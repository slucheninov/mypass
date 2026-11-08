import Foundation
import os.log

extension Notification.Name {
    /// Posted (on the main queue) after a backup was written, pruned or failed, so Settings can
    /// refresh its cached summary instead of touching the filesystem from `body`.
    static let vaultBackupsDidChange = Notification.Name("com.mypass.vaultBackupsDidChange")
}

/// How often a save may snapshot the previous on-disk vault into `backups/`.
enum VaultBackupInterval: String, CaseIterable, Identifiable {
    case everySave
    case tenMinutes
    case hourly
    case daily

    var id: String { rawValue }

    static let `default`: VaultBackupInterval = .everySave

    /// Minimum gap between two snapshots; `0` means "every save".
    var seconds: TimeInterval {
        switch self {
        case .everySave: return 0
        case .tenMinutes: return 10 * 60
        case .hourly: return 60 * 60
        case .daily: return 24 * 60 * 60
        }
    }
}

/// The user-facing backup settings, read from `UserDefaults` at the moment they are needed
/// (never captured at launch), so a change in Settings applies to the very next save.
enum VaultBackupSettings {
    static let countKey = "backupCount"
    static let intervalKey = "backupInterval"
    static let lastFailureMessageKey = "backupLastFailureMessage"
    static let lastFailureDateKey = "backupLastFailureDate"

    static let defaultCount = 10
    static let countRange = 1...50

    static func count(defaults: UserDefaults) -> Int {
        let stored = defaults.object(forKey: countKey) == nil ? defaultCount : defaults.integer(forKey: countKey)
        return min(max(stored, countRange.lowerBound), countRange.upperBound)
    }

    static func interval(defaults: UserDefaults) -> VaultBackupInterval {
        defaults.string(forKey: intervalKey).flatMap(VaultBackupInterval.init(rawValue:)) ?? .default
    }

    /// The one place the "is a snapshot due" rule lives, so the three stores cannot drift apart.
    /// The first write of a session always snapshots (the vault may have been changed outside
    /// the app since the last backup); after that the interval must have elapsed since the
    /// newest existing backup.
    static func isSnapshotDue(
        interval: VaultBackupInterval,
        newestBackupDate: Date?,
        now: Date,
        isFirstWriteOfSession: Bool
    ) -> Bool {
        if isFirstWriteOfSession || interval == .everySave { return true }
        guard let newestBackupDate else { return true }
        let elapsed = now.timeIntervalSince(newestBackupDate)
        // A negative gap means the newest backup is dated in the future (clock skew or a manual
        // clock change); waiting for it would suppress backups for as long as the skew, so
        // treat it as due.
        return elapsed < 0 || elapsed >= interval.seconds
    }
}

struct VaultBackupInfo: Identifiable, Equatable {
    let url: URL
    let date: Date
    let size: Int64
    var id: URL { url }
}

struct VaultBackupFailure: Equatable {
    let message: String
    let date: Date
}

/// Writes, rotates and lists the local pre-save snapshots of the vault file. Shared by
/// `VaultFileStore`, `LocalFileVaultStore` and `ICloudDriveVaultStore`.
///
/// Backups live in the app's own container (never in the vault's folder, never in iCloud or any
/// sync target), and a backup failure NEVER blocks the vault save: it is logged and recorded in
/// `UserDefaults` (message + date) for Settings to show, and cleared by the next success.
final class VaultBackupManager {
    private static let log = OSLog(subsystem: "com.mypass.app", category: "Backups")

    let directory: URL
    private let defaults: UserDefaults
    private let now: () -> Date
    private let removeFile: (URL) throws -> Void
    private let lock = NSLock()
    private var hasSnapshottedThisSession = false
    private var snapshotsSuppressed = false

    init(directory: URL, defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init,
         removeFile: @escaping (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }) {
        self.directory = directory
        self.defaults = defaults
        self.now = now
        self.removeFile = removeFile
    }

    /// Forget that this session already snapshotted, so the next write snapshots again.
    /// Called when the vault locks.
    func beginSession() {
        lock.lock()
        hasSnapshottedThisSession = false
        lock.unlock()
    }

