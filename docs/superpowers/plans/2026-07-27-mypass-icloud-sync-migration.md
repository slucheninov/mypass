# MyPass iCloud Sync Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Spec:** `docs/superpowers/specs/2026-07-27-mypass-icloud-sync-migration-design.md`

**Goal:** Let MyPass mirror its vault into a user-picked folder inside iCloud Drive, with a guided first-connect flow that never loses data when the folder already holds a vault.

**Architecture:** `iCloudBackend` gains a second root mode (`.userFolder(bookmark:)`) resolved from a security-scoped bookmark, keeping all coordinated I/O, download materialisation and `NSFileVersion` conflict handling shared with the ubiquity-container path. A new backend-agnostic `VaultMigrationService` probes the remote and executes one of four reconciliation strategies. `VaultSession` exposes the flow on its serial persist queue, and a `SyncMigrationSheet` drives folder pick → probe → strategy → progress → restart prompt.

**Tech Stack:** Swift 5.10, macOS 14, SwiftUI, XCTest, XcodeGen, local SwiftPM packages (`MyPassKit`, `SyncKit`), `NSFileCoordinator` / `NSFileVersion` / security-scoped bookmarks.

## Global Constraints

- No change to `MyPass/MyPass.entitlements`; no `DEVELOPMENT_TEAM` added to `project.yml`. The ubiquity-container path stays unreachable in this build.
- Canonical vault location never changes: `~/Library/Application Support/MyPass/vault.kdbx` via `VaultFileStore`.
- Governing safety principle: **never destroy a copy before its replacement has been validated.**
- Wrong-password or invalid remote vault must abort with **zero writes on both sides** (byte-identical before/after).
- The resolved `StorageBackend`/`SyncEngine` are built once in `MyPassApp.init()`; `VaultSession.syncEngine` stays `let`. First-time iCloud setup therefore requires an **app restart**, stated explicitly in the UI.
- All new user-facing copy is English. The string "sign in to iCloud and enable iCloud Drive in System Settings" must not remain in production code as the explanation for missing entitlements.
- Cipher/compression stay `.aes256` / `.gzip` everywhere, matching `VaultSession`.
- `SyncBackendOption` raw values remain display strings (`"Local File"`, `"iCloud Drive"`, `"SFTP"`) — Phase 7 will migrate them; do not change them here.
- Every task ends with a passing test run and a commit.

---

## Tasks Overview

1. `ICloudDriveLocation` helpers
2. Dual-root `iCloudBackend`
3. `VaultMigrationService`
4. `VaultSession` integration
5. Resolver, checkpoint helpers, launch wiring
6. UI — migration sheet and honest Sync pane copy
7. RUN.md and full verification

### Task 1: `ICloudDriveLocation` helpers

**Files:**
- Create: `Packages/SyncKit/Sources/SyncKit/ICloudDriveLocation.swift`
- Test (create): `Packages/SyncKit/Tests/SyncKitTests/ICloudDriveLocationTests.swift`

**Interfaces:**
- Consumes: Nothing — first task
- Produces: `public enum ICloudDriveLocation`, `public static var iCloudDriveRootURL: URL?`, `public static func isInsideICloudDrive(_ url: URL) -> Bool`, `static func isDescendantOrSame(_ url: URL, of root: URL) -> Bool`

The spec named these `defaultICloudDriveRootURL` / `isURLInsideICloudDrive`; they become members of an `ICloudDriveLocation` namespace instead. The spec's "or nil if absent" existence check is deliberately dropped: inside the app sandbox `FileManager.fileExists` on `~/Library/Mobile Documents/com~apple~CloudDocs` returns `false` until the user grants access via the open panel, so an existence check would make the open-panel prefill useless. The real home directory must come from `getpwuid(getuid())` because `NSHomeDirectory()` and `homeDirectoryForCurrentUser` both return the sandbox container path.

Corrected after implementation: the root URL includes the `Library` segment — the path is `~/Library/Mobile Documents/com~apple~CloudDocs`.

- [ ] **Step 1: Write the failing test file**

Create `Packages/SyncKit/Tests/SyncKitTests/ICloudDriveLocationTests.swift` with the test class below. SyncKit package tests use `import XCTest` and `@testable import SyncKit`. Temp dirs are not needed here — these tests use fixed paths and the live `iCloudDriveRootURL`.

```swift
import XCTest
@testable import SyncKit

final class ICloudDriveLocationTests: XCTestCase {
    func testRootURLEndsWithMobileDocumentsCloudDocs() throws {
        let root = try XCTUnwrap(ICloudDriveLocation.iCloudDriveRootURL)
        XCTAssertTrue(root.path.hasSuffix("/Library/Mobile Documents/com~apple~CloudDocs"), root.path)
        XCTAssertTrue(root.path.hasPrefix("/"), root.path)
    }

    func testRootURLIsNotInsideTheSandboxContainer() throws {
        let root = try XCTUnwrap(ICloudDriveLocation.iCloudDriveRootURL)
        XCTAssertFalse(root.path.contains("/Library/Containers/"), root.path)
    }

    func testIsDescendantOrSameAcceptsTheRootItself() {
        let root = URL(fileURLWithPath: "/Users/tester/Library/Mobile Documents/com~apple~CloudDocs")
        XCTAssertTrue(ICloudDriveLocation.isDescendantOrSame(root, of: root))
    }

    func testIsDescendantOrSameAcceptsNestedFolder() {
        let root = URL(fileURLWithPath: "/Users/tester/Library/Mobile Documents/com~apple~CloudDocs")
        let nested = root.appendingPathComponent("MyPass").appendingPathComponent("vaults")
        XCTAssertTrue(ICloudDriveLocation.isDescendantOrSame(nested, of: root))
    }

    func testIsDescendantOrSameNormalizesRelativeComponents() {
        let root = URL(fileURLWithPath: "/Users/tester/Library/Mobile Documents/com~apple~CloudDocs")
        let noisy = URL(fileURLWithPath: "/Users/tester/Library/Mobile Documents/com~apple~CloudDocs/MyPass/../MyPass")
        XCTAssertTrue(ICloudDriveLocation.isDescendantOrSame(noisy, of: root))
    }

    func testIsDescendantOrSameRejectsSiblingFolder() {
        let root = URL(fileURLWithPath: "/Users/tester/Library/Mobile Documents/com~apple~CloudDocs")
        let sibling = URL(fileURLWithPath: "/Users/tester/Library/Mobile Documents/com~apple~Keynote")
        XCTAssertFalse(ICloudDriveLocation.isDescendantOrSame(sibling, of: root))
    }

    func testIsDescendantOrSameRejectsParentFolder() {
        let root = URL(fileURLWithPath: "/Users/tester/Library/Mobile Documents/com~apple~CloudDocs")
        let parent = URL(fileURLWithPath: "/Users/tester/Library/Mobile Documents")
        XCTAssertFalse(ICloudDriveLocation.isDescendantOrSame(parent, of: root))
    }

    func testIsDescendantOrSameRejectsPrefixLookalikeName() {
        let root = URL(fileURLWithPath: "/Users/tester/Library/Mobile Documents/com~apple~CloudDocs")
        let lookalike = URL(fileURLWithPath: "/Users/tester/Library/Mobile Documents/com~apple~CloudDocsBackup")
        XCTAssertFalse(ICloudDriveLocation.isDescendantOrSame(lookalike, of: root))
    }

    func testIsInsideICloudDriveAcceptsTheResolvedRoot() throws {
        let root = try XCTUnwrap(ICloudDriveLocation.iCloudDriveRootURL)
        XCTAssertTrue(ICloudDriveLocation.isInsideICloudDrive(root.appendingPathComponent("MyPass")))
    }

    func testIsInsideICloudDriveRejectsTempDirectory() {
        XCTAssertFalse(ICloudDriveLocation.isInsideICloudDrive(URL(fileURLWithPath: "/tmp/mypass")))
    }
}
```

- [ ] **Step 2: Run the tests and observe the expected compile failure**

```bash
cd Packages/SyncKit && swift test --filter ICloudDriveLocationTests
```

Expected result: compile error — `cannot find 'ICloudDriveLocation' in scope`.

- [ ] **Step 3: Implement `ICloudDriveLocation.swift`**

Create `Packages/SyncKit/Sources/SyncKit/ICloudDriveLocation.swift`:

```swift
import Foundation
import Darwin

/// Locates the user's iCloud Drive folder (`~/Library/Mobile
/// Documents/com~apple~CloudDocs`). That folder is synced by the system file
/// provider and a sandboxed app may reach it through a user-selected
/// security-scoped bookmark, so it needs no iCloud container entitlement and
/// no paid Apple Developer account — unlike a real ubiquity container.
public enum ICloudDriveLocation {
    static let mobileDocumentsDirectoryName = "Mobile Documents"
    static let cloudDocsDirectoryName = "com~apple~CloudDocs"

    /// The conventional iCloud Drive path for the current user, computed
    /// without touching the filesystem. Used to pre-fill the folder open
    /// panel and to warn when a chosen folder sits outside iCloud Drive.
    ///
    /// No existence check: inside the sandbox, reading that path is denied
    /// until the user grants access through the open panel, so a check would
    /// report "absent" for every user who has not completed setup yet.
    public static var iCloudDriveRootURL: URL? {
        realHomeDirectoryURL?
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent(mobileDocumentsDirectoryName, isDirectory: true)
            .appendingPathComponent(cloudDocsDirectoryName, isDirectory: true)
    }

    /// `true` when `url` is the iCloud Drive root itself or anything beneath it.
    public static func isInsideICloudDrive(_ url: URL) -> Bool {
        guard let root = iCloudDriveRootURL else { return false }
        return isDescendantOrSame(url, of: root)
    }

    /// Pure path-prefix comparison, split out so it is unit-testable without
    /// a real iCloud Drive folder on the machine running the tests.
    static func isDescendantOrSame(_ url: URL, of root: URL) -> Bool {
        let urlComponents = url.standardizedFileURL.pathComponents
        let rootComponents = root.standardizedFileURL.pathComponents
        guard urlComponents.count >= rootComponents.count else { return false }
        return Array(urlComponents.prefix(rootComponents.count)) == rootComponents
    }

