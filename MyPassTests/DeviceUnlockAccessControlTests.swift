import XCTest
import Security
@testable import MyPass

final class DeviceUnlockAccessControlTests: XCTestCase {
    func testForTogglesMapsCombinationsCorrectly() {
        XCTAssertEqual(
            DeviceUnlockAccessControl.forToggles(touchIDEnabled: true, macPasswordEnabled: false),
            .touchID
        )
        XCTAssertEqual(
            DeviceUnlockAccessControl.forToggles(touchIDEnabled: false, macPasswordEnabled: true),
            .devicePassword
        )
        XCTAssertEqual(
            DeviceUnlockAccessControl.forToggles(touchIDEnabled: true, macPasswordEnabled: true),
            .touchIDOrDevicePassword
        )
        XCTAssertNil(
            DeviceUnlockAccessControl.forToggles(touchIDEnabled: false, macPasswordEnabled: false)
        )
    }

    func testEachAccessControlProducesAValidSecAccessControl() {
        for accessControl in [DeviceUnlockAccessControl.touchID, .devicePassword, .touchIDOrDevicePassword] {
            let secAccessControl = SecAccessControlCreateWithFlags(
                nil,
                kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                accessControl.secAccessControlFlags,
                nil
            )
            XCTAssertNotNil(secAccessControl, "Expected a valid SecAccessControl for \(accessControl)")
        }
    }
}