    /// Best-effort, never throws. `readCurrent` is only invoked when a snapshot is due, so a
    /// skipped snapshot costs no read (relevant for evicted iCloud placeholders). The decision
    /// and the write each hold the lock, but the read does NOT: an iCloud coordinated read can
    /// block until its timeout, and `list()` (called from the main thread by Settings) shares
    /// this lock.
    func snapshotIfDue(_ readCurrent: () throws -> Data?) {
        lock.lock()
        let due = !snapshotsSuppressed && VaultBackupSettings.isSnapshotDue(
            interval: VaultBackupSettings.interval(defaults: defaults),
            newestBackupDate: listLocked().first?.date,
            now: now(),
            isFirstWriteOfSession: !hasSnapshottedThisSession
        )
        lock.unlock()
        guard due else { return }
        do {
            guard let data = try readCurrent() else { return }
            lock.lock()
            defer { lock.unlock() }
            guard !snapshotsSuppressed else { return }
            let written = try writeLocked(data)
            hasSnapshottedThisSession = true
            pruneBestEffortLocked(protecting: written)
            recordSuccess()
        } catch {
            recordFailure(error)
        }
    }

    /// Snapshots `data` regardless of the interval; throws if the write fails. Used before a
    /// restore, where "the current content is recoverable" is a hard requirement. It does NOT
    /// prune: at the count limit the oldest file may be the restore source, and deleting it
    /// before the restore write succeeds could leave the content in neither place. The caller
    /// calls `pruneNow()` once the restore has succeeded.
    @discardableResult
    func forceSnapshot(_ data: Data) throws -> URL {
        lock.lock()
        defer { lock.unlock() }
        do {
            let written = try writeLocked(data)
            hasSnapshottedThisSession = true
            recordSuccess()
            return written
        } catch {
            recordFailure(error)
            throw error
        }
    }

    /// Rotates down to the current `backupCount`. Best-effort. `protecting` is never deleted.
    func pruneNow(protecting: URL? = nil) {
        lock.lock()
        defer { lock.unlock() }
        pruneBestEffortLocked(protecting: protecting)
        notifyChanged()
    }

