import Foundation

/// An optional additional copy the vault is synced to on top of whichever
/// `VaultLocationOption` is primary. Unlike the primary location, this is
/// inherently a second copy that needs reconciliation — reuses the existing
/// `SyncEngine` push/pull/merge machinery unchanged.
enum SecondaryDestinationOption: String, CaseIterable, Identifiable {
    case none = "None"
    case folder = "Folder"
    case sftp = "SFTP"

    var id: String { rawValue }

    /// The raw values are persisted (`secondaryDestination` in defaults), so they stay English
    /// forever and must never be shown directly; the picker shows this resource instead.
    var title: LocalizedStringResource {
        switch self {
        case .none: return "None"
        case .folder: return "Folder"
        case .sftp: return "SFTP"
        }
    }
}
