import Foundation

/// Pure resolution logic for the primary vault location — factored out of
/// `MyPassApp`/`UnlockView`/Settings so it is unit-testable without
/// instantiating SwiftUI views or a full app, following the same pattern as
/// `SyncBackendResolver`.
enum VaultLocationResolver {
    struct LegacyMigrationResult: Equatable {
        let vaultLocation: VaultLocationOption
        let secondaryDestination: SecondaryDestinationOption?
        let secondaryFolderBookmark: Data?
    }

    /// Resolves the persisted `"vaultLocation"` UserDefaults value, defaulting
    /// to `.local` for a `nil` or unrecognized value — the same
    /// never-crash-on-bad-or-missing-state contract `SyncBackendResolver`
    /// already uses for its bookmarks.
    static func resolveVaultLocation(rawValue: String?) -> VaultLocationOption {
        VaultLocationOption(rawValue: rawValue ?? "") ?? .local
    }

    /// Maps a pre-redesign `"syncBackend"` value (`SyncBackendOption`'s old
    /// rawValues: "Local File" / "iCloud Drive" / "SFTP") onto the new
    /// two-picker model, so an existing install upgrades without losing its
    /// configuration. Returns `nil` when there is nothing legacy to migrate
    /// (either a fresh install, or one already migrated/configured on the new
    /// model). Called once at launch, guarded by the caller checking the new
    /// `"vaultLocation"` key is not yet set.
    static func migrateLegacyBackendIfNeeded(
        legacySyncBackendRawValue: String?,
        legacyLocalFolderBookmark: Data?,
        legacyICloudFolderBookmark: Data? = nil,
        localVaultModificationDate: Date? = nil,
        iCloudVaultModificationDate: Date? = nil
    ) -> LegacyMigrationResult? {
        guard let legacySyncBackendRawValue else { return nil }
        switch legacySyncBackendRawValue {
        case "iCloud Drive":
            // In the old model, Application Support was always canonical and
            // iCloud only a mirror — one updated on save, but which can lag
            // behind if the last sync push failed while offline. Promoting
            // straight to iCloud-primary is only safe when the iCloud copy is
            // provably at least as new as the local one; otherwise (including
            // when either date is unavailable) keep Local canonical and
            // preserve the iCloud folder as a Folder secondary so nothing is
            // lost — the existing merge machinery can reconcile them later.
            let iCloudIsAtLeastAsNewAsLocal: Bool = {
                guard let iCloudDate = iCloudVaultModificationDate,
                      let localDate = localVaultModificationDate else { return false }
                return iCloudDate >= localDate
            }()
            guard iCloudIsAtLeastAsNewAsLocal else {
                return LegacyMigrationResult(
                    vaultLocation: .local,
                    secondaryDestination: .folder,
                    secondaryFolderBookmark: legacyICloudFolderBookmark
                )
            }
            return LegacyMigrationResult(vaultLocation: .iCloudDrive, secondaryDestination: nil, secondaryFolderBookmark: nil)
        case "Local File":
            // The user was mirroring into a picked folder — that folder
            // becomes the new secondary "Folder" destination; Application
            // Support stays primary exactly as it already was.
            return LegacyMigrationResult(
                vaultLocation: .local,
                secondaryDestination: .folder,
                secondaryFolderBookmark: legacyLocalFolderBookmark
            )
        case "SFTP":
            return LegacyMigrationResult(vaultLocation: .local, secondaryDestination: .sftp, secondaryFolderBookmark: nil)
        default:
            return LegacyMigrationResult(vaultLocation: .local, secondaryDestination: nil, secondaryFolderBookmark: nil)
        }
    }
}
