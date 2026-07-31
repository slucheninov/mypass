import SwiftUI
import AppKit
import MyPassKit
import SyncKit

/// Changes the vault's primary `VaultLocation` (Local ↔ iCloud Drive),
/// reachable whether the app is currently locked or unlocked. Entering the
/// master password here is both the "prove you own this vault" check and,
/// when the app was locked, the unlock itself — `VaultSession.verifyPassword`
/// checks it without side effects, and only on success is the vault actually
/// unlocked (if it wasn't already) before the existing probe/strategy/migrate
/// flow (`VaultMigrationService`, unchanged) runs.
struct VaultLocationChangeSheet: View {
    let targetLocation: VaultLocationOption

    @EnvironmentObject private var vaultSession: VaultSession
    @Environment(\.dismiss) private var dismiss
    @AppStorage("vaultLocation") private var vaultLocationRawValue: String = VaultLocationOption.local.rawValue
    @AppStorage(SyncBackendResolver.iCloudFolderBookmarkKey) private var syncICloudFolderBookmarkData: Data?

    @State private var step: Step
    @State private var vaultExistedAtOpen = true
    @State private var confirmPassword: String = ""
    @State private var chosenFolderURL: URL?
    @State private var chosenFolderBookmark: Data?
    @State private var outsideICloudDriveWarning: String?
    @State private var probe: VaultMigrationTargetProbe?
    @State private var strategy: VaultMigrationStrategy = .merge
    @State private var errorMessage: String?
    @State private var successMessage: String?

    init(targetLocation: VaultLocationOption) {
        self.targetLocation = targetLocation
        _step = State(initialValue: .confirmPassword)
    }

    private enum Step: Equatable {
        case confirmPassword
        case chooseFolder
        case probing
        case confirmStrategy
        case migrating
        case finished
    }

    /// Pure, testable version of "does the confirm-password step need to run
    /// right now" — factored out so it does not depend on `VaultSession`'s
    /// concrete `VaultState`/`KdbxDatabase` types.
    enum LockStateSnapshot { case locked, unlocked }
    static func needsPasswordConfirmation(currentState: LockStateSnapshot) -> Bool {
        currentState == .locked
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Change Vault Location")
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
        .onAppear {
            vaultExistedAtOpen = (try? vaultSession.loadVaultData()) != nil
            guard vaultExistedAtOpen else {
                // Nothing exists anywhere yet, so there is nothing to
                // authorize and nothing to migrate — set the location
                // directly, mirroring what the (now-removed) first-run
                // wizard used to do for a brand-new install.
                if targetLocation == .iCloudDrive {
                    step = .chooseFolder
                } else {
                    applyLocationChangeWithoutMigration()
                }
                return
            }
            let snapshot: LockStateSnapshot = isVaultUnlocked ? .unlocked : .locked
            if !Self.needsPasswordConfirmation(currentState: snapshot) {
                step = targetLocation == .iCloudDrive ? .chooseFolder : .probing
                if targetLocation == .local { startProbeAgainstLocal() }
            }
        }
    }

