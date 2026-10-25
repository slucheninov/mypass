import XCTest
@testable import MyPass

final class InstanceLockTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("InstanceLockTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func acquire(_ dir: URL? = nil) -> InstanceLock.Attempt {
        InstanceLock.tryAcquire(directory: dir ?? directory)
    }

    func testFirstAcquireSucceedsAndASecondDescriptorInTheSameProcessIsRefused() throws {
        guard case .acquired(let lock) = acquire() else { return XCTFail("expected to acquire") }
        defer { lock.release() }
        XCTAssertTrue(lock.isHeld)
        // flock belongs to the open file description, so a second open() in the
        // SAME process conflicts exactly like a second process would.
        guard case .held = acquire() else { return XCTFail("a second descriptor must be refused") }
    }

    func testReleaseAndDeallocationFreeTheLock() throws {
        guard case .acquired(let first) = acquire() else { return XCTFail() }
        first.release()
        XCTAssertFalse(first.isHeld)
        first.release()  // idempotent

        func acquireAndDrop() -> Bool {
            guard case .acquired = acquire() else { return false }
            return true  // the lock is released when the temporary is deallocated
        }
        XCTAssertTrue(acquireAndDrop(), "released lock must be free")
        XCTAssertTrue(acquireAndDrop(), "deinit must release the lock")
    }

    func testDescriptorIsCloseOnExecAndNotInheritedByChildren() throws {
        guard case .acquired(let lock) = acquire() else { return XCTFail() }
        let flags = fcntl(lock.fileDescriptorForTesting, F_GETFD)
        XCTAssertNotEqual(flags & FD_CLOEXEC, 0, "the lock descriptor must be O_CLOEXEC")

        // A long-lived child spawned while the lock is held must not keep it
        // alive after the parent releases it.
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        defer { child.terminate(); child.waitUntilExit() }

        lock.release()
        guard case .acquired(let again) = acquire() else {
            return XCTFail("a child process must not inherit and pin the lock")
        }
        again.release()
    }

    func testLockFileIsPrivate() throws {
        guard case .acquired(let lock) = acquire() else { return XCTFail() }
        defer { lock.release() }
        let path = directory.appendingPathComponent(InstanceLock.defaultFileName).path
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testMissingDirectoryIsCreatedPrivately() throws {
        let fresh = directory.appendingPathComponent("nested-new")
        guard case .acquired(let lock) = acquire(fresh) else { return XCTFail("expected to create the directory") }
        defer { lock.release() }
        let attributes = try FileManager.default.attributesOfItem(atPath: fresh.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    func testSymlinkedLockFileIsRefused() throws {
        let target = directory.appendingPathComponent("elsewhere")
        FileManager.default.createFile(atPath: target.path, contents: Data())
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent(InstanceLock.defaultFileName), withDestinationURL: target
        )
        guard case .failed = acquire() else { return XCTFail("a symlink at the lock path must be refused") }
    }

    func testSymlinkedDirectoryIsRefused() throws {
        let real = directory.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let link = directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        guard case .failed = acquire(link) else { return XCTFail("a symlinked directory must be refused") }
    }

    func testHardLinkedLockFileIsRefused() throws {
        let path = directory.appendingPathComponent(InstanceLock.defaultFileName)
        FileManager.default.createFile(atPath: path.path, contents: Data(), attributes: [.posixPermissions: 0o600])
        try FileManager.default.linkItem(at: path, to: directory.appendingPathComponent("alias"))
        guard case .failed = acquire() else { return XCTFail("a hard-linked lock file must be refused") }
    }

    func testOwnWorldWritableDirectoryIsTightenedToThePrivateShape() throws {
        let open = directory.appendingPathComponent("open-dir")
        try FileManager.default.createDirectory(at: open, withIntermediateDirectories: false)
        chmod(open.path, 0o777)
        guard case .acquired(let lock) = acquire(open) else { return XCTFail("our own directory is tightened, not refused") }
        defer { lock.release() }
        XCTAssertEqual(try mode(of: open), 0o755, "only the group/other write bits are removed")
    }

    func testOwnPermissiveLockFileIsTightenedOnTheSameDescriptor() throws {
        let path = directory.appendingPathComponent(InstanceLock.defaultFileName)
        FileManager.default.createFile(atPath: path.path, contents: Data())
        chmod(path.path, 0o666)
        guard case .acquired(let lock) = acquire() else { return XCTFail("our own lock file is tightened, not refused") }
        defer { lock.release() }
        XCTAssertEqual(try mode(of: path), 0o600)
    }

    // MARK: - Directory creation and permissions (umask-independent)

    /// Runs `body` with the process umask set to 002 (group-writable by default), the
    /// setting under which `FileManager` creates 0775 directories.
    private func withUmask002(_ body: () throws -> Void) rethrows {
        let previous = umask(0o002)
        defer { umask(previous) }
        try body()
    }

    private func mode(of url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    func testOwnDirectoryCreatedGroupWritableByAnotherPartOfTheAppIsTightenedNotRefusedForever() throws {
        try withUmask002 {
            // What `FileManager.createDirectory` leaves behind under umask 002.
            let support = directory.appendingPathComponent("MyPass")
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: false)
            XCTAssertEqual(try mode(of: support), 0o775, "precondition: umask 002 makes the directory group-writable")

            guard case .acquired(let lock) = acquire(support) else {
                return XCTFail("the user's own group-writable directory must be tightened, not refused forever")
            }
            defer { lock.release() }
            XCTAssertEqual(try mode(of: support) & 0o022, 0, "group/other write must be removed")
            XCTAssertEqual(try mode(of: support) & 0o700, 0o700, "the owner keeps full access")
        }
    }

    func testMissingDirectoryChainIsCreatedPrivatelyEvenUnderUmask002() throws {
        try withUmask002 {
            let root = directory.appendingPathComponent("never-created-parent")
            let support = root.appendingPathComponent("MyPass")
            guard case .acquired(let lock) = acquire(support) else {
                return XCTFail("a missing parent (a fresh sandbox container) must be created")
            }
            defer { lock.release() }
            XCTAssertEqual(try mode(of: support), 0o700)
            XCTAssertEqual(try mode(of: root), 0o700, "directories created by the lock are private too")
            XCTAssertEqual(try mode(of: support.appendingPathComponent(InstanceLock.defaultFileName)), 0o600)
        }
    }

    func testForeignWorldWritableDirectoryIsRefusedAndNeverChmodded() throws {
        // /private/tmp is world-writable (sticky) and owned by root: shared, not ours.
        var before = stat()
        XCTAssertEqual(stat("/private/tmp", &before), 0)
        guard case .failed(let detail) = InstanceLock.tryAcquire(directory: URL(fileURLWithPath: "/private/tmp")) else {
            return XCTFail("a shared directory the user does not own must be refused")
        }
        XCTAssertFalse(detail.isEmpty)
        var after = stat()
        XCTAssertEqual(stat("/private/tmp", &after), 0)
        XCTAssertEqual(before.st_mode, after.st_mode, "never chmod a shared directory")
        XCTAssertFalse(FileManager.default.fileExists(atPath: "/private/tmp/" + InstanceLock.defaultFileName))
    }

    func testSymlinkedDirectoryTargetIsNeverChmodded() throws {
        let real = directory.appendingPathComponent("real-open")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: false)
        chmod(real.path, 0o775)
        let link = directory.appendingPathComponent("link-open")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        guard case .failed = acquire(link) else { return XCTFail("a symlinked directory must be refused") }
        XCTAssertEqual(try mode(of: real), 0o775, "the symlink target must not be modified")
    }

    func testErrorsNameThePathAndTheReason() throws {
        let file = directory.appendingPathComponent("a-file")
        FileManager.default.createFile(atPath: file.path, contents: Data())
        guard case .failed(let detail) = acquire(file) else { return XCTFail("a regular file is not a directory") }
        XCTAssertTrue(detail.contains(file.path), detail)
        guard case .failed(let foreign) = InstanceLock.tryAcquire(directory: URL(fileURLWithPath: "/Library")) else {
            return XCTFail("a directory owned by another user must be refused")
        }
        XCTAssertTrue(foreign.contains("/Library"), foreign)
        XCTAssertTrue(foreign.lowercased().contains("owned"), foreign)
    }
}
