# MyPass Phase 3: Синхронизация (Sync) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Реализовать Фазу 3 синхронизации — бэкенды локальной папки / iCloud Drive / SFTP с автоматическим merge по KeePassXC-семантике, согласно разделу «Синхронизация» дизайн-спеки.

**Architecture:** Новый пакет `Packages/SyncKit` с протоколом `StorageBackend` (read/write/modificationDate/exists), чистой функцией `MergeEngine`, работающей над деревьями `KdbxDatabase` по UUID, и оркестратором `SyncEngine`, реализующим download-if-changed→merge→atomic-upload; `VaultSession` приложения `MyPass` подключается к нему, а `VaultFileStore` остаётся слоем локального бэкапа.

**Tech Stack:** Swift 5.10, локальный SwiftPM-пакет `SyncKit`, зависящий от `MyPassKit`, Foundation FileManager/FSEvents, NSFileCoordinator/NSFilePresenter для iCloud, SFTP-библиотека (Citadel или mft — решается в Task 8), Keychain (Security framework) для SFTP-учётных данных.

## Global Constraints

- Platform floor: macOS 14.0, Swift tools version 5.10 (matches `Packages/MyPassKit/Package.swift` and `project.yml`).
- `SyncKit` package depends on `MyPassKit` via local relative path dependency; `SyncKit` MUST NOT depend on the `MyPass` app target (wrong dependency direction — `MyPass` depends on `SyncKit`, not vice versa).
- `StorageBackend` protocol and `MergeEngine` are synchronous/throws-based, matching existing codebase style (`KdbxDatabase.open`, `VaultFileStore.load`/`save` are all synchronous throws-based) — no async/await introduced in this phase.
- `MergeEngine` has zero I/O dependencies — pure function over `KdbxDatabase` values, fully unit-testable without any backend.
- Out of scope, deferred to later phases: browser extensions (Safari/Chrome) — Phase 4; iOS/iPadOS + AutoFill — Phase 5; Passkeys — Phase 6.
- No placeholders: every step below contains complete, real Swift code — never "TODO"/"implement later"/"similar to Task N" (repeat the code in full each time).

---

### Task 1: SyncKit package scaffold

**Files:**
- Create: `Packages/SyncKit/Package.swift`
- Create: `Packages/SyncKit/Sources/SyncKit/StorageBackend.swift`
- Create: `Packages/SyncKit/Sources/SyncKit/InMemoryStorageBackend.swift`
- Modify: `project.yml` (добавить пакет `SyncKit` и зависимость таргета `MyPass` от него)
- Test: `Packages/SyncKit/Tests/SyncKitTests/InMemoryStorageBackendTests.swift`

**Interfaces:**
- Consumes: ничего из предыдущих фаз — это фундамент Фазы 3.
- Produces:
```swift
public protocol StorageBackend {
    func read() throws -> Data?
    func write(_ data: Data) throws
    func modificationDate() throws -> Date?
    func exists() throws -> Bool
}

public final class InMemoryStorageBackend: StorageBackend {
    public init(initialData: Data? = nil)
    public var writeError: Error?
}
```
`StorageBackend` — базовый протокол, потребляемый Task 2 (`LocalFolderBackend`), Task 6 (`SyncEngine`) и всеми будущими бэкендами (iCloud — Part B, SFTP — Part B/C). `InMemoryStorageBackend` — тестовый двойник; `MergeEngine` (Task 4/5) в нём не нуждается, так как не делает I/O, но Task 6's network-failure тесты используют его `writeError`.

- [ ] **Step 1: Write the failing test**

Create `Packages/SyncKit/Tests/SyncKitTests/InMemoryStorageBackendTests.swift`:

```swift
import XCTest
@testable import SyncKit

final class InMemoryStorageBackendTests: XCTestCase {
    func testExistsIsFalseWhenNoDataWritten() throws {
        let backend = InMemoryStorageBackend()
        XCTAssertFalse(try backend.exists())
        XCTAssertNil(try backend.read())
        XCTAssertNil(try backend.modificationDate())
    }

    func testWriteThenReadRoundTrips() throws {
        let backend = InMemoryStorageBackend()
        let payload = Data("hello sync".utf8)
        try backend.write(payload)
        XCTAssertEqual(try backend.read(), payload)
        XCTAssertTrue(try backend.exists())
    }

    func testModificationDateIsSetAfterWriteAndAdvancesOnSecondWrite() throws {
        let backend = InMemoryStorageBackend()
        try backend.write(Data("v1".utf8))
        let firstDate = try backend.modificationDate()
        XCTAssertNotNil(firstDate)

        Thread.sleep(forTimeInterval: 0.01)
        try backend.write(Data("v2".utf8))
        let secondDate = try backend.modificationDate()
        XCTAssertNotNil(secondDate)
        XCTAssertGreaterThan(secondDate!, firstDate!)
    }

    func testInitialDataIsReadableImmediately() throws {
        let seed = Data("seeded".utf8)
        let backend = InMemoryStorageBackend(initialData: seed)
        XCTAssertTrue(try backend.exists())
        XCTAssertEqual(try backend.read(), seed)
    }

    func testWriteErrorIsThrownWhenInjected() {
        struct InjectedError: Error, Equatable {}
        let backend = InMemoryStorageBackend()
        backend.writeError = InjectedError()
        XCTAssertThrowsError(try backend.write(Data("x".utf8))) { error in
            XCTAssertTrue(error is InjectedError)
        }
        // A failed write must not corrupt existing state.
        XCTAssertNoThrow(try backend.exists())
    }

    func testWriteErrorClearedAllowsSubsequentWriteToSucceed() throws {
        struct InjectedError: Error {}
        let backend = InMemoryStorageBackend()
        backend.writeError = InjectedError()
        XCTAssertThrowsError(try backend.write(Data("x".utf8)))
        backend.writeError = nil
        try backend.write(Data("y".utf8))
        XCTAssertEqual(try backend.read(), Data("y".utf8))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd Packages/SyncKit && swift test --filter InMemoryStorageBackendTests` (SwiftPM package tests use `swift test`, matching Phase 2's Task 1 convention for `MyPassKit`; app-target tests instead use `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:...`, matching Phase 2's Task 2 onward — `SyncKit` is a plain SwiftPM package like `MyPassKit`, so it uses `swift test`.)
Expected: FAIL — the package does not exist yet (`Package.swift` missing / no such module `SyncKit`).

- [ ] **Step 3: Write minimal implementation**

Create `Packages/SyncKit/Package.swift`:

```swift
// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "SyncKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SyncKit", targets: ["SyncKit"])
    ],
    dependencies: [
        .package(path: "../MyPassKit")
    ],
    targets: [
        .target(
            name: "SyncKit",
            dependencies: [
                .product(name: "MyPassKit", package: "MyPassKit")
            ]
        ),
        .testTarget(
            name: "SyncKitTests",
            dependencies: ["SyncKit"]
        )
    ]
)
```

Create `Packages/SyncKit/Sources/SyncKit/StorageBackend.swift`:

```swift
import Foundation

public protocol StorageBackend {
    func read() throws -> Data?
    func write(_ data: Data) throws
    func modificationDate() throws -> Date?
    func exists() throws -> Bool
}
```

Create `Packages/SyncKit/Sources/SyncKit/InMemoryStorageBackend.swift`:

```swift
import Foundation

public final class InMemoryStorageBackend: StorageBackend {
    private let lock = NSLock()
    private var storedData: Data?
    private var storedModificationDate: Date?

    /// When non-nil, `write(_:)` throws this error instead of storing data.
    /// Used by SyncEngine network-failure tests (Task 6).
    public var writeError: Error?

    public init(initialData: Data? = nil) {
        storedData = initialData
        storedModificationDate = initialData != nil ? Date() : nil
    }

    public func read() throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return storedData
    }

    public func write(_ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        if let writeError {
            throw writeError
        }
        storedData = data
        storedModificationDate = Date()
    }

    public func modificationDate() throws -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return storedModificationDate
    }

    public func exists() throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return storedData != nil
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd Packages/SyncKit && swift test --filter InMemoryStorageBackendTests`
Expected: PASS (6/6).

- [ ] **Step 5: Modify project.yml and regenerate/verify full workspace build**

In `project.yml`, add `SyncKit` under `packages:` and `- package: SyncKit` to the `MyPass` target's `dependencies:`. Full updated `packages:` and `dependencies:` sections:

```yaml
packages:
  MyPassKit:
    path: Packages/MyPassKit
  SyncKit:
    path: Packages/SyncKit
```

```yaml
  MyPass:
    type: application
    platform: macOS
    deploymentTarget: "14.0"
    sources:
      - path: MyPass
    dependencies:
      - package: MyPassKit
      - package: SyncKit
```

(the rest of `project.yml` — `settings:`, `info:`, `MyPassTests:` target — is unchanged from Phase 2.)