    private var isVaultUnlocked: Bool {
        if case .unlocked = vaultSession.state { return true }
        return false
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .confirmPassword:
            VStack(alignment: .leading, spacing: 8) {
                Text("Enter your master password to confirm this change.")
                    .fixedSize(horizontal: false, vertical: true)
                SecureField("Master Password", text: $confirmPassword)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(confirmPasswordAndContinue)
            }

        case .chooseFolder:
            VStack(alignment: .leading, spacing: 8) {
                Text("MyPass will keep the vault in a folder inside your iCloud Drive.")
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
                Text("Checking the target location…")
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
            }
        }
    }

    @ViewBuilder
    private var strategyChooser: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let probe, probe.exists {
                Text("That location already contains a vault\(Self.describe(probe)). Choose what to do with it.")
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
                Text("That location has no vault yet. MyPass will move the vault from its current location there.")
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack {
            Spacer()
            switch step {
            case .confirmPassword:
                Button("Cancel") { dismiss() }
                Button("Continue") { confirmPasswordAndContinue() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(confirmPassword.isEmpty)
            case .chooseFolder:
                Button("Cancel") { dismiss() }
                Button(chosenFolderURL == nil ? "Choose Folder…" : "Choose Another Folder…") { chooseFolder() }
                if chosenFolderBookmark != nil {
                    Button("Continue") {
                        vaultExistedAtOpen ? startProbeAgainstICloud() : applyLocationChangeWithoutMigration()
                    }
                        .keyboardShortcut(.defaultAction)
                }
            case .probing, .migrating:
                Button("Cancel") { dismiss() }
                    .disabled(true)
            case .confirmStrategy:
                Button("Back") {
                    errorMessage = nil
                    step = targetLocation == .iCloudDrive ? .chooseFolder : .confirmPassword
                }
                Button("Change Location") { startMigration() }
                    .keyboardShortcut(.defaultAction)
            case .finished:
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: - Actions

    private func confirmPasswordAndContinue() {
        guard vaultSession.verifyPassword(confirmPassword) else {
            errorMessage = "Incorrect password."
            return
        }
        if case .locked = vaultSession.state {
            try? vaultSession.unlock(password: confirmPassword)
        }
        confirmPassword = ""
        errorMessage = nil
        if targetLocation == .iCloudDrive {
            step = .chooseFolder
        } else {
            startProbeAgainstLocal()
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        panel.message = "Choose a folder inside iCloud Drive for the MyPass vault. MyPass will create a \"MyPass\" subfolder inside it if needed."
        panel.directoryURL = ICloudDriveLocation.iCloudDriveRootURL

        guard panel.runModal() == .OK, let folderURL = panel.url else { return }

        errorMessage = nil
        do {
            // Wherever the user grants access, keep the vault in its own
            // "MyPass" subfolder rather than dropping it loose into whatever
            // folder they picked (which defaults to the iCloud Drive root) —
            // unless the picked folder already IS a MyPass vault folder (an
            // existing vault.kdbx at its root, or already named "MyPass"),
            // since nesting again there would orphan an existing vault or
            // double-nest a folder created by this same flow on another Mac.
            let alreadyHoldsVault = FileManager.default.fileExists(
                atPath: folderURL.appendingPathComponent("vault.kdbx").path
            )
            let vaultFolderURL: URL
            if alreadyHoldsVault || folderURL.lastPathComponent == "MyPass" {
                vaultFolderURL = folderURL
            } else {
                vaultFolderURL = folderURL.appendingPathComponent("MyPass", isDirectory: true)
                try FileManager.default.createDirectory(at: vaultFolderURL, withIntermediateDirectories: true)
            }
            chosenFolderURL = vaultFolderURL
            outsideICloudDriveWarning = ICloudDriveLocation.isInsideICloudDrive(vaultFolderURL)
                ? nil
                : "This folder is not inside iCloud Drive, so iCloud will not sync it. MyPass will still keep the vault there."
            chosenFolderBookmark = try iCloudBackend.createFolderBookmark(for: vaultFolderURL)
        } catch {
            chosenFolderBookmark = nil
            errorMessage = "MyPass could not keep access to that folder: \(error)"
        }
    }

    private func startProbeAgainstICloud() {
        guard let backend = makeICloudTargetBackend() else { return }
        runProbe(against: backend)
    }

    private func startProbeAgainstLocal() {
        runProbe(against: makeLocalTargetBackend())
    }

    private func runProbe(against backend: StorageBackend) {
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
        let backend: StorageBackend?
        switch targetLocation {
        case .iCloudDrive: backend = makeICloudTargetBackend()
        case .local: backend = makeLocalTargetBackend()
        }
        guard let backend else { return }

        errorMessage = nil
        step = .migrating
        vaultSession.performMigration(to: backend, strategy: strategy) { result in
            switch result {
            case .success(let outcome):
                self.applyLocationChange(outcome: outcome)
            case .failure(let error):
                self.handle(error)
            }
        }
    }

    /// Only reached after `VaultMigrationService.migrate` has already
    /// succeeded — persists the new location and swaps `VaultSession`'s live
    /// primary store, so nothing is written to settings until the data is
    /// safely in place.
    private func applyLocationChange(outcome: VaultMigrationOutcome) {
        switch targetLocation {
        case .iCloudDrive:
            guard let chosenFolderBookmark,
                  let newStore = try? ICloudDriveVaultStore(
                      bookmarkData: chosenFolderBookmark,
                      localBackupDirectory: applicationSupportBackupsDirectory
                  ) else {
                errorMessage = "The vault was moved, but MyPass could not switch to it. Choose the folder again and retry."
                return
            }
            vaultSession.updatePrimaryStore(newStore)
            syncICloudFolderBookmarkData = chosenFolderBookmark
        case .local:
            vaultSession.updatePrimaryStore(VaultFileStore(directory: applicationSupportDirectory))
        }
        vaultLocationRawValue = targetLocation.rawValue
        SyncBackendResolver.clearCheckpoint(for: .folder)
        SyncBackendResolver.clearCheckpoint(for: .sftp)
        successMessage = Self.successMessage(for: outcome)
        step = .finished
    }

    /// Reached only when `vaultExistedAtOpen` is `false`: nothing exists
    /// anywhere yet, so there is nothing to authorize and nothing to
    /// migrate — just point the primary store at the chosen location,
    /// mirroring what the (now-removed) first-run wizard used to do.
    private func applyLocationChangeWithoutMigration() {
        switch targetLocation {
        case .iCloudDrive:
            guard let chosenFolderBookmark,
                  let newStore = try? ICloudDriveVaultStore(
                      bookmarkData: chosenFolderBookmark,
                      localBackupDirectory: applicationSupportBackupsDirectory
                  ) else {
                errorMessage = "MyPass could not use that folder. Choose the folder again and retry."
                return
            }
            vaultSession.updatePrimaryStore(newStore)
            syncICloudFolderBookmarkData = chosenFolderBookmark
        case .local:
            vaultSession.updatePrimaryStore(VaultFileStore(directory: applicationSupportDirectory))
        }
        vaultLocationRawValue = targetLocation.rawValue
        successMessage = "Vault location set. Choose a master password to finish setting up your vault."
        step = .finished
    }

    private var applicationSupportDirectory: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MyPass")
    }

    private var applicationSupportBackupsDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("backups")
    }

    private func makeICloudTargetBackend() -> iCloudBackend? {
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

    private func makeLocalTargetBackend() -> VaultFileStore {
        VaultFileStore(directory: applicationSupportDirectory)
    }

    private func handle(_ error: Error) {
        if let backendError = error as? iCloudBackendError,
           backendError == .folderBookmarkUnresolvable || backendError == .folderUnavailable {
            if Self.shouldClearPersistedBookmark(
                failingBookmark: chosenFolderBookmark,
                persistedBookmark: syncICloudFolderBookmarkData
            ) {
                syncICloudFolderBookmarkData = nil
            }
            chosenFolderBookmark = nil
            chosenFolderURL = nil
        }
        errorMessage = Self.message(for: error)
        step = targetLocation == .iCloudDrive ? .chooseFolder : .confirmPassword
    }

    // MARK: - Copy (unchanged from the previous SyncMigrationSheet — see
    // VaultLocationChangeSheetMessageTests for coverage)

    static func shouldClearPersistedBookmark(failingBookmark: Data?, persistedBookmark: Data?) -> Bool {
        guard let failingBookmark, let persistedBookmark, !failingBookmark.isEmpty else { return false }
        return failingBookmark == persistedBookmark
    }

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
        case .seedRemote: return "Move the vault to the new location"
        case .merge: return "Merge both vaults (recommended)"
        case .adoptRemote: return "Use the vault already at the new location"
        case .overwriteRemote: return "Replace the vault at the new location"
        }
    }

    static func explanation(for strategy: VaultMigrationStrategy) -> String {
        switch strategy {
        case .seedRemote:
            return "The new location has no vault yet, so the current vault is moved there unchanged."
        case .merge:
            return "Keeps every entry from both sides, using the same merge rules as normal syncing. Both copies end up identical."
        case .adoptRemote:
            return "Replaces the current vault with the one already at the new location. The current vault is snapshotted into the backups folder first."
        case .overwriteRemote:
            return "Replaces the vault at the new location with the current one. The copy currently there is discarded."
        }
    }

    static func successMessage(for outcome: VaultMigrationOutcome) -> String {
        switch outcome.strategy {
        case .seedRemote:
            return "The vault is now at the new location."
        case .merge:
            return "Both vaults were merged. The current vault and the new location now hold the same entries."
        case .adoptRemote:
            return "MyPass now uses the vault that was already at the new location. The previous vault was kept in the backups folder."
        case .overwriteRemote:
            return "The new location now holds the current vault."
        }
    }

    static func message(for error: Error) -> String {
        if let backendError = error as? iCloudBackendError {
            return message(forICloudBackendError: backendError)
        }
        if let migrationError = error as? VaultMigrationError {
            switch migrationError {
            case .vaultLocked:
                return "Unlock MyPass before changing the vault location."
            case .remoteNotAValidVault:
                return "The file at that location is not a MyPass vault. Nothing was changed on either side."
            case .remotePasswordMismatch:
                return "The vault at that location uses a different password. Nothing was changed on either side."
            case .remoteUnreadable(let underlying):
                if let backendError = underlying as? iCloudBackendError {
                    return message(forICloudBackendError: backendError)
                }
                return "MyPass could not read that location: \(underlying)"
            case .remoteWriteFailed(let underlying):
                if let backendError = underlying as? iCloudBackendError {
                    return message(forICloudBackendError: backendError)
                }
                return "MyPass could not write to that location: \(underlying). The current vault was not changed."
            case .serializedVaultInvalid:
                return "MyPass could not prepare the vault for the move. Nothing was written to the new location."
            case .localWriteFailed(let underlying):
                return "The new location is now ahead of the current vault: writing the result failed (\(underlying)). Try again and choose \u{201C}Use the vault already at the new location\u{201D} to catch up."
            }
        }
        return "\(error)"
    }

    private static func message(forICloudBackendError backendError: iCloudBackendError) -> String {
        switch backendError {
        case .folderBookmarkUnresolvable, .folderUnavailable:
            return "That folder is no longer reachable. Choose the iCloud Drive folder again."
        case .downloadTimedOut:
            return "The vault at that location is still downloading from iCloud. Wait until it finishes, then try again."
        case .containerUnavailable:
            return "MyPass keeps the vault in a folder in iCloud Drive, not a private iCloud container. Choose a folder to continue."
        }
    }
}