    /// `NSHomeDirectory()` and `FileManager.homeDirectoryForCurrentUser` both
    /// return the *container* path in a sandboxed app, so the real home
    /// directory has to be read from the password database.
    static var realHomeDirectoryURL: URL? {
        guard let passwd = getpwuid(getuid()), let directory = passwd.pointee.pw_dir else {
            return nil
        }
        return URL(fileURLWithPath: String(cString: directory), isDirectory: true)
    }
}
```

- [ ] **Step 4: Re-run the tests and confirm they pass**

```bash
cd Packages/SyncKit && swift test --filter ICloudDriveLocationTests
```

Expected result: all tests in `ICloudDriveLocationTests` pass.

- [ ] **Step 5: Commit**

```bash
git add Packages/SyncKit/Sources/SyncKit/ICloudDriveLocation.swift Packages/SyncKit/Tests/SyncKitTests/ICloudDriveLocationTests.swift
git commit -m "feat(synckit): add iCloud Drive folder location helpers"
```

### Task 2: dual-root `iCloudBackend`

**Files:**
- Modify: `Packages/SyncKit/Sources/SyncKit/iCloudBackend.swift`
- Test (modify): `Packages/SyncKit/Tests/SyncKitTests/iCloudBackendTests.swift`

**Interfaces:**
- Consumes: `ICloudDriveLocation.iCloudDriveRootURL` from Task 1
- Produces: `public enum iCloudRoot { case ubiquityContainer(identifier: String?); case userFolder(bookmark: Data) }`; `public init(root: iCloudRoot, relativePath: String) throws`; `public convenience init(relativePath: String = "vault.kdbx", containerIdentifier: String? = nil) throws`; `public static func createFolderBookmark(for folderURL: URL) throws -> Data`; `iCloudBackendError` gains `.folderBookmarkUnresolvable` and `.folderUnavailable`; `static func coordinatedURL(folderURL: URL, relativePath: String) -> URL`

The convenience initialiser keeps its existing `containerIdentifier:` parameter because `iCloudBackendUngatedTests.testInitThrowsContainerUnavailableWithBogusIdentifier` calls `iCloudBackend(relativePath:containerIdentifier:)` and must keep compiling unchanged. `.withSecurityScope` is the app-scoped bookmark flavour once `com.apple.security.files.bookmarks.app-scope` is in the entitlements, so the new root reuses exactly the option set `LocalFolderBackend` already uses. A `false` return from `startAccessingSecurityScopedResource()` must NOT be an error: in an unsandboxed `swift test` runner it returns `false` while plain access still works, which is why `LocalFolderBackend` falls back the same way. `.folderUnavailable` is reserved for "resolved path is not an existing directory". `ensureDownloaded` must skip non-ubiquitous files. `startDownloadingUbiquitousItem(at:)` throws for a path the iCloud file provider does not manage, so without a `URLResourceKey.isUbiquitousItemKey` guard every `read()` against a plain folder (including all ungated tests) would fail.

Because `fileURL` becomes a stored `let`, `URL`'s per-instance resource-value cache makes `modificationDate()` and `ensureDownloaded()`'s status polling read stale values. Every `resourceValues(forKeys:)` read therefore goes through the private `freshResourceValues(forKeys:)` helper, which reads through a copy whose cache was just cleared.

- [ ] **Step 1: Append the failing `iCloudBackendUserFolderTests` class to the test file**

Add the following class to the end of `Packages/SyncKit/Tests/SyncKitTests/iCloudBackendTests.swift`. SyncKit package tests use `import XCTest` and `@testable import SyncKit`. Temp dirs use `FileManager.default.temporaryDirectory.appendingPathComponent("SyncKitICloudUserFolderTests-\(UUID().uuidString)")` in `setUpWithError()` and are removed in `tearDownWithError()`.

```swift
/// `.userFolder` root tests. These need no iCloud account: the root is a
/// temporary directory reached through a real security-scoped bookmark, and
/// every code path except `ensureDownloaded`'s materialisation poll is shared
/// with the ubiquity-container root.
final class iCloudBackendUserFolderTests: XCTestCase {
    var tempDir: URL!
    var bookmark: Data!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SyncKitICloudUserFolderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        bookmark = try iCloudBackend.createFolderBookmark(for: tempDir)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testCoordinatedURLForUserFolderHasNoDocumentsComponent() {
        let folder = URL(fileURLWithPath: "/tmp/fake-icloud-drive-folder")
        let url = iCloudBackend.coordinatedURL(folderURL: folder, relativePath: "vault.kdbx")
        XCTAssertEqual(url.path, "/tmp/fake-icloud-drive-folder/vault.kdbx")
    }

    func testExistsIsFalseBeforeAnyWrite() throws {
        let backend = try iCloudBackend(root: .userFolder(bookmark: bookmark), relativePath: "vault.kdbx")
        XCTAssertFalse(try backend.exists())
        XCTAssertNil(try backend.read())
        XCTAssertNil(try backend.modificationDate())
    }

