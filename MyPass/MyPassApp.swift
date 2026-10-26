import SwiftUI
import AppKit
import MyPassKit
import SyncKit
import ExtensionBridgeKit
import os.log

/// Started by `AppLauncher` (the process entry point) only after this process
/// has won the single-instance election; hosted tests and previews start it
/// directly without taking part in the election.
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
    @StateObject private var deviceUnlockPromptCoordinator: DeviceUnlockPromptCoordinator
    @StateObject private var updateChecker: AppUpdateChecker

    init() {
        let defaults = UserDefaults.standard
        let autoLockIdleTimeout = AutoLockIdleTimeout(rawValue: defaults.string(forKey: "autoLockIdleTimeout") ?? "") ?? .thirtyMinutes
        let lockOnDeviceSleepEnabled = defaults.object(forKey: "lockOnDeviceSleepEnabled") as? Bool ?? true

        let applicationSupportDirectory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MyPass")

        if defaults.string(forKey: "vaultLocation") == nil {
            let legacySyncBackendRawValue = defaults.string(forKey: "syncBackend")
            var legacyICloudFolderBookmark: Data?
            var localVaultModificationDate: Date?
            var iCloudVaultModificationDate: Date?
            if legacySyncBackendRawValue == "iCloud Drive" {
                // Only worth the filesystem/coordinated-read cost when we're
                // actually about to decide between promoting iCloud to
                // primary or keeping Local — every other legacy value, and
                // every normal launch after migration has already run once,
                // skips this entirely.
                localVaultModificationDate = try? VaultFileStore(directory: applicationSupportDirectory).modificationDate()
                let bookmark = defaults.data(forKey: SyncBackendResolver.iCloudFolderBookmarkKey)
                legacyICloudFolderBookmark = bookmark
                if let bookmark, !bookmark.isEmpty,
                   let backend = try? iCloudBackend(root: .userFolder(bookmark: bookmark), relativePath: "vault.kdbx") {
                    iCloudVaultModificationDate = try? backend.modificationDate()
                }
            }
            if let migration = VaultLocationResolver.migrateLegacyBackendIfNeeded(
                legacySyncBackendRawValue: legacySyncBackendRawValue,
                legacyLocalFolderBookmark: defaults.data(forKey: "syncLocalFolderBookmark"),
                legacyICloudFolderBookmark: legacyICloudFolderBookmark,
                localVaultModificationDate: localVaultModificationDate,
                iCloudVaultModificationDate: iCloudVaultModificationDate
            ) {
                defaults.set(migration.vaultLocation.rawValue, forKey: "vaultLocation")
                if let secondaryDestination = migration.secondaryDestination {
                    defaults.set(secondaryDestination.rawValue, forKey: "secondaryDestination")
                }
                if let bookmark = migration.secondaryFolderBookmark {
                    defaults.set(bookmark, forKey: "secondaryFolderBookmark")
                }
            }
        }

        let vaultLocation = VaultLocationResolver.resolveVaultLocation(rawValue: defaults.string(forKey: "vaultLocation"))
        let resolution = VaultPrimaryStoreResolver.resolvePrimaryStore(
            vaultLocation: vaultLocation,
            applicationSupportDirectory: applicationSupportDirectory,
            iCloudBookmarkData: defaults.data(forKey: SyncBackendResolver.iCloudFolderBookmarkKey),
            localVaultFileBookmarkData: defaults.data(forKey: SyncBackendResolver.localVaultFileBookmarkKey),
            makeICloudStore: { bookmarkData in
                try? ICloudDriveVaultStore(
                    bookmarkData: bookmarkData,
                    localBackupDirectory: applicationSupportDirectory.appendingPathComponent("backups")
                )
            },
            makeLocalFileStore: { bookmarkData in
                try? LocalFileVaultStore(
                    bookmarkData: bookmarkData,
                    localBackupDirectory: applicationSupportDirectory.appendingPathComponent("backups")
                )
            }
        )
        let primaryStore = resolution.primaryStore

        let secondaryDestination = SecondaryDestinationOption(rawValue: defaults.string(forKey: "secondaryDestination") ?? "") ?? .none

        var localFolderURLForWatcher: URL?
        let syncEngine: SyncEngine? = {
            let backend: StorageBackend?
            switch secondaryDestination {
            case .none:
                return nil
            case .folder:
                let bookmarkData = defaults.data(forKey: "secondaryFolderBookmark")
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
                key: SyncBackendResolver.checkpointKey(for: secondaryDestination)
            )
            return SyncEngine(remote: backend, checkpointStore: checkpointStore)
        }()

        let session = VaultSession(
            fileStore: primaryStore,
            syncEngine: syncEngine,
            iCloudPrimaryFallbackActive: resolution.iCloudFallbackToLocal,
            localFileFallbackActive: resolution.localFileFallbackActive
        )
        _vaultSession = StateObject(wrappedValue: session)
        AppDelegate.vaultSession = session
        // Shared across `UnlockView`, `MenuBarUnlockPanelView`, and the extension's
        // `.requestDeviceUnlockPrompt` notification — deliberately one instance, not
        // per-view @State, so no surface can start a second device-unlock prompt while
        // another one is already in flight or already auto-fired this locked session.
        _deviceUnlockPromptCoordinator = StateObject(wrappedValue: DeviceUnlockPromptCoordinator(vaultSession: session))

        // Design spec's external-change handling (reload-and-merge when
        // another device/process touches the same iCloud Drive file) is wired
        // centrally by `VaultSession` itself — on `init` above and on every
        // later `updatePrimaryStore` swap (see `VaultSession.swift`), so an
        // in-session switch to iCloud from `VaultLocationChangeSheet` keeps it
        // working without this call site having to remember to re-wire it.

        // Created here, ahead of `ExtensionBridgeService`, purely so the service can
        // be handed a reference at init (mirroring how it already receives
        // `vaultSession`/`pairingManager`) instead of a settable-after-the-fact
        // singleton. See the `resetsAutoLockTimer` reset below for why this exists:
        // a user working entirely in the browser extension never triggers the
        // in-app key/mouse monitor that otherwise keeps this timer alive.
        let controller = AutoLockController(
            vaultSession: session,
            clock: RealAutoLockClock(),
            sleepObserver: NSWorkspaceSleepObserver(),
            timeout: autoLockIdleTimeout.seconds,
            lockOnSleepEnabled: lockOnDeviceSleepEnabled
        )
        _autoLockController = StateObject(wrappedValue: controller)

        let pairingStore = KeychainExtensionPairingStore()
        let pairingStoreModel = ExtensionPairingStoreModel(store: pairingStore)
        let pairingManager = ExtensionPairingManager(store: pairingStore)
        AppDelegate.extensionPairingStore = pairingStore
        AppDelegate.extensionPairingStoreModel = pairingStoreModel
        AppDelegate.extensionPairingManager = pairingManager
        let extensionBridgeService = ExtensionBridgeService(
            vaultSession: session,
            pairingManager: pairingManager,
            autoLockActivityRecorder: controller
        )
        // Hosted XCTest runs launch a second MyPass process. Publishing its
        // endpoint overwrites the running app's discovery record, leaving Chrome
        // pointed at a dead listener after the tests exit. Previews must likewise
        // never advertise themselves as the user's browser bridge.
        if !AppRuntimeEnvironment.isTestOrPreviewHost {
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
        }

        let navigationState = NavigationState()
        _navigationState = StateObject(wrappedValue: navigationState)

        pairingManager.onCodeGenerated = { [weak navigationState] code in
            DispatchQueue.main.async {
                navigationState?.pendingPairingCode = code
                // The code is an OUT-OF-BAND confirmation: the user must read it from the
                // app to prove they control an unlocked vault. It must never be sent to
                // the extension, so the window has to come forward or the code is
                // unreadable. Activation was removed in 95ea2a9 because it closed the
                // popup — harmless now, since the popup reopens straight onto the code
                // field while the challenge is fresh (`isPairingChallengeFresh`).
                MainWindowActivator.request()
                // Requested here, at app level, NOT from ContentView. ContentView is the
                // content of the very WindowGroup this needs to affect: with the main
                // window closed it does not exist, so its .onChange never ran and the
                // level was never even requested. Opening the window afterwards does not
                // help either — .onChange only fires for changes made after the view
                // exists, and the code was set before that.
                MainWindowActivator.setMainWindowFloating(true)
            }
        }
        pairingManager.onPairingFinished = { [weak navigationState] in
            DispatchQueue.main.async {
                navigationState?.pendingPairingCode = nil
                MainWindowActivator.setMainWindowFloating(false)
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
        extensionBridgeService.onBrowserSettingsRequested = {
            DispatchQueue.main.async { BrowserSettingsActivator.request() }
        }
        extensionBridgeService.onSaveProposal = { [weak navigationState] url, username, password in
            DispatchQueue.main.async {
                navigationState?.pendingSaveProposal = PendingSaveProposal(url: url, username: username, password: password)
                MainWindowActivator.request()
            }
        }
        extensionBridgeService.onTotpSaveProposal = { [weak navigationState] url, otpauthOrSecret, entryId in
            DispatchQueue.main.async {
                navigationState?.pendingTotpSaveProposal = PendingTotpSaveProposal(url: url, otpauthOrSecret: otpauthOrSecret, entryId: entryId)
                MainWindowActivator.request()
            }
        }

        // Stage 3 (U5): the popup's Unlock button. Activation alone is not enough —
        // if the window was already open on the unlock screen, `UnlockView.onAppear`
        // will not re-fire, so the Touch ID prompt has to be requested explicitly.
        //
        // When the window was closed instead, `MainWindowActivator.request()` opens it
        // asynchronously and `UnlockView.onAppear` runs its own auto-prompt; this
        // notification arrives before any observer exists and is harmlessly dropped, so
        // exactly one prompt is shown in both paths.
        extensionBridgeService.onUnlockRequested = {
            DispatchQueue.main.async {
                MainWindowActivator.request()
                NotificationCenter.default.post(name: .requestDeviceUnlockPrompt, object: nil)
            }
        }
        extensionBridgeService.onOpenAppRequested = {
            DispatchQueue.main.async {
                MainWindowActivator.request()
            }
        }

        // Best-effort cleanup of the pre-2026-07-28 Touch ID enrollment, which stored a
        // derived key under a fixed "master" account. Safe to call even if nothing is stored.
        try? BiometricKeyStore().remove(account: "master")

        // `controller` was created and assigned to `_autoLockController` above,
        // ahead of `ExtensionBridgeService`, so the service could receive it at init.
        //
        // Falls back to `defaultAutoLockTimeout` / `true` only on a true first-ever
        // launch, i.e. when the "autoLockIdleTimeout" AppStorage key isn't set yet or
        // fails to parse; `AutoLockIdleTimeout.thirtyMinutes` above already covers that
        // case for the timeout itself, so this constant is now unused for that purpose
        // and kept only as a documented fallback value.

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
            session?.triggerBackgroundSyncIfDirty()
        }

        // Update check: a banner-only notice that a newer GitHub release exists.
        let bundleVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
            .flatMap(SemanticVersion.init(string:))
        let updateChecker = MainActor.assumeIsolated {
            AppUpdateChecker(
                feed: GitHubReleaseClient(currentVersion: bundleVersion?.description ?? "unknown"),
                currentVersion: bundleVersion,
                defaults: .standard
            )
        }
        _updateChecker = StateObject(wrappedValue: updateChecker)
        AppDelegate.updateChecker = updateChecker
        // Hosted XCTest runs execute this init too; they must never reach api.github.com.
        if !AppRuntimeEnvironment.isTestOrPreviewHost {
            MainActor.assumeIsolated { updateChecker.startScheduling() }
        }

        // Design spec's Local-folder backend requirement "FSEvents for
        // external changes" — closes the forward reference Task 3 left
        // open ("Consumed by ... app-level auto-sync trigger").
        if secondaryDestination == .folder, let folderURL = localFolderURLForWatcher {
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
                .quitFreezeOverlay()
                .environmentObject(updateChecker)
                .environmentObject(vaultSession)
                .environmentObject(navigationState)
                .environmentObject(autoLockController)
                .environmentObject(deviceUnlockPromptCoordinator)
                .background(SettingsHotkeyObserver())
                .background(OpenMainWindowOnDemand())
                .background(OpenBrowserSettingsOnDemand())
        }
        .commands {
            // Replaces the standard Quit item (and Cmd-Q) so the keyboard path goes through the
            // same guard as the menu bar row: a second `NSApp.terminate` during the quit-time
            // save-flush would exit before the flush completes. The first press still reaches
            // `applicationShouldTerminate` through `NSApp.terminate`, unchanged.
            CommandGroup(replacing: .appTermination) {
                Button("Quit MyPass") { AppDelegate.requestTermination() }
                    .keyboardShortcut("q")
            }
            // The activator is used instead of `SettingsLink` because Commands cannot capture
            // `openSettings`, and the activator also opens the main window first when no scene
            // has registered the action yet.
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    BrowserSettingsActivator.request(pane: .general)
                    Task { await updateChecker.check(manual: true) }
                }
            }
        }
    }

    @SceneBuilder
    private var menuBarExtraScene: some Scene {
        MenuBarExtra("MyPass", systemImage: "key.fill", isInserted: $showMenuBarExtra) {
            MenuBarExtraContent()
                .quitFreezeOverlay()
                .environmentObject(updateChecker)
                .environmentObject(vaultSession)
                .environmentObject(navigationState)
                .environmentObject(deviceUnlockPromptCoordinator)
                .background(OpenMainWindowOnDemand())
                .background(OpenBrowserSettingsOnDemand())
        }
        .menuBarExtraStyle(.window)
    }

    @SceneBuilder
    private var settingsWindow: some Scene {
        Settings {
            SettingsView()
                .quitFreezeOverlay()
                .environmentObject(updateChecker)
                .background(OpenBrowserSettingsOnDemand())
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
