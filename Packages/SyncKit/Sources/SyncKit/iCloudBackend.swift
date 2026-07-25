import Foundation

public enum iCloudBackendError: Error, Equatable {
    case containerUnavailable
    case downloadTimedOut
}

/// `StorageBackend` over an iCloud Drive ubiquity container. Every read/write
/// goes through `NSFileCoordinator` so overlapping access from other
/// processes (Finder, other MyPass instances, the file-provider daemon
/// itself) is safely serialized — per the design spec's iCloud backend
/// section ("NSFileCoordinator + NSFilePresenter; conflict-версии
/// (NSFileVersion) прогоняются через merge и удаляются"). The
/// conflict-version sweep itself is `MergeEngine`'s job once `SyncEngine`
/// downloads the current file (Tasks 4-6); this class's job is only to
/// guarantee coordinated, safe I/O and that a read never returns a
/// partially-downloaded placeholder (`ensureDownloaded`, called from
/// `read()`), per the design doc's "iCloud задерживает выгрузку" risk row.
public final class iCloudBackend: StorageBackend {
    private let containerURL: URL
    private let relativePath: String
    private let presenter: iCloudFilePresenter

    public init(relativePath: String, containerIdentifier: String? = nil) throws {
        guard let containerURL = FileManager.default.url(forUbiquityContainerIdentifier: containerIdentifier) else {
            throw iCloudBackendError.containerUnavailable
        }
        self.containerURL = containerURL
        self.relativePath = relativePath
        self.presenter = iCloudFilePresenter(
            presentedItemURL: Self.coordinatedURL(containerURL: containerURL, relativePath: relativePath)
        )
        NSFileCoordinator.addFilePresenter(presenter)
    }

    deinit {
        NSFileCoordinator.removeFilePresenter(presenter)
    }

    /// Fires when iCloud delivers a change to the presented file made by
    /// another device/process while this backend instance is alive — see
    /// this task's Interfaces note above. `nil` by default (Task 6's
    /// `SyncEngine` never needs this; only Task 12's app-level wiring does).
    public var onRemoteChange: (() -> Void)? {
        get { presenter.onChange }
        set { presenter.onChange = newValue }
    }

    /// Pure helper computing the file URL for `relativePath` inside
    /// `containerURL` without touching the filesystem, so it's directly
    /// unit-testable without a real iCloud container. `Documents` is the
    /// standard iCloud Drive-visible subdirectory of a ubiquity container —
    /// files placed directly at the container root are not shown in the
    /// Finder/iCloud Drive UI.
    static func coordinatedURL(containerURL: URL, relativePath: String) -> URL {
        containerURL.appendingPathComponent("Documents").appendingPathComponent(relativePath)
    }

    private var fileURL: URL {
        Self.coordinatedURL(containerURL: containerURL, relativePath: relativePath)
    }

    public func exists() throws -> Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
    }

    public func modificationDate() throws -> Date? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let values = try fileURL.resourceValues(forKeys: [.contentModificationDateKey])
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

        let initial = try fileURL.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
        if initial.ubiquitousItemDownloadingStatus == .current {
            return
        }

        try FileManager.default.startDownloadingUbiquitousItem(at: fileURL)

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let latest = try fileURL.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
            if latest.ubiquitousItemDownloadingStatus == .current {
                return
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        throw iCloudBackendError.downloadTimedOut
    }
}

/// Minimal `NSFilePresenter` — required for `NSFileCoordinator`-coordinated
/// access to correctly serialize against OTHER presenters of the same URL,
/// and it doubles as this backend's external-change notification channel
/// (`onChange`, forwarded from `presentedItemDidChange()`) per the design
/// doc's iCloud-upload-delay risk mitigation.
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
