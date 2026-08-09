import XCTest
@testable import ExtensionBridgeKit

final class ExtensionBridgeMessagesTests: XCTestCase {
    private func jsonObject(from data: Data) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - Requests

    func testGetCredentialsRoundTripsAndHasExpectedShape() throws {
        let request = ExtensionBridgeRequest.getCredentials(token: "tok-1", url: "https://example.com", pairing: nil)
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(ExtensionBridgeRequest.self, from: data)
        XCTAssertEqual(decoded, request)

        let object = try jsonObject(from: data)
        XCTAssertEqual(object["type"] as? String, "getCredentials")
        XCTAssertEqual(object["token"] as? String, "tok-1")
        XCTAssertEqual(object["url"] as? String, "https://example.com")
    }

    func testFillCredentialRoundTripsAndHasExpectedShape() throws {
        let request = ExtensionBridgeRequest.fillCredential(token: "tok-2", id: "entry-1", url: "https://example.com/login", pairing: nil)
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(ExtensionBridgeRequest.self, from: data)
        XCTAssertEqual(decoded, request)

        let object = try jsonObject(from: data)
        XCTAssertEqual(object["type"] as? String, "fillCredential")
        XCTAssertEqual(object["token"] as? String, "tok-2")
        XCTAssertEqual(object["id"] as? String, "entry-1")
        XCTAssertEqual(object["url"] as? String, "https://example.com/login")
    }

    func testProposeSaveLoginRoundTripsAndHasExpectedShape() throws {
        let request = ExtensionBridgeRequest.proposeSaveLogin(
            token: "tok-3", url: "https://example.com/signup", username: "alice", password: "s3cret", pairing: nil
        )
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(ExtensionBridgeRequest.self, from: data)
        XCTAssertEqual(decoded, request)

        let object = try jsonObject(from: data)
        XCTAssertEqual(object["type"] as? String, "proposeSaveLogin")
        XCTAssertEqual(object["token"] as? String, "tok-3")
        XCTAssertEqual(object["username"] as? String, "alice")
        XCTAssertEqual(object["password"] as? String, "s3cret")
    }

    func testDecodingUnknownRequestTypeThrows() {
        let data = Data("{\"type\":\"bogus\",\"token\":\"t\"}".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(ExtensionBridgeRequest.self, from: data))
    }

    func testGetCredentialsRoundTripsWithOptionalPairing() throws {
        let request = ExtensionBridgeRequest.getCredentials(token: "tok-1", url: "https://example.com", pairing: "secret-b64")
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(ExtensionBridgeRequest.self, from: data)
        XCTAssertEqual(decoded, request)
        let object = try jsonObject(from: data)
        XCTAssertEqual(object["pairing"] as? String, "secret-b64")
    }

    func testGetCredentialsRoundTripsWithoutPairingKeyWhenNil() throws {
        let request = ExtensionBridgeRequest.getCredentials(token: "tok-1", url: "https://example.com", pairing: nil)
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(ExtensionBridgeRequest.self, from: data)
        XCTAssertEqual(decoded, request)
        XCTAssertNil(try jsonObject(from: data)["pairing"])
    }

    func testStartPairingRoundTripsAndHasExpectedShape() throws {
        let request = ExtensionBridgeRequest.startPairing(token: "tok-p", browser: "Google Chrome")
        let data = try JSONEncoder().encode(request)
        XCTAssertEqual(try JSONDecoder().decode(ExtensionBridgeRequest.self, from: data), request)
        let object = try jsonObject(from: data)
        XCTAssertEqual(object["type"] as? String, "startPairing")
        XCTAssertEqual(object["token"] as? String, "tok-p")
        XCTAssertEqual(object["browser"] as? String, "Google Chrome")
    }

    func testStartPairingRoundTripsWithoutBrowserKeyWhenNil() throws {
        let request = ExtensionBridgeRequest.startPairing(token: "tok-p", browser: nil)
        let data = try JSONEncoder().encode(request)
        XCTAssertEqual(try JSONDecoder().decode(ExtensionBridgeRequest.self, from: data), request)
        XCTAssertNil(try jsonObject(from: data)["browser"])
    }

