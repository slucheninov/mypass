import Foundation

public enum iCloudBackendError: Error, Equatable {
    case containerUnavailable
    case downloadTimedOut
    case folderBookmarkUnresolvable
    case folderUnavailable
}

/// Where an `iCloudBackend` instance keeps its remote file.
public enum iCloudRoot {
    /// A real iCloud ubiquity container. Requires
    /// `com.apple.developer.icloud-container-identifiers`, a restricted
    /// entitlement that needs a paid Apple Developer account, so this root is
    /// unreachable in ad-hoc-signed local builds. `nil` means "the app's first
    /// configured container".
    case ubiquityContainer(identifier: String?)
    /// A user-picked folder — normally inside `~/Library/Mobile
    /// Documents/com~apple~CloudDocs` — reached through a security-scoped
    /// bookmark. Needs only the sandbox entitlements the app already has:
    /// `com.apple.security.files.user-selected.read-write` and
    /// `com.apple.security.files.bookmarks.app-scope`.
    case userFolder(bookmark: Data)
}

/// `StorageBackend` over iCloud Drive. Every read/write goes through
/// `NSFileCoordinator` so overlapping access from other processes (Finder,
/// other MyPass instances, the file-provider daemon itself) is safely
/// serialized — per the design spec's iCloud backend section
/// ("NSFileCoordinator + NSFilePresenter; conflict versions (NSFileVersion)
/// are merged and removed"). Both roots share that coordinated I/O, the
/// download materialisation in `ensureDownloaded`, and the conflict sweep in
/// `resolveConflictVersions`; they differ only in how the file URL is
/// resolved. Plain uncoordinated I/O (as in `LocalFolderBackend`) is not
/// good enough for a file inside iCloud Drive: an evicted file could read as
/// a placeholder instead of the vault bytes, and parallel edits from another
/// device would never reach `NSFileVersion` conflict resolution.
public final class iCloudBackend: StorageBackend, ConflictResolvingStorageBackend {
    private let fileURL: URL
    /// Non-nil only for `.userFolder` roots whose security scope this instance
    /// actually acquired, so `deinit` can balance it. Held for the lifetime of
    /// the backend rather than per operation, mirroring the lifetime of the
    /// `NSFilePresenter` registration below.
    private let securityScopedFolderURL: URL?
    private let presenter: iCloudFilePresenter

    public init(root: iCloudRoot, relativePath: String) throws {
        switch root {
        case .ubiquityContainer(let identifier):
            guard let containerURL = FileManager.default.url(forUbiquityContainerIdentifier: identifier) else {
                throw iCloudBackendError.containerUnavailable
            }
            fileURL = Self.coordinatedURL(containerURL: containerURL, relativePath: relativePath)
            securityScopedFolderURL = nil

        case .userFolder(let bookmark):
            var isStale = false
            guard !bookmark.isEmpty,
                  let folderURL = try? URL(
                      resolvingBookmarkData: bookmark,
                      options: .withSecurityScope,
                      relativeTo: nil,
                      bookmarkDataIsStale: &isStale
                  ),
                  !isStale else {
                throw iCloudBackendError.folderBookmarkUnresolvable
            }
            // `false` here does not mean failure: an unsandboxed process (the
            // `swift test` runner) needs no security scope and still reads the
            // folder fine, exactly as `LocalFolderBackend` assumes. Only a
            // missing directory is a real error.
            let didStartAccessing = folderURL.startAccessingSecurityScopedResource()
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folderURL.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                if didStartAccessing {
                    folderURL.stopAccessingSecurityScopedResource()
                }
                throw iCloudBackendError.folderUnavailable
            }
            fileURL = Self.coordinatedURL(folderURL: folderURL, relativePath: relativePath)
            securityScopedFolderURL = didStartAccessing ? folderURL : nil
        }

