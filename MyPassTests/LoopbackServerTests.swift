import XCTest
import Network
import ExtensionBridgeKit
@testable import MyPass

final class LoopbackServerTests: XCTestCase {
    func testIsValidTokenMatchesExactString() {
        XCTAssertTrue(LoopbackServer.isValidToken("abc", expected: "abc"))
    }

    func testIsValidTokenRejectsMismatch() {
        XCTAssertFalse(LoopbackServer.isValidToken("abc", expected: "xyz"))
    }

    func testIsValidTokenRejectsEmptyCandidate() {
        XCTAssertFalse(LoopbackServer.isValidToken("", expected: "abc"))
    }

    func testServerRoundTripsAValidGetCredentialsRequest() throws {
        let tokenStore = InMemoryExtensionBridgeTokenStore()
        let server = LoopbackServer(tokenStore: tokenStore) { request in
            guard case .getCredentials = request else { return .error("unexpected") }
            return .credentialList([ExtensionCredentialSummary(id: "1", title: "Test", username: "u")])
        }
        try server.start()
        defer { server.stop() }

        guard let port = server.port, let endpoint = try tokenStore.load() else {
            return XCTFail("server did not persist an endpoint after start()")
        }
        XCTAssertEqual(endpoint.port, port)

        let expectation = expectation(description: "response received")
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let reader = NativeMessagingFrameReader()
        var receivedResponse: ExtensionBridgeResponse?

        connection.stateUpdateHandler = { state in
            if state == .ready {
                let request = ExtensionBridgeRequest.getCredentials(token: endpoint.token, url: "https://example.com")
                let payload = try! JSONEncoder().encode(request)
                connection.send(content: NativeMessagingCodec.encode(payload), completion: .contentProcessed { _ in })
            }
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
            guard let data else { return }
            let frames = reader.feed(data)
            if let frame = frames.first, let response = try? JSONDecoder().decode(ExtensionBridgeResponse.self, from: frame) {
                receivedResponse = response
                expectation.fulfill()
            }
        }
        connection.start(queue: .main)

        wait(for: [expectation], timeout: 5)
        connection.cancel()
        XCTAssertEqual(
            receivedResponse,
            .credentialList([ExtensionCredentialSummary(id: "1", title: "Test", username: "u")])
        )
    }

    func testServerRejectsInvalidToken() throws {
        let tokenStore = InMemoryExtensionBridgeTokenStore()
        let server = LoopbackServer(tokenStore: tokenStore) { _ in
            .credentialList([ExtensionCredentialSummary(id: "1", title: "Should not be reached", username: "u")])
        }
        try server.start()
        defer { server.stop() }
        guard let port = server.port else { return XCTFail("server did not report a port") }

        let expectation = expectation(description: "error response received")
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let reader = NativeMessagingFrameReader()
        var receivedResponse: ExtensionBridgeResponse?

        connection.stateUpdateHandler = { state in
            if state == .ready {
                let request = ExtensionBridgeRequest.getCredentials(token: "wrong-token", url: "https://example.com")
                let payload = try! JSONEncoder().encode(request)
                connection.send(content: NativeMessagingCodec.encode(payload), completion: .contentProcessed { _ in })
            }
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
            guard let data else { return }
            let frames = reader.feed(data)
            if let frame = frames.first, let response = try? JSONDecoder().decode(ExtensionBridgeResponse.self, from: frame) {
                receivedResponse = response
                expectation.fulfill()
            }
        }
        connection.start(queue: .main)

        wait(for: [expectation], timeout: 5)
        connection.cancel()
        XCTAssertEqual(receivedResponse, .error("invalid token"))
    }
}