    /// Runs `body` with automatic snapshots off (restore snapshots explicitly, once, before it
    /// writes, so the write itself must not add a duplicate).
    func withSnapshotsSuppressed<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        snapshotsSuppressed = true
        lock.unlock()
        defer {
            lock.lock()
            snapshotsSuppressed = false
            lock.unlock()
        }
        return try body()
    }

    /// Newest first.
    func list() -> [VaultBackupInfo] {
        lock.lock()
        defer { lock.unlock() }
        return listLocked()
    }

    var lastFailure: VaultBackupFailure? {
        guard let message = defaults.string(forKey: VaultBackupSettings.lastFailureMessageKey) else { return nil }
        let seconds = defaults.double(forKey: VaultBackupSettings.lastFailureDateKey)
        return VaultBackupFailure(message: message, date: Date(timeIntervalSince1970: seconds))
    }

    // MARK: - Private (lock held)

    @discardableResult
    private func writeLocked(_ data: Data) throws -> URL {
        let fm = FileManager.default
        ensureDirectoryExists()
        let stamp = String(format: "%.6f", now().timeIntervalSince1970)
        var url = directory.appendingPathComponent("vault-\(stamp).kdbx")
        var suffix = 1
        while fm.fileExists(atPath: url.path) {
            suffix += 1
            url = directory.appendingPathComponent("vault-\(stamp)-\(suffix).kdbx")
        }
        // Own atomic scheme instead of `data.write(options: .atomic)`: on the GitHub macOS runner
        // Foundation's atomic write reported a spurious "a file with the same name already
        // exists" (EEXIST) against the backups folder, which silently dropped snapshots. A
        // hidden temp file in the same directory plus a rename is atomic on the same volume and
        // never touches the final name until the bytes are complete. `listLocked` ignores
        // `.vault-*.partial` because it only accepts names starting with `vault-`.
        let partial = directory.appendingPathComponent(".vault-\(UUID().uuidString).partial")
        do {
            try data.write(to: partial, options: .withoutOverwriting)
            try fm.moveItem(at: partial, to: url)
        } catch {
            try? fm.removeItem(at: partial)
            throw error
        }
        notifyChanged()
        return url
    }

    /// Makes sure `directory` exists, without ever failing the snapshot on its own.
    ///
    /// On the GitHub macos-26 runner `createDirectory(withIntermediateDirectories: true)` threw
    /// NSCocoaErrorDomain 516 (underlying POSIX 17, EEXIST) with the path set to the backups
    /// directory itself, which dropped the first snapshot of a fresh folder. So an existing
    /// directory is never re-created, and an EEXIST-style failure is not trusted either way:
    /// the write that follows is the authority (a missing directory or a file in its place
    /// makes it fail with its own error, which `recordFailure` records).
    private func ensureDirectoryExists() {
        let fm = FileManager.default
        if (try? directory.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { return }
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            var isDir: ObjCBool = false
            let exists = fm.fileExists(atPath: directory.path, isDirectory: &isDir)
            var isResolvedDir: ObjCBool = false
            let resolved = directory.resolvingSymlinksInPath()
            let resolvedExists = fm.fileExists(atPath: resolved.path, isDirectory: &isResolvedDir)
            let type = (try? fm.attributesOfItem(atPath: directory.path))?[.type] as? FileAttributeType
            let nsError = error as NSError
            os_log("Vault backup directory creation failed [domain=%{public}@ code=%ld] path=%{public}@ exists=%{public}@ isDir=%{public}@ resolved=%{public}@ resolvedExists=%{public}@ resolvedIsDir=%{public}@ type=%{public}@ standardized=%{public}@",
                   log: Self.log, type: .error, nsError.domain, nsError.code, directory.path,
                   String(exists), String(isDir.boolValue), resolved.path, String(resolvedExists),
                   String(isResolvedDir.boolValue), type?.rawValue ?? "none", directory.standardizedFileURL.path)
        }
    }

    /// A failed prune must not turn a successful snapshot into a failure (it would abort a
    /// restore whose safety snapshot is already on disk); it is logged and retried next time.
    ///
    /// `protecting` is the snapshot just written. Backups are ordered by their filename
    /// timestamp, so an older backup dated in the future (clock skew) would otherwise rank
    /// newer than the fresh one and the prune would delete the very snapshot that was just
    /// taken, for example the pre-restore safety copy at a retention of one.
    private func pruneBestEffortLocked(protecting: URL? = nil) {
        let all = listLocked()
        let others = all.filter { $0.url != protecting }
        let keep = max(VaultBackupSettings.count(defaults: defaults) - (protecting == nil ? 0 : 1), 0)
        guard others.count > keep else { return }
        for backup in others.dropFirst(keep) {
            do {
                try removeFile(backup.url)
            } catch {
                os_log("Vault backup prune failed: %{public}@", log: Self.log, type: .error,
                       (error as NSError).localizedDescription)
            }
        }
    }

    private func listLocked() -> [VaultBackupInfo] {
        let keys: [URLResourceKey] = [.creationDateKey, .fileSizeKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else {
            return []
        }
        return urls.compactMap { url -> VaultBackupInfo? in
            guard url.pathExtension == "kdbx", url.lastPathComponent.hasPrefix("vault-") else { return nil }
            let values = try? url.resourceValues(forKeys: Set(keys))
            // The timestamp in the name comes from the (injectable) clock, so it is the
            // authoritative order; the creation date is only the fallback for odd names.
            let date = Self.timestamp(fromFileName: url.lastPathComponent)
                ?? values?.creationDate
                ?? .distantPast
            return VaultBackupInfo(url: url, date: date, size: Int64(values?.fileSize ?? 0))
        }
        .sorted { $0.date > $1.date }
    }

    static func timestamp(fromFileName name: String) -> Date? {
        // Drop the extension first: its leading dot would otherwise be swallowed by the number scan.
        let body = name.dropFirst("vault-".count).dropLast(".kdbx".count)
        let digits = body.prefix { $0.isNumber || $0 == "." }
        guard let seconds = Double(digits) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    private func recordSuccess() {
        let hadFailure = defaults.object(forKey: VaultBackupSettings.lastFailureMessageKey) != nil
        defaults.removeObject(forKey: VaultBackupSettings.lastFailureMessageKey)
        defaults.removeObject(forKey: VaultBackupSettings.lastFailureDateKey)
        if hadFailure { notifyChanged() }
    }

    private func recordFailure(_ error: Error) {
        let nsError = error as NSError
        let message = nsError.localizedDescription
        // The user-facing message is the localized text; the log carries the evidence needed to
        // tell apart look-alike failures (domain, code, offending path, underlying error).
        let underlying = (nsError.userInfo[NSUnderlyingErrorKey] as? NSError).map { "\($0.domain)/\($0.code)" } ?? "none"
        let path = (nsError.userInfo[NSFilePathErrorKey] as? String) ?? nsError.userInfo[NSURLErrorKey].map { "\($0)" } ?? "none"
        os_log("Vault backup failed: %{public}@ [domain=%{public}@ code=%ld path=%{public}@ underlying=%{public}@]",
               log: Self.log, type: .error, message, nsError.domain, nsError.code, path, underlying)
        defaults.set(message, forKey: VaultBackupSettings.lastFailureMessageKey)
        defaults.set(now().timeIntervalSince1970, forKey: VaultBackupSettings.lastFailureDateKey)
        notifyChanged()
    }

    private func notifyChanged() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .vaultBackupsDidChange, object: nil)
        }
    }
}
