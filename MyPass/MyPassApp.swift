import SwiftUI
import AppKit
import MyPassKit
import SyncKit
import ExtensionBridgeKit
import os.log

@main
struct MyPassApp: App {
    /// Default inactivity timeout before the vault auto-locks, per the design spec (15 minutes).
    private static let defaultAutoLockTimeout: TimeInterval = 900

    /// Design spec's sync cycle triggers "on open, after save" are
    /// wired directly inside `VaultSession` (Task 7). This interval covers
    /// the remaining "on a timer" trigger.
    private static let backgroundSyncInterval: TimeInterval = 300

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @AppStorage("showMenuBarExtra") private var showMenuBarExtra = true

    @StateObject private var vaultSession: VaultSession
    @StateObject private var navigationState: NavigationState
    @StateObject private var autoLockController: AutoLockController

    init() {
        let defaults = UserDefaults.standard
        let syncBackendOption = SyncBackendOption(rawValue: defaults.string(forKey: "syncBackend") ?? "") ?? .local

        var localFolderURLForWatcher: URL?
        let syncEngine: SyncEngine? = {
            guard syncBackendOption.isAvailable else { return nil }

            let backend: StorageBackend?
            switch syncBackendOption {
            case .local:
                let bookmarkData = defaults.data(forKey: "syncLocalFolderBookmark")
                backend = SyncBackendResolver.resolveLocalFolderBackend(bookmarkData: bookmarkData)
                if let bookmarkData, !bookmarkData.isEmpty {
                    var isStale = false
                    localFolderURLForWatcher = try? URL(
                        resolvingBookmarkData: bookmarkData,
                        options: .withSecurityScope,
                        relativeTo: nil,
                        bookmarkDataIsStale: &isStale
                    )
                    if isStale { localFolderURLForWatcher = nil }
                }
            case .iCloud:
                backend = SyncBackendResolver.resolveICloudBackend()
            case .sftp:
                let host = defaults.string(forKey: "syncSFTPHost") ?? ""
                let port = defaults.object(forKey: "syncSFTPPort") as? Int ?? 22
                let remotePath = defaults.string(forKey: "syncSFTPRemotePath") ?? "/upload/vault.kdbx"
                guard !host.isEmpty,
                      let credentials = try? CredentialKeychainStore().loadCredentials(forHost: host) else {
                    backend = nil
                    break
                }
                let configuration = SyncBackendResolver.buildSFTPConfiguration(
                    host: host,
                    port: port,
                    username: defaults.string(forKey: "syncSFTPUsername") ?? "",
                    remotePath: remotePath,
                    credentials: credentials
                )
                backend = configuration.map {
                    SFTPBackend(configuration: $0, trustedHostKeyStore: UserDefaultsTrustedHostKeyStore())
                }
            }

            guard let backend else { return nil }
            let checkpointStore = UserDefaultsSyncCheckpointStore(
                key: "com.mypass.sync.checkpoint.\(syncBackendOption.rawValue)"
            )
            return SyncEngine(remote: backend, checkpointStore: checkpointStore)
        }()

        let session = VaultSession(
            fileStore: VaultFileStore(
                directory: FileManager.default
                    .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("MyPass")
            ),
            syncEngine: syncEngine
        )
        _vaultSession = StateObject(wrappedValue: session)

        let pairingStore = KeychainExtensionPairingStore()
        let pairingStoreModel = ExtensionPairingStoreModel(store: pairingStore)
        let pairingManager = ExtensionPairingManager(store: pairingStore)
        AppDelegate.extensionPairingStore = pairingStore
        AppDelegate.extensionPairingStoreModel = pairingStoreModel
        AppDelegate.extensionPairingManager = pairingManager
        let extensionBridgeService = ExtensionBridgeService(
            vaultSession: session,
            pairingManager: pairingManager
        )
        let extensionBridgeServer = LoopbackServer(
            tokenStore: ExtensionBridgeTokenStore(),
            handler: extensionBridgeService.handle
        )
        do {
            try extensionBridgeServer.start()
        } catch {
            os_log(
                "ExtensionBridgeServer failed to start: %{public}@",
                log: OSLog(subsystem: "com.mypass.app", category: "ExtensionBridge"),
                type: .error,
                String(describing: error)
            )
        }
        AppDelegate.extensionBridgeServer = extensionBridgeServer

        let navigationState = NavigationState()
        _navigationState = StateObject(wrappedValue: navigationState)

        pairingManager.onCodeGenerated = { [weak navigationState] code in
            DispatchQueue.main.async {
                navigationState?.pendingPairingCode = code
                MainWindowActivator.request()
            }
        }
        pairingManager.onPairingFinished = { [weak navigationState] in
            DispatchQueue.main.async {
                navigationState?.pendingPairingCode = nil
            }
        }

        // Phase 4, Task 13: real UI for ExtensionBridgeService.onSaveProposal (Task 5's
        // extension point). The dispatch to main is technically redundant here since
        // LoopbackServer (Task 6) already dispatches onto the main thread before
        // invoking the handler that eventually calls this closure — but the window
        // activation calls below specifically need to run after SwiftUI has had a
        // chance to process the `@Published pendingSaveProposal` change (so the sheet
        // exists before we bring the window forward), so the async hop stays as
        // defense-in-depth rather than being removed.
        extensionBridgeService.onSaveProposal = { [weak navigationState] url, username, password in
            DispatchQueue.main.async {
                navigationState?.pendingSaveProposal = PendingSaveProposal(url: url, username: username, password: password)
                MainWindowActivator.request()
            }
        }

        let controller = AutoLockController(
            vaultSession: session,
            clock: RealAutoLockClock(),
            sleepObserver: NSWorkspaceSleepObserver(),
            timeout: Self.defaultAutoLockTimeout
        )
        _autoLockController = StateObject(wrappedValue: controller)

        // Reset the auto-lock timer on real user input so the vault locks after a
        // period of inactivity, not simply `timeout` seconds after launch.
        AppDelegate.activityMonitorToken = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel]
        ) { event in
            controller.recordActivity()
            return event
        }

        // Design spec sync trigger "on a timer".
        AppDelegate.backgroundSyncTimer = Timer.scheduledTimer(
            withTimeInterval: Self.backgroundSyncInterval,
            repeats: true
        ) { [weak session] _ in
            session?.triggerBackgroundSync()
        }

        // Design spec's Local-folder backend requirement "FSEvents for
        // external changes" — closes the forward reference Task 3 left
        // open ("Consumed by ... app-level auto-sync trigger").
        if syncBackendOption == .local, let folderURL = localFolderURLForWatcher {
            let watcher = LocalFolderChangeWatcher(folderURL: folderURL) { [weak session] in
                session?.triggerBackgroundSync()
            }
            watcher.start()
            AppDelegate.localFolderChangeWatcher = watcher
        }
    }

    var body: some Scene {
        mainWindow
        menuBarExtraScene
        settingsWindow
    }

    @SceneBuilder
    private var mainWindow: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environmentObject(vaultSession)
                .environmentObject(navigationState)
                .environmentObject(autoLockController)
                .background(SettingsHotkeyObserver())
                .background(OpenMainWindowOnDemand())
        }
    }

    @SceneBuilder
    private var menuBarExtraScene: some Scene {
        MenuBarExtra("MyPass", systemImage: "key.fill", isInserted: $showMenuBarExtra) {
            MenuBarExtraContent()
                .environmentObject(vaultSession)
                .environmentObject(navigationState)
                .background(OpenMainWindowOnDemand())
        }
        .menuBarExtraStyle(.window)
    }

    @SceneBuilder
    private var settingsWindow: some Scene {
        Settings {
            SettingsView()
                .environmentObject(autoLockController)
                .environmentObject(vaultSession)
        }
    }
}

private struct SettingsHotkeyObserver: View {
    @AppStorage("shortcutShowMyPass") private var shortcutShowMyPass = ""
    @AppStorage("shortcutLockMyPass") private var shortcutLockMyPass = "shift+command+L"
    @EnvironmentObject private var vaultSession: VaultSession

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear { reloadGlobalHotkeys() }
            .onChange(of: shortcutShowMyPass) { _, _ in reloadGlobalHotkeys() }
            .onChange(of: shortcutLockMyPass) { _, _ in reloadGlobalHotkeys() }
    }

    private func reloadGlobalHotkeys() {
        GlobalHotkeyManager.shared.reload(
            showMyPassStorage: shortcutShowMyPass,
            lockMyPassStorage: shortcutLockMyPass,
            showHandler: {
                MainWindowActivator.request()
            },
            lockHandler: {
                if case .unlocked = vaultSession.state {
                    vaultSession.lock()
                }
            }
        )
    }
}
