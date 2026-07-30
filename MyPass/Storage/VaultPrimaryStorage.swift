import Foundation

/// Abstracts "where the vault file currently lives" so `VaultSession` can hold
/// either `VaultFileStore` (Application Support) or `ICloudDriveVaultStore`
/// (a user-granted iCloud Drive folder) interchangeably, and swap between them
/// at runtime when the user changes the configured vault location.
protocol VaultPrimaryStorage {
    func load() throws -> Data?
    func save(data: Data) throws
}