    func testCompletePairingRoundTripsAndHasExpectedShape() throws {
        let request = ExtensionBridgeRequest.completePairing(token: "tok-p", code: "123456")
        let data = try JSONEncoder().encode(request)
        XCTAssertEqual(try JSONDecoder().decode(ExtensionBridgeRequest.self, from: data), request)
        let object = try jsonObject(from: data)
        XCTAssertEqual(object["type"] as? String, "completePairing")
        XCTAssertEqual(object["code"] as? String, "123456")
    }

    // MARK: - Responses

    func testLockedRoundTripsAndHasExpectedShape() throws {
        let response = ExtensionBridgeResponse.locked
        let data = try JSONEncoder().encode(response)
        XCTAssertEqual(try JSONDecoder().decode(ExtensionBridgeResponse.self, from: data), response)
        XCTAssertEqual(try jsonObject(from: data)["type"] as? String, "locked")
    }

    func testCredentialListRoundTripsAndNeverIncludesAPasswordKey() throws {
        let response = ExtensionBridgeResponse.credentialList([
            ExtensionCredentialSummary(id: "1", title: "Example", username: "alice", hasTotp: false, hasPasskey: false)
        ])
        let data = try JSONEncoder().encode(response)
        XCTAssertEqual(try JSONDecoder().decode(ExtensionBridgeResponse.self, from: data), response)

        let object = try jsonObject(from: data)
        XCTAssertEqual(object["type"] as? String, "credentialList")
        let credentials = try XCTUnwrap(object["credentials"] as? [[String: Any]])
        XCTAssertEqual(credentials.count, 1)
        XCTAssertEqual(credentials[0]["id"] as? String, "1")
        XCTAssertEqual(credentials[0]["title"] as? String, "Example")
        XCTAssertEqual(credentials[0]["username"] as? String, "alice")
        XCTAssertNil(credentials[0]["password"], "credentialList must never carry a password field")
    }

    func testCredentialRoundTripsWithTotp() throws {
        let response = ExtensionBridgeResponse.credential(username: "alice", password: "s3cret", totp: "JBSWY3DP")
        let data = try JSONEncoder().encode(response)
        XCTAssertEqual(try JSONDecoder().decode(ExtensionBridgeResponse.self, from: data), response)

        let object = try jsonObject(from: data)
        XCTAssertEqual(object["type"] as? String, "credential")
        XCTAssertEqual(object["username"] as? String, "alice")
        XCTAssertEqual(object["password"] as? String, "s3cret")
        XCTAssertEqual(object["totp"] as? String, "JBSWY3DP")
    }

    func testCredentialRoundTripsWithoutTotp() throws {
        let response = ExtensionBridgeResponse.credential(username: "alice", password: "s3cret", totp: nil)
        let data = try JSONEncoder().encode(response)
        XCTAssertEqual(try JSONDecoder().decode(ExtensionBridgeResponse.self, from: data), response)
        XCTAssertNil(try jsonObject(from: data)["totp"])
    }

    func testSaveProposalAcceptedRoundTrips() throws {
        let response = ExtensionBridgeResponse.saveProposalAccepted
        let data = try JSONEncoder().encode(response)
        XCTAssertEqual(try JSONDecoder().decode(ExtensionBridgeResponse.self, from: data), response)
        XCTAssertEqual(try jsonObject(from: data)["type"] as? String, "saveProposalAccepted")
    }

    func testErrorRoundTripsAndHasExpectedShape() throws {
        let response = ExtensionBridgeResponse.error("invalid token")
        let data = try JSONEncoder().encode(response)
        XCTAssertEqual(try JSONDecoder().decode(ExtensionBridgeResponse.self, from: data), response)

        let object = try jsonObject(from: data)
        XCTAssertEqual(object["type"] as? String, "error")
        XCTAssertEqual(object["message"] as? String, "invalid token")
    }

    func testPairingRequiredRoundTrips() throws {
        let response = ExtensionBridgeResponse.pairingRequired
        let data = try JSONEncoder().encode(response)
        XCTAssertEqual(try JSONDecoder().decode(ExtensionBridgeResponse.self, from: data), response)
        XCTAssertEqual(try jsonObject(from: data)["type"] as? String, "pairingRequired")
    }

    func testPairingStartedRoundTrips() throws {
        let response = ExtensionBridgeResponse.pairingStarted
        let data = try JSONEncoder().encode(response)
        XCTAssertEqual(try JSONDecoder().decode(ExtensionBridgeResponse.self, from: data), response)
        XCTAssertEqual(try jsonObject(from: data)["type"] as? String, "pairingStarted")
    }

