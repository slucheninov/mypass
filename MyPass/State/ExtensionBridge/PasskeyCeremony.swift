import Foundation
import CryptoKit
import MyPassKit

enum PasskeyCeremonyError: Error, Equatable {
    case unsupportedAlgorithm
    case noMatchingCredential
    case userCancelled
    case invalidRequestJSON
    /// The `originUrl` the extension put on the wire disagrees with the `origin` it
    /// stamped into `extensions.remoteDesktopClientOverride` inside the same
    /// `requestDetailsJson` payload — or that field is missing entirely. See
    /// `PasskeyCeremony.validateOrigin` for why this check is weak on its own but still
    /// worth having.
    case originMismatch
    /// The relying party ID the request asked to sign for is not one the origin is
    /// permitted to claim under the WebAuthn RP ID rules (same host, or a registrable
    /// domain no narrower than the Public Suffix List boundary).
    case rpIdNotAuthorized
}

struct PasskeyCreateContext {
    let rpId: String
    let rpName: String
    let challenge: Data
    let userId: Data
    let userName: String
    let userDisplayName: String
    let excludeCredentialIds: [Data]
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
        // Chrome serializes descriptor IDs as base64url. Decode to bytes before
        // comparing with vault IDs so padding cannot change the exclusion decision.
        // Unsupported credential types cannot identify one of our public-key records.
        var excludeCredentialIds: [Data] = []
        if let rawDescriptors = json["excludeCredentials"] {
            guard let descriptors = rawDescriptors as? [[String: Any]] else {
                throw PasskeyCeremonyError.invalidRequestJSON
            }
            for descriptor in descriptors {
                guard let type = descriptor["type"] as? String,
                      let encodedId = descriptor["id"] as? String,
                      let credentialId = PasskeyBase64URL.decode(encodedId), !credentialId.isEmpty else {
                    throw PasskeyCeremonyError.invalidRequestJSON
                }
                if type == "public-key" { excludeCredentialIds.append(credentialId) }
            }
        }
        return PasskeyCreateContext(
            rpId: rpId, rpName: rpName, challenge: challenge,
            userId: userId, userName: userName, userDisplayName: userDisplayName,
            excludeCredentialIds: excludeCredentialIds,
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

    // MARK: Origin validation

    /// Validates the origin of a passkey ceremony instead of trusting whatever the
    /// extension sent as `originUrl` — `originUrl` alone is just a string the message
    /// carried, and `performCreate`/`performGet` stamp it verbatim into
    /// `clientDataJSON.origin`, which is exactly the value a relying party trusts when
    /// verifying the signature we hand back. Two independent checks, both required.
    ///
    /// Check 1 re-parses `requestDetailsJson` and compares `originUrl` against the origin
    /// the extension's own `background.js` (`originFromRequestDetails()`) stamped into
    /// `extensions.remoteDesktopClientOverride.origin` inside that same payload, failing
    /// closed when the field is absent. This check is weak on its own: a fully compromised
    /// extension controls both copies and can simply lie in agreement. What it actually
    /// buys is cheap — it stops a *partially* wrong message (a bug or a MITM rewriting only
    /// one of the two fields in transit) and keeps the two copies from silently drifting
    /// apart, which would otherwise mask the exact class of bug this hardening exists to
    /// catch.
    ///
    /// Check 2 is the real gate: it enforces the WebAuthn RP ID invariant that an origin may
    /// only assert relying-party IDs equal to its own host or a registrable domain of it.
    /// Without this check the app would happily sign an assertion binding an
    /// attacker-chosen origin to an attacker-chosen relying party — e.g. a page at
    /// `evil.example` claiming `rpId: "bank.com"` — which is precisely the cross-origin
    /// confusion WebAuthn's RP ID scoping exists to prevent. The Public Suffix List is what
    /// stops an rpId from climbing past the registrable domain (an origin at
    /// `evil.co.uk` must not be able to claim `rpId: "co.uk"` just because `"evil.co.uk"`
    /// ends with `".co.uk"` — `"co.uk"` is a public suffix, not a domain anyone registers
    /// under).
    static func validateOrigin(_ originUrl: String, requestDetailsJson: String, rpId: String) throws {
        // Check 1: the wire origin must match the payload's own origin.
        guard let data = requestDetailsJson.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let extensions = json["extensions"] as? [String: Any],
              let override = extensions["remoteDesktopClientOverride"] as? [String: Any],
              let payloadOrigin = override["origin"] as? String else {
            throw PasskeyCeremonyError.originMismatch
        }
        guard payloadOrigin == originUrl else {
            throw PasskeyCeremonyError.originMismatch
        }

        // Check 2: rpId must be authorized for the origin's host.
        guard let host = URL(string: originUrl)?.host?.lowercased() else {
            throw PasskeyCeremonyError.rpIdNotAuthorized
        }
        let normalizedRpId = rpId.lowercased()

        if normalizedRpId == host {
            return
        }
        if host.hasSuffix("." + normalizedRpId) {
            guard let registrable = PublicSuffixList.registrableDomain(of: host) else {
                throw PasskeyCeremonyError.rpIdNotAuthorized
            }
            if normalizedRpId == registrable || normalizedRpId.hasSuffix("." + registrable) {
                return
            }
            throw PasskeyCeremonyError.rpIdNotAuthorized
        }
        throw PasskeyCeremonyError.rpIdNotAuthorized
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

    /// MyPass's authenticator model identifier (AAGUID), generated once:
    /// 94803471-f8b4-48f9-98ff-fc4ac1a92af8.
    ///
    /// It identifies the authenticator MODEL, not a credential or a user: it is the same
    /// for every MyPass passkey, it is not secret, and it MUST NEVER CHANGE — entries in
    /// the community registry (github.com/passkeydeveloper/passkey-authenticator-aaguids)
    /// and relying-party allow/deny policies are keyed on this exact value. Sites that
    /// ingest that registry can then label the passkey as "MyPass" instead of showing
    /// an anonymous one (an all-zero AAGUID, which this used to be, identifies nothing).
    ///
    /// Attestation is unchanged: with the default "none" conveyance the response still
    /// uses fmt "none" with an empty statement, so this proves nothing about the device;
    /// it only names the model. The intent is that the browser passes the AAGUID on to
    /// the relying party; whether any given browser or site actually surfaces or honours
    /// it is outside this code's control.
    static let mypassAAGUID = Data([
        0x94, 0x80, 0x34, 0x71, 0xf8, 0xb4, 0x48, 0xf9,
        0x98, 0xff, 0xfc, 0x4a, 0xc1, 0xa9, 0x2a, 0xf8,
    ])

    private static func buildAttestedCredentialData(credentialId: Data, cosePublicKey: Data) -> Data {
        // attestedCredentialData = aaguid(16) | credentialIdLength(2) | credentialId | COSE key.
        var out = mypassAAGUID
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
                // Chrome validates these WebAuthn JSON fields against the CBOR object;
                // omitting them rejects completion even after the vault saved the key.
                "publicKeyAlgorithm": -7,
                "authenticatorData": PasskeyBase64URL.encode(authData),
                "publicKey": PasskeyBase64URL.encode(publicKey.derRepresentation),
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
