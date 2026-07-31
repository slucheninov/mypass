import Foundation
import MyPassKit

/// Shared helpers for `VaultLocationChangeSheet`'s "move" flow: prove the
/// vault now at the new location is genuinely openable with the master
/// password before the old location's copy is discarded, and perform that
/// discard. Kept free of `VaultSession`/UI state so both halves are directly
/// unit-testable against plain `VaultPrimaryStorage` implementations.
enum VaultLocationMoveSupport {
    enum Error: Swift.Error {
        case destinationVerifyFailed(underlying: Swift.Error)
    }

    /// Parses `data` with `password`, mirroring the same check
    /// `KdbxDatabase.open` performs on unlock. Throws
    /// `Error.destinationVerifyFailed` (wrapping the underlying error) on any
    /// failure — wrong password, corrupt bytes, wrong file — so a caller
    /// never deletes the source vault unless the destination is provably
    /// readable with the vault's own password.
    static func verifyDestinationOpens(data: Data, password: String) throws {
        do {
            _ = try KdbxDatabase.open(data: data, password: password)
        } catch {
            throw Error.destinationVerifyFailed(underlying: error)
        }
    }

    /// Removes the primary vault file backing `store`, if one exists.
    /// Returns whether a file was actually present to delete, so callers can
    /// distinguish "deleted" from "there was nothing there anyway" without a
    /// separate existence check racing the delete.
    @discardableResult
    static func deleteSourceVault(at store: VaultPrimaryStorage) throws -> Bool {
        let url = store.primaryVaultFileURL
        let existed = url.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        try store.deleteVaultFileIfPresent()
        return existed
    }
}
