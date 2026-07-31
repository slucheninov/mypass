# Vault Location Move, Sync, and Open Existing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix four shipped bugs in unified vault location — move (not copy) with path display, case-insensitive iCloud folder guard, primary iCloud LWW sync without write churn, and a working Open Existing `.kdbx` flow — without changing the Local / iCloud primary model.

**Architecture:** Add `LocalFileVaultStore` for security-scoped file bookmarks (`localVaultFileBookmark`), extend `VaultPrimaryStoreResolver` and `VaultLocationChangeSheet` for move semantics (verify destination → delete source → swap bookmarks), teach `VaultSession.persist` to skip identical serialized bytes and reload (not push) on primary iCloud remote changes, and wire Open Existing through a password sheet that retargets primary storage.

**Tech Stack:** Swift, SwiftUI (macOS 14+), XCTest, SyncKit (`StorageBackend`, `iCloudBackend`, `SyncEngine`), existing `VaultSession` / `VaultMigrationService` / `VaultLocationChangeSheet`.

## Global Constraints

- English everywhere (code, comments, docs, UI, commits) — per root `CLAUDE.md`.
- Do not rename pinned UserDefaults key `syncICloudFolderBookmark` (`SyncBackendResolver.iCloudFolderBookmarkKey`).
- New UserDefaults key: `localVaultFileBookmark` (file bookmark for Open Existing / bookmarked local primary mode).
- Move deletes source only after verified destination write (open with master password succeeds on destination bytes).
- Primary sync is LWW (no entry merge on primary); secondary `SyncEngine` unchanged except it must not run when primary persist skipped due to identical bytes.
- Keep relativePath for iCloud as `vault.kdbx`.
- UI copy uses **Move**, not Switch/Copy, for location changes.
- Open Existing: selected file becomes primary at its path; delete Application Support vault only when current primary is default local (no `localVaultFileBookmark`); do not delete previous iCloud or bookmarked local file.
- Open Existing from iCloud primary: clear `syncICloudFolderBookmark`, set `vaultLocation = local`, save `localVaultFileBookmark`.
- iCloud remote reload on wrong password / corrupt file: do not wipe in-memory DB; show non-blocking error; do not write back.
- Path display when stale bookmark: show `"Path unavailable"` plus existing iCloud fallback warning.
- No new entitlements; security-scoped bookmarks only (`com.apple.security.files.user-selected.read-write` + `.files.bookmarks.app-scope`).
- KeePassXC 32-byte salt compatibility remains out of scope.

---

## File Structure

| File | Action | Responsibility |
|------|--------|----------------|
| `MyPass/Storage/LocalFileVaultStore.swift` | Create | Primary store for a user-picked `.kdbx` file via security-scoped file bookmark; `load`/`save` with scope access; exposes `vaultURL`. |
| `MyPass/Storage/VaultPrimaryStorage.swift` | Modify | Extend protocol with `primaryVaultFileURL` and `deleteVaultFileIfPresent()` for path display and move cleanup. |
| `MyPass/Storage/VaultFileStore.swift` | Modify | Conform new protocol requirements (`primaryVaultFileURL`, `deleteVaultFileIfPresent`). |
| `MyPass/Storage/ICloudDriveVaultStore.swift` | Modify | Conform new protocol requirements; expose coordinated vault file URL for display/delete. |
| `MyPass/Storage/VaultICloudFolderSelection.swift` | Create | Pure, testable iCloud folder resolution (case-insensitive `MyPass`, existing `vault.kdbx` at root). |
| `MyPass/Storage/VaultLocationMoveSupport.swift` | Create | Verify destination opens with password; delete source primary vault file after verified move. |
| `MyPass/State/SyncBackendResolver.swift` | Modify | Add `localVaultFileBookmarkKey = "localVaultFileBookmark"`. |
| `MyPass/State/VaultPrimaryStoreResolver.swift` | Modify | Resolve `LocalFileVaultStore` when `local` + valid file bookmark. |
| `MyPass/State/VaultSession.swift` | Modify | Skip-identical persist, dirty flag + timer gating, primary remote reload (LWW), `primaryVaultPathDisplay`, `retargetToOpenExistingVault(...)`. |
| `MyPass/MyPassApp.swift` | Modify | Pass `localVaultFileBookmark` into resolver; timer calls dirty-gated sync. |
| `MyPass/UI/Settings/VaultLocationChangeSheet.swift` | Modify | Use `VaultICloudFolderSelection`; move flow (verify → delete source → swap bookmarks); Move copy; bookmark bookkeeping. |
| `MyPass/UI/Settings/VaultLocationSettingsPane.swift` | Modify | Show resolved path caption; button labels use Move wording. |
| `MyPass/UI/EntryList/EntryListView.swift` | Modify | Replace Open Existing stub with password sheet + session retarget. |
| `MyPass/UI/Unlock/UnlockView.swift` | Modify | Add Open Existing `.kdbx` entry point (small addition — same sheet as EntryList). |
| `MyPass/UI/Settings/OpenExistingVaultSheet.swift` | Create | Reusable password prompt + error alert for Open Existing. |
| `Packages/SyncKit/Sources/SyncKit/iCloudBackend.swift` | Modify | Add `readNewestAvailableBytes()` using `NSFileVersion` LWW for primary reload. |
| `MyPassTests/LocalFileVaultStoreTests.swift` | Create | Bookmark round-trip, scope access, delete. |
| `MyPassTests/VaultPrimaryStoreResolverTests.swift` | Modify | Local + file bookmark → `LocalFileVaultStore`. |
| `MyPassTests/VaultICloudFolderSelectionTests.swift` | Create | Case-insensitive folder guard cases. |
| `MyPassTests/VaultLocationMoveSupportTests.swift` | Create | Verify + delete-after-move semantics. |
| `MyPassTests/VaultMigrationServiceTests.swift` | Modify | Update seedRemote test name/expectation if service unchanged (move delete is sheet-level). |
| `MyPassTests/VaultSessionTests.swift` | Modify | Skip-identical persist spy; remote reload replaces push; update `testUpdatePrimaryStoreRewiresOnRemoteChangeForTheNewStore`. |
| `MyPassTests/VaultLocationChangeSheetMessageTests.swift` | Modify | Assert Move wording where applicable. |
| `MyPassTests/OpenExistingVaultTests.swift` | Create | Session retarget, bookmark persistence, App Support delete guard. |

---

### Task 1: `LocalFileVaultStore`

**Files:**
- Create: `MyPass/Storage/LocalFileVaultStore.swift`
- Modify: `MyPass/Storage/VaultPrimaryStorage.swift`
- Modify: `MyPass/Storage/VaultFileStore.swift` (protocol conformance stubs — full delete impl in Task 4)
- Test: `MyPassTests/LocalFileVaultStoreTests.swift`

**Interfaces:**
- Produces: `final class LocalFileVaultStore: VaultPrimaryStorage` with `init(bookmarkData: Data) throws`, `static func createFileBookmark(for fileURL: URL) throws -> Data`, `var vaultURL: URL`, `var primaryVaultFileURL: URL? { vaultURL }`, `func deleteVaultFileIfPresent() throws`, `func load() throws -> Data?`, `func save(data: Data) throws`.
- Produces: extended `VaultPrimaryStorage` with `var primaryVaultFileURL: URL? { get }` and `func deleteVaultFileIfPresent() throws`.

- [ ] **Step 1: Write the failing test**

`MyPassTests/LocalFileVaultStoreTests.swift`:

