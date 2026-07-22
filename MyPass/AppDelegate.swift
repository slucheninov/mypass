import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Retains the local NSEvent monitor installed in `MyPassApp.init()` so it keeps
    /// firing for the lifetime of the app. `AppDelegate` is a class (unlike the `App`
    /// struct), so it's a natural place to hold this token.
    static var activityMonitorToken: Any?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