    func testWriteThenReadRoundTripsExactBytes() throws {
        let backend = try iCloudBackend(root: .userFolder(bookmark: bookmark), relativePath: "vault.kdbx")
        let payload = Data("icloud-user-folder-round-trip".utf8)
        try backend.write(payload)
        XCTAssertTrue(try backend.exists())
        XCTAssertEqual(try backend.read(), payload)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("vault.kdbx").path))
    }

    func testWriteCreatesIntermediateDirectoriesForNestedRelativePath() throws {
        let backend = try iCloudBackend(root: .userFolder(bookmark: bookmark), relativePath: "MyPass/vault.kdbx")
        try backend.write(Data("nested".utf8))
        XCTAssertEqual(try backend.read(), Data("nested".utf8))
    }

    func testSecondWriteOverwritesFirstAndAdvancesModificationDate() throws {
        let backend = try iCloudBackend(root: .userFolder(bookmark: bookmark), relativePath: "vault.kdbx")
        try backend.write(Data("v1".utf8))
        let firstDate = try XCTUnwrap(backend.modificationDate())

        Thread.sleep(forTimeInterval: 1.1)
        try backend.write(Data("v2".utf8))
        let secondDate = try XCTUnwrap(backend.modificationDate())

        XCTAssertEqual(try backend.read(), Data("v2".utf8))
        XCTAssertGreaterThan(secondDate, firstDate)
    }

    func testModificationDateReflectsExternalFileChangeOnSameBackendInstance() throws {
        let backend = try iCloudBackend(root: .userFolder(bookmark: bookmark), relativePath: "vault.kdbx")
        try backend.write(Data("initial".utf8))
        let firstDate = try XCTUnwrap(backend.modificationDate())

        Thread.sleep(forTimeInterval: 1.1)
        let externalPath = tempDir.appendingPathComponent("vault.kdbx")
        try Data("external-update".utf8).write(to: externalPath)

        let secondDate = try XCTUnwrap(backend.modificationDate())
        XCTAssertGreaterThan(secondDate, firstDate)
    }

    func testEnsureDownloadedIsANoOpForANonUbiquitousFile() throws {
        let backend = try iCloudBackend(root: .userFolder(bookmark: bookmark), relativePath: "vault.kdbx")
        try backend.write(Data("plain local file, not managed by iCloud".utf8))
        XCTAssertNoThrow(try backend.ensureDownloaded(timeout: 1))
    }

    func testResolveConflictVersionsReturnsFalseWhenNoConflictsExist() throws {
        let backend = try iCloudBackend(root: .userFolder(bookmark: bookmark), relativePath: "vault.kdbx")
        try backend.write(Data("no conflicts here".utf8))

        var mergeCalled = false
        let resolved = try backend.resolveConflictVersions { current, _ in
            mergeCalled = true
            return current
        }

        XCTAssertFalse(resolved)
        XCTAssertFalse(mergeCalled)
    }

    func testInitThrowsFolderBookmarkUnresolvableForEmptyBookmark() {
        XCTAssertThrowsError(try iCloudBackend(root: .userFolder(bookmark: Data()), relativePath: "vault.kdbx")) { error in
            XCTAssertEqual(error as? iCloudBackendError, .folderBookmarkUnresolvable)
        }
    }

    func testInitThrowsFolderBookmarkUnresolvableForGarbageBookmark() {
        let garbage = Data([0x00, 0x01, 0x02, 0x03, 0xFF, 0xFE])
        XCTAssertThrowsError(try iCloudBackend(root: .userFolder(bookmark: garbage), relativePath: "vault.kdbx")) { error in
            XCTAssertEqual(error as? iCloudBackendError, .folderBookmarkUnresolvable)
        }
    }

    func testInitThrowsFolderUnavailableWhenBookmarkPointsAtAFile() throws {
        let fileURL = tempDir.appendingPathComponent("not-a-folder.txt")
        try Data("x".utf8).write(to: fileURL)
        let fileBookmark = try iCloudBackend.createFolderBookmark(for: fileURL)

        XCTAssertThrowsError(try iCloudBackend(root: .userFolder(bookmark: fileBookmark), relativePath: "vault.kdbx")) { error in
            XCTAssertEqual(error as? iCloudBackendError, .folderUnavailable)
        }
    }

    func testUbiquityConvenienceInitStillThrowsContainerUnavailableWithoutEntitlements() {
        XCTAssertThrowsError(
            try iCloudBackend(relativePath: "vault.kdbx", containerIdentifier: "iCloud.com.mypass.definitely-not-a-real-container-id")
        ) { error in
            XCTAssertEqual(error as? iCloudBackendError, .containerUnavailable)
        }
    }
}
```

- [ ] **Step 2: Run the new tests and observe the expected compile failure**

```bash
cd Packages/SyncKit && swift test --filter iCloudBackendUserFolderTests
```

Expected result: compile error — `cannot find 'iCloudRoot' in scope` / no `createFolderBookmark`.

- [ ] **Step 3: Replace `iCloudBackend` with the dual-root implementation**

Replace the top of `Packages/SyncKit/Sources/SyncKit/iCloudBackend.swift` through the end of the `iCloudBackend` class with the code below. The `iCloudFilePresenter` class at the bottom of the existing file stays exactly as it is and is included unchanged at the tail of this block.

```swift
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
```

- [ ] **Step 4: Append the gated integration test and update the skip message**

Inside the existing gated `iCloudBackendTests` class, add:

```swift
    func testUserFolderRootRoundTripsInsideRealICloudDrive() throws {
        let root = try XCTUnwrap(ICloudDriveLocation.iCloudDriveRootURL)
        let folder = root.appendingPathComponent("MyPassICloudBackendTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let bookmark = try iCloudBackend.createFolderBookmark(for: folder)
        let backend = try iCloudBackend(root: .userFolder(bookmark: bookmark), relativePath: "vault.kdbx")

        XCTAssertFalse(try backend.exists())
        let payload = Data("real-icloud-drive-folder-round-trip".utf8)
        try backend.write(payload)
        XCTAssertTrue(try backend.exists())
        XCTAssertEqual(try backend.read(), payload)
        XCTAssertNotNil(try backend.modificationDate())
    }
```

Update the gated class's `XCTSkipUnless` message to:

```swift
try XCTSkipUnless(ProcessInfo.processInfo.environment["MYPASS_ICLOUD_INTEGRATION_TESTS"] == "1", "set MYPASS_ICLOUD_INTEGRATION_TESTS=1 (on a machine signed into iCloud with Drive enabled) to run tests against a real ubiquity container and a real iCloud Drive folder")
```

- [ ] **Step 5: Re-run the user-folder tests and confirm they pass**

```bash
cd Packages/SyncKit && swift test --filter iCloudBackendUserFolderTests
```

Expected result: all tests in `iCloudBackendUserFolderTests` pass.

- [ ] **Step 6: Run the full SyncKit package to prove nothing regressed**

```bash
cd Packages/SyncKit && swift test
```

Expected result: all SyncKit tests pass (gated tests skip unless `MYPASS_ICLOUD_INTEGRATION_TESTS=1`).

- [ ] **Step 7: Commit**

```bash
git add Packages/SyncKit/Sources/SyncKit/iCloudBackend.swift Packages/SyncKit/Tests/SyncKitTests/iCloudBackendTests.swift
git commit -m "feat(synckit): support user-picked iCloud Drive folder as iCloudBackend root"
```

### Task 3: `VaultMigrationService`

**Files:**
- Create: `MyPass/Storage/VaultMigrationService.swift`
- Test (create): `MyPassTests/VaultMigrationServiceTests.swift`

**Interfaces:**
- Consumes: `iCloudBackend`/`StorageBackend`/`SyncEngine`/`InMemorySyncCheckpointStore` from SyncKit; `VaultFileStore(directory:backupCount:)` with `load() throws -> Data?` and `save(data:) throws`; `KdbxDatabase.open(data:password:) throws`, `KdbxDatabase.save(password:cipher:compression:) throws -> Data`
- Produces: `VaultMigrationStrategy`, `VaultMigrationTargetProbe`, `VaultMigrationOutcome`, `VaultMigrationError`, `VaultMigrationService(fileStore:cipher:compression:)`, `probe(remote:)`, `migrate(local:password:remote:strategy:)`

The merge strategy uses `InMemorySyncCheckpointStore(initialCheckpoint: .distantPast)` rather than `nil`: `SyncEngine` treats "remote modification date equals checkpoint" as "remote unchanged, just re-upload local", and a remote whose `modificationDate()` returns `nil` would compare equal to a `nil` checkpoint and silently overwrite the remote vault without merging. `.distantPast` can never match a real modification date, forcing the download-and-merge branch. `VaultMigrationError` is not `Equatable` because two cases carry an `Error` payload; tests match with `guard case`. `serializedVaultInvalid` is an addition to the spec's error list, covering the spec's "validate non-empty KDBX header" instruction for the seed/overwrite paths. The service never writes locally before validating the replacement: adopt parses before saving, merge saves only after `SyncEngine.sync` returned.

- [ ] **Step 1: Write the failing test file**

Create `MyPassTests/VaultMigrationServiceTests.swift`. App tests use `import XCTest`, `import MyPassKit`, `import SyncKit`, and `@testable import MyPass`. Temp dirs use `FileManager.default.temporaryDirectory.appendingPathComponent("VaultMigrationServiceTests-\(UUID().uuidString)")` in `setUpWithError()` and are removed in `tearDownWithError()`.

```swift
import XCTest
import MyPassKit
import SyncKit
@testable import MyPass

final class VaultMigrationServiceTests: XCTestCase {
    var tempDir: URL!
    var fileStore: VaultFileStore!
    let password = "correct-horse"

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VaultMigrationServiceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        fileStore = VaultFileStore(directory: tempDir)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Fixtures

    private func makeEntry(title: String, timestamp: Date = Date()) -> KdbxEntry {
        var entry = KdbxEntry(
            uuid: UUID(),
            iconID: 0,
            fields: [],
            creationTime: timestamp,
            lastModificationTime: timestamp,
            lastAccessTime: timestamp,
            locationChanged: timestamp,
            history: []
        )
        entry.title = title
        return entry
    }

    private func makeDatabase(rootUUID: UUID, entryTitles: [String], timestamp: Date = Date()) -> KdbxDatabase {
        let rootGroup = KdbxGroup(
            uuid: rootUUID,
            name: "MyPass",
            iconID: 0,
            creationTime: timestamp,
            lastModificationTime: timestamp,
            locationChanged: timestamp,
            entries: entryTitles.map { makeEntry(title: $0, timestamp: timestamp) },
            subgroups: []
        )
        return KdbxDatabase(rootGroup: rootGroup, deletedObjects: [])
    }

    private func titles(inRemote remote: StorageBackend, password: String) throws -> Set<String> {
        let data = try XCTUnwrap(try remote.read())
        let database = try KdbxDatabase.open(data: data, password: password)
        return Set(database.rootGroup.entries.map { $0.title })
    }

    private func titlesOnDisk(password: String) throws -> Set<String> {
        let data = try XCTUnwrap(try fileStore.load())
        let database = try KdbxDatabase.open(data: data, password: password)
        return Set(database.rootGroup.entries.map { $0.title })
    }

    private var backupFileURLs: [URL] {
        let backups = tempDir.appendingPathComponent("backups")
        return (try? FileManager.default.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil)) ?? []
    }

    // MARK: - Probe

    func testProbeReportsEmptyRemote() throws {
        let service = VaultMigrationService(fileStore: fileStore)
        let probe = try service.probe(remote: InMemoryStorageBackend())
        XCTAssertEqual(probe, VaultMigrationTargetProbe(exists: false, modificationDate: nil, byteCount: nil))
    }

    func testProbeReportsSizeAndDateForOccupiedRemote() throws {
        let remoteDatabase = makeDatabase(rootUUID: UUID(), entryTitles: ["Remote Only"])
        let remoteData = try remoteDatabase.save(password: password, cipher: .aes256, compression: .gzip)
        let remote = InMemoryStorageBackend(initialData: remoteData)

        let service = VaultMigrationService(fileStore: fileStore)
        let probe = try service.probe(remote: remote)

        XCTAssertTrue(probe.exists)
        XCTAssertEqual(probe.byteCount, remoteData.count)
        XCTAssertNotNil(probe.modificationDate)
    }

    func testProbeNeverNeedsThePassword() throws {
        let remoteDatabase = makeDatabase(rootUUID: UUID(), entryTitles: ["Remote Only"])
        let remoteData = try remoteDatabase.save(password: "a-totally-different-password", cipher: .aes256, compression: .gzip)
        let remote = InMemoryStorageBackend(initialData: remoteData)

        let service = VaultMigrationService(fileStore: fileStore)
        XCTAssertTrue(try service.probe(remote: remote).exists)
    }

    // MARK: - seedRemote

    func testSeedRemoteUploadsLocalVaultAndLeavesLocalFileUntouched() throws {
        let local = makeDatabase(rootUUID: UUID(), entryTitles: ["Local Only"])
        try fileStore.save(data: try local.save(password: password, cipher: .aes256, compression: .gzip))
        let localBytesBefore = try XCTUnwrap(try fileStore.load())
        let remote = InMemoryStorageBackend()

        let service = VaultMigrationService(fileStore: fileStore)
        let outcome = try service.migrate(local: local, password: password, remote: remote, strategy: .seedRemote)

        XCTAssertTrue(outcome.remoteWritten)
        XCTAssertFalse(outcome.localReplaced)
        XCTAssertNil(outcome.mergedDatabase)
        XCTAssertEqual(try titles(inRemote: remote, password: password), ["Local Only"])
        XCTAssertEqual(try fileStore.load(), localBytesBefore)
    }

    func testSeedRemoteReportsRemoteWriteFailureAndLeavesLocalUntouched() throws {
        struct SimulatedRemoteFailure: Error {}
        let local = makeDatabase(rootUUID: UUID(), entryTitles: ["Local Only"])
        try fileStore.save(data: try local.save(password: password, cipher: .aes256, compression: .gzip))
        let localBytesBefore = try XCTUnwrap(try fileStore.load())
        let remote = InMemoryStorageBackend()
        remote.writeError = SimulatedRemoteFailure()

        let service = VaultMigrationService(fileStore: fileStore)
        XCTAssertThrowsError(
            try service.migrate(local: local, password: password, remote: remote, strategy: .seedRemote)
        ) { error in
            guard case VaultMigrationError.remoteWriteFailed = error else {
                return XCTFail("expected remoteWriteFailed, got \(error)")
            }
        }
        XCTAssertEqual(try fileStore.load(), localBytesBefore)
        XCTAssertNil(try remote.read())
    }

    // MARK: - merge

    func testMergeKeepsEntriesFromBothSides() throws {
        let rootUUID = UUID()
        let local = makeDatabase(rootUUID: rootUUID, entryTitles: ["Local Only"])
        try fileStore.save(data: try local.save(password: password, cipher: .aes256, compression: .gzip))
        let remoteDatabase = makeDatabase(rootUUID: rootUUID, entryTitles: ["Remote Only"])
        let remote = InMemoryStorageBackend(
            initialData: try remoteDatabase.save(password: password, cipher: .aes256, compression: .gzip)
        )

        let service = VaultMigrationService(fileStore: fileStore)
        let outcome = try service.migrate(local: local, password: password, remote: remote, strategy: .merge)

        let merged = try XCTUnwrap(outcome.mergedDatabase)
        XCTAssertEqual(Set(merged.rootGroup.entries.map { $0.title }), ["Local Only", "Remote Only"])
        XCTAssertTrue(outcome.remoteWritten)
        XCTAssertTrue(outcome.localReplaced)
        XCTAssertEqual(try titlesOnDisk(password: password), ["Local Only", "Remote Only"])
        XCTAssertEqual(try titles(inRemote: remote, password: password), ["Local Only", "Remote Only"])
    }

    func testMergeLeavesLocalFileUntouchedWhenTheSyncPassFails() throws {
        struct SimulatedRemoteFailure: Error {}
        let rootUUID = UUID()
        let local = makeDatabase(rootUUID: rootUUID, entryTitles: ["Local Only"])
        try fileStore.save(data: try local.save(password: password, cipher: .aes256, compression: .gzip))
        let localBytesBefore = try XCTUnwrap(try fileStore.load())
        let remoteDatabase = makeDatabase(rootUUID: rootUUID, entryTitles: ["Remote Only"])
        let remote = InMemoryStorageBackend(
            initialData: try remoteDatabase.save(password: password, cipher: .aes256, compression: .gzip)
        )
        remote.writeError = SimulatedRemoteFailure()

        let service = VaultMigrationService(fileStore: fileStore)
        XCTAssertThrowsError(
            try service.migrate(local: local, password: password, remote: remote, strategy: .merge)
        )
        XCTAssertEqual(try fileStore.load(), localBytesBefore)
        XCTAssertTrue(backupFileURLs.isEmpty)
    }

    func testMergeWithWrongRemotePasswordLeavesBothSidesByteIdentical() throws {
        let rootUUID = UUID()
        let local = makeDatabase(rootUUID: rootUUID, entryTitles: ["Local Only"])
        try fileStore.save(data: try local.save(password: password, cipher: .aes256, compression: .gzip))
        let localBytesBefore = try XCTUnwrap(try fileStore.load())
        let remoteDatabase = makeDatabase(rootUUID: rootUUID, entryTitles: ["Remote Only"])
        let remoteBytesBefore = try remoteDatabase.save(
            password: "a-totally-different-password", cipher: .aes256, compression: .gzip
        )
        let remote = InMemoryStorageBackend(initialData: remoteBytesBefore)

        let service = VaultMigrationService(fileStore: fileStore)
        XCTAssertThrowsError(
            try service.migrate(local: local, password: password, remote: remote, strategy: .merge)
        ) { error in
            guard case VaultMigrationError.remotePasswordMismatch = error else {
                return XCTFail("expected remotePasswordMismatch, got \(error)")
            }
        }
        XCTAssertEqual(try fileStore.load(), localBytesBefore)
        XCTAssertEqual(try remote.read(), remoteBytesBefore)
        XCTAssertTrue(backupFileURLs.isEmpty)
    }

    // MARK: - adoptRemote

    func testAdoptRemoteReplacesLocalAndSnapshotsPreviousStateIntoBackups() throws {
        let local = makeDatabase(rootUUID: UUID(), entryTitles: ["Local Only"])
        try fileStore.save(data: try local.save(password: password, cipher: .aes256, compression: .gzip))
        let localBytesBefore = try XCTUnwrap(try fileStore.load())
        let remoteDatabase = makeDatabase(rootUUID: UUID(), entryTitles: ["Remote Only"])
        let remoteBytes = try remoteDatabase.save(password: password, cipher: .aes256, compression: .gzip)
        let remote = InMemoryStorageBackend(initialData: remoteBytes)

        let service = VaultMigrationService(fileStore: fileStore)
        let outcome = try service.migrate(local: local, password: password, remote: remote, strategy: .adoptRemote)

        XCTAssertTrue(outcome.localReplaced)
        XCTAssertFalse(outcome.remoteWritten)
        XCTAssertEqual(
            Set(try XCTUnwrap(outcome.mergedDatabase).rootGroup.entries.map { $0.title }),
            ["Remote Only"]
        )
        XCTAssertEqual(try titlesOnDisk(password: password), ["Remote Only"])
        XCTAssertEqual(try remote.read(), remoteBytes)

        let backups = backupFileURLs
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(backups.first)), localBytesBefore)
    }

    func testAdoptRemoteWithWrongPasswordLeavesBothSidesByteIdentical() throws {
        let local = makeDatabase(rootUUID: UUID(), entryTitles: ["Local Only"])
        try fileStore.save(data: try local.save(password: password, cipher: .aes256, compression: .gzip))
        let localBytesBefore = try XCTUnwrap(try fileStore.load())
        let remoteDatabase = makeDatabase(rootUUID: UUID(), entryTitles: ["Remote Only"])
        let remoteBytesBefore = try remoteDatabase.save(
            password: "a-totally-different-password", cipher: .aes256, compression: .gzip
        )
        let remote = InMemoryStorageBackend(initialData: remoteBytesBefore)

        let service = VaultMigrationService(fileStore: fileStore)
        XCTAssertThrowsError(
            try service.migrate(local: local, password: password, remote: remote, strategy: .adoptRemote)
        ) { error in
            guard case VaultMigrationError.remotePasswordMismatch = error else {
                return XCTFail("expected remotePasswordMismatch, got \(error)")
            }
        }
        XCTAssertEqual(try fileStore.load(), localBytesBefore)
        XCTAssertEqual(try remote.read(), remoteBytesBefore)
        XCTAssertTrue(backupFileURLs.isEmpty)
    }

    func testAdoptRemoteRejectsBytesThatAreNotAVault() throws {
        let local = makeDatabase(rootUUID: UUID(), entryTitles: ["Local Only"])
        try fileStore.save(data: try local.save(password: password, cipher: .aes256, compression: .gzip))
        let localBytesBefore = try XCTUnwrap(try fileStore.load())
        let remote = InMemoryStorageBackend(initialData: Data("this is definitely not a kdbx file".utf8))

        let service = VaultMigrationService(fileStore: fileStore)
        XCTAssertThrowsError(
            try service.migrate(local: local, password: password, remote: remote, strategy: .adoptRemote)
        ) { error in
            guard case VaultMigrationError.remoteNotAValidVault = error else {
                return XCTFail("expected remoteNotAValidVault, got \(error)")
            }
        }
        XCTAssertEqual(try fileStore.load(), localBytesBefore)
        XCTAssertTrue(backupFileURLs.isEmpty)
    }

    // MARK: - overwriteRemote

    func testOverwriteRemoteDiscardsRemoteContent() throws {
        let local = makeDatabase(rootUUID: UUID(), entryTitles: ["Local Only"])
        try fileStore.save(data: try local.save(password: password, cipher: .aes256, compression: .gzip))
        let localBytesBefore = try XCTUnwrap(try fileStore.load())
        let remoteDatabase = makeDatabase(rootUUID: UUID(), entryTitles: ["Remote Only"])
        let remote = InMemoryStorageBackend(
            initialData: try remoteDatabase.save(password: password, cipher: .aes256, compression: .gzip)
        )

        let service = VaultMigrationService(fileStore: fileStore)
        let outcome = try service.migrate(local: local, password: password, remote: remote, strategy: .overwriteRemote)

        XCTAssertTrue(outcome.remoteWritten)
        XCTAssertFalse(outcome.localReplaced)
        XCTAssertEqual(try titles(inRemote: remote, password: password), ["Local Only"])
        XCTAssertEqual(try fileStore.load(), localBytesBefore)
    }

    // MARK: - Signature helper

    func testLooksLikeKdbxAcceptsSerializedVaultAndRejectsGarbage() throws {
        let data = try makeDatabase(rootUUID: UUID(), entryTitles: ["Local Only"])
            .save(password: password, cipher: .aes256, compression: .gzip)
        XCTAssertTrue(VaultMigrationService.looksLikeKdbx(data))
        XCTAssertFalse(VaultMigrationService.looksLikeKdbx(Data("nope".utf8)))
        XCTAssertFalse(VaultMigrationService.looksLikeKdbx(Data()))
    }
}
```

- [ ] **Step 2: Run the tests and observe the expected compile failure**

```bash
./scripts/generate.sh && xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/VaultMigrationServiceTests
```

Expected result: compile error — `cannot find 'VaultMigrationService' in scope`.

- [ ] **Step 3: Implement `VaultMigrationService.swift`**

Create `MyPass/Storage/VaultMigrationService.swift`:

```swift
import Foundation
import MyPassKit
import SyncKit

