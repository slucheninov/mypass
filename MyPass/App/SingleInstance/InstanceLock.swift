import Foundation
import Darwin

/// Process-lifetime exclusive `flock` on a file inside the app's own support
/// directory.
///
/// Scope, stated precisely: the lock is only visible to processes that resolve
/// the SAME file. `applicationSupportDirectory` differs between a sandboxed
/// build (inside the container) and an unsandboxed one (`~/Library/Application
/// Support`), so a signed sandboxed MyPass and an unsandboxed development copy
/// do NOT exclude each other through this file. Across scopes the guard relies
/// on process enumeration plus the cooperative takeover messages instead, and
/// is deliberately NOT described as one atomic global lock.
///
/// The descriptor is opened `O_CLOEXEC` and kept open for the lifetime of the
/// process (a `flock` belongs to the open file description, so it is released
/// by `close` or by process exit and is never inherited by a child). A second
/// descriptor opened in the SAME process conflicts too, which makes the
/// behaviour testable without spawning anything.
final class InstanceLock {
    enum Attempt {
        case acquired(InstanceLock)
        case held
        case failed(String)
    }

    static let defaultFileName = ".instance.lock"

    private var descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        release()
    }

    /// Releases the lock now. Idempotent.
    func release() {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }

    var isHeld: Bool { descriptor >= 0 }

    /// Exposed so tests can assert `FD_CLOEXEC`.
    var fileDescriptorForTesting: Int32 { descriptor }

    /// Never blocks. Refuses (as `.failed`) to use anything that is not a
    /// plain, current-user-owned file in a current-user-owned directory: a
    /// symlink or a hard link planted at the lock path must not redirect the
    /// open to some other file.
    ///
    /// Permissions never depend on the process umask. A directory this call
    /// creates is forced to 0700 on the descriptor it just verified. An
    /// existing directory or lock file that the current user owns but that is
    /// group- or other-writable (typically left by another part of the app
    /// under umask 002, where `FileManager` makes 0775 directories) is
    /// tightened with `fchmod` on that same verified descriptor instead of
    /// being refused forever. A directory the user does NOT own (a shared
    /// `Application Support`, `/tmp`) is refused and never chmodded.
    static func tryAcquire(directory: URL, fileName: String = defaultFileName) -> Attempt {
        let directoryPath = directory.path
        let directoryDescriptor: Int32
        switch openPrivateDirectory(directoryPath) {
        case .failure(let detail): return .failed(detail)
        case .success(let descriptor): directoryDescriptor = descriptor
        }
        defer { close(directoryDescriptor) }

        let path = (directoryPath as NSString).appendingPathComponent(fileName)
        // Opened relative to the verified directory descriptor, so the directory
        // cannot be swapped for another one between the checks and this open.
        let descriptor = openat(directoryDescriptor, fileName, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            return .failed("cannot open \(path): \(describe(errno))")
        }
        var fileInfo = stat()
        guard fstat(descriptor, &fileInfo) == 0,
              (fileInfo.st_mode & S_IFMT) == S_IFREG,
              fileInfo.st_uid == geteuid(),
              fileInfo.st_nlink == 1 else {
            close(descriptor)
            return .failed("\(path) is not a plain file owned by the current user with a single link")
        }
        if fileInfo.st_mode & 0o022 != 0 {
            // Ours (verified above) and group/other-writable: tighten the open file itself.
            guard fchmod(descriptor, 0o600) == 0 else {
                let reason = errno
                close(descriptor)
                return .failed("\(path) is writable by other users and could not be tightened: \(describe(reason)). Run: chmod 600 \"\(path)\"")
            }
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let reason = errno
            close(descriptor)
            return reason == EWOULDBLOCK ? .held : .failed("flock \(path): \(describe(reason))")
        }
        return .acquired(InstanceLock(descriptor: descriptor))
    }

    private enum DirectoryResult {
        case success(Int32)
        case failure(String)
    }

    /// Opens (creating when absent) the lock directory without following a
    /// symlink at its last component, verifies it on the open descriptor, and
    /// returns that descriptor.
    private static func openPrivateDirectory(_ path: String) -> DirectoryResult {
        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        var created = false
        var descriptor = open(path, flags)
        if descriptor < 0, errno == ENOENT {
            if let detail = createMissingChain(path) { return .failure(detail) }
            created = true
            descriptor = open(path, flags)
        }
        guard descriptor >= 0 else {
            let reason = errno
            if reason == ELOOP || reason == ENOTDIR {
                return .failure("\(path) is not a plain directory (\(describe(reason)))")
            }
            return .failure("cannot open \(path): \(describe(reason))")
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
            close(descriptor)
            return .failure("\(path) is not a plain directory")
        }
        guard info.st_uid == geteuid() else {
            close(descriptor)
            return .failure("\(path) is owned by another user (uid \(info.st_uid)), so it cannot hold MyPass's lock")
        }
        if created {
            // `mkdir` applied the umask; state the mode explicitly.
            guard fchmod(descriptor, 0o700) == 0 else {
                let reason = errno
                close(descriptor)
                return .failure("cannot make \(path) private: \(describe(reason))")
            }
        } else if info.st_mode & 0o022 != 0 {
            let tightened = mode_t(info.st_mode & 0o7755)
            guard fchmod(descriptor, tightened) == 0 else {
                let reason = errno
                close(descriptor)
                return .failure("\(path) is writable by other users and could not be tightened: \(describe(reason)). Run: chmod go-w \"\(path)\"")
            }
        }
        return .success(descriptor)
    }

    /// Creates `path` and any missing ancestors, each 0700, and returns a failure
    /// description (or `nil`). Existing ancestors are left exactly as they are;
    /// only components created here are touched.
    private static func createMissingChain(_ path: String) -> String? {
        var missing: [String] = []
        var current = path
        while !current.isEmpty, current != "/", access(current, F_OK) != 0 {
            guard errno == ENOENT else { break }
            missing.append(current)
            current = (current as NSString).deletingLastPathComponent
        }
        for component in missing.reversed() {
            if mkdir(component, 0o700) != 0, errno != EEXIST {
                return "cannot create \(component): \(describe(errno))"
            }
            // Components that are not the final one are ours too; make them private
            // without following a symlink raced into place.
            let descriptor = open(component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if descriptor >= 0 {
                var info = stat()
                if fstat(descriptor, &info) == 0, info.st_uid == geteuid() { _ = fchmod(descriptor, 0o700) }
                close(descriptor)
            }
        }
        return nil
    }

    private static func describe(_ code: Int32) -> String {
        "\(String(cString: strerror(code))) (errno \(code))"
    }
}
