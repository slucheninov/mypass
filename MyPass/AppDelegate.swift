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
    static var extensionPairingStoreModel: ExtensionPairingStoreModel?
    static var extensionPairingManager: ExtensionPairingManager?

    /// The single-instance election, kept alive for the whole process: it owns
    /// the instance lock descriptor and the takeover listener that lets a newer
    /// MyPass ask this one to quit. `nil` in hosted test runs and previews,
    /// which never take part in the election at all.
    static var singleInstance: SingleInstanceCoordinator?

    /// The session whose queued writes must reach disk before the process exits.
    static var vaultSession: VaultSession?

    private lazy var quitFlushCoordinator = QuitFlushCoordinator(
        session: Self.vaultSession,
        prompter: AppKitQuitPrompter()
    )

    /// The live delegate, so code outside the AppKit callbacks can ask whether a quit is
    /// already being flushed. Main thread only; `nil` before the app has started.
    private static weak var current: AppDelegate?

    override init() {
        super.init()
        Self.current = self
    }

    /// The only way anything outside `applicationShouldTerminate` may ask the app to quit
    /// (menu bar Quit row, the single-instance takeover request). A second `NSApp.terminate`
    /// while a save-flush is pending (`terminateLater`) is NOT routed to
    /// `applicationShouldTerminate` again: AppKit terminates at once and the flush is lost, so
    /// the duplicate request is dropped here instead. Returns whether `terminate` ran. Main
    /// thread only.
    @discardableResult
    static func requestTermination(_ terminate: () -> Void = { NSApp.terminate(nil) }) -> Bool {
        guard let delegate = current else {
            terminate()
            return true
        }
        return delegate.quitFlushCoordinator.requestTermination(terminate)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // A hosted test run or preview must stay inert: it owns no election
        // state and no production vault queue worth waiting for.
        if AppRuntimeEnvironment.isTestOrPreviewHost { return .terminateNow }
        switch quitFlushCoordinator.begin(reply: { [weak sender] shouldTerminate in
            if !shouldTerminate { Self.singleInstance?.quitWasCancelled() }
            sender?.reply(toApplicationShouldTerminate: shouldTerminate)
        }) {
        case .terminateNow: return .terminateNow
        case .terminateLater: return .terminateLater
        // Not reachable through `requestTermination`, and AppKit does not call the delegate for a
        // duplicate `NSApp.terminate` anyway; cancelling is the safe answer if it ever does (a
        // reply of `terminateNow` would skip the flush, a second `terminateLater` would need a
        // second reply).
        case .alreadyInFlight: return .terminateCancel
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Removes the browser discovery record, but only if it is still ours.
        Self.extensionBridgeServer?.shutdown()
    }
}
