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
            return .credentialList([ExtensionCredentialSummary(id: "1", title: "Test", username: "u", hasTotp: false)])
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
                let request = ExtensionBridgeRequest.getCredentials(token: endpoint.token, url: "https://example.com", pairing: nil)
                let payload = try! JSONEncoder().encode(request)
                connection.send(content: NativeMessagingCodec.encode(payload), completion: .contentProcessed { _ in })
            }
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
            guard let data else { return }
            guard let frames = try? reader.feed(data) else { return }
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
            .credentialList([ExtensionCredentialSummary(id: "1", title: "Test", username: "u", hasTotp: false)])
        )
    }

    func testServerRejectsInvalidToken() throws {
        let tokenStore = InMemoryExtensionBridgeTokenStore()
        let server = LoopbackServer(tokenStore: tokenStore) { _ in
            .credentialList([ExtensionCredentialSummary(id: "1", title: "Should not be reached", username: "u", hasTotp: false)])
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
                let request = ExtensionBridgeRequest.getCredentials(token: "wrong-token", url: "https://example.com", pairing: nil)
                let payload = try! JSONEncoder().encode(request)
                connection.send(content: NativeMessagingCodec.encode(payload), completion: .contentProcessed { _ in })
            }
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
            guard let data else { return }
            guard let frames = try? reader.feed(data) else { return }
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

    // NOTE on interface restriction (loopback-only bind): `start()` builds its
    // `NWListener` with `parameters.requiredInterfaceType = .loopback`, which
    // is what confines the socket to 127.0.0.1/::1 instead of the wildcard
    // address. This is deliberately NOT re-verified by a same-machine test
    // here: connecting via `NWConnection(host: "127.0.0.1", ...)` from this
    // test process succeeds identically whether the listener is bound
    // loopback-only or to all interfaces (the loopback path is reachable
    // either way), so no assertion made from localhost can distinguish the
    // two. Network.framework does not expose the bound listener's
    // `NWParameters`/interface restriction back out in a way this test could
    // inspect. Confidence here rests on code inspection of `start()`
    // (`requiredInterfaceType = .loopback` is set before the listener is
    // constructed) rather than an automated assertion — flagging this
    // explicitly rather than claiming coverage the test suite doesn't have.

    func testServerRejectsConnectionsBeyondMaxConcurrentConnections() throws {
        let tokenStore = InMemoryExtensionBridgeTokenStore()
        let server = LoopbackServer(
            tokenStore: tokenStore,
            handler: { _ in .credentialList([]) },
            maxConcurrentConnections: 1
        )
        try server.start()
        defer { server.stop() }
        guard let port = server.port else { return XCTFail("server did not report a port") }

        // Open and hold the first connection (never closed during the test)
        // to occupy the single connection slot the server is capped at.
        let holderReady = expectation(description: "first connection ready")
        let holderConnection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        holderConnection.stateUpdateHandler = { state in
            if state == .ready { holderReady.fulfill() }
        }
        holderConnection.start(queue: .main)
        wait(for: [holderReady], timeout: 5)

        // A second connection arrives once the server is already at its cap;
        // `accept` should cancel it immediately (before calling `start()` on
        // it), which the client observes as the connection closing without
        // ever receiving data.
        let rejected = expectation(description: "second connection closed by server without data")
        let rejectedConnection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        rejectedConnection.stateUpdateHandler = { _ in }
        rejectedConnection.start(queue: .main)
        rejectedConnection.receive(minimumIncompleteLength: 1, maximumLength: 1) { data, _, isComplete, error in
            if (data == nil || data!.isEmpty) && (isComplete || error != nil) {
                rejected.fulfill()
            }
        }

        wait(for: [rejected], timeout: 5)
        holderConnection.cancel()
        rejectedConnection.cancel()
    }

    func testServerClosesConnectionAndRespondsErrorWhenClaimedFrameLengthExceedsCap() throws {
        let tokenStore = InMemoryExtensionBridgeTokenStore()
        let server = LoopbackServer(tokenStore: tokenStore) { _ in
            .credentialList([ExtensionCredentialSummary(id: "1", title: "Should not be reached", username: "u", hasTotp: false)])
        }
        try server.start()
        defer { server.stop() }
        guard let port = server.port else { return XCTFail("server did not report a port") }

        let expectation = expectation(description: "error response received for oversized frame")
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let reader = NativeMessagingFrameReader()
        var receivedResponse: ExtensionBridgeResponse?

        connection.stateUpdateHandler = { state in
            if state == .ready {
                // Claim a frame far larger than NativeMessagingFrameReader's
                // default cap (10 MB), but never actually send that many
                // bytes -- the server must reject based on the claimed
                // length alone, without waiting for (or buffering toward)
                // the full claimed payload.
                var oversizedLength = UInt32(200_000_000).littleEndian
                let header = Data(bytes: &oversizedLength, count: 4)
                connection.send(content: header, completion: .contentProcessed { _ in })
            }
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
            guard let data else { return }
            guard let frames = try? reader.feed(data) else { return }
            if let frame = frames.first, let response = try? JSONDecoder().decode(ExtensionBridgeResponse.self, from: frame) {
                receivedResponse = response
                expectation.fulfill()
            }
        }
        connection.start(queue: .main)

        wait(for: [expectation], timeout: 5)
        connection.cancel()
        XCTAssertEqual(receivedResponse, .error("frame too large"))
    }
}
