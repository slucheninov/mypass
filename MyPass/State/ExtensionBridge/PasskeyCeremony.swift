import Foundation
import CryptoKit

enum PasskeyCeremonyError: Error, Equatable {
    case unsupportedAlgorithm
    case noMatchingCredential
    case userCancelled
    case invalidRequestJSON
}

struct PasskeyCreateContext {
    let rpId: String
    let rpName: String
    let challenge: Data
    let userId: Data
    let userName: String
    let userDisplayName: String
    /// The RP's requested attestation conveyance, verbatim. WebAuthn's default is
    /// "none", and a live capture confirms Chrome forwards this field unchanged, so
    /// the authenticator — us — is what must honour it.
    let attestation: String
}

struct PasskeyGetContext {
    let rpId: String
    let challenge: Data
    let allowCredentialIds: [Data]
}

struct PasskeyCreateResult {
    let responseJson: String
    let credentialId: Data
    let privateKeyPEM: String
    /// Exposed so tests can independently re-verify the signature without
    /// re-parsing CBOR — see PasskeyCeremonyTests.
    let authData: Data
    let signature: Data
}

struct PasskeyGetResult {
    let responseJson: String
    let authData: Data
    let signature: Data
}

// MARK: - Minimal CBOR encoder (RFC 8949) — only the major types this ceremony
// needs: unsigned int (0), negative int (1), byte string (2), text string (3),
// map (5). No indefinite-length items, tags, or floats — not a general-purpose
// CBOR library, just enough for a fixed-shape attestation object.
enum CBOR {
    private static func encodeHeader(majorType: UInt8, length: UInt64) -> Data {
        let typeBits = majorType << 5
        if length < 24 {
            return Data([typeBits | UInt8(length)])
        } else if length <= 0xFF {
            return Data([typeBits | 24, UInt8(length)])
        } else if length <= 0xFFFF {
            return Data([typeBits | 25, UInt8((length >> 8) & 0xFF), UInt8(length & 0xFF)])
        } else {
            return Data([
                typeBits | 26,
                UInt8((length >> 24) & 0xFF), UInt8((length >> 16) & 0xFF),
                UInt8((length >> 8) & 0xFF), UInt8(length & 0xFF),
            ])
        }
    }

    static func encodeUnsignedInt(_ value: UInt64) -> Data { encodeHeader(majorType: 0, length: value) }

    static func encodeNegativeInt(_ value: Int) -> Data {
        precondition(value < 0)
        return encodeHeader(majorType: 1, length: UInt64(-1 - value))
    }

    static func encodeByteString(_ bytes: Data) -> Data {
        encodeHeader(majorType: 2, length: UInt64(bytes.count)) + bytes
    }

    static func encodeTextString(_ string: String) -> Data {
        let bytes = Data(string.utf8)
        return encodeHeader(majorType: 3, length: UInt64(bytes.count)) + bytes
    }

    static func encodeMapHeader(pairCount: Int) -> Data { encodeHeader(majorType: 5, length: UInt64(pairCount)) }
}

enum PasskeyCeremony {
    // MARK: Parsing