```swift
import XCTest
@testable import MyPass

final class LocalFileVaultStoreTests: XCTestCase {
    var tempDir: URL!
    var vaultFileURL: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalFileVaultStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        vaultFileURL = tempDir.appendingPathComponent("my-vault.kdbx")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testLoadReturnsNilBeforeAnyWrite() throws {
        try Data("seed".utf8).write(to: vaultFileURL)
        let bookmark = try LocalFileVaultStore.createFileBookmark(for: vaultFileURL)
        let store = try LocalFileVaultStore(bookmarkData: bookmark)
        try FileManager.default.removeItem(at: vaultFileURL)
        XCTAssertNil(try store.load())
    }

    func testSaveThenLoadRoundTripsThroughBookmark() throws {
        let bookmark = try LocalFileVaultStore.createFileBookmark(for: vaultFileURL)
        let store = try LocalFileVaultStore(bookmarkData: bookmark)
        try store.save(data: Data("local-file-round-trip".utf8))
        XCTAssertEqual(try store.load(), Data("local-file-round-trip".utf8))
        XCTAssertEqual(store.primaryVaultFileURL?.path, vaultFileURL.path)
    }

    func testDeleteVaultFileIfPresentRemovesFile() throws {
        let bookmark = try LocalFileVaultStore.createFileBookmark(for: vaultFileURL)
        let store = try LocalFileVaultStore(bookmarkData: bookmark)
        try store.save(data: Data("to-delete".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: vaultFileURL.path))
        try store.deleteVaultFileIfPresent()
        XCTAssertFalse(FileManager.default.fileExists(atPath: vaultFileURL.path))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/LocalFileVaultStoreTests 2>&1 | tail -40`

Expected: FAIL — `LocalFileVaultStore` does not exist (compile error).

- [ ] **Step 3: Extend `VaultPrimaryStorage` and add `LocalFileVaultStore`**

`MyPass/Storage/VaultPrimaryStorage.swift`:

```swift
import Foundation

protocol VaultPrimaryStorage {
    func load() throws -> Data?
    func save(data: Data) throws

    /// Absolute path to the primary `vault.kdbx` (or opened `.kdbx`) for Settings display.
    var primaryVaultFileURL: URL? { get }

    /// Removes the primary vault file if it exists. Used after a verified move.
    func deleteVaultFileIfPresent() throws
}
```

`MyPass/Storage/LocalFileVaultStore.swift`:

```swift
import Foundation

/// Primary storage when the user opened an existing `.kdbx` file (security-scoped file bookmark).
final class LocalFileVaultStore: VaultPrimaryStorage {
    private let fileURL: URL
    private let holdsSecurityScope: Bool
    private let queue = DispatchQueue(label: "com.tentens.mypass.LocalFileVaultStore")

    var vaultURL: URL { fileURL }
    var primaryVaultFileURL: URL? { fileURL }

    init(bookmarkData: Data) throws {
        var isStale = false
        guard !bookmarkData.isEmpty,
              let url = try? URL(
                  resolvingBookmarkData: bookmarkData,
                  options: .withSecurityScope,
                  relativeTo: nil,
                  bookmarkDataIsStale: &isStale
              ),
              !isStale else {
            throw LocalFileVaultStoreError.staleBookmark
        }
        self.fileURL = url
        self.holdsSecurityScope = url.startAccessingSecurityScopedResource()
    }

    deinit {
        if holdsSecurityScope {
            fileURL.stopAccessingSecurityScopedResource()
        }
    }

    static func createFileBookmark(for fileURL: URL) throws -> Data {
        try fileURL.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    func load() throws -> Data? {
        try queue.sync {
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
            return try Data(contentsOf: fileURL)
        }
    }

    func save(data: Data) throws {
        try queue.sync {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let tempURL = directory.appendingPathComponent(".tmp-\(UUID().uuidString)")
            try data.write(to: tempURL, options: .atomic)
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tempURL)
        }
    }

    func deleteVaultFileIfPresent() throws {
        try queue.sync {
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
            try FileManager.default.removeItem(at: fileURL)
        }
    }
}

enum LocalFileVaultStoreError: Error {
    case staleBookmark
}
```

Add to `MyPass/Storage/VaultFileStore.swift`:

```swift
    var primaryVaultFileURL: URL? { vaultURL }

    func deleteVaultFileIfPresent() throws {
        try queue.sync {
            guard FileManager.default.fileExists(atPath: vaultURL.path) else { return }
            try FileManager.default.removeItem(at: vaultURL)
        }
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/LocalFileVaultStoreTests 2>&1 | tail -40`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add MyPass/Storage/VaultPrimaryStorage.swift MyPass/Storage/LocalFileVaultStore.swift MyPass/Storage/VaultFileStore.swift MyPassTests/LocalFileVaultStoreTests.swift
git commit -m "$(cat <<'EOF'
feat(mypass): add LocalFileVaultStore for bookmarked local vault files

EOF
)"
```

---

### Task 2: Resolver + UserDefaults `localVaultFileBookmark`

**Files:**
- Modify: `MyPass/State/SyncBackendResolver.swift`
- Modify: `MyPass/State/VaultPrimaryStoreResolver.swift`
- Modify: `MyPass/MyPassApp.swift`
- Test: `MyPassTests/VaultPrimaryStoreResolverTests.swift`

**Interfaces:**
- Consumes: `LocalFileVaultStore` (Task 1).
- Produces: `SyncBackendResolver.localVaultFileBookmarkKey == "localVaultFileBookmark"`.
- Produces: `VaultPrimaryStoreResolver.resolvePrimaryStore(vaultLocation:applicationSupportDirectory:iCloudBookmarkData:localVaultFileBookmarkData:makeICloudStore:makeLocalFileStore:) -> Resolution` where `.local` + valid file bookmark → `LocalFileVaultStore`, else Application Support `VaultFileStore`.

- [ ] **Step 1: Write the failing test**

Append to `MyPassTests/VaultPrimaryStoreResolverTests.swift`:

```swift
    func testLocalLocationWithValidFileBookmarkUsesLocalFileVaultStore() throws {
        let vaultFile = applicationSupportDirectory.appendingPathComponent("opened.kdbx")
        try FileManager.default.createDirectory(at: applicationSupportDirectory, withIntermediateDirectories: true)
        try Data("opened".utf8).write(to: vaultFile)
        let bookmark = try LocalFileVaultStore.createFileBookmark(for: vaultFile)
        let expectedStore = try LocalFileVaultStore(bookmarkData: bookmark)

        let resolution = VaultPrimaryStoreResolver.resolvePrimaryStore(
            vaultLocation: .local,
            applicationSupportDirectory: applicationSupportDirectory,
            iCloudBookmarkData: nil,
            localVaultFileBookmarkData: bookmark,
            makeICloudStore: { _ in XCTFail("must not attempt iCloud for .local"); return nil },
            makeLocalFileStore: { data in try? LocalFileVaultStore(bookmarkData: data) }
        )
        XCTAssertTrue(resolution.primaryStore is LocalFileVaultStore)
        XCTAssertFalse(resolution.iCloudFallbackToLocal)
        XCTAssertEqual(
            resolution.primaryStore.primaryVaultFileURL?.path,
            expectedStore.primaryVaultFileURL?.path
        )
    }

    func testLocalLocationWithoutFileBookmarkUsesApplicationSupportVaultFileStore() {
        let resolution = VaultPrimaryStoreResolver.resolvePrimaryStore(
            vaultLocation: .local,
            applicationSupportDirectory: applicationSupportDirectory,
            iCloudBookmarkData: nil,
            localVaultFileBookmarkData: nil,
            makeICloudStore: { _ in XCTFail("must not attempt iCloud for .local"); return nil },
            makeLocalFileStore: { _ in XCTFail("must not attempt file bookmark store without data"); return nil }
        )
        XCTAssertTrue(resolution.primaryStore is VaultFileStore)
        XCTAssertFalse(resolution.primaryStore is LocalFileVaultStore)
        XCTAssertFalse(resolution.iCloudFallbackToLocal)
    }