/// How a local vault and a remote mirror are reconciled the first time they
/// are connected.
enum VaultMigrationStrategy: String, CaseIterable, Identifiable {
    /// Remote is empty: upload the local vault, leave local untouched.
    case seedRemote
    /// Remote holds a vault: run one `SyncEngine` pass and keep everything
    /// from both sides. The default offer.
    case merge
    /// Remote holds a vault: replace the local working copy with it.
    case adoptRemote
    /// Remote holds a vault: replace it with the local working copy.
    case overwriteRemote

    var id: String { rawValue }
}

/// What a remote backend currently holds, established without ever decrypting
/// it — probing needs no vault password.
struct VaultMigrationTargetProbe: Equatable {
    let exists: Bool
    let modificationDate: Date?
    let byteCount: Int?
}

struct VaultMigrationOutcome {
    let strategy: VaultMigrationStrategy
    /// Non-nil when the local in-memory database was replaced, so the caller
    /// can republish it and avoid showing stale entries.
    let mergedDatabase: KdbxDatabase?
    let remoteWritten: Bool
    let localReplaced: Bool
}

enum VaultMigrationError: Error {
    case vaultLocked
    case remoteUnreadable(underlying: Error)
    case remoteNotAValidVault
    case remotePasswordMismatch
    case remoteWriteFailed(underlying: Error)
    case localWriteFailed(underlying: Error)
    /// Serializing the in-memory vault produced bytes that are not a KDBX
    /// file. Nothing is written anywhere when this is thrown.
    case serializedVaultInvalid
}

/// Connects a local vault to a remote mirror for the first time. Backend
/// agnostic: it accepts any `StorageBackend`, so the same logic later serves
/// the SFTP and local-folder connect flows. No UI, no UserDefaults.
///
/// Governing rule for every branch: never destroy a copy before its
/// replacement has been validated.
final class VaultMigrationService {
    private let fileStore: VaultFileStore
    private let cipher: KdbxCipher
    private let compression: KdbxCompression

    init(fileStore: VaultFileStore, cipher: KdbxCipher = .aes256, compression: KdbxCompression = .gzip) {
        self.fileStore = fileStore
        self.cipher = cipher
        self.compression = compression
    }

    /// Reports what the remote currently holds. Reads the whole file rather
    /// than just stat-ing it: `StorageBackend` exposes no size API, and for an
    /// iCloud folder the read also forces an evicted file to materialise, so a
    /// download timeout surfaces here instead of mid-migration.
    func probe(remote: StorageBackend) throws -> VaultMigrationTargetProbe {
        do {
            guard try remote.exists() else {
                return VaultMigrationTargetProbe(exists: false, modificationDate: nil, byteCount: nil)
            }
            let modificationDate = try remote.modificationDate()
            let data = try remote.read()
            return VaultMigrationTargetProbe(
                exists: true,
                modificationDate: modificationDate,
                byteCount: data?.count
            )
        } catch {
            throw VaultMigrationError.remoteUnreadable(underlying: error)
        }
    }

    func migrate(
        local: KdbxDatabase,
        password: String,
        remote: StorageBackend,
        strategy: VaultMigrationStrategy
    ) throws -> VaultMigrationOutcome {
        switch strategy {
        case .seedRemote, .overwriteRemote:
            return try uploadLocal(local, password: password, remote: remote, strategy: strategy)
        case .adoptRemote:
            return try adoptRemote(password: password, remote: remote)
        case .merge:
            return try mergeBothSides(local: local, password: password, remote: remote)
        }
    }

    /// `seedRemote` and `overwriteRemote` differ only in when the UI offers
    /// them; the mechanics are identical. Serialize and validate in memory
    /// first, and never touch the local file.
    private func uploadLocal(
        _ local: KdbxDatabase,
        password: String,
        remote: StorageBackend,
        strategy: VaultMigrationStrategy
    ) throws -> VaultMigrationOutcome {
        let data: Data
        do {
            data = try local.save(password: password, cipher: cipher, compression: compression)
        } catch {
            throw VaultMigrationError.serializedVaultInvalid
        }
        guard Self.looksLikeKdbx(data) else {
            throw VaultMigrationError.serializedVaultInvalid
        }
        do {
            try remote.write(data)
        } catch {
            throw VaultMigrationError.remoteWriteFailed(underlying: error)
        }
        return VaultMigrationOutcome(
            strategy: strategy,
            mergedDatabase: nil,
            remoteWritten: true,
            localReplaced: false
        )
    }

    /// Parses the remote bytes with the session password BEFORE any local
    /// write, so a wrong password or a non-vault file leaves both sides
    /// byte-identical. `VaultFileStore.save` rotates the previous local vault
    /// into `backups/`, so the replaced copy stays recoverable.
    private func adoptRemote(password: String, remote: StorageBackend) throws -> VaultMigrationOutcome {
        let remoteData: Data?
        do {
            remoteData = try remote.read()
        } catch {
            throw VaultMigrationError.remoteUnreadable(underlying: error)
        }
        guard let remoteData, Self.looksLikeKdbx(remoteData) else {
            throw VaultMigrationError.remoteNotAValidVault
        }

        let remoteDatabase: KdbxDatabase
        do {
            remoteDatabase = try KdbxDatabase.open(data: remoteData, password: password)
        } catch KdbxDatabaseError.wrongPassword {
            throw VaultMigrationError.remotePasswordMismatch
        } catch {
            throw VaultMigrationError.remoteNotAValidVault
        }

        do {
            try fileStore.save(data: remoteData)
        } catch {
            throw VaultMigrationError.localWriteFailed(underlying: error)
        }
        return VaultMigrationOutcome(
            strategy: .adoptRemote,
            mergedDatabase: remoteDatabase,
            remoteWritten: false,
            localReplaced: true
        )
    }

    /// One `SyncEngine` pass, reusing the app's merge semantics instead of a
    /// bespoke merge. The checkpoint store is deliberately in-memory and
    /// seeded with `.distantPast`: a persisted checkpoint could short-circuit
    /// this one-off pass into a plain re-upload, and a `nil` seed would do the
    /// same for any remote whose `modificationDate()` is `nil`.
    private func mergeBothSides(
        local: KdbxDatabase,
        password: String,
        remote: StorageBackend
    ) throws -> VaultMigrationOutcome {
        let engine = SyncEngine(
            remote: remote,
            checkpointStore: InMemorySyncCheckpointStore(initialCheckpoint: .distantPast)
        )
        let result: SyncResult
        do {
            result = try engine.sync(local: local, password: password, cipher: cipher, compression: compression)
        } catch KdbxDatabaseError.wrongPassword {
            throw VaultMigrationError.remotePasswordMismatch
        } catch is KdbxDatabaseError {
            throw VaultMigrationError.remoteNotAValidVault
        } catch {
            throw VaultMigrationError.remoteWriteFailed(underlying: error)
        }

        guard case .merged(let mergedDatabase) = result else {
            // `.uploadedInitial` / `.uploadedDirect`: nothing came back from
            // the remote, so the local working copy is already correct.
            return VaultMigrationOutcome(
                strategy: .merge,
                mergedDatabase: nil,
                remoteWritten: true,
                localReplaced: false
            )
        }

        let mergedData: Data
        do {
            mergedData = try mergedDatabase.save(password: password, cipher: cipher, compression: compression)
        } catch {
            throw VaultMigrationError.localWriteFailed(underlying: error)
        }
        do {
            try fileStore.save(data: mergedData)
        } catch {
            throw VaultMigrationError.localWriteFailed(underlying: error)
        }
        return VaultMigrationOutcome(
            strategy: .merge,
            mergedDatabase: mergedDatabase,
            remoteWritten: true,
            localReplaced: true
        )
    }