    static func parseCreateRequest(_ requestDetailsJson: String) throws -> PasskeyCreateContext {
        guard let data = requestDetailsJson.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PasskeyCeremonyError.invalidRequestJSON
        }
        guard let challengeB64 = json["challenge"] as? String,
              let challenge = PasskeyBase64URL.decode(challengeB64),
              let rp = json["rp"] as? [String: Any],
              let rpId = rp["id"] as? String,
              let user = json["user"] as? [String: Any],
              let userIdB64 = user["id"] as? String,
              let userId = PasskeyBase64URL.decode(userIdB64) else {
            throw PasskeyCeremonyError.invalidRequestJSON
        }
        let pubKeyCredParams = json["pubKeyCredParams"] as? [[String: Any]] ?? []
        guard pubKeyCredParams.contains(where: { ($0["alg"] as? Int) == -7 }) else {
            throw PasskeyCeremonyError.unsupportedAlgorithm
        }
        let rpName = (rp["name"] as? String) ?? rpId
        let userName = (user["name"] as? String) ?? ""
        let userDisplayName = (user["displayName"] as? String) ?? userName
        let attestation = (json["attestation"] as? String) ?? "none"
        return PasskeyCreateContext(
            rpId: rpId, rpName: rpName, challenge: challenge,
            userId: userId, userName: userName, userDisplayName: userDisplayName,
            attestation: attestation
        )
    }

    static func parseGetRequest(_ requestDetailsJson: String) throws -> PasskeyGetContext {
        guard let data = requestDetailsJson.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let challengeB64 = json["challenge"] as? String,
              let challenge = PasskeyBase64URL.decode(challengeB64),
              let rpId = json["rpId"] as? String else {
            throw PasskeyCeremonyError.invalidRequestJSON
        }
        let allowCredentials = json["allowCredentials"] as? [[String: Any]] ?? []
        let allowCredentialIds = allowCredentials.compactMap { ($0["id"] as? String).flatMap(PasskeyBase64URL.decode) }
        return PasskeyGetContext(rpId: rpId, challenge: challenge, allowCredentialIds: allowCredentialIds)
    }

    // MARK: Building blocks shared by create + get

    private static func buildClientDataJSON(type: String, challenge: Data, origin: String) -> Data {
        let object: [String: Any] = [
            "type": type, "challenge": PasskeyBase64URL.encode(challenge), "origin": origin, "crossOrigin": false,
        ]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }

    /// COSE_Key for an EC2 P-256 public key. Key order is canonical CTAP2 CBOR:
    /// unsigned labels ascending (1, 3) before negative labels ascending (-1, -2, -3).
    private static func coseEC2PublicKey(x: Data, y: Data) -> Data {
        var out = CBOR.encodeMapHeader(pairCount: 5)
        out += CBOR.encodeUnsignedInt(1) + CBOR.encodeUnsignedInt(2)   // kty: EC2
        out += CBOR.encodeUnsignedInt(3) + CBOR.encodeNegativeInt(-7)  // alg: ES256
        out += CBOR.encodeNegativeInt(-1) + CBOR.encodeUnsignedInt(1)  // crv: P-256
        out += CBOR.encodeNegativeInt(-2) + CBOR.encodeByteString(x)
        out += CBOR.encodeNegativeInt(-3) + CBOR.encodeByteString(y)
        return out
    }

    private static func buildAuthenticatorData(
        rpId: String, flags: UInt8, signCount: UInt32, attestedCredentialData: Data?
    ) -> Data {
        var out = Data(SHA256.hash(data: Data(rpId.utf8)))
        out.append(flags)
        withUnsafeBytes(of: signCount.bigEndian) { out.append(contentsOf: $0) }
        if let attestedCredentialData { out.append(attestedCredentialData) }
        return out
    }

    private static func buildAttestedCredentialData(credentialId: Data, cosePublicKey: Data) -> Data {
        // AAGUID: all-zero — a software authenticator with no FIDO MDS registration.
        var out = Data(repeating: 0, count: 16)
        let length = UInt16(credentialId.count)
        out.append(UInt8(length >> 8))
        out.append(UInt8(length & 0xFF))
        out.append(credentialId)
        out.append(cosePublicKey)
        return out
    }

    /// Honours the RP's requested conveyance. When the RP asked for "none" — the WebAuthn
    /// default, and what a live Chrome capture actually sends — we emit the `none` format
    /// with an empty statement. Returning self-attestation regardless would be rejected by
    /// any RP that checks `fmt == "none"` for a `none` request. Key ordering stays
    /// canonical CTAP2 in both branches: text keys sort by length, then bytewise.
    private static func buildAttestationObject(authData: Data, signature: Data, attestation: String) -> Data {
        var out = CBOR.encodeMapHeader(pairCount: 3)
        if attestation == "none" {
            out += CBOR.encodeTextString("fmt") + CBOR.encodeTextString("none")
            out += CBOR.encodeTextString("attStmt") + CBOR.encodeMapHeader(pairCount: 0)
            out += CBOR.encodeTextString("authData") + CBOR.encodeByteString(authData)
            return out
        }
        out += CBOR.encodeTextString("fmt") + CBOR.encodeTextString("packed")
        var attStmt = CBOR.encodeMapHeader(pairCount: 2)
        attStmt += CBOR.encodeTextString("alg") + CBOR.encodeNegativeInt(-7)
        attStmt += CBOR.encodeTextString("sig") + CBOR.encodeByteString(signature)
        out += CBOR.encodeTextString("attStmt") + attStmt
        out += CBOR.encodeTextString("authData") + CBOR.encodeByteString(authData)
        return out
    }

    // MARK: Create

    static func performCreate(context: PasskeyCreateContext, originUrl: String) throws -> PasskeyCreateResult {
        let privateKey = P256.Signing.PrivateKey()
        let publicKey = privateKey.publicKey
        let rawKey = publicKey.rawRepresentation // 64 bytes: X(32) || Y(32), no format-byte prefix
        guard rawKey.count == 64 else { throw PasskeyCeremonyError.invalidRequestJSON }
        let x = rawKey.prefix(32)
        let y = rawKey.suffix(32)

        var credentialIdBytes = Data(count: 32)
        _ = credentialIdBytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }

        let cosePublicKey = coseEC2PublicKey(x: Data(x), y: Data(y))
        let attestedCredentialData = buildAttestedCredentialData(
            credentialId: credentialIdBytes, cosePublicKey: cosePublicKey
        )
        // Flags: UP(0x01) | UV(0x04) | BE(0x08) | BS(0x10) | AT(0x40) — MyPass's own
        // unlock+confirm stands in for user verification for a software authenticator.
        let authData = buildAuthenticatorData(
            rpId: context.rpId, flags: 0x5D, signCount: 0, attestedCredentialData: attestedCredentialData
        )

        let clientDataJSON = buildClientDataJSON(
            type: "webauthn.create", challenge: context.challenge, origin: originUrl
        )
        let clientDataHash = Data(SHA256.hash(data: clientDataJSON))
        let signature = try privateKey.signature(for: authData + clientDataHash).derRepresentation

        let attestationObject = buildAttestationObject(
            authData: authData, signature: signature, attestation: context.attestation
        )

        let response: [String: Any] = [
            "id": PasskeyBase64URL.encode(credentialIdBytes),
            "rawId": PasskeyBase64URL.encode(credentialIdBytes),
            "type": "public-key",
            "response": [
                "clientDataJSON": PasskeyBase64URL.encode(clientDataJSON),
                "attestationObject": PasskeyBase64URL.encode(attestationObject),
                "transports": ["internal"],
            ],
            "clientExtensionResults": [String: Any](),
        ]
        let responseData = try JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])
        let responseJson = String(data: responseData, encoding: .utf8) ?? "{}"

        return PasskeyCreateResult(
            responseJson: responseJson, credentialId: credentialIdBytes,
            privateKeyPEM: privateKey.pemRepresentation, authData: authData, signature: signature
        )
    }

    // MARK: Get

    static func performGet(
        context: PasskeyGetContext, originUrl: String, privateKeyPEM: String, credentialId: Data, userHandle: Data?
    ) throws -> PasskeyGetResult {
        let privateKey = try P256.Signing.PrivateKey(pemRepresentation: privateKeyPEM)

        // Flags: UP(0x01) | UV(0x04) | BE(0x08) | BS(0x10) — no AT, no attested
        // credential data on an assertion.
        let authData = buildAuthenticatorData(
            rpId: context.rpId, flags: 0x1D, signCount: 0, attestedCredentialData: nil
        )

        let clientDataJSON = buildClientDataJSON(
            type: "webauthn.get", challenge: context.challenge, origin: originUrl
        )
        let clientDataHash = Data(SHA256.hash(data: clientDataJSON))
        let signature = try privateKey.signature(for: authData + clientDataHash).derRepresentation

        var responseInner: [String: Any] = [
            "clientDataJSON": PasskeyBase64URL.encode(clientDataJSON),
            "authenticatorData": PasskeyBase64URL.encode(authData),
            "signature": PasskeyBase64URL.encode(signature),
        ]
        if let userHandle {
            responseInner["userHandle"] = PasskeyBase64URL.encode(userHandle)
        }
        let response: [String: Any] = [
            "id": PasskeyBase64URL.encode(credentialId),
            "rawId": PasskeyBase64URL.encode(credentialId),
            "type": "public-key",
            "response": responseInner,
            "clientExtensionResults": [String: Any](),
        ]
        let responseData = try JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])
        let responseJson = String(data: responseData, encoding: .utf8) ?? "{}"

        return PasskeyGetResult(responseJson: responseJson, authData: authData, signature: signature)
    }
}
