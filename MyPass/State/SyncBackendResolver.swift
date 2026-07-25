import Foundation
import SyncKit

/// Pure(ish) resolution logic turning persisted Settings values into a
/// concrete `StorageBackend` — factored out of `SettingsView`/`MyPassApp` so
/// it's unit-testable without instantiating SwiftUI views or a full app
/// (`MyPassTests/SettingsViewSyncBackendTests.swift`).
enum SyncBackendResolver {
    /// Resolves the Local-folder backend from previously-persisted
    /// security-scoped bookmark data (Task 2's `LocalFolderBackend`).
    /// Returns `nil` (never throws) when no folder has been chosen yet — a
    /// missing bookmark is expected, common state (fresh install, user
    /// hasn't picked a folder), not an error. A stale or otherwise corrupt
    /// bookmark also resolves to `nil` rather than throwing, so a bad
    /// persisted value can never crash app launch — the user simply sees
    /// "no folder chosen" in Settings and can re-pick one.
    static func resolveLocalFolderBackend(bookmarkData: Data?) -> LocalFolderBackend? {
        guard let bookmarkData, !bookmarkData.isEmpty else { return nil }
        return try? LocalFolderBackend(bookmarkData: bookmarkData)
    }

    /// Resolves the iCloud backend. Returns `nil` (never throws) when the
    /// container isn't available (iCloud Drive disabled/not signed in),
    /// for the same "never crash app launch on bad/missing external state"
    /// reason as above — `SettingsView` surfaces the warning inline instead.
    static func resolveICloudBackend(relativePath: String = "vault.kdbx") -> iCloudBackend? {
        try? iCloudBackend(relativePath: relativePath)
    }
}
