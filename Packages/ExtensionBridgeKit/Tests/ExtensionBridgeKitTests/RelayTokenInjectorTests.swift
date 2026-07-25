import XCTest
@testable import ExtensionBridgeKit

final class RelayTokenInjectorTests: XCTestCase {
    func testInjectTokenAddsTokenFieldToExistingObject() throws {
        let requestJSON = Data("{\"type\":\"getCredentials\",\"url\":\"https://example.com\"}".utf8)
        let result = try RelayTokenInjector.injectToken(into: requestJSON, token: "tok-abc")
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: result) as? [String: Any])
        XCTAssertEqual(object["token"] as? String, "tok-abc")
        XCTAssertEqual(object["type"] as? String, "getCredentials")
        XCTAssertEqual(object["url"] as? String, "https://example.com")
    }

    func testInjectTokenOverwritesExistingTokenField() throws {
        let requestJSON = Data("{\"type\":\"getCredentials\",\"token\":\"old\",\"url\":\"https://example.com\"}".utf8)
        let result = try RelayTokenInjector.injectToken(into: requestJSON, token: "new-token")
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: result) as? [String: Any])
        XCTAssertEqual(object["token"] as? String, "new-token")
    }

    func testInjectTokenThrowsOnMalformedJSON() {
        let malformed = Data("not json".utf8)
        XCTAssertThrowsError(try RelayTokenInjector.injectToken(into: malformed, token: "t"))
    }

    func testInjectTokenThrowsOnNonObjectJSON() {
        let arrayJSON = Data("[1,2,3]".utf8)
        XCTAssertThrowsError(try RelayTokenInjector.injectToken(into: arrayJSON, token: "t"))
    }
}
