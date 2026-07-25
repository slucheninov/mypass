import SwiftUI
import AppKit
import MyPassKit
import SyncKit

enum SyncBackendOption: String, CaseIterable, Identifiable {
    case local = "Локальный файл"
    case iCloud = "iCloud Drive"
    case sftp = "SFTP"

    var id: String { rawValue }

    // .local and .iCloud are wired in Phase 3 Task 12. .sftp is wired in
    // Task 13. The picker below persists the user's choice to UserDefaults
    // regardless of availability so a preference recorded before a backend
    // was wired is still there once it is.
    var isAvailable: Bool {
        switch self {
        case .local, .iCloud: return true
        case .sftp: return false
        }
    }
}

struct SettingsView: View {
    @AppStorage("autoLockTimeoutMinutes") private var autoLockTimeoutMinutes: Double = 15
    @AppStorage("backupCount") private var backupCount: Int = 10
    @AppStorage("syncBackend") private var syncBackendRawValue: String = SyncBackendOption.local.rawValue

    // Non-secret Local-folder bookmark data — @AppStorage supports `Data?`
    // directly (one of AppStorage's natively-supported property list types
    // alongside Bool/Int/Double/String/URL), so no base64/string bridging is
    // needed here, unlike the SFTP secrets in Task 13 which deliberately
    // avoid @AppStorage/UserDefaults entirely and go to Keychain instead.
    @AppStorage("syncLocalFolderBookmark") private var syncLocalFolderBookmarkData: Data?

    @State private var iCloudContainerAvailable: Bool = true
    @State private var iCloudContainerCheckMessage: String?
    @State private var manualSyncStatusMessage: String?

    // Bridges the persisted timeout to the live, running AutoLockController (Task 5) so that
    // changing the stepper actually affects autolock behavior in this session, and so a value
    // persisted in a previous session is restored into the controller on next launch too —
    // otherwise UserDefaults would hold a value the running controller never reads.
    @EnvironmentObject private var autoLockController: AutoLockController
    @EnvironmentObject private var vaultSession: VaultSession

    private var selectedOption: SyncBackendOption {
        SyncBackendOption(rawValue: syncBackendRawValue) ?? .local
    }

    var body: some View {
        Form {
            Section("Автоблокировка") {
                Stepper("Таймаут: \(Int(autoLockTimeoutMinutes)) мин", value: $autoLockTimeoutMinutes, in: 1...120)
            }
            Section("Резервные копии") {
                Stepper("Хранить последних: \(backupCount)", value: $backupCount, in: 1...50)
            }
            Section("Синхронизация") {
                Picker("Бэкенд", selection: $syncBackendRawValue) {
                    ForEach(SyncBackendOption.allCases) { option in
                        Text(option.isAvailable ? option.rawValue : "\(option.rawValue) (скоро)")
                            .tag(option.rawValue)
                    }
                }

                switch selectedOption {
                case .local:
                    localFolderSection
                case .iCloud:
                    iCloudSection
                case .sftp:
                    Text("SFTP появится в следующей задаче Фазы 3.")
                        .foregroundStyle(.secondary)
                }

                Button("Синхронизировать сейчас") {
                    vaultSession.triggerBackgroundSync()
                    manualSyncStatusMessage = "Запущено…"
                }
                if let manualSyncStatusMessage {
                    Text(manualSyncStatusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .frame(width: 360)
        .onAppear {
            // Restore a persisted value into the live controller at view-appear time — covers
            // the case where a timeout was changed in a previous session but the controller
            // (constructed once in MyPassApp.init with a hardcoded default) never saw it.
            autoLockController.timeout = autoLockTimeoutMinutes * 60
            refreshICloudStatus()
        }
        .onChange(of: autoLockTimeoutMinutes) { _, newValue in
            autoLockController.timeout = newValue * 60
        }
        .onChange(of: syncBackendRawValue) { _, _ in
            refreshICloudStatus()
        }
    }

    private var localFolderSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let bookmarkData = syncLocalFolderBookmarkData, !bookmarkData.isEmpty,
               let backend = SyncBackendResolver.resolveLocalFolderBackend(bookmarkData: bookmarkData) {
                Text("Папка выбрана.")
                    .foregroundStyle(.secondary)
                    .task { _ = backend } // keeps `backend` from being flagged unused; construction itself already validates the bookmark
            } else {
                Text("Папка не выбрана.")
                    .foregroundStyle(.secondary)
            }
            Button("Выбрать папку…") {
                let panel = NSOpenPanel()
                panel.canChooseFiles = false
                panel.canChooseDirectories = true
                panel.allowsMultipleSelection = false
                if panel.runModal() == .OK, let folderURL = panel.url {
                    syncLocalFolderBookmarkData = try? LocalFolderBackend.createBookmark(for: folderURL)
                }
            }
        }
    }

    private var iCloudSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            if iCloudContainerAvailable {
                Text("Контейнер iCloud доступен.")
                    .foregroundStyle(.secondary)
            } else {
                Text(iCloudContainerCheckMessage ?? "iCloud Drive недоступен — войдите в iCloud и включите iCloud Drive в Системных настройках.")
                    .foregroundStyle(.orange)
            }
        }
    }

    private func refreshICloudStatus() {
        guard selectedOption == .iCloud else { return }
        do {
            _ = try iCloudBackend(relativePath: "vault.kdbx")
            iCloudContainerAvailable = true
            iCloudContainerCheckMessage = nil
        } catch iCloudBackendError.containerUnavailable {
            iCloudContainerAvailable = false
            iCloudContainerCheckMessage = "iCloud Drive недоступен — войдите в iCloud и включите iCloud Drive в Системных настройках."
        } catch {
            iCloudContainerAvailable = false
            iCloudContainerCheckMessage = "Не удалось проверить контейнер iCloud: \(error)"
        }
    }
}