        presenter = iCloudFilePresenter(presentedItemURL: fileURL)
        NSFileCoordinator.addFilePresenter(presenter)
    }

    /// Ubiquity-container convenience initialiser, kept so existing call sites
    /// and the future paid-account setup keep working unchanged.
    public convenience init(relativePath: String = "vault.kdbx", containerIdentifier: String? = nil) throws {
        try self.init(root: .ubiquityContainer(identifier: containerIdentifier), relativePath: relativePath)
    }

    deinit {
        NSFileCoordinator.removeFilePresenter(presenter)
        securityScopedFolderURL?.stopAccessingSecurityScopedResource()
    }

    /// Creates the bookmark a `.userFolder` root is built from. Same option
    /// set as `LocalFolderBackend.createBookmark(for:)` — with
    /// `com.apple.security.files.bookmarks.app-scope` entitled, this is an
    /// app-scoped bookmark that survives relaunch.
    public static func createFolderBookmark(for folderURL: URL) throws -> Data {
        try folderURL.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    /// Fires when iCloud delivers a change to the presented file made by
    /// another device/process while this backend instance is alive. `nil` by
    /// default (`SyncEngine` never needs it; only app-level wiring does).
    public var onRemoteChange: (() -> Void)? {
        get { presenter.onChange }
        set { presenter.onChange = newValue }
    }

    /// Pure helper computing the file URL for `relativePath` inside a ubiquity
    /// container, so it is directly unit-testable without a real container.
    /// `Documents` is the standard iCloud Drive-visible subdirectory of a
    /// ubiquity container — files placed directly at the container root are
    /// not shown in the Finder/iCloud Drive UI.
    static func coordinatedURL(containerURL: URL, relativePath: String) -> URL {
        containerURL.appendingPathComponent("Documents").appendingPathComponent(relativePath)
    }

    /// Pure helper computing the file URL for `relativePath` inside a
    /// user-picked folder. No `Documents` component: that subdirectory is a
    /// ubiquity-container convention, and the user already picked the exact
    /// folder the vault should live in.
    static func coordinatedURL(folderURL: URL, relativePath: String) -> URL {
        folderURL.appendingPathComponent(relativePath)
    }

    /// Re-fetches resource values from disk, bypassing Foundation's per-URL cache.
    /// `fileURL` is a stored `let`; repeated `resourceValues(forKeys:)` on it
    /// returns cached values. Clearing via a local `var` copy works because
    /// `NSURL`'s resource-value cache is not copy-on-write — mutating the copy
    /// clears entries the stored `let` reads through.
    private func freshResourceValues(forKeys keys: Set<URLResourceKey>) throws -> URLResourceValues {
        var url = fileURL
        url.removeAllCachedResourceValues()
        return try url.resourceValues(forKeys: keys)
    }

    public func exists() throws -> Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
    }

    public func modificationDate() throws -> Date? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let values = try freshResourceValues(forKeys: [.contentModificationDateKey])
        return values.contentModificationDate
    }

    public func read() throws -> Data? {
        guard try exists() else { return nil }
        try ensureDownloaded()

        let coordinator = NSFileCoordinator(filePresenter: presenter)
        var coordinatorError: NSError?
        var result: Data?
        var readError: Error?
        coordinator.coordinate(readingItemAt: fileURL, options: [], error: &coordinatorError) { url in
            do {
                result = try Data(contentsOf: url)
            } catch {
                readError = error
            }
        }
        if let coordinatorError { throw coordinatorError }
        if let readError { throw readError }
        return result
    }

    public func write(_ data: Data) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let coordinator = NSFileCoordinator(filePresenter: presenter)
        var coordinatorError: NSError?
        var writeError: Error?
        coordinator.coordinate(writingItemAt: fileURL, options: .forReplacing, error: &coordinatorError) { url in
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                writeError = error
            }
        }
        if let coordinatorError { throw coordinatorError }
        if let writeError { throw writeError }
    }

    /// iCloud downloads are not synchronous — a file that "exists" per
    /// `FileManager` may still be a not-yet-materialized placeholder. This
    /// starts the download (if needed) and polls
    /// `URLResourceKey.ubiquitousItemDownloadingStatusKey` until it reports
    /// `.current`, or throws `.downloadTimedOut` after `timeout` seconds.
    public func ensureDownloaded(timeout: TimeInterval = 10) throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }

        // A file the iCloud file provider does not manage — a plain folder, or
        // a test temp directory — has nothing to materialize, and
        // `startDownloadingUbiquitousItem` throws for such paths. Skipping is
        // both correct and what makes `.userFolder` roots testable outside
        // iCloud Drive.
        let ubiquityFlags = try? freshResourceValues(forKeys: [.isUbiquitousItemKey])
        guard ubiquityFlags?.isUbiquitousItem == true else { return }

        let initial = try freshResourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
        if initial.ubiquitousItemDownloadingStatus == .current {
            return
        }

        try FileManager.default.startDownloadingUbiquitousItem(at: fileURL)

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let latest = try freshResourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
            if latest.ubiquitousItemDownloadingStatus == .current {
                return
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        throw iCloudBackendError.downloadTimedOut
    }

    /// Folds any unresolved iCloud conflict versions of this backend's file
    /// into a single merged version, via the caller-supplied `merge` closure —
    /// one raw-`Data`-in, raw-`Data`-out step per conflict, so `iCloudBackend`
    /// itself stays password/`KdbxDatabase`-agnostic. Returns `false` when
    /// there are no unresolved conflicts.
    public func resolveConflictVersions(merge: (Data, Data) throws -> Data) throws -> Bool {
        guard let conflictVersions = NSFileVersion.unresolvedConflictVersionsOfItem(at: fileURL),
              !conflictVersions.isEmpty else {
            return false
        }
        guard var mergedData = try read() else {
            // No readable current version to merge conflicts into — nothing
            // sensible to do; leave the conflicts unresolved rather than
            // guessing which conflict version should become "current".
            return false
        }

        for conflictVersion in conflictVersions {
            guard let conflictData = try? Data(contentsOf: conflictVersion.url) else { continue }
            mergedData = try merge(mergedData, conflictData)
        }

        try write(mergedData)
        for conflictVersion in conflictVersions {
            conflictVersion.isResolved = true
        }
        return true
    }
}

/// Minimal `NSFilePresenter` — required for `NSFileCoordinator`-coordinated
/// access to correctly serialize against OTHER presenters of the same URL,
/// and it doubles as this backend's external-change notification channel
/// (`onChange`, forwarded from `presentedItemDidChange()`).
final class iCloudFilePresenter: NSObject, NSFilePresenter {
    let presentedItemURL: URL?
    let presentedItemOperationQueue: OperationQueue = .main
    var onChange: (() -> Void)?

    init(presentedItemURL: URL) {
        self.presentedItemURL = presentedItemURL
    }

    func presentedItemDidChange() {
        onChange?()
    }
}