```

Update existing tests in the same file to pass the new parameters (`localVaultFileBookmarkData: nil`, `makeLocalFileStore: { _ in nil }`).

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/VaultPrimaryStoreResolverTests 2>&1 | tail -40`

Expected: FAIL — extra arguments / missing `localVaultFileBookmarkData`.

- [ ] **Step 3: Implement resolver + key**

`MyPass/State/SyncBackendResolver.swift` — add after `iCloudFolderBookmarkKey`:

```swift
    /// UserDefaults key holding the security-scoped bookmark for a user-opened
    /// `.kdbx` file used as the local primary vault (Open Existing flow).
    static let localVaultFileBookmarkKey = "localVaultFileBookmark"
```

`MyPass/State/VaultPrimaryStoreResolver.swift`:

```swift
    static func resolvePrimaryStore(
        vaultLocation: VaultLocationOption,
        applicationSupportDirectory: URL,
        iCloudBookmarkData: Data?,
        localVaultFileBookmarkData: Data?,
        makeICloudStore: (Data) -> ICloudDriveVaultStore?,
        makeLocalFileStore: (Data) -> LocalFileVaultStore?
    ) -> Resolution {
        switch vaultLocation {
        case .local:
            if let localVaultFileBookmarkData, !localVaultFileBookmarkData.isEmpty,
               let store = makeLocalFileStore(localVaultFileBookmarkData) {
                return Resolution(primaryStore: store, iCloudFallbackToLocal: false)
            }
            return Resolution(
                primaryStore: VaultFileStore(directory: applicationSupportDirectory),
                iCloudFallbackToLocal: false
            )
        case .iCloudDrive:
            // ... existing iCloud branch unchanged ...
        }
    }
```

`MyPass/MyPassApp.swift` — update `resolvePrimaryStore` call:

```swift
        let resolution = VaultPrimaryStoreResolver.resolvePrimaryStore(
            vaultLocation: vaultLocation,
            applicationSupportDirectory: applicationSupportDirectory,
            iCloudBookmarkData: defaults.data(forKey: SyncBackendResolver.iCloudFolderBookmarkKey),
            localVaultFileBookmarkData: defaults.data(forKey: SyncBackendResolver.localVaultFileBookmarkKey),
            makeICloudStore: { bookmarkData in
                try? ICloudDriveVaultStore(
                    bookmarkData: bookmarkData,
                    localBackupDirectory: applicationSupportDirectory.appendingPathComponent("backups")
                )
            },
            makeLocalFileStore: { bookmarkData in
                try? LocalFileVaultStore(bookmarkData: bookmarkData)
            }
        )
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/VaultPrimaryStoreResolverTests 2>&1 | tail -40`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add MyPass/State/SyncBackendResolver.swift MyPass/State/VaultPrimaryStoreResolver.swift MyPass/MyPassApp.swift MyPassTests/VaultPrimaryStoreResolverTests.swift
git commit -m "$(cat <<'EOF'
feat(mypass): resolve LocalFileVaultStore from localVaultFileBookmark

EOF
)"
```

---

### Task 3: Case-insensitive MyPass folder guard

**Files:**
- Create: `MyPass/Storage/VaultICloudFolderSelection.swift`
- Modify: `MyPass/UI/Settings/VaultLocationChangeSheet.swift` (`chooseFolder`)
- Test: `MyPassTests/VaultICloudFolderSelectionTests.swift`

**Interfaces:**
- Produces: `enum VaultICloudFolderSelection { static func resolveVaultFolder(from pickedFolderURL: URL, fileManager: FileManager = .default) throws -> URL }` — returns `pickedFolderURL` when last path component equals `"MyPass"` case-insensitively **or** `vault.kdbx` exists at picked root; otherwise creates/returns `pickedFolderURL/MyPass`.

- [ ] **Step 1: Write the failing test**

`MyPassTests/VaultICloudFolderSelectionTests.swift`:

```swift
import XCTest
@testable import MyPass

final class VaultICloudFolderSelectionTests: XCTestCase {
    var baseDir: URL!

