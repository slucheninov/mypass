import LocalAuthentication
import XCTest
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

    func testEachAccessControlMapsToExpectedLAPolicy() {
        XCTAssertEqual(
            DeviceUnlockAccessControl.touchID.laPolicy,
            .deviceOwnerAuthenticationWithBiometrics
        )
        XCTAssertEqual(
            DeviceUnlockAccessControl.devicePassword.laPolicy,
            .deviceOwnerAuthentication
        )
        XCTAssertEqual(
            DeviceUnlockAccessControl.touchIDOrDevicePassword.laPolicy,
            .deviceOwnerAuthentication
        )
    }
}
