/// Where the vault file itself lives — the single primary copy, not a
/// mirror. Custom Folder and SFTP are never primary; see
/// `SecondaryDestinationOption`.
enum VaultLocationOption: String, CaseIterable, Identifiable {
    case local = "Local File"
    case iCloudDrive = "iCloud Drive"

    var id: String { rawValue }
}
