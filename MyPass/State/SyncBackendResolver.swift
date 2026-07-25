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

    /// Combines the non-secret SFTP form fields with Keychain-loaded
    /// `SFTPCredentials` (Task 9) into a real `SFTPBackendConfiguration`
    /// (Task 10). Returns `nil` when `host` is empty or no credentials have
    /// been stored yet — both are expected, common "not configured yet"
    /// states, not errors. The username actually used always comes from the
    /// loaded credentials (paired with the private key at storage time),
    /// not the possibly-stale `username` form field, so a form field edited
    /// without re-picking the key can never silently desync from the key
    /// it's meant to go with.
    static func buildSFTPConfiguration(
        host: String,
        port: Int,
        username: String,
        remotePath: String,
        credentials: SFTPCredentials?
    ) -> SFTPBackendConfiguration? {
        guard !host.isEmpty, let credentials else { return nil }
        return SFTPBackendConfiguration(
            host: host,
            port: port,
            username: credentials.username,
            remotePath: remotePath,
            privateKeyPEM: credentials.privateKeyPEM,
            privateKeyPassphrase: credentials.privateKeyPassphrase
        )
    }
}
