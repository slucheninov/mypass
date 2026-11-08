import Foundation

/// Size and modification date of a vault file, plus the display helpers shared by the unlock
/// screen, the file finder and Settings.
struct VaultFileInfo: Equatable {
    let url: URL
    let modified: Date?
    let size: Int64?

    init(url: URL, modified: Date?, size: Int64?) {
        self.url = url
        self.modified = modified
        self.size = size
    }

    /// Reads the file's metadata; `nil` when the file does not exist or is not a regular file.
    init?(url: URL, fileManager: FileManager = .default) {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return nil
        }
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        self.init(
            url: url,
            modified: attributes?[.modificationDate] as? Date,
            size: (attributes?[.size] as? NSNumber)?.int64Value
        )
    }

    var fileName: String { url.lastPathComponent }

    var sizeText: String? { size.map(Self.sizeText(_:)) }

    var modifiedText: String? {
        modified.map { String(localized: "Modified \(Self.dateText($0))", comment: "Vault file details: last modification date and time; the argument is the formatted date") }
    }

    /// "Modified 8 Nov 2026 at 14:03 · 12 KB", with whichever parts are known.
    var summary: String? {
        let parts = [modifiedText, sizeText].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func sizeText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func dateText(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    /// Replaces the user's home prefix with `~`. Done by hand because `abbreviatingWithTildeInPath`
    /// uses the sandbox container as "home", which is not what the user sees in Finder.
    static func abbreviatedPath(_ path: String, home: String = RealHomeDirectory.url.path) -> String {
        if path == home { return "~" }
        let prefix = home.hasSuffix("/") ? home : home + "/"
        return path.hasPrefix(prefix) ? "~/" + path.dropFirst(prefix.count) : path
    }

    var abbreviatedPath: String { Self.abbreviatedPath(url.path) }
}

/// What the unlock screen should say about the vault file, resolved without any UI so it can be
/// tested on a temp directory.
enum VaultFileStatus: Equatable {
    /// The configured vault file exists.
    case connected(VaultFileInfo)
    /// Nothing exists at the default location yet: first run.
    case noVault
    /// A vault file was configured (a bookmarked `.kdbx`, or iCloud Drive) but is unreachable.
    /// `path` is `nil` when the bookmark did not resolve, so the old location is unknown.
    case missing(path: String?)
    /// The configured file is unreachable and MyPass is using the existing default copy instead.
    /// The master password unlocks that copy.
    case missingUsingLocalCopy(VaultFileInfo)

    /// - Parameters:
    ///   - primaryURL: the file the active primary store reads and writes.
    ///   - isDefaultLocation: `true` for the Application Support `vault.kdbx`.
    ///   - fallbackActive: a configured bookmark failed to resolve and the default is in use.
    static func resolve(
        primaryURL: URL?,
        isDefaultLocation: Bool,
        fallbackActive: Bool,
        fileManager: FileManager = .default
    ) -> VaultFileStatus {
        // Checked first: the default file may well exist, but it is not the one the user chose.
        if fallbackActive {
            if let primaryURL, let copy = VaultFileInfo(url: primaryURL, fileManager: fileManager) {
                return .missingUsingLocalCopy(copy)
            }
            return .missing(path: nil)
        }
        guard let primaryURL else { return .noVault }
        if let info = VaultFileInfo(url: primaryURL, fileManager: fileManager) { return .connected(info) }
        return isDefaultLocation ? .noVault : .missing(path: primaryURL.path)
    }
}
