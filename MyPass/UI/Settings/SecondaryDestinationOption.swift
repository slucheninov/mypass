/// An optional additional copy the vault is synced to on top of whichever
/// `VaultLocationOption` is primary. Unlike the primary location, this is
/// inherently a second copy that needs reconciliation — reuses the existing
/// `SyncEngine` push/pull/merge machinery unchanged.
enum SecondaryDestinationOption: String, CaseIterable, Identifiable {
    case none = "None"
    case folder = "Folder"
    case sftp = "SFTP"

    var id: String { rawValue }
}