    func testPairedRoundTripsAndHasExpectedShape() throws {
        let response = ExtensionBridgeResponse.paired(secret: "YWJj")
        let data = try JSONEncoder().encode(response)
        XCTAssertEqual(try JSONDecoder().decode(ExtensionBridgeResponse.self, from: data), response)
        let object = try jsonObject(from: data)
        XCTAssertEqual(object["type"] as? String, "paired")
        XCTAssertEqual(object["secret"] as? String, "YWJj")
    }

    func testInvalidCodeErrorRoundTrips() throws {
        let response = ExtensionBridgeResponse.error("invalid_code")
        let data = try JSONEncoder().encode(response)
        XCTAssertEqual(try JSONDecoder().decode(ExtensionBridgeResponse.self, from: data), response)
        XCTAssertEqual(try jsonObject(from: data)["message"] as? String, "invalid_code")
    }

    // MARK: - Unlock from popup

    func testRequestUnlockRoundTripsAndHasExpectedShape() throws {
        let request = ExtensionBridgeRequest.requestUnlock(token: "tok-9", pairing: "pair-secret")
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(ExtensionBridgeRequest.self, from: data)
        XCTAssertEqual(decoded, request)

        let object = try jsonObject(from: data)
        XCTAssertEqual(object["type"] as? String, "requestUnlock")
        XCTAssertEqual(object["token"] as? String, "tok-9")
        XCTAssertEqual(object["pairing"] as? String, "pair-secret")
    }

    func testRequestUnlockRoundTripsWithoutPairing() throws {
        let request = ExtensionBridgeRequest.requestUnlock(token: "tok-10", pairing: nil)
        let data = try JSONEncoder().encode(request)
        XCTAssertEqual(try JSONDecoder().decode(ExtensionBridgeRequest.self, from: data), request)

        let object = try jsonObject(from: data)
        XCTAssertNil(object["pairing"])
    }

    func testUnlockResponsesRoundTrip() throws {
        for response in [ExtensionBridgeResponse.unlockPresented, .unlockNotNeeded] {
            let data = try JSONEncoder().encode(response)
            XCTAssertEqual(try JSONDecoder().decode(ExtensionBridgeResponse.self, from: data), response)
        }

        let presented = try jsonObject(from: try JSONEncoder().encode(ExtensionBridgeResponse.unlockPresented))
        XCTAssertEqual(presented["type"] as? String, "unlockPresented")
        let notNeeded = try jsonObject(from: try JSONEncoder().encode(ExtensionBridgeResponse.unlockNotNeeded))
        XCTAssertEqual(notNeeded["type"] as? String, "unlockNotNeeded")
    }

    func testOnlyRequestUnlockAndPasskeyProxyStatusAreAnswerableWhileLocked() {
        XCTAssertTrue(ExtensionBridgeRequest.requestUnlock(token: "t", pairing: nil).isAnswerableWhileLocked)
        // `getPasskeyProxyStatus` exists specifically to report lock state, so answering
        // it with a blanket `.locked` would make it useless. It is the second — and only
        // other — exemption, per plan C's Global Constraints.
        XCTAssertTrue(ExtensionBridgeRequest.getPasskeyProxyStatus(token: "t", pairing: nil).isAnswerableWhileLocked)

        let gated: [ExtensionBridgeRequest] = [
            .getCredentials(token: "t", url: "https://example.com", pairing: nil),
            .fillCredential(token: "t", id: "e", url: "https://example.com", pairing: nil),
            .getTotp(token: "t", id: "e", url: "https://example.com", pairing: nil),
            .proposeSaveLogin(token: "t", url: "https://example.com", username: "u", password: "p", pairing: nil),
            .proposeSaveTotp(token: "t", url: "https://example.com", otpauthOrSecret: "secret", entryId: nil, pairing: nil),
            .startPairing(token: "t", browser: nil),
            .completePairing(token: "t", code: "123456"),
            .setPasskeyProxyEnabled(token: "t", enabled: true, pairing: nil),
            .passkeyCreate(token: "t", requestId: 1, requestDetailsJson: "{}", originUrl: "https://example.com", pairing: nil),
            .passkeyCreateConfirm(token: "t", requestId: 1, entryId: nil, replace: false, pairing: nil),
            .passkeyGet(token: "t", requestId: 1, requestDetailsJson: "{}", originUrl: "https://example.com", pairing: nil),
            .passkeyGetApprove(token: "t", requestId: 1, entryId: "e", pairing: nil),
            .passkeyCancel(token: "t", requestId: 1, pairing: nil),
        ]
        for request in gated {
            XCTAssertFalse(request.isAnswerableWhileLocked, "\(request) must stay behind the locked gate")
        }
    }

