# Unified Vault Location Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the hardcoded Application-Support-only vault storage plus optional sync-mirror system with a single configurable `VaultLocation` (Local or iCloud Drive), reachable from Settings before authentication, with Custom Folder and SFTP demoted to an optional secondary destination.

**Architecture:** A new `VaultPrimaryStorage` protocol abstracts "where the vault file lives" so `VaultSession` can hold either `VaultFileStore` (Application Support) or a new `ICloudDriveVaultStore` (iCloud Drive folder) interchangeably and swap between them at runtime. Custom Folder and SFTP move to an orthogonal `SecondaryDestinationOption` picker reusing the existing `SyncEngine`/`LocalFolderBackend`/`SFTPBackend` machinery unchanged. Changing the primary location reuses `VaultMigrationService`'s existing probe/strategy logic, gated by a new non-mutating `VaultSession.verifyPassword` check that doubles as the "authorize this change" step.

**Tech Stack:** Swift, SwiftUI (macOS), XCTest, existing `SyncKit` package (`StorageBackend`, `iCloudBackend`, `LocalFolderBackend`, `SyncEngine`).

## Global Constraints

- English everywhere (code, comments, docs, UI, commits) — per root `CLAUDE.md`.
- No new entitlements: iCloud Drive access stays via user-granted security-scoped bookmark (`com.apple.security.files.user-selected.read-write` + `.files.bookmarks.app-scope`, already present in `MyPass.entitlements`). No ubiquity-container entitlement is added.
- Never rename or remove the persisted UserDefaults key `"syncICloudFolderBookmark"` (pinned by `testICloudFolderBookmarkKeyIsPinned` in `MyPassTests/SettingsViewSyncBackendTests.swift`) — it keeps being the iCloud Drive folder bookmark, now for the primary location instead of a mirror.
- Existing installs must keep working unchanged on next launch with zero data loss: an install with a pre-existing `vault.kdbx` in Application Support and/or a configured legacy `syncBackend` value must resolve to the equivalent new configuration automatically (see Task 4/5), never to a blank first-run wizard.
- UI copy must never use the word "Backup"/"Backups" for the new Custom-Folder/SFTP secondary destination — `BackupsSettingsPane` already owns that word for local snapshot rotation (`backupCount`). Use "Secondary" / "also sync to" phrasing instead.
- Custom Folder and SFTP are secondary-only, never primary; primary `VaultLocation` has exactly two cases: Local and iCloud Drive. Only one secondary destination is active at a time (None / Folder / SFTP picker, not simultaneous toggles).

---

### Task 1: `VaultPrimaryStorage` protocol + `VaultFileStore` conformance

**Files:**
- Create: `MyPass/Storage/VaultPrimaryStorage.swift`
- Modify: `MyPass/Storage/VaultFileStore.swift`
- Test: `MyPassTests/VaultFileStoreTests.swift`

**Interfaces:**
- Produces: `protocol VaultPrimaryStorage { func load() throws -> Data?; func save(data: Data) throws }`. `VaultFileStore` conforms to both `VaultPrimaryStorage` (via its existing `load()`/`save(data:)`) and `SyncKit.StorageBackend` (via new thin wrapper methods `read()`/`write(_:)`/`exists()`/`modificationDate()`). Every later task that needs "the primary store" or "a `StorageBackend` for Local" depends on this.

- [ ] **Step 1: Write the failing tests**

Add to `MyPassTests/VaultFileStoreTests.swift` (open the file first to see its existing `setUp`/`tempDir` pattern and match it):

```swift
func testConformsToVaultPrimaryStorageViaLoadAndSave() throws {
    let store: VaultPrimaryStorage = VaultFileStore(directory: tempDir)
    XCTAssertNil(try store.load())
    try store.save(data: Data("primary-storage-round-trip".utf8))
    XCTAssertEqual(try store.load(), Data("primary-storage-round-trip".utf8))
}

func testConformsToStorageBackendViaReadAndWrite() throws {
    let store: StorageBackend = VaultFileStore(directory: tempDir)
    XCTAssertFalse(try store.exists())
    XCTAssertNil(try store.modificationDate())
    try store.write(Data("storage-backend-round-trip".utf8))
    XCTAssertTrue(try store.exists())
    XCTAssertEqual(try store.read(), Data("storage-backend-round-trip".utf8))
    XCTAssertNotNil(try store.modificationDate())
}
```

Make sure `import SyncKit` is present at the top of `VaultFileStoreTests.swift` (add it if missing — `StorageBackend` is defined there).

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/VaultFileStoreTests 2>&1 | tail -40`
Expected: FAIL — `VaultFileStore` does not conform to `VaultPrimaryStorage` / `StorageBackend` yet (compile error).

- [ ] **Step 3: Create the protocol**

`MyPass/Storage/VaultPrimaryStorage.swift`:

```swift
import Foundation

/// Abstracts "where the vault file currently lives" so `VaultSession` can hold
/// either `VaultFileStore` (Application Support) or `ICloudDriveVaultStore`
/// (a user-granted iCloud Drive folder) interchangeably, and swap between them
/// at runtime when the user changes the configured vault location.
protocol VaultPrimaryStorage {
    func load() throws -> Data?
    func save(data: Data) throws
}
```

- [ ] **Step 4: Conform `VaultFileStore` to both protocols**

Append to `MyPass/Storage/VaultFileStore.swift` (add `import SyncKit` at the top of the file):

```swift
extension VaultFileStore: VaultPrimaryStorage {}

extension VaultFileStore: StorageBackend {
    func read() throws -> Data? { try load() }
    func write(_ data: Data) throws { try save(data: data) }

    func exists() throws -> Bool {
        FileManager.default.fileExists(atPath: vaultURL.path)
    }

