import Foundation

/// One `.kdbx` file found by `KdbxFileScanner`.
struct FoundVaultFile: Equatable, Identifiable {
    let url: URL
    let modified: Date
    let size: Int64
    /// `true` for an iCloud item whose content is not on this Mac yet. Its metadata is readable
    /// without a download, so it is listed (marked), but opening it makes the system download it.
    let isCloudPlaceholder: Bool

    var id: URL { url }
}

/// Looks for `.kdbx` files below a folder the user granted through `NSOpenPanel`.
///
/// Pure file-system logic with no UI, so it is unit-testable on a temp tree. The caller owns the
/// security-scoped access to the folder and must hold it for the whole scan.
///
/// Rules, and why:
/// - Hidden entries are skipped (`.git`, `.Trash`, the `.name.kdbx.icloud` placeholders iCloud
///   leaves for evicted files — those must never be "opened", it would trigger a download).
/// - Packages and bundles (`.app`, `.photoslibrary`, …) are treated as opaque: scanning into them
///   is slow and a vault never lives there. `node_modules` is skipped for the same reason.
/// - Symbolic links are never followed (no loops, no escaping the granted folder).
/// - The depth, result count and time are bounded so a huge home folder cannot hang the UI.
struct KdbxFileScanner {
    struct Limits: Equatable {
        /// How many directory levels below a scan root are entered (the root itself is level 0).
        var maxDepth = 6
        var maxResults = 100
        /// Wall-clock budget for the whole scan, shared by every root.
        var timeBudget: TimeInterval = 10
    }

    var limits = Limits()

    static let skippedDirectoryNames: Set<String> = ["node_modules"]
    static let opaqueDirectoryExtensions: Set<String> = [
        "app", "bundle", "framework", "plugin", "appex", "kext", "xpc",
        "photoslibrary", "musiclibrary", "tvlibrary", "xcodeproj", "xcworkspace", "playground",
    ]

    /// Scans `folder`. When `folder` is `home`, the places vaults usually live (Documents,
    /// Desktop, Downloads, iCloud Drive, the cloud providers under `Library/CloudStorage`,
    /// `~/Dropbox`) are scanned first and the rest of home afterwards, with `Library` left out
    /// of that remainder. Depth counts from each of those roots. Results are sorted by
    /// modification date, newest first.
    func scan(folder: URL, home: URL? = nil, isCancelled: @escaping () -> Bool = { false }) -> [FoundVaultFile] {
        let run = Run(limits: limits, isCancelled: isCancelled)
        if let home, Self.samePath(folder, home) {
            let priority = Self.priorityRoots(home: home)
            for root in priority { run.walk(root: root, excluded: []) }
            let library = home.appendingPathComponent("Library", isDirectory: true)
            let excluded = Set((priority + [library]).map { Self.key($0) })
            run.walk(root: home, excluded: excluded)
        } else {
            run.walk(root: folder, excluded: [])
        }
        return run.results.sorted { $0.modified > $1.modified }
    }

    static func priorityRoots(home: URL) -> [URL] {
        var roots = ["Documents", "Desktop", "Downloads", "Library/Mobile Documents/com~apple~CloudDocs"]
            .map { home.appendingPathComponent($0, isDirectory: true) }
        let cloudStorage = home.appendingPathComponent("Library/CloudStorage", isDirectory: true)
        if let providers = try? FileManager.default.contentsOfDirectory(
            at: cloudStorage, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) {
            roots += providers.sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
        roots.append(home.appendingPathComponent("Dropbox", isDirectory: true))
        return roots
    }

    private static func key(_ url: URL) -> String { url.standardizedFileURL.path }
    private static func samePath(_ a: URL, _ b: URL) -> Bool { key(a) == key(b) }

    private final class Run {
        let limits: Limits
        let isCancelled: () -> Bool
        let deadline: Date
        var results: [FoundVaultFile] = []
        var seen = Set<String>()

        private static let keys: [URLResourceKey] = [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isPackageKey,
            .contentModificationDateKey, .fileSizeKey, .ubiquitousItemDownloadingStatusKey,
        ]

        init(limits: Limits, isCancelled: @escaping () -> Bool) {
            self.limits = limits
            self.isCancelled = isCancelled
            self.deadline = Date().addingTimeInterval(limits.timeBudget)
        }

        private var shouldStop: Bool {
            results.count >= limits.maxResults || isCancelled() || Date() >= deadline
        }

        func walk(root: URL, excluded: Set<String>) {
            var stack: [(url: URL, depth: Int)] = [(root, 0)]
            while let (directory, depth) = stack.popLast() {
                if shouldStop { return }
                guard let children = try? FileManager.default.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: Self.keys,
                    options: [.skipsHiddenFiles]
                ) else { continue }
                for child in children {
                    if shouldStop { return }
                    guard let values = try? child.resourceValues(forKeys: Set(Self.keys)),
                          values.isSymbolicLink != true else { continue }
                    if values.isDirectory == true {
                        let name = child.lastPathComponent.lowercased()
                        if depth >= limits.maxDepth
                            || values.isPackage == true
                            || KdbxFileScanner.skippedDirectoryNames.contains(name)
                            || KdbxFileScanner.opaqueDirectoryExtensions.contains(child.pathExtension.lowercased())
                            || excluded.contains(KdbxFileScanner.key(child)) { continue }
                        stack.append((child, depth + 1))
                    } else if values.isRegularFile == true, child.pathExtension.lowercased() == "kdbx" {
                        guard seen.insert(KdbxFileScanner.key(child)).inserted else { continue }
                        let status = values.ubiquitousItemDownloadingStatus
                        results.append(FoundVaultFile(
                            url: child,
                            modified: values.contentModificationDate ?? .distantPast,
                            size: Int64(values.fileSize ?? 0),
                            isCloudPlaceholder: status != nil && status != .current && status != .downloaded
                        ))
                    }
                }
            }
        }
    }
}

/// The user's real home directory. Inside the sandbox `FileManager.homeDirectoryForCurrentUser`
/// points into the app container, while the password database still reports the real one, which
/// is the folder the user means in an open panel.
enum RealHomeDirectory {
    static var url: URL {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }
}

/// Holds security-scoped access to a folder the user picked, and releases it exactly once.
/// Used while a found file is being opened: the file bookmark can only be created while the
/// folder grant is active. The home folder is deliberately never bookmarked; the access ends
/// with this object.
final class FolderAccessGrant {
    let url: URL
    private var active: Bool

    init(url: URL) {
        self.url = url
        self.active = url.startAccessingSecurityScopedResource()
    }

    func release() {
        guard active else { return }
        active = false
        url.stopAccessingSecurityScopedResource()
    }

    deinit { release() }
}