    func testGetTotpRoundTripsAndHasExpectedShape() throws {
        let request = ExtensionBridgeRequest.getTotp(token: "tok", id: "entry-1", url: "https://example.com", pairing: "pair-secret")
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(ExtensionBridgeRequest.self, from: data)
        XCTAssertEqual(decoded, request)

        let json = try jsonObject(from: data)
        XCTAssertEqual(json["type"] as? String, "getTotp")
        XCTAssertEqual(json["token"] as? String, "tok")
        XCTAssertEqual(json["id"] as? String, "entry-1")
        XCTAssertEqual(json["url"] as? String, "https://example.com")
        XCTAssertEqual(json["pairing"] as? String, "pair-secret")
    }

    func testTotpResponseRoundTripsAndHasExpectedShape() throws {
        let response = ExtensionBridgeResponse.totp(code: "123456")
        let data = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(ExtensionBridgeResponse.self, from: data)
        XCTAssertEqual(decoded, response)

        let json = try jsonObject(from: data)
        XCTAssertEqual(json["type"] as? String, "totp")
        XCTAssertEqual(json["code"] as? String, "123456")
        XCTAssertNil(json["username"])
        XCTAssertNil(json["password"])
    }

    func testCredentialListIncludesHasTotpField() throws {
        let summary = ExtensionCredentialSummary(id: "1", title: "Example", username: "alice", hasTotp: true, hasPasskey: false)
        let response = ExtensionBridgeResponse.credentialList([summary])
        let data = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(ExtensionBridgeResponse.self, from: data)
        XCTAssertEqual(decoded, response)

        let json = try jsonObject(from: data)
        let credentials = try XCTUnwrap(json["credentials"] as? [[String: Any]])
        XCTAssertEqual(credentials.first?["hasTotp"] as? Bool, true)
    }

    func testProposeSaveTotpRoundTripsAndHasExpectedShapeWithEntryId() throws {
        let request = ExtensionBridgeRequest.proposeSaveTotp(
            token: "tok", url: "https://example.com", otpauthOrSecret: "otpauth://totp/Example:alice?secret=JBSWY3DP",
            entryId: "entry-1", pairing: "pair-secret"
        )
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(ExtensionBridgeRequest.self, from: data)
        XCTAssertEqual(decoded, request)

        let json = try jsonObject(from: data)
        XCTAssertEqual(json["type"] as? String, "proposeSaveTotp")
        XCTAssertEqual(json["url"] as? String, "https://example.com")
        XCTAssertEqual(json["otpauthOrSecret"] as? String, "otpauth://totp/Example:alice?secret=JBSWY3DP")
        XCTAssertEqual(json["entryId"] as? String, "entry-1")
        XCTAssertEqual(json["pairing"] as? String, "pair-secret")
    }

    func testProposeSaveTotpRoundTripsWithoutEntryIdOrPairing() throws {
        let request = ExtensionBridgeRequest.proposeSaveTotp(
            token: "tok", url: "https://example.com", otpauthOrSecret: "JBSWY3DPEHPK3PXP", entryId: nil, pairing: nil
        )
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(ExtensionBridgeRequest.self, from: data)
        XCTAssertEqual(decoded, request)

        let json = try jsonObject(from: data)
        XCTAssertNil(json["entryId"])
        XCTAssertNil(json["pairing"])
    }

    // MARK: - Passkeys

    func testGetPasskeyProxyStatusRoundTrips() throws {
        let request = ExtensionBridgeRequest.getPasskeyProxyStatus(token: "tok", pairing: "pair-secret")
        let data = try JSONEncoder().encode(request)
        XCTAssertEqual(try JSONDecoder().decode(ExtensionBridgeRequest.self, from: data), request)
        let json = try jsonObject(from: data)
        XCTAssertEqual(json["type"] as? String, "getPasskeyProxyStatus")
    }

