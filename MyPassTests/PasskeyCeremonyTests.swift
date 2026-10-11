import XCTest
import CryptoKit
@testable import MyPass

final class PasskeyCeremonyTests: XCTestCase {
    private func createFixtureJSON(
        challenge: Data,
        userId: Data,
        algs: [Int] = [-7],
        attestation: String = "none"
    ) -> String {
        let params = algs.map { "{ \"type\": \"public-key\", \"alg\": \($0) }" }.joined(separator: ", ")
        return """
        {
          "challenge": "\(PasskeyBase64URL.encode(challenge))",
          "rp": { "id": "example.com", "name": "Example" },
          "user": { "id": "\(PasskeyBase64URL.encode(userId))", "name": "alice", "displayName": "Alice" },
          "pubKeyCredParams": [\(params)],
          "attestation": "\(attestation)"
        }
        """
    }

    private func getFixtureJSON(challenge: Data, credentialIds: [Data] = []) -> String {
        let allow = credentialIds
            .map { "{ \"type\": \"public-key\", \"id\": \"\(PasskeyBase64URL.encode($0))\" }" }
            .joined(separator: ", ")
        return """
        {
          "challenge": "\(PasskeyBase64URL.encode(challenge))",
          "rpId": "example.com",
          "allowCredentials": [\(allow)]
        }
        """
    }

    private func attestationObject(from result: PasskeyCreateResult) throws -> Data {
        let responseData = try XCTUnwrap(result.responseJson.data(using: .utf8))
        let response = try XCTUnwrap(try JSONSerialization.jsonObject(with: responseData) as? [String: Any])
        let inner = try XCTUnwrap(response["response"] as? [String: Any])
        let b64 = try XCTUnwrap(inner["attestationObject"] as? String)
        return try XCTUnwrap(PasskeyBase64URL.decode(b64))
    }

    private func clientDataJSON(fromResponseJson json: String) throws -> Data {
        let responseData = try XCTUnwrap(json.data(using: .utf8))
        let response = try XCTUnwrap(try JSONSerialization.jsonObject(with: responseData) as? [String: Any])
        let inner = try XCTUnwrap(response["response"] as? [String: Any])
        let b64 = try XCTUnwrap(inner["clientDataJSON"] as? String)
        return try XCTUnwrap(PasskeyBase64URL.decode(b64))
    }

    // MARK: Parsing

    func testParseCreateRequestExtractsRpAndUser() throws {
        let challenge = Data((0..<16).map { UInt8($0) })
        let userId = Data([1, 2, 3, 4])
        let context = try PasskeyCeremony.parseCreateRequest(createFixtureJSON(challenge: challenge, userId: userId))
        XCTAssertEqual(context.rpId, "example.com")
        XCTAssertEqual(context.rpName, "Example")
        XCTAssertEqual(context.userName, "alice")
        XCTAssertEqual(context.userDisplayName, "Alice")
        XCTAssertEqual(context.challenge, challenge)
        XCTAssertEqual(context.userId, userId)
        XCTAssertEqual(context.attestation, "none")
        XCTAssertEqual(context.excludeCredentialIds, [])
    }

