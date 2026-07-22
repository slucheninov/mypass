import SwiftUI
import MyPassKit

@main
struct MyPassApp: App {
    /// Default inactivity timeout before the vault auto-locks, per the design spec (15 minutes).
    private static let defaultAutoLockTimeout: TimeInterval = 900

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @StateObject private var vaultSession: VaultSession
    @StateObject private var navigationState: NavigationState
    @StateObject private var autoLockController: AutoLockController

    init() {
        let session = VaultSession(
            fileStore: VaultFileStore(
                directory: FileManager.default
                    .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("MyPass")
            )
        )
        _vaultSession = StateObject(wrappedValue: session)
        _navigationState = StateObject(wrappedValue: NavigationState())
        _autoLockController = StateObject(wrappedValue: AutoLockController(
            vaultSession: session,
            clock: RealAutoLockClock(),
            sleepObserver: NSWorkspaceSleepObserver(),
            timeout: Self.defaultAutoLockTimeout
        ))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(vaultSession)
                .environmentObject(navigationState)
        }

        MenuBarExtra("MyPass", systemImage: "key.fill") {
            MenuBarExtraContent()
                .environmentObject(vaultSession)
                .environmentObject(navigationState)
        }
    }
}