    /// Cheap KDBX4 signature check (`0x9AA2D903` `0xB54BFB67`, little-endian),
    /// so obvious non-vault bytes are rejected before paying for an Argon2id
    /// key derivation.
    static func looksLikeKdbx(_ data: Data) -> Bool {
        guard data.count >= 12 else { return false }
        let signature: [UInt8] = [0x03, 0xD9, 0xA2, 0x9A, 0x67, 0xFB, 0x4B, 0xB5]
        return Array(data.prefix(8)) == signature
    }
}
```

- [ ] **Step 4: Re-run the tests and confirm they pass**

```bash
./scripts/generate.sh && xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/VaultMigrationServiceTests
```

Expected result: all tests in `VaultMigrationServiceTests` pass.

- [ ] **Step 5: Commit**

```bash
git add MyPass/Storage/VaultMigrationService.swift MyPassTests/VaultMigrationServiceTests.swift
git commit -m "feat: add backend-agnostic vault migration service"
```

### Task 4: `VaultSession` integration

**Files:**
- Modify: `MyPass/State/VaultSession.swift`
- Test (modify): `MyPassTests/VaultSessionTests.swift`

**Interfaces:**
- Consumes: everything Task 3 produced
- Produces: `VaultSession.hasPendingTouchAccessPersist: Bool`, `VaultSession.probeMigrationTarget(remote:completion:)`, `VaultSession.performMigration(to:strategy:completion:)`

The spec sketched these as synchronous throwing methods, but migration performs two or three Argon2id derivations (64 MiB, 3 iterations) plus remote I/O that can block for the 10-second iCloud download timeout, so a synchronous version would freeze the main thread and make the sheet's progress step impossible. Both methods therefore validate preconditions on the calling (main) thread, run the work on the existing serial `persistQueue` — the same queue as `persist(_:)`, which is what keeps migration from racing an in-flight autosave or background sync — and deliver their result on the main queue. `performMigration` cancels the debounced `touchAccessPersistWorkItem` synchronously before dispatching, so the caller can rely on it being cancelled the moment the call returns.

- [ ] **Step 1: Append the failing migration tests**

Add the following tests to `MyPassTests/VaultSessionTests.swift`. App tests use `import XCTest`, `import MyPassKit`, `import SyncKit`, and `@testable import MyPass`.

```swift
    // MARK: - Migration

    private func makeMigrationEntry(title: String) -> KdbxEntry {
        let now = Date()
        var entry = KdbxEntry(
            uuid: UUID(),
            iconID: 0,
            fields: [],
            creationTime: now,
            lastModificationTime: now,
            lastAccessTime: now,
            locationChanged: now,
            history: []
        )
        entry.title = title
        return entry
    }

    func testPerformMigrationIsRejectedWhileLocked() {
        let session = VaultSession(fileStore: fileStore)
        let expectation = expectation(description: "completion")

        session.performMigration(to: InMemoryStorageBackend(), strategy: .seedRemote) { result in
            switch result {
            case .success:
                XCTFail("expected failure while locked")
            case .failure(let error):
                guard case VaultMigrationError.vaultLocked = error else {
                    return XCTFail("expected vaultLocked, got \(error)")
                }
            }
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5)
    }

    func testProbeMigrationTargetIsRejectedWhileLocked() {
        let session = VaultSession(fileStore: fileStore)
        let expectation = expectation(description: "completion")

        session.probeMigrationTarget(remote: InMemoryStorageBackend()) { result in
            switch result {
            case .success:
                XCTFail("expected failure while locked")
            case .failure(let error):
                guard case VaultMigrationError.vaultLocked = error else {
                    return XCTFail("expected vaultLocked, got \(error)")
                }
            }
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5)
    }

    func testPerformMigrationCancelsPendingTouchAccessPersist() throws {
        let session = VaultSession(fileStore: fileStore)
        try session.unlock(password: "correct-horse")

        let entry = makeMigrationEntry(title: "Touched Entry")
        session.mutate { database in
            database.rootGroup.entries.append(entry)
        }
        session.touchAccess(entryID: entry.uuid)
        XCTAssertTrue(session.hasPendingTouchAccessPersist)

        let expectation = expectation(description: "completion")
        session.performMigration(to: InMemoryStorageBackend(), strategy: .seedRemote) { result in
            if case .failure(let error) = result {
                XCTFail("expected success, got \(error)")
            }
            expectation.fulfill()
        }
        XCTAssertFalse(session.hasPendingTouchAccessPersist)

        wait(for: [expectation], timeout: 30)
    }

    func testPerformMigrationSeedRemoteUploadsWithoutChangingInMemoryState() throws {
        let session = VaultSession(fileStore: fileStore)
        try session.unlock(password: "correct-horse")
        session.mutate { database in
            database.rootGroup.entries.append(self.makeMigrationEntry(title: "Local Only"))
        }

        let remote = InMemoryStorageBackend()
        let expectation = expectation(description: "completion")
        session.performMigration(to: remote, strategy: .seedRemote) { result in
            switch result {
            case .success(let outcome):
                XCTAssertTrue(outcome.remoteWritten)
                XCTAssertFalse(outcome.localReplaced)
                XCTAssertNil(outcome.mergedDatabase)
            case .failure(let error):
                XCTFail("expected success, got \(error)")
            }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 60)

        guard case .unlocked(let db) = session.state else {
            return XCTFail("expected unlocked state")
        }
        XCTAssertEqual(Set(db.rootGroup.entries.map { $0.title }), ["Local Only"])

        let remoteData = try XCTUnwrap(try remote.read())
        let remoteDatabase = try KdbxDatabase.open(data: remoteData, password: "correct-horse")
        XCTAssertEqual(Set(remoteDatabase.rootGroup.entries.map { $0.title }), ["Local Only"])
    }

    func testPerformMigrationAdoptRemotePublishesTheAdoptedDatabase() throws {
        let session = VaultSession(fileStore: fileStore)
        try session.unlock(password: "correct-horse")
        session.mutate { database in
            database.rootGroup.entries.append(self.makeMigrationEntry(title: "Local Only"))
        }

        var remoteEntry = makeMigrationEntry(title: "From Remote")
        remoteEntry.title = "From Remote"
        let remoteRoot = KdbxGroup(
            uuid: UUID(),
            name: "MyPass",
            iconID: 0,
            creationTime: Date(),
            lastModificationTime: Date(),
            locationChanged: Date(),
            entries: [remoteEntry],
            subgroups: []
        )
        let remoteDatabase = KdbxDatabase(rootGroup: remoteRoot, deletedObjects: [])
        let remote = InMemoryStorageBackend(
            initialData: try remoteDatabase.save(password: "correct-horse", cipher: .aes256, compression: .gzip)
        )

        let expectation = expectation(description: "completion")
        session.performMigration(to: remote, strategy: .adoptRemote) { result in
            switch result {
            case .success(let outcome):
                XCTAssertTrue(outcome.localReplaced)
                XCTAssertFalse(outcome.remoteWritten)
            case .failure(let error):
                XCTFail("expected success, got \(error)")
            }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 60)

        guard case .unlocked(let db) = session.state else {
            return XCTFail("expected unlocked state")
        }
        XCTAssertEqual(Set(db.rootGroup.entries.map { $0.title }), ["From Remote"])
    }

    func testProbeMigrationTargetReportsOccupiedRemote() throws {
        let session = VaultSession(fileStore: fileStore)
        try session.unlock(password: "correct-horse")

        let remoteDatabase = KdbxDatabase(
            rootGroup: KdbxGroup(
                uuid: UUID(),
                name: "MyPass",
                iconID: 0,
                creationTime: Date(),
                lastModificationTime: Date(),
                locationChanged: Date(),
                entries: [makeMigrationEntry(title: "From Remote")],
                subgroups: []
            ),
            deletedObjects: []
        )
        let remoteData = try remoteDatabase.save(password: "correct-horse", cipher: .aes256, compression: .gzip)
        let remote = InMemoryStorageBackend(initialData: remoteData)

        let expectation = expectation(description: "completion")
        session.probeMigrationTarget(remote: remote) { result in
            switch result {
            case .success(let probe):
                XCTAssertTrue(probe.exists)
                XCTAssertEqual(probe.byteCount, remoteData.count)
                XCTAssertNotNil(probe.modificationDate)
            case .failure(let error):
                XCTFail("expected success, got \(error)")
            }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 30)
    }
```

- [ ] **Step 2: Run the tests and observe the expected compile failure**

```bash
./scripts/generate.sh && xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/VaultSessionTests
```

Expected result: compile error — `hasPendingTouchAccessPersist`, `probeMigrationTarget`, or `performMigration` not found on `VaultSession`.

- [ ] **Step 3: Add `hasPendingTouchAccessPersist` to `VaultSession`**

Place this property immediately after the `touchAccessPersistWorkItem` declaration in `MyPass/State/VaultSession.swift`:

```swift
    /// `true` while a debounced `touchAccess` persist is still waiting to run.
    /// Exposed so tests can assert that starting a migration cancels it.
    var hasPendingTouchAccessPersist: Bool {
        guard let touchAccessPersistWorkItem else { return false }
        return !touchAccessPersistWorkItem.isCancelled
    }
