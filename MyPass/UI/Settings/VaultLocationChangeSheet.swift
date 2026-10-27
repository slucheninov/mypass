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
    @AppStorage(SyncBackendResolver.localVaultFileBookmarkKey) private var localVaultFileBookmarkData: Data?

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
    /// The primary store `VaultSession` was using right before `startMigration()`
    /// kicked off the current migration — captured so `applyLocationChange` knows
    /// what "the old location" is once the new one has been verified. `nil`
    /// whenever there is nothing to delete (e.g. `applyLocationChangeWithoutMigration`'s
    /// first-run path, which never sets it).
    @State private var sourceStoreBeforeMigration: VaultPrimaryStorage?

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

    /// Pure, testable helper to compute bookmark mutations when changing vault location.
    /// When moving to iCloud, sets the iCloud folder bookmark and clears the local file bookmark.
    /// When moving to local, clears both bookmarks.
    static func applyBookmarkChanges(
        targetLocation: VaultLocationOption,
        chosenICloudFolderBookmark: Data?,
        localVaultFileBookmark: inout Data?,
        iCloudFolderBookmark: inout Data?
    ) {
        switch targetLocation {
        case .iCloudDrive:
            iCloudFolderBookmark = chosenICloudFolderBookmark
            localVaultFileBookmark = nil
        case .local:
            iCloudFolderBookmark = nil
            localVaultFileBookmark = nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Move Vault")
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
            do {
                vaultExistedAtOpen = try vaultSession.loadVaultData() != nil
            } catch {
                // Could not determine whether a vault exists (e.g. a
                // transient iCloud read failure on an evicted placeholder) —
                // assume it does, so this falls through to the normal
                // confirm/probe/migrate flow (which surfaces the real error
                // there) instead of treating a temporarily-unreadable vault
                // as a fresh install and silently switching location with
                // nothing confirmed and nothing migrated.
                vaultExistedAtOpen = true
            }
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
                    Text(verbatim: chosenFolderURL.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                if let outsideICloudDriveWarning {
                    // Already localized where it is set.
                    Text(verbatim: outsideICloudDriveWarning)
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
                Label(successMessage ?? String(localized: "Done.", comment: "Vault location change sheet: fallback success message shown when the move finished without a more specific message"), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var strategyChooser: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let probe, probe.exists {
                Text(verbatim: Self.existingVaultMessage(for: probe))
                    .fixedSize(horizontal: false, vertical: true)
                Picker("", selection: $strategy) {
                    ForEach([VaultMigrationStrategy.merge, .adoptRemote, .overwriteRemote]) { option in
                        Text(verbatim: Self.title(for: option)).tag(option)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                Text(verbatim: Self.explanation(for: strategy))
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
                Button("Move Vault") { startMigration() }
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
            errorMessage = String(localized: "Incorrect password.", comment: "Vault location change sheet: message")
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
        panel.prompt = String(localized: "Use Folder", comment: "Open panel confirm button for choosing the iCloud Drive vault folder")
        panel.message = String(localized: "Choose a folder inside iCloud Drive for the MyPass vault. MyPass will create a \"MyPass\" subfolder inside it if needed.", comment: "Open panel message for choosing the iCloud Drive vault folder")
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
            let vaultFolderURL = try VaultICloudFolderSelection.resolveVaultFolder(from: folderURL)
            chosenFolderURL = vaultFolderURL
            outsideICloudDriveWarning = ICloudDriveLocation.isInsideICloudDrive(vaultFolderURL)
                ? nil
                : String(localized: "This folder is not inside iCloud Drive, so iCloud will not sync it. MyPass will still keep the vault there.", comment: "Vault location change sheet: warning")
            chosenFolderBookmark = try iCloudBackend.createFolderBookmark(for: vaultFolderURL)
        } catch {
            chosenFolderBookmark = nil
            errorMessage = String(localized: "MyPass could not keep access to that folder: \(String(describing: error))", comment: "Vault location change sheet: message")
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

        let sourceStore = vaultSession.currentPrimaryStore
        // Refuse a "move" whose destination is the SAME file as the source —
        // most commonly reachable when the app silently fell back to Local
        // storage (`iCloudPrimaryFallbackActive`, e.g. an unresolvable
        // iCloud bookmark at launch) while `vaultLocation` still reads
        // `.iCloudDrive`, so this sheet still offers "Move to Local…" even
        // though the current primary already IS the Application Support
        // file. Without this guard, the move would trivially "verify" (the
        // destination is the source, so of course it opens with the
        // password) and then delete the only copy of the vault. Checked here
        // — before migration even starts — rather than only at the delete
        // step, so the user sees an explanatory error instead of a
        // migration that silently no-ops before destroying data.
        if Self.destinationIsSameFileAsSource(sourceStore: sourceStore, destinationBackend: backend) {
            errorMessage = String(localized: "The vault is already at that location. Nothing was changed.", comment: "Vault location change sheet: message")
            return
        }

        sourceStoreBeforeMigration = sourceStore
        errorMessage = nil
        step = .migrating
        vaultSession.performMigration(to: backend, strategy: strategy) { result in
            switch result {
            case .success(let outcome):
                self.applyLocationChange(outcome: outcome, destinationBackend: backend)
            case .failure(let error):
                self.handle(error)
            }
        }
    }

    /// Only reached after `VaultMigrationService.migrate` has already
    /// succeeded. Before touching anything persistent, re-reads the bytes
    /// `migrate` just wrote to `destinationBackend` and confirms they open
    /// with the vault's own password — the same "prove it's real" bar the
    /// old location was already held to — and only then deletes the old
    /// location's file and swaps `VaultSession`'s live primary store. If the
    /// verify fails, nothing is changed on either side and the user is sent
    /// back to choose again. If verify succeeds but the delete fails, the
    /// move still completes (the new location is good and already primary)
    /// but the success message becomes a warning about the leftover copy.
    private func applyLocationChange(outcome: VaultMigrationOutcome, destinationBackend: StorageBackend) {
        let destinationData: Data
        do {
            guard let data = try destinationBackend.read() else {
                errorMessage = String(localized: "MyPass could not read the vault at the new location. Nothing was changed.", comment: "Vault location change sheet: message")
                step = .confirmStrategy
                return
            }
            destinationData = data
        } catch {
            errorMessage = String(localized: "MyPass could not read the vault at the new location. Nothing was changed.", comment: "Vault location change sheet: message")
            step = .confirmStrategy
            return
        }

        do {
            try vaultSession.verifyDestinationOpens(data: destinationData)
        } catch {
            errorMessage = String(localized: "The vault at the new location could not be opened with your password. Nothing was changed.", comment: "Vault location change sheet: message")
            step = .confirmStrategy
            return
        }

        // Everything from here down that can still fail (re-resolving the
        // iCloud folder bookmark, constructing the new store) must run BEFORE
        // the source is deleted — never destroy a copy before its
        // replacement is not just verified-readable but actually live as the
        // new primary. Source deletion below is therefore the last step and
        // is warning-only: once reached, nothing after it can fail.
        let destinationStore: VaultPrimaryStorage
        switch targetLocation {
        case .iCloudDrive:
            guard let chosenFolderBookmark,
                  let newStore = try? ICloudDriveVaultStore(
                      bookmarkData: chosenFolderBookmark,
                      localBackupDirectory: applicationSupportBackupsDirectory
                  ) else {
                errorMessage = String(localized: "MyPass could not switch to the new location. Nothing was changed. Choose the folder again and retry.", comment: "Vault location change sheet: message")
                step = .confirmStrategy
                return
            }
            destinationStore = newStore
        case .local:
            destinationStore = VaultFileStore(directory: applicationSupportDirectory)
        }
        vaultSession.updatePrimaryStore(destinationStore)
        // Apply bookmark bookkeeping: set/clear the appropriate UserDefaults keys
        // based on the target location, using the pure testable helper.
        Self.applyBookmarkChanges(
            targetLocation: targetLocation,
            chosenICloudFolderBookmark: chosenFolderBookmark,
            localVaultFileBookmark: &localVaultFileBookmarkData,
            iCloudFolderBookmark: &syncICloudFolderBookmarkData
        )
        vaultLocationRawValue = targetLocation.rawValue
        // Secondary `.folder`/`.sftp` checkpoint clearing now happens inside
        // `VaultSession.updatePrimaryStore` itself (see its doc comment), so
        // every primary-swap call site — including
        // `retargetToOpenExistingVault` — inherits it automatically instead
        // of each one needing to remember to call it here.

        var sourceDeleteWarning: String?
        if let sourceStore = sourceStoreBeforeMigration {
            // Defensive, independent re-check right at the point of deletion
            // (in addition to `startMigration`'s earlier guard): never delete
            // a file that is also the one we just switched primary to. This
            // should be unreachable given that earlier guard, but this is
            // the actual line that would destroy the vault's only copy if
            // source and destination ever did turn out to be the same file,
            // so it stays defended on its own rather than only trusting a
            // check made several steps — and one full migration — earlier.
            if VaultLocationMoveSupport.isSameVaultFile(
                sourceStore.primaryVaultFileURL,
                destinationStore.primaryVaultFileURL
            ) {
                sourceDeleteWarning = String(localized: "The vault was moved, but MyPass detected the old location was the same file as the new one and left it in place.", comment: "Vault location change sheet: message")
            } else {
                do {
                    try VaultLocationMoveSupport.deleteSourceVault(at: sourceStore)
                } catch {
                    if let path = sourceStore.primaryVaultFileURL?.path {
                        sourceDeleteWarning = String(localized: "The vault was moved, but an old copy could not be removed at \(path).", comment: "Vault location change sheet: message")
                    } else {
                        sourceDeleteWarning = String(localized: "The vault was moved, but the previous copy could not be removed.", comment: "Vault location change sheet: message")
                    }
                }
            }
        }
        sourceStoreBeforeMigration = nil

        successMessage = sourceDeleteWarning ?? Self.successMessage(for: outcome)
        step = .finished
    }

    /// `true` when `sourceStore`'s current vault file and `destinationBackend`
    /// (about to become the new primary) resolve to the same file on disk —
    /// see Finding 1's doc comment on `startMigration` for why this matters.
    /// `destinationBackend` is a `StorageBackend`, not a `VaultPrimaryStorage`,
    /// so its file URL is recovered by concrete type rather than through the
    /// `VaultPrimaryStorage` protocol.
    static func destinationIsSameFileAsSource(
        sourceStore: VaultPrimaryStorage,
        destinationBackend: StorageBackend
    ) -> Bool {
        let destinationURL: URL?
        switch destinationBackend {
        case let iCloud as iCloudBackend:
            destinationURL = iCloud.vaultFileURL
        case let local as VaultFileStore:
            destinationURL = local.primaryVaultFileURL
        default:
            destinationURL = nil
        }
        return VaultLocationMoveSupport.isSameVaultFile(sourceStore.primaryVaultFileURL, destinationURL)
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
                errorMessage = String(localized: "MyPass could not use that folder. Choose the folder again and retry.", comment: "Vault location change sheet: message")
                return
            }
            vaultSession.updatePrimaryStore(newStore)
        case .local:
            vaultSession.updatePrimaryStore(VaultFileStore(directory: applicationSupportDirectory))
        }
        // Apply bookmark bookkeeping: set/clear the appropriate UserDefaults keys
        // based on the target location, using the pure testable helper.
        Self.applyBookmarkChanges(
            targetLocation: targetLocation,
            chosenICloudFolderBookmark: chosenFolderBookmark,
            localVaultFileBookmark: &localVaultFileBookmarkData,
            iCloudFolderBookmark: &syncICloudFolderBookmarkData
        )
        vaultLocationRawValue = targetLocation.rawValue
        successMessage = String(localized: "Vault location set. Choose a master password to finish setting up your vault.", comment: "Vault location change sheet: message")
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
            errorMessage = String(localized: "Choose a folder first.", comment: "Vault location change sheet: message")
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

    /// The "that location already contains a vault" sentence. The size and the modification date
    /// are optional, so there is one whole localized sentence per combination instead of a
    /// sentence stitched together from fragments: a translator sees (and can word, punctuate and
    /// order) each full sentence, rather than inheriting English " (" / ", " separators.
    static func existingVaultMessage(for probe: VaultMigrationTargetProbe) -> String {
        let size = probe.byteCount.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }
        let modified = probe.modificationDate?.formatted(date: .abbreviated, time: .shortened)
        switch (size, modified) {
        case let (size?, modified?):
            return String(localized: "That location already contains a vault (\(size), modified \(modified)). Choose what to do with it.", comment: "Vault location change sheet: message when the target already holds a vault. First placeholder is the file size (for example 4 KB), second is the last modification date and time")
        case let (size?, nil):
            return String(localized: "That location already contains a vault (\(size)). Choose what to do with it.", comment: "Vault location change sheet: message when the target already holds a vault. The placeholder is the file size (for example 4 KB); the modification date is unknown")
        case let (nil, modified?):
            return String(localized: "That location already contains a vault (modified \(modified)). Choose what to do with it.", comment: "Vault location change sheet: message when the target already holds a vault. The placeholder is the last modification date and time; the file size is unknown")
        case (nil, nil):
            return String(localized: "That location already contains a vault. Choose what to do with it.", comment: "Vault location change sheet: message when the target already holds a vault and neither its size nor its modification date is known")
        }
    }

    static func title(for strategy: VaultMigrationStrategy) -> String {
        switch strategy {
        case .seedRemote: return String(localized: "Move the vault to the new location", comment: "Vault location change sheet: migration strategy option")
        case .merge: return String(localized: "Merge both vaults (recommended)", comment: "Vault location change sheet: migration strategy option")
        case .adoptRemote: return String(localized: "Use the vault already at the new location", comment: "Vault location change sheet: migration strategy option")
        case .overwriteRemote: return String(localized: "Replace the vault at the new location", comment: "Vault location change sheet: migration strategy option")
        }
    }

    static func explanation(for strategy: VaultMigrationStrategy) -> String {
        switch strategy {
        case .seedRemote:
            return String(localized: "The new location has no vault yet, so the current vault is moved there unchanged.", comment: "Vault location change sheet: message")
        case .merge:
            return String(localized: "Keeps every entry from both sides, using the same merge rules as normal syncing. Both copies end up identical.", comment: "Vault location change sheet: message")
        case .adoptRemote:
            return String(localized: "Replaces the current vault with the one already at the new location. The current vault is snapshotted into the backups folder first.", comment: "Vault location change sheet: message")
        case .overwriteRemote:
            return String(localized: "Replaces the vault at the new location with the current one. The copy currently there is discarded.", comment: "Vault location change sheet: message")
        }
    }

    static func successMessage(for outcome: VaultMigrationOutcome) -> String {
        switch outcome.strategy {
        case .seedRemote:
            return String(localized: "The vault is now at the new location.", comment: "Vault location change sheet: message")
        case .merge:
            return String(localized: "Both vaults were merged. The current vault and the new location now hold the same entries.", comment: "Vault location change sheet: message")
        case .adoptRemote:
            return String(localized: "MyPass now uses the vault that was already at the new location. The previous vault was kept in the backups folder.", comment: "Vault location change sheet: message")
        case .overwriteRemote:
            return String(localized: "The new location now holds the current vault.", comment: "Vault location change sheet: message")
        }
    }

    static func message(for error: Error) -> String {
        if let backendError = error as? iCloudBackendError {
            return message(forICloudBackendError: backendError)
        }
        if let migrationError = error as? VaultMigrationError {
            switch migrationError {
            case .vaultLocked:
                return String(localized: "Unlock MyPass before changing the vault location.", comment: "Vault location change sheet: message")
            case .remoteNotAValidVault:
                return String(localized: "The file at that location is not a MyPass vault. Nothing was changed on either side.", comment: "Vault location change sheet: message")
            case .remotePasswordMismatch:
                return String(localized: "The vault at that location uses a different password. Nothing was changed on either side.", comment: "Vault location change sheet: message")
            case .remoteUnreadable(let underlying):
                if let backendError = underlying as? iCloudBackendError {
                    return message(forICloudBackendError: backendError)
                }
                return String(localized: "MyPass could not read that location: \(String(describing: underlying))", comment: "Vault location change sheet: message")
            case .remoteWriteFailed(let underlying):
                if let backendError = underlying as? iCloudBackendError {
                    return message(forICloudBackendError: backendError)
                }
                return String(localized: "MyPass could not write to that location: \(String(describing: underlying)). The current vault was not changed.", comment: "Vault location change sheet: message")
            case .serializedVaultInvalid:
                return String(localized: "MyPass could not prepare the vault for the move. Nothing was written to the new location.", comment: "Vault location change sheet: message")
            case .localWriteFailed(let underlying):
                return String(localized: "The new location is now ahead of the current vault: writing the result failed (\(String(describing: underlying))). Try again and choose \u{201C}Use the vault already at the new location\u{201D} to catch up.", comment: "Vault location change sheet: message")
            }
        }
        return "\(error)"
    }

    private static func message(forICloudBackendError backendError: iCloudBackendError) -> String {
        switch backendError {
        case .folderBookmarkUnresolvable, .folderUnavailable:
            return String(localized: "That folder is no longer reachable. Choose the iCloud Drive folder again.", comment: "Vault location change sheet: message")
        case .downloadTimedOut:
            return String(localized: "The vault at that location is still downloading from iCloud. Wait until it finishes, then try again.", comment: "Vault location change sheet: message")
        case .containerUnavailable:
            return String(localized: "MyPass keeps the vault in a folder in iCloud Drive, not a private iCloud container. Choose a folder to continue.", comment: "Vault location change sheet: message")
        }
    }
}
