import XCTest
@testable import MyPass

final class AppRuntimeEnvironmentTests: XCTestCase {
    func testNormalLaunchUsesProductionStartup() {
        XCTAssertFalse(AppRuntimeEnvironment.isTestOrPreview(environment: [:], hasXCTestRuntime: false))
    }

    func testHostedTestsAreIsolatedBeforeXCTestRuntimeLoads() {
        for key in ["XCTestConfigurationFilePath", "XCTestBundlePath"] {
            XCTAssertTrue(AppRuntimeEnvironment.isTestOrPreview(
                environment: [key: "/test-host"], hasXCTestRuntime: false
            ))
        }
    }

    func testLoadedXCTestRuntimeIsIsolatedWithoutEnvironmentMarker() {
        XCTAssertTrue(AppRuntimeEnvironment.isTestOrPreview(environment: [:], hasXCTestRuntime: true))
    }

    func testPreviewsAreIsolated() {
        XCTAssertTrue(AppRuntimeEnvironment.isTestOrPreview(
            environment: ["XCODE_RUNNING_FOR_PREVIEWS": "1"], hasXCTestRuntime: false
        ))
        XCTAssertFalse(AppRuntimeEnvironment.isTestOrPreview(
            environment: ["XCODE_RUNNING_FOR_PREVIEWS": "0"], hasXCTestRuntime: false
        ))
    }

    func testActualHostedAppDidNotStartProductionBridge() {
        // This assertion runs in the app process that Xcode launched. A pure
        // policy test alone cannot catch a guard wired too late in App.init.
        XCTAssertTrue(AppRuntimeEnvironment.isTestOrPreviewHost)
        XCTAssertNil(AppDelegate.extensionBridgeServer)
    }
}
