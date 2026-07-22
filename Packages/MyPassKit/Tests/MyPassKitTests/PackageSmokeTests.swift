import XCTest
import Sodium
@testable import MyPassKit

final class PackageSmokeTests: XCTestCase {
    func testSodiumIsLinkedAndUsable() {
        let sodium = Sodium()
        let bytes = sodium.randomBytes.buf(length: 16)
        XCTAssertNotNil(bytes)
        XCTAssertEqual(bytes?.count, 16)
    }

    func testMyPassKitVersionConstantExists() {
        XCTAssertEqual(MyPassKitVersion, "0.1.0")
    }
}
