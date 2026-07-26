import AppKit
import SyncKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Retains the local NSEvent monitor installed in `MyPassApp.init()` so it keeps
    /// firing for the lifetime of the app. `AppDelegate` is a class (unlike the `App`
    /// struct), so it's a natural place to hold this token.
    static var activityMonitorToken: Any?

    /// Retains the periodic background-sync `Timer` installed in
    /// `MyPassApp.init()` (Phase 3, Task 12) for the lifetime of the app.
    static var backgroundSyncTimer: Timer?

    /// Retains the `LocalFolderChangeWatcher` installed in `MyPassApp.init()`
    /// (Phase 3, Task 12) when the Local-folder backend is active, for the
    /// lifetime of the app.
    static var localFolderChangeWatcher: LocalFolderChangeWatcher?

    /// Phase 4: retains the loopback server that bridges MyPass.app to ChromeHost
    /// for the lifetime of the app.
    static var extensionBridgeServer: LoopbackServer?

    /// Retains the extension pairing store and manager for the lifetime of the app.
    static var extensionPairingStore: KeychainExtensionPairingStore?
    static var extensionPairingManager: ExtensionPairingManager?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
