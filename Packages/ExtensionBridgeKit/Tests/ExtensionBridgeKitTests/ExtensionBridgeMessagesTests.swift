import XCTest
@testable import ExtensionBridgeKit

final class ExtensionBridgeMessagesTests: XCTestCase {
    private func jsonObject(from data: Data) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - Requests

    func testGetCredentialsRoundTripsAndHasExpectedShape() throws {
        let request = ExtensionBridgeRequest.getCredentials(token: "tok-1", url: "https://example.com")
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(ExtensionBridgeRequest.self, from: data)
        XCTAssertEqual(decoded, request)

        let object = try jsonObject(from: data)
        XCTAssertEqual(object["type"] as? String, "getCredentials")
        XCTAssertEqual(object["token"] as? String, "tok-1")
        XCTAssertEqual(object["url"] as? String, "https://example.com")
    }

    func testFillCredentialRoundTripsAndHasExpectedShape() throws {
        let request = ExtensionBridgeRequest.fillCredential(token: "tok-2", id: "entry-1", url: "https://example.com/login")
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
            token: "tok-3", url: "https://example.com/signup", username: "alice", password: "s3cret"
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

    // MARK: - Responses

    func testLockedRoundTripsAndHasExpectedShape() throws {
        let response = ExtensionBridgeResponse.locked
        let data = try JSONEncoder().encode(response)
        XCTAssertEqual(try JSONDecoder().decode(ExtensionBridgeResponse.self, from: data), response)
        XCTAssertEqual(try jsonObject(from: data)["type"] as? String, "locked")
    }

    func testCredentialListRoundTripsAndNeverIncludesAPasswordKey() throws {
        let response = ExtensionBridgeResponse.credentialList([
            ExtensionCredentialSummary(id: "1", title: "Example", username: "alice")
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
}