    func modificationDate() throws -> Date? {
        guard FileManager.default.fileExists(atPath: vaultURL.path) else { return nil }
        return try vaultURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/VaultFileStoreTests 2>&1 | tail -40`
Expected: PASS (all `VaultFileStoreTests` cases, old and new).

- [ ] **Step 6: Commit**

```bash
git add MyPass/Storage/VaultPrimaryStorage.swift MyPass/Storage/VaultFileStore.swift MyPassTests/VaultFileStoreTests.swift
git commit -m "feat(mypass): add VaultPrimaryStorage protocol, conform VaultFileStore to it and StorageBackend"
```

---

### Task 2: `ICloudDriveVaultStore`

**Files:**
- Create: `MyPass/Storage/ICloudDriveVaultStore.swift`
- Test: `MyPassTests/ICloudDriveVaultStoreTests.swift`

**Interfaces:**
- Consumes: `VaultPrimaryStorage` (Task 1), `SyncKit.iCloudBackend`, `iCloudRoot.userFolder(bookmark:)`.
- Produces: `final class ICloudDriveVaultStore: VaultPrimaryStorage` with `init(bookmarkData: Data, relativePath: String = "vault.kdbx", localBackupDirectory: URL, backupCount: Int = 10) throws`, a passthrough `var onRemoteChange: (() -> Void)?`, and `load()`/`save(data:)`. Later tasks (5, 6, 7) construct this when the resolved primary location is iCloud Drive.

- [ ] **Step 1: Write the failing test**

`MyPassTests/ICloudDriveVaultStoreTests.swift`:

```swift
import XCTest
import SyncKit
@testable import MyPass

final class ICloudDriveVaultStoreTests: XCTestCase {
    var folderDir: URL!
    var backupDir: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("ICloudDriveVaultStoreTests-\(UUID().uuidString)")
        folderDir = base.appendingPathComponent("folder")
        backupDir = base.appendingPathComponent("backups")
        try FileManager.default.createDirectory(at: folderDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folderDir.deletingLastPathComponent())
    }

    func testLoadReturnsNilBeforeAnyWrite() throws {
        let bookmark = try iCloudBackend.createFolderBookmark(for: folderDir)
        let store = try ICloudDriveVaultStore(bookmarkData: bookmark, localBackupDirectory: backupDir)
        XCTAssertNil(try store.load())
    }

    func testSaveThenLoadRoundTrips() throws {
        let bookmark = try iCloudBackend.createFolderBookmark(for: folderDir)
        let store = try ICloudDriveVaultStore(bookmarkData: bookmark, localBackupDirectory: backupDir)
        try store.save(data: Data("icloud-primary-round-trip".utf8))
        XCTAssertEqual(try store.load(), Data("icloud-primary-round-trip".utf8))
    }

    func testSecondSaveRotatesPreviousContentIntoLocalBackupDirectory() throws {
        let bookmark = try iCloudBackend.createFolderBookmark(for: folderDir)
        let store = try ICloudDriveVaultStore(bookmarkData: bookmark, localBackupDirectory: backupDir)
        try store.save(data: Data("first-version".utf8))
        try store.save(data: Data("second-version".utf8))

        let backedUpFiles = try FileManager.default.contentsOfDirectory(at: backupDir, includingPropertiesForKeys: nil)
        XCTAssertEqual(backedUpFiles.count, 1)
        let backedUpData = try Data(contentsOf: backedUpFiles[0])
        XCTAssertEqual(backedUpData, Data("first-version".utf8))
        XCTAssertEqual(try store.load(), Data("second-version".utf8))
    }

    func testRotatesOldestBackupsBeyondBackupCount() throws {
        let bookmark = try iCloudBackend.createFolderBookmark(for: folderDir)
        let store = try ICloudDriveVaultStore(bookmarkData: bookmark, localBackupDirectory: backupDir, backupCount: 2)
        try store.save(data: Data("v1".utf8))
        try store.save(data: Data("v2".utf8))
        try store.save(data: Data("v3".utf8))
        try store.save(data: Data("v4".utf8))

        let backedUpFiles = try FileManager.default.contentsOfDirectory(at: backupDir, includingPropertiesForKeys: nil)
        XCTAssertEqual(backedUpFiles.count, 2)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/ICloudDriveVaultStoreTests 2>&1 | tail -40`
Expected: FAIL — `ICloudDriveVaultStore` does not exist.

- [ ] **Step 3: Implement `ICloudDriveVaultStore`**

`MyPass/Storage/ICloudDriveVaultStore.swift`:

```swift
import Foundation
import SyncKit

/// The vault's primary storage when the configured `VaultLocation` is iCloud
/// Drive: wraps `iCloudBackend` (which already handles `NSFileCoordinator`,
/// download materialisation, and conflict-version resolution) and adds the
/// same local snapshot-backup rotation `VaultFileStore` does, so
/// `BackupsSettingsPane`'s "keep last N" setting behaves identically
/// regardless of which primary location is active.
final class ICloudDriveVaultStore: VaultPrimaryStorage {
    private let backend: iCloudBackend
    private let localBackupDirectory: URL
    private let backupCount: Int

    init(
        bookmarkData: Data,
        relativePath: String = "vault.kdbx",
        localBackupDirectory: URL,
        backupCount: Int = 10
    ) throws {
        self.backend = try iCloudBackend(root: .userFolder(bookmark: bookmarkData), relativePath: relativePath)
        self.localBackupDirectory = localBackupDirectory
        self.backupCount = backupCount
    }

    /// Fires when another device/process changes the iCloud Drive file while
    /// this store is alive. Forwarded from the underlying `iCloudBackend`.
    var onRemoteChange: (() -> Void)? {
        get { backend.onRemoteChange }
        set { backend.onRemoteChange = newValue }
    }

    func load() throws -> Data? {
        try backend.read()
    }

    func save(data: Data) throws {
        try backupCurrentContentIfPresent()
        try backend.write(data)
    }

    private func backupCurrentContentIfPresent() throws {
        guard let existingData = try backend.read() else { return }
        try FileManager.default.createDirectory(at: localBackupDirectory, withIntermediateDirectories: true)
        let timestamp = String(format: "%.6f", Date().timeIntervalSince1970)
        let backupURL = localBackupDirectory.appendingPathComponent("vault-\(timestamp).kdbx")
        try existingData.write(to: backupURL, options: .atomic)
        try rotateBackups()
    }

    private func rotateBackups() throws {
        let fm = FileManager.default
        let entries = try fm.contentsOfDirectory(at: localBackupDirectory, includingPropertiesForKeys: [.creationDateKey])
        let sorted = try entries.sorted { lhs, rhs in
            let l = try lhs.resourceValues(forKeys: [.creationDateKey]).creationDate ?? .distantPast
            let r = try rhs.resourceValues(forKeys: [.creationDateKey]).creationDate ?? .distantPast
            return l < r
        }
        guard sorted.count > backupCount else { return }
        for url in sorted.prefix(sorted.count - backupCount) {
            try fm.removeItem(at: url)
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/ICloudDriveVaultStoreTests 2>&1 | tail -40`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add MyPass/Storage/ICloudDriveVaultStore.swift MyPassTests/ICloudDriveVaultStoreTests.swift
git commit -m "feat(mypass): add ICloudDriveVaultStore as an iCloud-backed VaultPrimaryStorage"
```

---

### Task 3: `VaultSession` swappable primary store + `verifyPassword`

**Files:**
- Modify: `MyPass/State/VaultSession.swift`
- Modify: `MyPass/Storage/VaultMigrationService.swift`
- Test: `MyPassTests/VaultSessionTests.swift`

**Interfaces:**
- Consumes: `VaultPrimaryStorage` (Task 1).
- Produces: `VaultSession.init(fileStore: VaultPrimaryStorage, syncEngine: SyncEngine? = nil)`, `func updatePrimaryStore(_ newStore: VaultPrimaryStorage)`, `func verifyPassword(_ password: String) -> Bool`. `VaultMigrationService.init(fileStore: VaultPrimaryStorage, cipher:, compression:)`. Task 6 depends on `verifyPassword` and `updatePrimaryStore`; Task 5 depends on the widened `init` parameter type.

- [ ] **Step 1: Write the failing tests**

Add to `MyPassTests/VaultSessionTests.swift` (match its existing `setUp`/`tempDir`/password conventions — open the file first):

```swift
func testVerifyPasswordReturnsTrueForCorrectPasswordWithoutMutatingState() throws {
    let session = VaultSession(fileStore: VaultFileStore(directory: tempDir))
    try session.unlock(password: "correct-horse")
    session.lock()

    XCTAssertTrue(session.verifyPassword("correct-horse"))
    XCTAssertEqual(session.state, .locked)
}

func testVerifyPasswordReturnsFalseForWrongPassword() throws {
    let session = VaultSession(fileStore: VaultFileStore(directory: tempDir))
    try session.unlock(password: "correct-horse")
    session.lock()

    XCTAssertFalse(session.verifyPassword("wrong-password"))
}

func testVerifyPasswordReturnsFalseWhenNoVaultExistsYet() {
    let session = VaultSession(fileStore: VaultFileStore(directory: tempDir))
    XCTAssertFalse(session.verifyPassword("anything"))
}

func testUpdatePrimaryStoreSwapsWhereSubsequentUnlockReadsFrom() throws {
    let firstDir = tempDir.appendingPathComponent("first")
    let secondDir = tempDir.appendingPathComponent("second")
    try FileManager.default.createDirectory(at: firstDir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: secondDir, withIntermediateDirectories: true)

    let session = VaultSession(fileStore: VaultFileStore(directory: firstDir))
    try session.unlock(password: "pw") // creates a fresh vault under firstDir
    session.lock()

    session.updatePrimaryStore(VaultFileStore(directory: secondDir))

    // secondDir has no vault yet, so unlocking now creates a brand new one there.
    XCTAssertNil(try session.loadVaultData())
    try session.unlock(password: "different-pw")
    XCTAssertNotNil(session.currentDatabase)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/VaultSessionTests 2>&1 | tail -40`
Expected: FAIL — `verifyPassword`/`updatePrimaryStore` do not exist yet.

- [ ] **Step 3: Update `VaultSession`**

In `MyPass/State/VaultSession.swift`, change the stored property and initializer:

```swift
private var fileStore: VaultPrimaryStorage
```

```swift
init(fileStore: VaultPrimaryStorage, syncEngine: SyncEngine? = nil) {
    self.fileStore = fileStore
    self.syncEngine = syncEngine
}
```

Add these two new methods (near `lock()`):

```swift
/// Swaps the primary store the session reads/writes from — used when the
/// user changes the configured vault location. Callers are responsible for
/// having already migrated any existing data to the new store (see
/// `VaultLocationChangeSheet`); this method only changes where subsequent
/// `unlock`/`persist` calls point.
func updatePrimaryStore(_ newStore: VaultPrimaryStorage) {
    fileStore = newStore
}

/// Checks `password` against the vault currently on disk at `fileStore`,
/// without mutating `state` or `sessionPassword` — used to gate a settings
/// change (e.g. changing the vault location) behind proof of ownership
/// without disturbing an in-progress unlocked session or its unsaved edits.
/// Returns `false` (never throws) for a wrong password, a corrupt file, or
/// when no vault exists yet at the current location.
func verifyPassword(_ password: String) -> Bool {
    guard let data = (try? fileStore.load()) ?? nil else { return false }
    return (try? KdbxDatabase.open(data: data, password: password)) != nil
}
```

- [ ] **Step 4: Update `VaultMigrationService`'s stored type**

In `MyPass/Storage/VaultMigrationService.swift`, change:

```swift
private let fileStore: VaultFileStore
```
to
```swift
private let fileStore: VaultPrimaryStorage
```
and change the initializer parameter type to match:
```swift
init(fileStore: VaultPrimaryStorage, cipher: KdbxCipher = .aes256, compression: KdbxCompression = .gzip) {
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/VaultSessionTests -only-testing:MyPassTests/VaultMigrationServiceTests 2>&1 | tail -60`
Expected: PASS for all `VaultSessionTests` and `VaultMigrationServiceTests` cases (the latter should compile and pass unchanged — `VaultFileStore` still conforms to the new parameter type).

- [ ] **Step 6: Commit**

```bash
git add MyPass/State/VaultSession.swift MyPass/Storage/VaultMigrationService.swift MyPassTests/VaultSessionTests.swift
git commit -m "feat(mypass): make VaultSession's primary store swappable, add verifyPassword"
```

---

### Task 4: `VaultLocationOption`, `SecondaryDestinationOption`, `VaultLocationResolver`

**Files:**
- Create: `MyPass/UI/Settings/VaultLocationOption.swift`
- Create: `MyPass/UI/Settings/SecondaryDestinationOption.swift`
- Create: `MyPass/State/VaultLocationResolver.swift`
- Modify: `MyPass/State/SyncBackendResolver.swift`
- Test: `MyPassTests/VaultLocationResolverTests.swift`
- Test: `MyPassTests/SettingsViewSyncBackendTests.swift`

**Interfaces:**
- Produces: `enum VaultLocationOption: String, CaseIterable, Identifiable { case local = "Local File", iCloudDrive = "iCloud Drive" }`; `enum SecondaryDestinationOption: String, CaseIterable, Identifiable { case none = "None", folder = "Folder", sftp = "SFTP" }`; `VaultLocationResolver.migrateLegacyBackendIfNeeded(legacySyncBackendRawValue:legacyLocalFolderBookmark:) -> VaultLocationResolver.LegacyMigrationResult?`; `VaultLocationResolver.resolveVaultLocation(rawValue:) -> VaultLocationOption`; `VaultLocationResolver.shouldShowFirstRunWizard(vaultLocationRawValue:legacySyncBackendRawValue:applicationSupportVaultExists:) -> Bool`; `SyncBackendResolver.checkpointKey(for: SecondaryDestinationOption) -> String` and `SyncBackendResolver.clearCheckpoint(for: SecondaryDestinationOption, defaults:)` (retargeted from the old `SyncBackendOption` parameter — done here, in the same task that introduces `SecondaryDestinationOption`, so every later task that reads/clears a checkpoint already sees the final signature and the app keeps compiling after every task). Task 5 (app launch wiring), Task 6 (location-change sheet), Task 7 (first-run wizard), and Task 8 (secondary pane) all depend on these types.

- [ ] **Step 1: Write the failing tests**

`MyPassTests/VaultLocationResolverTests.swift`:

```swift
import XCTest
@testable import MyPass

final class VaultLocationResolverTests: XCTestCase {
    func testResolveVaultLocationDefaultsToLocalForNilOrUnknown() {
        XCTAssertEqual(VaultLocationResolver.resolveVaultLocation(rawValue: nil), .local)
        XCTAssertEqual(VaultLocationResolver.resolveVaultLocation(rawValue: "garbage"), .local)
        XCTAssertEqual(VaultLocationResolver.resolveVaultLocation(rawValue: "iCloud Drive"), .iCloudDrive)
    }

    func testShouldShowFirstRunWizardOnlyForTrulyFreshInstall() {
        XCTAssertTrue(VaultLocationResolver.shouldShowFirstRunWizard(
            vaultLocationRawValue: nil, legacySyncBackendRawValue: nil, applicationSupportVaultExists: false
        ))
        XCTAssertFalse(VaultLocationResolver.shouldShowFirstRunWizard(
            vaultLocationRawValue: "Local File", legacySyncBackendRawValue: nil, applicationSupportVaultExists: false
        ))
        XCTAssertFalse(VaultLocationResolver.shouldShowFirstRunWizard(
            vaultLocationRawValue: nil, legacySyncBackendRawValue: "iCloud Drive", applicationSupportVaultExists: false
        ))
        XCTAssertFalse(VaultLocationResolver.shouldShowFirstRunWizard(
            vaultLocationRawValue: nil, legacySyncBackendRawValue: nil, applicationSupportVaultExists: true
        ))
    }

    func testMigrateLegacyBackendReturnsNilWhenNothingLegacyIsConfigured() {
        XCTAssertNil(VaultLocationResolver.migrateLegacyBackendIfNeeded(
            legacySyncBackendRawValue: nil, legacyLocalFolderBookmark: nil
        ))
    }

    func testMigrateLegacyICloudBackendPromotesToDrivePrimary() throws {
        let result = try XCTUnwrap(VaultLocationResolver.migrateLegacyBackendIfNeeded(
            legacySyncBackendRawValue: "iCloud Drive", legacyLocalFolderBookmark: nil
        ))
        XCTAssertEqual(result.vaultLocation, .iCloudDrive)
        XCTAssertNil(result.secondaryDestination)
        XCTAssertNil(result.secondaryFolderBookmark)
    }

    func testMigrateLegacyLocalFolderBackendBecomesFolderSecondary() throws {
        let bookmark = Data("fake-bookmark".utf8)
        let result = try XCTUnwrap(VaultLocationResolver.migrateLegacyBackendIfNeeded(
            legacySyncBackendRawValue: "Local File", legacyLocalFolderBookmark: bookmark
        ))
        XCTAssertEqual(result.vaultLocation, .local)
        XCTAssertEqual(result.secondaryDestination, .folder)
        XCTAssertEqual(result.secondaryFolderBookmark, bookmark)
    }

    func testMigrateLegacySFTPBackendBecomesSFTPSecondary() throws {
        let result = try XCTUnwrap(VaultLocationResolver.migrateLegacyBackendIfNeeded(
            legacySyncBackendRawValue: "SFTP", legacyLocalFolderBookmark: nil
        ))
        XCTAssertEqual(result.vaultLocation, .local)
        XCTAssertEqual(result.secondaryDestination, .sftp)
        XCTAssertNil(result.secondaryFolderBookmark)
    }

    func testMigrateUnrecognizedLegacyValueFallsBackToLocalWithNoSecondary() throws {
        let result = try XCTUnwrap(VaultLocationResolver.migrateLegacyBackendIfNeeded(
            legacySyncBackendRawValue: "something-unexpected", legacyLocalFolderBookmark: nil
        ))
        XCTAssertEqual(result.vaultLocation, .local)
        XCTAssertNil(result.secondaryDestination)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/VaultLocationResolverTests 2>&1 | tail -40`
Expected: FAIL — none of the new types exist.

- [ ] **Step 3: Create the two option enums**

`MyPass/UI/Settings/VaultLocationOption.swift`:

```swift
/// Where the vault file itself lives — the single primary copy, not a
/// mirror. Custom Folder and SFTP are never primary; see
/// `SecondaryDestinationOption`.
enum VaultLocationOption: String, CaseIterable, Identifiable {
    case local = "Local File"
    case iCloudDrive = "iCloud Drive"

    var id: String { rawValue }
}
```

`MyPass/UI/Settings/SecondaryDestinationOption.swift`:

```swift
/// An optional additional copy the vault is synced to on top of whichever
/// `VaultLocationOption` is primary. Unlike the primary location, this is
/// inherently a second copy that needs reconciliation — reuses the existing
/// `SyncEngine` push/pull/merge machinery unchanged.
enum SecondaryDestinationOption: String, CaseIterable, Identifiable {
    case none = "None"
    case folder = "Folder"
    case sftp = "SFTP"

    var id: String { rawValue }
}
```

- [ ] **Step 4: Implement `VaultLocationResolver`**

`MyPass/State/VaultLocationResolver.swift`:

```swift
import Foundation

/// Pure resolution logic for the primary vault location — factored out of
/// `MyPassApp`/`UnlockView`/Settings so it is unit-testable without
/// instantiating SwiftUI views or a full app, following the same pattern as
/// `SyncBackendResolver`.
enum VaultLocationResolver {
    struct LegacyMigrationResult: Equatable {
        let vaultLocation: VaultLocationOption
        let secondaryDestination: SecondaryDestinationOption?
        let secondaryFolderBookmark: Data?
    }

    /// Resolves the persisted `"vaultLocation"` UserDefaults value, defaulting
    /// to `.local` for a `nil` or unrecognized value — the same
    /// never-crash-on-bad-or-missing-state contract `SyncBackendResolver`
    /// already uses for its bookmarks.
    static func resolveVaultLocation(rawValue: String?) -> VaultLocationOption {
        VaultLocationOption(rawValue: rawValue ?? "") ?? .local
    }

    /// `true` only for a genuinely fresh install: no new-model `"vaultLocation"`
    /// key, no legacy `"syncBackend"` key, and no vault file already sitting in
    /// Application Support from a pre-redesign install. Any of those three
    /// existing means the location is already decided and the wizard must not
    /// interrupt the user.
    static func shouldShowFirstRunWizard(
        vaultLocationRawValue: String?,
        legacySyncBackendRawValue: String?,
        applicationSupportVaultExists: Bool
    ) -> Bool {
        guard vaultLocationRawValue == nil, legacySyncBackendRawValue == nil else { return false }
        return !applicationSupportVaultExists
    }

    /// Maps a pre-redesign `"syncBackend"` value (`SyncBackendOption`'s old
    /// rawValues: "Local File" / "iCloud Drive" / "SFTP") onto the new
    /// two-picker model, so an existing install upgrades without losing its
    /// configuration. Returns `nil` when there is nothing legacy to migrate
    /// (either a fresh install, or one already migrated/configured on the new
    /// model). Called once at launch, guarded by the caller checking the new
    /// `"vaultLocation"` key is not yet set.
    static func migrateLegacyBackendIfNeeded(
        legacySyncBackendRawValue: String?,
        legacyLocalFolderBookmark: Data?
    ) -> LegacyMigrationResult? {
        guard let legacySyncBackendRawValue else { return nil }
        switch legacySyncBackendRawValue {
        case "iCloud Drive":
            // The user was already mirroring into iCloud Drive — promote it
            // straight to primary, which is what they were already relying on.
            return LegacyMigrationResult(vaultLocation: .iCloudDrive, secondaryDestination: nil, secondaryFolderBookmark: nil)
        case "Local File":
            // The user was mirroring into a picked folder — that folder
            // becomes the new secondary "Folder" destination; Application
            // Support stays primary exactly as it already was.
            return LegacyMigrationResult(
                vaultLocation: .local,
                secondaryDestination: .folder,
                secondaryFolderBookmark: legacyLocalFolderBookmark
            )
        case "SFTP":
            return LegacyMigrationResult(vaultLocation: .local, secondaryDestination: .sftp, secondaryFolderBookmark: nil)
        default:
            return LegacyMigrationResult(vaultLocation: .local, secondaryDestination: nil, secondaryFolderBookmark: nil)
        }
    }
}
```

- [ ] **Step 5: Retarget `SyncBackendResolver`'s checkpoint helpers to `SecondaryDestinationOption`**

Custom Folder and SFTP are the only destinations that ever use `SyncEngine`'s checkpoint now (Local/iCloud Drive are the single canonical copy, no push/pull checkpoint needed). In `MyPass/State/SyncBackendResolver.swift`, change:

```swift
static func checkpointKey(for option: SyncBackendOption) -> String {
    "com.mypass.sync.checkpoint.\(option.rawValue)"
}

static func clearCheckpoint(for option: SyncBackendOption, defaults: UserDefaults = .standard) {
    defaults.removeObject(forKey: checkpointKey(for: option))
}
```

to:

```swift
static func checkpointKey(for option: SecondaryDestinationOption) -> String {
    "com.mypass.sync.checkpoint.\(option.rawValue)"
}

static func clearCheckpoint(for option: SecondaryDestinationOption, defaults: UserDefaults = .standard) {
    defaults.removeObject(forKey: checkpointKey(for: option))
}
```

In `MyPassTests/SettingsViewSyncBackendTests.swift`, replace:

```swift
func testCheckpointKeyIsNamespacedPerBackend() {
    XCTAssertEqual(SyncBackendResolver.checkpointKey(for: .iCloud), "com.mypass.sync.checkpoint.iCloud Drive")
    XCTAssertEqual(SyncBackendResolver.checkpointKey(for: .local), "com.mypass.sync.checkpoint.Local File")
    XCTAssertNotEqual(
        SyncBackendResolver.checkpointKey(for: .iCloud),
        SyncBackendResolver.checkpointKey(for: .sftp)
    )
}
```

with:

```swift
func testCheckpointKeyIsNamespacedPerSecondaryDestination() {
    XCTAssertEqual(SyncBackendResolver.checkpointKey(for: .folder), "com.mypass.sync.checkpoint.Folder")
    XCTAssertEqual(SyncBackendResolver.checkpointKey(for: .sftp), "com.mypass.sync.checkpoint.SFTP")
    XCTAssertNotEqual(
        SyncBackendResolver.checkpointKey(for: .folder),
        SyncBackendResolver.checkpointKey(for: .sftp)
    )
}
```

and in `testClearCheckpointRemovesOnlyThatBackendsCheckpoint`, replace `.iCloud`/`.local` with `.folder`/`.sftp`:

```swift
func testClearCheckpointRemovesOnlyThatBackendsCheckpoint() throws {
    let suiteName = "com.mypass.tests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

    defaults.set(1.0, forKey: SyncBackendResolver.checkpointKey(for: .folder))
    defaults.set(2.0, forKey: SyncBackendResolver.checkpointKey(for: .sftp))

    SyncBackendResolver.clearCheckpoint(for: .folder, defaults: defaults)

    XCTAssertNil(defaults.object(forKey: SyncBackendResolver.checkpointKey(for: .folder)))
    XCTAssertNotNil(defaults.object(forKey: SyncBackendResolver.checkpointKey(for: .sftp)))
}
```

Leave every other test in that file (`resolveLocalFolderBackend`, `resolveICloudBackend`, `buildSFTPConfiguration`, `SFTPConnectionTester`, `iCloudFolderBookmarkKey`) exactly as-is — they are unaffected by this change. Note this leaves `SyncBackendOption` itself still referenced elsewhere in the app (`MyPassApp.swift`, `SyncSettingsPane.swift`, `SyncMigrationSheet.swift`) until Tasks 5, 6, and 8 update those call sites — that's expected; this step only changes the resolver's own signature and its direct tests.

- [ ] **Step 6: Run tests to verify they pass**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/VaultLocationResolverTests -only-testing:MyPassTests/SettingsViewSyncBackendTests 2>&1 | tail -60`
Expected: PASS for the new `VaultLocationResolverTests` and for `SettingsViewSyncBackendTests`'s renamed checkpoint tests.

- [ ] **Step 7: Commit**

```bash
git add MyPass/UI/Settings/VaultLocationOption.swift MyPass/UI/Settings/SecondaryDestinationOption.swift MyPass/State/VaultLocationResolver.swift MyPass/State/SyncBackendResolver.swift MyPassTests/VaultLocationResolverTests.swift MyPassTests/SettingsViewSyncBackendTests.swift
git commit -m "feat(mypass): add VaultLocationOption/SecondaryDestinationOption, legacy-migration resolver, retarget checkpoint keys"
```

---

### Task 5: Wire `MyPassApp.init()` to the new location model

**Files:**
- Modify: `MyPass/MyPassApp.swift`

**Interfaces:**
- Consumes: `VaultLocationResolver` (Task 4), `ICloudDriveVaultStore` (Task 2), `VaultPrimaryStorage`-typed `VaultSession.init` (Task 3).
- Produces: nothing new consumed by later tasks — this is app-launch wiring, verified manually (see Step 3 below) since `MyPassApp.init()` cannot be unit tested in isolation (matches how the existing hardcoded wiring is untested today).

- [ ] **Step 1: Replace the hardcoded primary store construction**

In `MyPass/MyPassApp.swift`, inside `init()`, before the existing `let syncBackendOption = ...` line, add the legacy-migration + resolution:

```swift
let applicationSupportDirectory = FileManager.default
    .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("MyPass")

if defaults.string(forKey: "vaultLocation") == nil,
   let migration = VaultLocationResolver.migrateLegacyBackendIfNeeded(
       legacySyncBackendRawValue: defaults.string(forKey: "syncBackend"),
       legacyLocalFolderBookmark: defaults.data(forKey: "syncLocalFolderBookmark")
   ) {
    defaults.set(migration.vaultLocation.rawValue, forKey: "vaultLocation")
    if let secondaryDestination = migration.secondaryDestination {
        defaults.set(secondaryDestination.rawValue, forKey: "secondaryDestination")
    }
    if let bookmark = migration.secondaryFolderBookmark {
        defaults.set(bookmark, forKey: "secondaryFolderBookmark")
    }
}

let vaultLocation = VaultLocationResolver.resolveVaultLocation(rawValue: defaults.string(forKey: "vaultLocation"))
let primaryStore: VaultPrimaryStorage
var iCloudPrimaryStore: ICloudDriveVaultStore?
switch vaultLocation {
case .local:
    primaryStore = VaultFileStore(directory: applicationSupportDirectory)
case .iCloudDrive:
    if let bookmarkData = defaults.data(forKey: SyncBackendResolver.iCloudFolderBookmarkKey), !bookmarkData.isEmpty,
       let store = try? ICloudDriveVaultStore(
           bookmarkData: bookmarkData,
           localBackupDirectory: applicationSupportDirectory.appendingPathComponent("backups")
       ) {
        primaryStore = store
        iCloudPrimaryStore = store
    } else {
        // Bookmark missing or stale: fall back to Local rather than crash
        // launch. Settings surfaces this so the user can re-grant access.
        primaryStore = VaultFileStore(directory: applicationSupportDirectory)
    }
}
```

Then change the existing `VaultFileStore(directory: ...)` argument passed into `VaultSession(fileStore:...)` to `primaryStore`:

```swift
let session = VaultSession(
    fileStore: primaryStore,
    syncEngine: syncEngine
)
```

- [ ] **Step 2: Wire the iCloud external-change watcher**

Right after `_vaultSession = StateObject(wrappedValue: session)`, add:

```swift
// Design spec's external-change handling: reload-and-merge when another
// device/process touches the same iCloud Drive file.
if let iCloudPrimaryStore {
    iCloudPrimaryStore.onRemoteChange = { [weak session] in
        session?.triggerBackgroundSync()
    }
}
```

- [ ] **Step 3: Replace the secondary-destination switch**

The existing `switch syncBackendOption { case .local: ... case .iCloud: ... case .sftp: ... }` block that builds the `SyncEngine`'s `backend` now governs the *secondary* destination only. Replace `syncBackendOption`/`SyncBackendOption` in that block with a new `secondaryDestination` read from the new key, dropping the `.iCloud` case entirely (iCloud is primary-only now) and keeping `.folder`/`.sftp` bodies as today's `.local`/`.sftp` bodies were (reading from the new key names):

```swift
let secondaryDestination = SecondaryDestinationOption(rawValue: defaults.string(forKey: "secondaryDestination") ?? "") ?? .none

var localFolderURLForWatcher: URL?
let syncEngine: SyncEngine? = {
    let backend: StorageBackend?
    switch secondaryDestination {
    case .none:
        return nil
    case .folder:
        let bookmarkData = defaults.data(forKey: "secondaryFolderBookmark")
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
    }

    guard let backend else { return nil }
    let checkpointStore = UserDefaultsSyncCheckpointStore(
        key: SyncBackendResolver.checkpointKey(for: secondaryDestination)
    )
    return SyncEngine(remote: backend, checkpointStore: checkpointStore)
}()
```

(This replaces the existing `let syncEngine: SyncEngine? = { guard syncBackendOption.isAvailable else { return nil } ... }()` block and its `syncBackendOption` variable entirely — delete the old `let syncBackendOption = SyncBackendOption(rawValue: ...)` line too.)

The later `if syncBackendOption == .local, let folderURL = localFolderURLForWatcher { ... LocalFolderChangeWatcher ... }` block becomes:

```swift
if secondaryDestination == .folder, let folderURL = localFolderURLForWatcher {
    let watcher = LocalFolderChangeWatcher(folderURL: folderURL) { [weak session] in
        session?.triggerBackgroundSync()
    }
    watcher.start()
    AppDelegate.localFolderChangeWatcher = watcher
}
```

- [ ] **Step 4: Manual verification**

Use the `run` skill to build and launch the app three times, resetting state between runs with:
`defaults delete com.mypass.app 2>/dev/null; rm -rf ~/Library/Containers/com.mypass.app/Data/Library/Application\ Support/MyPass`
(check the actual bundle identifier in `MyPass.entitlements`'s sibling `Info.plist`/project settings if `com.mypass.app` doesn't match).

1. Fresh install (defaults cleared): app should reach `UnlockView` in first-run mode against Local (Application Support) — full wizard UI lands in Task 7, so for now just confirm the app still launches and unlocks/creates a vault normally.
2. Simulate a pre-redesign install: `defaults write com.mypass.app syncBackend "iCloud Drive"` and set some fake `syncICloudFolderBookmark` data, then relaunch — confirm via a debugger breakpoint or temporary `os_log` that `vaultLocation` gets set to `"iCloud Drive"` in defaults after this launch (`defaults read com.mypass.app vaultLocation`).
3. Simulate legacy Local-folder mirror: `defaults write com.mypass.app syncBackend "Local File"`, relaunch, confirm `defaults read com.mypass.app secondaryDestination` reads `"Folder"`.

- [ ] **Step 5: Commit**

```bash
git add MyPass/MyPassApp.swift
git commit -m "feat(mypass): resolve primary vault location and secondary destination at launch, migrate legacy settings"
```

---

### Task 6: `VaultLocationChangeSheet` (renamed/reworked from `SyncMigrationSheet`)

**Files:**
- Modify (rename): `MyPass/UI/Settings/SyncMigrationSheet.swift` → `MyPass/UI/Settings/VaultLocationChangeSheet.swift`
- Modify (rename): `MyPassTests/SyncMigrationSheetMessageTests.swift` → `MyPassTests/VaultLocationChangeSheetMessageTests.swift`

**Interfaces:**
- Consumes: `VaultSession.verifyPassword`/`.unlock`/`.performMigration`/`.probeMigrationTarget` (Task 3), `VaultLocationOption` (Task 4), `ICloudDriveVaultStore` is not directly needed here (the sheet builds a plain `iCloudBackend`/`VaultFileStore` `StorageBackend` for probing/migrating, matching `VaultMigrationService`'s existing backend-agnostic design; Task 7's caller is responsible for calling `vaultSession.updatePrimaryStore` afterward with the right wrapper type).
- Produces: `struct VaultLocationChangeSheet: View { let targetLocation: VaultLocationOption; ... }`. Task 7's `VaultLocationSettingsPane` presents this sheet.

- [ ] **Step 1: Rename the files**

```bash
git mv MyPass/UI/Settings/SyncMigrationSheet.swift MyPass/UI/Settings/VaultLocationChangeSheet.swift
git mv MyPassTests/SyncMigrationSheetMessageTests.swift MyPassTests/VaultLocationChangeSheetMessageTests.swift
```

- [ ] **Step 2: Write the failing tests for the new pure logic**

Open `MyPassTests/VaultLocationChangeSheetMessageTests.swift`, rename the type under test in every existing test (`SyncMigrationSheet.` → `VaultLocationChangeSheet.`), keep all existing test bodies as-is (the static helpers `describe`/`title`/`explanation`/`successMessage`/`message`/`shouldClearPersistedBookmark` behave identically), and add:

```swift
func testConfirmStepIsSkippedWhenAlreadyUnlocked() {
    XCTAssertFalse(VaultLocationChangeSheet.needsPasswordConfirmation(currentState: .unlocked))
}

func testConfirmStepIsRequiredWhenLocked() {
    XCTAssertTrue(VaultLocationChangeSheet.needsPasswordConfirmation(currentState: .locked))
}
```

(`.unlocked`/`.locked` here are a tiny test-only enum defined alongside the test — see Step 3's `LockStateSnapshot` — not `VaultState` itself, since the sheet's helper should not need to import `MyPassKit`'s `KdbxDatabase` just to decide whether to show a password field.)

- [ ] **Step 3: Run tests to verify they fail**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/VaultLocationChangeSheetMessageTests 2>&1 | tail -40`
Expected: FAIL — `needsPasswordConfirmation`/`LockStateSnapshot` don't exist; existing renamed tests should already compile once Step 2's rename is applied (if they fail only because of the rename before Step 4's implementation rename, that's expected too).

- [ ] **Step 4: Rewrite `VaultLocationChangeSheet.swift`**

Replace the `struct SyncMigrationSheet: View` declaration and its surrounding doc-comment with:

```swift
import SwiftUI
import AppKit
import MyPassKit
import SyncKit

/// Changes the vault's primary `VaultLocation` (Local ↔ iCloud Drive),
/// reachable whether the app is currently locked or unlocked. Entering the
/// master password here is both the "prove you own this vault" check and,
/// when the app was locked, the unlock itself — `VaultSession.verifyPassword`
/// checks it without side effects, and only on success is the vault actually
/// unlocked (if it wasn't already) before the existing probe/strategy/migrate
/// flow (`VaultMigrationService`, unchanged) runs.
struct VaultLocationChangeSheet: View {
    let targetLocation: VaultLocationOption

    @EnvironmentObject private var vaultSession: VaultSession
    @Environment(\.dismiss) private var dismiss
    @AppStorage("vaultLocation") private var vaultLocationRawValue: String = VaultLocationOption.local.rawValue
    @AppStorage(SyncBackendResolver.iCloudFolderBookmarkKey) private var syncICloudFolderBookmarkData: Data?

    @State private var step: Step
    @State private var confirmPassword: String = ""
    @State private var chosenFolderURL: URL?
    @State private var chosenFolderBookmark: Data?
    @State private var outsideICloudDriveWarning: String?
    @State private var probe: VaultMigrationTargetProbe?
    @State private var strategy: VaultMigrationStrategy = .merge
    @State private var errorMessage: String?
    @State private var successMessage: String?

    init(targetLocation: VaultLocationOption) {
        self.targetLocation = targetLocation
        _step = State(initialValue: .confirmPassword)
    }

    private enum Step: Equatable {
        case confirmPassword
        case chooseFolder
        case probing
        case confirmStrategy
        case migrating
        case finished
    }

    /// Pure, testable version of "does the confirm-password step need to run
    /// right now" — factored out so it does not depend on `VaultSession`'s
    /// concrete `VaultState`/`KdbxDatabase` types.
    enum LockStateSnapshot { case locked, unlocked }
    static func needsPasswordConfirmation(currentState: LockStateSnapshot) -> Bool {
        currentState == .locked
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Change Vault Location")
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
        .onAppear {
            let snapshot: LockStateSnapshot = isVaultUnlocked ? .unlocked : .locked
            if !Self.needsPasswordConfirmation(currentState: snapshot) {
                step = targetLocation == .iCloudDrive ? .chooseFolder : .probing
                if targetLocation == .local { startProbeAgainstLocal() }
            }
        }
    }

    private var isVaultUnlocked: Bool {
        if case .unlocked = vaultSession.state { return true }
        return false
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .confirmPassword:
            VStack(alignment: .leading, spacing: 8) {
                Text("Enter your master password to confirm this change.")
                    .fixedSize(horizontal: false, vertical: true)
                SecureField("Master Password", text: $confirmPassword)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(confirmPasswordAndContinue)
            }

        case .chooseFolder:
            VStack(alignment: .leading, spacing: 8) {
                Text("MyPass will keep the vault in a folder inside your iCloud Drive.")
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
                Text("Checking the target location…")
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
            }
        }
    }

    @ViewBuilder
    private var strategyChooser: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let probe, probe.exists {
                Text("That location already contains a vault\(Self.describe(probe)). Choose what to do with it.")
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
                Text("That location has no vault yet. MyPass will move the vault from its current location there.")
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack {
            Spacer()
            switch step {
            case .confirmPassword:
                Button("Cancel") { dismiss() }
                Button("Continue") { confirmPasswordAndContinue() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(confirmPassword.isEmpty)
            case .chooseFolder:
                Button("Cancel") { dismiss() }
                Button(chosenFolderURL == nil ? "Choose Folder…" : "Choose Another Folder…") { chooseFolder() }
                if chosenFolderBookmark != nil {
                    Button("Continue") { startProbeAgainstICloud() }
                        .keyboardShortcut(.defaultAction)
                }
            case .probing, .migrating:
                Button("Cancel") { dismiss() }
                    .disabled(true)
            case .confirmStrategy:
                Button("Back") {
                    errorMessage = nil
                    step = targetLocation == .iCloudDrive ? .chooseFolder : .confirmPassword
                }
                Button("Change Location") { startMigration() }
                    .keyboardShortcut(.defaultAction)
            case .finished:
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: - Actions

    private func confirmPasswordAndContinue() {
        guard vaultSession.verifyPassword(confirmPassword) else {
            errorMessage = "Incorrect password."
            return
        }
        if case .locked = vaultSession.state {
            try? vaultSession.unlock(password: confirmPassword)
        }
        confirmPassword = ""
        errorMessage = nil
        if targetLocation == .iCloudDrive {
            step = .chooseFolder
        } else {
            startProbeAgainstLocal()
        }
    }

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
            : "This folder is not inside iCloud Drive, so iCloud will not sync it. MyPass will still keep the vault there."
        do {
            chosenFolderBookmark = try iCloudBackend.createFolderBookmark(for: folderURL)
        } catch {
            chosenFolderBookmark = nil
            errorMessage = "MyPass could not keep access to that folder: \(error)"
        }
    }

    private func startProbeAgainstICloud() {
        guard let backend = makeICloudTargetBackend() else { return }
        runProbe(against: backend)
    }

    private func startProbeAgainstLocal() {
        runProbe(against: makeLocalTargetBackend())
    }

    private func runProbe(against backend: StorageBackend) {
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
        let backend: StorageBackend?
        switch targetLocation {
        case .iCloudDrive: backend = makeICloudTargetBackend()
        case .local: backend = makeLocalTargetBackend()
        }
        guard let backend else { return }

        errorMessage = nil
        step = .migrating
        vaultSession.performMigration(to: backend, strategy: strategy) { result in
            switch result {
            case .success(let outcome):
                self.applyLocationChange(outcome: outcome)
            case .failure(let error):
                self.handle(error)
            }
        }
    }

    /// Only reached after `VaultMigrationService.migrate` has already
    /// succeeded — persists the new location and swaps `VaultSession`'s live
    /// primary store, so nothing is written to settings until the data is
    /// safely in place.
    private func applyLocationChange(outcome: VaultMigrationOutcome) {
        switch targetLocation {
        case .iCloudDrive:
            guard let chosenFolderBookmark,
                  let newStore = try? ICloudDriveVaultStore(
                      bookmarkData: chosenFolderBookmark,
                      localBackupDirectory: applicationSupportBackupsDirectory
                  ) else {
                errorMessage = "The vault was moved, but MyPass could not switch to it. Restart MyPass and try again."
                return
            }
            vaultSession.updatePrimaryStore(newStore)
            syncICloudFolderBookmarkData = chosenFolderBookmark
        case .local:
            vaultSession.updatePrimaryStore(VaultFileStore(directory: applicationSupportDirectory))
        }
        vaultLocationRawValue = targetLocation.rawValue
        SyncBackendResolver.clearCheckpoint(for: .folder)
        SyncBackendResolver.clearCheckpoint(for: .sftp)
        successMessage = Self.successMessage(for: outcome)
        step = .finished
    }

    private var applicationSupportDirectory: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MyPass")
    }

    private var applicationSupportBackupsDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("backups")
    }

    private func makeICloudTargetBackend() -> iCloudBackend? {
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

    private func makeLocalTargetBackend() -> VaultFileStore {
        VaultFileStore(directory: applicationSupportDirectory)
    }

    private func handle(_ error: Error) {
        if let backendError = error as? iCloudBackendError,
           backendError == .folderBookmarkUnresolvable || backendError == .folderUnavailable {
            if Self.shouldClearPersistedBookmark(
                failingBookmark: chosenFolderBookmark,
                persistedBookmark: syncICloudFolderBookmarkData
            ) {
                syncICloudFolderBookmarkData = nil
            }
            chosenFolderBookmark = nil
            chosenFolderURL = nil
        }
        errorMessage = Self.message(for: error)
        step = targetLocation == .iCloudDrive ? .chooseFolder : .confirmPassword
    }

    // MARK: - Copy (unchanged from the previous SyncMigrationSheet — see
    // VaultLocationChangeSheetMessageTests for coverage)

    static func shouldClearPersistedBookmark(failingBookmark: Data?, persistedBookmark: Data?) -> Bool {
        guard let failingBookmark, let persistedBookmark, !failingBookmark.isEmpty else { return false }
        return failingBookmark == persistedBookmark
    }

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
        case .seedRemote: return "Move the vault to the new location"
        case .merge: return "Merge both vaults (recommended)"
        case .adoptRemote: return "Use the vault already at the new location"
        case .overwriteRemote: return "Replace the vault at the new location"
        }
    }

    static func explanation(for strategy: VaultMigrationStrategy) -> String {
        switch strategy {
        case .seedRemote:
            return "The new location has no vault yet, so the current vault is moved there unchanged."
        case .merge:
            return "Keeps every entry from both sides, using the same merge rules as normal syncing. Both copies end up identical."
        case .adoptRemote:
            return "Replaces the current vault with the one already at the new location. The current vault is snapshotted into the backups folder first."
        case .overwriteRemote:
            return "Replaces the vault at the new location with the current one. The copy currently there is discarded."
        }
    }

    static func successMessage(for outcome: VaultMigrationOutcome) -> String {
        switch outcome.strategy {
        case .seedRemote:
            return "The vault is now at the new location."
        case .merge:
            return "Both vaults were merged. The current vault and the new location now hold the same entries."
        case .adoptRemote:
            return "MyPass now uses the vault that was already at the new location. The previous vault was kept in the backups folder."
        case .overwriteRemote:
            return "The new location now holds the current vault."
        }
    }

    static func message(for error: Error) -> String {
        if let backendError = error as? iCloudBackendError {
            return message(forICloudBackendError: backendError)
        }
        if let migrationError = error as? VaultMigrationError {
            switch migrationError {
            case .vaultLocked:
                return "Unlock MyPass before changing the vault location."
            case .remoteNotAValidVault:
                return "The file at that location is not a MyPass vault. Nothing was changed on either side."
            case .remotePasswordMismatch:
                return "The vault at that location uses a different password. Nothing was changed on either side."
            case .remoteUnreadable(let underlying):
                if let backendError = underlying as? iCloudBackendError {
                    return message(forICloudBackendError: backendError)
                }
                return "MyPass could not read that location: \(underlying)"
            case .remoteWriteFailed(let underlying):
                if let backendError = underlying as? iCloudBackendError {
                    return message(forICloudBackendError: backendError)
                }
                return "MyPass could not write to that location: \(underlying). The current vault was not changed."
            case .serializedVaultInvalid:
                return "MyPass could not prepare the vault for the move. Nothing was written to the new location."
            case .localWriteFailed(let underlying):
                return "The new location is now ahead of the current vault: writing the result failed (\(underlying)). Try again and choose \u{201C}Use the vault already at the new location\u{201D} to catch up."
            }
        }
        return "\(error)"
    }

    private static func message(forICloudBackendError backendError: iCloudBackendError) -> String {
        switch backendError {
        case .folderBookmarkUnresolvable, .folderUnavailable:
            return "That folder is no longer reachable. Choose the iCloud Drive folder again."
        case .downloadTimedOut:
            return "The vault at that location is still downloading from iCloud. Wait until it finishes, then try again."
        case .containerUnavailable:
            return "MyPass keeps the vault in a folder in iCloud Drive, not a private iCloud container. Choose a folder to continue."
        }
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/VaultLocationChangeSheetMessageTests 2>&1 | tail -60`
Expected: PASS for all renamed and new cases.

- [ ] **Step 6: Commit**

```bash
git add MyPass/UI/Settings/VaultLocationChangeSheet.swift MyPassTests/VaultLocationChangeSheetMessageTests.swift
git commit -m "feat(mypass): rework SyncMigrationSheet into bidirectional VaultLocationChangeSheet"
```

---

### Task 7: `VaultLocationSettingsPane`, first-run wizard, `SettingsPane`/`SettingsView`/`UnlockView` wiring

**Files:**
- Create: `MyPass/UI/Settings/VaultLocationSettingsPane.swift`
- Create: `MyPass/UI/Settings/VaultLocationFirstRunSheet.swift`
- Modify: `MyPass/UI/Settings/SettingsPane.swift`
- Modify: `MyPass/UI/Settings/SettingsView.swift`
- Modify: `MyPass/UI/Unlock/UnlockView.swift`

**Interfaces:**
- Consumes: `VaultLocationChangeSheet` (Task 6), `VaultLocationResolver` (Task 4), `ICloudDriveVaultStore` (Task 2).
- Produces: reachable pre-auth "Vault Location" settings pane and a pre-auth first-run wizard. Nothing later depends on new types here — this is the last UI-wiring task before Task 8's secondary-pane cleanup.

- [ ] **Step 1: Add the new `SettingsPane` case**

In `MyPass/UI/Settings/SettingsPane.swift`, add `case vaultLocation` to the enum (put it right after `.general`) and its `title`/`symbolName`:

```swift
case vaultLocation
```
```swift
case .vaultLocation: return "Vault Location"
```
```swift
case .vaultLocation: return "folder"
```

- [ ] **Step 2: Wire it into `SettingsView`**

In `MyPass/UI/Settings/SettingsView.swift`'s `paneContent(for:)`, add:

```swift
case .vaultLocation:
    VaultLocationSettingsPane()
        .environmentObject(vaultSession)
```

- [ ] **Step 3: Implement `VaultLocationSettingsPane`**

`MyPass/UI/Settings/VaultLocationSettingsPane.swift`:

```swift
import SwiftUI

/// Reachable before authentication as well as after — unlike the old Sync
/// pane's iCloud button, "Change Location…" is never disabled on lock state;
/// `VaultLocationChangeSheet` handles proving ownership itself.
struct VaultLocationSettingsPane: View {
    @AppStorage("vaultLocation") private var vaultLocationRawValue: String = VaultLocationOption.local.rawValue
    @State private var showingChangeSheet = false
    @State private var pendingTargetLocation: VaultLocationOption?

    private var currentLocation: VaultLocationOption {
        VaultLocationOption(rawValue: vaultLocationRawValue) ?? .local
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Current Location", value: currentLocation.rawValue)
                Button(currentLocation == .local ? "Switch to iCloud Drive…" : "Switch to Local…") {
                    pendingTargetLocation = currentLocation == .local ? .iCloudDrive : .local
                    showingChangeSheet = true
                }
                SettingsHelperText(text: "Local keeps the vault only on this Mac. iCloud Drive keeps it in a folder that syncs between your Macs (and, in the future, other devices signed into the same iCloud account).")
            } header: {
                Text("Vault Location")
                    .font(.system(size: 13, weight: .semibold))
            }
        }
        .formStyle(.grouped)
        .padding()
        .sheet(isPresented: $showingChangeSheet) {
            if let pendingTargetLocation {
                VaultLocationChangeSheet(targetLocation: pendingTargetLocation)
            }
        }
    }
}
```

- [ ] **Step 4: Implement the first-run wizard**

`MyPass/UI/Settings/VaultLocationFirstRunSheet.swift`:

```swift
import SwiftUI
import AppKit
import SyncKit

/// Shown once, before any vault has ever been created, per the approved
/// design: "Use iCloud Drive" (default) or "Skip for now (local only)".
/// There is no password-confirmation step here — nothing exists yet to
/// verify against, unlike `VaultLocationChangeSheet`.
struct VaultLocationFirstRunSheet: View {
    @EnvironmentObject private var vaultSession: VaultSession
    @AppStorage("vaultLocation") private var vaultLocationRawValue: String = VaultLocationOption.local.rawValue
    @AppStorage(SyncBackendResolver.iCloudFolderBookmarkKey) private var syncICloudFolderBookmarkData: Data?

    let onFinished: () -> Void

    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Where should MyPass keep your vault?")
                .font(.headline)
            Text("iCloud Drive keeps the vault in a folder that syncs between your Macs. You can change this later in Settings.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Skip for Now (Local Only)") {
                    vaultLocationRawValue = VaultLocationOption.local.rawValue
                    onFinished()
                }
                Button("Use iCloud Drive") { useICloudDrive() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func useICloudDrive() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        panel.message = "Choose a folder inside iCloud Drive for the MyPass vault."
        panel.directoryURL = ICloudDriveLocation.iCloudDriveRootURL

        guard panel.runModal() == .OK, let folderURL = panel.url else { return }

        do {
            let bookmark = try iCloudBackend.createFolderBookmark(for: folderURL)
            let applicationSupportDirectory = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("MyPass")
            let store = try ICloudDriveVaultStore(
                bookmarkData: bookmark,
                localBackupDirectory: applicationSupportDirectory.appendingPathComponent("backups")
            )
            vaultSession.updatePrimaryStore(store)
            syncICloudFolderBookmarkData = bookmark
            vaultLocationRawValue = VaultLocationOption.iCloudDrive.rawValue
            onFinished()
        } catch {
            errorMessage = "MyPass could not use that folder: \(error)"
        }
    }
}
```

- [ ] **Step 5: Present it from `UnlockView`**

In `MyPass/UI/Unlock/UnlockView.swift`, add state and a sheet presentation, and gate it in `onAppear`:

```swift
@State private var showingLocationWizard = false
```

Change the existing `.onAppear` block from:

```swift
.onAppear {
    isFirstRun = (try? vaultSession.loadVaultData()) == nil
    if !isFirstRun, canShowDeviceUnlockButton, !didAutoPromptDeviceUnlock {
        didAutoPromptDeviceUnlock = true
        attemptDeviceUnlock(silentCancel: true)
    }
}
```

to:

```swift
.onAppear {
    isFirstRun = (try? vaultSession.loadVaultData()) == nil
    if isFirstRun {
        let defaults = UserDefaults.standard
        showingLocationWizard = VaultLocationResolver.shouldShowFirstRunWizard(
            vaultLocationRawValue: defaults.string(forKey: "vaultLocation"),
            legacySyncBackendRawValue: defaults.string(forKey: "syncBackend"),
            applicationSupportVaultExists: (try? vaultSession.loadVaultData()) != nil
        )
    }
    if !isFirstRun, canShowDeviceUnlockButton, !didAutoPromptDeviceUnlock {
        didAutoPromptDeviceUnlock = true
        attemptDeviceUnlock(silentCancel: true)
    }
}
.sheet(isPresented: $showingLocationWizard) {
    VaultLocationFirstRunSheet(onFinished: {
        showingLocationWizard = false
        isFirstRun = (try? vaultSession.loadVaultData()) == nil
    })
}
```

(`applicationSupportVaultExists` is always `false` here in practice for a first-run check — `vaultSession.loadVaultData()` reads through whatever primary store is currently configured, which for a fresh install is `.local`/Application Support per Task 5's resolution; passing the direct result keeps the helper call honest rather than hardcoding `false`.)

- [ ] **Step 6: Manual verification**

Use the `run` skill:
1. Clear defaults and the Application Support vault (see Task 5 Step 4's cleanup commands), launch: the wizard should appear before the password field. Choose "Skip for Now" — confirm the normal first-run password-creation UI appears next and unlocking creates a vault in Application Support as before.
2. Repeat from clean state, choose "Use iCloud Drive", pick a folder, confirm the wizard dismisses and the normal password-creation UI appears; after setting a password, confirm (`defaults read com.mypass.app vaultLocation`) reads `"iCloud Drive"` and the vault file appears in the chosen folder.
3. Quit and relaunch after either path — confirm the wizard does NOT reappear (existing `vaultLocation` key present).
4. Open Settings (Cmd-,) while still locked — confirm "Vault Location" pane is reachable and shows the current location with a working "Switch to…" button.

- [ ] **Step 7: Commit**

```bash
git add MyPass/UI/Settings/VaultLocationSettingsPane.swift MyPass/UI/Settings/VaultLocationFirstRunSheet.swift MyPass/UI/Settings/SettingsPane.swift MyPass/UI/Settings/SettingsView.swift MyPass/UI/Unlock/UnlockView.swift
git commit -m "feat(mypass): add pre-auth Vault Location settings pane and first-run location wizard"
```

---

### Task 8: Repurpose `SyncSettingsPane` as the secondary-destination pane, retire `SyncBackendOption`

**Files:**
- Modify: `MyPass/UI/Settings/SyncSettingsPane.swift`
- Delete: `MyPass/UI/Settings/SyncBackendOption.swift`

**Interfaces:**
- Consumes: `SecondaryDestinationOption` (Task 4). `SyncBackendResolver`'s checkpoint helpers were already retargeted to `SecondaryDestinationOption` in Task 4, Step 5 — nothing left to change there.
- Produces: nothing further consumed by other tasks — this is the final cleanup task.

- [ ] **Step 1: Rewrite `SyncSettingsPane`**

Replace the picker and remove the `localFolderSection`/`iCloudSection` (moved to `VaultLocationSettingsPane`/`VaultLocationChangeSheet` in Task 7), keeping the SFTP section as-is and renaming the local-folder section into a "Folder" secondary section keyed off the new `secondaryFolderBookmark`/`secondaryDestination` keys:

```swift
import SwiftUI
import AppKit
import SyncKit

struct SyncSettingsPane: View {
    @AppStorage("secondaryDestination") private var secondaryDestinationRawValue: String = SecondaryDestinationOption.none.rawValue
    @AppStorage("secondaryFolderBookmark") private var secondaryFolderBookmarkData: Data?

    @AppStorage("syncSFTPHost") private var sftpHost: String = ""
    @AppStorage("syncSFTPPort") private var sftpPort: Int = 22
    @AppStorage("syncSFTPUsername") private var sftpUsername: String = ""
    @AppStorage("syncSFTPRemotePath") private var sftpRemotePath: String = "/upload/vault.kdbx"
    @AppStorage("syncSFTPPrivateKeyPath") private var sftpPrivateKeyPath: String = ""
    @AppStorage("syncSFTPCertificatePath") private var sftpCertificatePath: String = ""

    @State private var sftpPrivateKeyPEM: String = ""
    @State private var sftpPassphrase: String = ""
    @State private var connectionTestState: ConnectionTestState = .idle
    @State private var manualSyncStatusMessage: String?

    @EnvironmentObject private var vaultSession: VaultSession

    private enum ConnectionTestState: Equatable {
        case idle
        case testing
        case success
        case failure(String)
    }

    private var selectedOption: SecondaryDestinationOption {
        SecondaryDestinationOption(rawValue: secondaryDestinationRawValue) ?? .none
    }

    var body: some View {
        Form {
            Section {
                Picker("Also Sync To", selection: $secondaryDestinationRawValue) {
                    ForEach(SecondaryDestinationOption.allCases) { option in
                        Text(option.rawValue).tag(option.rawValue)
                    }
                }
                switch selectedOption {
                case .none:
                    EmptyView()
                case .folder:
                    folderSection
                case .sftp:
                    sftpSection
                }
                if selectedOption != .none {
                    Button("Sync Now") {
                        vaultSession.triggerBackgroundSync()
                        manualSyncStatusMessage = "Started…"
                    }
                    if let manualSyncStatusMessage {
                        Text(manualSyncStatusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                SettingsHelperText(text: "Keep an additional copy of the vault in a folder or on an SFTP server, on top of its main location (set under Vault Location). Restart MyPass after changing this.")
            } header: {
                Text("Sync")
                    .font(.system(size: 13, weight: .semibold))
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear { loadSFTPCredentialsIfAvailable() }
    }

    private var folderSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let bookmarkData = secondaryFolderBookmarkData, !bookmarkData.isEmpty,
               SyncBackendResolver.resolveLocalFolderBackend(bookmarkData: bookmarkData) != nil {
                Text("Folder selected.")
                    .foregroundStyle(.secondary)
            } else {
                Text("No folder selected.")
                    .foregroundStyle(.secondary)
            }
            Button("Choose Folder…") {
                let panel = NSOpenPanel()
                panel.canChooseFiles = false
                panel.canChooseDirectories = true
                panel.allowsMultipleSelection = false
                if panel.runModal() == .OK, let folderURL = panel.url {
                    secondaryFolderBookmarkData = try? LocalFolderBackend.createBookmark(for: folderURL)
                }
            }
        }
    }

    private var sftpSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Host", text: $sftpHost)
            Stepper("Port: \(sftpPort)", value: $sftpPort, in: 1...65535)
            TextField("Username", text: $sftpUsername)
                .onChange(of: sftpUsername) { _, _ in persistCredentialsToKeychain() }
            TextField("Remote Path", text: $sftpRemotePath)
            SecureField("Key Passphrase (if any)", text: $sftpPassphrase)
                .onChange(of: sftpPassphrase) { _, _ in persistCredentialsToKeychain() }

            HStack {
                Text(sftpPrivateKeyPath.isEmpty ? "No key selected" : sftpPrivateKeyPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Choose Private Key…") {
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
                Text(sftpCertificatePath.isEmpty ? "No certificate selected (optional)" : sftpCertificatePath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Choose Certificate…") {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = true
                    panel.canChooseDirectories = false
                    panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK, let url = panel.url {
                        sftpCertificatePath = url.path
                    }
                }
            }

            Button("Test Connection") {
                testSFTPConnection()
            }
            switch connectionTestState {
            case .idle:
                EmptyView()
            case .testing:
                ProgressView().controlSize(.small)
            case .success:
                Label("Connection successful", systemImage: "checkmark.circle.fill")
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
}
```

- [ ] **Step 2: Confirm no remaining references to `SyncBackendOption`, then delete it**

Run: `grep -rn "SyncBackendOption" MyPass MyPassTests 2>/dev/null`
Expected: no output.

```bash
git rm MyPass/UI/Settings/SyncBackendOption.swift
```

- [ ] **Step 3: Run the full test suite**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' 2>&1 | tail -100`
Expected: PASS across the whole `MyPassTests` target.

- [ ] **Step 4: Commit**

```bash
git add MyPass/UI/Settings/SyncSettingsPane.swift
git commit -m "refactor(mypass): repurpose Sync pane as secondary-destination picker, retire SyncBackendOption"
```

---

### Task 9: End-to-end verification pass

**Files:** none (verification only).

- [ ] **Step 1: Run the full test suite one more time**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' 2>&1 | tail -100`
Expected: PASS, zero failures, across `MyPassTests` and the `SyncKit`/`MyPassKit` package tests (`swift test --package-path Packages/SyncKit`, `swift test --package-path Packages/MyPassKit` if either was touched — they were not in this plan, but confirm they still pass since `VaultFileStore` in the app target now conforms to `SyncKit.StorageBackend`).

- [ ] **Step 2: Manual verification via the `run` skill**

Cover every scenario from the design spec's Testing section that isn't already covered by Task 5/7's manual steps:
1. Fresh install → wizard → "Use iCloud Drive" → create vault → quit/relaunch → vault still unlocks correctly from the iCloud Drive folder.
2. Fresh install → wizard → "Skip for now" → create vault → later, open Settings → Vault Location → "Switch to iCloud Drive…" while UNLOCKED → confirm password step still appears → complete migration → confirm entries survived.
3. Lock the app → open Settings → Vault Location → "Switch to Local…" → enter the WRONG password → confirm the error appears and the location is unchanged (`defaults read com.mypass.app vaultLocation` still shows the prior value).
4. Repeat step 3 with the correct password → confirm the app becomes unlocked as a side effect and the migration completes.
5. Set `secondaryDestination` to Folder in the Sync pane, pick a folder, confirm entries mirror there (existing `SyncEngine` behavior, unchanged) alongside whichever primary location is active.
6. Legacy migration: with an existing vault already in Application Support (no `vaultLocation` key), set `syncBackend` to each of `"iCloud Drive"`, `"Local File"`, `"SFTP"` via `defaults write` before relaunch, and confirm the mapping documented in Task 4/5 lands correctly each time.

- [ ] **Step 3: Update the design spec if any behavior changed during implementation**

If any step above required deviating from `docs/superpowers/specs/2026-07-30-unified-vault-location-design.md`, update that file to match reality and commit it alongside a short note in the commit message about what changed and why.