    override func setUpWithError() throws {
        baseDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VaultICloudFolderSelectionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: baseDir)
    }

    func testMyPassCaseInsensitiveNamesUseFolderAsIs() throws {
        for name in ["MyPass", "mypass", "MYPASS"] {
            let folder = baseDir.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let resolved = try VaultICloudFolderSelection.resolveVaultFolder(from: folder)
            XCTAssertEqual(resolved.path, folder.path, "expected no nesting for \(name)")
            try FileManager.default.removeItem(at: folder)
        }
    }

    func testExistingVaultAtPickedRootUsesFolderAsIs() throws {
        let folder = baseDir.appendingPathComponent("CustomSync", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("vault".utf8).write(to: folder.appendingPathComponent("vault.kdbx"))
        let resolved = try VaultICloudFolderSelection.resolveVaultFolder(from: folder)
        XCTAssertEqual(resolved.path, folder.path)
    }

    func testOtherwiseCreatesMyPassSubfolder() throws {
        let folder = baseDir.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let resolved = try VaultICloudFolderSelection.resolveVaultFolder(from: folder)
        XCTAssertEqual(resolved.lastPathComponent, "MyPass")
        XCTAssertTrue(FileManager.default.fileExists(atPath: resolved.path))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/VaultICloudFolderSelectionTests 2>&1 | tail -40`

Expected: FAIL — `VaultICloudFolderSelection` does not exist.

- [ ] **Step 3: Implement pure helper and wire `chooseFolder`**

`MyPass/Storage/VaultICloudFolderSelection.swift`:

```swift
import Foundation

enum VaultICloudFolderSelection {
    static func resolveVaultFolder(from pickedFolderURL: URL, fileManager: FileManager = .default) throws -> URL {
        let alreadyHoldsVault = fileManager.fileExists(
            atPath: pickedFolderURL.appendingPathComponent("vault.kdbx").path
        )
        let isMyPassFolder = pickedFolderURL.lastPathComponent.compare("MyPass", options: .caseInsensitive) == .orderedSame
        if alreadyHoldsVault || isMyPassFolder {
            return pickedFolderURL
        }
        let vaultFolderURL = pickedFolderURL.appendingPathComponent("MyPass", isDirectory: true)
        try fileManager.createDirectory(at: vaultFolderURL, withIntermediateDirectories: true)
        return vaultFolderURL
    }
}
```

In `VaultLocationChangeSheet.chooseFolder()`, replace the inline `alreadyHoldsVault` / `lastPathComponent == "MyPass"` block with:

```swift
            let vaultFolderURL = try VaultICloudFolderSelection.resolveVaultFolder(from: folderURL)
            chosenFolderURL = vaultFolderURL
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/VaultICloudFolderSelectionTests 2>&1 | tail -40`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add MyPass/Storage/VaultICloudFolderSelection.swift MyPass/UI/Settings/VaultLocationChangeSheet.swift MyPassTests/VaultICloudFolderSelectionTests.swift
git commit -m "$(cat <<'EOF'
fix(mypass): case-insensitive MyPass iCloud folder guard

EOF
)"
```

---

### Task 4: Migration move (delete source after verified write)

**Files:**
- Create: `MyPass/Storage/VaultLocationMoveSupport.swift`
- Modify: `MyPass/Storage/ICloudDriveVaultStore.swift` (`primaryVaultFileURL`, `deleteVaultFileIfPresent`)
- Modify: `MyPass/UI/Settings/VaultLocationChangeSheet.swift`
- Test: `MyPassTests/VaultLocationMoveSupportTests.swift`

**Interfaces:**
- Consumes: `VaultPrimaryStorage` delete/URL (Task 1), `KdbxDatabase.open`, `StorageBackend.read()`.
- Produces: `enum VaultLocationMoveSupport { static func verifyDestinationOpens(data: Data, password: String) throws; static func deleteSourceVault(at store: VaultPrimaryStorage) throws -> Bool /* deleted */ }`.
- Produces: `VaultLocationChangeSheet.applyLocationChange(outcome:sourceStore:destinationBackend:password:)` path that verifies destination bytes, deletes source, then swaps — with warning when delete fails.

- [ ] **Step 1: Write the failing test**

`MyPassTests/VaultLocationMoveSupportTests.swift`:

```swift
import XCTest
import MyPassKit
@testable import MyPass

final class VaultLocationMoveSupportTests: XCTestCase {
    let password = "correct-horse"
    var sourceDir: URL!
    var destDir: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("VaultLocationMoveSupportTests-\(UUID().uuidString)")
        sourceDir = base.appendingPathComponent("source")
        destDir = base.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sourceDir.deletingLastPathComponent())
    }

    private func makeDatabase() throws -> KdbxDatabase {
        let now = Date()
        let root = KdbxGroup(
            uuid: UUID(), name: "MyPass", iconID: 0,
            creationTime: now, lastModificationTime: now, locationChanged: now,
            entries: [], subgroups: []
        )
        return KdbxDatabase(rootGroup: root, deletedObjects: [])
    }

    func testVerifyDestinationOpensAcceptsValidKdbxBytes() throws {
        let db = try makeDatabase()
        let data = try db.save(password: password, cipher: .aes256, compression: .gzip)
        XCTAssertNoThrow(try VaultLocationMoveSupport.verifyDestinationOpens(data: data, password: password))
    }

    func testVerifyDestinationOpensRejectsWrongPassword() throws {
        let db = try makeDatabase()
        let data = try db.save(password: password, cipher: .aes256, compression: .gzip)
        XCTAssertThrowsError(try VaultLocationMoveSupport.verifyDestinationOpens(data: data, password: "wrong"))
    }

    func testDeleteSourceVaultRemovesApplicationSupportFile() throws {
        let sourceStore = VaultFileStore(directory: sourceDir)
        let db = try makeDatabase()
        try sourceStore.save(data: try db.save(password: password, cipher: .aes256, compression: .gzip))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceStore.vaultURL.path))

        let deleted = try VaultLocationMoveSupport.deleteSourceVault(at: sourceStore)
        XCTAssertTrue(deleted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceStore.vaultURL.path))
    }

    func testMoveFlowAfterSeedRemoteLeavesSourceAbsent() throws {
        let sourceStore = VaultFileStore(directory: sourceDir)
        let destStore = VaultFileStore(directory: destDir)
        let db = try makeDatabase()
        var entry = KdbxEntry(
            uuid: UUID(), iconID: 0, fields: [],
            creationTime: Date(), lastModificationTime: Date(),
            lastAccessTime: Date(), locationChanged: Date(), history: []
        )
        entry.title = "Only Entry"
        db.rootGroup.entries.append(entry)
        try sourceStore.save(data: try db.save(password: password, cipher: .aes256, compression: .gzip))

        let service = VaultMigrationService(fileStore: sourceStore)
        _ = try service.migrate(local: db, password: password, remote: destStore, strategy: .seedRemote)

        let destData = try XCTUnwrap(try destStore.load())
        try VaultLocationMoveSupport.verifyDestinationOpens(data: destData, password: password)
        _ = try VaultLocationMoveSupport.deleteSourceVault(at: sourceStore)

        XCTAssertNil(try sourceStore.load())
        XCTAssertNotNil(try destStore.load())
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/VaultLocationMoveSupportTests 2>&1 | tail -40`

Expected: FAIL — `VaultLocationMoveSupport` does not exist.

- [ ] **Step 3: Implement move support + sheet integration**

`MyPass/Storage/VaultLocationMoveSupport.swift`:

```swift
import Foundation
import MyPassKit

enum VaultLocationMoveSupport {
    enum Error: Swift.Error {
        case destinationVerifyFailed(underlying: Swift.Error)
    }

    static func verifyDestinationOpens(data: Data, password: String) throws {
        do {
            _ = try KdbxDatabase.open(data: data, password: password)
        } catch {
            throw Error.destinationVerifyFailed(underlying: error)
        }
    }

    @discardableResult
    static func deleteSourceVault(at store: VaultPrimaryStorage) throws -> Bool {
        let url = store.primaryVaultFileURL
        let existed = url.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        try store.deleteVaultFileIfPresent()
        return existed
    }
}
```

`MyPass/Storage/ICloudDriveVaultStore.swift` — add:

```swift
    var primaryVaultFileURL: URL? {
        // Expose via package-visible accessor on iCloudBackend (add `var vaultFileURL: URL { fileURL }` in SyncKit).
        backend.vaultFileURL
    }

    func deleteVaultFileIfPresent() throws {
        try backend.deleteFileIfPresent()
    }
```

In `Packages/SyncKit/Sources/SyncKit/iCloudBackend.swift` add:

```swift
    public var vaultFileURL: URL { fileURL }

    public func deleteFileIfPresent() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let coordinator = NSFileCoordinator(filePresenter: presenter)
        var coordinatorError: NSError?
        var deleteError: Error?
        coordinator.coordinate(writingItemAt: fileURL, options: .forDeleting, error: &coordinatorError) { url in
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                deleteError = error
            }
        }
        if let coordinatorError { throw coordinatorError }
        if let deleteError { throw deleteError }
    }
```

In `VaultLocationChangeSheet`, capture source store before migration and extend `applyLocationChange`:

```swift
    @State private var sourceStoreBeforeMigration: VaultPrimaryStorage?

    private func startMigration() {
        sourceStoreBeforeMigration = nil // VaultSession needs read accessor — add `var currentPrimaryStore: VaultPrimaryStorage { fileStore }` (internal/testable)
        // ... existing probe/migrate ...
    }

    private func applyLocationChange(outcome: VaultMigrationOutcome, destinationBackend: StorageBackend, password: String) {
        guard let destData = try? destinationBackend.read() else {
            errorMessage = "MyPass could not read the vault at the new location. Nothing was changed."
            step = .confirmStrategy
            return
        }
        do {
            try VaultLocationMoveSupport.verifyDestinationOpens(data: destData, password: password)
        } catch {
            errorMessage = "The vault at the new location could not be opened with your password. Nothing was changed."
            step = .confirmStrategy
            return
        }

        var sourceDeleteWarning: String?
        if let sourceStore = sourceStoreBeforeMigration {
            do {
                _ = try VaultLocationMoveSupport.deleteSourceVault(at: sourceStore)
            } catch {
                if let path = sourceStore.primaryVaultFileURL?.path {
                    sourceDeleteWarning = "The vault was moved, but an old copy could not be removed at \(path)."
                } else {
                    sourceDeleteWarning = "The vault was moved, but the previous copy could not be removed."
                }
            }
        }

        // ... existing swap primary + bookmarks (Task 9 extends bookmark clearing) ...
        if let sourceDeleteWarning {
            successMessage = sourceDeleteWarning
        } else {
            successMessage = Self.successMessage(for: outcome)
        }
        step = .finished
    }
```

Add to `VaultSession.swift`:

```swift
    var currentPrimaryStore: VaultPrimaryStorage { fileStore }
```

Set `sourceStoreBeforeMigration = vaultSession.currentPrimaryStore` at the start of `startMigration()`.

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/VaultLocationMoveSupportTests 2>&1 | tail -40`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add MyPass/Storage/VaultLocationMoveSupport.swift MyPass/Storage/ICloudDriveVaultStore.swift Packages/SyncKit/Sources/SyncKit/iCloudBackend.swift MyPass/State/VaultSession.swift MyPass/UI/Settings/VaultLocationChangeSheet.swift MyPassTests/VaultLocationMoveSupportTests.swift
git commit -m "$(cat <<'EOF'
feat(mypass): delete source vault after verified location move

EOF
)"
```

---

### Task 5: Settings path display + Move wording

**Files:**
- Modify: `MyPass/State/VaultSession.swift`
- Modify: `MyPass/UI/Settings/VaultLocationSettingsPane.swift`
- Modify: `MyPass/UI/Settings/VaultLocationChangeSheet.swift` (button/copy strings)
- Test: `MyPassTests/VaultSessionTests.swift` (path display helper)

**Interfaces:**
- Produces: `VaultSession.primaryVaultPathDisplay: String` — resolved absolute path from `fileStore.primaryVaultFileURL?.path`, or `"Path unavailable"` when nil / stale.

- [ ] **Step 1: Write the failing test**

Append to `MyPassTests/VaultSessionTests.swift`:

```swift
    func testPrimaryVaultPathDisplayReturnsVaultURLPath() throws {
        let session = VaultSession(fileStore: fileStore)
        XCTAssertEqual(session.primaryVaultPathDisplay, fileStore.primaryVaultFileURL?.path)
    }

    func testPrimaryVaultPathDisplayUnavailableWhenURLNil() {
        final class NoURLStore: VaultPrimaryStorage {
            var primaryVaultFileURL: URL? { nil }
            func load() throws -> Data? { nil }
            func save(data: Data) throws {}
            func deleteVaultFileIfPresent() throws {}
        }
        let session = VaultSession(fileStore: NoURLStore())
        XCTAssertEqual(session.primaryVaultPathDisplay, "Path unavailable")
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/VaultSessionTests/testPrimaryVaultPathDisplayReturnsVaultURLPath -only-testing:MyPassTests/VaultSessionTests/testPrimaryVaultPathDisplayUnavailableWhenURLNil 2>&1 | tail -40`

Expected: FAIL — `primaryVaultPathDisplay` missing.

- [ ] **Step 3: Implement path display and UI copy**

`VaultSession.swift`:

```swift
    var primaryVaultPathDisplay: String {
        fileStore.primaryVaultFileURL?.path ?? "Path unavailable"
    }
```

`VaultLocationSettingsPane.swift` — inside the Section, after `LabeledContent`:

```swift
                Text(vaultSession.primaryVaultPathDisplay)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
```

Change button labels:

```swift
                Button(currentLocation == .local ? "Move to iCloud Drive…" : "Move to Local…") {
```

`VaultLocationChangeSheet.swift` — update sheet title/footer strings from "Change Vault Location" / "Change Location" to "Move Vault" / "Move Vault" where user-facing (keep internal enum names unchanged).

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/VaultSessionTests/testPrimaryVaultPathDisplayReturnsVaultURLPath -only-testing:MyPassTests/VaultSessionTests/testPrimaryVaultPathDisplayUnavailableWhenURLNil 2>&1 | tail -40`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add MyPass/State/VaultSession.swift MyPass/UI/Settings/VaultLocationSettingsPane.swift MyPass/UI/Settings/VaultLocationChangeSheet.swift MyPassTests/VaultSessionTests.swift
git commit -m "$(cat <<'EOF'
feat(mypass): show primary vault path in Settings, use Move wording

EOF
)"
```

---

### Task 6: Skip-identical-bytes persist

**Files:**
- Modify: `MyPass/State/VaultSession.swift`
- Test: `MyPassTests/VaultSessionTests.swift`

**Interfaces:**
- Produces: `VaultSession` tracks `lastSuccessfullyWrittenBytes: Data?` and `hasDirtyLocalChanges: Bool`.
- Produces: `persist(_:)` skips `fileStore.save` when serialized bytes equal `lastSuccessfullyWrittenBytes`; skips `syncEngine.sync` in the same early-return path.
- Produces: `mutate` / successful persist sets/clears dirty flag; `MyPassApp` timer calls `triggerBackgroundSyncIfDirty()` instead of unconditional sync.

- [ ] **Step 1: Write the failing test**

Append to `MyPassTests/VaultSessionTests.swift`:

```swift
    func testPersistSkipsWriteWhenSerializedBytesUnchanged() throws {
        let spy = CountingVaultPrimaryStorage(inner: fileStore)
        let session = VaultSession(fileStore: spy)
        try session.unlock(password: "correct-horse")

        waitForPersist(on: session)

        let writesAfterUnlock = spy.saveCallCount
        XCTAssertGreaterThan(writesAfterUnlock, 0)

        session.triggerBackgroundSyncIfDirty()
        waitForBackgroundWork()

        XCTAssertEqual(spy.saveCallCount, writesAfterUnlock, "identical bytes should not invoke save again")
    }

    func testPersistWritesWhenDatabaseMutated() throws {
        let spy = CountingVaultPrimaryStorage(inner: fileStore)
        let session = VaultSession(fileStore: spy)
        try session.unlock(password: "correct-horse")
        waitForPersist(on: session)
        let baseline = spy.saveCallCount

        session.mutate { db in
            var entry = KdbxEntry(
                uuid: UUID(), iconID: 0, fields: [],
                creationTime: Date(), lastModificationTime: Date(),
                lastAccessTime: Date(), locationChanged: Date(), history: []
            )
            entry.title = "New"
            db.rootGroup.entries.append(entry)
        }
        waitForPersist(on: session)
        XCTAssertGreaterThan(spy.saveCallCount, baseline)
    }

    private func waitForPersist(on session: VaultSession, file: StaticString = #file, line: UInt = #line) {
        for _ in 0..<50 {
            if session.lastSaveError != nil { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    private func waitForBackgroundWork() {
        Thread.sleep(forTimeInterval: 0.3)
    }
```

Add test double at bottom of `VaultSessionTests.swift`:

```swift
private final class CountingVaultPrimaryStorage: VaultPrimaryStorage {
    let inner: VaultFileStore
    private(set) var saveCallCount = 0

    init(inner: VaultFileStore) { self.inner = inner }

    var primaryVaultFileURL: URL? { inner.primaryVaultFileURL }
    func load() throws -> Data? { try inner.load() }
    func deleteVaultFileIfPresent() throws { try inner.deleteVaultFileIfPresent() }

    func save(data: Data) throws {
        saveCallCount += 1
        try inner.save(data: data)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/VaultSessionTests/testPersistSkipsWriteWhenSerializedBytesUnchanged 2>&1 | tail -40`

Expected: FAIL — save invoked on second trigger / missing `triggerBackgroundSyncIfDirty`.

- [ ] **Step 3: Implement skip-identical persist**

In `VaultSession.swift`:

```swift
    private var lastSuccessfullyWrittenBytes: Data?
    private var hasDirtyLocalChanges = false

    func triggerBackgroundSyncIfDirty() {
        guard hasDirtyLocalChanges else { return }
        triggerBackgroundSync()
    }

    func mutate(_ body: (inout KdbxDatabase) -> Void) {
        guard case .unlocked(var db) = state else { return }
        body(&db)
        state = .unlocked(db)
        hasDirtyLocalChanges = true
        persist(db)
    }

    private func persist(_ db: KdbxDatabase) {
        guard let sessionPassword else { return }
        let snapshot = KdbxDatabase(
            rootGroup: db.rootGroup.deepCopy(),
            deletedObjects: db.deletedObjects,
            recycleBinGroupUUID: db.recycleBinGroupUUID
        )
        persistQueue.async { [fileStore, syncEngine] in
            do {
                let data = try snapshot.save(password: sessionPassword, cipher: .aes256, compression: .gzip)
                if data == self.lastSuccessfullyWrittenBytes {
                    DispatchQueue.main.async { [weak self] in
                        self?.hasDirtyLocalChanges = false
                    }
                    return
                }
                try fileStore.save(data: data)
                self.lastSuccessfullyWrittenBytes = data
                DispatchQueue.main.async { [weak self] in
                    self?.hasDirtyLocalChanges = false
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.lastSaveError = "Failed to save changes: \(error)"
                }
                return
            }
            guard let syncEngine else {
                DispatchQueue.main.async { [weak self] in self?.lastSaveError = nil }
                return
            }
            do {
                _ = try syncEngine.sync(local: snapshot, password: sessionPassword, cipher: .aes256, compression: .gzip)
                DispatchQueue.main.async { [weak self] in self?.lastSaveError = nil }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.lastSaveError = "Local save completed, but sync failed: \(error)"
                }
            }
        }
    }
```

Use a thread-safe box or capture `lastSuccessfullyWrittenBytes` on `persistQueue` only (store as local `var lastBytes` on the queue, mirrored to property with lock if tests need visibility). Simplest: make `lastSuccessfullyWrittenBytes` only read/written on `persistQueue` by using instance variable accessed only from that queue.

In `unlock` / `save(password:)` success paths, seed `lastSuccessfullyWrittenBytes` from loaded/written data.

`MyPassApp.swift` timer:

```swift
            session?.triggerBackgroundSyncIfDirty()
```

`touchAccess` debounced persist already calls `persist`; identical-byte skip covers it.

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/VaultSessionTests/testPersistSkipsWriteWhenSerializedBytesUnchanged -only-testing:MyPassTests/VaultSessionTests/testPersistWritesWhenDatabaseMutated 2>&1 | tail -40`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add MyPass/State/VaultSession.swift MyPass/MyPassApp.swift MyPassTests/VaultSessionTests.swift
git commit -m "$(cat <<'EOF'
fix(mypass): skip primary persist when serialized vault bytes unchanged

EOF
)"
```

---

### Task 7: Remote change LWW reload (no push)

**Files:**
- Modify: `Packages/SyncKit/Sources/SyncKit/iCloudBackend.swift`
- Modify: `MyPass/State/VaultSession.swift`
- Modify: `MyPassTests/VaultSessionTests.swift`

**Interfaces:**
- Produces: `iCloudBackend.readNewestAvailableBytes() throws -> Data?` — coordinated read; when `NSFileVersion.unresolvedConflictVersionsOfItem` non-empty, pick newest modification date (LWW), not entry merge.
- Produces: `VaultSession.reloadPrimaryFromRemoteIfChanged()` — replaces `triggerBackgroundSync()` in `wireRemoteChangeHandler` for `ICloudDriveVaultStore`.
- Produces: on newer remote bytes: open with `sessionPassword`, replace in-memory DB, update `lastSuccessfullyWrittenBytes`; identical bytes: no-op; corrupt/wrong password: set `lastSaveError`, keep DB.

- [ ] **Step 1: Write the failing test**

Append to `MyPassTests/VaultSessionTests.swift`:

```swift
    func testRemoteChangeReloadsWhenBytesDiffer() throws {
        let folder = tempDir.appendingPathComponent("icloud-primary")
        let backups = tempDir.appendingPathComponent("icloud-backups")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let bookmark = try iCloudBackend.createFolderBookmark(for: folder)
        let store = try ICloudDriveVaultStore(bookmarkData: bookmark, localBackupDirectory: backups)
        let session = VaultSession(fileStore: store)
        try session.unlock(password: "correct-horse")

        waitForPersist(on: session)

        let remoteDB = KdbxDatabase(
            rootGroup: KdbxGroup(
                uuid: UUID(), name: "MyPass", iconID: 0,
                creationTime: Date(), lastModificationTime: Date(), locationChanged: Date(),
                entries: [], subgroups: []
            ),
            deletedObjects: []
        )
        var remoteEntry = KdbxEntry(
            uuid: UUID(), iconID: 0, fields: [],
            creationTime: Date(), lastModificationTime: Date(),
            lastAccessTime: Date(), locationChanged: Date(), history: []
        )
        remoteEntry.title = "From Other Mac"
        remoteDB.rootGroup.entries.append(remoteEntry)
        let remoteBytes = try remoteDB.save(password: "correct-horse", cipher: .aes256, compression: .gzip)
        try store.save(data: remoteBytes)

        session.reloadPrimaryFromRemoteIfChanged()

        for _ in 0..<50 {
            if session.currentDatabase?.rootGroup.entries.first?.title == "From Other Mac" { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertEqual(session.currentDatabase?.rootGroup.entries.first?.title, "From Other Mac")
    }

    func testRemoteChangeNoOpsWhenBytesMatch() throws {
        let spy = CountingVaultPrimaryStorage(inner: fileStore)
        let session = VaultSession(fileStore: spy)
        try session.unlock(password: "correct-horse")
        waitForPersist(on: session)
        let baseline = spy.saveCallCount

        session.reloadPrimaryFromRemoteIfChanged()
        waitForBackgroundWork()

        XCTAssertEqual(spy.saveCallCount, baseline)
    }
```

Update `testUpdatePrimaryStoreRewiresOnRemoteChangeForTheNewStore` to call `reloadPrimaryFromRemoteIfChanged` via `onRemoteChange` and assert **no** write when bytes unchanged (invert prior expectation).

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/VaultSessionTests/testRemoteChangeReloadsWhenBytesDiffer 2>&1 | tail -40`

Expected: FAIL — `reloadPrimaryFromRemoteIfChanged` missing or still pushes.

- [ ] **Step 3: Implement LWW reload**

`iCloudBackend.swift`:

```swift
    public func readNewestAvailableBytes() throws -> Data? {
        if try resolveConflictVersionsLWW() {
            return try read()
        }
        return try read()
    }

    @discardableResult
    private func resolveConflictVersionsLWW() throws -> Bool {
        guard let versions = NSFileVersion.unresolvedConflictVersionsOfItem(at: fileURL), !versions.isEmpty else {
            return false
        }
        let current = try read()
        var candidates: [(date: Date, data: Data)] = []
        if let current { candidates.append((try modificationDate() ?? .distantPast, current)) }
        for version in versions {
            guard let data = try? Data(contentsOf: version.url) else { continue }
            candidates.append((version.modificationDate ?? .distantPast, data))
        }
        guard let newest = candidates.max(by: { $0.date < $1.date }) else { return false }
        try write(newest.data)
        for version in versions { version.isResolved = true }
        return true
    }
```

`VaultSession.wireRemoteChangeHandler`:

```swift
        iCloudStore.onRemoteChange = { [weak self] in
            self?.reloadPrimaryFromRemoteIfChanged()
        }
```

`VaultSession.reloadPrimaryFromRemoteIfChanged()`:

```swift
    func reloadPrimaryFromRemoteIfChanged() {
        guard case .unlocked = state, let password = sessionPassword else { return }
        guard let iCloudStore = fileStore as? ICloudDriveVaultStore else { return }
        persistQueue.async { [weak self] in
            guard let self else { return }
            do {
                guard let remoteBytes = try iCloudStore.loadNewestBytes() else { return }
                if remoteBytes == self.lastSuccessfullyWrittenBytes { return }
                let db = try KdbxDatabase.open(data: remoteBytes, password: password)
                DispatchQueue.main.async {
                    self.lastSuccessfullyWrittenBytes = remoteBytes
                    self.hasDirtyLocalChanges = false
                    if case .unlocked = self.state {
                        self.state = .unlocked(db)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.lastSaveError = "Could not reload vault from iCloud: \(error)"
                }
            }
        }
    }
```

Add `ICloudDriveVaultStore.loadNewestBytes() throws -> Data?` forwarding to `backend.readNewestAvailableBytes()`.

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/VaultSessionTests/testRemoteChangeReloadsWhenBytesDiffer -only-testing:MyPassTests/VaultSessionTests/testRemoteChangeNoOpsWhenBytesMatch -only-testing:MyPassTests/VaultSessionTests/testUpdatePrimaryStoreRewiresOnRemoteChangeForTheNewStore 2>&1 | tail -40`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/SyncKit/Sources/SyncKit/iCloudBackend.swift MyPass/Storage/ICloudDriveVaultStore.swift MyPass/State/VaultSession.swift MyPassTests/VaultSessionTests.swift
git commit -m "$(cat <<'EOF'
fix(mypass): LWW reload primary iCloud vault on remote change

EOF
)"
```

---

### Task 8: Open Existing `.kdbx`

**Files:**
- Create: `MyPass/UI/Settings/OpenExistingVaultSheet.swift`
- Modify: `MyPass/State/VaultSession.swift`
- Modify: `MyPass/UI/EntryList/EntryListView.swift`
- Modify: `MyPass/UI/Unlock/UnlockView.swift`
- Test: `MyPassTests/OpenExistingVaultTests.swift`

**Interfaces:**
- Produces: `VaultSession.retargetToOpenExistingVault(fileURL:bookmarkData:password:database:defaults:)` — sets local location, saves `localVaultFileBookmark`, clears `syncICloudFolderBookmark` when leaving iCloud, deletes App Support vault only when previous primary was default `VaultFileStore` without file bookmark, `updatePrimaryStore(LocalFileVaultStore)`, publishes unlocked `database`.
- Produces: `OpenExistingVaultSheet(fileURL:onSuccess:onCancel:)` with `SecureField` password and `NSAlert`-style error `alert`.

- [ ] **Step 1: Write the failing test**

`MyPassTests/OpenExistingVaultTests.swift`:

```swift
import XCTest
import MyPassKit
@testable import MyPass

final class OpenExistingVaultTests: XCTestCase {
    let password = "correct-horse"
    var appSupportDir: URL!
    var externalVaultURL: URL!
    var defaults: UserDefaults!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenExistingVaultTests-\(UUID().uuidString)")
        appSupportDir = base.appendingPathComponent("AppSupport/MyPass")
        externalVaultURL = base.appendingPathComponent("external/legacy.kdbx")
        try FileManager.default.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: externalVaultURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: "OpenExistingVaultTests-\(UUID().uuidString)")!
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: defaults.suiteName!)
        try? FileManager.default.removeItem(at: appSupportDir.deletingLastPathComponent().deletingLastPathComponent())
    }

    private func makeDatabase(title: String) throws -> KdbxDatabase {
        let now = Date()
        var entry = KdbxEntry(
            uuid: UUID(), iconID: 0, fields: [],
            creationTime: now, lastModificationTime: now,
            lastAccessTime: now, locationChanged: now, history: []
        )
        entry.title = title
        let root = KdbxGroup(
            uuid: UUID(), name: "MyPass", iconID: 0,
            creationTime: now, lastModificationTime: now, locationChanged: now,
            entries: [entry], subgroups: []
        )
        return KdbxDatabase(rootGroup: root, deletedObjects: [])
    }

    func testRetargetFromDefaultLocalDeletesAppSupportVault() throws {
        let defaultStore = VaultFileStore(directory: appSupportDir)
        let session = VaultSession(fileStore: defaultStore)
        let oldDB = try makeDatabase(title: "Old")
        try defaultStore.save(data: try oldDB.save(password: password, cipher: .aes256, compression: .gzip))

        let newDB = try makeDatabase(title: "External")
        try Data().write(to: externalVaultURL) // placeholder replaced below
        let newData = try newDB.save(password: password, cipher: .aes256, compression: .gzip)
        try newData.write(to: externalVaultURL)
        let bookmark = try LocalFileVaultStore.createFileBookmark(for: externalVaultURL)

        try session.retargetToOpenExistingVault(
            fileURL: externalVaultURL,
            bookmarkData: bookmark,
            password: password,
            database: newDB,
            defaults: defaults
        )

        XCTAssertEqual(defaults.string(forKey: "vaultLocation"), VaultLocationOption.local.rawValue)
        XCTAssertEqual(defaults.data(forKey: SyncBackendResolver.localVaultFileBookmarkKey), bookmark)
        XCTAssertFalse(FileManager.default.fileExists(atPath: defaultStore.vaultURL.path))
        XCTAssertEqual(session.currentDatabase?.rootGroup.entries.first?.title, "External")
        XCTAssertTrue(session.currentPrimaryStore is LocalFileVaultStore)
    }

    func testRetargetFromICloudDoesNotDeleteICloudFile() throws {
        let icloudFolder = appSupportDir.deletingLastPathComponent().appendingPathComponent("icloud")
        try FileManager.default.createDirectory(at: icloudFolder, withIntermediateDirectories: true)
        let icloudBookmark = try iCloudBackend.createFolderBookmark(for: icloudFolder)
        let icloudStore = try ICloudDriveVaultStore(
            bookmarkData: icloudBookmark,
            localBackupDirectory: appSupportDir.appendingPathComponent("backups")
        )
        defaults.set(VaultLocationOption.iCloudDrive.rawValue, forKey: "vaultLocation")
        defaults.set(icloudBookmark, forKey: SyncBackendResolver.iCloudFolderBookmarkKey)

        let session = VaultSession(fileStore: icloudStore)
        let newDB = try makeDatabase(title: "External")
        let newData = try newDB.save(password: password, cipher: .aes256, compression: .gzip)
        try newData.write(to: externalVaultURL)
        let fileBookmark = try LocalFileVaultStore.createFileBookmark(for: externalVaultURL)

        try session.retargetToOpenExistingVault(
            fileURL: externalVaultURL,
            bookmarkData: fileBookmark,
            password: password,
            database: newDB,
            defaults: defaults
        )

        XCTAssertNil(defaults.data(forKey: SyncBackendResolver.iCloudFolderBookmarkKey))
        XCTAssertNotNil(defaults.data(forKey: SyncBackendResolver.localVaultFileBookmarkKey))
        XCTAssertNotNil(try icloudStore.load())
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/OpenExistingVaultTests 2>&1 | tail -40`

Expected: FAIL — `retargetToOpenExistingVault` missing.

- [ ] **Step 3: Implement session retarget + UI sheet**

`VaultSession.swift`:

```swift
    func retargetToOpenExistingVault(
        fileURL: URL,
        bookmarkData: Data,
        password: String,
        database: KdbxDatabase,
        defaults: UserDefaults = .standard
    ) throws {
        let newStore = try LocalFileVaultStore(bookmarkData: bookmarkData)
        let wasDefaultLocal = fileStore is VaultFileStore
            && defaults.data(forKey: SyncBackendResolver.localVaultFileBookmarkKey) == nil
            && defaults.string(forKey: "vaultLocation") == VaultLocationOption.local.rawValue

        updatePrimaryStore(newStore)
        defaults.set(VaultLocationOption.local.rawValue, forKey: "vaultLocation")
        defaults.set(bookmarkData, forKey: SyncBackendResolver.localVaultFileBookmarkKey)
        defaults.removeObject(forKey: SyncBackendResolver.iCloudFolderBookmarkKey)

        if wasDefaultLocal {
            try VaultFileStore(directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("MyPass")).deleteVaultFileIfPresent()
        }

        state = .unlocked(database)
        sessionPassword = password
        lastSuccessfullyWrittenBytes = try database.save(password: password, cipher: .aes256, compression: .gzip)
        hasDirtyLocalChanges = false
    }
```

`OpenExistingVaultSheet.swift` — small sheet with `SecureField("Master Password")`, Continue/Cancel, `@State errorMessage`, calls `KdbxDatabase.open` before retarget; on failure sets alert text (not beep).

`EntryListView.openExistingVault()` — after panel OK, set `@State selectedOpenExistingURL` and present sheet.

`UnlockView` — add `Button("Open Existing .kdbx…")` below unlock form presenting same sheet (when locked).

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/OpenExistingVaultTests 2>&1 | tail -40`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add MyPass/State/VaultSession.swift MyPass/UI/Settings/OpenExistingVaultSheet.swift MyPass/UI/EntryList/EntryListView.swift MyPass/UI/Unlock/UnlockView.swift MyPassTests/OpenExistingVaultTests.swift
git commit -m "$(cat <<'EOF'
feat(mypass): implement Open Existing kdbx with password prompt

EOF
)"
```

---

### Task 9: Move bookmark bookkeeping on location change

**Files:**
- Modify: `MyPass/UI/Settings/VaultLocationChangeSheet.swift`
- Modify: `MyPassTests/VaultPrimaryStoreResolverTests.swift` (bookmark key constants if needed)
- Test: extend `MyPassTests/VaultLocationMoveSupportTests.swift` or add `MyPassTests/VaultLocationChangeBookmarkTests.swift`

**Interfaces:**
- Consumes: Task 4 move flow, Task 2 bookmark keys.
- Produces: `applyLocationChange` bookmark rules:
  - **local → iCloud:** set `syncICloudFolderBookmark`, clear `localVaultFileBookmark`.
  - **iCloud → local:** clear `syncICloudFolderBookmark`; primary becomes Application Support `VaultFileStore` (unless moving from bookmarked local file — Task 4 delete handles file).
  - **Open Existing from iCloud:** covered in Task 8.

- [ ] **Step 1: Write the failing test**

`MyPassTests/VaultLocationChangeBookmarkTests.swift`:

```swift
import XCTest
@testable import MyPass