Run, in order:
1. `cd Packages/SyncKit && swift test` — Expected: all `SyncKitTests` PASS.
2. `xcodegen generate` (repo root) — Expected: prints `Generated project at MyPass.xcodeproj`.
3. `xcodebuild -project MyPass.xcodeproj -scheme MyPass build` (Phase 2's Task 2 full-build convention) — Expected: `** BUILD SUCCEEDED **`, now linking `SyncKit` into the `MyPass` target with no errors.

- [ ] **Step 6: Commit**

```bash
git add Packages/SyncKit project.yml
git commit -m "SyncKit: скаффолдинг пакета, StorageBackend протокол, InMemoryStorageBackend (Фаза 3, Task 1)"
```

---

### Task 2: LocalFolderBackend

**Files:**
- Create: `Packages/SyncKit/Sources/SyncKit/LocalFolderBackend.swift`
- Test: `Packages/SyncKit/Tests/SyncKitTests/LocalFolderBackendTests.swift`

**Interfaces:**
- Consumes: `StorageBackend` (Task 1); `Foundation.FileManager`, `Foundation.URL` bookmark APIs.
- Produces:
```swift
public final class LocalFolderBackend: StorageBackend {
    public init(bookmarkData: Data, filename: String = "vault.kdbx") throws
    public static func createBookmark(for folderURL: URL) throws -> Data
}
```
Consumed by Task 6 (`SyncEngine`, generically via `StorageBackend`) and by the `MyPass` app's Settings UI in Part B/C (folder-picker flow calling `LocalFolderBackend.createBookmark(for:)` after an `NSOpenPanel` selection).

- [ ] **Step 1: Write the failing test**

Create `Packages/SyncKit/Tests/SyncKitTests/LocalFolderBackendTests.swift`:

```swift
import XCTest
@testable import SyncKit

final class LocalFolderBackendTests: XCTestCase {
    var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SyncKitLocalFolderBackendTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testExistsIsFalseBeforeAnyWrite() throws {
        let bookmark = try LocalFolderBackend.createBookmark(for: tempDir)
        let backend = try LocalFolderBackend(bookmarkData: bookmark)
        XCTAssertFalse(try backend.exists())
        XCTAssertNil(try backend.read())
    }

    func testWriteThenReadRoundTripsExactBytes() throws {
        let bookmark = try LocalFolderBackend.createBookmark(for: tempDir)
        let backend = try LocalFolderBackend(bookmarkData: bookmark)
        let payload = Data("kdbx-bytes-example".utf8)
        try backend.write(payload)
        XCTAssertTrue(try backend.exists())
        XCTAssertEqual(try backend.read(), payload)
    }

    func testModificationDateIsNonNilAfterWriteAndIncreasesOnSecondWrite() throws {
        let bookmark = try LocalFolderBackend.createBookmark(for: tempDir)
        let backend = try LocalFolderBackend(bookmarkData: bookmark)
        try backend.write(Data("v1".utf8))
        let firstDate = try backend.modificationDate()
        XCTAssertNotNil(firstDate)

        Thread.sleep(forTimeInterval: 1.0)
        try backend.write(Data("v2".utf8))
        let secondDate = try backend.modificationDate()
        XCTAssertNotNil(secondDate)
        XCTAssertGreaterThan(secondDate!, firstDate!)
    }

    func testSecondWriteOverwritesFirst() throws {
        let bookmark = try LocalFolderBackend.createBookmark(for: tempDir)
        let backend = try LocalFolderBackend(bookmarkData: bookmark)
        try backend.write(Data("first".utf8))
        try backend.write(Data("second".utf8))
        XCTAssertEqual(try backend.read(), Data("second".utf8))
    }
}
```

(bookmarks created via the plain, non-security-scoped-restricted API against a temp directory work fine under XCTest — the app's real sandboxed usage always creates the bookmark from an `NSOpenPanel`-granted URL, which is exercised by the UI task in Part B/C, not here.)

- [ ] **Step 2: Run test to verify it fails**

Run: `cd Packages/SyncKit && swift test --filter LocalFolderBackendTests`
Expected: FAIL — `LocalFolderBackend` does not exist yet (compile error).

- [ ] **Step 3: Write minimal implementation**

Create `Packages/SyncKit/Sources/SyncKit/LocalFolderBackend.swift`:

```swift
import Foundation

public enum LocalFolderBackendError: Error {
    case staleBookmark
}

public final class LocalFolderBackend: StorageBackend {
    private let folderURL: URL
    private let filename: String

    public init(bookmarkData: Data, filename: String = "vault.kdbx") throws {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: bookmarkData,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        if isStale {
            throw LocalFolderBackendError.staleBookmark
        }
        self.folderURL = url
        self.filename = filename
    }

    public static func createBookmark(for folderURL: URL) throws -> Data {
        try folderURL.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    private var fileURL: URL {
        folderURL.appendingPathComponent(filename)
    }

    public func read() throws -> Data? {
        guard folderURL.startAccessingSecurityScopedResource() else {
            return try? Data(contentsOf: fileURL)
        }
        defer { folderURL.stopAccessingSecurityScopedResource() }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }
        return try Data(contentsOf: fileURL)
    }

    public func write(_ data: Data) throws {
        guard folderURL.startAccessingSecurityScopedResource() else {
            try atomicWrite(data: data, to: fileURL)
            return
        }
        defer { folderURL.stopAccessingSecurityScopedResource() }
        try atomicWrite(data: data, to: fileURL)
    }

    public func modificationDate() throws -> Date? {
        guard folderURL.startAccessingSecurityScopedResource() else {
            return try readModificationDate()
        }
        defer { folderURL.stopAccessingSecurityScopedResource() }
        return try readModificationDate()
    }

    public func exists() throws -> Bool {
        guard folderURL.startAccessingSecurityScopedResource() else {
            return FileManager.default.fileExists(atPath: fileURL.path)
        }
        defer { folderURL.stopAccessingSecurityScopedResource() }
        return FileManager.default.fileExists(atPath: fileURL.path)
    }

    private func readModificationDate() throws -> Date? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }
        let values = try fileURL.resourceValues(forKeys: [.contentModificationDateKey])
        return values.contentModificationDate
    }

    private func atomicWrite(data: Data, to url: URL) throws {
        let tempURL = folderURL.appendingPathComponent(".tmp-\(UUID().uuidString)")
        try data.write(to: tempURL, options: .atomic)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
    }
}
```

(the `startAccessingSecurityScopedResource()`/`defer { stopAccessingSecurityScopedResource() }` pattern is applied around every file operation, per spec; `startAccessingSecurityScopedResource()` returning `false` in a non-sandboxed context — e.g. this test suite — is not itself an error, so the fallback path still performs the operation directly, mirroring `VaultFileStore.atomicWrite`'s temp-file-then-`replaceItemAt` pattern.)

- [ ] **Step 4: Run test to verify it passes**

Run: `cd Packages/SyncKit && swift test --filter LocalFolderBackendTests`
Expected: PASS (4/4).

- [ ] **Step 5: Commit**

```bash
git add Packages/SyncKit/Sources/SyncKit/LocalFolderBackend.swift Packages/SyncKit/Tests/SyncKitTests/LocalFolderBackendTests.swift
git commit -m "LocalFolderBackend: security-scoped bookmark + атомарная запись (Фаза 3, Task 2)"
```

---

### Task 3: LocalFolderBackend FSEvents watcher

**Files:**
- Create: `Packages/SyncKit/Sources/SyncKit/LocalFolderChangeWatcher.swift`
- Test: `Packages/SyncKit/Tests/SyncKitTests/LocalFolderChangeWatcherTests.swift`

**Interfaces:**
- Consumes: `CoreServices`/`Foundation` FSEvents C API (`FSEventStreamCreate`, `FSEventStreamStart`, `FSEventStreamStop`, `FSEventStreamInvalidate`, `FSEventStreamRelease`, `FSEventStreamScheduleWithRunLoop`).
- Produces:
```swift
public final class LocalFolderChangeWatcher {
    public init(folderURL: URL, onChange: @escaping () -> Void)
    public func start()
    public func stop()
}
```
Consumed by Part B's `SyncEngine`/app-level auto-sync trigger (watches the configured local sync folder and kicks off a sync pass on external change) and by the `MyPass` app's iCloud-folder integration in Part B.

- [ ] **Step 1: Write the failing test**

Create `Packages/SyncKit/Tests/SyncKitTests/LocalFolderChangeWatcherTests.swift`:

```swift
import XCTest
@testable import SyncKit

final class LocalFolderChangeWatcherTests: XCTestCase {
    var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SyncKitLocalFolderChangeWatcherTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testChangeInWatchedFolderFiresOnChange() throws {
        let expectation = XCTestExpectation(description: "onChange fires after file write")
        let watcher = LocalFolderChangeWatcher(folderURL: tempDir) {
            expectation.fulfill()
        }
        watcher.start()

        // Give FSEventStream a moment to register before mutating the folder.
        Thread.sleep(forTimeInterval: 0.2)
        try Data("changed".utf8).write(to: tempDir.appendingPathComponent("vault.kdbx"))

        wait(for: [expectation], timeout: 5.0)
        watcher.stop()
    }

    func testNoCallbackAfterStop() throws {
        var fireCount = 0
        let watcher = LocalFolderChangeWatcher(folderURL: tempDir) {
            fireCount += 1
        }
        watcher.start()
        Thread.sleep(forTimeInterval: 0.2)
        try Data("first".utf8).write(to: tempDir.appendingPathComponent("vault.kdbx"))
        Thread.sleep(forTimeInterval: 1.0) // allow debounce window to fire once

        watcher.stop()
        let countAfterStop = fireCount
        XCTAssertGreaterThanOrEqual(countAfterStop, 1)

        try Data("second".utf8).write(to: tempDir.appendingPathComponent("vault.kdbx"))
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertEqual(fireCount, countAfterStop, "no further callback should fire after stop()")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd Packages/SyncKit && swift test --filter LocalFolderChangeWatcherTests`
Expected: FAIL — `LocalFolderChangeWatcher` does not exist yet (compile error).

- [ ] **Step 3: Write minimal implementation**

Create `Packages/SyncKit/Sources/SyncKit/LocalFolderChangeWatcher.swift`:

```swift
import Foundation
import CoreServices

public final class LocalFolderChangeWatcher {
    private let folderURL: URL
    private let onChange: () -> Void
    private var stream: FSEventStreamRef?
    private var debounceWorkItem: DispatchWorkItem?
    private let debounceQueue = DispatchQueue(label: "com.mypass.sync.fsevents.debounce")
    private static let debounceInterval: TimeInterval = 0.5

    public init(folderURL: URL, onChange: @escaping () -> Void) {
        self.folderURL = folderURL
        self.onChange = onChange
    }

    public func start() {
        guard stream == nil else { return }

        let pathsToWatch = [folderURL.path] as CFArray
        // Pass `self` as unretained context so the C callback can call back into this instance.
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { (streamRef, clientCallBackInfo, numEvents, eventPaths, eventFlags, eventIds) in
            guard let clientCallBackInfo else { return }
            let watcher = Unmanaged<LocalFolderChangeWatcher>.fromOpaque(clientCallBackInfo).takeUnretainedValue()
            watcher.handleRawEvent()
        }

        guard let newStream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0, // latency handled by our own debounce, not FSEvents' built-in latency
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNone)
        ) else {
            return
        }

        stream = newStream
        FSEventStreamSetDispatchQueue(newStream, debounceQueue)
        FSEventStreamStart(newStream)
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
    }

    /// Called on `debounceQueue` from the C trampoline. Coalesces rapid-fire
    /// events into a single `onChange` call at least `debounceInterval` apart.
    private func handleRawEvent() {
        debounceWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.onChange()
        }
        debounceWorkItem = workItem
        debounceQueue.asyncAfter(deadline: .now() + Self.debounceInterval, execute: workItem)
    }

    deinit {
        stop()
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd Packages/SyncKit && swift test --filter LocalFolderChangeWatcherTests`
Expected: PASS (2/2). If `testChangeInWatchedFolderFiresOnChange` is flaky due to FSEvents scheduling latency in CI sandboxes, increase the `Thread.sleep` before the write from 0.2s to 0.5s and the `wait(for:timeout:)` from 5.0 to 8.0 — do this only if an actual flake is observed, not preemptively.

- [ ] **Step 5: Commit**

```bash
git add Packages/SyncKit/Sources/SyncKit/LocalFolderChangeWatcher.swift Packages/SyncKit/Tests/SyncKitTests/LocalFolderChangeWatcherTests.swift
git commit -m "LocalFolderChangeWatcher: FSEvents-наблюдатель с debounce 0.5s (Фаза 3, Task 3)"
```

---

### Task 4: MergeEngine — basic add/edit merge (rules 1-4+9)

**Files:**
- Create: `Packages/SyncKit/Sources/SyncKit/MergeEngine.swift`
- Test: `Packages/SyncKit/Tests/SyncKitTests/MergeEngineBasicTests.swift`

**Interfaces:**
- Consumes: `MyPassKit.KdbxDatabase`, `MyPassKit.KdbxGroup`, `MyPassKit.KdbxEntry`, `MyPassKit.KdbxField`, `MyPassKit.KdbxDeletedObject` (all public per Phase 2's Task 1).
- Produces:
```swift
public enum MergeEngine {
    public static func merge(local: KdbxDatabase, remote: KdbxDatabase) -> KdbxDatabase
}
```
Consumed by Task 5 (extends the same function's body in the same file) and by Task 6 (`SyncEngine`, which calls `MergeEngine.merge(local:remote:)` as the pure merge step between download and upload).

- [ ] **Step 1: Write the failing test**

Create `Packages/SyncKit/Tests/SyncKitTests/MergeEngineBasicTests.swift`:

```swift
import XCTest
import MyPassKit
@testable import SyncKit

final class MergeEngineBasicTests: XCTestCase {
    /// Builds a minimal single-entry database. `rootUUID` must match between
    /// `local` and `remote` databases in every test, since MergeEngine's root
    /// merge logic requires matching root UUIDs (see MergeEngine.swift rule 9).
    func makeDatabase(
        rootUUID: UUID,
        rootName: String = "MyPass",
        rootModified: Date = Date(timeIntervalSince1970: 1_000),
        entries: [KdbxEntry] = [],
        subgroups: [KdbxGroup] = [],
        deletedObjects: [KdbxDeletedObject] = [],
        recycleBinGroupUUID: UUID? = nil
    ) -> KdbxDatabase {
        let root = KdbxGroup(
            uuid: rootUUID,
            name: rootName,
            iconID: 0,
            creationTime: rootModified,
            lastModificationTime: rootModified,
            locationChanged: rootModified,
            entries: entries,
            subgroups: subgroups
        )
        return KdbxDatabase(rootGroup: root, deletedObjects: deletedObjects, recycleBinGroupUUID: recycleBinGroupUUID)
    }

    func makeEntry(
        uuid: UUID,
        title: String,
        modified: Date,
        history: [KdbxEntry] = []
    ) -> KdbxEntry {
        var entry = KdbxEntry(
            uuid: uuid,
            iconID: 0,
            fields: [],
            creationTime: modified,
            lastModificationTime: modified,
            lastAccessTime: modified,
            locationChanged: modified,
            history: history
        )
        entry.fields = [KdbxField(key: "Title", value: title, isProtected: false)]
        return entry
    }

    func testAddedOnlyLocally() {
        let rootUUID = UUID()
        let localOnlyEntry = makeEntry(uuid: UUID(), title: "LocalOnly", modified: Date(timeIntervalSince1970: 2_000))
        let local = makeDatabase(rootUUID: rootUUID, entries: [localOnlyEntry])
        let remote = makeDatabase(rootUUID: rootUUID, entries: [])

        let merged = MergeEngine.merge(local: local, remote: remote)

        XCTAssertEqual(merged.rootGroup.entries.count, 1)
        XCTAssertEqual(merged.rootGroup.entries.first?.uuid, localOnlyEntry.uuid)
    }

    func testAddedOnlyRemotely() {
        let rootUUID = UUID()
        let remoteOnlyEntry = makeEntry(uuid: UUID(), title: "RemoteOnly", modified: Date(timeIntervalSince1970: 2_000))
        let local = makeDatabase(rootUUID: rootUUID, entries: [])
        let remote = makeDatabase(rootUUID: rootUUID, entries: [remoteOnlyEntry])

        let merged = MergeEngine.merge(local: local, remote: remote)

        XCTAssertEqual(merged.rootGroup.entries.count, 1)
        XCTAssertEqual(merged.rootGroup.entries.first?.uuid, remoteOnlyEntry.uuid)
    }

    func testEditedBothNewerLocalWins() {
        let rootUUID = UUID()
        let entryUUID = UUID()
        let localEntry = makeEntry(uuid: entryUUID, title: "LocalNewer", modified: Date(timeIntervalSince1970: 3_000))
        let remoteEntry = makeEntry(uuid: entryUUID, title: "RemoteOlder", modified: Date(timeIntervalSince1970: 1_000))
        let local = makeDatabase(rootUUID: rootUUID, entries: [localEntry])
        let remote = makeDatabase(rootUUID: rootUUID, entries: [remoteEntry])

        let merged = MergeEngine.merge(local: local, remote: remote)

        XCTAssertEqual(merged.rootGroup.entries.count, 1)
        let winner = merged.rootGroup.entries.first!
        XCTAssertEqual(winner.title, "LocalNewer")
        XCTAssertTrue(winner.history.contains { $0.title == "RemoteOlder" })
    }

    func testEditedBothNewerRemoteWins() {
        let rootUUID = UUID()
        let entryUUID = UUID()
        let localEntry = makeEntry(uuid: entryUUID, title: "LocalOlder", modified: Date(timeIntervalSince1970: 1_000))
        let remoteEntry = makeEntry(uuid: entryUUID, title: "RemoteNewer", modified: Date(timeIntervalSince1970: 3_000))
        let local = makeDatabase(rootUUID: rootUUID, entries: [localEntry])
        let remote = makeDatabase(rootUUID: rootUUID, entries: [remoteEntry])

        let merged = MergeEngine.merge(local: local, remote: remote)

        XCTAssertEqual(merged.rootGroup.entries.count, 1)
        let winner = merged.rootGroup.entries.first!
        XCTAssertEqual(winner.title, "RemoteNewer")
        XCTAssertTrue(winner.history.contains { $0.title == "LocalOlder" })
    }

    func testEditedEqualTimestampsPrefersLocal() {
        let rootUUID = UUID()
        let entryUUID = UUID()
        let sameTime = Date(timeIntervalSince1970: 5_000)
        let localEntry = makeEntry(uuid: entryUUID, title: "LocalTie", modified: sameTime)
        let remoteEntry = makeEntry(uuid: entryUUID, title: "RemoteTie", modified: sameTime)
        let local = makeDatabase(rootUUID: rootUUID, entries: [localEntry])
        let remote = makeDatabase(rootUUID: rootUUID, entries: [remoteEntry])

        let merged = MergeEngine.merge(local: local, remote: remote)

        let winner = merged.rootGroup.entries.first!
        XCTAssertEqual(winner.title, "LocalTie")
        XCTAssertFalse(winner.history.contains { $0.title == "RemoteTie" }, "equal timestamps must not append history")
    }

    func testGroupMetadataMergeIndependentOfChildMerge() {
        let rootUUID = UUID()
        let childGroupUUID = UUID()
        let newEntryUUID = UUID()

        // Local: renames the child group, does not add the new entry.
        let localChildGroup = KdbxGroup(
            uuid: childGroupUUID,
            name: "RenamedByLocal",
            iconID: 1,
            creationTime: Date(timeIntervalSince1970: 1_000),
            lastModificationTime: Date(timeIntervalSince1970: 4_000),
            locationChanged: Date(timeIntervalSince1970: 1_000),
            entries: [],
            subgroups: []
        )
        // Remote: keeps the old name, but adds a new entry into the same group.
        let newEntry = makeEntry(uuid: newEntryUUID, title: "AddedByRemote", modified: Date(timeIntervalSince1970: 2_000))
        let remoteChildGroup = KdbxGroup(
            uuid: childGroupUUID,
            name: "OriginalName",
            iconID: 1,
            creationTime: Date(timeIntervalSince1970: 1_000),
            lastModificationTime: Date(timeIntervalSince1970: 1_500),
            locationChanged: Date(timeIntervalSince1970: 1_000),
            entries: [newEntry],
            subgroups: []
        )

        let local = makeDatabase(rootUUID: rootUUID, subgroups: [localChildGroup])
        let remote = makeDatabase(rootUUID: rootUUID, subgroups: [remoteChildGroup])

        let merged = MergeEngine.merge(local: local, remote: remote)

        XCTAssertEqual(merged.rootGroup.subgroups.count, 1)
        let mergedChild = merged.rootGroup.subgroups.first!
        XCTAssertEqual(mergedChild.name, "RenamedByLocal", "newer lastModificationTime wins group metadata")
        XCTAssertEqual(mergedChild.entries.count, 1)
        XCTAssertEqual(mergedChild.entries.first?.uuid, newEntryUUID, "child entry merge is independent of parent metadata winner")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd Packages/SyncKit && swift test --filter MergeEngineBasicTests`
Expected: FAIL — `MergeEngine` does not exist yet (compile error).

- [ ] **Step 3: Write minimal implementation**

Create `Packages/SyncKit/Sources/SyncKit/MergeEngine.swift`:

```swift
import Foundation
import MyPassKit

public enum MergeEngine {
    /// Merges two divergent copies of the same logical database, `local` and
    /// `remote`, using KeePassXC-style per-object merge semantics keyed by
    /// UUID. Pure function: no I/O, does not mutate its arguments.
    ///
    /// This task implements rules 1-4 and 9 (additions, edits, group metadata
    /// vs. child merge independence, tree reconstruction). Rules 5-8
    /// (deletions, moves, deletedObjects union, recycle bin) are implemented
    /// in Task 5, which extends this same function.
    public static func merge(local: KdbxDatabase, remote: KdbxDatabase) -> KdbxDatabase {
        let localEntries = collectEntries(in: local.rootGroup)
        let remoteEntries = collectEntries(in: remote.rootGroup)
        let localGroups = collectGroups(in: local.rootGroup)
        let remoteGroups = collectGroups(in: remote.rootGroup)

        let mergedRoot: KdbxGroup
        if local.rootGroup.uuid == remote.rootGroup.uuid {
            mergedRoot = mergeGroup(
                uuid: local.rootGroup.uuid,
                localGroup: local.rootGroup,
                remoteGroup: remote.rootGroup,
                localEntries: localEntries,
                remoteEntries: remoteEntries,
                localGroups: localGroups,
                remoteGroups: remoteGroups
            )
        } else {
            // Known limitation: mismatched root UUIDs are not a supported
            // scenario (both databases are expected to share one synthetic
            // root UUID created once at first sync). Fall back to local's
            // root unchanged rather than attempting a cross-root merge.
            mergedRoot = local.rootGroup
        }

        // Rule 9 (naive placeholder, refined by Task 5): union deletedObjects
        // with no dedup.
        let mergedDeletedObjects = local.deletedObjects + remote.deletedObjects

        // Rule 8 (naive placeholder — this exact formula happens to already
        // match the final rule 8 logic Task 5 documents, since there is only
        // ever one recycle bin in practice; Task 5 does not need to change
        // this line): prefer local's recycleBinGroupUUID if present, else
        // remote's. `recycleBinGroupUUID` already exists as a public stored
        // property on `KdbxDatabase` (see `Packages/MyPassKit/Sources/MyPassKit/KdbxDatabase.swift`)
        // — this task only wires MergeEngine to read/pass it through.
        let mergedRecycleBinGroupUUID = local.recycleBinGroupUUID ?? remote.recycleBinGroupUUID

        return KdbxDatabase(rootGroup: mergedRoot, deletedObjects: mergedDeletedObjects, recycleBinGroupUUID: mergedRecycleBinGroupUUID)
    }

    // MARK: - Collection helpers

    private static func collectEntries(in group: KdbxGroup) -> [UUID: KdbxEntry] {
        var result: [UUID: KdbxEntry] = [:]
        for entry in group.entries {
            result[entry.uuid] = entry
        }
        for subgroup in group.subgroups {
            for (uuid, entry) in collectEntries(in: subgroup) {
                result[uuid] = entry
            }
        }
        return result
    }

    private static func collectGroups(in group: KdbxGroup) -> [UUID: KdbxGroup] {
        var result: [UUID: KdbxGroup] = [group.uuid: group]
        for subgroup in group.subgroups {
            for (uuid, g) in collectGroups(in: subgroup) {
                result[uuid] = g
            }
        }
        return result
    }

    // MARK: - Entry merge (rule 2)

    private static func mergeEntry(local: KdbxEntry?, remote: KdbxEntry?) -> KdbxEntry? {
        switch (local, remote) {
        case (nil, nil):
            return nil
        case (let l?, nil):
            return l
        case (nil, let r?):
            return r
        case (let l?, let r?):
            if l.lastModificationTime > r.lastModificationTime {
                return appendToHistoryIfNeeded(winner: l, loser: r)
            } else if r.lastModificationTime > l.lastModificationTime {
                return appendToHistoryIfNeeded(winner: r, loser: l)
            } else {
                // Equal timestamps: prefer local, no history append.
                return l
            }
        }
    }

    private static func appendToHistoryIfNeeded(winner: KdbxEntry, loser: KdbxEntry) -> KdbxEntry {
        var result = winner
        var loserForHistory = loser
        loserForHistory.history = [] // history entries themselves don't carry nested history
        let alreadyPresent = result.history.contains { historical in
            historical.uuid == loserForHistory.uuid &&
            historical.lastModificationTime == loserForHistory.lastModificationTime &&
            historical.fields == loserForHistory.fields
        }
        if !alreadyPresent {
            result.history.append(loserForHistory)
        }
        return result
    }

    // MARK: - Group merge (rules 3, 4, 9)

    private static func mergeGroup(
        uuid: UUID,
        localGroup: KdbxGroup?,
        remoteGroup: KdbxGroup?,
        localEntries: [UUID: KdbxEntry],
        remoteEntries: [UUID: KdbxEntry],
        localGroups: [UUID: KdbxGroup],
        remoteGroups: [UUID: KdbxGroup]
    ) -> KdbxGroup {
        let metadataSource: KdbxGroup
        switch (localGroup, remoteGroup) {
        case (let l?, let r?):
            metadataSource = l.lastModificationTime >= r.lastModificationTime ? l : r
        case (let l?, nil):
            metadataSource = l
        case (nil, let r?):
            metadataSource = r
        case (nil, nil):
            fatalError("mergeGroup called with no source for uuid \(uuid)")
        }

        // Child entry UUIDs present under this group on either side.
        let localChildEntryUUIDs = Set(localGroup?.entries.map(\.uuid) ?? [])
        let remoteChildEntryUUIDs = Set(remoteGroup?.entries.map(\.uuid) ?? [])
        let allChildEntryUUIDs = localChildEntryUUIDs.union(remoteChildEntryUUIDs)

        let mergedEntries: [KdbxEntry] = allChildEntryUUIDs.compactMap { entryUUID in
            mergeEntry(local: localEntries[entryUUID], remote: remoteEntries[entryUUID])
        }.sorted { $0.uuid.uuidString < $1.uuid.uuidString } // deterministic ordering for tests

        // Child subgroup UUIDs present under this group on either side.
        let localChildGroupUUIDs = Set(localGroup?.subgroups.map(\.uuid) ?? [])
        let remoteChildGroupUUIDs = Set(remoteGroup?.subgroups.map(\.uuid) ?? [])
        let allChildGroupUUIDs = localChildGroupUUIDs.union(remoteChildGroupUUIDs)

        let mergedSubgroups: [KdbxGroup] = allChildGroupUUIDs.map { groupUUID in
            mergeGroup(
                uuid: groupUUID,
                localGroup: localGroups[groupUUID],
                remoteGroup: remoteGroups[groupUUID],
                localEntries: localEntries,
                remoteEntries: remoteEntries,
                localGroups: localGroups,
                remoteGroups: remoteGroups
            )
        }.sorted { $0.uuid.uuidString < $1.uuid.uuidString } // deterministic ordering for tests

        return KdbxGroup(
            uuid: uuid,
            name: metadataSource.name,
            iconID: metadataSource.iconID,
            creationTime: metadataSource.creationTime,
            lastModificationTime: metadataSource.lastModificationTime,
            locationChanged: metadataSource.locationChanged,
            entries: mergedEntries,
            subgroups: mergedSubgroups
        )
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd Packages/SyncKit && swift test --filter MergeEngineBasicTests`
Expected: PASS (6/6).

- [ ] **Step 5: Commit**

```bash
git add Packages/SyncKit/Sources/SyncKit/MergeEngine.swift Packages/SyncKit/Tests/SyncKitTests/MergeEngineBasicTests.swift
git commit -m "MergeEngine: базовый merge add/edit по UUID, история изменений (Фаза 3, Task 4)"
```

---

### Task 5: MergeEngine — deletions, moves, deletedObjects/recycleBin (rules 5-8)

**Files:**
- Modify: `Packages/SyncKit/Sources/SyncKit/MergeEngine.swift` (extends `merge(local:remote:)` from Task 4 with deletion/move/deletedObjects/recycle-bin logic)
- Test: `Packages/SyncKit/Tests/SyncKitTests/MergeEngineDeletionsAndMovesTests.swift`

**Interfaces:**
- Consumes: same `KdbxDatabase`/`KdbxGroup`/`KdbxEntry`/`KdbxDeletedObject` types as Task 4; Task 4's private helpers `collectEntries(in:)`, `collectGroups(in:)`, `mergeEntry(local:remote:)`, `mergeGroup(uuid:localGroup:remoteGroup:localEntries:remoteEntries:localGroups:remoteGroups:)` are extended in place, signatures unchanged from Task 4 except where noted below.
- Produces: same public signature `public static func merge(local: KdbxDatabase, remote: KdbxDatabase) -> KdbxDatabase` — behavior extended, not the signature. Consumed by Task 6 (`SyncEngine`) unchanged.

- [ ] **Step 1: Write the failing test**

Create `Packages/SyncKit/Tests/SyncKitTests/MergeEngineDeletionsAndMovesTests.swift`:

```swift
import XCTest
import MyPassKit
@testable import SyncKit

final class MergeEngineDeletionsAndMovesTests: XCTestCase {
    func makeDatabase(
        rootUUID: UUID,
        rootModified: Date = Date(timeIntervalSince1970: 1_000),
        entries: [KdbxEntry] = [],
        subgroups: [KdbxGroup] = [],
        deletedObjects: [KdbxDeletedObject] = [],
        recycleBinGroupUUID: UUID? = nil
    ) -> KdbxDatabase {
        let root = KdbxGroup(
            uuid: rootUUID,
            name: "MyPass",
            iconID: 0,
            creationTime: rootModified,
            lastModificationTime: rootModified,
            locationChanged: rootModified,
            entries: entries,
            subgroups: subgroups
        )
        return KdbxDatabase(rootGroup: root, deletedObjects: deletedObjects, recycleBinGroupUUID: recycleBinGroupUUID)
    }

    func makeEntry(uuid: UUID, title: String, modified: Date, locationChanged: Date? = nil) -> KdbxEntry {
        var entry = KdbxEntry(
            uuid: uuid,
            iconID: 0,
            fields: [],
            creationTime: modified,
            lastModificationTime: modified,
            lastAccessTime: modified,
            locationChanged: locationChanged ?? modified,
            history: []
        )
        entry.fields = [KdbxField(key: "Title", value: title, isProtected: false)]
        return entry
    }

    // Rule 5: delete on one side + edit on the other, resurrection vs deletion-wins.

    func testDeleteLocalEditRemoteNewerResurrects() {
        let rootUUID = UUID()
        let entryUUID = UUID()
        // Local deleted the entry at t=2000.
        let local = makeDatabase(
            rootUUID: rootUUID,
            entries: [],
            deletedObjects: [KdbxDeletedObject(uuid: entryUUID, deletionTime: Date(timeIntervalSince1970: 2_000))]
        )
        // Remote edited it at t=3000 — newer than the deletion.
        let remoteEntry = makeEntry(uuid: entryUUID, title: "ResurrectedByRemote", modified: Date(timeIntervalSince1970: 3_000))
        let remote = makeDatabase(rootUUID: rootUUID, entries: [remoteEntry])

        let merged = MergeEngine.merge(local: local, remote: remote)

        XCTAssertEqual(merged.rootGroup.entries.count, 1)
        XCTAssertEqual(merged.rootGroup.entries.first?.uuid, entryUUID)
        XCTAssertFalse(merged.deletedObjects.contains { $0.uuid == entryUUID })
    }

    func testDeleteLocalEditRemoteOlderDeletionWins() {
        let rootUUID = UUID()
        let entryUUID = UUID()
        // Local deleted the entry at t=5000.
        let local = makeDatabase(
            rootUUID: rootUUID,
            entries: [],
            deletedObjects: [KdbxDeletedObject(uuid: entryUUID, deletionTime: Date(timeIntervalSince1970: 5_000))]
        )
        // Remote's edit at t=1000 predates the deletion.
        let remoteEntry = makeEntry(uuid: entryUUID, title: "StaleEdit", modified: Date(timeIntervalSince1970: 1_000))
        let remote = makeDatabase(rootUUID: rootUUID, entries: [remoteEntry])

        let merged = MergeEngine.merge(local: local, remote: remote)

        XCTAssertFalse(merged.rootGroup.entries.contains { $0.uuid == entryUUID })
        XCTAssertTrue(merged.deletedObjects.contains { $0.uuid == entryUUID })
    }

    func testDeleteRemoteEditLocalNewerResurrects() {
        let rootUUID = UUID()
        let entryUUID = UUID()
        let localEntry = makeEntry(uuid: entryUUID, title: "ResurrectedByLocal", modified: Date(timeIntervalSince1970: 3_000))
        let local = makeDatabase(rootUUID: rootUUID, entries: [localEntry])
        let remote = makeDatabase(
            rootUUID: rootUUID,
            entries: [],
            deletedObjects: [KdbxDeletedObject(uuid: entryUUID, deletionTime: Date(timeIntervalSince1970: 2_000))]
        )

        let merged = MergeEngine.merge(local: local, remote: remote)

        XCTAssertEqual(merged.rootGroup.entries.count, 1)
        XCTAssertEqual(merged.rootGroup.entries.first?.uuid, entryUUID)
        XCTAssertFalse(merged.deletedObjects.contains { $0.uuid == entryUUID })
    }

    func testDeleteRemoteEditLocalOlderDeletionWins() {
        let rootUUID = UUID()
        let entryUUID = UUID()
        let localEntry = makeEntry(uuid: entryUUID, title: "StaleEdit", modified: Date(timeIntervalSince1970: 1_000))
        let local = makeDatabase(rootUUID: rootUUID, entries: [localEntry])
        let remote = makeDatabase(
            rootUUID: rootUUID,
            entries: [],
            deletedObjects: [KdbxDeletedObject(uuid: entryUUID, deletionTime: Date(timeIntervalSince1970: 5_000))]
        )

        let merged = MergeEngine.merge(local: local, remote: remote)

        XCTAssertFalse(merged.rootGroup.entries.contains { $0.uuid == entryUUID })
        XCTAssertTrue(merged.deletedObjects.contains { $0.uuid == entryUUID })
    }

    // Rule 6: moves via locationChanged.

    func testMoveLocalNewerLocationWins() {
        let rootUUID = UUID()
        let folderAUUID = UUID()
        let folderBUUID = UUID()
        let entryUUID = UUID()

        let entryInA = makeEntry(uuid: entryUUID, title: "Moved", modified: Date(timeIntervalSince1970: 1_000), locationChanged: Date(timeIntervalSince1970: 1_000))
        let entryInB = makeEntry(uuid: entryUUID, title: "Moved", modified: Date(timeIntervalSince1970: 1_000), locationChanged: Date(timeIntervalSince1970: 9_000))

        let localFolderA = KdbxGroup(uuid: folderAUUID, name: "A", iconID: 0, creationTime: Date(timeIntervalSince1970: 500), lastModificationTime: Date(timeIntervalSince1970: 500), locationChanged: Date(timeIntervalSince1970: 500), entries: [], subgroups: [])
        let localFolderB = KdbxGroup(uuid: folderBUUID, name: "B", iconID: 0, creationTime: Date(timeIntervalSince1970: 500), lastModificationTime: Date(timeIntervalSince1970: 500), locationChanged: Date(timeIntervalSince1970: 500), entries: [entryInB], subgroups: [])
        let local = makeDatabase(rootUUID: rootUUID, subgroups: [localFolderA, localFolderB])

        let remoteFolderA = KdbxGroup(uuid: folderAUUID, name: "A", iconID: 0, creationTime: Date(timeIntervalSince1970: 500), lastModificationTime: Date(timeIntervalSince1970: 500), locationChanged: Date(timeIntervalSince1970: 500), entries: [entryInA], subgroups: [])
        let remoteFolderB = KdbxGroup(uuid: folderBUUID, name: "B", iconID: 0, creationTime: Date(timeIntervalSince1970: 500), lastModificationTime: Date(timeIntervalSince1970: 500), locationChanged: Date(timeIntervalSince1970: 500), entries: [], subgroups: [])
        let remote = makeDatabase(rootUUID: rootUUID, subgroups: [remoteFolderA, remoteFolderB])

        let merged = MergeEngine.merge(local: local, remote: remote)

        let mergedFolderB = merged.rootGroup.subgroups.first { $0.uuid == folderBUUID }!
        let mergedFolderA = merged.rootGroup.subgroups.first { $0.uuid == folderAUUID }!
        XCTAssertTrue(mergedFolderB.entries.contains { $0.uuid == entryUUID }, "local's newer locationChanged (folder B) must win")
        XCTAssertFalse(mergedFolderA.entries.contains { $0.uuid == entryUUID })
    }

    func testMoveRemoteNewerLocationWins() {
        let rootUUID = UUID()
        let folderAUUID = UUID()
        let folderBUUID = UUID()
        let entryUUID = UUID()

        let entryInA = makeEntry(uuid: entryUUID, title: "Moved", modified: Date(timeIntervalSince1970: 1_000), locationChanged: Date(timeIntervalSince1970: 9_000))
        let entryInB = makeEntry(uuid: entryUUID, title: "Moved", modified: Date(timeIntervalSince1970: 1_000), locationChanged: Date(timeIntervalSince1970: 1_000))

        let localFolderA = KdbxGroup(uuid: folderAUUID, name: "A", iconID: 0, creationTime: Date(timeIntervalSince1970: 500), lastModificationTime: Date(timeIntervalSince1970: 500), locationChanged: Date(timeIntervalSince1970: 500), entries: [entryInA], subgroups: [])
        let localFolderB = KdbxGroup(uuid: folderBUUID, name: "B", iconID: 0, creationTime: Date(timeIntervalSince1970: 500), lastModificationTime: Date(timeIntervalSince1970: 500), locationChanged: Date(timeIntervalSince1970: 500), entries: [], subgroups: [])
        let local = makeDatabase(rootUUID: rootUUID, subgroups: [localFolderA, localFolderB])

        let remoteFolderA = KdbxGroup(uuid: folderAUUID, name: "A", iconID: 0, creationTime: Date(timeIntervalSince1970: 500), lastModificationTime: Date(timeIntervalSince1970: 500), locationChanged: Date(timeIntervalSince1970: 500), entries: [], subgroups: [])
        let remoteFolderB = KdbxGroup(uuid: folderBUUID, name: "B", iconID: 0, creationTime: Date(timeIntervalSince1970: 500), lastModificationTime: Date(timeIntervalSince1970: 500), locationChanged: Date(timeIntervalSince1970: 500), entries: [entryInB], subgroups: [])
        let remote = makeDatabase(rootUUID: rootUUID, subgroups: [remoteFolderA, remoteFolderB])

        let merged = MergeEngine.merge(local: local, remote: remote)

        let mergedFolderA = merged.rootGroup.subgroups.first { $0.uuid == folderAUUID }!
        let mergedFolderB = merged.rootGroup.subgroups.first { $0.uuid == folderBUUID }!
        XCTAssertTrue(mergedFolderA.entries.contains { $0.uuid == entryUUID }, "remote's newer locationChanged (folder A) must win")
        XCTAssertFalse(mergedFolderB.entries.contains { $0.uuid == entryUUID })
    }

    // Rule 7: deletedObjects union.

    func testDeletedObjectsUnionKeepsLaterDeletionTime() {
        let rootUUID = UUID()
        let deletedUUID = UUID()
        let local = makeDatabase(
            rootUUID: rootUUID,
            deletedObjects: [KdbxDeletedObject(uuid: deletedUUID, deletionTime: Date(timeIntervalSince1970: 1_000))]
        )
        let remote = makeDatabase(
            rootUUID: rootUUID,
            deletedObjects: [KdbxDeletedObject(uuid: deletedUUID, deletionTime: Date(timeIntervalSince1970: 9_000))]
        )

        let merged = MergeEngine.merge(local: local, remote: remote)

        let mergedDeletion = merged.deletedObjects.first { $0.uuid == deletedUUID }
        XCTAssertEqual(mergedDeletion?.deletionTime, Date(timeIntervalSince1970: 9_000))
        XCTAssertEqual(merged.deletedObjects.filter { $0.uuid == deletedUUID }.count, 1, "no duplicate entries for the same uuid")
    }

    // Rule 8: recycleBinGroupUUID.

    func testRecycleBinGroupUUIDPrefersNonNil() {
        let rootUUID = UUID()
        let recycleBinUUID = UUID()

        let bothNonNilSame = MergeEngine.merge(
            local: makeDatabase(rootUUID: rootUUID, recycleBinGroupUUID: recycleBinUUID),
            remote: makeDatabase(rootUUID: rootUUID, recycleBinGroupUUID: recycleBinUUID)
        )
        XCTAssertEqual(bothNonNilSame.recycleBinGroupUUID, recycleBinUUID)

        let onlyLocalNonNil = MergeEngine.merge(
            local: makeDatabase(rootUUID: rootUUID, recycleBinGroupUUID: recycleBinUUID),
            remote: makeDatabase(rootUUID: rootUUID, recycleBinGroupUUID: nil)
        )
        XCTAssertEqual(onlyLocalNonNil.recycleBinGroupUUID, recycleBinUUID)

        let onlyRemoteNonNil = MergeEngine.merge(
            local: makeDatabase(rootUUID: rootUUID, recycleBinGroupUUID: nil),
            remote: makeDatabase(rootUUID: rootUUID, recycleBinGroupUUID: recycleBinUUID)
        )
        XCTAssertEqual(onlyRemoteNonNil.recycleBinGroupUUID, recycleBinUUID)

        let bothNil = MergeEngine.merge(
            local: makeDatabase(rootUUID: rootUUID, recycleBinGroupUUID: nil),
            remote: makeDatabase(rootUUID: rootUUID, recycleBinGroupUUID: nil)
        )
        XCTAssertNil(bothNil.recycleBinGroupUUID)
    }
}
```

Note: `KdbxDatabase(rootGroup:deletedObjects:recycleBinGroupUUID:)` and `KdbxDatabase.recycleBinGroupUUID` already exist in the current `MyPassKit` (`Packages/MyPassKit/Sources/MyPassKit/KdbxDatabase.swift`) — Task 4 already reads/passes this field through via its naive `local.recycleBinGroupUUID ?? remote.recycleBinGroupUUID` placeholder. This task does NOT modify `MyPassKit` at all; it only extends `MergeEngine` in `SyncKit`.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd Packages/SyncKit && swift test --filter MergeEngineDeletionsAndMovesTests`
Expected: 7 of 8 tests FAIL, 1 passes already:
- `testRecycleBinGroupUUIDPrefersNonNil` PASSES already — Task 4's naive `local.recycleBinGroupUUID ?? remote.recycleBinGroupUUID` happens to produce the exact same result as rule 8's full "both non-nil→keep; one non-nil→use it; both nil→nil" logic for every case this test exercises.
- `testDeleteLocalEditRemoteNewerResurrects` / `testDeleteRemoteEditLocalNewerResurrects` FAIL — Task 4's naive `deletedObjects` union (`local.deletedObjects + remote.deletedObjects`, no pruning) still lists the resurrected uuid as deleted, so `XCTAssertFalse(merged.deletedObjects.contains { ... })` fails.
- `testDeleteLocalEditRemoteOlderDeletionWins` / `testDeleteRemoteEditLocalOlderDeletionWins` FAIL — Task 4 never prunes a tree node just because the other side recorded a deletion for its uuid, so the entry that should have been dropped is still present in `merged.rootGroup.entries`.
- `testMoveLocalNewerLocationWins` / `testMoveRemoteNewerLocationWins` FAIL — Task 4's `mergeGroup` decides entry inclusion independently per parent group (whichever side has that uuid as a child there), with no `locationChanged` tie-break, so a moved entry appears duplicated under BOTH the old and new parent instead of only the winning one — the `XCTAssertFalse` on the losing parent's `entries.contains` fails.
- `testDeletedObjectsUnionKeepsLaterDeletionTime` FAILS — Task 4's naive union keeps both copies of the same uuid (no dedup), so `merged.deletedObjects.filter { $0.uuid == deletedUUID }.count` is 2, not 1, and the retained `deletionTime` is whichever happened to come first in the concatenation, not necessarily the later one.

- [ ] **Step 3: Extend MergeEngine for rules 5-7 (rule 8 already correct from Task 4)**

Extend `Packages/SyncKit/Sources/SyncKit/MergeEngine.swift`. Replace the body of `public static func merge(local:remote:)` from Task 4 with:

```swift
    public static func merge(local: KdbxDatabase, remote: KdbxDatabase) -> KdbxDatabase {
        let localEntries = collectEntries(in: local.rootGroup)
        let remoteEntries = collectEntries(in: remote.rootGroup)
        let localGroups = collectGroups(in: local.rootGroup)
        let remoteGroups = collectGroups(in: remote.rootGroup)

        // Rule 7: union deletedObjects by uuid, keeping the later deletionTime.
        var deletedByUUID: [UUID: KdbxDeletedObject] = [:]
        for object in local.deletedObjects + remote.deletedObjects {
            if let existing = deletedByUUID[object.uuid] {
                deletedByUUID[object.uuid] = existing.deletionTime >= object.deletionTime ? existing : object
            } else {
                deletedByUUID[object.uuid] = object
            }
        }

        // Rule 5: resurrect uuids whose surviving edit is newer than their
        // recorded deletion; entries/groups that are properly deleted are
        // simply absent from the merged tree (pruned by construction, since
        // mergeGroup/mergeEntry below only ever include uuids present in the
        // live local/remote entry or group maps combined with this deletion
        // check).
        var resurrectedUUIDs: Set<UUID> = []
        for (uuid, deletion) in deletedByUUID {
            let survivingModification = localEntries[uuid]?.lastModificationTime
                ?? remoteEntries[uuid]?.lastModificationTime
                ?? localGroups[uuid]?.lastModificationTime
                ?? remoteGroups[uuid]?.lastModificationTime
            if let survivingModification, survivingModification > deletion.deletionTime {
                resurrectedUUIDs.insert(uuid)
            }
        }
        for uuid in resurrectedUUIDs {
            deletedByUUID.removeValue(forKey: uuid)
        }

        let mergedDeletedObjects = Array(deletedByUUID.values)
        let deletedUUIDsAfterResurrection = Set(deletedByUUID.keys)

        let mergedRoot: KdbxGroup
        if local.rootGroup.uuid == remote.rootGroup.uuid {
            mergedRoot = mergeGroup(
                uuid: local.rootGroup.uuid,
                localGroup: local.rootGroup,
                remoteGroup: remote.rootGroup,
                localEntries: localEntries,
                remoteEntries: remoteEntries,
                localGroups: localGroups,
                remoteGroups: remoteGroups,
                deletedUUIDs: deletedUUIDsAfterResurrection
            )
        } else {
            // Known limitation: mismatched root UUIDs are not a supported
            // scenario (both databases are expected to share one synthetic
            // root UUID created once at first sync). Fall back to local's
            // root unchanged rather than attempting a cross-root merge.
            mergedRoot = local.rootGroup
        }

        // Rule 8: recycleBinGroupUUID — both non-nil (must be equal in
        // practice, there is only ever one recycle bin) → keep it; only one
        // non-nil → use that one; both nil → nil.
        let mergedRecycleBinGroupUUID = local.recycleBinGroupUUID ?? remote.recycleBinGroupUUID

        return KdbxDatabase(
            rootGroup: mergedRoot,
            deletedObjects: mergedDeletedObjects,
            recycleBinGroupUUID: mergedRecycleBinGroupUUID
        )
    }
```

Replace `mergeGroup(uuid:localGroup:remoteGroup:localEntries:remoteEntries:localGroups:remoteGroups:)` from Task 4 with a version that takes deletion state into account (rules 5, 6) when deciding which entries/subgroups to include and where:

```swift
    private static func mergeGroup(
        uuid: UUID,
        localGroup: KdbxGroup?,
        remoteGroup: KdbxGroup?,
        localEntries: [UUID: KdbxEntry],
        remoteEntries: [UUID: KdbxEntry],
        localGroups: [UUID: KdbxGroup],
        remoteGroups: [UUID: KdbxGroup],
        deletedUUIDs: Set<UUID>
    ) -> KdbxGroup {
        let metadataSource: KdbxGroup
        switch (localGroup, remoteGroup) {
        case (let l?, let r?):
            metadataSource = l.lastModificationTime >= r.lastModificationTime ? l : r
        case (let l?, nil):
            metadataSource = l
        case (nil, let r?):
            metadataSource = r
        case (nil, nil):
            fatalError("mergeGroup called with no source for uuid \(uuid)")
        }

        // Rule 6: for every entry/group uuid, decide its winning parent by
        // comparing locationChanged on whichever side that uuid currently
        // sits as a direct child. A uuid whose winning parent is a DIFFERENT
        // group than `uuid` is excluded here (it will be attached under its
        // winning parent instead, when that parent is being built).
        let localChildEntryUUIDs = Set(localGroup?.entries.map(\.uuid) ?? [])
        let remoteChildEntryUUIDs = Set(remoteGroup?.entries.map(\.uuid) ?? [])
        let candidateEntryUUIDs = localChildEntryUUIDs.union(remoteChildEntryUUIDs)
            .subtracting(deletedUUIDs)

        let mergedEntries: [KdbxEntry] = candidateEntryUUIDs.compactMap { entryUUID -> KdbxEntry? in
            guard winningParentUUID(
                for: entryUUID,
                currentGroupUUID: uuid,
                isChildOfLocal: localChildEntryUUIDs.contains(entryUUID),
                isChildOfRemote: remoteChildEntryUUIDs.contains(entryUUID),
                localEntries: localEntries,
                remoteEntries: remoteEntries
            ) == uuid else {
                return nil
            }
            return mergeEntry(local: localEntries[entryUUID], remote: remoteEntries[entryUUID])
        }.sorted { $0.uuid.uuidString < $1.uuid.uuidString }

        let localChildGroupUUIDs = Set(localGroup?.subgroups.map(\.uuid) ?? [])
        let remoteChildGroupUUIDs = Set(remoteGroup?.subgroups.map(\.uuid) ?? [])
        let candidateGroupUUIDs = localChildGroupUUIDs.union(remoteChildGroupUUIDs)
            .subtracting(deletedUUIDs)

        let mergedSubgroups: [KdbxGroup] = candidateGroupUUIDs.compactMap { groupUUID -> KdbxGroup? in
            mergeGroup(
                uuid: groupUUID,
                localGroup: localGroups[groupUUID],
                remoteGroup: remoteGroups[groupUUID],
                localEntries: localEntries,
                remoteEntries: remoteEntries,
                localGroups: localGroups,
                remoteGroups: remoteGroups,
                deletedUUIDs: deletedUUIDs
            )
        }.sorted { $0.uuid.uuidString < $1.uuid.uuidString }

        return KdbxGroup(
            uuid: uuid,
            name: metadataSource.name,
            iconID: metadataSource.iconID,
            creationTime: metadataSource.creationTime,
            lastModificationTime: metadataSource.lastModificationTime,
            locationChanged: metadataSource.locationChanged,
            entries: mergedEntries,
            subgroups: mergedSubgroups
        )
    }

    /// Rule 6: when an entry uuid is a direct child on both sides but under
    /// DIFFERENT parent groups, its final parent is whichever side recorded
    /// the more recent `locationChanged` for that entry. When it's a child
    /// on only one side (the common case — no move happened), that side's
    /// current group is the answer.
    private static func winningParentUUID(
        for entryUUID: UUID,
        currentGroupUUID: UUID,
        isChildOfLocal: Bool,
        isChildOfRemote: Bool,
        localEntries: [UUID: KdbxEntry],
        remoteEntries: [UUID: KdbxEntry]
    ) -> UUID {
        guard isChildOfLocal, isChildOfRemote,
              let localLocationChanged = localEntries[entryUUID]?.locationChanged,
              let remoteLocationChanged = remoteEntries[entryUUID]?.locationChanged else {
            // Not a move candidate (only one side has this uuid as a direct
            // child of ANY group) — that side's current group wins trivially.
            return currentGroupUUID
        }
        // Both sides have this uuid as a child of *some* group; this helper
        // is called once per (uuid, groupUUID) candidate pair, so we only
        // need to decide whether `currentGroupUUID` is the correct location
        // given which side's locationChanged is newer.
        return localLocationChanged >= remoteLocationChanged ? currentGroupUUID : currentGroupUUID
    }
```

The `winningParentUUID` helper above is intentionally simplistic and does not yet correctly disambiguate "which of the two candidate parent groups wins" when they differ — fix it now with the full, correct version that compares against the ACTUAL two parent uuids (not just the current one being evaluated). Replace it with:

```swift
    /// Rule 6: given an entry uuid that is a direct child in `localGroup`
    /// under `localParentUUID` and/or in `remoteGroup` under
    /// `remoteParentUUID`, determines the single winning parent uuid.
    /// - If the uuid is a child on only one side, that side's parent wins
    ///   trivially (no move happened).
    /// - If it's a child under the SAME parent uuid on both sides, that
    ///   parent uuid wins trivially (no move happened).
    /// - If it's a child under DIFFERENT parent uuids on the two sides, the
    ///   parent recorded by whichever side has the more recent
    ///   `locationChanged` for that entry wins.
    private static func winningParentUUID(
        for entryUUID: UUID,
        localParentUUID: UUID?,
        remoteParentUUID: UUID?,
        localEntries: [UUID: KdbxEntry],
        remoteEntries: [UUID: KdbxEntry]
    ) -> UUID? {
        switch (localParentUUID, remoteParentUUID) {
        case (nil, nil):
            return nil
        case (let l?, nil):
            return l
        case (nil, let r?):
            return r
        case (let l?, let r?) where l == r:
            return l
        case (let l?, let r?):
            let localLocationChanged = localEntries[entryUUID]?.locationChanged ?? .distantPast
            let remoteLocationChanged = remoteEntries[entryUUID]?.locationChanged ?? .distantPast
            return localLocationChanged >= remoteLocationChanged ? l : r
        }
    }
```

Because this corrected helper needs each candidate uuid's ACTUAL parent uuid on each side (not just whether `currentGroupUUID` matches), `mergeGroup` must look up parents globally rather than per-call. Replace the entry-inclusion logic inside `mergeGroup` with a version that computes global parent maps once and passes them down. Rewrite `mergeGroup`'s signature and body one final time to thread these through:

```swift
    private static func mergeGroup(
        uuid: UUID,
        localGroup: KdbxGroup?,
        remoteGroup: KdbxGroup?,
        localEntries: [UUID: KdbxEntry],
        remoteEntries: [UUID: KdbxEntry],
        localGroups: [UUID: KdbxGroup],
        remoteGroups: [UUID: KdbxGroup],
        localEntryParents: [UUID: UUID],
        remoteEntryParents: [UUID: UUID],
        deletedUUIDs: Set<UUID>
    ) -> KdbxGroup {
        let metadataSource: KdbxGroup
        switch (localGroup, remoteGroup) {
        case (let l?, let r?):
            metadataSource = l.lastModificationTime >= r.lastModificationTime ? l : r
        case (let l?, nil):
            metadataSource = l
        case (nil, let r?):
            metadataSource = r
        case (nil, nil):
            fatalError("mergeGroup called with no source for uuid \(uuid)")
        }

        let localChildEntryUUIDs = Set(localGroup?.entries.map(\.uuid) ?? [])
        let remoteChildEntryUUIDs = Set(remoteGroup?.entries.map(\.uuid) ?? [])
        let candidateEntryUUIDs = localChildEntryUUIDs.union(remoteChildEntryUUIDs)
            .subtracting(deletedUUIDs)

        let mergedEntries: [KdbxEntry] = candidateEntryUUIDs.compactMap { entryUUID -> KdbxEntry? in
            let winningParent = winningParentUUID(
                for: entryUUID,
                localParentUUID: localEntryParents[entryUUID],
                remoteParentUUID: remoteEntryParents[entryUUID],
                localEntries: localEntries,
                remoteEntries: remoteEntries
            )
            guard winningParent == uuid else { return nil }
            return mergeEntry(local: localEntries[entryUUID], remote: remoteEntries[entryUUID])
        }.sorted { $0.uuid.uuidString < $1.uuid.uuidString }

        let localChildGroupUUIDs = Set(localGroup?.subgroups.map(\.uuid) ?? [])
        let remoteChildGroupUUIDs = Set(remoteGroup?.subgroups.map(\.uuid) ?? [])
        let candidateGroupUUIDs = localChildGroupUUIDs.union(remoteChildGroupUUIDs)
            .subtracting(deletedUUIDs)

        let mergedSubgroups: [KdbxGroup] = candidateGroupUUIDs.compactMap { groupUUID -> KdbxGroup? in
            mergeGroup(
                uuid: groupUUID,
                localGroup: localGroups[groupUUID],
                remoteGroup: remoteGroups[groupUUID],
                localEntries: localEntries,
                remoteEntries: remoteEntries,
                localGroups: localGroups,
                remoteGroups: remoteGroups,
                localEntryParents: localEntryParents,
                remoteEntryParents: remoteEntryParents,
                deletedUUIDs: deletedUUIDs
            )
        }.sorted { $0.uuid.uuidString < $1.uuid.uuidString }

        return KdbxGroup(
            uuid: uuid,
            name: metadataSource.name,
            iconID: metadataSource.iconID,
            creationTime: metadataSource.creationTime,
            lastModificationTime: metadataSource.lastModificationTime,
            locationChanged: metadataSource.locationChanged,
            entries: mergedEntries,
            subgroups: mergedSubgroups
        )
    }
```

Add the parent-map builder used to populate `localEntryParents`/`remoteEntryParents`, and update the top-level `merge(local:remote:)` to build and pass them:

```swift
    private static func collectEntryParents(in group: KdbxGroup) -> [UUID: UUID] {
        var result: [UUID: UUID] = [:]
        for entry in group.entries {
            result[entry.uuid] = group.uuid
        }
        for subgroup in group.subgroups {
            for (entryUUID, parentUUID) in collectEntryParents(in: subgroup) {
                result[entryUUID] = parentUUID
            }
        }
        return result
    }
```

In `merge(local:remote:)`, after computing `localGroups`/`remoteGroups`, add:

```swift
        let localEntryParents = collectEntryParents(in: local.rootGroup)
        let remoteEntryParents = collectEntryParents(in: remote.rootGroup)
```

and update the `mergeGroup` call site to pass them through:

```swift
            mergedRoot = mergeGroup(
                uuid: local.rootGroup.uuid,
                localGroup: local.rootGroup,
                remoteGroup: remote.rootGroup,
                localEntries: localEntries,
                remoteEntries: remoteEntries,
                localGroups: localGroups,
                remoteGroups: remoteGroups,
                localEntryParents: localEntryParents,
                remoteEntryParents: remoteEntryParents,
                deletedUUIDs: deletedUUIDsAfterResurrection
            )
```

(subgroup moves — rule 6 applied to a *group* uuid whose parent group differs between local/remote — are out of scope for this task's test list, which only exercises entry moves; the same `winningParentUUID`-style comparison would apply symmetrically to subgroups via `localGroups`' parent map if needed later, but is not required by any test above and is therefore not added here, to avoid unverified code.)

- [ ] **Step 4: Run test to verify it passes**

Run: `cd Packages/SyncKit && swift test --filter MergeEngineDeletionsAndMovesTests`
Expected: PASS (8/8).

- [ ] **Step 5: Run the full SyncKit and MyPassKit suites to check for regressions**

Run: `cd Packages/SyncKit && swift test`, then `cd Packages/MyPassKit && swift test`
Expected: all `SyncKitTests` (Tasks 1-5, cumulative) PASS; all `MyPassKitTests`/`MyPassKitPublicAPITests` PASS — this task does not touch `MyPassKit`, so its suite is unaffected.

- [ ] **Step 6: Commit**

```bash
git add Packages/SyncKit/Sources/SyncKit/MergeEngine.swift Packages/SyncKit/Tests/SyncKitTests/MergeEngineDeletionsAndMovesTests.swift
git commit -m "MergeEngine: удаления/resurrection, перемещения по locationChanged, дедуп deletedObjects (Фаза 3, Task 5)"
```

---

### Task 6: SyncEngine — checkpoint-aware download→merge→upload orchestrator

**Files:**
- Create: `Packages/SyncKit/Sources/SyncKit/SyncCheckpointStore.swift`
- Create: `Packages/SyncKit/Sources/SyncKit/SyncEngine.swift`
- Test: `Packages/SyncKit/Tests/SyncKitTests/SyncEngineTests.swift`

**Interfaces:**
- Consumes: `StorageBackend`/`InMemoryStorageBackend` (Task 1), `MergeEngine.merge(local:remote:)` (Tasks 4-5), `MyPassKit.KdbxDatabase`/`.open(data:password:)`/`.save(password:cipher:compression:)`, `KdbxCipher`, `KdbxCompression` (all public, `Packages/MyPassKit/Sources/MyPassKit/KdbxDatabase.swift` + `Format/KdbxOuterHeader.swift`).
- Produces:
```swift
public protocol SyncCheckpointStore {
    func loadCheckpoint() throws -> Date?
    func saveCheckpoint(_ date: Date?) throws
}

public final class UserDefaultsSyncCheckpointStore: SyncCheckpointStore {
    public init(defaults: UserDefaults = .standard, key: String = "com.mypass.sync.lastRemoteModificationDate")
}

public final class InMemorySyncCheckpointStore: SyncCheckpointStore {
    public init(initialCheckpoint: Date? = nil)
}

public enum SyncResult {
    case uploadedInitial
    case uploadedDirect
    case merged(KdbxDatabase)
}

public enum SyncEngineError: Error {
    case remoteDataUndecodable
}

public final class SyncEngine {
    public init(remote: StorageBackend, checkpointStore: SyncCheckpointStore)
    public func sync(local: KdbxDatabase, password: String, cipher: KdbxCipher, compression: KdbxCompression) throws -> SyncResult
}
```
Consumed by Task 7 (`VaultSession` calls `syncEngine.sync(local:password:cipher:compression:)` both right after unlocking and after every autosave), and by Part B/C (each concrete remote backend — iCloud folder, SFTP — is just another `StorageBackend` handed to the same `SyncEngine`, no changes to this file needed). `SyncEngine` deliberately does NOT depend on `VaultFileStore` — per this plan's Architecture line, `VaultFileStore` remains the local-backup layer, and `VaultSession` is the one place that bridges the two, feeding `SyncEngine` the in-memory `KdbxDatabase` and writing merge results back to `fileStore` itself.

`SyncCheckpointStore` records the remote's `modificationDate()` as it stood right after our own last successful upload — this is how `sync(...)` tells "nobody else has touched remote since we last synced" (skip straight to re-uploading local; no download/merge needed) apart from "remote changed since then" (a real three-way merge against the downloaded remote is required). `SyncEngineError.remoteDataUndecodable` is declared for API completeness but not thrown by this task's implementation (a corrupt/empty remote read is handled by treating it the same as "remote does not exist" — see Step 3 below); no other component or test in this task uses it.

- [ ] **Step 1: Write the failing test**

Create `Packages/SyncKit/Tests/SyncKitTests/SyncEngineTests.swift`:

```swift
import XCTest
import MyPassKit
@testable import SyncKit

final class SyncEngineTests: XCTestCase {
    let password = "sync-engine-tests-password"

    /// `KdbxEntry.title` isn't visible from `SyncKitTests` — it's an
    /// app-level convenience extension declared in
    /// `MyPass/Models/KdbxEntry+Convenience.swift`, part of the `MyPass`
    /// app target, not `MyPassKit` — so these tests read "Title" directly
    /// via `fields`, exactly as `KdbxEntry` itself exposes it.
    func titleFieldValue(of entry: KdbxEntry) -> String? {
        entry.fields.first(where: { $0.key == "Title" })?.value
    }

    func makeEntry(title: String, uuid: UUID = UUID(), modified: Date = Date(timeIntervalSince1970: 1_000)) -> KdbxEntry {
        KdbxEntry(
            uuid: uuid,
            iconID: 0,
            fields: [KdbxField(key: "Title", value: title, isProtected: false)],
            creationTime: modified,
            lastModificationTime: modified,
            lastAccessTime: modified,
            locationChanged: modified,
            history: []
        )
    }

    /// Always constructs a brand-new `KdbxGroup` (a *reference* type) so two
    /// "copies" built from separate calls never secretly alias the same
    /// underlying group object — each call to this helper is a fully
    /// independent tree, avoiding the mutation-aliasing trap `KdbxGroup`'s
    /// class semantics would otherwise set for a test that tried to build a
    /// "second" database by copying and then mutating a "first" one.
    func makeDatabase(rootUUID: UUID, entries: [KdbxEntry], recycleBinGroupUUID: UUID? = nil) -> KdbxDatabase {
        let now = Date(timeIntervalSince1970: 1_000)
        let root = KdbxGroup(
            uuid: rootUUID,
            name: "MyPass",
            iconID: 0,
            creationTime: now,
            lastModificationTime: now,
            locationChanged: now,
            entries: entries,
            subgroups: []
        )
        return KdbxDatabase(rootGroup: root, deletedObjects: [], recycleBinGroupUUID: recycleBinGroupUUID)
    }

    func testFirstSyncBackendDoesNotExistUploadsLocal() throws {
        let rootUUID = UUID()
        let local = makeDatabase(rootUUID: rootUUID, entries: [makeEntry(title: "OnlyLocal")])
        let remote = InMemoryStorageBackend()
        let checkpointStore = InMemorySyncCheckpointStore()
        let engine = SyncEngine(remote: remote, checkpointStore: checkpointStore)

        XCTAssertFalse(try remote.exists())

        let result = try engine.sync(local: local, password: password, cipher: .aes256, compression: .gzip)

        guard case .uploadedInitial = result else {
            return XCTFail("expected .uploadedInitial, got \(result)")
        }
        XCTAssertTrue(try remote.exists())
        let remoteData = try XCTUnwrap(try remote.read())
        let remoteDatabase = try KdbxDatabase.open(data: remoteData, password: password)
        XCTAssertEqual(titleFieldValue(of: remoteDatabase.rootGroup.entries.first!), "OnlyLocal")
        XCTAssertNotNil(try checkpointStore.loadCheckpoint())
    }

    func testUnchangedRemoteReuploadsLocalDirectly() throws {
        let rootUUID = UUID()
        let firstEntry = makeEntry(title: "First")
        let firstLocal = makeDatabase(rootUUID: rootUUID, entries: [firstEntry])
        let remote = InMemoryStorageBackend()
        let checkpointStore = InMemorySyncCheckpointStore()
        let engine = SyncEngine(remote: remote, checkpointStore: checkpointStore)

        _ = try engine.sync(local: firstLocal, password: password, cipher: .aes256, compression: .gzip)
        let checkpointAfterFirstSync = try XCTUnwrap(try checkpointStore.loadCheckpoint())

        // A brand-new database value (not a mutated copy of `firstLocal`, to
        // avoid the class/struct aliasing trap noted above) with an extra
        // entry, simulating a local-only edit made since the first sync.
        // Nobody has touched `remote` in between, so its modification date
        // is still exactly what the first sync left it at — this must
        // trigger the "unchanged" direct-upload path, not a merge.
        let secondEntry = makeEntry(title: "Second")
        let secondLocal = makeDatabase(rootUUID: rootUUID, entries: [firstEntry, secondEntry])

        let result = try engine.sync(local: secondLocal, password: password, cipher: .aes256, compression: .gzip)

        guard case .uploadedDirect = result else {
            return XCTFail("expected .uploadedDirect, got \(result)")
        }
        let remoteData = try XCTUnwrap(try remote.read())
        let remoteDatabase = try KdbxDatabase.open(data: remoteData, password: password)
        XCTAssertEqual(remoteDatabase.rootGroup.entries.count, 2)
        let checkpointAfterSecondSync = try XCTUnwrap(try checkpointStore.loadCheckpoint())
        XCTAssertNotEqual(checkpointAfterFirstSync, checkpointAfterSecondSync)
    }

    func testChangedRemoteTriggersMerge() throws {
        let rootUUID = UUID()
        let sharedEntry = makeEntry(title: "Shared", uuid: UUID())
        let firstLocal = makeDatabase(rootUUID: rootUUID, entries: [sharedEntry])
        let remote = InMemoryStorageBackend()
        let checkpointStore = InMemorySyncCheckpointStore()
        let engine = SyncEngine(remote: remote, checkpointStore: checkpointStore)

        _ = try engine.sync(local: firstLocal, password: password, cipher: .aes256, compression: .gzip)

        // Simulate a second device writing to the SAME remote, independent
        // of this `engine`/`checkpointStore` — a fresh, unrelated database
        // encrypted straight to `remote`, bypassing `SyncEngine` entirely.
        // This is exactly what "the remote changed since our last
        // checkpoint" looks like.
        let remoteOnlyEntry = makeEntry(title: "RemoteOnly", uuid: UUID(), modified: Date(timeIntervalSince1970: 5_000))
        let remoteDatabaseFromOtherDevice = makeDatabase(rootUUID: rootUUID, entries: [sharedEntry, remoteOnlyEntry])
        let remoteDataFromOtherDevice = try remoteDatabaseFromOtherDevice.save(password: password, cipher: .aes256, compression: .gzip)
        try remote.write(remoteDataFromOtherDevice)

        let localOnlyEntry = makeEntry(title: "LocalOnly", uuid: UUID(), modified: Date(timeIntervalSince1970: 6_000))
        let secondLocal = makeDatabase(rootUUID: rootUUID, entries: [sharedEntry, localOnlyEntry])

        let result = try engine.sync(local: secondLocal, password: password, cipher: .aes256, compression: .gzip)

        guard case .merged(let mergedDatabase) = result else {
            return XCTFail("expected .merged, got \(result)")
        }
        let mergedTitles = Set(mergedDatabase.rootGroup.entries.map { titleFieldValue(of: $0) })
        XCTAssertEqual(mergedTitles, ["Shared", "RemoteOnly", "LocalOnly"])

        let remoteData = try XCTUnwrap(try remote.read())
        let remoteDatabaseAfterSync = try KdbxDatabase.open(data: remoteData, password: password)
        let uploadedTitles = Set(remoteDatabaseAfterSync.rootGroup.entries.map { titleFieldValue(of: $0) })
        XCTAssertEqual(uploadedTitles, mergedTitles)
    }

    func testMidCycleFailureLeavesCheckpointAndLocalUntouched() throws {
        let rootUUID = UUID()
        let firstLocal = makeDatabase(rootUUID: rootUUID, entries: [makeEntry(title: "First")])
        let remote = InMemoryStorageBackend()
        let checkpointStore = InMemorySyncCheckpointStore()
        let engine = SyncEngine(remote: remote, checkpointStore: checkpointStore)

        _ = try engine.sync(local: firstLocal, password: password, cipher: .aes256, compression: .gzip)
        let checkpointBeforeFailure = try checkpointStore.loadCheckpoint()
        let remoteDataBeforeFailure = try remote.read()

        struct SimulatedNetworkError: Error {}
        remote.writeError = SimulatedNetworkError()

        let secondLocal = makeDatabase(rootUUID: rootUUID, entries: [makeEntry(title: "SecondA"), makeEntry(title: "SecondB")])

        XCTAssertThrowsError(try engine.sync(local: secondLocal, password: password, cipher: .aes256, compression: .gzip)) { error in
            XCTAssertTrue(error is SimulatedNetworkError)
        }

        // The failed write must not have moved the checkpoint forward, nor
        // altered whatever was already on the remote.
        XCTAssertEqual(try checkpointStore.loadCheckpoint(), checkpointBeforeFailure)
        XCTAssertEqual(try remote.read(), remoteDataBeforeFailure)

        // `secondLocal` — the caller's in-memory value — is untouched by a
        // failed sync attempt; `sync(local:...)` takes it by value and never
        // mutates its parameter, so this is inherently true, but assert it
        // explicitly.
        XCTAssertEqual(secondLocal.rootGroup.entries.count, 2)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd Packages/SyncKit && swift test --filter SyncEngineTests`
Expected: FAIL — `SyncEngine`/`SyncCheckpointStore`/`InMemorySyncCheckpointStore`/`SyncResult` do not exist yet (compile error).

- [ ] **Step 3: Write minimal implementation**

Create `Packages/SyncKit/Sources/SyncKit/SyncCheckpointStore.swift`:

```swift
import Foundation

/// Persists the remote backend's `modificationDate()` as it stood right
/// after our own last successful upload, so `SyncEngine` can tell "remote is
/// unchanged since our last sync" (skip merge, just re-upload local) apart
/// from "remote changed since then" (download + merge is required).
public protocol SyncCheckpointStore {
    func loadCheckpoint() throws -> Date?
    func saveCheckpoint(_ date: Date?) throws
}

public final class UserDefaultsSyncCheckpointStore: SyncCheckpointStore {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "com.mypass.sync.lastRemoteModificationDate") {
        self.defaults = defaults
        self.key = key
    }

    public func loadCheckpoint() throws -> Date? {
        // `UserDefaults.double(forKey:)` returns 0 both for "the key holds a
        // real 0" and "the key is missing" — track presence explicitly via
        // `object(forKey:)` instead of trusting that ambiguity.
        guard defaults.object(forKey: key) != nil else { return nil }
        return Date(timeIntervalSinceReferenceDate: defaults.double(forKey: key))
    }

    public func saveCheckpoint(_ date: Date?) throws {
        guard let date else {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(date.timeIntervalSinceReferenceDate, forKey: key)
    }
}

public final class InMemorySyncCheckpointStore: SyncCheckpointStore {
    private var checkpoint: Date?

    public init(initialCheckpoint: Date? = nil) {
        checkpoint = initialCheckpoint
    }

    public func loadCheckpoint() throws -> Date? { checkpoint }
    public func saveCheckpoint(_ date: Date?) throws { checkpoint = date }
}
```

Create `Packages/SyncKit/Sources/SyncKit/SyncEngine.swift`:

```swift
import Foundation
import MyPassKit

/// What kind of sync cycle actually happened — surfaced mainly so `VaultSession`
/// (Task 7) and tests can distinguish "nothing to merge" from "a real
/// three-way merge occurred" (in which case the merged database must replace
/// the caller's in-memory/on-disk state).
public enum SyncResult {
    /// The remote backend did not exist yet (first sync ever) — local was
    /// uploaded as-is, with no merge to perform.
    case uploadedInitial
    /// The remote existed and was unchanged since our last successful sync
    /// — local was re-uploaded directly, with no merge to perform.
    case uploadedDirect
    /// The remote existed and had changed since our last successful sync —
    /// remote was downloaded, merged with local via `MergeEngine.merge`, and
    /// the merged result was uploaded. Carries the merged database so the
    /// caller can adopt it as the new in-memory/on-disk state.
    case merged(KdbxDatabase)
}

public enum SyncEngineError: Error {
    /// Reserved for a future backend whose `read()` can return non-nil-but-
    /// undecodable bytes in a way that must be distinguished from "no data
    /// at all" — not thrown by the current implementation (see Step 3's
    /// `sync(...)` body: a nil read on an existing remote is instead treated
    /// the same as "remote does not exist yet").
    case remoteDataUndecodable
}

/// Orchestrates one download-if-changed → merge → atomic-upload cycle
/// against a single remote `StorageBackend`. Pure with respect to `local`
/// (never mutates the caller's value); all I/O and state live in `remote`
/// and `checkpointStore`.
public final class SyncEngine {
    private let remote: StorageBackend
    private let checkpointStore: SyncCheckpointStore

    public init(remote: StorageBackend, checkpointStore: SyncCheckpointStore) {
        self.remote = remote
        self.checkpointStore = checkpointStore
    }

    public func sync(
        local: KdbxDatabase,
        password: String,
        cipher: KdbxCipher,
        compression: KdbxCompression
    ) throws -> SyncResult {
        let localData = try local.save(password: password, cipher: cipher, compression: compression)

        guard try remote.exists() else {
            try remote.write(localData)
            try checkpointStore.saveCheckpoint(try remote.modificationDate())
            return .uploadedInitial
        }

        let remoteModificationDate = try remote.modificationDate()
        let lastKnownCheckpoint = try checkpointStore.loadCheckpoint()

        if remoteModificationDate == lastKnownCheckpoint {
            try remote.write(localData)
            try checkpointStore.saveCheckpoint(try remote.modificationDate())
            return .uploadedDirect
        }

        guard let remoteData = try remote.read() else {
            // Remote reported `exists() == true` but returned no data on
            // read — nothing to merge against, so treat it the same as a
            // fresh remote.
            try remote.write(localData)
            try checkpointStore.saveCheckpoint(try remote.modificationDate())
            return .uploadedInitial
        }
        let remoteDatabase = try KdbxDatabase.open(data: remoteData, password: password)
        let mergedDatabase = MergeEngine.merge(local: local, remote: remoteDatabase)
        let mergedData = try mergedDatabase.save(password: password, cipher: cipher, compression: compression)
        try remote.write(mergedData)
        try checkpointStore.saveCheckpoint(try remote.modificationDate())
        return .merged(mergedDatabase)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd Packages/SyncKit && swift test --filter SyncEngineTests`
Expected: PASS (4/4).

- [ ] **Step 5: Run the full SyncKit suite to check for regressions**

Run: `cd Packages/SyncKit && swift test`
Expected: all `SyncKitTests` (Tasks 1-6, cumulative) PASS.

- [ ] **Step 6: Commit**

```bash
git add Packages/SyncKit/Sources/SyncKit/SyncCheckpointStore.swift Packages/SyncKit/Sources/SyncKit/SyncEngine.swift Packages/SyncKit/Tests/SyncKitTests/SyncEngineTests.swift
git commit -m "SyncKit: SyncEngine — checkpoint-aware download/merge/upload orchестратор (Фаза 3, Task 6)"
```

---

### Task 7: Подключить SyncEngine к VaultSession

**Files:**
- Modify: `MyPass/State/VaultSession.swift`
- Modify: `project.yml` (добавить пакет `SyncKit` и зависимость таргета `MyPass` от него — если ещё не сделано в Task 1; см. примечание в Step 3)
- Test: `MyPassTests/VaultSessionTests.swift` (добавить 3 новых теста к 4 существующим)

**Interfaces:**
- Consumes: `SyncKit.SyncEngine`/`.sync(local:password:cipher:compression:)`, `SyncKit.SyncResult`, `SyncKit.InMemoryStorageBackend`, `SyncKit.InMemorySyncCheckpointStore` (Task 6); `MyPass/Models/KdbxEntry+Convenience.swift`'s `.title` extension (existing, Phase 2); `MyPass/Models/KdbxGroup+DeepCopy.swift`'s `.deepCopy()` extension (existing, Phase 2, unchanged by this task).
- Produces: `VaultSession.init(fileStore:syncEngine:)` — an additional `syncEngine: SyncEngine? = nil` parameter (default `nil` keeps every existing Phase 2 call site — the real `MyPass/State/VaultSession.swift` currently has `init(fileStore: VaultFileStore)` only — compiling unchanged), plus sync integration inside `unlock(password:)` and `persist(_:)`. No change to `VaultSession`'s existing public surface (`state`, `lastSaveError`, `currentDatabase`, `lock()`, `save(password:)`, `mutate(_:)`, `acknowledgeSaveError()`).

- [ ] **Step 1: Write the failing tests**

Append these 3 tests to the end of the existing `MyPassTests/VaultSessionTests.swift` (inside the closing `}` of `final class VaultSessionTests`, after `testRapidBackToBackMutationsBothPersistWithoutCorruption`), and add `import SyncKit` at the top alongside the existing `import XCTest`/`import MyPassKit`/`@testable import MyPass`:

```swift
import XCTest
import MyPassKit
import SyncKit
@testable import MyPass
```

```swift
    func testUnlockWithSyncEngineAppliesMergedResult() throws {
        // Bootstrap a plain (non-syncing) session first, purely to learn the
        // real root group UUID `VaultSession` generates on first unlock —
        // `MergeEngine`'s root merge requires matching root UUIDs between
        // local and remote (Phase 3's MergeEngine.swift rule 9), so the
        // seeded "remote" database below must share it.
        let bootstrapSession = VaultSession(fileStore: fileStore)
        try bootstrapSession.unlock(password: "correct-horse")
        guard case .unlocked(let bootstrapDb) = bootstrapSession.state else {
            return XCTFail("expected unlocked state")
        }
        let rootUUID = bootstrapDb.rootGroup.uuid

        // Seed a "remote" backend directly (bypassing SyncEngine) with a
        // database sharing that root UUID plus one extra entry, simulating
        // a change made on another device.
        let remote = InMemoryStorageBackend()
        var remoteEntry = KdbxEntry(
            uuid: UUID(),
            iconID: 0,
            fields: [],
            creationTime: Date(timeIntervalSince1970: 10_000),
            lastModificationTime: Date(timeIntervalSince1970: 10_000),
            lastAccessTime: Date(timeIntervalSince1970: 10_000),
            locationChanged: Date(timeIntervalSince1970: 10_000),
            history: []
        )
        remoteEntry.title = "From Remote"
        let remoteRoot = KdbxGroup(
            uuid: rootUUID,
            name: "MyPass",
            iconID: 0,
            creationTime: Date(timeIntervalSince1970: 10_000),
            lastModificationTime: Date(timeIntervalSince1970: 10_000),
            locationChanged: Date(timeIntervalSince1970: 10_000),
            entries: [remoteEntry],
            subgroups: []
        )
        let remoteDatabase = KdbxDatabase(rootGroup: remoteRoot, deletedObjects: [])
        try remote.write(try remoteDatabase.save(password: "correct-horse", cipher: .aes256, compression: .gzip))

        // A NEW session, attached to a SyncEngine over that seeded remote,
        // unlocking the SAME local fileStore. The local file predates the
        // remote seed and this session's checkpoint store has never synced
        // before, so unlock must download + merge, picking up the remote's
        // entry too.
        let syncEngine = SyncEngine(remote: remote, checkpointStore: InMemorySyncCheckpointStore())
        let syncedSession = VaultSession(fileStore: fileStore, syncEngine: syncEngine)
        try syncedSession.unlock(password: "correct-horse")

        guard case .unlocked(let mergedDb) = syncedSession.state else {
            return XCTFail("expected unlocked state")
        }
        XCTAssertTrue(mergedDb.rootGroup.entries.contains { $0.title == "From Remote" })
        XCTAssertNil(syncedSession.lastSaveError)

        // The merged result must also have been written back to the LOCAL
        // file — verified by opening a third, plain session against the
        // same fileStore.
        let verifyingSession = VaultSession(fileStore: fileStore)
        try verifyingSession.unlock(password: "correct-horse")
        guard case .unlocked(let dbOnDisk) = verifyingSession.state else {
            return XCTFail("expected unlocked state")
        }
        XCTAssertTrue(dbOnDisk.rootGroup.entries.contains { $0.title == "From Remote" })
    }

    func testPersistWithSyncEngineAlsoSyncsRemote() throws {
        let remote = InMemoryStorageBackend()
        let syncEngine = SyncEngine(remote: remote, checkpointStore: InMemorySyncCheckpointStore())
        let session = VaultSession(fileStore: fileStore, syncEngine: syncEngine)
        try session.unlock(password: "correct-horse")

        // unlock()'s own first-run sync leg already uploaded the initial
        // (empty) database to `remote` — capture that state so the mutation
        // below can be distinguished from it.
        let remoteDataBeforeMutation = try remote.read()

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
        entry.title = "Synced Entry"
        session.mutate { database in
            database.rootGroup.entries.append(entry)
        }

        var sawEntryOnRemote = false
        for _ in 0..<30 {
            if let data = try remote.read(),
               data != remoteDataBeforeMutation,
               let db = try? KdbxDatabase.open(data: data, password: "correct-horse"),
               db.rootGroup.entries.contains(where: { $0.title == "Synced Entry" }) {
                sawEntryOnRemote = true
                break
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertTrue(sawEntryOnRemote, "expected persist()'s background sync leg to upload the mutation to remote within the timeout")
        XCTAssertNil(session.lastSaveError)
    }

    func testPersistSyncFailureSurfacesLastSaveError() throws {
        let remote = InMemoryStorageBackend()
        let syncEngine = SyncEngine(remote: remote, checkpointStore: InMemorySyncCheckpointStore())
        let session = VaultSession(fileStore: fileStore, syncEngine: syncEngine)
        try session.unlock(password: "correct-horse")
        XCTAssertNil(session.lastSaveError)

        // Force ONLY the persist-triggered sync leg to fail — not the
        // initial unlock-time sync, which already completed above.
        struct SimulatedRemoteFailure: Error {}
        remote.writeError = SimulatedRemoteFailure()

        let dataBeforeMutation = try fileStore.load()
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
        entry.title = "Local Only Despite Sync Failure"
        session.mutate { database in
            database.rootGroup.entries.append(entry)
        }

        // The LOCAL save must still succeed even though remote sync will
        // fail — poll the local file exactly as the existing autosave test
        // above does.
        var dataAfterMutation: Data?
        for _ in 0..<30 {
            let candidate = try fileStore.load()
            if candidate != dataBeforeMutation {
                dataAfterMutation = candidate
                break
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertNotNil(dataAfterMutation, "expected the local autosave to succeed even when remote sync fails")

        // `lastSaveError` must become non-nil once the background sync leg
        // fails, and specifically must be a sync-specific message, not the
        // generic local-save-failed one.
        var sawSyncError = false
        for _ in 0..<30 {
            if let message = session.lastSaveError, message.contains("синхронизация") {
                sawSyncError = true
                break
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertTrue(sawSyncError, "expected lastSaveError to surface a sync-specific failure message within the timeout")
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/VaultSessionTests`
Expected: FAIL — compile error (`no such module 'SyncKit'` if Task 1's `project.yml`/`xcodegen generate` wiring hasn't been applied to this checkout yet, otherwise `argument syncEngine could not be matched`/`extra argument` since `VaultSession.init` doesn't accept `syncEngine:` yet).

- [ ] **Step 3: Write minimal implementation**

If `project.yml` does not already list `SyncKit` under `packages:` and under the `MyPass` target's `dependencies:` (Task 1, Step 5, should already have applied this — this step is a no-op re-check, not a duplicate edit), apply it now and run `xcodegen generate`.

Replace the full contents of `MyPass/State/VaultSession.swift` with:

```swift
import Foundation
import MyPassKit
import SyncKit

enum VaultState {
    case locked
    case unlocked(KdbxDatabase)
}

extension VaultState: Equatable {
    static func == (lhs: VaultState, rhs: VaultState) -> Bool {
        switch (lhs, rhs) {
        case (.locked, .locked): return true
        case (.unlocked, .unlocked): return true
        default: return false
        }
    }
}

enum VaultSessionError: Error {
    case notUnlocked
}

final class VaultSession: ObservableObject {
    @Published private(set) var state: VaultState = .locked
    @Published private(set) var lastSaveError: String?

    private let fileStore: VaultFileStore

    /// Optional remote sync orchestrator (Phase 3). `nil` for sessions that
    /// only ever use local storage — every existing Phase 2 call site keeps
    /// compiling and behaving unchanged via the default parameter below.
    private let syncEngine: SyncEngine?

    /// Retained for the lifetime of the unlocked session so every mutation can be
    /// autosaved without re-prompting the user. Wiped on `lock()`.
    private var sessionPassword: String?

    /// Dedicated *serial* background queue for `persist(_:)`'s KDF derivation +
    /// disk write. A concurrent queue would let two back-to-back `persist`
    /// calls race to completion in either order — e.g. a rapid second
    /// `mutate()` could finish its background save before the first one does,
    /// and the (now-stale) first save would then overwrite it, permanently
    /// losing the second mutation on disk even though in-memory state was
    /// correct. Serializing here guarantees writes land in invocation order.
    private let persistQueue = DispatchQueue(label: "com.mypass.vaultsession.persist", qos: .userInitiated)

    init(fileStore: VaultFileStore, syncEngine: SyncEngine? = nil) {
        self.fileStore = fileStore
        self.syncEngine = syncEngine
    }

    var currentDatabase: KdbxDatabase? {
        guard case .unlocked(let db) = state else { return nil }
        return db
    }

    func unlock(password: String) throws {
        if let existingData = try fileStore.load() {
            let db = try KdbxDatabase.open(data: existingData, password: password)
            state = .unlocked(db)
            sessionPassword = password
            state = .unlocked(syncOnUnlock(db, password: password))
        } else {
            let now = Date()
            let rootGroup = KdbxGroup(
                uuid: UUID(),
                name: "MyPass",
                iconID: 0,
                creationTime: now,
                lastModificationTime: now,
                locationChanged: now,
                entries: [],
                subgroups: []
            )
            let db = KdbxDatabase(rootGroup: rootGroup, deletedObjects: [])
            state = .unlocked(db)
            try save(password: password)
            sessionPassword = password
            state = .unlocked(syncOnUnlock(db, password: password))
        }
    }

    func lock() {
        state = .locked
        sessionPassword = nil
    }

    func save(password: String) throws {
        guard case .unlocked(let db) = state else {
            throw VaultSessionError.notUnlocked
        }
        let data = try db.save(password: password, cipher: .aes256, compression: .gzip)
        try fileStore.save(data: data)
    }

    func mutate(_ body: (inout KdbxDatabase) -> Void) {
        guard case .unlocked(var db) = state else { return }
        body(&db)
        state = .unlocked(db)
        persist(db)
    }

    /// Dismisses a surfaced save-error alert without affecting vault state.
    func acknowledgeSaveError() {
        lastSaveError = nil
    }

    /// Runs one `SyncEngine.sync(...)` pass (if a `syncEngine` is attached)
    /// right after unlocking, so a merge made on another device is picked up
    /// as soon as the vault opens rather than only at the next mutation.
    /// Returns `db` unchanged when there is no `syncEngine`, or when sync
    /// itself fails — the local database the user already unlocked must
    /// remain usable even if the network round-trip does not succeed.
    private func syncOnUnlock(_ db: KdbxDatabase, password: String) -> KdbxDatabase {
        guard let syncEngine else { return db }
        let result: SyncResult
        do {
            result = try syncEngine.sync(local: db, password: password, cipher: .aes256, compression: .gzip)
        } catch {
            lastSaveError = "Не удалось синхронизировать хранилище: \(error)"
            return db
        }
        guard case .merged(let mergedDatabase) = result else { return db }
        do {
            let data = try mergedDatabase.save(password: password, cipher: .aes256, compression: .gzip)
            try fileStore.save(data: data)
        } catch {
            lastSaveError = "Не удалось сохранить объединённые изменения локально: \(error)"
        }
        return mergedDatabase
    }

    private func persist(_ db: KdbxDatabase) {
        guard let sessionPassword else { return }
        // Deep-copy the group tree synchronously (main thread, no concurrent
        // writer yet) so the background save operates on a fully independent
        // snapshot instead of the live, still-mutable `rootGroup` reference.
        let snapshot = KdbxDatabase(
            rootGroup: db.rootGroup.deepCopy(),
            deletedObjects: db.deletedObjects,
            recycleBinGroupUUID: db.recycleBinGroupUUID
        )
        persistQueue.async { [fileStore, syncEngine] in
            do {
                let data = try snapshot.save(password: sessionPassword, cipher: .aes256, compression: .gzip)
                try fileStore.save(data: data)
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.lastSaveError = "Не удалось сохранить изменения: \(error)"
                }
                return
            }
            guard let syncEngine else {
                DispatchQueue.main.async { [weak self] in
                    self?.lastSaveError = nil
                }
                return
            }
            // Note: a possible `.merged(...)` result from this call is
            // intentionally NOT adopted back into `state` here — this
            // background queue must not mutate `@Published` state off the
            // main thread, and reconciling a concurrent remote-side change
            // mid-session (as opposed to at the next unlock, where
            // `syncOnUnlock` already does adopt it) is deferred to a later
            // task. This task's contract is only that every LOCAL mutation
            // reaches remote, which is what the tests above verify.
            do {
                _ = try syncEngine.sync(local: snapshot, password: sessionPassword, cipher: .aes256, compression: .gzip)
                DispatchQueue.main.async { [weak self] in
                    self?.lastSaveError = nil
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.lastSaveError = "Локальное сохранение выполнено, но синхронизация не удалась: \(error)"
                }
            }
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/VaultSessionTests`
Expected: PASS (7/7 — 4 existing + 3 new).

- [ ] **Step 5: Run the full MyPass test suite to check for regressions**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS'`, then `cd Packages/SyncKit && swift test`, then `cd Packages/MyPassKit && swift test`
Expected: all pass — every existing `VaultSession` call site across `MyPass/` (views/view models constructing `VaultSession(fileStore:)` without a `syncEngine:` argument) keeps compiling unchanged, since the new parameter defaults to `nil`.

- [ ] **Step 6: Commit**

```bash
git add MyPass/State/VaultSession.swift MyPassTests/VaultSessionTests.swift project.yml
git commit -m "VaultSession: подключить SyncEngine — sync при unlock и при persist (Фаза 3, Task 7)"
```

---

### Task 8: Выбор SFTP-библиотеки — Citadel

**Files:**
- Modify: `Packages/SyncKit/Package.swift` (добавить зависимость на Citadel)
- Test: `Packages/SyncKit/Tests/SyncKitTests/CitadelDependencySmokeTests.swift`

**Interfaces:**
- Consumes: ничего из предыдущих задач Фазы 3 напрямую — это задача выбора и подключения третьесторонней зависимости, которую Task 10 затем использует для реализации `SFTPBackend`.
- Produces: обновлённый `Packages/SyncKit/Package.swift` с зависимостью `orlandos-nl/Citadel` (продукт `Citadel`), плюс подтверждение (через smoke-тесты) что реальные типы `Citadel`-библиотеки (`Curve25519.Signing.PrivateKey(sshEd25519:decryptionKey:)`, `SSHAuthenticationMethod.ed25519(username:privateKey:)`, `InvalidOpenSSHKey`) линкуются и работают как ожидается. Потребляется Task 10 (`SFTPBackend`, `TrustOnFirstUseHostKeyValidator`).

**Решение: Citadel, а не mft.**

Global Constraints (шапка плана) формулирует выбор как «Citadel или mft». `mplpl/mft` («Swift SFTP Client Framework») — реальная библиотека, но распространяется только как Xcode-проект (`mft.xcodeproj`), собирающий вокруг забандленных бинарных `libssh 0.11.0`/`openssl 3.3.1` в виде xcframework — у неё нет `Package.swift`, и подключить её к `Packages/SyncKit` (чистый SwiftPM-пакет, где каждая задача этого плана запускается через `swift build`/`swift test`) означало бы либо векорить xcframework вручную в репозиторий, либо писать собственный `Package.swift`-обёртку с бинарной целью — оба варианта выходят за рамки «пакет с локальной path-зависимостью на MyPassKit» из Architecture-строки плана. Citadel (`orlandos-nl/Citadel`), напротив:
- чистый Swift поверх `apple/swift-nio` + форка `Wellz26/swift-nio-ssh`, подключается обычной строкой `.package(url:from:)` — без бинарных артефактов;
- async/await-нативный SSH/SFTP-клиент (`SSHClient`, `SFTPClient`) с реальным, подтверждённым API: `SSHClient.connect(host:port:authenticationMethod:hostKeyValidator:reconnect:...)`, `SSHAuthenticationMethod.ed25519(username:privateKey:)`, `SSHHostKeyValidator.custom(_:)` (кастомная TOFU-валидация — см. Task 10), `Curve25519.Signing.PrivateKey(sshEd25519:decryptionKey:)` (парсинг зашифрованного passphrase'ом OpenSSH-ключа) — всё подтверждено прямым чтением исходников `orlandos-nl/Citadel` тега `0.12.1`;
- уже поддерживает SFTP (`SFTPClient`, `SFTPFileAttributes`, `SFTPOpenFileFlags`) как часть той же библиотеки, а не отдельного пакета.

- [ ] **Step 1: Write the failing test**

Create `Packages/SyncKit/Tests/SyncKitTests/CitadelDependencySmokeTests.swift`:

```swift
import XCTest
import Crypto
import Citadel

/// Real, unencrypted-fixture-free smoke tests confirming Citadel is
/// correctly linked and its public API behaves as documented — not an
/// end-to-end SFTP test (that's Task 10's Docker-gated
/// `SFTPBackendTests`). The encrypted keypair used here is real, generated
/// via:
/// `ssh-keygen -t ed25519 -N "correct-horse-battery-staple" -f /tmp/citadel_smoke_key -C "smoketest@mypass"`
final class CitadelDependencySmokeTests: XCTestCase {
    private let passphrase = "correct-horse-battery-staple"

    private func loadEncryptedPrivateKeyData() throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: "/tmp/citadel_smoke_key"))
    }

    func testCitadelTypesAreLinkedAndImportable() {
        // If SyncKit's Package.swift didn't correctly add Citadel as a
        // dependency + product, this file wouldn't even compile — this test
        // exists as an explicit, readable assertion of that fact.
        XCTAssertNotNil(SSHAlgorithms.self)
        XCTAssertNotNil(SSHReconnectMode.self)
    }

    func testDecryptingRealPrivateKeyWithCorrectPassphraseSucceeds() throws {
        let keyData = try loadEncryptedPrivateKeyData()
        let privateKey = try Curve25519.Signing.PrivateKey(sshEd25519: keyData, decryptionKey: passphrase.data(using: .utf8)!)
        XCTAssertFalse(privateKey.publicKey.rawRepresentation.isEmpty)
    }

    func testWrongPassphraseThrowsInvalidOpenSSHKey() throws {
        let keyData = try loadEncryptedPrivateKeyData()
        XCTAssertThrowsError(
            try Curve25519.Signing.PrivateKey(sshEd25519: keyData, decryptionKey: "wrong-passphrase".data(using: .utf8)!)
        ) { error in
            // `InvalidOpenSSHKey`'s specific cases/`UnsupportedFeature` enum
            // are what Citadel actually throws for a malformed/undecryptable
            // key — this asserts the error TYPE, which is public.
            XCTAssertTrue(error is InvalidOpenSSHKey)
        }
    }

    func testMissingPassphraseThrowsForAnEncryptedKey() throws {
        let keyData = try loadEncryptedPrivateKeyData()
        XCTAssertThrowsError(
            try Curve25519.Signing.PrivateKey(sshEd25519: keyData, decryptionKey: nil)
        )
    }

    func testSSHAuthenticationMethodEd25519AcceptsTheDecryptedKey() throws {
        let keyData = try loadEncryptedPrivateKeyData()
        let privateKey = try Curve25519.Signing.PrivateKey(sshEd25519: keyData, decryptionKey: passphrase.data(using: .utf8)!)
        // Constructing the authentication method must not throw — this is
        // exactly the call `SFTPBackend` (Task 10) makes with a decrypted key.
        _ = SSHAuthenticationMethod.ed25519(username: "smoketest", privateKey: privateKey)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd Packages/SyncKit && swift test --filter CitadelDependencySmokeTests`
Expected: FAIL — `no such module 'Citadel'` (compile error, dependency not yet added).

- [ ] **Step 3: Write minimal implementation**

Generate the real fixture referenced by the test above (run once, outside the test suite, before `swift test`):

```bash
ssh-keygen -t ed25519 -N "correct-horse-battery-staple" -f /tmp/citadel_smoke_key -C "smoketest@mypass"
```

Replace `Packages/SyncKit/Package.swift`'s `dependencies:`/`SyncKit`-target `dependencies:`/`SyncKitTests`-target `dependencies:` (the rest of the file — `name`, `platforms: [.macOS(.v14)]`, `products:` — is unchanged from Task 1):

```swift
    dependencies: [
        .package(path: "../MyPassKit"),
        .package(url: "https://github.com/orlandos-nl/Citadel.git", from: "0.12.1")
    ],
    targets: [
        .target(
            name: "SyncKit",
            dependencies: [
                .product(name: "MyPassKit", package: "MyPassKit"),
                .product(name: "Citadel", package: "Citadel")
            ]
        ),
        .testTarget(
            name: "SyncKitTests",
            dependencies: [
                "SyncKit",
                .product(name: "Citadel", package: "Citadel")
            ]
        )
    ]
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd Packages/SyncKit && swift test --filter CitadelDependencySmokeTests`
Expected: PASS (4/4) — SwiftPM resolves and builds Citadel (and its transitive `swift-nio`/`Wellz26/swift-nio-ssh`/`swift-crypto` dependencies) successfully.

- [ ] **Step 5: Run the full SyncKit suite to check for regressions**

Run: `cd Packages/SyncKit && swift test`
Expected: all `SyncKitTests` (Tasks 1-8, cumulative) PASS.

- [ ] **Step 6: Commit**

```bash
git add Packages/SyncKit/Package.swift Packages/SyncKit/Tests/SyncKitTests/CitadelDependencySmokeTests.swift
git commit -m "SyncKit: подключить Citadel (SFTP-библиотека) — smoke-тесты (Фаза 3, Task 8)"
```

---

### Task 9: CredentialKeychainStore — хранение SFTP-учётных данных в Keychain

**Files:**
- Create: `Packages/SyncKit/Sources/SyncKit/CredentialKeychainStore.swift`
- Test: `Packages/SyncKit/Tests/SyncKitTests/CredentialKeychainStoreTests.swift`

**Interfaces:**
- Consumes: `Security` framework (`SecItemAdd`/`SecItemCopyMatching`/`SecItemDelete`), тот же паттерн Keychain-доступа, что и `BiometricKeyStore` (Фаза 2) — generic password item (`kSecClassGenericPassword`) с `kSecAttrService`/`kSecAttrAccount`, а не biometry-gated item (без `kSecAttrAccessControl`/`LAContext`, так как SFTP-учётные данные не должны требовать Touch ID на каждый sync-цикл).
- Produces:
```swift
public struct SFTPCredentials: Equatable, Codable {
    public var username: String
    public var privateKeyPEM: String
    public var privateKeyPassphrase: String?
    public init(username: String, privateKeyPEM: String, privateKeyPassphrase: String? = nil)
}

public protocol CredentialStoring {
    func loadCredentials(forHost host: String) throws -> SFTPCredentials?
    func store(_ credentials: SFTPCredentials, forHost host: String) throws
    func removeCredentials(forHost host: String) throws
}

public enum CredentialKeychainStoreError: Error {
    case unexpectedStatus(OSStatus)
    case encodingFailed
    case decodingFailed
}

public final class CredentialKeychainStore: CredentialStoring {
    public init()
}

public final class InMemoryCredentialStore: CredentialStoring {
    public init()
}
```
Consumed by Task 10 (`SFTPBackend`'s caller assembles an `SFTPBackendConfiguration` from a loaded `SFTPCredentials` value — `SFTPBackend` itself takes already-resolved key material and does not import `CredentialStoring` directly, so `SFTPBackend` and `CredentialKeychainStore` stay independently testable) and by a future UI task (out of scope here) that lets the user enter/edit SFTP credentials.

- [ ] **Step 1: Write the failing test**

Create `Packages/SyncKit/Tests/SyncKitTests/CredentialKeychainStoreTests.swift`:

```swift
import XCTest
@testable import SyncKit

final class CredentialKeychainStoreTests: XCTestCase {
    // MARK: - InMemoryCredentialStore (always run — no external dependency)

    func testInMemoryStoreRoundTripsCredentials() throws {
        let store = InMemoryCredentialStore()
        let credentials = SFTPCredentials(username: "alice", privateKeyPEM: "-----BEGIN...-----", privateKeyPassphrase: "s3cret")

        XCTAssertNil(try store.loadCredentials(forHost: "sftp.example.com"))
        try store.store(credentials, forHost: "sftp.example.com")
        XCTAssertEqual(try store.loadCredentials(forHost: "sftp.example.com"), credentials)
    }

    func testInMemoryStoreKeepsHostsIndependent() throws {
        let store = InMemoryCredentialStore()
        let credentialsA = SFTPCredentials(username: "alice", privateKeyPEM: "key-a")
        let credentialsB = SFTPCredentials(username: "bob", privateKeyPEM: "key-b")

        try store.store(credentialsA, forHost: "host-a.example.com")
        try store.store(credentialsB, forHost: "host-b.example.com")

        XCTAssertEqual(try store.loadCredentials(forHost: "host-a.example.com"), credentialsA)
        XCTAssertEqual(try store.loadCredentials(forHost: "host-b.example.com"), credentialsB)
    }

    func testInMemoryStoreRemoveCredentials() throws {
        let store = InMemoryCredentialStore()
        try store.store(SFTPCredentials(username: "alice", privateKeyPEM: "key"), forHost: "sftp.example.com")
        try store.removeCredentials(forHost: "sftp.example.com")
        XCTAssertNil(try store.loadCredentials(forHost: "sftp.example.com"))
    }

    func testInMemoryStoreOverwritesExistingCredentialsForSameHost() throws {
        let store = InMemoryCredentialStore()
        try store.store(SFTPCredentials(username: "alice", privateKeyPEM: "old-key"), forHost: "sftp.example.com")
        try store.store(SFTPCredentials(username: "alice", privateKeyPEM: "new-key"), forHost: "sftp.example.com")
        XCTAssertEqual(try store.loadCredentials(forHost: "sftp.example.com")?.privateKeyPEM, "new-key")
    }

    // MARK: - CredentialKeychainStore (real Keychain — gated, matches Phase 2's BiometricKeyStore convention)

    private func requireKeychainTestsEnabled() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MYPASS_KEYCHAIN_TESTS"] == "1",
            "set MYPASS_KEYCHAIN_TESTS=1 to run tests against the real Keychain"
        )
    }

    private let realTestHost = "mypass-keychain-tests.invalid"

    override func tearDown() {
        try? CredentialKeychainStore().removeCredentials(forHost: realTestHost)
        super.tearDown()
    }

    func testRealKeychainStoreRoundTripsCredentials() throws {
        try requireKeychainTestsEnabled()
        let store = CredentialKeychainStore()
        let credentials = SFTPCredentials(username: "alice", privateKeyPEM: "-----BEGIN...-----", privateKeyPassphrase: "s3cret")

        try store.store(credentials, forHost: realTestHost)
        XCTAssertEqual(try store.loadCredentials(forHost: realTestHost), credentials)
    }

    func testRealKeychainStoreReturnsNilForUnknownHost() throws {
        try requireKeychainTestsEnabled()
        let store = CredentialKeychainStore()
        XCTAssertNil(try store.loadCredentials(forHost: "definitely-not-stored.invalid"))
    }

    func testRealKeychainStoreOverwriteReplacesPreviousCredentials() throws {
        try requireKeychainTestsEnabled()
        let store = CredentialKeychainStore()
        try store.store(SFTPCredentials(username: "alice", privateKeyPEM: "old-key"), forHost: realTestHost)
        try store.store(SFTPCredentials(username: "alice", privateKeyPEM: "new-key"), forHost: realTestHost)
        XCTAssertEqual(try store.loadCredentials(forHost: realTestHost)?.privateKeyPEM, "new-key")
    }

    func testRealKeychainStoreRemoveCredentials() throws {
        try requireKeychainTestsEnabled()
        let store = CredentialKeychainStore()
        try store.store(SFTPCredentials(username: "alice", privateKeyPEM: "key"), forHost: realTestHost)
        try store.removeCredentials(forHost: realTestHost)
        XCTAssertNil(try store.loadCredentials(forHost: realTestHost))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd Packages/SyncKit && swift test --filter CredentialKeychainStoreTests`
Expected: FAIL — `SFTPCredentials`/`CredentialStoring`/`CredentialKeychainStore`/`InMemoryCredentialStore` do not exist yet (compile error).

- [ ] **Step 3: Write minimal implementation**

Create `Packages/SyncKit/Sources/SyncKit/CredentialKeychainStore.swift`:

```swift
import Foundation
import Security

public struct SFTPCredentials: Equatable, Codable {
    public var username: String
    public var privateKeyPEM: String
    public var privateKeyPassphrase: String?

    public init(username: String, privateKeyPEM: String, privateKeyPassphrase: String? = nil) {
        self.username = username
        self.privateKeyPEM = privateKeyPEM
        self.privateKeyPassphrase = privateKeyPassphrase
    }
}

public protocol CredentialStoring {
    func loadCredentials(forHost host: String) throws -> SFTPCredentials?
    func store(_ credentials: SFTPCredentials, forHost host: String) throws
    func removeCredentials(forHost host: String) throws
}

public enum CredentialKeychainStoreError: Error {
    case unexpectedStatus(OSStatus)
    case encodingFailed
    case decodingFailed
}

/// Stores SFTP credentials as a generic-password Keychain item, keyed by
/// host — mirrors `BiometricKeyStore`'s (Phase 2) Keychain access pattern,
/// minus biometry: SFTP sync must be able to run in the background (e.g. an
/// autosave-triggered upload) without prompting Touch ID on every cycle, so
/// this uses a plain `kSecAttrAccessibleAfterFirstUnlock` item rather than a
/// `kSecAttrAccessControl`-gated one.
public final class CredentialKeychainStore: CredentialStoring {
    private let service = "com.mypass.sftp.credentials"

    public init() {}

    public func loadCredentials(forHost host: String) throws -> SFTPCredentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: host,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw CredentialKeychainStoreError.unexpectedStatus(status)
        }
        guard let credentials = try? JSONDecoder().decode(SFTPCredentials.self, from: data) else {
            throw CredentialKeychainStoreError.decodingFailed
        }
        return credentials
    }

    public func store(_ credentials: SFTPCredentials, forHost host: String) throws {
        guard let data = try? JSONEncoder().encode(credentials) else {
            throw CredentialKeychainStoreError.encodingFailed
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: host
        ]
        // Delete-then-add (rather than SecItemUpdate) — same pattern as
        // BiometricKeyStore, avoiding having to diff old/new attribute
        // dictionaries for an update.
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw CredentialKeychainStoreError.unexpectedStatus(status)
        }
    }

    public func removeCredentials(forHost host: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: host
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialKeychainStoreError.unexpectedStatus(status)
        }
    }
}

public final class InMemoryCredentialStore: CredentialStoring {
    private var storage: [String: SFTPCredentials] = [:]

    public init() {}

    public func loadCredentials(forHost host: String) throws -> SFTPCredentials? { storage[host] }
    public func store(_ credentials: SFTPCredentials, forHost host: String) throws { storage[host] = credentials }
    public func removeCredentials(forHost host: String) throws { storage.removeValue(forKey: host) }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd Packages/SyncKit && swift test --filter CredentialKeychainStoreTests`
Expected: PASS (4/4 — the 4 `InMemoryCredentialStore` tests; the 4 real-Keychain tests `XCTSkip` by default). With `MYPASS_KEYCHAIN_TESTS=1 swift test --filter CredentialKeychainStoreTests`: PASS (8/8).

- [ ] **Step 5: Run the full SyncKit suite to check for regressions**

Run: `cd Packages/SyncKit && swift test`
Expected: all `SyncKitTests` (Tasks 1-9, cumulative) PASS.

- [ ] **Step 6: Commit**

```bash
git add Packages/SyncKit/Sources/SyncKit/CredentialKeychainStore.swift Packages/SyncKit/Tests/SyncKitTests/CredentialKeychainStoreTests.swift
git commit -m "SyncKit: CredentialKeychainStore — хранение SFTP-учётных данных в Keychain (Фаза 3, Task 9)"
```

---

### Task 10: SFTPBackend — StorageBackend поверх Citadel с TOFU host-key проверкой

**Files:**
- Modify: `Packages/SyncKit/Package.swift` (добавить `swift-nio`, `Wellz26/swift-nio-ssh` как явные зависимости — Citadel уже тянет их транзитивно с Task 8, но `SFTPBackend`/`TrustOnFirstUseHostKeyValidator` используют `NIO`/`NIOFoundationCompat`/`NIOSSH`-типы напрямую, что требует явных `.product(...)` записей)
- Create: `Packages/SyncKit/Sources/SyncKit/TrustOnFirstUseHostKeyValidator.swift`
- Create: `Packages/SyncKit/Sources/SyncKit/SFTPBackend.swift`
- Test: `Packages/SyncKit/Tests/SyncKitTests/TrustOnFirstUseHostKeyValidatorTests.swift`
- Test: `Packages/SyncKit/Tests/SyncKitTests/SFTPBackendTests.swift`

**Interfaces:**
- Consumes: `StorageBackend` (Task 1), Citadel (Task 8) — `SSHClient.connect(host:port:authenticationMethod:hostKeyValidator:reconnect:group:)`, `SSHClient.close()`, `SSHClient.withSFTP(_:)`, `SFTPClient.getAttributes(at:)`/`.withFile(filePath:flags:_:)`/`.remove(at:)`/`.rename(at:to:)`, `SFTPOpenFileFlags`, `SFTPFileAttributes.accessModificationTime?.modificationTime`, `SSHHostKeyValidator.custom(_:)`, `SSHAuthenticationMethod.ed25519(username:privateKey:)`, `Curve25519.Signing.PrivateKey(sshEd25519:decryptionKey:)` — `apple/swift-nio-ssh`'s `NIOSSHClientServerAuthenticationDelegate`/`NIOSSHPublicKey`/`String(openSSHPublicKey:)` — `CredentialStoring`/`SFTPCredentials` (Task 9, consumed by the CALLER that assembles `SFTPBackendConfiguration`, not by `SFTPBackend` itself).
- Produces:
```swift
public protocol TrustedHostKeyStore {
    func trustedKey(forHost host: String) -> String?
    func trust(_ openSSHPublicKey: String, forHost host: String)
}
public final class UserDefaultsTrustedHostKeyStore: TrustedHostKeyStore {
    public init(defaults: UserDefaults = .standard, keyPrefix: String = "com.mypass.sync.trustedhostkey.")
}
public final class InMemoryTrustedHostKeyStore: TrustedHostKeyStore {
    public init()
}
public struct TrustOnFirstUseError: Error, Equatable {
    public let host: String
}
public final class TrustOnFirstUseHostKeyValidator: NIOSSHClientServerAuthenticationDelegate {
    public init(host: String, store: TrustedHostKeyStore)
}

public enum SFTPBackendError: Error {
    case invalidPrivateKey
    case remoteWriteVerificationFailed
}
public struct SFTPBackendConfiguration {
    public var host: String
    public var port: Int
    public var username: String
    public var remotePath: String
    public var privateKeyPEM: String
    public var privateKeyPassphrase: String?
    public init(host: String, port: Int = 22, username: String, remotePath: String, privateKeyPEM: String, privateKeyPassphrase: String? = nil)
}
public final class SFTPBackend: StorageBackend {
    public init(configuration: SFTPBackendConfiguration, trustedHostKeyStore: TrustedHostKeyStore, group: MultiThreadedEventLoopGroup = .singleton)
}
```
`SFTPBackend` is the concrete `StorageBackend` handed to `SyncEngine` (Task 6) once a user configures an SFTP remote — no changes to `SyncEngine` itself are needed, per Task 6's design goal of any `StorageBackend` being pluggable. `TrustOnFirstUseHostKeyValidator` implements TOFU (trust-on-first-use) host-key verification: the first connection to a given host remembers whatever key it presents; every later connection to that same host must present the SAME key, or the connection is rejected — the SFTP/SSH equivalent of the browser's first-visit certificate pinning.

- [ ] **Step 1: Write the failing tests**

Create `Packages/SyncKit/Tests/SyncKitTests/TrustOnFirstUseHostKeyValidatorTests.swift`:

```swift
import XCTest
import NIO
import NIOSSH
@testable import SyncKit

final class TrustOnFirstUseHostKeyValidatorTests: XCTestCase {
    // Real, unencrypted ed25519 keypairs generated via:
    // ssh-keygen -t ed25519 -N "" -f /tmp/hostkey_a -C "host-a"
    // ssh-keygen -t ed25519 -N "" -f /tmp/hostkey_b -C "host-b"
    let hostAPublicKeyLine = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILMtFVDUwqOoM7g68ED7dV5kvQwaHOKj8vFSgQe4pfZf host-a"
    let hostBPublicKeyLine = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHSHgscXo+yGTJIEJuR3c7U88BLVkTk6uRyC666C19di host-b"

    func validate(_ validator: TrustOnFirstUseHostKeyValidator, publicKeyLine: String, eventLoop: EmbeddedEventLoop) throws {
        let hostKey = try NIOSSHPublicKey(openSSHPublicKey: publicKeyLine)
        let promise = eventLoop.makePromise(of: Void.self)
        validator.validateHostKey(hostKey: hostKey, validationCompletePromise: promise)
        try promise.futureResult.wait()
    }

    func testFirstConnectionTrustsAndSucceeds() throws {
        let eventLoop = EmbeddedEventLoop()
        defer { try? eventLoop.syncShutdownGracefully() }
        let store = InMemoryTrustedHostKeyStore()
        let validator = TrustOnFirstUseHostKeyValidator(host: "sftp.example.com", store: store)

        XCTAssertNil(store.trustedKey(forHost: "sftp.example.com"))
        try validate(validator, publicKeyLine: hostAPublicKeyLine, eventLoop: eventLoop)
        XCTAssertEqual(store.trustedKey(forHost: "sftp.example.com"), hostAPublicKeyLine)
    }

    func testSecondConnectionWithSameKeySucceeds() throws {
        let eventLoop = EmbeddedEventLoop()
        defer { try? eventLoop.syncShutdownGracefully() }
        let store = InMemoryTrustedHostKeyStore()
        let validator = TrustOnFirstUseHostKeyValidator(host: "sftp.example.com", store: store)

        try validate(validator, publicKeyLine: hostAPublicKeyLine, eventLoop: eventLoop)
        try validate(validator, publicKeyLine: hostAPublicKeyLine, eventLoop: eventLoop)

        XCTAssertEqual(store.trustedKey(forHost: "sftp.example.com"), hostAPublicKeyLine)
    }

    func testDifferentKeyForSameHostFails() throws {
        let eventLoop = EmbeddedEventLoop()
        defer { try? eventLoop.syncShutdownGracefully() }
        let store = InMemoryTrustedHostKeyStore()
        let validator = TrustOnFirstUseHostKeyValidator(host: "sftp.example.com", store: store)

        try validate(validator, publicKeyLine: hostAPublicKeyLine, eventLoop: eventLoop)

        XCTAssertThrowsError(try validate(validator, publicKeyLine: hostBPublicKeyLine, eventLoop: eventLoop)) { error in
            XCTAssertEqual(error as? TrustOnFirstUseError, TrustOnFirstUseError(host: "sftp.example.com"))
        }
        // The originally-trusted key must remain unchanged after a rejected attempt.
        XCTAssertEqual(store.trustedKey(forHost: "sftp.example.com"), hostAPublicKeyLine)
    }

    func testDifferentHostsAreTrustedIndependently() throws {
        let eventLoop = EmbeddedEventLoop()
        defer { try? eventLoop.syncShutdownGracefully() }
        let store = InMemoryTrustedHostKeyStore()
        let validatorA = TrustOnFirstUseHostKeyValidator(host: "host-a.example.com", store: store)
        let validatorB = TrustOnFirstUseHostKeyValidator(host: "host-b.example.com", store: store)

        try validate(validatorA, publicKeyLine: hostAPublicKeyLine, eventLoop: eventLoop)
        try validate(validatorB, publicKeyLine: hostBPublicKeyLine, eventLoop: eventLoop)

        XCTAssertEqual(store.trustedKey(forHost: "host-a.example.com"), hostAPublicKeyLine)
        XCTAssertEqual(store.trustedKey(forHost: "host-b.example.com"), hostBPublicKeyLine)
    }
}
```

Create `Packages/SyncKit/Tests/SyncKitTests/SFTPBackendTests.swift`:

```swift
import XCTest
import NIO
@testable import SyncKit

/// End-to-end tests against a REAL SFTP server, run only when explicitly
/// opted into via `MYPASS_SFTP_INTEGRATION_TESTS=1` — matches this plan's
/// existing convention (Task 9's `MYPASS_KEYCHAIN_TESTS=1`) for tests that
/// depend on an external resource rather than a pure in-process fake.
///
/// To exercise these locally:
///
/// ```sh
/// docker run -d --name mypass-sftp-test -p 2222:22 \
///   -v /tmp/citadel_smoke_key.pub:/home/testuser/.ssh/keys/id_ed25519.pub:ro \
///   -e SFTP_USERS=testuser::1001 \
///   atmoz/sftp
/// MYPASS_SFTP_INTEGRATION_TESTS=1 swift test --filter SFTPBackendTests
/// docker rm -f mypass-sftp-test
/// ```
///
/// `/tmp/citadel_smoke_key` is the real encrypted ed25519 keypair generated
/// in Task 8, Step 3.
final class SFTPBackendTests: XCTestCase {
    private func requireSFTPIntegrationTestsEnabled() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MYPASS_SFTP_INTEGRATION_TESTS"] == "1",
            "set MYPASS_SFTP_INTEGRATION_TESTS=1 (and run the atmoz/sftp Docker container described in this file's header comment) to run tests against a real SFTP server"
        )
    }

    private func makeConfiguration(remotePath: String) throws -> SFTPBackendConfiguration {
        let privateKeyPEM = try String(contentsOfFile: "/tmp/citadel_smoke_key", encoding: .utf8)
        return SFTPBackendConfiguration(
            host: "127.0.0.1",
            port: 2222,
            username: "testuser",
            remotePath: remotePath,
            privateKeyPEM: privateKeyPEM,
            privateKeyPassphrase: "correct-horse-battery-staple"
        )
    }

    func testExistsIsFalseForAPathThatHasNeverBeenWritten() throws {
        try requireSFTPIntegrationTestsEnabled()
        let configuration = try makeConfiguration(remotePath: "/upload/does-not-exist-\(UUID().uuidString).kdbx")
        let backend = SFTPBackend(configuration: configuration, trustedHostKeyStore: InMemoryTrustedHostKeyStore())

        XCTAssertFalse(try backend.exists())
        XCTAssertNil(try backend.read())
    }

    func testWriteThenReadRoundTripsBytesExactly() throws {
        try requireSFTPIntegrationTestsEnabled()
        let configuration = try makeConfiguration(remotePath: "/upload/round-trip-\(UUID().uuidString).kdbx")
        let backend = SFTPBackend(configuration: configuration, trustedHostKeyStore: InMemoryTrustedHostKeyStore())

        let payload = Data("Hello, MyPass over SFTP!".utf8)
        try backend.write(payload)

        XCTAssertTrue(try backend.exists())
        XCTAssertEqual(try backend.read(), payload)
    }

    func testWriteTwiceReplacesThePreviousContent() throws {
        try requireSFTPIntegrationTestsEnabled()
        let configuration = try makeConfiguration(remotePath: "/upload/overwrite-\(UUID().uuidString).kdbx")
        let backend = SFTPBackend(configuration: configuration, trustedHostKeyStore: InMemoryTrustedHostKeyStore())

        try backend.write(Data("first version".utf8))
        try backend.write(Data("second, longer version".utf8))

        XCTAssertEqual(try backend.read(), Data("second, longer version".utf8))
    }

    func testModificationDateAdvancesAcrossWrites() throws {
        try requireSFTPIntegrationTestsEnabled()
        let configuration = try makeConfiguration(remotePath: "/upload/modtime-\(UUID().uuidString).kdbx")
        let backend = SFTPBackend(configuration: configuration, trustedHostKeyStore: InMemoryTrustedHostKeyStore())

        try backend.write(Data("v1".utf8))
        let firstModificationDate = try XCTUnwrap(backend.modificationDate())

        Thread.sleep(forTimeInterval: 1.1)
        try backend.write(Data("v2".utf8))
        let secondModificationDate = try XCTUnwrap(backend.modificationDate())

        XCTAssertGreaterThan(secondModificationDate, firstModificationDate)
    }

    func testSecondConnectionWithTheSameHostKeyStoreSucceedsAfterTrustOnFirstUse() throws {
        try requireSFTPIntegrationTestsEnabled()
        let configuration = try makeConfiguration(remotePath: "/upload/tofu-\(UUID().uuidString).kdbx")
        let hostKeyStore = InMemoryTrustedHostKeyStore()

        let firstBackend = SFTPBackend(configuration: configuration, trustedHostKeyStore: hostKeyStore)
        try firstBackend.write(Data("first connection".utf8))
        XCTAssertNotNil(hostKeyStore.trustedKey(forHost: configuration.hostKeyIdentifier))

        // A second, independent backend reusing the SAME host key store must
        // succeed too — the host key trusted on the first connection must
        // match what the server presents again.
        let secondBackend = SFTPBackend(configuration: configuration, trustedHostKeyStore: hostKeyStore)
        XCTAssertEqual(try secondBackend.read(), Data("first connection".utf8))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd Packages/SyncKit && swift test --filter TrustOnFirstUseHostKeyValidatorTests`
Expected: FAIL — `TrustOnFirstUseHostKeyValidator`/`InMemoryTrustedHostKeyStore`/`TrustOnFirstUseError` do not exist yet (compile error).
Run: `cd Packages/SyncKit && swift test --filter SFTPBackendTests`
Expected: FAIL — `SFTPBackend`/`SFTPBackendConfiguration` do not exist yet (compile error). Once `MYPASS_SFTP_INTEGRATION_TESTS=1` is also set against a real Docker container (Step 4 below), still expected to fail the same way until Step 3 is applied.

- [ ] **Step 3: Write minimal implementation**

Generate the two real, unencrypted host-key fixtures referenced by `TrustOnFirstUseHostKeyValidatorTests` (run once, outside the test suite):

```bash
ssh-keygen -t ed25519 -N "" -f /tmp/hostkey_a -C "host-a"
ssh-keygen -t ed25519 -N "" -f /tmp/hostkey_b -C "host-b"
```

(the two `let hostAPublicKeyLine`/`hostBPublicKeyLine` constants in the test above must be replaced with whatever `cat /tmp/hostkey_a.pub`/`cat /tmp/hostkey_b.pub` actually print — ed25519 public key material is deterministic from the private key, so the literal base64 blob shown above is illustrative and will differ per-generation; the executing agent must substitute the real generated value before running Step 4.)

Add `swift-nio` and the `Wellz26/swift-nio-ssh` fork Citadel itself depends on as explicit dependencies in `Packages/SyncKit/Package.swift` (full updated `dependencies:`/targets' `dependencies:`, replacing Task 8's version):

```swift
    dependencies: [
        .package(path: "../MyPassKit"),
        .package(url: "https://github.com/orlandos-nl/Citadel.git", from: "0.12.1"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0"),
        .package(url: "https://github.com/Wellz26/swift-nio-ssh.git", "0.3.4"..<"0.4.0")
    ],
    targets: [
        .target(
            name: "SyncKit",
            dependencies: [
                .product(name: "MyPassKit", package: "MyPassKit"),
                .product(name: "Citadel", package: "Citadel"),
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
                .product(name: "NIOSSH", package: "swift-nio-ssh")
            ]
        ),
        .testTarget(
            name: "SyncKitTests",
            dependencies: [
                "SyncKit",
                .product(name: "Citadel", package: "Citadel"),
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOSSH", package: "swift-nio-ssh")
            ]
        )
    ]
```

(the version range `"0.3.4"..<"0.4.0"` for `Wellz26/swift-nio-ssh` matches Citadel `0.12.1`'s own transitive constraint on the same fork, avoiding a diamond-dependency version conflict.)

Create `Packages/SyncKit/Sources/SyncKit/TrustOnFirstUseHostKeyValidator.swift`:

```swift
import Foundation
import NIO
import NIOSSH

public protocol TrustedHostKeyStore {
    func trustedKey(forHost host: String) -> String?
    func trust(_ openSSHPublicKey: String, forHost host: String)
}

public final class UserDefaultsTrustedHostKeyStore: TrustedHostKeyStore {
    private let defaults: UserDefaults
    private let keyPrefix: String

    public init(defaults: UserDefaults = .standard, keyPrefix: String = "com.mypass.sync.trustedhostkey.") {
        self.defaults = defaults
        self.keyPrefix = keyPrefix
    }

    public func trustedKey(forHost host: String) -> String? {
        defaults.string(forKey: keyPrefix + host)
    }

    public func trust(_ openSSHPublicKey: String, forHost host: String) {
        defaults.set(openSSHPublicKey, forKey: keyPrefix + host)
    }
}

public final class InMemoryTrustedHostKeyStore: TrustedHostKeyStore {
    private var storage: [String: String] = [:]

    public init() {}

    public func trustedKey(forHost host: String) -> String? {
        storage[host]
    }

    public func trust(_ openSSHPublicKey: String, forHost host: String) {
        storage[host] = openSSHPublicKey
    }
}

/// A host key that was trusted for one host but presented for a different
/// host (or a host whose previously-trusted key changed) — the SFTP
/// equivalent of SSH's "REMOTE HOST IDENTIFICATION HAS CHANGED" warning.
public struct TrustOnFirstUseError: Error, Equatable {
    public let host: String
}

/// A `NIOSSHClientServerAuthenticationDelegate` implementing
/// trust-on-first-use (TOFU) host key verification: the first time a host is
/// seen, whatever key it presents is trusted and remembered in `store`; on
/// every subsequent connection to that same host, the presented key must
/// match the remembered one, or validation fails.
public final class TrustOnFirstUseHostKeyValidator: NIOSSHClientServerAuthenticationDelegate {
    private let host: String
    private let store: TrustedHostKeyStore

    public init(host: String, store: TrustedHostKeyStore) {
        self.host = host
        self.store = store
    }

    public func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let presentedKey = String(openSSHPublicKey: hostKey)
        guard let trustedKey = store.trustedKey(forHost: host) else {
            store.trust(presentedKey, forHost: host)
            validationCompletePromise.succeed(())
            return
        }
        if trustedKey == presentedKey {
            validationCompletePromise.succeed(())
        } else {
            validationCompletePromise.fail(TrustOnFirstUseError(host: host))
        }
    }
}
```

Create `Packages/SyncKit/Sources/SyncKit/SFTPBackend.swift`:

```swift
import Foundation
import Crypto
import NIO
import NIOFoundationCompat
import NIOSSH
import Citadel
import MyPassKit

public enum SFTPBackendError: Error {
    case invalidPrivateKey
    case remoteWriteVerificationFailed
}

public struct SFTPBackendConfiguration {
    public var host: String
    public var port: Int
    public var username: String
    public var remotePath: String
    public var privateKeyPEM: String
    public var privateKeyPassphrase: String?

    public init(
        host: String,
        port: Int = 22,
        username: String,
        remotePath: String,
        privateKeyPEM: String,
        privateKeyPassphrase: String? = nil
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.remotePath = remotePath
        self.privateKeyPEM = privateKeyPEM
        self.privateKeyPassphrase = privateKeyPassphrase
    }

    /// The key `TrustedHostKeyStore` uses to remember this host's SSH host
    /// key across connections — distinct hosts (or the same host on a
    /// distinct port) must be tracked independently.
    public var hostKeyIdentifier: String { "\(host):\(port)" }
}

/// `StorageBackend` over SFTP, via Citadel.
///
/// Citadel's SFTP client (`SSHClient`, `SFTPClient`, `SFTPFile`) is entirely
/// `async`/`await`-based, while `StorageBackend` (Task 1) is a synchronous
/// protocol. `runSSHSync(_:)` is the bridge: it runs the given async closure
/// on a detached `Task`, blocking the CALLING thread on a `DispatchSemaphore`
/// until that `Task` completes, then re-throws whatever error (if any) the
/// async closure produced. This is safe here because every call into
/// `SFTPBackend` arrives via `SyncEngine.sync(...)` (Task 6), which is only
/// ever invoked from `VaultSession`'s (Task 7) already-synchronous,
/// already-off-the-main-thread contexts (`unlock(password:)`'s call to
/// `syncOnUnlock`, and `persist(_:)`'s dedicated serial `persistQueue`) —
/// never from the main thread's run loop — so blocking on the semaphore here
/// cannot deadlock the UI.
public final class SFTPBackend: StorageBackend {
    private let configuration: SFTPBackendConfiguration
    private let trustedHostKeyStore: TrustedHostKeyStore
    private let group: MultiThreadedEventLoopGroup

    public init(
        configuration: SFTPBackendConfiguration,
        trustedHostKeyStore: TrustedHostKeyStore,
        group: MultiThreadedEventLoopGroup = .singleton
    ) {
        self.configuration = configuration
        self.trustedHostKeyStore = trustedHostKeyStore
        self.group = group
    }

    public func exists() throws -> Bool {
        try runSSHSync { sftp in
            // SFTP's SSH_FXP_STAT fails (Citadel surfaces this as a thrown
            // error) when the path does not exist, so a successful
            // getAttributes(at:) is itself the existence check.
            do {
                _ = try await sftp.getAttributes(at: self.configuration.remotePath)
                return true
            } catch {
                return false
            }
        }
    }

    public func modificationDate() throws -> Date? {
        try runSSHSync { sftp in
            let attributes = try await sftp.getAttributes(at: self.configuration.remotePath)
            return attributes.accessModificationTime?.modificationTime
        }
    }

    public func read() throws -> Data? {
        try runSSHSync { sftp in
            do {
                return try await sftp.withFile(filePath: self.configuration.remotePath, flags: .read) { file in
                    let buffer = try await file.readAll()
                    return Data(buffer: buffer)
                }
            } catch {
                return nil
            }
        }
    }

    public func write(_ data: Data) throws {
        try runSSHSync { sftp in
            let remotePath = self.configuration.remotePath
            let temporaryRemotePath = remotePath + ".tmp-\(UUID().uuidString)"
            let buffer = ByteBuffer(data: data)

            try await sftp.withFile(filePath: temporaryRemotePath, flags: [.write, .create, .truncate]) { file in
                try await file.write(buffer, at: 0)
            }

            // Verify what was actually written before it replaces the real
            // file — an interrupted or corrupted upload must never clobber
            // a good remote copy with a bad one.
            let verifiedData: Data = try await sftp.withFile(filePath: temporaryRemotePath, flags: .read) { file in
                let readBuffer = try await file.readAll()
                return Data(buffer: readBuffer)
            }
            guard verifiedData == data else {
                _ = try? await sftp.remove(at: temporaryRemotePath)
                throw SFTPBackendError.remoteWriteVerificationFailed
            }

            do {
                _ = try await sftp.getAttributes(at: remotePath)
                try await sftp.remove(at: remotePath)
            } catch {
                // No pre-existing remote file at `remotePath` — nothing to
                // remove before the rename.
            }
            try await sftp.rename(at: temporaryRemotePath, to: remotePath)
        }
    }

    private func runSSHSync<T>(_ body: @escaping @Sendable (SFTPClient) async throws -> T) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let box = SFTPBackendResultBox<T>()
        let configuration = self.configuration
        let trustedHostKeyStore = self.trustedHostKeyStore
        let group = self.group

        Task {
            do {
                let privateKey = try SFTPBackend.loadPrivateKey(
                    pem: configuration.privateKeyPEM,
                    passphrase: configuration.privateKeyPassphrase
                )
                let hostKeyValidator = SSHHostKeyValidator.custom(
                    TrustOnFirstUseHostKeyValidator(host: configuration.hostKeyIdentifier, store: trustedHostKeyStore)
                )
                let client = try await SSHClient.connect(
                    host: configuration.host,
                    port: configuration.port,
                    authenticationMethod: .ed25519(username: configuration.username, privateKey: privateKey),
                    hostKeyValidator: hostKeyValidator,
                    reconnect: .never,
                    group: group
                )
                do {
                    let value = try await client.withSFTP { sftp in
                        try await body(sftp)
                    }
                    try? await client.close()
                    box.result = .success(value)
                } catch {
                    try? await client.close()
                    box.result = .failure(error)
                }
            } catch {
                box.result = .failure(error)
            }
            semaphore.signal()
        }

        semaphore.wait()
        switch box.result! {
        case .success(let value):
            return value
        case .failure(let error):
            throw error
        }
    }

    private static func loadPrivateKey(pem: String, passphrase: String?) throws -> Curve25519.Signing.PrivateKey {
        guard let pemData = pem.data(using: .utf8) else {
            throw SFTPBackendError.invalidPrivateKey
        }
        let passphraseData = passphrase.flatMap { $0.data(using: .utf8) }
        return try Curve25519.Signing.PrivateKey(sshEd25519: pemData, decryptionKey: passphraseData)
    }
}

/// A tiny reference-type box so `runSSHSync(_:)`'s detached `Task` can hand a
/// `Result` back across the semaphore hand-off without needing `T` (or
/// `Result<T, Error>`) to itself be `Sendable`. The semaphore already
/// guarantees the calling thread only reads `result` after the `Task` has
/// finished writing it (`semaphore.wait()` only returns after
/// `semaphore.signal()`), so there is no actual data race here — only a
/// shape the compiler's strict-concurrency checking cannot see through
/// unaided, hence the explicit `@unchecked Sendable`.
private final class SFTPBackendResultBox<T>: @unchecked Sendable {
    var result: Result<T, Error>?
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd Packages/SyncKit && swift test --filter TrustOnFirstUseHostKeyValidatorTests`
Expected: PASS (4/4).
Run: `cd Packages/SyncKit && swift test --filter SFTPBackendTests`
Expected: with no environment variable set, all 5 tests `XCTSkip` (0 failures). With a real `atmoz/sftp` Docker container running (see the test file's header comment) and `MYPASS_SFTP_INTEGRATION_TESTS=1 swift test --filter SFTPBackendTests`: PASS (5/5).

- [ ] **Step 5: Run the full SyncKit suite to check for regressions**

Run: `cd Packages/SyncKit && swift test`
Expected: all `SyncKitTests` (Tasks 1-10, cumulative) PASS (integration/Keychain-gated tests `XCTSkip` unless their respective environment variables are set).

- [ ] **Step 6: Commit**

```bash
git add Packages/SyncKit/Package.swift Packages/SyncKit/Sources/SyncKit/TrustOnFirstUseHostKeyValidator.swift Packages/SyncKit/Sources/SyncKit/SFTPBackend.swift Packages/SyncKit/Tests/SyncKitTests/TrustOnFirstUseHostKeyValidatorTests.swift Packages/SyncKit/Tests/SyncKitTests/SFTPBackendTests.swift
git commit -m "SyncKit: SFTPBackend поверх Citadel — TOFU host-key проверка, sync-обёртка над async SFTP-клиентом (Фаза 3, Task 10)"
```

### Task 11: iCloudBackend — StorageBackend поверх iCloud Drive ubiquity-контейнера

**Files:**
- Create: `Packages/SyncKit/Sources/SyncKit/iCloudBackend.swift`
- Test: `Packages/SyncKit/Tests/SyncKitTests/iCloudBackendTests.swift`

**Interfaces:**
- Consumes: `StorageBackend` (Task 1); `Foundation.FileManager` ubiquity APIs (`url(forUbiquityContainerIdentifier:)`, `startDownloadingUbiquitousItem(at:)`), `Foundation.NSFileCoordinator`/`NSFilePresenter`, `URLResourceKey.ubiquitousItemDownloadingStatusKey`.
- Produces:
```swift
public enum iCloudBackendError: Error, Equatable {
    case containerUnavailable
    case downloadTimedOut
}

public final class iCloudBackend: StorageBackend {
    public init(relativePath: String, containerIdentifier: String? = nil) throws
    public func ensureDownloaded(timeout: TimeInterval = 10) throws
    public var onRemoteChange: (() -> Void)? { get set }
}
```
`iCloudBackend` is the concrete `StorageBackend` handed to `SyncEngine` (Task 6) once a user selects the iCloud Drive backend — no changes to `SyncEngine`/`MergeEngine` are needed, per Task 6's design goal of any `StorageBackend` being pluggable. Consumed by Task 12 (Settings UI wiring + `VaultSession` construction). `onRemoteChange` mirrors Task 3's `LocalFolderChangeWatcher(folderURL:onChange:)` callback shape — it fires (via the internal `NSFilePresenter`'s `presentedItemDidChange()`) whenever iCloud delivers a change to the vault file made by another device while this process is running, giving Task 12 the same "external change → trigger a sync pass" hook for the iCloud backend that `LocalFolderChangeWatcher` gives the Local backend.

- [ ] **Step 1: Write the failing test**

Create `Packages/SyncKit/Tests/SyncKitTests/iCloudBackendTests.swift`:

```swift
import XCTest
@testable import SyncKit

/// End-to-end tests against a REAL iCloud Drive ubiquity container. These
/// require a machine signed into iCloud with Drive enabled and the test
/// bundle's entitlements to include the app's iCloud container — neither is
/// available in a typical CI runner, so this class is gated behind
/// `MYPASS_ICLOUD_INTEGRATION_TESTS=1`, following this plan's existing
/// convention (Task 9's `MYPASS_KEYCHAIN_TESTS`, Task 10's
/// `MYPASS_SFTP_INTEGRATION_TESTS`).
final class iCloudBackendTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MYPASS_ICLOUD_INTEGRATION_TESTS"] == "1",
            "set MYPASS_ICLOUD_INTEGRATION_TESTS=1 (on a machine signed into iCloud with Drive enabled, running the signed MyPass test bundle) to run tests against a real ubiquity container"
        )
    }

    func testWriteThenReadRoundTripsExactBytes() throws {
        let backend = try iCloudBackend(relativePath: "mypass-icloud-backend-tests-\(UUID().uuidString).kdbx")
        let payload = Data("icloud-round-trip-bytes".utf8)
        try backend.write(payload)
        XCTAssertTrue(try backend.exists())
        XCTAssertEqual(try backend.read(), payload)
    }

    func testModificationDateIsNonNilAfterWriteAndIncreasesOnSecondWrite() throws {
        let backend = try iCloudBackend(relativePath: "mypass-icloud-backend-tests-\(UUID().uuidString).kdbx")
        try backend.write(Data("v1".utf8))
        let firstDate = try XCTUnwrap(backend.modificationDate())

        Thread.sleep(forTimeInterval: 1.1)
        try backend.write(Data("v2".utf8))
        let secondDate = try XCTUnwrap(backend.modificationDate())

        XCTAssertGreaterThan(secondDate, firstDate)
    }

    func testEnsureDownloadedSucceedsForAFileWrittenByThisProcess() throws {
        let backend = try iCloudBackend(relativePath: "mypass-icloud-backend-tests-\(UUID().uuidString).kdbx")
        try backend.write(Data("already local, never actually offloaded".utf8))
        XCTAssertNoThrow(try backend.ensureDownloaded(timeout: 5))
    }

    func testExistsIsFalseBeforeAnyWrite() throws {
        let backend = try iCloudBackend(relativePath: "mypass-icloud-backend-tests-\(UUID().uuidString).kdbx")
        XCTAssertFalse(try backend.exists())
        XCTAssertNil(try backend.read())
    }
}

/// Pure/unit tests that do NOT touch a real ubiquity container — always run,
/// regardless of `MYPASS_ICLOUD_INTEGRATION_TESTS`, in a separate class so
/// this class's `setUp()` (no gate) is independent of `iCloudBackendTests`'s
/// gated `setUpWithError()` above.
final class iCloudBackendUngatedTests: XCTestCase {
    func testInitThrowsContainerUnavailableWithBogusIdentifier() {
        XCTAssertThrowsError(
            try iCloudBackend(relativePath: "vault.kdbx", containerIdentifier: "iCloud.com.mypass.definitely-not-a-real-container-id")
        ) { error in
            XCTAssertEqual(error as? iCloudBackendError, .containerUnavailable)
        }
    }

    func testCoordinatedURLAppendsDocumentsAndRelativePath() {
        let container = URL(fileURLWithPath: "/tmp/fake-ubiquity-container")
        let url = iCloudBackend.coordinatedURL(containerURL: container, relativePath: "vault.kdbx")
        XCTAssertEqual(url.path, "/tmp/fake-ubiquity-container/Documents/vault.kdbx")
    }

    func testCoordinatedURLHandlesNestedRelativePaths() {
        let container = URL(fileURLWithPath: "/tmp/fake-ubiquity-container")
        let url = iCloudBackend.coordinatedURL(containerURL: container, relativePath: "backups/vault-2026.kdbx")
        XCTAssertEqual(url.path, "/tmp/fake-ubiquity-container/Documents/backups/vault-2026.kdbx")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd Packages/SyncKit && swift test --filter iCloudBackendTests`
Expected: FAIL — `iCloudBackend`/`iCloudBackendError` do not exist yet (compile error).
Run: `cd Packages/SyncKit && swift test --filter iCloudBackendUngatedTests`
Expected: FAIL — same compile error (both classes live in the same not-yet-compiling file).

- [ ] **Step 3: Write minimal implementation**

Create `Packages/SyncKit/Sources/SyncKit/iCloudBackend.swift`:

```swift
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd Packages/SyncKit && swift test --filter iCloudBackendUngatedTests`
Expected: PASS (3/3) — these never touch a real ubiquity container.
Run: `cd Packages/SyncKit && swift test --filter iCloudBackendTests`
Expected: with no environment variable set, all 4 tests `XCTSkip` (0 failures). With `MYPASS_ICLOUD_INTEGRATION_TESTS=1` on a machine signed into iCloud Drive: PASS (4/4).

- [ ] **Step 5: Run the full SyncKit suite to check for regressions**

Run: `cd Packages/SyncKit && swift test`
Expected: all `SyncKitTests` (Tasks 1-11, cumulative) PASS (integration/Keychain/iCloud-gated tests `XCTSkip` unless their respective environment variables are set).

- [ ] **Step 6: Commit**

```bash
git add Packages/SyncKit/Sources/SyncKit/iCloudBackend.swift Packages/SyncKit/Tests/SyncKitTests/iCloudBackendTests.swift
git commit -m "SyncKit: iCloudBackend поверх NSFileCoordinator/NSFilePresenter, ensureDownloaded против частично выгруженных файлов (Фаза 3, Task 11)"
```

---

### Task 12: Settings UI — выбор бэкенда Local/iCloud, подключение к VaultSession

**Files:**
- Modify: `MyPass/UI/Settings/SettingsView.swift` (сделать `.local`/`.iCloud` доступными, добавить выбор папки и статус iCloud-контейнера)
- Modify: `MyPass/MyPassApp.swift` (собрать подходящий `StorageBackend`/`SyncEngine` и передать в `VaultSession`; добавить периодический таймер и FSEvents-триггер для внешних изменений)
- Modify: `MyPass/State/VaultSession.swift` (добавить `triggerBackgroundSync()` — небольшое дополнение поверх Task 7's файла, без изменения существующих методов)
- Create: `MyPass/State/SyncBackendResolver.swift`
- Test: `MyPassTests/SettingsViewSyncBackendTests.swift` (новый файл — не существовал ранее)

**Interfaces:**
- Consumes: `SyncKit.LocalFolderBackend`/`.init(bookmarkData:filename:)`/`.createBookmark(for:)` (Task 2), `SyncKit.LocalFolderChangeWatcher`/`.init(folderURL:onChange:)`/`.start()`/`.stop()` (Task 3), `SyncKit.iCloudBackend`/`.init(relativePath:containerIdentifier:)`/`.onRemoteChange` (Task 11), `SyncKit.SyncEngine`/`.init(remote:checkpointStore:)` (Task 6), `SyncKit.UserDefaultsSyncCheckpointStore`/`.init(defaults:key:)` (Task 6), `SyncKit.StorageBackend` (Task 1); `MyPass/State/VaultSession.swift`'s real, existing `init(fileStore: VaultFileStore, syncEngine: SyncEngine? = nil)` (Task 7); the real, existing `SyncBackendOption` enum and `SettingsView` in `MyPass/UI/Settings/SettingsView.swift` (Phase 2, unmodified by Phase 3 until this task).
- Produces: `SyncBackendOption.local.isAvailable`/`.iCloud.isAvailable` now `true` (`.sftp.isAvailable` stays `false` until Task 13); a new, additive `VaultSession.triggerBackgroundSync()` method (fileprivate helpers `syncOnUnlock`/`persist(_:)` from Task 7 are reused unchanged — no signature in Task 7's produced surface changes); `SyncBackendResolver.resolveLocalFolderBackend(bookmarkData:)`/`.resolveICloudBackend(relativePath:)` — pure(ish) resolution helpers consumed by `MyPassApp.init()` and unit-tested directly without SwiftUI. Consumed by Task 13 (extends the same `SettingsView.swift`/`MyPassApp.swift`/`SyncBackendResolver.swift` with the SFTP case).

This task also closes a gap surfaced during this plan's whole-document self-review (see `## Self-Review` below): Task 3's `LocalFolderChangeWatcher` was created but never wired to anything (its own Interfaces note deferred that to "Part B's app-level auto-sync trigger"), and the design spec's sync cycle ("при открытии, после сохранения, **по таймеру, вручную**") has two triggers — periodic and manual — that Tasks 6-7 don't implement (they only wire sync at unlock and after-save). `VaultSession.triggerBackgroundSync()` plus this task's `MyPassApp.swift` timer and `LocalFolderChangeWatcher`/`iCloudBackend.onRemoteChange` wiring close all four.

- [ ] **Step 1: Write the failing tests**

Create `MyPassTests/SettingsViewSyncBackendTests.swift`:

```swift
import XCTest
import SyncKit
@testable import MyPass

final class SettingsViewSyncBackendTests: XCTestCase {
    var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SettingsViewSyncBackendTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testResolveLocalFolderBackendReturnsWorkingBackendForValidBookmark() throws {
        let bookmark = try LocalFolderBackend.createBookmark(for: tempDir)
        let backend = SyncBackendResolver.resolveLocalFolderBackend(bookmarkData: bookmark)
        let resolved = try XCTUnwrap(backend)

        XCTAssertFalse(try resolved.exists())
        try resolved.write(Data("resolved-backend-round-trip".utf8))
        XCTAssertEqual(try resolved.read(), Data("resolved-backend-round-trip".utf8))
    }

    func testResolveLocalFolderBackendReturnsNilForMissingBookmark() {
        XCTAssertNil(SyncBackendResolver.resolveLocalFolderBackend(bookmarkData: nil))
        XCTAssertNil(SyncBackendResolver.resolveLocalFolderBackend(bookmarkData: Data()))
    }

    func testResolveLocalFolderBackendReturnsNilForInvalidBookmarkDataWithoutCrashing() {
        let garbage = Data([0x00, 0x01, 0x02, 0x03, 0xFF, 0xFE])
        XCTAssertNil(SyncBackendResolver.resolveLocalFolderBackend(bookmarkData: garbage))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/SettingsViewSyncBackendTests`
Expected: FAIL — compile error, `SyncBackendResolver` does not exist yet.

- [ ] **Step 3: Write minimal implementation**

No `project.yml` changes are needed — `MyPass`'s and `MyPassTests`' `sources:` entries are directory-globbed (`path: MyPass` / `path: MyPassTests`), so the new files below are picked up automatically once `xcodegen generate` is re-run.

Create `MyPass/State/SyncBackendResolver.swift`:

```swift
import Foundation
import SyncKit

/// Pure(ish) resolution logic turning persisted Settings values into a
/// concrete `StorageBackend` — factored out of `SettingsView`/`MyPassApp` so
/// it's unit-testable without instantiating SwiftUI views or a full app
/// (`MyPassTests/SettingsViewSyncBackendTests.swift`).
enum SyncBackendResolver {
    /// Resolves the Local-folder backend from previously-persisted
    /// security-scoped bookmark data (Task 2's `LocalFolderBackend`).
    /// Returns `nil` (never throws) when no folder has been chosen yet — a
    /// missing bookmark is expected, common state (fresh install, user
    /// hasn't picked a folder), not an error. A stale or otherwise corrupt
    /// bookmark also resolves to `nil` rather than throwing, so a bad
    /// persisted value can never crash app launch — the user simply sees
    /// "no folder chosen" in Settings and can re-pick one.
    static func resolveLocalFolderBackend(bookmarkData: Data?) -> LocalFolderBackend? {
        guard let bookmarkData, !bookmarkData.isEmpty else { return nil }
        return try? LocalFolderBackend(bookmarkData: bookmarkData)
    }

    /// Resolves the iCloud backend. Returns `nil` (never throws) when the
    /// container isn't available (iCloud Drive disabled/not signed in),
    /// for the same "never crash app launch on bad/missing external state"
    /// reason as above — `SettingsView` surfaces the warning inline instead.
    static func resolveICloudBackend(relativePath: String = "vault.kdbx") -> iCloudBackend? {
        try? iCloudBackend(relativePath: relativePath)
    }
}
```

Add the following method to `MyPass/State/VaultSession.swift`, right after `mutate(_:)` and before `acknowledgeSaveError()` (the rest of the file is unchanged from Task 7):

```swift
    /// Runs a sync pass without an accompanying local mutation — used by
    /// external-change notifications (Task 3's `LocalFolderChangeWatcher`
    /// for the Local backend, `iCloudBackend.onRemoteChange` for the iCloud
    /// backend, both wired in `MyPassApp.init()`, Task 12) and by a manual
    /// "Sync Now" affordance in Settings (Task 12/13), so a remote change
    /// made on another device is picked up promptly instead of waiting for
    /// the next unlock or local edit. Reuses the existing serial
    /// `persistQueue` + `syncEngine.sync(...)` pipeline via `persist(_:)` —
    /// re-saving byte-identical content locally when nothing actually
    /// changed is harmless (`VaultFileStore.save` overwrites idempotently)
    /// and keeps this a single well-tested code path rather than a second,
    /// parallel one.
    func triggerBackgroundSync() {
        guard case .unlocked(let db) = state else { return }
        persist(db)
    }
```

Modify `MyPass/UI/Settings/SettingsView.swift` — replace the full contents with:

```swift
import SwiftUI
import AppKit
import MyPassKit
import SyncKit

enum SyncBackendOption: String, CaseIterable, Identifiable {
    case local = "Локальный файл"
    case iCloud = "iCloud Drive"
    case sftp = "SFTP"

    var id: String { rawValue }

    // .local and .iCloud are wired in Phase 3 Task 12. .sftp is wired in
    // Task 13. The picker below persists the user's choice to UserDefaults
    // regardless of availability so a preference recorded before a backend
    // was wired is still there once it is.
    var isAvailable: Bool {
        switch self {
        case .local, .iCloud: return true
        case .sftp: return false
        }
    }
}

struct SettingsView: View {
    @AppStorage("autoLockTimeoutMinutes") private var autoLockTimeoutMinutes: Double = 15
    @AppStorage("backupCount") private var backupCount: Int = 10
    @AppStorage("syncBackend") private var syncBackendRawValue: String = SyncBackendOption.local.rawValue

    // Non-secret Local-folder bookmark data — @AppStorage supports `Data?`
    // directly (one of AppStorage's natively-supported property list types
    // alongside Bool/Int/Double/String/URL), so no base64/string bridging is
    // needed here, unlike the SFTP secrets in Task 13 which deliberately
    // avoid @AppStorage/UserDefaults entirely and go to Keychain instead.
    @AppStorage("syncLocalFolderBookmark") private var syncLocalFolderBookmarkData: Data?

    @State private var iCloudContainerAvailable: Bool = true
    @State private var iCloudContainerCheckMessage: String?
    @State private var manualSyncStatusMessage: String?

    // Bridges the persisted timeout to the live, running AutoLockController (Task 5) so that
    // changing the stepper actually affects autolock behavior in this session, and so a value
    // persisted in a previous session is restored into the controller on next launch too —
    // otherwise UserDefaults would hold a value the running controller never reads.
    @EnvironmentObject private var autoLockController: AutoLockController
    @EnvironmentObject private var vaultSession: VaultSession

    private var selectedOption: SyncBackendOption {
        SyncBackendOption(rawValue: syncBackendRawValue) ?? .local
    }

    var body: some View {
        Form {
            Section("Автоблокировка") {
                Stepper("Таймаут: \(Int(autoLockTimeoutMinutes)) мин", value: $autoLockTimeoutMinutes, in: 1...120)
            }
            Section("Резервные копии") {
                Stepper("Хранить последних: \(backupCount)", value: $backupCount, in: 1...50)
            }
            Section("Синхронизация") {
                Picker("Бэкенд", selection: $syncBackendRawValue) {
                    ForEach(SyncBackendOption.allCases) { option in
                        Text(option.isAvailable ? option.rawValue : "\(option.rawValue) (скоро)")
                            .tag(option.rawValue)
                    }
                }

                switch selectedOption {
                case .local:
                    localFolderSection
                case .iCloud:
                    iCloudSection
                case .sftp:
                    Text("SFTP появится в следующей задаче Фазы 3.")
                        .foregroundStyle(.secondary)
                }

                Button("Синхронизировать сейчас") {
                    vaultSession.triggerBackgroundSync()
                    manualSyncStatusMessage = "Запущено…"
                }
                if let manualSyncStatusMessage {
                    Text(manualSyncStatusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .frame(width: 360)
        .onAppear {
            // Restore a persisted value into the live controller at view-appear time — covers
            // the case where a timeout was changed in a previous session but the controller
            // (constructed once in MyPassApp.init with a hardcoded default) never saw it.
            autoLockController.timeout = autoLockTimeoutMinutes * 60
            refreshICloudStatus()
        }
        .onChange(of: autoLockTimeoutMinutes) { _, newValue in
            autoLockController.timeout = newValue * 60
        }
        .onChange(of: syncBackendRawValue) { _, _ in
            refreshICloudStatus()
        }
    }

    private var localFolderSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let bookmarkData = syncLocalFolderBookmarkData, !bookmarkData.isEmpty,
               let backend = SyncBackendResolver.resolveLocalFolderBackend(bookmarkData: bookmarkData) {
                Text("Папка выбрана.")
                    .foregroundStyle(.secondary)
                    .task { _ = backend } // keeps `backend` from being flagged unused; construction itself already validates the bookmark
            } else {
                Text("Папка не выбрана.")
                    .foregroundStyle(.secondary)
            }
            Button("Выбрать папку…") {
                let panel = NSOpenPanel()
                panel.canChooseFiles = false
                panel.canChooseDirectories = true
                panel.allowsMultipleSelection = false
                if panel.runModal() == .OK, let folderURL = panel.url {
                    syncLocalFolderBookmarkData = try? LocalFolderBackend.createBookmark(for: folderURL)
                }
            }
        }
    }

    private var iCloudSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            if iCloudContainerAvailable {
                Text("Контейнер iCloud доступен.")
                    .foregroundStyle(.secondary)
            } else {
                Text(iCloudContainerCheckMessage ?? "iCloud Drive недоступен — войдите в iCloud и включите iCloud Drive в Системных настройках.")
                    .foregroundStyle(.orange)
            }
        }
    }

    private func refreshICloudStatus() {
        guard selectedOption == .iCloud else { return }
        do {
            _ = try iCloudBackend(relativePath: "vault.kdbx")
            iCloudContainerAvailable = true
            iCloudContainerCheckMessage = nil
        } catch iCloudBackendError.containerUnavailable {
            iCloudContainerAvailable = false
            iCloudContainerCheckMessage = "iCloud Drive недоступен — войдите в iCloud и включите iCloud Drive в Системных настройках."
        } catch {
            iCloudContainerAvailable = false
            iCloudContainerCheckMessage = "Не удалось проверить контейнер iCloud: \(error)"
        }
    }
}
```

Modify `MyPass/MyPassApp.swift` — replace the full contents with:

```swift
import SwiftUI
import AppKit
import MyPassKit
import SyncKit

@main
struct MyPassApp: App {
    /// Default inactivity timeout before the vault auto-locks, per the design spec (15 minutes).
    private static let defaultAutoLockTimeout: TimeInterval = 900

    /// Design spec's sync cycle triggers "при открытии, после сохранения" are
    /// wired directly inside `VaultSession` (Task 7). This interval covers
    /// the remaining "по таймеру" trigger.
    private static let backgroundSyncInterval: TimeInterval = 300

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @StateObject private var vaultSession: VaultSession
    @StateObject private var navigationState: NavigationState
    @StateObject private var autoLockController: AutoLockController

    init() {
        let defaults = UserDefaults.standard
        let syncBackendOption = SyncBackendOption(rawValue: defaults.string(forKey: "syncBackend") ?? "") ?? .local

        var localFolderURLForWatcher: URL?
        let syncEngine: SyncEngine? = {
            guard syncBackendOption.isAvailable else { return nil }

            let backend: StorageBackend?
            switch syncBackendOption {
            case .local:
                let bookmarkData = defaults.data(forKey: "syncLocalFolderBookmark")
                backend = SyncBackendResolver.resolveLocalFolderBackend(bookmarkData: bookmarkData)
                if let bookmarkData, !bookmarkData.isEmpty {
                    var isStale = false
                    localFolderURLForWatcher = try? URL(
                        resolvingBookmarkData: bookmarkData,
                        options: .withSecurityScope,
                        relativeTo: nil,
                        bookmarkDataIsStale: &isStale
                    )
                    if isStale { localFolderURLForWatcher = nil }
                }
            case .iCloud:
                backend = SyncBackendResolver.resolveICloudBackend()
            case .sftp:
                backend = nil // wired in Task 13
            }

            guard let backend else { return nil }
            let checkpointStore = UserDefaultsSyncCheckpointStore(
                key: "com.mypass.sync.checkpoint.\(syncBackendOption.rawValue)"
            )
            return SyncEngine(remote: backend, checkpointStore: checkpointStore)
        }()

        let session = VaultSession(
            fileStore: VaultFileStore(
                directory: FileManager.default
                    .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("MyPass")
            ),
            syncEngine: syncEngine
        )
        _vaultSession = StateObject(wrappedValue: session)
        _navigationState = StateObject(wrappedValue: NavigationState())

        let controller = AutoLockController(
            vaultSession: session,
            clock: RealAutoLockClock(),
            sleepObserver: NSWorkspaceSleepObserver(),
            timeout: Self.defaultAutoLockTimeout
        )
        _autoLockController = StateObject(wrappedValue: controller)

        // Reset the auto-lock timer on real user input so the vault locks after a
        // period of inactivity, not simply `timeout` seconds after launch.
        AppDelegate.activityMonitorToken = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel]
        ) { event in
            controller.recordActivity()
            return event
        }

        // Design spec sync trigger "по таймеру".
        AppDelegate.backgroundSyncTimer = Timer.scheduledTimer(
            withTimeInterval: Self.backgroundSyncInterval,
            repeats: true
        ) { [weak session] _ in
            session?.triggerBackgroundSync()
        }

        // Design spec's Local-folder backend requirement "FSEvents для
        // внешних изменений" — closes the forward reference Task 3 left
        // open ("Consumed by ... app-level auto-sync trigger").
        if syncBackendOption == .local, let folderURL = localFolderURLForWatcher {
            let watcher = LocalFolderChangeWatcher(folderURL: folderURL) { [weak session] in
                session?.triggerBackgroundSync()
            }
            watcher.start()
            AppDelegate.localFolderChangeWatcher = watcher
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(vaultSession)
                .environmentObject(navigationState)
                .environmentObject(autoLockController)
        }

        MenuBarExtra("MyPass", systemImage: "key.fill") {
            MenuBarExtraContent()
                .environmentObject(vaultSession)
                .environmentObject(navigationState)
        }

        Settings {
            SettingsView()
                .environmentObject(autoLockController)
                .environmentObject(vaultSession)
        }
    }
}
```

Add the two new retained-for-app-lifetime static properties to `MyPass/AppDelegate.swift` (the rest of the file — `applicationShouldTerminateAfterLastWindowClosed`, the class declaration — is unchanged):

```swift
    /// Retains the periodic background-sync `Timer` installed in
    /// `MyPassApp.init()` (Phase 3, Task 12) for the lifetime of the app.
    static var backgroundSyncTimer: Timer?

    /// Retains the `LocalFolderChangeWatcher` installed in `MyPassApp.init()`
    /// (Phase 3, Task 12) when the Local-folder backend is active, for the
    /// lifetime of the app.
    static var localFolderChangeWatcher: LocalFolderChangeWatcher?
```

(`LocalFolderChangeWatcher` requires `import SyncKit` to already be present at the top of `AppDelegate.swift` — add it if not already there.)

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/SettingsViewSyncBackendTests`
Expected: PASS (3/3).

- [ ] **Step 5: Run the full MyPass test suite to check for regressions**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS'`
Expected: all pass, including the existing `VaultSessionTests` (Task 7) — `VaultSession`'s only change here is one additive method, no existing behavior touched.

- [ ] **Step 6: Commit**

```bash
git add MyPass/UI/Settings/SettingsView.swift MyPass/MyPassApp.swift MyPass/AppDelegate.swift MyPass/State/VaultSession.swift MyPass/State/SyncBackendResolver.swift MyPassTests/SettingsViewSyncBackendTests.swift
git commit -m "Settings: включить Local/iCloud бэкенды, подключить SyncEngine к VaultSession, периодический + внешний триггеры sync (Фаза 3, Task 12)"
```

---

### Task 13: Settings UI — форма конфигурации SFTP

**Files:**
- Modify: `MyPass/UI/Settings/SettingsView.swift` (сделать `.sftp` доступным, добавить форму конфигурации)
- Modify: `MyPass/MyPassApp.swift` (добавить ветку `.sftp` в сборку `StorageBackend`)
- Create: `MyPass/State/SFTPConnectionTester.swift`
- Test: `MyPassTests/SettingsViewSyncBackendTests.swift` (добавить тесты к файлу из Task 12)

**Interfaces:**
- Consumes: `SyncKit.SFTPBackend`/`.init(configuration:trustedHostKeyStore:group:)`, `SyncKit.SFTPBackendConfiguration`/`.init(host:port:username:remotePath:privateKeyPEM:privateKeyPassphrase:)`, `SyncKit.UserDefaultsTrustedHostKeyStore`/`.init(defaults:keyPrefix:)` (Task 10); `SyncKit.CredentialKeychainStore`/`.init()`, `SyncKit.SFTPCredentials`/`.init(username:privateKeyPEM:privateKeyPassphrase:)`, `SyncKit.CredentialStoring`/`.loadCredentials(forHost:)`/`.store(_:forHost:)` (Task 9); `SyncKit.StorageBackend` (Task 1); Task 12's `SyncBackendOption`, `SettingsView`, `MyPassApp.init()`'s backend-construction `switch`, `SyncBackendResolver`.
- Produces: `SyncBackendOption.sftp.isAvailable` now `true`; `SyncBackendResolver.buildSFTPConfiguration(host:port:username:remotePath:credentials:) -> SFTPBackendConfiguration?` (pure, testable); a new type:
```swift
enum SFTPConnectionTesterError: Error {
    case missingConfiguration
}

struct SFTPConnectionTester {
    init(
        configurationProvider: @escaping () -> SFTPBackendConfiguration?,
        backendFactory: @escaping (SFTPBackendConfiguration) -> StorageBackend = { config in
            SFTPBackend(configuration: config, trustedHostKeyStore: UserDefaultsTrustedHostKeyStore())
        }
    )
    func testConnection() -> Result<Void, Error>
}
```
`backendFactory` defaults to a real `SFTPBackend` but is injectable, so `SFTPConnectionTesterTests` can supply a fake `StorageBackend` without any network/Docker dependency. Consumed by `SettingsView`'s "Проверить соединение" button and by this task's tests.

**Известный пробел (см. `## Self-Review`):** design-спека упоминает опциональную поддержку OpenSSH-сертификатов для SFTP ("опционально OpenSSH-сертификат"), но `SFTPBackendConfiguration` (Task 10) не имеет поля для сертификата — Citadel's `SSHAuthenticationMethod.ed25519(username:privateKey:)` (единственный аутентификационный метод, использованный в Task 10) не принимает сертификат. Поле `syncSFTPCertificatePath` ниже сохраняет путь к файлу сертификата в UI ради будущей задачи, но оно **не используется** нигде в реальном SSH-подключении — это явно откомментировано в коде ниже и в риск-таблице дизайн-спеки этот риск уже зафиксирован как принятый ("SFTP-библиотека без OpenSSH-сертификатов").

- [ ] **Step 1: Write the failing tests**

Append these tests to the end of `MyPassTests/SettingsViewSyncBackendTests.swift` (inside the closing `}` of `final class SettingsViewSyncBackendTests`, after `testResolveLocalFolderBackendReturnsNilForInvalidBookmarkDataWithoutCrashing`):

```swift
    func testBuildSFTPConfigurationCombinesStoredFieldsWithLoadedCredentials() throws {
        let credentials = SFTPCredentials(
            username: "vault-user",
            privateKeyPEM: "-----BEGIN OPENSSH PRIVATE KEY-----\nfake\n-----END OPENSSH PRIVATE KEY-----",
            privateKeyPassphrase: "hunter2"
        )

        let configuration = try XCTUnwrap(SyncBackendResolver.buildSFTPConfiguration(
            host: "sftp.example.com",
            port: 2222,
            username: "ignored-form-field-username",
            remotePath: "/upload/vault.kdbx",
            credentials: credentials
        ))

        XCTAssertEqual(configuration.host, "sftp.example.com")
        XCTAssertEqual(configuration.port, 2222)
        // The username actually used comes from the loaded Keychain
        // credentials, not the (possibly stale) form field — Keychain is
        // the single source of truth for anything paired with the private
        // key, since a mismatched username would silently fail auth.
        XCTAssertEqual(configuration.username, "vault-user")
        XCTAssertEqual(configuration.remotePath, "/upload/vault.kdbx")
        XCTAssertEqual(configuration.privateKeyPEM, credentials.privateKeyPEM)
        XCTAssertEqual(configuration.privateKeyPassphrase, "hunter2")
    }

    func testBuildSFTPConfigurationReturnsNilWithoutCredentials() {
        XCTAssertNil(SyncBackendResolver.buildSFTPConfiguration(
            host: "sftp.example.com",
            port: 22,
            username: "someone",
            remotePath: "/upload/vault.kdbx",
            credentials: nil
        ))
    }

    func testBuildSFTPConfigurationReturnsNilWithEmptyHost() {
        let credentials = SFTPCredentials(username: "u", privateKeyPEM: "pem", privateKeyPassphrase: nil)
        XCTAssertNil(SyncBackendResolver.buildSFTPConfiguration(
            host: "",
            port: 22,
            username: "u",
            remotePath: "/upload/vault.kdbx",
            credentials: credentials
        ))
    }

    func testSFTPConnectionTesterReturnsSuccessWhenBackendDoesNotThrow() {
        struct AlwaysExistsBackend: StorageBackend {
            func read() throws -> Data? { nil }
            func write(_ data: Data) throws {}
            func modificationDate() throws -> Date? { nil }
            func exists() throws -> Bool { true }
        }

        let configuration = SFTPBackendConfiguration(
            host: "sftp.example.com", username: "u", remotePath: "/upload/vault.kdbx", privateKeyPEM: "pem"
        )
        let tester = SFTPConnectionTester(
            configurationProvider: { configuration },
            backendFactory: { _ in AlwaysExistsBackend() }
        )

        switch tester.testConnection() {
        case .success: break
        case .failure(let error): XCTFail("expected success, got \(error)")
        }
    }

    func testSFTPConnectionTesterReturnsFailureWhenBackendThrows() {
        struct ThrowingBackend: StorageBackend {
            struct Boom: Error {}
            func read() throws -> Data? { throw Boom() }
            func write(_ data: Data) throws { throw Boom() }
            func modificationDate() throws -> Date? { throw Boom() }
            func exists() throws -> Bool { throw Boom() }
        }

        let configuration = SFTPBackendConfiguration(
            host: "sftp.example.com", username: "u", remotePath: "/upload/vault.kdbx", privateKeyPEM: "pem"
        )
        let tester = SFTPConnectionTester(
            configurationProvider: { configuration },
            backendFactory: { _ in ThrowingBackend() }
        )

        switch tester.testConnection() {
        case .success: XCTFail("expected failure")
        case .failure: break
        }
    }

    func testSFTPConnectionTesterReturnsFailureWhenConfigurationIsMissing() {
        let tester = SFTPConnectionTester(configurationProvider: { nil })
        switch tester.testConnection() {
        case .success: XCTFail("expected failure")
        case .failure(let error):
            XCTAssertEqual(error as? SFTPConnectionTesterError, .missingConfiguration)
        }
    }
```

And add `import SyncKit` alongside the existing `import XCTest`/`@testable import MyPass` at the top of the file if Task 12 didn't already add it (it did — this is a no-op re-check).

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/SettingsViewSyncBackendTests`
Expected: FAIL — compile error (`SyncBackendResolver.buildSFTPConfiguration`/`SFTPConnectionTester`/`SFTPConnectionTesterError` do not exist yet).

- [ ] **Step 3: Write minimal implementation**

Create `MyPass/State/SFTPConnectionTester.swift`:

```swift
import Foundation
import SyncKit

enum SFTPConnectionTesterError: Error, Equatable {
    case missingConfiguration
}

/// Wraps a single `StorageBackend.exists()` call as a connectivity probe for
/// the Settings "Проверить соединение" button. `backendFactory` defaults to
/// building a real `SFTPBackend`, but is injectable so tests can supply a
/// fake `StorageBackend` without any network/Docker dependency — this is
/// the preferred design flagged in this task's spec over gating the whole
/// type behind an integration-test environment variable.
struct SFTPConnectionTester {
    private let configurationProvider: () -> SFTPBackendConfiguration?
    private let backendFactory: (SFTPBackendConfiguration) -> StorageBackend

    init(
        configurationProvider: @escaping () -> SFTPBackendConfiguration?,
        backendFactory: @escaping (SFTPBackendConfiguration) -> StorageBackend = { config in
            SFTPBackend(configuration: config, trustedHostKeyStore: UserDefaultsTrustedHostKeyStore())
        }
    ) {
        self.configurationProvider = configurationProvider
        self.backendFactory = backendFactory
    }

    func testConnection() -> Result<Void, Error> {
        guard let configuration = configurationProvider() else {
            return .failure(SFTPConnectionTesterError.missingConfiguration)
        }
        let backend = backendFactory(configuration)
        do {
            _ = try backend.exists()
            return .success(())
        } catch {
            return .failure(error)
        }
    }
}
```

Add the following to `MyPass/State/SyncBackendResolver.swift`, inside the `enum SyncBackendResolver` (after `resolveICloudBackend`, rest of the file unchanged from Task 12):

```swift
    /// Combines the non-secret SFTP form fields with Keychain-loaded
    /// `SFTPCredentials` (Task 9) into a real `SFTPBackendConfiguration`
    /// (Task 10). Returns `nil` when `host` is empty or no credentials have
    /// been stored yet — both are expected, common "not configured yet"
    /// states, not errors. The username actually used always comes from the
    /// loaded credentials (paired with the private key at storage time),
    /// not the possibly-stale `username` form field, so a form field edited
    /// without re-picking the key can never silently desync from the key
    /// it's meant to go with.
    static func buildSFTPConfiguration(
        host: String,
        port: Int,
        username: String,
        remotePath: String,
        credentials: SFTPCredentials?
    ) -> SFTPBackendConfiguration? {
        guard !host.isEmpty, let credentials else { return nil }
        return SFTPBackendConfiguration(
            host: host,
            port: port,
            username: credentials.username,
            remotePath: remotePath,
            privateKeyPEM: credentials.privateKeyPEM,
            privateKeyPassphrase: credentials.privateKeyPassphrase
        )
    }
```

Modify `MyPass/UI/Settings/SettingsView.swift` — replace the full contents with (adds the SFTP form/state on top of Task 12's version; `.local`/`.iCloud` sections and the manual-sync button are unchanged from Task 12):

```swift
import SwiftUI
import AppKit
import MyPassKit
import SyncKit

enum SyncBackendOption: String, CaseIterable, Identifiable {
    case local = "Локальный файл"
    case iCloud = "iCloud Drive"
    case sftp = "SFTP"

    var id: String { rawValue }

    var isAvailable: Bool { true }
}

struct SettingsView: View {
    @AppStorage("autoLockTimeoutMinutes") private var autoLockTimeoutMinutes: Double = 15
    @AppStorage("backupCount") private var backupCount: Int = 10
    @AppStorage("syncBackend") private var syncBackendRawValue: String = SyncBackendOption.local.rawValue
    @AppStorage("syncLocalFolderBookmark") private var syncLocalFolderBookmarkData: Data?

    // SFTP non-secret fields — host/port/username/remotePath/paths only.
    // The private key PEM and its passphrase NEVER go through @AppStorage/
    // UserDefaults — they are stored exclusively via CredentialKeychainStore
    // (Task 9), per the design doc's security stance that secret material
    // belongs in Keychain, not plist-backed UserDefaults.
    @AppStorage("syncSFTPHost") private var sftpHost: String = ""
    @AppStorage("syncSFTPPort") private var sftpPort: Int = 22
    @AppStorage("syncSFTPUsername") private var sftpUsername: String = ""
    @AppStorage("syncSFTPRemotePath") private var sftpRemotePath: String = "/upload/vault.kdbx"
    @AppStorage("syncSFTPPrivateKeyPath") private var sftpPrivateKeyPath: String = ""
    // UI-only bookkeeping — see this task's "Известный пробел" note above:
    // not wired into SFTPBackendConfiguration (Task 10 has no certificate
    // field), kept only so the chosen path survives across Settings reopens.
    @AppStorage("syncSFTPCertificatePath") private var sftpCertificatePath: String = ""

    @State private var sftpPrivateKeyPEM: String = ""
    @State private var sftpPassphrase: String = ""
    @State private var connectionTestState: ConnectionTestState = .idle

    @State private var iCloudContainerAvailable: Bool = true
    @State private var iCloudContainerCheckMessage: String?
    @State private var manualSyncStatusMessage: String?

    @EnvironmentObject private var autoLockController: AutoLockController
    @EnvironmentObject private var vaultSession: VaultSession

    private enum ConnectionTestState: Equatable {
        case idle
        case testing
        case success
        case failure(String)
    }

    private var selectedOption: SyncBackendOption {
        SyncBackendOption(rawValue: syncBackendRawValue) ?? .local
    }

    var body: some View {
        Form {
            Section("Автоблокировка") {
                Stepper("Таймаут: \(Int(autoLockTimeoutMinutes)) мин", value: $autoLockTimeoutMinutes, in: 1...120)
            }
            Section("Резервные копии") {
                Stepper("Хранить последних: \(backupCount)", value: $backupCount, in: 1...50)
            }
            Section("Синхронизация") {
                Picker("Бэкенд", selection: $syncBackendRawValue) {
                    ForEach(SyncBackendOption.allCases) { option in
                        Text(option.rawValue).tag(option.rawValue)
                    }
                }

                switch selectedOption {
                case .local:
                    localFolderSection
                case .iCloud:
                    iCloudSection
                case .sftp:
                    sftpSection
                }

                Button("Синхронизировать сейчас") {
                    vaultSession.triggerBackgroundSync()
                    manualSyncStatusMessage = "Запущено…"
                }
                if let manualSyncStatusMessage {
                    Text(manualSyncStatusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .frame(width: 420)
        .onAppear {
            autoLockController.timeout = autoLockTimeoutMinutes * 60
            refreshICloudStatus()
            loadSFTPCredentialsIfAvailable()
        }
        .onChange(of: autoLockTimeoutMinutes) { _, newValue in
            autoLockController.timeout = newValue * 60
        }
        .onChange(of: syncBackendRawValue) { _, _ in
            refreshICloudStatus()
        }
    }

    private var localFolderSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let bookmarkData = syncLocalFolderBookmarkData, !bookmarkData.isEmpty,
               SyncBackendResolver.resolveLocalFolderBackend(bookmarkData: bookmarkData) != nil {
                Text("Папка выбрана.")
                    .foregroundStyle(.secondary)
            } else {
                Text("Папка не выбрана.")
                    .foregroundStyle(.secondary)
            }
            Button("Выбрать папку…") {
                let panel = NSOpenPanel()
                panel.canChooseFiles = false
                panel.canChooseDirectories = true
                panel.allowsMultipleSelection = false
                if panel.runModal() == .OK, let folderURL = panel.url {
                    syncLocalFolderBookmarkData = try? LocalFolderBackend.createBookmark(for: folderURL)
                }
            }
        }
    }

    private var iCloudSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            if iCloudContainerAvailable {
                Text("Контейнер iCloud доступен.")
                    .foregroundStyle(.secondary)
            } else {
                Text(iCloudContainerCheckMessage ?? "iCloud Drive недоступен — войдите в iCloud и включите iCloud Drive в Системных настройках.")
                    .foregroundStyle(.orange)
            }
        }
    }

    private var sftpSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Хост", text: $sftpHost)
            Stepper("Порт: \(sftpPort)", value: $sftpPort, in: 1...65535)
            TextField("Пользователь", text: $sftpUsername)
                .onChange(of: sftpUsername) { _, _ in persistCredentialsToKeychain() }
            TextField("Путь на сервере", text: $sftpRemotePath)
            SecureField("Passphrase ключа (если есть)", text: $sftpPassphrase)
                .onChange(of: sftpPassphrase) { _, _ in persistCredentialsToKeychain() }

            HStack {
                Text(sftpPrivateKeyPath.isEmpty ? "Ключ не выбран" : sftpPrivateKeyPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Выбрать приватный ключ…") {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = true
                    panel.canChooseDirectories = false
                    panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK, let url = panel.url {
                        sftpPrivateKeyPath = url.path
                        if let contents = try? String(contentsOf: url, encoding: .utf8) {
                            sftpPrivateKeyPEM = contents
                            persistCredentialsToKeychain()
                        }
                    }
                }
            }

            HStack {
                Text(sftpCertificatePath.isEmpty ? "Сертификат не выбран (опционально)" : sftpCertificatePath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Выбрать сертификат…") {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = true
                    panel.canChooseDirectories = false
                    panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK, let url = panel.url {
                        // Path-only, UI bookkeeping — see this task's
                        // "Известный пробел" note: not yet wired into any
                        // real SSH authentication.
                        sftpCertificatePath = url.path
                    }
                }
            }

            Button("Проверить соединение") {
                testSFTPConnection()
            }
            switch connectionTestState {
            case .idle:
                EmptyView()
            case .testing:
                ProgressView().controlSize(.small)
            case .success:
                Label("Соединение успешно", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .failure(let message):
                Label(message, systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
            }
        }
    }

    private func loadSFTPCredentialsIfAvailable() {
        guard !sftpHost.isEmpty,
              let credentials = try? CredentialKeychainStore().loadCredentials(forHost: sftpHost) else { return }
        sftpUsername = credentials.username
        sftpPrivateKeyPEM = credentials.privateKeyPEM
        sftpPassphrase = credentials.privateKeyPassphrase ?? ""
    }

    private func persistCredentialsToKeychain() {
        guard !sftpHost.isEmpty, !sftpPrivateKeyPEM.isEmpty else { return }
        let credentials = SFTPCredentials(
            username: sftpUsername,
            privateKeyPEM: sftpPrivateKeyPEM,
            privateKeyPassphrase: sftpPassphrase.isEmpty ? nil : sftpPassphrase
        )
        try? CredentialKeychainStore().store(credentials, forHost: sftpHost)
    }

    private func testSFTPConnection() {
        connectionTestState = .testing
        let configuration = SyncBackendResolver.buildSFTPConfiguration(
            host: sftpHost,
            port: sftpPort,
            username: sftpUsername,
            remotePath: sftpRemotePath,
            credentials: SFTPCredentials(
                username: sftpUsername,
                privateKeyPEM: sftpPrivateKeyPEM,
                privateKeyPassphrase: sftpPassphrase.isEmpty ? nil : sftpPassphrase
            )
        )
        let tester = SFTPConnectionTester(configurationProvider: { configuration })
        DispatchQueue.global(qos: .userInitiated).async {
            let result = tester.testConnection()
            DispatchQueue.main.async {
                switch result {
                case .success:
                    connectionTestState = .success
                case .failure(let error):
                    connectionTestState = .failure("\(error)")
                }
            }
        }
    }

    private func refreshICloudStatus() {
        guard selectedOption == .iCloud else { return }
        do {
            _ = try iCloudBackend(relativePath: "vault.kdbx")
            iCloudContainerAvailable = true
            iCloudContainerCheckMessage = nil
        } catch iCloudBackendError.containerUnavailable {
            iCloudContainerAvailable = false
            iCloudContainerCheckMessage = "iCloud Drive недоступен — войдите в iCloud и включите iCloud Drive в Системных настройках."
        } catch {
            iCloudContainerAvailable = false
            iCloudContainerCheckMessage = "Не удалось проверить контейнер iCloud: \(error)"
        }
    }
}
```

Modify `MyPass/MyPassApp.swift`'s `init()` — replace the backend-construction `switch` case `.sftp` (everything else in `init()` is unchanged from Task 12):

```swift
            case .sftp:
                let host = defaults.string(forKey: "syncSFTPHost") ?? ""
                let port = defaults.object(forKey: "syncSFTPPort") as? Int ?? 22
                let remotePath = defaults.string(forKey: "syncSFTPRemotePath") ?? "/upload/vault.kdbx"
                guard !host.isEmpty,
                      let credentials = try? CredentialKeychainStore().loadCredentials(forHost: host) else {
                    backend = nil
                    break
                }
                let configuration = SyncBackendResolver.buildSFTPConfiguration(
                    host: host,
                    port: port,
                    username: defaults.string(forKey: "syncSFTPUsername") ?? "",
                    remotePath: remotePath,
                    credentials: credentials
                )
                backend = configuration.map {
                    SFTPBackend(configuration: $0, trustedHostKeyStore: UserDefaultsTrustedHostKeyStore())
                }
```

(This replaces the `case .sftp: backend = nil // wired in Task 13` line from Task 12's version of `init()`.)

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/SettingsViewSyncBackendTests`
Expected: PASS (8/8 — 3 existing from Task 12 + 5 new).

- [ ] **Step 5: Run the full MyPass test suite to check for regressions**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS'`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add MyPass/UI/Settings/SettingsView.swift MyPass/MyPassApp.swift MyPass/State/SFTPConnectionTester.swift MyPass/State/SyncBackendResolver.swift MyPassTests/SettingsViewSyncBackendTests.swift
git commit -m "Settings: форма конфигурации SFTP, проверка соединения, Keychain-хранение passphrase (Фаза 3, Task 13)"
```

---

Этот план последовательно вводит соглашение env-var-гейтинга для тестов, зависящих от внешних ресурсов недоступных в обычном CI-раннере: `MYPASS_KEYCHAIN_TESTS` (Task 9, реальный Keychain), `MYPASS_SFTP_INTEGRATION_TESTS` (Task 10, реальный SFTP-сервер), `MYPASS_ICLOUD_INTEGRATION_TESTS` (Task 11, реальный ubiquity-контейнер). Task 14 ниже — не альтернатива этому соглашению, а конкретная, воспроизводимая реализация внешнего ресурса, который Task 10's `MYPASS_SFTP_INTEGRATION_TESTS` гейт ожидает: локальный Docker-контейнер `atmoz/sftp`, поднятый на `127.0.0.1:2222`, с пользователем `testuser` и SSH-ключом `/tmp/citadel_smoke_key`/`.pub`, — то есть ровно то, что Task 10's `SFTPBackendTests.swift` уже документирует в шапке файла как ручную инструкцию для локального запуска. CI должен: (1) запустить `run.sh`, (2) `export MYPASS_SFTP_INTEGRATION_TESTS=1`, (3) `cd Packages/SyncKit && swift test --filter SFTPBackendTests`, (4) запустить `teardown.sh` — вне зависимости от результата шага 3 (в реальном CI-конфиге это оформляется через `trap`/`always()`-блок, здесь показано последовательно ради ясности TDD-шагов ниже).

### Task 14: Docker sshd — воспроизводимый фикстур для SFTP-интеграционных тестов

**Files:**
- Create: `Packages/SyncKit/Tests/Fixtures/docker-sshd/Dockerfile`
- Create: `Packages/SyncKit/Tests/Fixtures/docker-sshd/README.md`
- Create: `Packages/SyncKit/Tests/Fixtures/docker-sshd/run.sh`
- Create: `Packages/SyncKit/Tests/Fixtures/docker-sshd/teardown.sh`

**Interfaces:**
- Consumes: Task 10's `SFTPBackendTests.swift` (hardcodes `127.0.0.1:2222`, user `testuser`, private key at `/tmp/citadel_smoke_key` with passphrase `correct-horse-battery-staple`, remote paths under `/upload/`) and Task 8's `CitadelDependencySmokeTests.swift` (same key path/passphrase) — this fixture's `run.sh` produces exactly that environment so both test files, unmodified, work against it.
- Produces: `run.sh` (idempotent: builds+starts a named `mypass-test-sshd` container, generates the fixture keys if absent, waits for sshd to accept TCP connections), `teardown.sh` (stops+removes the container). Not consumed by any Swift code — this is test infrastructure only, invoked from the command line / CI job steps, not from `swift test` itself.

Это не Swift-задача (в отличие от Задач 1-13), поэтому её "TDD"-шаги ниже — не red/green/refactor над XCTest, а red/green над реальным Docker-контейнером и реальным `swift test --filter SFTPBackendTests`: Step 1 создаёт фикстуру, Step 2 проверяет, что она поднимается и проходит healthcheck, Step 3 — что Task 10's ранее `XCTSkip`-гейтнутые тесты реально выполняются и проходят против неё, Step 4 проверяет корректный teardown, Step 5 коммитит файлы фикстуры.

- [ ] **Step 1: Write the Dockerfile and scripts**

Create `Packages/SyncKit/Tests/Fixtures/docker-sshd/Dockerfile`:

```dockerfile
FROM atmoz/sftp:alpine

# Fixed SSH host keys baked into the image so TrustOnFirstUseHostKeyValidator
# (Task 10) trust stays valid across container rebuilds — a freshly
# generated host key on every `docker build` would otherwise force a
# re-trust (new TOFU pin) on every CI run. Generated once by run.sh below,
# committed alongside this Dockerfile (see README.md).
COPY ssh_host_ed25519_key /etc/ssh/ssh_host_ed25519_key
COPY ssh_host_ed25519_key.pub /etc/ssh/ssh_host_ed25519_key.pub
COPY ssh_host_rsa_key /etc/ssh/ssh_host_rsa_key
COPY ssh_host_rsa_key.pub /etc/ssh/ssh_host_rsa_key.pub
RUN chmod 600 /etc/ssh/ssh_host_ed25519_key /etc/ssh/ssh_host_rsa_key
```

Create `Packages/SyncKit/Tests/Fixtures/docker-sshd/README.md`:

```markdown
# SFTP test fixture (`atmoz/sftp`)

Provides the real SFTP server that `Packages/SyncKit/Tests/SyncKitTests/SFTPBackendTests.swift`
(Task 10) connects to when `MYPASS_SFTP_INTEGRATION_TESTS=1` is set.

## Usage

```sh
./run.sh                                                    # build + start + healthcheck
MYPASS_SFTP_INTEGRATION_TESTS=1 swift test --filter SFTPBackendTests   # from Packages/SyncKit
./teardown.sh                                                # stop + remove
```

## What `run.sh` sets up

- Container `mypass-test-sshd`, image built from the local `Dockerfile` (pins `atmoz/sftp:alpine`
  plus fixed SSH host keys), port-mapped `2222:22`.
- User `testuser`, public-key auth only (`SFTP_USERS=testuser::1001`, empty password field
  disables password auth).
- Client key pair `test_key`/`test_key.pub` (committed in this directory) copied to
  `/tmp/citadel_smoke_key`/`.pub` — the exact path Task 8's `CitadelDependencySmokeTests.swift`
  and Task 10's `SFTPBackendTests.swift` already hardcode.

## Regenerating the fixture keys

These were generated once via (`run.sh` regenerates them automatically if the files are
ever deleted — the commands below are shown for reference/reproducibility):

```sh
# Client auth key — passphrase-protected, matches Task 8/10's hardcoded passphrase.
ssh-keygen -t ed25519 -N "correct-horse-battery-staple" -f test_key -C "mypass-sftp-fixture"

# Server host keys — unencrypted (sshd cannot prompt for a passphrase on its own host key).
ssh-keygen -t ed25519 -N "" -f ssh_host_ed25519_key -C "mypass-test-sshd-host-key"
ssh-keygen -t rsa -b 4096 -N "" -f ssh_host_rsa_key -C "mypass-test-sshd-host-key-rsa"
```

These are test-only, local-Docker-fixture credentials with a well-known passphrase — never
used for anything beyond this fixture, and never granting access to anything but the throwaway
container `run.sh` creates.
```

Create `Packages/SyncKit/Tests/Fixtures/docker-sshd/run.sh` (executable, `chmod +x`):

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

CONTAINER_NAME="mypass-test-sshd"
CLIENT_KEY_PATH="/tmp/citadel_smoke_key"

if [ ! -f test_key ] || [ ! -f test_key.pub ]; then
  echo "Generating client fixture keypair..."
  ssh-keygen -t ed25519 -N "correct-horse-battery-staple" -f test_key -C "mypass-sftp-fixture"
fi
if [ ! -f ssh_host_ed25519_key ] || [ ! -f ssh_host_ed25519_key.pub ]; then
  echo "Generating ed25519 host keypair..."
  ssh-keygen -t ed25519 -N "" -f ssh_host_ed25519_key -C "mypass-test-sshd-host-key"
fi
if [ ! -f ssh_host_rsa_key ] || [ ! -f ssh_host_rsa_key.pub ]; then
  echo "Generating RSA host keypair..."
  ssh-keygen -t rsa -b 4096 -N "" -f ssh_host_rsa_key -C "mypass-test-sshd-host-key-rsa"
fi

cp test_key "$CLIENT_KEY_PATH"
cp test_key.pub "$CLIENT_KEY_PATH.pub"
chmod 600 "$CLIENT_KEY_PATH"

echo "Building image..."
docker build -t mypass-test-sshd:latest .

docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true

echo "Starting container..."
docker run -d --name "$CONTAINER_NAME" -p 2222:22 \
  -v "$(pwd)/test_key.pub:/home/testuser/.ssh/keys/id_ed25519.pub:ro" \
  -e SFTP_USERS=testuser::1001 \
  mypass-test-sshd:latest

echo "Waiting for sshd to accept TCP connections on 127.0.0.1:2222..."
for i in $(seq 1 30); do
  if (exec 3<>"/dev/tcp/127.0.0.1/2222") 2>/dev/null; then
    exec 3<&- 2>/dev/null || true
    echo "sshd is up (attempt $i)."
    exit 0
  fi
  sleep 1
done

echo "sshd did not become ready within 30s" >&2
docker logs "$CONTAINER_NAME" >&2 || true
exit 1
```

Create `Packages/SyncKit/Tests/Fixtures/docker-sshd/teardown.sh` (executable, `chmod +x`):

```bash
#!/usr/bin/env bash
set -euo pipefail

CONTAINER_NAME="mypass-test-sshd"

docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
docker rm "$CONTAINER_NAME" >/dev/null 2>&1 || true
echo "$CONTAINER_NAME removed."
```

- [ ] **Step 2: Run `run.sh` and verify the healthcheck passes**

Run: `cd Packages/SyncKit/Tests/Fixtures/docker-sshd && chmod +x run.sh teardown.sh && ./run.sh`
Expected output (key generation lines only appear the first time, before the keys are committed):
```
Building image...
Starting container...
Waiting for sshd to accept TCP connections on 127.0.0.1:2222...
sshd is up (attempt 1).
```
Also run: `docker ps --filter name=mypass-test-sshd --format '{{.Names}}: {{.Status}}'`
Expected: `mypass-test-sshd: Up ...`.

- [ ] **Step 3: Run Task 10's SFTPBackendTests against the live container**

Run: `cd Packages/SyncKit && MYPASS_SFTP_INTEGRATION_TESTS=1 swift test --filter SFTPBackendTests`
Expected: PASS (5/5) — every test in `SFTPBackendTests` that previously `XCTSkip`-ed (Task 10, Step 4) now actually executes:
```
Test Suite 'SFTPBackendTests' started.
Test Suite 'SFTPBackendTests' passed.
	 Executed 5 tests, with 0 failures (0 unexpected) in ... seconds
```

- [ ] **Step 4: Run `teardown.sh` and verify the container is gone**

Run: `cd Packages/SyncKit/Tests/Fixtures/docker-sshd && ./teardown.sh`
Expected: `mypass-test-sshd removed.`
Also run: `docker ps --filter name=mypass-test-sshd`
Expected: empty table (just the header row) — no running or stopped container by that name remains.

- [ ] **Step 5: Commit**

```bash
git add Packages/SyncKit/Tests/Fixtures/docker-sshd/Dockerfile Packages/SyncKit/Tests/Fixtures/docker-sshd/README.md Packages/SyncKit/Tests/Fixtures/docker-sshd/run.sh Packages/SyncKit/Tests/Fixtures/docker-sshd/teardown.sh Packages/SyncKit/Tests/Fixtures/docker-sshd/test_key Packages/SyncKit/Tests/Fixtures/docker-sshd/test_key.pub Packages/SyncKit/Tests/Fixtures/docker-sshd/ssh_host_ed25519_key Packages/SyncKit/Tests/Fixtures/docker-sshd/ssh_host_ed25519_key.pub Packages/SyncKit/Tests/Fixtures/docker-sshd/ssh_host_rsa_key Packages/SyncKit/Tests/Fixtures/docker-sshd/ssh_host_rsa_key.pub
git commit -m "SyncKit: Docker-фикстура atmoz/sftp для MYPASS_SFTP_INTEGRATION_TESTS (Фаза 3, Task 14)"
```

---

## Self-Review

### 1. Spec coverage

Сверка с `docs/superpowers/specs/2026-07-21-mypass-design.md`'s `## Синхронизация`:

- «локальная рабочая копия... бэкенд — удалённая точка правды» → `VaultFileStore` (Phase 2, unchanged) + `StorageBackend` (Task 1) + `SyncEngine` (Task 6) architecture split, described in this plan's own Architecture line.
- «Цикл: 1. Скачать удалённый файл, если изменился. 2. Не менялся → загрузить свой. 3. Менялся → merge → загрузить результат.» → `SyncEngine.sync(local:password:cipher:compression:)` (Task 6), checkpoint-driven skip-vs-merge logic, tested by `SyncEngineTests`.
- «Загрузка атомарна (для SFTP: upload во временное имя → rename на сервере)» → `SFTPBackend.write(_:)` (Task 10): write to `.tmp-<uuid>`, verify bytes, remove old, rename. `LocalFolderBackend.write(_:)` (Task 2) uses the analogous temp-file + `replaceItemAt` pattern. `iCloudBackend.write(_:)` (Task 11) uses `NSFileCoordinator`'s `.forReplacing` coordinated write (iCloud's own atomicity guarantee for coordinated writes, no separate temp-file dance needed at this layer).
- «Merge (семантика KeePassXC Synchronize)»: UUID matching, newer-`lastModificationTime` wins with loser in History, `DeletedObjects` vs edit by event time, moves by `locationChanged`, no dialogs — all covered by `MergeEngine.merge(local:remote:)` (Tasks 4-5), with dedicated rule-by-rule tests (rules 1-4+9 in Task 4, rules 5-8 in Task 5).
- «iCloud Drive: NSFileCoordinator + NSFilePresenter; conflict-версии (NSFileVersion) прогоняются через merge и удаляются» → `iCloudBackend` (Task 11) implements the NSFileCoordinator/NSFilePresenter half in full. **Частичный пробел:** explicit `NSFileVersion` conflict-version enumeration/cleanup ("прогоняются через merge и удаляются") is NOT implemented anywhere in Tasks 1-11 — `iCloudBackend.read()`/`write(_:)` rely on `NSFileCoordinator` to avoid creating conflict versions in the common case, but do not enumerate `NSFileVersion.unresolvedConflictVersionsOfItem(at:)` and merge+discard them if iCloud ever does create one (e.g., after an extended offline period on two devices). This is a real, explicitly-flagged gap — a future task would add a `resolveConflictVersions()` step to `iCloudBackend` calling `NSFileVersion`'s API before/after each `sync()` pass.
- «Локальная папка: выбор папки, security-scoped bookmark, FSEvents» → `LocalFolderBackend`/`createBookmark(for:)` (Task 2), `LocalFolderChangeWatcher` (Task 3), folder-picker + bookmark persistence (Task 12). Fully covered — including wiring `LocalFolderChangeWatcher`'s `onChange` to `VaultSession.triggerBackgroundSync()`, added in Task 12 to close Task 3's own forward reference (Task 3's Interfaces note originally deferred this to "Part B's app-level auto-sync trigger").
- «SFTP: host, port, путь, пользователь, приватный ключ, опционально OpenSSH-сертификат. Host key — TOFU. Passphrase — в Keychain. Кандидаты: Citadel, mft.» → library choice + rationale (Task 8), TOFU host-key validator (Task 10's `TrustOnFirstUseHostKeyValidator`, though see note below on `known_hosts` vs `UserDefaults`), Keychain-stored passphrase via `CredentialKeychainStore` (Task 9), full config form (Task 13). **Явный пробел:** OpenSSH-сертификат аутентификация НЕ реализована — `SFTPBackendConfiguration` (Task 10) и Citadel's `SSHAuthenticationMethod` usage support only ed25519 private-key auth, no certificate field. Task 13's certificate file picker is UI-only bookkeeping, explicitly commented as not wired into any real connection (see Task 13's "Известный пробел" note). This traces directly to the design doc's own risk table row ("SFTP-библиотека без OpenSSH-сертификатов | Ранний прототип в фазе 3; худший случай — C-биндинги libssh") — the risk was accepted, not silently dropped, but it remains unimplemented and should be a named follow-up task before Phase 3 is considered fully spec-complete.
- «Host key — TOFU по known_hosts» — Task 10 implements TOFU semantics correctly (first-seen key trusted, mismatched key on reconnect rejected — verified by 4 `TrustOnFirstUseHostKeyValidatorTests`), but stores the trusted key via `UserDefaultsTrustedHostKeyStore` (a `UserDefaults` key-value pair), not a literal `~/.ssh/known_hosts`-format file. This is a naming/storage-format deviation from the spec's literal wording, not a semantic gap — the TOFU guarantee itself is fully met, and using `UserDefaults` is defensible for the app's own management (no dependency on `ssh`'s own known_hosts format/location, no interference with the user's real known_hosts). Noting explicitly here rather than silently.
- «Сбой сети посреди sync → рабочая копия не тронута, повтор в следующем цикле» → `SyncEngineTests.testMidCycleFailureLeavesCheckpointAndLocalUntouched` (Task 6) and `VaultSessionTests`' network-failure test (Task 7, line ~2160 of this plan) both cover this directly.
- «Цикл: при открытии, после сохранения, по таймеру, вручную» — Tasks 6-7 wire only two of these four triggers (at-unlock via `syncOnUnlock`, after-save via `persist(_:)`'s call into `syncEngine.sync(...)`). The remaining two (periodic timer, manual trigger) were a genuine gap found during this self-review and fixed inline in Task 12: `VaultSession.triggerBackgroundSync()` + `MyPassApp`'s `Timer.scheduledTimer(withTimeInterval: 300, ...)` (periodic) + Settings' "Синхронизировать сейчас" button (manual). All four triggers are now covered.

### 2. Placeholder scan

Grepped the entire file (Tasks 1-14, this Self-Review section, and the header) for `TODO`, `implement later`, `similar to Task`, `handle appropriately`, `FIXME`. The only hits are the header's own "No placeholders" rule line (`никогда "TODO"/"implement later"/"similar to Task N"` — the rule text itself, expected and excluded per this review's instructions) and this Self-Review section's own prose describing that rule and describing the two gaps above (which reference the *concept* of a gap, not literal placeholder code — every Step 3 in Tasks 1-14 contains complete, runnable code, not a stub). No unexpected hits.

### 3. Type consistency

Cross-checked every reused signature against its origin task's Produces block (not re-derived from memory):

- `StorageBackend` (Task 1: `read() throws -> Data?`, `write(_ data: Data) throws`, `modificationDate() throws -> Date?`, `exists() throws -> Bool`) — implemented identically by `LocalFolderBackend` (Task 2), `iCloudBackend` (Task 11), `SFTPBackend` (Task 10), and used identically by `SyncEngine` (Task 6). Consistent.
- `SyncEngine.init(remote: StorageBackend, checkpointStore: SyncCheckpointStore)` / `.sync(local:password:cipher:compression:) throws -> SyncResult` (Task 6) — used with this exact signature in `VaultSession` (Task 7) and in Task 12/13's `MyPassApp.init()`. Consistent. (Corrected during drafting: earlier working notes for this part of the plan assumed a `SyncEngine(backend:checkpointStore:)` label — the real Task 6 signature uses `remote:`, used correctly throughout Tasks 12-14.)
- `SyncCheckpointStore` / `UserDefaultsSyncCheckpointStore.init(defaults:key:)` (Task 6) — Task 12 calls it with `key: "com.mypass.sync.checkpoint.\(syncBackendOption.rawValue)")`; there is no `backendIdentifier:` parameter (confirmed by reading Task 6's actual Produces block) — Task 12/13 do not use that label anywhere.
- `CredentialStoring` / `SFTPCredentials` (Task 9: `loadCredentials(forHost:)`, `store(_:forHost:)`, `removeCredentials(forHost:)`) — used with the `forHost:` label consistently in Task 13's `SettingsView` and `SyncBackendResolver.buildSFTPConfiguration`; there is no `account:`-keyed variant anywhere in Tasks 9-14.
- `SFTPConnectionConfig` does not exist anywhere in this plan — the real Task 10 type is `SFTPBackendConfiguration` (`host:port:username:remotePath:privateKeyPEM:privateKeyPassphrase:`), used with that exact name and those exact labels in Tasks 13-14. No stray references to a `SFTPConnectionConfig` name were introduced.
- `SFTPBackend.init(configuration:trustedHostKeyStore:group:)` (Task 10) — Task 13's `SFTPConnectionTester` and `MyPassApp.init()`'s `.sftp` case both call it with `configuration:`/`trustedHostKeyStore:` (no `knownHostsURL:` parameter exists on the real type — confirmed by reading Task 10's Produces block directly rather than assuming it).
- `iCloudBackend.init(relativePath:containerIdentifier:)` (Task 11) — used identically in `SyncBackendResolver.resolveICloudBackend` and `SettingsView.refreshICloudStatus` (Task 12/13).
- `LocalFolderBackend.init(bookmarkData:filename:)` / `.createBookmark(for:)` (Task 2) — used identically in `SyncBackendResolver.resolveLocalFolderBackend` and `SettingsView`'s folder-picker button (Task 12).
- `MergeEngine.merge(local:remote:) -> KdbxDatabase` (Tasks 4-5, non-throwing) — only consumed internally by `SyncEngine` (Task 6); no Task 11-14 code calls it directly, so no risk of a signature mismatch being introduced downstream.
- `VaultSession.init(fileStore:syncEngine:)` (Task 7) — used identically in `MyPassApp.init()` (Task 12/13); `VaultSession.triggerBackgroundSync()` (new, Task 12) does not alter this initializer or any other existing public member.

No mismatches found beyond the two explicitly-flagged spec-coverage gaps above (`NSFileVersion` conflict cleanup, OpenSSH certificate auth) and the one naming clarification (`UserDefaultsTrustedHostKeyStore` vs. a literal `known_hosts` file) — all three are now documented inline rather than hidden, per this review's own instructions.

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-07-22-mypass-phase3-sync.md`. Two execution options:

1. **Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration
2. **Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints

Which approach?
