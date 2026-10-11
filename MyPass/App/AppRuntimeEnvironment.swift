import Foundation

/// Hosted XCTest runs execute MyPassApp.init in a second signed MyPass process.
/// That process must not publish a browser endpoint: its discovery record
/// outlives the test process and
/// would redirect ChromeHost away from the real, still-running app.
enum AppRuntimeEnvironment {
    static let isTestOrPreviewHost = isTestOrPreview(
        environment: ProcessInfo.processInfo.environment,
        hasXCTestRuntime: NSClassFromString("XCTestCase") != nil
    )

    static func isTestOrPreview(environment: [String: String], hasXCTestRuntime: Bool) -> Bool {
        hasXCTestRuntime
            || environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
    }
}
