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
        legacyLocalFolderBookmark: Data?
    ) -> LegacyMigrationResult? {
        guard let legacySyncBackendRawValue else { return nil }
        switch legacySyncBackendRawValue {
        case "iCloud Drive":
            // The user was already mirroring into iCloud Drive — promote it
            // straight to primary, which is what they were already relying on.
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
