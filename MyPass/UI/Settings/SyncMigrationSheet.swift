import SwiftUI
import AppKit
import MyPassKit
import SyncKit

/// First-connect flow for the iCloud Drive backend: pick a folder inside
/// iCloud Drive, see whether it already holds a vault, choose how to
/// reconcile, run the migration, restart. Kept out of `SyncSettingsPane`,
/// which already carries three backends' worth of configuration.
struct SyncMigrationSheet: View {
    @EnvironmentObject private var vaultSession: VaultSession
    @Environment(\.dismiss) private var dismiss
    @AppStorage("syncICloudFolderBookmark") private var syncICloudFolderBookmarkData: Data?

    @State private var step: Step = .chooseFolder
    @State private var chosenFolderURL: URL?
    @State private var chosenFolderBookmark: Data?
    @State private var outsideICloudDriveWarning: String?
    @State private var probe: VaultMigrationTargetProbe?
    @State private var strategy: VaultMigrationStrategy = .merge
    @State private var errorMessage: String?
    @State private var successMessage: String?

    private enum Step: Equatable {
        case chooseFolder
        case probing
        case confirmStrategy
        case migrating
        case finished
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Set Up iCloud Sync")
                .font(.headline)

            content

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            footer
        }
        .padding(20)
        .frame(width: 460)
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .chooseFolder:
            VStack(alignment: .leading, spacing: 8) {
                Text("MyPass mirrors its encrypted vault into a folder inside your iCloud Drive. iCloud syncs that folder between your Macs, and no Apple Developer account is needed.")
                    .fixedSize(horizontal: false, vertical: true)
                if let chosenFolderURL {
                    Text(chosenFolderURL.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                if let outsideICloudDriveWarning {
                    Text(outsideICloudDriveWarning)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

        case .probing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking the folder…")
            }

        case .confirmStrategy:
            strategyChooser

        case .migrating:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Migrating. This can take a while — the vault key is re-derived for every copy.")
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .finished:
            VStack(alignment: .leading, spacing: 8) {
                Label(successMessage ?? "Done.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Quit and reopen MyPass to start syncing: the sync backend is created when the app launches.")
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var strategyChooser: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let probe, probe.exists {
                Text("That folder already contains a vault\(Self.describe(probe)). Choose what to do with it.")
                    .fixedSize(horizontal: false, vertical: true)
                Picker("", selection: $strategy) {
                    ForEach([VaultMigrationStrategy.merge, .adoptRemote, .overwriteRemote]) { option in
                        Text(Self.title(for: option)).tag(option)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                Text(Self.explanation(for: strategy))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("That folder has no vault yet. MyPass will upload the vault from this Mac. Nothing on this Mac changes.")
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack {
            Spacer()
            switch step {
            case .chooseFolder:
                Button("Cancel") { dismiss() }
                Button(chosenFolderURL == nil ? "Choose Folder…" : "Choose Another Folder…") { chooseFolder() }
                if chosenFolderBookmark != nil {
                    Button("Continue") { startProbe() }
                        .keyboardShortcut(.defaultAction)
                }
            case .probing, .migrating:
                Button("Cancel") { dismiss() }
                    .disabled(true)
            case .confirmStrategy:
                Button("Back") {
                    errorMessage = nil
                    step = .chooseFolder
                }
                Button("Migrate") { startMigration() }
                    .keyboardShortcut(.defaultAction)
            case .finished:
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: - Actions

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        panel.message = "Choose a folder inside iCloud Drive for the MyPass vault."
        panel.directoryURL = ICloudDriveLocation.iCloudDriveRootURL

        guard panel.runModal() == .OK, let folderURL = panel.url else { return }

        errorMessage = nil
        chosenFolderURL = folderURL
        outsideICloudDriveWarning = ICloudDriveLocation.isInsideICloudDrive(folderURL)
            ? nil
            : "This folder is not inside iCloud Drive, so iCloud will not sync it. MyPass will still mirror the vault there."
        do {
            chosenFolderBookmark = try iCloudBackend.createFolderBookmark(for: folderURL)
        } catch {
            chosenFolderBookmark = nil
            errorMessage = "MyPass could not keep access to that folder: \(error)"
        }
    }

    private func startProbe() {
        guard let backend = makeBackend() else { return }
        errorMessage = nil
        step = .probing
        vaultSession.probeMigrationTarget(remote: backend) { result in
            switch result {
            case .success(let probe):
                self.probe = probe
                self.strategy = probe.exists ? .merge : .seedRemote
                self.step = .confirmStrategy
            case .failure(let error):
                self.handle(error)
            }
        }
    }

    private func startMigration() {
        guard let backend = makeBackend() else { return }
        errorMessage = nil
        step = .migrating
        vaultSession.performMigration(to: backend, strategy: strategy) { result in
            switch result {
            case .success(let outcome):
                // The bookmark is only persisted once a migration actually
                // succeeded, so a failed attempt never leaves the app pointing
                // at a folder it could not use.
                self.syncICloudFolderBookmarkData = self.chosenFolderBookmark
                // A checkpoint left over from an earlier iCloud folder would
                // make the first sync after restart skip the merge.
                SyncBackendResolver.clearCheckpoint(for: .iCloud)
                self.successMessage = Self.successMessage(for: outcome)
                self.step = .finished
            case .failure(let error):
                self.handle(error)
            }
        }
    }

    private func makeBackend() -> iCloudBackend? {
        guard let chosenFolderBookmark else {
            errorMessage = "Choose a folder first."
            return nil
        }
        do {
            return try iCloudBackend(root: .userFolder(bookmark: chosenFolderBookmark), relativePath: "vault.kdbx")
        } catch {
            handle(error)
            return nil
        }
    }

    private func handle(_ error: Error) {
        if let backendError = error as? iCloudBackendError,
           backendError == .folderBookmarkUnresolvable || backendError == .folderUnavailable {
            syncICloudFolderBookmarkData = nil
            chosenFolderBookmark = nil
            chosenFolderURL = nil
        }
        errorMessage = Self.message(for: error)
        step = .chooseFolder
    }

    // MARK: - Copy

    static func describe(_ probe: VaultMigrationTargetProbe) -> String {
        var parts: [String] = []
        if let byteCount = probe.byteCount {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file))
        }
        if let modificationDate = probe.modificationDate {
            parts.append("modified \(modificationDate.formatted(date: .abbreviated, time: .shortened))")
        }
        return parts.isEmpty ? "" : " (\(parts.joined(separator: ", ")))"
    }

    static func title(for strategy: VaultMigrationStrategy) -> String {
        switch strategy {
        case .seedRemote: return "Upload the vault from this Mac"
        case .merge: return "Merge both vaults (recommended)"
        case .adoptRemote: return "Use the vault from the folder"
        case .overwriteRemote: return "Replace the vault in the folder"
        }
    }

    static func explanation(for strategy: VaultMigrationStrategy) -> String {
        switch strategy {
        case .seedRemote:
            return "The folder has no vault yet, so the vault from this Mac is uploaded unchanged."
        case .merge:
            return "Keeps every entry from both sides, using the same merge rules as normal syncing. Both copies end up identical."
        case .adoptRemote:
            return "Replaces this Mac's vault with the one in the folder. The current local vault is snapshotted into the backups folder first."
        case .overwriteRemote:
            return "Replaces the vault in the folder with the one from this Mac. The copy currently in the folder is discarded."
        }
    }

    static func successMessage(for outcome: VaultMigrationOutcome) -> String {
        switch outcome.strategy {
        case .seedRemote:
            return "The vault from this Mac is now in the iCloud Drive folder."
        case .merge:
            return "Both vaults were merged. This Mac and the iCloud Drive folder now hold the same entries."
        case .adoptRemote:
            return "This Mac now uses the vault from the iCloud Drive folder. The previous local vault was kept in the backups folder."
        case .overwriteRemote:
            return "The iCloud Drive folder now holds the vault from this Mac."
        }
    }

    static func message(for error: Error) -> String {
        if let backendError = error as? iCloudBackendError {
            switch backendError {
            case .folderBookmarkUnresolvable, .folderUnavailable:
                return "That folder is no longer reachable. Choose the iCloud Drive folder again."
            case .downloadTimedOut:
                return "The vault in that folder is still downloading from iCloud. Wait until it finishes, then try again."
            case .containerUnavailable:
                return "MyPass syncs through a folder in iCloud Drive, not a private iCloud container. Choose a folder to continue."
            }
        }
        if let migrationError = error as? VaultMigrationError {
            switch migrationError {
            case .vaultLocked:
                return "Unlock MyPass before setting up iCloud sync."
            case .remoteNotAValidVault:
                return "The file in that folder is not a MyPass vault. Nothing was changed on either side."
            case .remotePasswordMismatch:
                return "The vault in that folder uses a different password. Nothing was changed on either side."
            case .remoteUnreadable(let underlying):
                return "MyPass could not read that folder: \(underlying)"
            case .remoteWriteFailed(let underlying):
                return "MyPass could not write to that folder: \(underlying). Your local vault was not changed."
            case .serializedVaultInvalid:
                return "MyPass could not prepare the vault for upload. Nothing was written to the folder."
            case .localWriteFailed(let underlying):
                return "The copy in iCloud Drive is now ahead of the vault on this Mac: writing the result to disk failed (\(underlying)). Run setup again and choose \u{201C}Use the vault from the folder\u{201D} to catch up."
            }
        }
        return "\(error)"
    }
}