    func testPasskeyProxyStatusResponseRoundTrips() throws {
        let response = ExtensionBridgeResponse.passkeyProxyStatus(unlocked: true, paired: true, attachAllowed: true)
        let data = try JSONEncoder().encode(response)
        XCTAssertEqual(try JSONDecoder().decode(ExtensionBridgeResponse.self, from: data), response)
        let json = try jsonObject(from: data)
        XCTAssertEqual(json["type"] as? String, "passkeyProxyStatus")
        XCTAssertEqual(json["unlocked"] as? Bool, true)
        XCTAssertEqual(json["paired"] as? Bool, true)
        XCTAssertEqual(json["attachAllowed"] as? Bool, true)
    }

    func testSetPasskeyProxyEnabledRoundTrips() throws {
        let request = ExtensionBridgeRequest.setPasskeyProxyEnabled(token: "tok", enabled: true, pairing: "pair-secret")
        let data = try JSONEncoder().encode(request)
        XCTAssertEqual(try JSONDecoder().decode(ExtensionBridgeRequest.self, from: data), request)
        XCTAssertEqual(try jsonObject(from: data)["enabled"] as? Bool, true)

        let response = ExtensionBridgeResponse.passkeyProxyEnabled(enabled: true)
        let responseData = try JSONEncoder().encode(response)
        XCTAssertEqual(try JSONDecoder().decode(ExtensionBridgeResponse.self, from: responseData), response)
    }

    func testPasskeyCreateRoundTripsWithRequestIdAsNumber() throws {
        let request = ExtensionBridgeRequest.passkeyCreate(
            token: "tok", requestId: 42, requestDetailsJson: "{\"challenge\":\"AA\"}",
            originUrl: "https://example.com", pairing: "pair-secret"
        )
        let data = try JSONEncoder().encode(request)
        XCTAssertEqual(try JSONDecoder().decode(ExtensionBridgeRequest.self, from: data), request)
        let json = try jsonObject(from: data)
        XCTAssertEqual(json["requestId"] as? Int, 42, "requestId must serialize as a JSON number, not a string")
        XCTAssertEqual(json["originUrl"] as? String, "https://example.com")
    }

    /// A live capture (spike S3) shows Chrome issuing negative request ids — `-56026996`
    /// and `-913466539` — so the signedness of `Int` here is load-bearing, not incidental.
    func testPasskeyRequestIdRoundTripsWhenNegative() throws {
        let request = ExtensionBridgeRequest.passkeyGet(
            token: "tok", requestId: -913466539, requestDetailsJson: "{}",
            originUrl: "https://example.com", pairing: nil
        )
        let data = try JSONEncoder().encode(request)
        XCTAssertEqual(try JSONDecoder().decode(ExtensionBridgeRequest.self, from: data), request)
        XCTAssertEqual(try jsonObject(from: data)["requestId"] as? Int, -913466539)

        let response = ExtensionBridgeResponse.passkeyCancelled(requestId: -56026996)
        let responseData = try JSONEncoder().encode(response)
        XCTAssertEqual(try JSONDecoder().decode(ExtensionBridgeResponse.self, from: responseData), response)
        XCTAssertEqual(try jsonObject(from: responseData)["requestId"] as? Int, -56026996)
    }

    func testPasskeyCreateConfirmRoundTripsWithAndWithoutEntryId() throws {
        let withEntry = ExtensionBridgeRequest.passkeyCreateConfirm(
            token: "tok", requestId: 1, entryId: "entry-1", replace: true, pairing: "p"
        )
        let dataWithEntry = try JSONEncoder().encode(withEntry)
        XCTAssertEqual(try JSONDecoder().decode(ExtensionBridgeRequest.self, from: dataWithEntry), withEntry)
        XCTAssertEqual(try jsonObject(from: dataWithEntry)["replace"] as? Bool, true)

        let withoutEntry = ExtensionBridgeRequest.passkeyCreateConfirm(
            token: "tok", requestId: 1, entryId: nil, replace: false, pairing: "p"
        )
        let dataWithoutEntry = try JSONEncoder().encode(withoutEntry)
        XCTAssertEqual(try JSONDecoder().decode(ExtensionBridgeRequest.self, from: dataWithoutEntry), withoutEntry)
        XCTAssertNil(try jsonObject(from: dataWithoutEntry)["entryId"])
    }