final class VaultLocationChangeBookmarkTests: XCTestCase {
    func testBookmarkMutationsWhenMovingLocalToICloud() {
        var localBookmark: Data? = Data("local-file-bookmark".utf8)
        var iCloudBookmark: Data? = nil
        VaultLocationChangeSheet.applyBookmarkChanges(
            targetLocation: .iCloudDrive,
            chosenICloudFolderBookmark: Data("icloud-folder".utf8),
            localVaultFileBookmark: &localBookmark,
            iCloudFolderBookmark: &iCloudBookmark
        )
        XCTAssertNil(localBookmark)
        XCTAssertEqual(iCloudBookmark, Data("icloud-folder".utf8))
    }

    func testBookmarkMutationsWhenMovingICloudToLocal() {
        var localBookmark: Data? = nil
        var iCloudBookmark: Data? = Data("icloud-folder".utf8)
        VaultLocationChangeSheet.applyBookmarkChanges(
            targetLocation: .local,
            chosenICloudFolderBookmark: nil,
            localVaultFileBookmark: &localBookmark,
            iCloudFolderBookmark: &iCloudBookmark
        )
        XCTAssertNil(iCloudBookmark)
        XCTAssertNil(localBookmark)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/VaultLocationChangeBookmarkTests 2>&1 | tail -40`

Expected: FAIL — `applyBookmarkChanges` missing.

- [ ] **Step 3: Extract bookmark helper and wire sheet**

In `VaultLocationChangeSheet.swift`:

```swift
    static func applyBookmarkChanges(
        targetLocation: VaultLocationOption,
        chosenICloudFolderBookmark: Data?,
        localVaultFileBookmark: inout Data?,
        iCloudFolderBookmark: inout Data?
    ) {
        switch targetLocation {
        case .iCloudDrive:
            iCloudFolderBookmark = chosenICloudFolderBookmark
            localVaultFileBookmark = nil
        case .local:
            iCloudFolderBookmark = nil
            localVaultFileBookmark = nil
        }
    }
```

In `applyLocationChange`, after successful verify/delete, before `updatePrimaryStore`:

```swift
        @AppStorage(SyncBackendResolver.localVaultFileBookmarkKey) var localVaultFileBookmarkData: Data?
        applyBookmarkChanges(
            targetLocation: targetLocation,
            chosenICloudFolderBookmark: chosenFolderBookmark,
            localVaultFileBookmark: &localVaultFileBookmarkData,
            iCloudFolderBookmark: &syncICloudFolderBookmarkData
        )
```

When target is `.local`, construct `VaultFileStore(directory: applicationSupportDirectory)` (not `LocalFileVaultStore`) unless Open Existing — move from bookmarked local deletes file in Task 4.

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/VaultLocationChangeBookmarkTests 2>&1 | tail -40`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add MyPass/UI/Settings/VaultLocationChangeSheet.swift MyPassTests/VaultLocationChangeBookmarkTests.swift
git commit -m "$(cat <<'EOF'
fix(mypass): clear/set vault location bookmarks on move

EOF
)"
```

---

## Self-Review

### Spec coverage checklist

| Spec requirement | Task |
|------------------|------|
| Move not copy; delete source after verified write | Task 4 |
| Delete fail still swaps with warning | Task 4 |
| Failure before verify leaves source untouched | Task 4 |
| Settings shows resolved absolute path | Task 5 |
| Path unavailable when stale | Task 5 |
| Case-insensitive MyPass folder guard | Task 3 |
| `vault.kdbx` at picked root used as-is | Task 3 |
| `LocalFileVaultStore` + `localVaultFileBookmark` | Task 1, Task 2 |
| Resolver: local + bookmark → LocalFileVaultStore | Task 2 |
| Open Existing: password, bookmark, retarget, load entries | Task 8 |
| Open Existing: delete App Support only for default local | Task 8 |
| Open Existing: clear iCloud bookmark when leaving iCloud | Task 8, Task 9 |
| Skip write when identical serialized bytes | Task 6 |
| Secondary sync skipped when primary write skipped | Task 6 |
| Remote change: reload LWW, no push | Task 7 |
| Timer only when dirty | Task 6 |
| NSFileVersion newest on conflict (primary) | Task 7 |
| touchAccess debounce + skip identical | Task 6 |
| Move UI wording | Task 5 |
| Bookmark bookkeeping local↔iCloud | Task 9 |
| Do not rename `syncICloudFolderBookmark` | Global Constraints; Task 2/9 |
| relativePath `vault.kdbx` | Global Constraints; unchanged |
| Wrong password/corrupt remote reload: no wipe | Task 7 |
| Secondary SyncEngine unchanged (except no forced rewrite on skip) | Task 6 |

### Intentional deviations from suggested split

- **Task 4 vs migration service:** Source deletion stays in `VaultLocationChangeSheet` + `VaultLocationMoveSupport` rather than inside `VaultMigrationService.uploadLocal`, because migration already treats remote as target and must remain usable for secondary connect flows; move-delete is location-change-specific.
- **Task 5 vs Task 1:** Protocol path/delete methods start in Task 1 (`LocalFileVaultStore` + `VaultFileStore`); iCloud conformances land in Task 4 when delete is needed.
- **Task 7 SyncKit change:** `readNewestAvailableBytes` lives in `iCloudBackend` rather than only in `ICloudDriveVaultStore` so coordinated conflict resolution stays with existing `NSFileCoordinator` code.
- **`VaultMigrationServiceTests`:** Existing `testSeedRemoteUploadsLocalVaultAndLeavesLocalFileUntouched` remains valid for the service in isolation; move-delete coverage is in `VaultLocationMoveSupportTests` (integration-style).

---

**Plan complete and saved to `docs/superpowers/plans/2026-07-31-vault-location-move-sync-open.md`. Two execution options:**

**1. Subagent-Driven (recommended)** — dispatch a fresh subagent per task, review between tasks, fast iteration

**2. Inline Execution** — execute tasks in this session using executing-plans, batch execution with checkpoints

**Which approach?**
