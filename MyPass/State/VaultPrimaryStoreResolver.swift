import Foundation

/// Resolves the concrete `VaultPrimaryStorage` a launch (or any later
/// rebuild of it) should use for the configured `VaultLocationOption` —
/// factored out of `MyPassApp.init()` so the "iCloud requested but the
/// bookmark can't resolve, so we silently fell back to Local" path is
/// unit-testable without instantiating a full app. Follows the same "pure
/// decision, caller supplies the I/O" split `VaultLocationResolver` already
/// uses: the actual `ICloudDriveVaultStore` construction (security-scoped
/// bookmark resolution, `NSFileCoordinator` setup) stays the caller's job,
/// injected as `makeICloudStore`.
enum VaultPrimaryStoreResolver {
    struct Resolution {
        let primaryStore: VaultPrimaryStorage

        /// `true` when `vaultLocation == .iCloudDrive` was configured but the
        /// bookmark was missing, stale, or otherwise unresolvable, so
        /// `primaryStore` is actually the Local `VaultFileStore` instead —
        /// possibly a stale copy from before the user switched to iCloud.
        /// The caller persists this so Settings can warn instead of silently
        /// continuing to claim "iCloud Drive" is active.
        let iCloudFallbackToLocal: Bool

        /// `true` when a `localVaultFileBookmarkData` WAS present (the user
        /// had previously opened an existing `.kdbx` via "Open Existing…")
        /// but it could not be resolved (stale bookmark, access denied, the
        /// file was moved/deleted/renamed), so `primaryStore` silently fell
        /// back to the Application Support `VaultFileStore` instead of the
        /// file the user actually opened. Distinct from
        /// `iCloudFallbackToLocal` — this is the LOCAL-bookmark equivalent —
        /// so Settings can show a warning with different, accurate text
        /// rather than either staying silent or misattributing the failure
        /// to iCloud. `false` when no local file bookmark was configured at
        /// all (the normal default-local case, not a fallback).
        let localFileFallbackActive: Bool
    }

    static func resolvePrimaryStore(
        vaultLocation: VaultLocationOption,
        applicationSupportDirectory: URL,
        iCloudBookmarkData: Data?,
        localVaultFileBookmarkData: Data?,
        makeICloudStore: (Data) -> ICloudDriveVaultStore?,
        makeLocalFileStore: (Data) -> LocalFileVaultStore?
    ) -> Resolution {
        switch vaultLocation {
        case .local:
            if let localVaultFileBookmarkData, !localVaultFileBookmarkData.isEmpty {
                if let store = makeLocalFileStore(localVaultFileBookmarkData) {
                    return Resolution(
                        primaryStore: store,
                        iCloudFallbackToLocal: false,
                        localFileFallbackActive: false
                    )
                }
                // A local file bookmark WAS configured but could not be
                // resolved (stale, access denied, file moved/deleted): fall
                // back to Application Support rather than crash launch, but
                // — unlike the "no bookmark configured at all" case below —
                // flag it so Settings can warn instead of silently showing
                // the Application Support path as if it were the user's
                // actual file.
                return Resolution(
                    primaryStore: VaultFileStore(directory: applicationSupportDirectory),
                    iCloudFallbackToLocal: false,
                    localFileFallbackActive: true
                )
            }
            return Resolution(
                primaryStore: VaultFileStore(directory: applicationSupportDirectory),
                iCloudFallbackToLocal: false,
                localFileFallbackActive: false
            )
        case .iCloudDrive:
            if let iCloudBookmarkData, !iCloudBookmarkData.isEmpty,
               let store = makeICloudStore(iCloudBookmarkData) {
                return Resolution(primaryStore: store, iCloudFallbackToLocal: false, localFileFallbackActive: false)
            }
            // Bookmark missing or stale: fall back to Local rather than crash
            // launch. Settings surfaces this (`iCloudPrimaryFallbackActive`)
            // so the user can re-grant access instead of unknowingly
            // autosaving into a possibly-stale local copy.
            return Resolution(
                primaryStore: VaultFileStore(directory: applicationSupportDirectory),
                iCloudFallbackToLocal: true,
                localFileFallbackActive: false
            )
        }
    }
}