    func testPasskeyGetAndGetApproveRoundTrip() throws {
        let get = ExtensionBridgeRequest.passkeyGet(
            token: "tok", requestId: 7, requestDetailsJson: "{}", originUrl: "https://example.com", pairing: "p"
        )
        XCTAssertEqual(try JSONDecoder().decode(ExtensionBridgeRequest.self, from: try JSONEncoder().encode(get)), get)

        let approve = ExtensionBridgeRequest.passkeyGetApprove(token: "tok", requestId: 7, entryId: "entry-1", pairing: "p")
        XCTAssertEqual(try JSONDecoder().decode(ExtensionBridgeRequest.self, from: try JSONEncoder().encode(approve)), approve)
    }

    func testPasskeyCancelRoundTripsAndCancelledResponseRoundTrips() throws {
        let request = ExtensionBridgeRequest.passkeyCancel(token: "tok", requestId: 3, pairing: "p")
        XCTAssertEqual(try JSONDecoder().decode(ExtensionBridgeRequest.self, from: try JSONEncoder().encode(request)), request)

        let response = ExtensionBridgeResponse.passkeyCancelled(requestId: 3)
        let data = try JSONEncoder().encode(response)
        XCTAssertEqual(try JSONDecoder().decode(ExtensionBridgeResponse.self, from: data), response)
        let json = try jsonObject(from: data)
        XCTAssertEqual(json["type"] as? String, "passkeyCancelled")
        XCTAssertEqual(json["requestId"] as? Int, 3)
    }

    func testPasskeyCreatePendingIncludesMatchesWithHasPasskey() throws {
        let summary = ExtensionCredentialSummary(id: "1", title: "Example", username: "alice", hasTotp: false, hasPasskey: true)
        let response = ExtensionBridgeResponse.passkeyCreatePending(
            requestId: 1, rpId: "example.com", rpName: "Example", matches: [summary]
        )
        let data = try JSONEncoder().encode(response)
        XCTAssertEqual(try JSONDecoder().decode(ExtensionBridgeResponse.self, from: data), response)
        let json = try jsonObject(from: data)
        XCTAssertEqual(json["rpName"] as? String, "Example")
        let matches = try XCTUnwrap(json["matches"] as? [[String: Any]])
        XCTAssertEqual(matches.first?["hasPasskey"] as? Bool, true)
    }

    func testPasskeyCreateCompleteRoundTripsWithResponseJsonOrError() throws {
        let success = ExtensionBridgeResponse.passkeyCreateComplete(requestId: 1, responseJson: "{\"id\":\"abc\"}", error: nil)
        XCTAssertEqual(try JSONDecoder().decode(ExtensionBridgeResponse.self, from: try JSONEncoder().encode(success)), success)

        let failure = ExtensionBridgeResponse.passkeyCreateComplete(
            requestId: 1, responseJson: nil,
            error: PasskeyErrorDetails(name: "NotSupportedError", message: "MyPass passkeys require ES256")
        )
        let failureData = try JSONEncoder().encode(failure)
        XCTAssertEqual(try JSONDecoder().decode(ExtensionBridgeResponse.self, from: failureData), failure)
        let json = try jsonObject(from: failureData)
        XCTAssertNil(json["responseJson"])
        let error = try XCTUnwrap(json["error"] as? [String: Any])
        XCTAssertEqual(error["name"] as? String, "NotSupportedError")
        XCTAssertEqual(error["message"] as? String, "MyPass passkeys require ES256")
    }

    func testPasskeyGetPendingAndCompleteRoundTrip() throws {
        let pending = ExtensionBridgeResponse.passkeyGetPending(requestId: 2, rpId: "example.com", matches: [])
        XCTAssertEqual(try JSONDecoder().decode(ExtensionBridgeResponse.self, from: try JSONEncoder().encode(pending)), pending)

        let complete = ExtensionBridgeResponse.passkeyGetComplete(requestId: 2, responseJson: "{\"id\":\"abc\"}", error: nil)
        XCTAssertEqual(try JSONDecoder().decode(ExtensionBridgeResponse.self, from: try JSONEncoder().encode(complete)), complete)
    }

    /// The whole point of the two-phase design: no private-key material has a wire
    /// representation at all. `PasskeyErrorDetails` mirrors Chrome's `DOMExceptionDetails`.
    func testPasskeyResponsesCarryNoPrivateKeyField() throws {
        let complete = ExtensionBridgeResponse.passkeyGetComplete(requestId: 2, responseJson: "{\"id\":\"abc\"}", error: nil)
        let json = try jsonObject(from: try JSONEncoder().encode(complete))
        XCTAssertNil(json["privateKeyPEM"])
        XCTAssertNil(json["pem"])
    }
}