    func testParseCreateRequestDecodesExcludedIDsAndIgnoresUnsupportedCredentialTypes() throws {
        let fixture = createFixtureJSON(challenge: Data([1]), userId: Data([2]))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(fixture.utf8)) as? [String: Any])
        json["excludeCredentials"] = [
            ["type": "public-key", "id": "-_8"],
            ["type": "public-key", "id": "AQI="],
            ["type": "future-type", "id": "Aw"]
        ]
        let encoded = String(decoding: try JSONSerialization.data(withJSONObject: json), as: UTF8.self)

        let context = try PasskeyCeremony.parseCreateRequest(encoded)

        XCTAssertEqual(context.excludeCredentialIds, [Data([0xfb, 0xff]), Data([1, 2])])
    }

    func testParseCreateRequestRejectsMalformedExclusionRatherThanDroppingIt() throws {
        let fixture = createFixtureJSON(challenge: Data([1]), userId: Data([2]))
        let malformed: [Any] = [
            "not an array", [["type": "public-key", "id": "%%%"]],
            [["type": "public-key", "id": ""]], [["type": "public-key"]], [["id": "AQ"]]
        ]
        for descriptors in malformed {
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(fixture.utf8)) as? [String: Any])
            json["excludeCredentials"] = descriptors
            let encoded = String(decoding: try JSONSerialization.data(withJSONObject: json), as: UTF8.self)
            XCTAssertThrowsError(try PasskeyCeremony.parseCreateRequest(encoded)) { error in
                XCTAssertEqual(error as? PasskeyCeremonyError, .invalidRequestJSON)
            }
        }
    }

    func testParseCreateRequestThrowsUnsupportedAlgorithmWhenES256Missing() {
        let json = createFixtureJSON(challenge: Data([1, 2, 3]), userId: Data([9, 9, 9]), algs: [-257])
        XCTAssertThrowsError(try PasskeyCeremony.parseCreateRequest(json)) { error in
            XCTAssertEqual(error as? PasskeyCeremonyError, .unsupportedAlgorithm)
        }
    }

    func testParseCreateRequestAcceptsES256AlongsideOtherAlgorithms() throws {
        // A real Chrome payload offers [-7, -257]; we must accept it, not reject it.
        let json = createFixtureJSON(challenge: Data([1]), userId: Data([2]), algs: [-7, -257])
        XCTAssertNoThrow(try PasskeyCeremony.parseCreateRequest(json))
    }

    func testParseCreateRequestThrowsInvalidRequestJSONOnGarbage() {
        XCTAssertThrowsError(try PasskeyCeremony.parseCreateRequest("not json")) { error in
            XCTAssertEqual(error as? PasskeyCeremonyError, .invalidRequestJSON)
        }
    }

    func testParseCreateRequestDefaultsAttestationToNoneWhenAbsent() throws {
        let json = """
        {
          "challenge": "\(PasskeyBase64URL.encode(Data([1])))",
          "rp": { "id": "example.com" },
          "user": { "id": "\(PasskeyBase64URL.encode(Data([2])))", "name": "alice" },
          "pubKeyCredParams": [{ "type": "public-key", "alg": -7 }]
        }
        """
        let context = try PasskeyCeremony.parseCreateRequest(json)
        XCTAssertEqual(context.attestation, "none")
        XCTAssertEqual(context.rpName, "example.com", "rpName falls back to rpId")
        XCTAssertEqual(context.userDisplayName, "alice", "displayName falls back to name")
    }

    func testParseGetRequestExtractsRpIdAndAllowCredentials() throws {
        let credentialId = Data([5, 6, 7])
        let context = try PasskeyCeremony.parseGetRequest(
            getFixtureJSON(challenge: Data([1, 2, 3]), credentialIds: [credentialId])
        )
        XCTAssertEqual(context.rpId, "example.com")
        XCTAssertEqual(context.allowCredentialIds, [credentialId])
    }

    func testParseGetRequestIgnoresChromeInjectedTransports() throws {
        // Chrome adds a `transports` array of its own; parsing must not depend on it.
        let credentialId = Data([5, 6, 7])
        let json = """
        {
          "challenge": "\(PasskeyBase64URL.encode(Data([1])))",
          "rpId": "example.com",
          "allowCredentials": [{
            "type": "public-key",
            "id": "\(PasskeyBase64URL.encode(credentialId))",
            "transports": ["usb", "nfc", "ble", "hybrid", "internal"]
          }]
        }
        """
        let context = try PasskeyCeremony.parseGetRequest(json)
        XCTAssertEqual(context.allowCredentialIds, [credentialId])
    }

    // MARK: Create

    func testPerformCreateProducesVerifiableES256Signature() throws {
        let challenge = Data((0..<16).map { UInt8($0) })
        let userId = Data([1, 2, 3, 4])
        let context = try PasskeyCeremony.parseCreateRequest(createFixtureJSON(challenge: challenge, userId: userId))

        let result = try PasskeyCeremony.performCreate(context: context, originUrl: "https://example.com")

        let privateKey = try P256.Signing.PrivateKey(pemRepresentation: result.privateKeyPEM)
        let publicKey = privateKey.publicKey

        let responseData = try XCTUnwrap(result.responseJson.data(using: .utf8))
        let response = try XCTUnwrap(try JSONSerialization.jsonObject(with: responseData) as? [String: Any])
        XCTAssertEqual(response["type"] as? String, "public-key")

        let clientDataJSON = try clientDataJSON(fromResponseJson: result.responseJson)
        let clientDataHash = Data(SHA256.hash(data: clientDataJSON))

        // Independently verify the signature — proves real ES256 correctness,
        // not just that JSON round-trips.
        let signature = try P256.Signing.ECDSASignature(derRepresentation: result.signature)
        XCTAssertTrue(publicKey.isValidSignature(signature, for: result.authData + clientDataHash))
        XCTAssertGreaterThan(result.credentialId.count, 0)

        let clientData = try XCTUnwrap(try JSONSerialization.jsonObject(with: clientDataJSON) as? [String: Any])
        XCTAssertEqual(clientData["type"] as? String, "webauthn.create")
        XCTAssertEqual(clientData["origin"] as? String, "https://example.com")
        XCTAssertEqual(clientData["challenge"] as? String, PasskeyBase64URL.encode(challenge))
    }

    func testCreateResponseIncludesChromiumRequiredFieldsMatchingAttestation() throws {
        for attestation in ["none", "direct"] {
            let context = try PasskeyCeremony.parseCreateRequest(
                createFixtureJSON(challenge: Data([1, 2]), userId: Data([3]), attestation: attestation)
            )
            let result = try PasskeyCeremony.performCreate(context: context, originUrl: "https://example.com")
            let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.responseJson.utf8)) as? [String: Any])
            let response = try XCTUnwrap(root["response"] as? [String: Any])
            XCTAssertEqual(response["publicKeyAlgorithm"] as? Int, -7)
            let authData = try XCTUnwrap(PasskeyBase64URL.decode(try XCTUnwrap(response["authenticatorData"] as? String)))
            XCTAssertEqual(authData, result.authData)
            let object = try attestationObject(from: result)
            // Canonical CBOR ends with the authData byte string in both conveyances.
            // Verify the encoded byte-string length, not only an arbitrary suffix match.
            let expectedAuthField = Data([0x68]) + Data("authData".utf8) + Data([0x58, UInt8(authData.count)]) + authData
            XCTAssertEqual(object.suffix(expectedAuthField.count), expectedAuthField)
            let der = try XCTUnwrap(PasskeyBase64URL.decode(try XCTUnwrap(response["publicKey"] as? String)))
            let publicKey = try P256.Signing.PublicKey(derRepresentation: der)
            let savedKey = try P256.Signing.PrivateKey(pemRepresentation: result.privateKeyPEM)
            XCTAssertEqual(publicKey.rawRepresentation, savedKey.publicKey.rawRepresentation)
            // Independently construct the EC2 COSE tail: kty=2, alg=-7, crv=1,
            // followed by 32-byte x/y coordinates from the returned SPKI public key.
            let cose = Data([0xa5, 0x01, 0x02, 0x03, 0x26, 0x20, 0x01, 0x21, 0x58, 0x20])
                + publicKey.rawRepresentation.prefix(32) + Data([0x22, 0x58, 0x20])
                + publicKey.rawRepresentation.suffix(32)
            XCTAssertEqual(authData.suffix(cose.count), cose)
        }
    }

    func testPerformCreateAuthDataHasAttestedCredentialDataFlagSet() throws {
        let context = try PasskeyCeremony.parseCreateRequest(createFixtureJSON(challenge: Data([1]), userId: Data([2])))
        let result = try PasskeyCeremony.performCreate(context: context, originUrl: "https://example.com")
        let flags = result.authData[32] // byte 32: rpIdHash is 32 bytes, flags is the next byte
        XCTAssertNotEqual(flags & 0x40, 0, "AT (attested credential data present) flag must be set on create")
        XCTAssertNotEqual(flags & 0x01, 0, "UP flag must be set")
        XCTAssertNotEqual(flags & 0x04, 0, "UV flag must be set")
    }

    func testAuthDataRpIdHashMatchesSHA256OfRpId() throws {
        let context = try PasskeyCeremony.parseCreateRequest(createFixtureJSON(challenge: Data([1]), userId: Data([2])))
        let result = try PasskeyCeremony.performCreate(context: context, originUrl: "https://example.com")
        let expected = Data(SHA256.hash(data: Data("example.com".utf8)))
        XCTAssertEqual(result.authData.prefix(32), expected)
    }

    /// The S8 decision: honour the conveyance the RP asked for.
    func testAttestationObjectUsesNoneFormatWhenRequested() throws {
        let context = try PasskeyCeremony.parseCreateRequest(
            createFixtureJSON(challenge: Data([1]), userId: Data([2]), attestation: "none")
        )
        let result = try PasskeyCeremony.performCreate(context: context, originUrl: "https://example.com")
        let object = try attestationObject(from: result)

        // CBOR: a3 (map, 3 pairs) 63 "fmt" 64 "none"
        let expectedPrefix = Data([0xA3, 0x63]) + Data("fmt".utf8) + Data([0x64]) + Data("none".utf8)
        XCTAssertEqual(object.prefix(expectedPrefix.count), expectedPrefix)
    }

    func testAttestationObjectUsesPackedFormatWhenDirectRequested() throws {
        let context = try PasskeyCeremony.parseCreateRequest(
            createFixtureJSON(challenge: Data([1]), userId: Data([2]), attestation: "direct")
        )
        let result = try PasskeyCeremony.performCreate(context: context, originUrl: "https://example.com")
        let object = try attestationObject(from: result)

        // CBOR: a3 (map, 3 pairs) 63 "fmt" 66 "packed"
        let expectedPrefix = Data([0xA3, 0x63]) + Data("fmt".utf8) + Data([0x66]) + Data("packed".utf8)
        XCTAssertEqual(object.prefix(expectedPrefix.count), expectedPrefix)
    }

    // MARK: Get

    func testPerformGetProducesValidAssertionSignature() throws {
        // Reuse performCreate to get a real ES256 keypair/PEM, then sign a get ceremony with it.
        let createContext = try PasskeyCeremony.parseCreateRequest(
            createFixtureJSON(challenge: Data([1]), userId: Data([2, 2]))
        )
        let createResult = try PasskeyCeremony.performCreate(context: createContext, originUrl: "https://example.com")

        let getContext = try PasskeyCeremony.parseGetRequest(getFixtureJSON(challenge: Data([9, 9, 9, 9])))
        let getResult = try PasskeyCeremony.performGet(
            context: getContext, originUrl: "https://example.com",
            privateKeyPEM: createResult.privateKeyPEM, credentialId: createResult.credentialId, userHandle: Data([2, 2])
        )

        let privateKey = try P256.Signing.PrivateKey(pemRepresentation: createResult.privateKeyPEM)
        let clientDataJSON = try clientDataJSON(fromResponseJson: getResult.responseJson)
        let clientDataHash = Data(SHA256.hash(data: clientDataJSON))

        let signature = try P256.Signing.ECDSASignature(derRepresentation: getResult.signature)
        XCTAssertTrue(privateKey.publicKey.isValidSignature(signature, for: getResult.authData + clientDataHash))

        let clientData = try XCTUnwrap(try JSONSerialization.jsonObject(with: clientDataJSON) as? [String: Any])
        XCTAssertEqual(clientData["type"] as? String, "webauthn.get")
    }

    func testPerformGetAuthDataDoesNotHaveAttestedCredentialDataFlag() throws {
        let createContext = try PasskeyCeremony.parseCreateRequest(
            createFixtureJSON(challenge: Data([1]), userId: Data([2]))
        )
        let createResult = try PasskeyCeremony.performCreate(context: createContext, originUrl: "https://example.com")
        let getContext = try PasskeyCeremony.parseGetRequest(getFixtureJSON(challenge: Data([3])))
        let getResult = try PasskeyCeremony.performGet(
            context: getContext, originUrl: "https://example.com",
            privateKeyPEM: createResult.privateKeyPEM, credentialId: createResult.credentialId, userHandle: nil
        )
        let flags = getResult.authData[32]
        XCTAssertEqual(flags & 0x40, 0, "AT flag must NOT be set on a get/assertion authData")
        XCTAssertEqual(getResult.authData.count, 37, "assertion authData is exactly rpIdHash(32) + flags(1) + counter(4)")
    }

    func testPerformGetOmitsUserHandleWhenNil() throws {
        let createContext = try PasskeyCeremony.parseCreateRequest(
            createFixtureJSON(challenge: Data([1]), userId: Data([2]))
        )
        let createResult = try PasskeyCeremony.performCreate(context: createContext, originUrl: "https://example.com")
        let getContext = try PasskeyCeremony.parseGetRequest(getFixtureJSON(challenge: Data([3])))
        let getResult = try PasskeyCeremony.performGet(
            context: getContext, originUrl: "https://example.com",
            privateKeyPEM: createResult.privateKeyPEM, credentialId: createResult.credentialId, userHandle: nil
        )

        let responseData = try XCTUnwrap(getResult.responseJson.data(using: .utf8))
        let response = try XCTUnwrap(try JSONSerialization.jsonObject(with: responseData) as? [String: Any])
        let inner = try XCTUnwrap(response["response"] as? [String: Any])
        XCTAssertNil(inner["userHandle"])
    }

    // MARK: Origin validation

    /// Minimal payload carrying only what `validateOrigin` itself reads — the
    /// `extensions.remoteDesktopClientOverride.origin` field. `nil` omits the whole
    /// `extensions` block, matching a payload the extension never stamped.
    private func requestJSONWithOrigin(_ origin: String?) -> String {
        guard let origin else { return "{}" }
        return """
        { "extensions": { "remoteDesktopClientOverride": { "origin": "\(origin)" } } }
        """
    }

    func testValidateOriginAcceptsExactRpIdMatch() {
        let json = requestJSONWithOrigin("https://example.com")
        XCTAssertNoThrow(
            try PasskeyCeremony.validateOrigin("https://example.com", requestDetailsJson: json, rpId: "example.com")
        )
    }

    func testValidateOriginAcceptsLocalhost() {
        let json = requestJSONWithOrigin("http://localhost:8765")
        XCTAssertNoThrow(
            try PasskeyCeremony.validateOrigin("http://localhost:8765", requestDetailsJson: json, rpId: "localhost")
        )
    }

    func testValidateOriginAcceptsRpIdOnParentRegistrableDomain() {
        let json = requestJSONWithOrigin("https://login.example.com")
        XCTAssertNoThrow(
            try PasskeyCeremony.validateOrigin("https://login.example.com", requestDetailsJson: json, rpId: "example.com")
        )
    }

    func testValidateOriginRejectsWireOriginDisagreeingWithPayloadOrigin() {
        let json = requestJSONWithOrigin("https://example.com")
        XCTAssertThrowsError(
            try PasskeyCeremony.validateOrigin("https://attacker.example", requestDetailsJson: json, rpId: "example.com")
        ) { error in
            XCTAssertEqual(error as? PasskeyCeremonyError, .originMismatch)
        }
    }

    func testValidateOriginFailsClosedWhenPayloadHasNoRemoteDesktopClientOverride() {
        let json = requestJSONWithOrigin(nil)
        XCTAssertThrowsError(
            try PasskeyCeremony.validateOrigin("https://example.com", requestDetailsJson: json, rpId: "example.com")
        ) { error in
            XCTAssertEqual(error as? PasskeyCeremonyError, .originMismatch)
        }
    }

    func testValidateOriginRejectsUnrelatedRpId() {
        let json = requestJSONWithOrigin("https://example.com")
        XCTAssertThrowsError(
            try PasskeyCeremony.validateOrigin("https://example.com", requestDetailsJson: json, rpId: "evil.com")
        ) { error in
            XCTAssertEqual(error as? PasskeyCeremonyError, .rpIdNotAuthorized)
        }
    }

    func testValidateOriginRejectsRpIdClimbingPastPublicSuffix() {
        let json = requestJSONWithOrigin("https://evil.co.uk")
        XCTAssertThrowsError(
            try PasskeyCeremony.validateOrigin("https://evil.co.uk", requestDetailsJson: json, rpId: "co.uk")
        ) { error in
            XCTAssertEqual(error as? PasskeyCeremonyError, .rpIdNotAuthorized)
        }
    }

    // MARK: CBOR

    func testCBOREncodesCanonicalHeadersAcrossLengthBoundaries() {
        XCTAssertEqual(CBOR.encodeUnsignedInt(1), Data([0x01]))
        XCTAssertEqual(CBOR.encodeUnsignedInt(23), Data([0x17]))
        XCTAssertEqual(CBOR.encodeUnsignedInt(24), Data([0x18, 0x18]))
        XCTAssertEqual(CBOR.encodeUnsignedInt(256), Data([0x19, 0x01, 0x00]))
        XCTAssertEqual(CBOR.encodeNegativeInt(-1), Data([0x20]))
        XCTAssertEqual(CBOR.encodeNegativeInt(-7), Data([0x26]))
        XCTAssertEqual(CBOR.encodeTextString("fmt"), Data([0x63]) + Data("fmt".utf8))
        XCTAssertEqual(CBOR.encodeByteString(Data([1, 2])), Data([0x42, 0x01, 0x02]))
        XCTAssertEqual(CBOR.encodeMapHeader(pairCount: 3), Data([0xA3]))
    }
}
