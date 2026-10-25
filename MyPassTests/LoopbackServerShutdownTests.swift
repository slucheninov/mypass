import XCTest
import ExtensionBridgeKit
@testable import MyPass

final class LoopbackServerShutdownTests: XCTestCase {
    func testShutdownRetiresItsOwnDiscoveryRecord() throws {
        let store = InMemoryExtensionBridgeTokenStore()
        let server = LoopbackServer(tokenStore: store) { _ in .error("unused") }
        try server.start()
        XCTAssertNotNil(try store.load())
        server.shutdown()
        XCTAssertNil(try store.load())
    }

    func testShutdownLeavesAnotherInstancesRecordAlone() throws {
        let store = InMemoryExtensionBridgeTokenStore()
        let server = LoopbackServer(tokenStore: store) { _ in .error("unused") }
        try server.start()
        // A newer MyPass took over and published its own endpoint meanwhile.
        let theirs = ExtensionBridgeEndpoint(port: 1, token: "newer-instance-token")
        try store.save(theirs)
        server.shutdown()
        XCTAssertEqual(try store.load(), theirs)
    }

    func testSamePortWithADifferentTokenIsNotOurs() throws {
        let store = InMemoryExtensionBridgeTokenStore()
        let server = LoopbackServer(tokenStore: store) { _ in .error("unused") }
        try server.start()
        let port = try XCTUnwrap(server.port)
        let theirs = ExtensionBridgeEndpoint(port: port, token: "someone-else")
        try store.save(theirs)
        server.shutdown()
        XCTAssertEqual(try store.load(), theirs)
    }

    func testShutdownWithoutStartAndRepeatedShutdownAreSafe() throws {
        let store = InMemoryExtensionBridgeTokenStore()
        let kept = ExtensionBridgeEndpoint(port: 9, token: "kept")
        try store.save(kept)
        let never = LoopbackServer(tokenStore: store) { _ in .error("unused") }
        never.shutdown()
        XCTAssertEqual(try store.load(), kept)

        let server = LoopbackServer(tokenStore: store) { _ in .error("unused") }
        try server.start()
        server.shutdown()
        server.shutdown()
        XCTAssertNil(try store.load())
    }
}
