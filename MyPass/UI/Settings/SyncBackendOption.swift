enum SyncBackendOption: String, CaseIterable, Identifiable {
    case local = "Local File"
    case iCloud = "iCloud Drive"
    case sftp = "SFTP"

    var id: String { rawValue }

    var isAvailable: Bool { true }
}