```

- [ ] **Step 4: Add `probeMigrationTarget` and `performMigration` after `triggerBackgroundSync()`**

```swift
    /// Reports what a candidate remote currently holds, so the connect flow can
    /// offer the right reconciliation strategies. Runs on `persistQueue` because
    /// probing an iCloud folder performs a coordinated read that can block for
    /// the download timeout, and completes on the main queue.
    func probeMigrationTarget(
        remote: StorageBackend,
        completion: @escaping (Result<VaultMigrationTargetProbe, Error>) -> Void
    ) {
        guard case .unlocked = state, sessionPassword != nil else {
            DispatchQueue.main.async { completion(.failure(VaultMigrationError.vaultLocked)) }
            return
        }
        let service = VaultMigrationService(fileStore: fileStore)
        persistQueue.async {
            let result = Result { try service.probe(remote: remote) }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Connects this vault to `remote` using `strategy`. Must be called from the
    /// main thread: preconditions and the debounce cancellation happen
    /// synchronously, then the Argon2id derivations and remote I/O run on
    /// `persistQueue` so migration cannot interleave with an autosave or a
    /// background sync pass. When the strategy replaced the local database, the
    /// published state is updated on the main queue before `completion` runs, so
    /// the UI never shows stale entries.
    func performMigration(
        to remote: StorageBackend,
        strategy: VaultMigrationStrategy,
        completion: @escaping (Result<VaultMigrationOutcome, Error>) -> Void
    ) {
        guard case .unlocked(let db) = state, let password = sessionPassword else {
            DispatchQueue.main.async { completion(.failure(VaultMigrationError.vaultLocked)) }
            return
        }

        touchAccessPersistWorkItem?.cancel()
        touchAccessPersistWorkItem = nil

        // Same deep copy `persist(_:)` takes: the background work must not see
        // the live, still-mutable group tree.
        let snapshot = KdbxDatabase(
            rootGroup: db.rootGroup.deepCopy(),
            deletedObjects: db.deletedObjects,
            recycleBinGroupUUID: db.recycleBinGroupUUID
        )
        let service = VaultMigrationService(fileStore: fileStore)

        persistQueue.async {
            let result = Result {
                try service.migrate(
                    local: snapshot,
                    password: password,
                    remote: remote,
                    strategy: strategy
                )
            }
            DispatchQueue.main.async { [weak self] in
                if case .success(let outcome) = result, let mergedDatabase = outcome.mergedDatabase {
                    self?.state = .unlocked(mergedDatabase)
                }
                completion(result)
            }
        }
    }
```

- [ ] **Step 5: Re-run the tests and confirm they pass**

```bash
./scripts/generate.sh && xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/VaultSessionTests
```

Expected result: all tests in `VaultSessionTests` pass.

- [ ] **Step 6: Commit**

```bash
git add MyPass/State/VaultSession.swift MyPassTests/VaultSessionTests.swift
git commit -m "feat: run vault migration through the session persist queue"
```

### Task 5: resolver, checkpoint helpers, launch wiring

**Files:**
- Modify: `MyPass/State/SyncBackendResolver.swift`
- Modify: `MyPass/MyPassApp.swift`
- Test (modify): `MyPassTests/SettingsViewSyncBackendTests.swift`

**Interfaces:**
- Consumes: Task 2's `iCloudBackend(root:relativePath:)` and `createFolderBookmark(for:)`
- Produces: `SyncBackendResolver.resolveICloudBackend(bookmarkData:relativePath:) -> iCloudBackend?`, `SyncBackendResolver.checkpointKey(for:) -> String`, `SyncBackendResolver.clearCheckpoint(for:defaults:)`; new UserDefaults key `syncICloudFolderBookmark`

`resolveICloudBackend` gains a required `bookmarkData:` parameter and keeps the "never throw, return nil for unconfigured or unusable state" contract the local-folder resolver already has, so a bad persisted bookmark can never crash launch. The checkpoint key moves out of `MyPassApp` into the resolver so the migration sheet can clear the same key without duplicating the string literal. `syncICloudFolderBookmark` is deliberately separate from `syncLocalFolderBookmark` so both backends stay configured independently.

- [ ] **Step 1: Append the failing resolver tests**

Add the following tests to `MyPassTests/SettingsViewSyncBackendTests.swift`. App tests use `import XCTest`, `import SyncKit`, and `@testable import MyPass`. The test class already has a `tempDir` from `setUpWithError()`.

```swift
    func testResolveICloudBackendReturnsWorkingBackendForValidFolderBookmark() throws {
        let bookmark = try iCloudBackend.createFolderBookmark(for: tempDir)
        let resolved = try XCTUnwrap(SyncBackendResolver.resolveICloudBackend(bookmarkData: bookmark))

        XCTAssertFalse(try resolved.exists())
        try resolved.write(Data("icloud-resolver-round-trip".utf8))
        XCTAssertEqual(try resolved.read(), Data("icloud-resolver-round-trip".utf8))
    }

    func testResolveICloudBackendReturnsNilForMissingBookmark() {
        XCTAssertNil(SyncBackendResolver.resolveICloudBackend(bookmarkData: nil))
        XCTAssertNil(SyncBackendResolver.resolveICloudBackend(bookmarkData: Data()))
    }

    func testResolveICloudBackendReturnsNilForInvalidBookmarkDataWithoutCrashing() {
        let garbage = Data([0x00, 0x01, 0x02, 0x03, 0xFF, 0xFE])
        XCTAssertNil(SyncBackendResolver.resolveICloudBackend(bookmarkData: garbage))
    }

    func testCheckpointKeyIsNamespacedPerBackend() {
        XCTAssertEqual(SyncBackendResolver.checkpointKey(for: .iCloud), "com.mypass.sync.checkpoint.iCloud Drive")
        XCTAssertEqual(SyncBackendResolver.checkpointKey(for: .local), "com.mypass.sync.checkpoint.Local File")
        XCTAssertNotEqual(
            SyncBackendResolver.checkpointKey(for: .iCloud),
            SyncBackendResolver.checkpointKey(for: .sftp)
        )
    }

    func testClearCheckpointRemovesOnlyThatBackendsCheckpoint() throws {
        let suiteName = "com.mypass.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        defaults.set(1.0, forKey: SyncBackendResolver.checkpointKey(for: .iCloud))
        defaults.set(2.0, forKey: SyncBackendResolver.checkpointKey(for: .local))

        SyncBackendResolver.clearCheckpoint(for: .iCloud, defaults: defaults)

        XCTAssertNil(defaults.object(forKey: SyncBackendResolver.checkpointKey(for: .iCloud)))
        XCTAssertNotNil(defaults.object(forKey: SyncBackendResolver.checkpointKey(for: .local)))
    }
```

- [ ] **Step 2: Run the tests and observe the expected failure**

```bash
./scripts/generate.sh && xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/SettingsViewSyncBackendTests
```

Expected result: compile error — `resolveICloudBackend(bookmarkData:)` or `checkpointKey(for:)` not found.

- [ ] **Step 3: Replace `resolveICloudBackend` and add checkpoint helpers in `SyncBackendResolver.swift`**

Replace the existing `resolveICloudBackend` with:

```swift
    /// Resolves the iCloud backend from the folder bookmark stored under
    /// `syncICloudFolderBookmark`. Returns `nil` (never throws) when no folder
    /// has been chosen yet or the bookmark no longer resolves — the same
    /// "never crash app launch on bad or missing external state" contract as
    /// the local-folder resolver above. `MyPassApp` then attaches no
    /// `SyncEngine` at all, which is the correct pre-setup state, and Settings
    /// surfaces the warning inline.
    ///
    /// Note the deliberate absence of a ubiquity-container fallback: without
    /// `com.apple.developer.icloud-container-identifiers` (a restricted
    /// entitlement needing a paid Apple Developer account),
    /// `url(forUbiquityContainerIdentifier:)` always returns nil, so falling
    /// back would only ever produce a misleading failure.
    static func resolveICloudBackend(bookmarkData: Data?, relativePath: String = "vault.kdbx") -> iCloudBackend? {
        guard let bookmarkData, !bookmarkData.isEmpty else { return nil }
        return try? iCloudBackend(root: .userFolder(bookmark: bookmarkData), relativePath: relativePath)
    }

    /// UserDefaults key holding `SyncEngine`'s last-known remote modification
    /// date for `option`. Single definition shared by app launch wiring and by
    /// the migration flow, which clears it so the first sync after a restart
    /// performs a full merge instead of trusting a checkpoint taken against a
    /// different remote.
    static func checkpointKey(for option: SyncBackendOption) -> String {
        "com.mypass.sync.checkpoint.\(option.rawValue)"
    }

    static func clearCheckpoint(for option: SyncBackendOption, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: checkpointKey(for: option))
    }
```

- [ ] **Step 4: Update `MyPassApp.init()` — iCloud backend resolution**

Replace:

```swift
            case .iCloud:
                backend = SyncBackendResolver.resolveICloudBackend()
```

with:

```swift
            case .iCloud:
                backend = SyncBackendResolver.resolveICloudBackend(
                    bookmarkData: defaults.data(forKey: "syncICloudFolderBookmark")
                )
```

- [ ] **Step 5: Update `MyPassApp.init()` — checkpoint store key**

Replace:

```swift
            let checkpointStore = UserDefaultsSyncCheckpointStore(
                key: "com.mypass.sync.checkpoint.\(syncBackendOption.rawValue)"
            )
```

with:

```swift
            let checkpointStore = UserDefaultsSyncCheckpointStore(
                key: SyncBackendResolver.checkpointKey(for: syncBackendOption)
            )
```

- [ ] **Step 6: Re-run the tests and confirm they pass**

```bash
./scripts/generate.sh && xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/SettingsViewSyncBackendTests
```

Expected result: all tests in `SettingsViewSyncBackendTests` pass.

- [ ] **Step 7: Commit**

```bash
git add MyPass/State/SyncBackendResolver.swift MyPass/MyPassApp.swift MyPassTests/SettingsViewSyncBackendTests.swift
git commit -m "feat: resolve the iCloud backend from a stored folder bookmark"
```

### Task 6: UI — migration sheet and honest Sync pane copy

**Files:**
- Create: `MyPass/UI/Settings/SyncMigrationSheet.swift`
- Modify: `MyPass/UI/Settings/SyncSettingsPane.swift`
- Test (create): `MyPassTests/SyncMigrationSheetMessageTests.swift`

**Interfaces:**
- Consumes: Task 2's `iCloudBackend(root:relativePath:)` + `createFolderBookmark(for:)` + `ICloudDriveLocation`, Task 3's strategies/errors, Task 4's session methods, Task 5's `clearCheckpoint(for:defaults:)`

The sheet lives in its own file so `SyncSettingsPane` does not grow into a wizard. The misleading "sign in to iCloud" copy is replaced by an explanation that MyPass syncs through a folder in iCloud Drive and needs no developer account. A locked vault disables setup because the session password is required to parse a vault already present in the folder. Success ends with an explicit restart prompt because the `SyncEngine` is built once at launch.

- [ ] **Step 1: Write the failing message tests**

Create `MyPassTests/SyncMigrationSheetMessageTests.swift`. App tests use `import XCTest`, `import SyncKit`, and `@testable import MyPass`.

```swift
import XCTest
import SyncKit
@testable import MyPass

/// The migration sheet's user-facing copy carries safety guarantees, so the
/// wording of the branches that matter is asserted rather than trusted.
final class SyncMigrationSheetMessageTests: XCTestCase {
    func testLocalWriteFailureSaysTheCloudCopyIsAhead() {
        struct Boom: Error {}
        let message = SyncMigrationSheet.message(for: VaultMigrationError.localWriteFailed(underlying: Boom()))
        XCTAssertTrue(message.localizedCaseInsensitiveContains("ahead"), message)
    }

    func testPasswordMismatchSaysNothingChanged() {
        let message = SyncMigrationSheet.message(for: VaultMigrationError.remotePasswordMismatch)
        XCTAssertTrue(message.localizedCaseInsensitiveContains("different password"), message)
        XCTAssertTrue(message.localizedCaseInsensitiveContains("nothing was changed"), message)
    }

    func testInvalidRemoteVaultSaysNothingChanged() {
        let message = SyncMigrationSheet.message(for: VaultMigrationError.remoteNotAValidVault)
        XCTAssertTrue(message.localizedCaseInsensitiveContains("nothing was changed"), message)
    }

    func testRemoteWriteFailureSaysTheLocalVaultIsIntact() {
        struct Boom: Error {}
        let message = SyncMigrationSheet.message(for: VaultMigrationError.remoteWriteFailed(underlying: Boom()))
        XCTAssertTrue(message.localizedCaseInsensitiveContains("local vault was not changed"), message)
    }

    func testDownloadTimeoutOffersToWaitAndRetry() {
        let message = SyncMigrationSheet.message(for: iCloudBackendError.downloadTimedOut)
        XCTAssertTrue(message.localizedCaseInsensitiveContains("still downloading"), message)
    }

    func testNoMessageMentionsSigningIntoICloud() {
        let errors: [Error] = [
            iCloudBackendError.containerUnavailable,
            iCloudBackendError.folderUnavailable,
            iCloudBackendError.folderBookmarkUnresolvable,
            iCloudBackendError.downloadTimedOut,
            VaultMigrationError.vaultLocked,
            VaultMigrationError.remoteNotAValidVault,
            VaultMigrationError.remotePasswordMismatch,
            VaultMigrationError.serializedVaultInvalid
        ]
        for error in errors {
            let message = SyncMigrationSheet.message(for: error)
            XCTAssertFalse(message.localizedCaseInsensitiveContains("sign in to iCloud"), message)
        }
    }

    func testMergeIsDescribedAsKeepingBothSides() {
        let explanation = SyncMigrationSheet.explanation(for: .merge)
        XCTAssertTrue(explanation.localizedCaseInsensitiveContains("both sides"), explanation)
    }

    func testProbeDescriptionIncludesSizeAndDate() {
        let probe = VaultMigrationTargetProbe(
            exists: true,
            modificationDate: Date(timeIntervalSince1970: 1_700_000_000),
            byteCount: 4096
        )
        let description = SyncMigrationSheet.describe(probe)
        XCTAssertTrue(description.contains("KB"), description)
        XCTAssertTrue(description.localizedCaseInsensitiveContains("modified"), description)
    }

    func testProbeDescriptionIsEmptyWithoutMetadata() {
        let probe = VaultMigrationTargetProbe(exists: true, modificationDate: nil, byteCount: nil)
        XCTAssertEqual(SyncMigrationSheet.describe(probe), "")
    }
}
```

- [ ] **Step 2: Run the tests and observe the expected compile failure**

```bash
./scripts/generate.sh && xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/SyncMigrationSheetMessageTests
```

Expected result: compile error — `SyncMigrationSheet` not found.

- [ ] **Step 3: Create `SyncMigrationSheet.swift`**

Create `MyPass/UI/Settings/SyncMigrationSheet.swift` with the full implementation below.

```swift
import SwiftUI
import AppKit
import MyPassKit
import SyncKit

/// First-connect flow for the iCloud Drive backend: pick a folder inside
/// iCloud Drive, see whether it already holds a vault, choose how to
/// reconcile, run the migration, restart. Kept out of `SyncSettingsPane`,
/// which already carries three backends' worth of configuration.
struct SyncMigrationSheet: View {
    @EnvironmentObject private var vaultSession: VaultSession
    @Environment(\.dismiss) private var dismiss
    @AppStorage("syncICloudFolderBookmark") private var syncICloudFolderBookmarkData: Data?

    @State private var step: Step = .chooseFolder
    @State private var chosenFolderURL: URL?
    @State private var chosenFolderBookmark: Data?
    @State private var outsideICloudDriveWarning: String?
    @State private var probe: VaultMigrationTargetProbe?
    @State private var strategy: VaultMigrationStrategy = .merge
    @State private var errorMessage: String?
    @State private var successMessage: String?

    private enum Step: Equatable {
        case chooseFolder
        case probing
        case confirmStrategy
        case migrating
        case finished
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Set Up iCloud Sync")
                .font(.headline)

            content

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            footer
        }
        .padding(20)
        .frame(width: 460)
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .chooseFolder:
            VStack(alignment: .leading, spacing: 8) {
                Text("MyPass mirrors its encrypted vault into a folder inside your iCloud Drive. iCloud syncs that folder between your Macs, and no Apple Developer account is needed.")
                    .fixedSize(horizontal: false, vertical: true)
                if let chosenFolderURL {
                    Text(chosenFolderURL.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                if let outsideICloudDriveWarning {
                    Text(outsideICloudDriveWarning)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

        case .probing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking the folder…")
            }

        case .confirmStrategy:
            strategyChooser

        case .migrating:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Migrating. This can take a while — the vault key is re-derived for every copy.")
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .finished:
            VStack(alignment: .leading, spacing: 8) {
                Label(successMessage ?? "Done.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Quit and reopen MyPass to start syncing: the sync backend is created when the app launches.")
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var strategyChooser: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let probe, probe.exists {
                Text("That folder already contains a vault\(Self.describe(probe)). Choose what to do with it.")
                    .fixedSize(horizontal: false, vertical: true)
                Picker("", selection: $strategy) {
                    ForEach([VaultMigrationStrategy.merge, .adoptRemote, .overwriteRemote]) { option in
                        Text(Self.title(for: option)).tag(option)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                Text(Self.explanation(for: strategy))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("That folder has no vault yet. MyPass will upload the vault from this Mac. Nothing on this Mac changes.")
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack {
            Spacer()
            switch step {
            case .chooseFolder:
                Button("Cancel") { dismiss() }
                Button(chosenFolderURL == nil ? "Choose Folder…" : "Choose Another Folder…") { chooseFolder() }
                if chosenFolderBookmark != nil {
                    Button("Continue") { startProbe() }
                        .keyboardShortcut(.defaultAction)
                }
            case .probing, .migrating:
                Button("Cancel") { dismiss() }
                    .disabled(true)
            case .confirmStrategy:
                Button("Back") {
                    errorMessage = nil
                    step = .chooseFolder
                }
                Button("Migrate") { startMigration() }
                    .keyboardShortcut(.defaultAction)
            case .finished:
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: - Actions

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        panel.message = "Choose a folder inside iCloud Drive for the MyPass vault."
        panel.directoryURL = ICloudDriveLocation.iCloudDriveRootURL

        guard panel.runModal() == .OK, let folderURL = panel.url else { return }

        errorMessage = nil
        chosenFolderURL = folderURL
        outsideICloudDriveWarning = ICloudDriveLocation.isInsideICloudDrive(folderURL)
            ? nil
            : "This folder is not inside iCloud Drive, so iCloud will not sync it. MyPass will still mirror the vault there."
        do {
            chosenFolderBookmark = try iCloudBackend.createFolderBookmark(for: folderURL)
        } catch {
            chosenFolderBookmark = nil
            errorMessage = "MyPass could not keep access to that folder: \(error)"
        }
    }

    private func startProbe() {
        guard let backend = makeBackend() else { return }
        errorMessage = nil
        step = .probing
        vaultSession.probeMigrationTarget(remote: backend) { result in
            switch result {
            case .success(let probe):
                self.probe = probe
                self.strategy = probe.exists ? .merge : .seedRemote
                self.step = .confirmStrategy
            case .failure(let error):
                self.handle(error)
            }
        }
    }

    private func startMigration() {
        guard let backend = makeBackend() else { return }
        errorMessage = nil
        step = .migrating
        vaultSession.performMigration(to: backend, strategy: strategy) { result in
            switch result {
            case .success(let outcome):
                // The bookmark is only persisted once a migration actually
                // succeeded, so a failed attempt never leaves the app pointing
                // at a folder it could not use.
                self.syncICloudFolderBookmarkData = self.chosenFolderBookmark
                // A checkpoint left over from an earlier iCloud folder would
                // make the first sync after restart skip the merge.
                SyncBackendResolver.clearCheckpoint(for: .iCloud)
                self.successMessage = Self.successMessage(for: outcome)
                self.step = .finished
            case .failure(let error):
                self.handle(error)
            }
        }
    }

    private func makeBackend() -> iCloudBackend? {
        guard let chosenFolderBookmark else {
            errorMessage = "Choose a folder first."
            return nil
        }
        do {
            return try iCloudBackend(root: .userFolder(bookmark: chosenFolderBookmark), relativePath: "vault.kdbx")
        } catch {
            handle(error)
            return nil
        }
    }

    private func handle(_ error: Error) {
        if let backendError = error as? iCloudBackendError,
           backendError == .folderBookmarkUnresolvable || backendError == .folderUnavailable {
            syncICloudFolderBookmarkData = nil
            chosenFolderBookmark = nil
            chosenFolderURL = nil
        }
        errorMessage = Self.message(for: error)
        step = .chooseFolder
    }

    // MARK: - Copy

    static func describe(_ probe: VaultMigrationTargetProbe) -> String {
        var parts: [String] = []
        if let byteCount = probe.byteCount {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file))
        }
        if let modificationDate = probe.modificationDate {
            parts.append("modified \(modificationDate.formatted(date: .abbreviated, time: .shortened))")
        }
        return parts.isEmpty ? "" : " (\(parts.joined(separator: ", ")))"
    }

    static func title(for strategy: VaultMigrationStrategy) -> String {
        switch strategy {
        case .seedRemote: return "Upload the vault from this Mac"
        case .merge: return "Merge both vaults (recommended)"
        case .adoptRemote: return "Use the vault from the folder"
        case .overwriteRemote: return "Replace the vault in the folder"
        }
    }

    static func explanation(for strategy: VaultMigrationStrategy) -> String {
        switch strategy {
        case .seedRemote:
            return "The folder has no vault yet, so the vault from this Mac is uploaded unchanged."
        case .merge:
            return "Keeps every entry from both sides, using the same merge rules as normal syncing. Both copies end up identical."
        case .adoptRemote:
            return "Replaces this Mac's vault with the one in the folder. The current local vault is snapshotted into the backups folder first."
        case .overwriteRemote:
            return "Replaces the vault in the folder with the one from this Mac. The copy currently in the folder is discarded."
        }
    }

    static func successMessage(for outcome: VaultMigrationOutcome) -> String {
        switch outcome.strategy {
        case .seedRemote:
            return "The vault from this Mac is now in the iCloud Drive folder."
        case .merge:
            return "Both vaults were merged. This Mac and the iCloud Drive folder now hold the same entries."
        case .adoptRemote:
            return "This Mac now uses the vault from the iCloud Drive folder. The previous local vault was kept in the backups folder."
        case .overwriteRemote:
            return "The iCloud Drive folder now holds the vault from this Mac."
        }
    }

    static func message(for error: Error) -> String {
        if let backendError = error as? iCloudBackendError {
            switch backendError {
            case .folderBookmarkUnresolvable, .folderUnavailable:
                return "That folder is no longer reachable. Choose the iCloud Drive folder again."
            case .downloadTimedOut:
                return "The vault in that folder is still downloading from iCloud. Wait until it finishes, then try again."
            case .containerUnavailable:
                return "MyPass syncs through a folder in iCloud Drive, not a private iCloud container. Choose a folder to continue."
            }
        }
        if let migrationError = error as? VaultMigrationError {
            switch migrationError {
            case .vaultLocked:
                return "Unlock MyPass before setting up iCloud sync."
            case .remoteNotAValidVault:
                return "The file in that folder is not a MyPass vault. Nothing was changed on either side."
            case .remotePasswordMismatch:
                return "The vault in that folder uses a different password. Nothing was changed on either side."
            case .remoteUnreadable(let underlying):
                return "MyPass could not read that folder: \(underlying)"
            case .remoteWriteFailed(let underlying):
                return "MyPass could not write to that folder: \(underlying). Your local vault was not changed."
            case .serializedVaultInvalid:
                return "MyPass could not prepare the vault for upload. Nothing was written to the folder."
            case .localWriteFailed(let underlying):
                return "The copy in iCloud Drive is now ahead of the vault on this Mac: writing the result to disk failed (\(underlying)). Run setup again and choose “Use the vault from the folder” to catch up."
            }
        }
        return "\(error)"
    }
}
```

- [ ] **Step 4: Edit `SyncSettingsPane.swift` — add iCloud folder bookmark storage**

Add after the `@AppStorage("syncLocalFolderBookmark")` line:

```swift
    @AppStorage("syncICloudFolderBookmark") private var syncICloudFolderBookmarkData: Data?
```

- [ ] **Step 5: Edit `SyncSettingsPane.swift` — replace iCloud state properties**

Replace:

```swift
    @State private var iCloudContainerAvailable: Bool = true
    @State private var iCloudContainerCheckMessage: String?
```

with:

```swift
    @State private var iCloudFolderDisplayPath: String?
    @State private var iCloudStatusMessage: String?
    @State private var showingMigrationSheet = false
```

- [ ] **Step 6: Edit `SyncSettingsPane.swift` — replace `iCloudSection`**

Replace the whole `iCloudSection` computed property with:

```swift
    private var iCloudSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let iCloudFolderDisplayPath {
                Text("Mirroring the vault to: \(iCloudFolderDisplayPath)")
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            } else {
                Text("MyPass mirrors its encrypted vault into a folder inside your iCloud Drive, which needs no Apple Developer account. Syncing through a private iCloud container would require a paid developer account and is not enabled in this build.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let iCloudStatusMessage {
                Text(iCloudStatusMessage)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !isVaultUnlocked {
                Text("Unlock the vault first: MyPass needs your vault password to read a vault that is already in the chosen folder.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(iCloudFolderDisplayPath == nil ? "Set Up iCloud Sync…" : "Change iCloud Folder…") {
                showingMigrationSheet = true
            }
            .disabled(!isVaultUnlocked)
        }
        .sheet(isPresented: $showingMigrationSheet, onDismiss: refreshICloudStatus) {
            SyncMigrationSheet()
                .environmentObject(vaultSession)
        }
    }

    private var isVaultUnlocked: Bool {
        if case .unlocked = vaultSession.state { return true }
        return false
    }
```

- [ ] **Step 7: Edit `SyncSettingsPane.swift` — replace `refreshICloudStatus()`**

Replace the whole `refreshICloudStatus()` method with:

```swift
    /// Reports the configured iCloud Drive folder, and self-heals a bookmark
    /// that no longer resolves by clearing it and asking the user to re-pick.
    /// Deliberately does NOT probe a ubiquity container: this build has no
    /// container entitlement, so the old "sign in to iCloud" message was
    /// always wrong about the cause.
    private func refreshICloudStatus() {
        guard selectedOption == .iCloud else { return }
        guard let bookmarkData = syncICloudFolderBookmarkData, !bookmarkData.isEmpty else {
            iCloudFolderDisplayPath = nil
            iCloudStatusMessage = nil
            return
        }

        var isStale = false
        guard let folderURL = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ), !isStale else {
            syncICloudFolderBookmarkData = nil
            iCloudFolderDisplayPath = nil
            iCloudStatusMessage = "The saved iCloud Drive folder is no longer available. Choose the folder again."
            return
        }

        iCloudFolderDisplayPath = folderURL.path
        iCloudStatusMessage = ICloudDriveLocation.isInsideICloudDrive(folderURL)
            ? nil
            : "This folder is not inside iCloud Drive, so iCloud will not sync it."
    }
```

- [ ] **Step 8: Confirm the old iCloud sign-in string is gone from production code**

```bash
rg "sign in to iCloud" MyPass ChromeHost Packages
```

Expected result: no matches.

- [ ] **Step 9: Re-run the message tests and confirm they pass**

```bash
./scripts/generate.sh && xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/SyncMigrationSheetMessageTests
```

Expected result: all tests in `SyncMigrationSheetMessageTests` pass.

- [ ] **Step 10: Manual verification checklist**

Run `./scripts/build-all.sh && ./scripts/run.sh`, then verify:

- [ ] Open Settings → Sync → pick "iCloud Drive"; confirm the pane no longer mentions signing in to iCloud
- [ ] With the vault locked, confirm the setup button is disabled and explains why
- [ ] Unlock, run setup into a fresh folder in iCloud Drive, confirm the success text asks for a restart
- [ ] Restart the app and confirm `vault.kdbx` appears in the chosen folder
- [ ] Run setup again against the same folder and confirm merge/adopt/replace are offered with the folder's size and modification date

- [ ] **Step 11: Commit**

```bash
git add MyPass/UI/Settings/SyncMigrationSheet.swift MyPass/UI/Settings/SyncSettingsPane.swift MyPassTests/SyncMigrationSheetMessageTests.swift
git commit -m "feat: add iCloud sync setup sheet and replace misleading sync copy"
```

### Task 7: RUN.md and full verification

**Files:**
- Modify: `RUN.md`

**Interfaces:**
- Consumes: Nothing new — documents the completed feature
- Produces: Updated Ukrainian setup instructions in `RUN.md`

`RUN.md` is the one file in the repo that must stay Ukrainian; do not translate it, and do not add English copy to it.

- [ ] **Step 1: Replace the `## Обмеження` iCloud bullet**

Replace:

```
- **iCloud entitlements** — у репозиторії можуть бути неповними; інтеграційні iCloud-тести потребують налаштованого середовища розробника.
```

with:

```
- **iCloud** — синхронізація працює через **теку в iCloud Drive** і не потребує платного акаунта Apple Developer. Шлях через приватний iCloud-контейнер (ubiquity container) вимагає платного акаунта Apple Developer і в цій збірці не задіяний. Інтеграційні iCloud-тести (`MYPASS_ICLOUD_INTEGRATION_TESTS=1`) потребують Mac з увімкненим iCloud Drive.
```

- [ ] **Step 2: Add the iCloud Drive sync section before `## Обмеження`**

Insert immediately before `## Обмеження`:

```
## Синхронізація через iCloud Drive

1. Розблокуйте сховище (потрібен пароль сховища, щоб прочитати сховище, яке вже може лежати в теці).
2. Відкрийте **Settings → Sync**, виберіть бекенд **iCloud Drive** і натисніть **Set Up iCloud Sync…**.
3. Виберіть теку в iCloud Drive (панель відкривається на `~/Library/Mobile Documents/com~apple~CloudDocs`). Можна створити нову теку, наприклад `MyPass`.
4. Якщо тека порожня — MyPass завантажить туди сховище з цього Mac. Якщо в теці вже є `vault.kdbx`, виберіть один з варіантів:
   - **Merge** (за замовчуванням) — залишає записи з обох боків;
   - **Use the vault from the folder** — замінює локальне сховище тим, що в теці (попереднє локальне потрапляє в `backups/`);
   - **Replace the vault in the folder** — замінює сховище в теці локальним.
5. **Перезапустіть MyPass** — бекенд синхронізації створюється під час запуску застосунку.
6. Після перезапуску в вибраній теці має з'явитися `vault.kdbx`, а кнопка **Sync Now** у Settings → Sync запускає синхронізацію вручну.

Якщо тека стала недоступною (перейменована, видалена, знята з iCloud Drive), MyPass очистить збережену закладку і попросить вибрати теку знову.
```

- [ ] **Step 3: Run the full test suite**

```bash
./scripts/test.sh
```

Expected result: all targets pass (`MyPass` scheme tests, MyPassKit, SyncKit, ExtensionBridgeKit, Chrome extension JS tests).

- [ ] **Step 4: Run the gated iCloud integration test**

```bash
MYPASS_ICLOUD_INTEGRATION_TESTS=1 bash -c 'cd Packages/SyncKit && swift test --filter iCloudBackendTests'
```

Expected result: `testUserFolderRootRoundTripsInsideRealICloudDrive` passes on a Mac with iCloud Drive enabled. The ubiquity-container tests may still fail or skip because this build has no container entitlement — that is expected.

- [ ] **Step 5: Commit**

```bash
git add RUN.md
git commit -m "docs: describe iCloud Drive folder sync setup in RUN.md"
```

## Spec Coverage

| Spec section | Task |
|---|---|
| Component 1 root abstraction | 2 |
| Component 1 path resolution | 1, 2 |
| Component 1 errors | 2 |
| Component 1 iCloud Drive helpers | 1 |
| Component 2 new UserDefaults key | 5, 6 |
| Component 2 resolver and launch wiring | 5 |
| Component 2 restart constraint | 5, 6 |
| Component 3 API | 3 |
| Component 3 strategy semantics | 3 |
| Component 3 probe behaviour | 3 |
| Component 3 safety ordering | 3 |
| Component 4 preconditions | 4, 6 |
| Component 4 concurrency with autosave | 4 |
| Component 4 state updates | 4 |
| Component 4 checkpoint cleanup | 5, 6 |
| Component 5 status copy | 6 |
| Component 5 SyncMigrationSheet | 6 |
| Component 5 error surfacing | 6 |
| Testing SyncKit ungated | 1, 2 |
| Testing SyncKit gated | 2, 7 |
| Testing VaultMigrationServiceTests | 3 |
| Testing VaultSessionTests additions | 4 |
| Testing SettingsViewSyncBackendTests additions | 5 |
| Documentation impact | 7 |

## Deviations From the Spec

| Spec said | Plan does | Why |
|---|---|---|
| `defaultICloudDriveRootURL` / `isURLInsideICloudDrive` free functions | `ICloudDriveLocation.iCloudDriveRootURL` / `.isInsideICloudDrive(_:)` | Namespaced, and the pure `isDescendantOrSame(_:of:)` split out for tests. |
| Root URL returns nil when the folder is absent | No existence check | In the sandbox that path is unreadable until the user grants access, so the check would report "absent" for every unconfigured user and break the open-panel prefill. |
| `init(relativePath: String = "vault.kdbx")` convenience | `init(relativePath: String = "vault.kdbx", containerIdentifier: String? = nil)` | The existing parameter is used by `iCloudBackendUngatedTests`; dropping it would break a passing test. |
| Hold security scope for the backend's lifetime, treating denial as `.folderUnavailable` | Hold for the lifetime, but a `false` return from `startAccessingSecurityScopedResource()` is not an error | Unsandboxed `swift test` returns `false` while plain access works, exactly as `LocalFolderBackend` already assumes. `.folderUnavailable` now means "resolved path is not an existing directory". |
| Nothing about `ensureDownloaded` | Added an `isUbiquitousItemKey` guard | `startDownloadingUbiquitousItem` throws for paths the file provider does not manage, so every ungated `.userFolder` read would fail without it. |
| `probeMigrationTarget` / `performMigration` are synchronous and throwing | Completion-handler based | Two or three Argon2id derivations plus up to a 10-second iCloud download wait would freeze the main thread and make the sheet's progress step impossible. |
| Error list without a serialization case | Added `VaultMigrationError.serializedVaultInvalid` | Carries the spec's "validate non-empty KDBX header before writing" instruction for the seed and overwrite paths. |

## Success Criteria Verification

1. **Honest iCloud copy — no "sign in to iCloud" as the missing-entitlements explanation.** Verify with `rg "sign in to iCloud" MyPass ChromeHost Packages` (Task 6, Step 8) and `SyncMigrationSheetMessageTests.testNoMessageMentionsSigningIntoICloud`.
2. **Guided first-connect flow with restart prompt.** Task 6 manual checklist: folder pick → probe → strategy → progress → restart message → post-restart `vault.kdbx` in folder → re-setup offers merge/adopt/replace with metadata.
3. **Four reconciliation strategies work correctly.** `VaultMigrationServiceTests`: `testSeedRemoteUploadsLocalVaultAndLeavesLocalFileUntouched`, `testMergeKeepsEntriesFromBothSides`, `testAdoptRemoteReplacesLocalAndSnapshotsPreviousStateIntoBackups`, `testOverwriteRemoteDiscardsRemoteContent`.
4. **Wrong password or invalid remote vault aborts with zero writes on both sides.** `VaultMigrationServiceTests.testMergeWithWrongRemotePasswordLeavesBothSidesByteIdentical` and `testAdoptRemoteWithWrongPasswordLeavesBothSidesByteIdentical`.
5. **Full test suite passes.** `./scripts/test.sh` (Task 7, Step 3) plus gated run `MYPASS_ICLOUD_INTEGRATION_TESTS=1 bash -c 'cd Packages/SyncKit && swift test --filter iCloudBackendTests'` (Task 7, Step 4).

## Out of Scope

- Hot-swapping `SyncEngine` without restart
- Ubiquity-container entitlements and `DEVELOPMENT_TEAM`
- Wiring `iCloudBackend.onRemoteChange` / `NSFilePresenter` into the app
- Phase 7 `SyncBackendOption` raw-value migration
- iOS support
- Wiring `backupCount` from Settings into `VaultFileStore`
- SFTP and Local File connect sheets
- Real-time remote change notifications
