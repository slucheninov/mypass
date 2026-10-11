import XCTest
@testable import ExtensionBridgeKit

final class ExtensionAddressTests: XCTestCase {
    func testFillAddressRequestRoundTripsAndRequiresUnlockedDeliberateActivity() throws {
        let request = ExtensionBridgeRequest.fillAddress(token: "launch", id: "address-id", url: "https://shop.example/checkout", pairing: "paired")
        let encoded = try JSONEncoder().encode(request)
        XCTAssertEqual(try JSONDecoder().decode(ExtensionBridgeRequest.self, from: encoded), request)
        XCTAssertFalse(request.isAnswerableWhileLocked)
        XCTAssertTrue(request.resetsAutoLockTimer)
    }

    func testAddressResponseWireShapeAndRoundTrip() throws {
        let address = ExtensionAddress(id: "address-id", label: "Home", fullName: "Ada Example",
            addressLine1: "12 Example Street", city: "Warsaw", countryCode: "PL", countryName: "Poland")
        let response = ExtensionBridgeResponse.address(address)
        let encoded = try JSONEncoder().encode(response)
        XCTAssertEqual(try JSONDecoder().decode(ExtensionBridgeResponse.self, from: encoded), response)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(json["type"] as? String, "address")
        let payload = try XCTUnwrap(json["address"] as? [String: String])
        XCTAssertEqual(payload["countryCode"], "PL")
        XCTAssertEqual(payload["givenName"], "")
        XCTAssertEqual(payload["email"], "")
        XCTAssertEqual(payload.count, 15)
    }
}
