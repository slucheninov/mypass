import Foundation

/// Where the vault file itself lives — the single primary copy, not a
/// mirror. Custom Folder and SFTP are never primary; see
/// `SecondaryDestinationOption`.
enum VaultLocationOption: String, CaseIterable, Identifiable {
    case local = "Local File"
    case iCloudDrive = "iCloud Drive"

    var id: String { rawValue }

    /// The raw values are persisted (`vaultLocation` in defaults), so they stay English forever
    /// and must never be shown directly; the UI shows this resource instead.
    var title: LocalizedStringResource {
        switch self {
        case .local: return "Local File"
        case .iCloudDrive: return "iCloud Drive"
        }
    }
}
