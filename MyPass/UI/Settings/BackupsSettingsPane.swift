import SwiftUI
import AppKit

/// Cached snapshot of the backup folder for the Settings pane. The filesystem is read here, on
/// appear and after a `vaultBackupsDidChange` notification, never from a view `body`.
@MainActor
final class BackupsSummaryModel: ObservableObject {
    @Published private(set) var backups: [VaultBackupInfo] = []
    @Published private(set) var lastFailure: VaultBackupFailure?
    @Published private(set) var directory: URL?

    func refresh(from manager: VaultBackupManager?) {
        directory = manager?.directory
        backups = manager?.list() ?? []
        lastFailure = manager?.lastFailure
    }

    var totalSize: Int64 { backups.reduce(0) { $0 + $1.size } }
}

/// The "Backups" section of the Vault pane. It is a section hosted by `VaultSettingsPane`, which
/// supplies the single grouped `Form` (and its scrolling) around it, not a pane of its own.
struct BackupsSettingsPane: View {
    @EnvironmentObject private var vaultSession: VaultSession
    @AppStorage(VaultBackupSettings.countKey) private var backupCount: Int = VaultBackupSettings.defaultCount
    @AppStorage(VaultBackupSettings.intervalKey) private var intervalRaw: String = VaultBackupInterval.default.rawValue
    @StateObject private var model = BackupsSummaryModel()
    @State private var pendingRestore: VaultBackupInfo?
    @State private var restoreError: String?

    var body: some View {
        Group {
            Section {
                Stepper("Keep last: \(backupCount)", value: $backupCount, in: VaultBackupSettings.countRange)
                Picker("Frequency", selection: $intervalRaw) {
                    ForEach(VaultBackupInterval.allCases) { interval in
                        Text(Self.title(for: interval)).tag(interval.rawValue)
                    }
                }
                SettingsHelperText(text: "Rotate local backup copies of the vault file so you can recover from a corrupted save. The first save after unlocking always makes a backup.")
            } header: {
                Text("Backups")
                    .font(.system(size: 13, weight: .semibold))
            }

            Section {
                if let failure = model.lastFailure {
                    Text("Last backup failed: \(failure.message) (\(failure.date.formatted(date: .abbreviated, time: .shortened)))")
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                }
                LabeledContent("Folder") {
                    Text(model.directory?.path ?? "–")
                        .font(.system(size: 12))
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                LabeledContent("Backups", value: String(model.backups.count))
                LabeledContent("Latest backup") {
                    if let newest = model.backups.first {
                        Text(newest.date.formatted(date: .abbreviated, time: .standard))
                    } else {
                        Text("None yet")
                    }
                }
                LabeledContent("Total size", value: ByteCountFormatter.string(fromByteCount: model.totalSize, countStyle: .file))
                Button("Show in Finder") { showInFinder() }
                    .disabled(model.directory == nil)
            }

            if !model.backups.isEmpty {
                Section {
                    ForEach(model.backups) { backup in
                        HStack {
                            Text(backup.date.formatted(date: .abbreviated, time: .standard))
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: backup.size, countStyle: .file))
                                .foregroundStyle(.secondary)
                            Button("Restore…") { pendingRestore = backup }
                        }
                    }
                } header: {
                    Text("Available backups")
                        .font(.system(size: 13, weight: .semibold))
                }
            }
        }
        .onAppear { model.refresh(from: vaultSession.backupManager) }
        .onReceive(NotificationCenter.default.publisher(for: .vaultBackupsDidChange)) { _ in
            model.refresh(from: vaultSession.backupManager)
        }
        .alert(
            "Restore this backup?",
            isPresented: Binding(get: { pendingRestore != nil }, set: { if !$0 { pendingRestore = nil } }),
            presenting: pendingRestore
        ) { backup in
            Button("Restore", role: .destructive) { restore(backup) }
            Button("Cancel", role: .cancel) {}
        } message: { backup in
            Text(Self.restoreMessage(date: backup.date, hasSecondary: vaultSession.hasSecondaryDestination))
        }
        .alert(
            "Restore Failed",
            isPresented: Binding(get: { restoreError != nil }, set: { if !$0 { restoreError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(restoreError ?? "")
        }
    }

    private func showInFinder() {
        guard let directory = model.directory else { return }
        // The folder may not exist before the first backup; reveal the newest file when there
        // is one, otherwise open the parent so the button still does something useful.
        if let newest = model.backups.first {
            NSWorkspace.shared.activateFileViewerSelecting([newest.url])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([directory.deletingLastPathComponent()])
        }
    }

    private func restore(_ backup: VaultBackupInfo) {
        do {
            try vaultSession.restoreBackup(from: backup.url)
        } catch VaultSessionError.writeInProgress {
            restoreError = String(localized: "A save is still in progress. Try again in a moment.", comment: "Backup restore error")
        } catch VaultSessionError.invalidBackup {
            restoreError = String(localized: "The selected file is not a valid vault.", comment: "Backup restore error")
        } catch {
            restoreError = String(localized: "The backup could not be restored: \(error.localizedDescription)", comment: "Backup restore error; the argument is the underlying reason")
        }
        model.refresh(from: vaultSession.backupManager)
    }

    static func title(for interval: VaultBackupInterval) -> LocalizedStringKey {
        switch interval {
        case .everySave: return "Every save"
        case .tenMinutes: return "At most every 10 minutes"
        case .hourly: return "Hourly"
        case .daily: return "Daily"
        }
    }

    static func restoreMessage(date: Date, hasSecondary: Bool) -> String {
        let when = date.formatted(date: .abbreviated, time: .standard)
        var text = String(
            localized: "The vault will be replaced with the backup from \(when) and locked. The current vault is saved as a new backup first, so you can undo this. Unlock with the master password the backup was created with, which may be an older one.",
            comment: "Backup restore confirmation; the argument is the backup date"
        )
        if hasSecondary {
            text += "\n\n" + String(
                localized: "Sync is on: the sync destination is not rolled back, so the next sync may merge newer entries from it back into the restored vault.",
                comment: "Backup restore confirmation warning when a sync destination is configured"
            )
        }
        return text
    }
}
