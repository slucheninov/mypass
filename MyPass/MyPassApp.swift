import SwiftUI
import AppKit
import MyPassKit
import SyncKit
import ExtensionBridgeKit

@main
struct MyPassApp: App {
    /// Default inactivity timeout before the vault auto-locks, per the design spec (15 minutes).
    private static let defaultAutoLockTimeout: TimeInterval = 900

    /// Design spec's sync cycle triggers "при открытии, после сохранения" are
    /// wired directly inside `VaultSession` (Task 7). This interval covers
    /// the remaining "по таймеру" trigger.
    private static let backgroundSyncInterval: TimeInterval = 300

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

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

        let extensionBridgeService = ExtensionBridgeService(vaultSession: session)
        let extensionBridgeServer = LoopbackServer(
            tokenStore: ExtensionBridgeTokenStore(),
            handler: extensionBridgeService.handle
        )
        try? extensionBridgeServer.start()
        AppDelegate.extensionBridgeServer = extensionBridgeServer

        NativeMessagingHostInstaller.installIfNeeded(
            hostBinaryPath: NativeMessagingHostInstaller.debugChromeHostBinaryPath,
            extensionID: NativeMessagingHostInstaller.developmentPlaceholderExtensionID
        )
        _navigationState = StateObject(wrappedValue: NavigationState())

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

        // Design spec sync trigger "по таймеру".
        AppDelegate.backgroundSyncTimer = Timer.scheduledTimer(
            withTimeInterval: Self.backgroundSyncInterval,
            repeats: true
        ) { [weak session] _ in
            session?.triggerBackgroundSync()
        }

        // Design spec's Local-folder backend requirement "FSEvents для
        // внешних изменений" — closes the forward reference Task 3 left
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
        WindowGroup {
            ContentView()
                .environmentObject(vaultSession)
                .environmentObject(navigationState)
                .environmentObject(autoLockController)
        }

        MenuBarExtra("MyPass", systemImage: "key.fill") {
            MenuBarExtraContent()
                .environmentObject(vaultSession)
                .environmentObject(navigationState)
        }

        Settings {
            SettingsView()
                .environmentObject(autoLockController)
                .environmentObject(vaultSession)
        }
    }
}
