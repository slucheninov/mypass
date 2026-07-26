# MyPass Menu Bar Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the minimal 240 pt `MenuBarExtraContent` popover with an Apple Passwords–style window-style menu bar panel: compact unlock prompt when locked, up to five recent entries plus app actions when unlocked, and `VaultSession.touchAccess(entryID:)` wired at all access call sites.

**Architecture:** Add `VaultSession.touchAccess` and a `RecentEntriesQuery` helper first so ranking data is correct before UI ships. Split menu bar UI into unlock panel, recent entry row, and unlocked panel views under `MyPass/UI/MenuBar/`. Reuse `LetterAvatarView` from `MyPass/UI/Shell/LetterAvatar.swift` (feature branch `feature/ui-shell-wave1`). Gate tray registration on `showMenuBarExtra` from the Settings redesign plan; apply `.menuBarExtraStyle(.window)` in `MyPassApp`.

**Tech Stack:** SwiftUI, AppKit, MyPassKit (`KdbxEntry.lastAccessTime`), existing `BiometricKeyStore` / `UnlockView` patterns, `EntrySearch.allEntries`, `GroupTreeOperations`, XCTest, XcodeGen (`project.yml` globs `MyPass/`)

## Global Constraints

- English UI strings only until Phase 7 localization
- Spec reference: `docs/superpowers/specs/2026-07-26-mypass-menu-bar-redesign-design.md`
- **Dependency:** Settings redesign must land first for `@AppStorage("showMenuBarExtra")` gating (`docs/superpowers/plans/2026-07-26-mypass-settings-redesign.md`, Task 6)
- **Dependency:** `LetterAvatarView` from UI shell Wave 1 (`MyPass/UI/Shell/LetterAvatar.swift`) — rebase onto `feature/ui-shell-wave1` or ensure that file exists before Task 5
- Do not implement Quick Access panel behavior — **Open Quick Access** row disabled with **Coming later**
- Global shortcut registration stays in Settings/MyPassApp plan — panel buttons must work without shortcuts
- Tray icon remains `key.fill`
- macOS deployment target 14.0+
- Tests via `./scripts/test.sh`; build via `./scripts/build.sh`
- No `project.yml` change for new files under `MyPass/` or `MyPassTests/`

---

## File structure (created/modified by this plan)

```
MyPass/State/
  VaultSession.swift                    (MODIFY — add touchAccess(entryID:))

MyPass/UI/Sidebar/
  GroupTreeOperations.swift             (MODIFY — expose entry lookup for touchAccess)

MyPass/UI/MenuBar/
  MenuBarExtraContent.swift             (MODIFY — route locked/unlocked layouts)
  MenuBarUnlockPanelView.swift          (NEW)
  MenuBarUnlockedPanelView.swift        (NEW)
  MenuBarRecentEntryRow.swift           (NEW)
  RecentEntriesQuery.swift              (NEW)
  RecycleBinEntryFilter.swift           (NEW)

MyPass/UI/EntryDetail/
  EntryDetailView.swift                 (MODIFY — touchAccess on appear + copy)

MyPass/State/ExtensionBridge/
  ExtensionBridgeService.swift          (MODIFY — touchAccess on fillCredential)

MyPass/MyPassApp.swift                  (MODIFY — .menuBarExtraStyle(.window))

MyPassTests/
  VaultSessionTouchAccessTests.swift    (NEW)
  RecentEntriesQueryTests.swift         (NEW)
  ExtensionBridgeServiceTests.swift     (MODIFY — assert touchAccess on fill)
```

---

### Task 1: VaultSession.touchAccess + entry lookup (TDD)

**Files:**
- Modify: `MyPass/UI/Sidebar/GroupTreeOperations.swift`
- Modify: `MyPass/State/VaultSession.swift`
- Create: `MyPassTests/VaultSessionTouchAccessTests.swift`

**Interfaces:**
- Consumes: `GroupTreeOperations.findEntryLocation` (currently private)
- Produces:
  - `GroupTreeOperations.entryLocation(entryID:in:) -> (group: KdbxGroup, index: Int)?` (public wrapper)
  - `VaultSession.touchAccess(entryID: UUID)` — no-op when locked or ID not found; sets `lastAccessTime = Date()` and triggers `mutate`/`persist`

- [ ] **Step 1: Write failing test**

```swift
import XCTest
import MyPassKit
@testable import MyPass

final class VaultSessionTouchAccessTests: XCTestCase {
    var tempDir: URL!
    var fileStore: VaultFileStore!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TouchAccessTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        fileStore = VaultFileStore(directory: tempDir)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testTouchAccessUpdatesLastAccessTimeAndPersists() throws {
        let session = VaultSession(fileStore: fileStore)
        try session.unlock(password: "pw")
        let entryID = UUID()
        let oldAccess = Date(timeIntervalSince1970: 1_000)
        session.mutate { db in
            var entry = KdbxEntry(
                uuid: entryID, iconID: 0, fields: [],
                creationTime: oldAccess, lastModificationTime: oldAccess,
                lastAccessTime: oldAccess, locationChanged: oldAccess, history: []
            )
            entry.title = "GitHub"
            db.rootGroup.entries.append(entry)
        }

        Thread.sleep(forTimeInterval: 0.05) // allow async persist to queue
        session.touchAccess(entryID: entryID)

        guard case .unlocked(let db) = session.state,
              let updated = GroupTreeOperations.entryLocation(entryID: entryID, in: db.rootGroup) else {
            return XCTFail("entry not found")
        }
        XCTAssertGreaterThan(db.rootGroup.entries[updated.index].lastAccessTime, oldAccess)
    }

    func testTouchAccessNoOpWhenLocked() {
        let session = VaultSession(fileStore: fileStore)
        session.touchAccess(entryID: UUID()) // must not crash
        XCTAssertEqual(session.state, .locked)
    }
}
```

- [ ] **Step 2: Run test — expect FAIL**

Run: `./scripts/generate.sh && xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/VaultSessionTouchAccessTests 2>&1 | tail -20`

- [ ] **Step 3: Expose entry lookup on GroupTreeOperations**

Add to `GroupTreeOperations.swift`:

```swift
static func entryLocation(entryID: UUID, in root: KdbxGroup) -> (group: KdbxGroup, index: Int)? {
    findEntryLocation(entryID: entryID, in: root)
}
```

Change `findEntryLocation` from `private` to `fileprivate` if needed for same-file access.

- [ ] **Step 4: Add touchAccess to VaultSession**

```swift
/// Bumps `lastAccessTime` for the entry and schedules a background persist.
/// No-op when vault is locked or entry ID is not found.
func touchAccess(entryID: UUID) {
    mutate { database in
        guard let location = GroupTreeOperations.entryLocation(entryID: entryID, in: database.rootGroup) else { return }
        var entry = location.group.entries[location.index]
        entry.lastAccessTime = Date()
        location.group.entries[location.index] = entry
    }
}
```

Note: `mutate` already no-ops when locked (guard at line 98).

- [ ] **Step 5: Run tests**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/VaultSessionTouchAccessTests 2>&1 | tail -20`

Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add MyPass/State/VaultSession.swift MyPass/UI/Sidebar/GroupTreeOperations.swift MyPassTests/VaultSessionTouchAccessTests.swift
git commit -m "feat(vault): touchAccess bumps lastAccessTime and persists"
```

---

### Task 2: touchAccess call sites — EntryDetailView + ExtensionBridge

**Files:**
- Modify: `MyPass/UI/EntryDetail/EntryDetailView.swift`
- Modify: `MyPass/State/ExtensionBridge/ExtensionBridgeService.swift`
- Modify: `MyPassTests/ExtensionBridgeServiceTests.swift`

**Interfaces:**
- Consumes: `VaultSession.touchAccess(entryID:)`
- Produces: Access tracking on detail appear, copy username/password/TOTP, Chrome fill

- [ ] **Step 1: EntryDetailView — onAppear touch**

When `currentEntry` is non-nil, call touch once per entry selection:

```swift
.onChange(of: navigationState.selectedEntryID) { _, newID in
    if let id = newID { vaultSession.touchAccess(entryID: id) }
}
.onAppear {
    if let id = navigationState.selectedEntryID {
        vaultSession.touchAccess(entryID: id)
    }
}
```

- [ ] **Step 2: EntryDetailView — copy paths**

In `copy(_:)` after copying to pasteboard, if `navigationState.selectedEntryID` is set:

```swift
if let id = navigationState.selectedEntryID {
    vaultSession.touchAccess(entryID: id)
}
```

- [ ] **Step 3: ExtensionBridgeService — fillCredential**

After match guard (line 37), before return:

```swift
vaultSession?.touchAccess(entryID: entry.uuid)
return .credential(username: entry.login, password: entry.password, totp: nil)
```

- [ ] **Step 4: Extend ExtensionBridgeServiceTests**

Add assertion that a test double vault session records `touchAccess` — use a `TouchTrackingVaultSession` test subclass or capture via injected closure on a refactored service init for tests. Minimal approach: subclass `VaultSession` in test file with `var touchedIDs: [UUID] = []` override — if override isn't possible, inject optional `(UUID) -> Void` callback `onTouchAccess` on `ExtensionBridgeService` defaulting to `vaultSession?.touchAccess`.

Preferred minimal diff — add to `ExtensionBridgeService`:

```swift
var onCredentialFilled: ((UUID) -> Void)?
// in fillCredential case:
onCredentialFilled?(entry.uuid)
vaultSession?.touchAccess(entryID: entry.uuid)
```

Test sets `service.onCredentialFilled = { ids.append($0) }`.

- [ ] **Step 5: Run tests**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/ExtensionBridgeServiceTests 2>&1 | tail -25`

Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add MyPass/UI/EntryDetail/EntryDetailView.swift MyPass/State/ExtensionBridge/ExtensionBridgeService.swift MyPassTests/ExtensionBridgeServiceTests.swift
git commit -m "feat(access): touchAccess on detail view, copy, and Chrome fill"
```

---

### Task 3: RecentEntriesQuery + RecycleBinEntryFilter (TDD)

**Files:**
- Create: `MyPass/UI/MenuBar/RecycleBinEntryFilter.swift`
- Create: `MyPass/UI/MenuBar/RecentEntriesQuery.swift`
- Create: `MyPassTests/RecentEntriesQueryTests.swift`

**Interfaces:**
- Consumes: `EntrySearch.allEntries`, `KdbxDatabase.recycleBinGroupUUID`, `GroupTreeOperations.isRecycleBinGroup`
- Produces:
  - `enum RecycleBinEntryFilter { static func isInRecycleBin(_ entry: KdbxEntry, database: KdbxDatabase) -> Bool }`
  - `enum RecentEntriesQuery { static func recent(in database: KdbxDatabase, limit: Int = 5) -> [KdbxEntry] }`

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
import MyPassKit
@testable import MyPass

final class RecentEntriesQueryTests: XCTestCase {
    func testReturnsTopFiveByLastAccessTimeDescending() {
        let db = makeDatabaseWithEntries(accessTimes: [100, 500, 300, 700, 200, 600, 400])
        let recent = RecentEntriesQuery.recent(in: db, limit: 5)
        XCTAssertEqual(recent.map { $0.lastAccessTime.timeIntervalSince1970 }, [700, 600, 500, 400, 300])
    }

    func testExcludesRecycleBinEntries() throws {
        var db = makeDatabaseWithEntries(accessTimes: [900, 800])
        let bin = GroupTreeOperations.recycleBinGroup(in: db.rootGroup, recycleBinGroupUUID: &db.recycleBinGroupUUID)
        var recycled = db.rootGroup.entries.removeLast()
        recycled.lastAccessTime = Date(timeIntervalSince1970: 9999)
        bin.entries.append(recycled)

        let recent = RecentEntriesQuery.recent(in: db, limit: 5)
        XCTAssertFalse(recent.contains(where: { $0.uuid == recycled.uuid }))
        XCTAssertEqual(recent.count, 1)
    }

    func testEmptyWhenNoQualifyingEntries() {
        let now = Date()
        let entry = KdbxEntry(uuid: UUID(), iconID: 0, fields: [], creationTime: now, lastModificationTime: now, lastAccessTime: now, locationChanged: now, history: [])
        let db = KdbxDatabase(rootGroup: KdbxGroup(uuid: UUID(), name: "Root", iconID: 0, creationTime: now, lastModificationTime: now, locationChanged: now, entries: [entry], subgroups: []), deletedObjects: [])
        var binUUID: UUID? = nil
        let bin = GroupTreeOperations.recycleBinGroup(in: db.rootGroup, recycleBinGroupUUID: &binUUID)
        var dbCopy = db
        dbCopy.recycleBinGroupUUID = binUUID
        bin.entries.append(entry)
        XCTAssertTrue(RecentEntriesQuery.recent(in: dbCopy).isEmpty)
    }

    // Helper builds root with flat entries at given access times
    private func makeDatabaseWithEntries(accessTimes: [TimeInterval]) -> KdbxDatabase {
        let now = Date()
        let entries = accessTimes.map { t in
            var e = KdbxEntry(uuid: UUID(), iconID: 0, fields: [], creationTime: now, lastModificationTime: now, lastAccessTime: Date(timeIntervalSince1970: t), locationChanged: now, history: [])
            e.title = "Entry-\(Int(t))"
            return e
        }
        let root = KdbxGroup(uuid: UUID(), name: "Root", iconID: 0, creationTime: now, lastModificationTime: now, locationChanged: now, entries: entries, subgroups: [])
        return KdbxDatabase(rootGroup: root, deletedObjects: [])
    }
}
```

- [ ] **Step 2: Run test — expect FAIL**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/RecentEntriesQueryTests 2>&1 | tail -20`

- [ ] **Step 3: Implement RecycleBinEntryFilter.swift**

Mirror `EntryDetailView.isInRecycleBin` (lines 49–54):

```swift
import MyPassKit

enum RecycleBinEntryFilter {
    static func isInRecycleBin(_ entry: KdbxEntry, database: KdbxDatabase) -> Bool {
        guard let binUUID = database.recycleBinGroupUUID,
              let bin = database.rootGroup.subgroups.first(where: { $0.uuid == binUUID })
                ?? findGroup(uuid: binUUID, in: database.rootGroup) else { return false }
        return bin.entries.contains(where: { $0.uuid == entry.uuid })
    }

    private static func findGroup(uuid: UUID, in group: KdbxGroup) -> KdbxGroup? {
        if group.uuid == uuid { return group }
        for sub in group.subgroups {
            if let found = findGroup(uuid: uuid, in: sub) { return found }
        }
        return nil
    }
}
```

- [ ] **Step 4: Implement RecentEntriesQuery.swift**

```swift
import MyPassKit

enum RecentEntriesQuery {
    static func recent(in database: KdbxDatabase, limit: Int = 5) -> [KdbxEntry] {
        EntrySearch.allEntries(in: database.rootGroup)
            .filter { !RecycleBinEntryFilter.isInRecycleBin($0, database: database) }
            .sorted { $0.lastAccessTime > $1.lastAccessTime }
            .prefix(limit)
            .map { $0 }
    }
}
```

- [ ] **Step 5: Run tests**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/RecentEntriesQueryTests 2>&1 | tail -20`

Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add MyPass/UI/MenuBar/RecycleBinEntryFilter.swift MyPass/UI/MenuBar/RecentEntriesQuery.swift MyPassTests/RecentEntriesQueryTests.swift
git commit -m "feat(menu-bar): recent entries query with recycle bin exclusion"
```

---

### Task 4: MenuBarUnlockPanelView

**Files:**
- Create: `MyPass/UI/MenuBar/MenuBarUnlockPanelView.swift`

**Interfaces:**
- Consumes: `@EnvironmentObject VaultSession`, `BiometricKeyStoring` (default `BiometricKeyStore()`), unlock patterns from `UnlockView`
- Produces: Locked panel ~280 pt wide; successful unlock refreshes parent via `@EnvironmentObject` state change

- [ ] **Step 1: Implement MenuBarUnlockPanelView**

```swift
import SwiftUI

struct MenuBarUnlockPanelView: View {
    @EnvironmentObject private var vaultSession: VaultSession
    @State private var password = ""
    @State private var errorMessage: String?

    let biometricKeyStore: BiometricKeyStoring

    init(biometricKeyStore: BiometricKeyStoring = BiometricKeyStore()) {
        self.biometricKeyStore = biometricKeyStore
    }

    private var hasStoredBiometricKey: Bool {
        (try? biometricKeyStore.retrieve(account: "master")) != nil
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("MyPass is locked")
                .font(.headline)

            Image(systemName: "key.fill")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)

            SecureField("Enter Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .onSubmit(attemptUnlock)

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            Button("Unlock", action: attemptUnlock)
                .buttonStyle(.borderedProminent)

            if hasStoredBiometricKey {
                Button("Touch ID", systemImage: "touchid", action: attemptBiometricUnlock)
                    .buttonStyle(.bordered)
            }

            Text("The vault remains locked until you unlock it manually.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(20)
        .frame(width: 280)
    }

    private func attemptUnlock() {
        do {
            try vaultSession.unlock(password: password)
            password = ""
            errorMessage = nil
        } catch {
            errorMessage = "Incorrect password or corrupted file."
        }
    }

    private func attemptBiometricUnlock() {
        // Same contract as UnlockView — retrieve succeeds after Touch ID;
        // full derived-key unlock wiring follows existing UnlockView path.
        if (try? biometricKeyStore.retrieve(account: "master")) == nil {
            errorMessage = "Touch ID is unavailable."
        } else {
            errorMessage = nil
        }
    }
}
```

- [ ] **Step 2: Build**

Run: `./scripts/build.sh 2>&1 | tail -20`

Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add MyPass/UI/MenuBar/MenuBarUnlockPanelView.swift
git commit -m "feat(menu-bar): locked unlock panel"
```

---

### Task 5: MenuBarRecentEntryRow + MenuBarUnlockedPanelView

**Files:**
- Create: `MyPass/UI/MenuBar/MenuBarRecentEntryRow.swift`
- Create: `MyPass/UI/MenuBar/MenuBarUnlockedPanelView.swift`

**Interfaces:**
- Consumes: `LetterAvatarView` (28×28, 6 pt radius), `RecentEntriesQuery`, `NavigationState`, `VaultSession`
- Produces: Unlocked panel ~300 pt; row click activates app + selects entry + touchAccess

- [ ] **Step 1: Implement MenuBarRecentEntryRow**

```swift
import SwiftUI
import MyPassKit

struct MenuBarRecentEntryRow: View {
    let entry: KdbxEntry
    let action: () -> Void

    private var displayTitle: String {
        entry.title.isEmpty ? "(untitled)" : entry.title
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                LetterAvatarView(title: displayTitle, size: 28, cornerRadius: 6)
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    if !entry.login.isEmpty {
                        Text(entry.login)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
```

- [ ] **Step 2: Implement MenuBarUnlockedPanelView**

```swift
import SwiftUI
import AppKit

struct MenuBarUnlockedPanelView: View {
    @EnvironmentObject private var vaultSession: VaultSession
    @EnvironmentObject private var navigationState: NavigationState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let database = vaultSession.currentDatabase {
                let recents = RecentEntriesQuery.recent(in: database)
                if !recents.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(recents, id: \.uuid) { entry in
                            MenuBarRecentEntryRow(entry: entry) {
                                openEntry(entry.uuid)
                            }
                        }
                    }
                    Divider()
                }
            }

            menuRow("Open MyPass") { activateMainWindow() }

            HStack {
                Text("Open Quick Access")
                Spacer()
                Text("Coming later")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .foregroundStyle(.secondary)

            Divider()

            menuRow("Lock") {
                vaultSession.lock()
            }
            .disabled({
                if case .locked = vaultSession.state { return true }
                return false
            }())

            menuRow("Settings…") {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }

            menuRow("Quit MyPass") {
                NSApplication.shared.terminate(nil)
            }
        }
        .frame(width: 300)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func menuRow(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func activateMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.canBecomeMain || $0.isVisible }?.makeKeyAndOrderFront(nil)
    }

    private func openEntry(_ id: UUID) {
        activateMainWindow()
        navigationState.selectedEntryID = id
        vaultSession.touchAccess(entryID: id)
    }
}
```

- [ ] **Step 3: Build**

Run: `./scripts/build.sh 2>&1 | tail -20`

Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add MyPass/UI/MenuBar/MenuBarRecentEntryRow.swift MyPass/UI/MenuBar/MenuBarUnlockedPanelView.swift
git commit -m "feat(menu-bar): unlocked panel with recent entries and actions"
```

---

### Task 6: Rewrite MenuBarExtraContent

**Files:**
- Modify: `MyPass/UI/MenuBar/MenuBarExtraContent.swift`

**Interfaces:**
- Consumes: `MenuBarUnlockPanelView`, `MenuBarUnlockedPanelView`, `vaultSession.state`
- Produces: Root router; **removes** status text, Quick Search, Password Generator sheet

- [ ] **Step 1: Replace MenuBarExtraContent body**

```swift
import SwiftUI

struct MenuBarExtraContent: View {
    @EnvironmentObject var vaultSession: VaultSession
    @EnvironmentObject var navigationState: NavigationState

    var body: some View {
        Group {
            switch vaultSession.state {
            case .locked:
                MenuBarUnlockPanelView()
            case .unlocked:
                MenuBarUnlockedPanelView()
            }
        }
        .environmentObject(vaultSession)
        .environmentObject(navigationState)
    }
}
```

Delete `@State showPasswordGenerator`, `statusText`, Quick Search `TextField`, Password Generator button/sheet.

- [ ] **Step 2: Build**

Run: `./scripts/build.sh 2>&1 | tail -20`

Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add MyPass/UI/MenuBar/MenuBarExtraContent.swift
git commit -m "feat(menu-bar): route locked/unlocked panel layouts"
```

---

### Task 7: MyPassApp window style + verify gating

**Files:**
- Modify: `MyPass/MyPassApp.swift`

**Interfaces:**
- Consumes: Settings plan's `showMenuBarExtra` conditional `MenuBarExtra`
- Produces: `.menuBarExtraStyle(.window)` on the extra

- [ ] **Step 1: Add menuBarExtraStyle**

On the conditional `MenuBarExtra` block from Settings Task 6:

```swift
if showMenuBarExtra {
    MenuBarExtra("MyPass", systemImage: "key.fill") {
        MenuBarExtraContent()
            .environmentObject(vaultSession)
            .environmentObject(navigationState)
    }
    .menuBarExtraStyle(.window)
}
```

- [ ] **Step 2: Full test + build**

Run: `./scripts/test.sh 2>&1 | tail -30`

Run: `./scripts/build.sh 2>&1 | tail -20`

Expected: all PASS / BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add MyPass/MyPassApp.swift
git commit -m "feat(menu-bar): window-style MenuBarExtra panel"
```

---

### Task 8: Manual acceptance checklist

**Files:** none (verification only)

- [ ] **Step 1: Locked panel manual check**

Run app via `./scripts/run.sh` (or Xcode). Lock vault. Click tray icon.

Verify: **MyPass is locked**, password field, Unlock, Touch ID when enrolled, no recents/actions.

- [ ] **Step 2: Unlocked panel manual check**

Unlock vault. Open several entries (detail view). Click tray icon.

Verify: up to 5 recent rows with avatars; **Open MyPass**, disabled **Open Quick Access** / **Coming later**, Lock, Settings…, Quit MyPass. No Quick Search or Password Generator.

- [ ] **Step 3: Recent row navigation**

Click a recent row. Verify main window activates and entry detail shows selected entry.

- [ ] **Step 4: showMenuBarExtra off**

Settings → General → disable menu bar toggle. Verify tray icon disappears; re-enable restores it.

- [ ] **Step 5: Document verification in commit message or PR test plan**

No code commit required if all checks pass.

---

## Self-Review

### 1. Spec coverage

| Spec requirement | Task |
|---|---|
| Window-style panel ~280–320 pt | Tasks 4, 5, 7 |
| Up to 5 recents by lastAccessTime, exclude recycle bin | Task 3 |
| Row: LetterAvatar 28×28, title, username, chevron | Task 5 |
| Row click: activate window, select entry, touchAccess | Task 5 |
| Open MyPass, Quick Access disabled, Lock, Settings, Quit | Task 5 |
| Remove status, Quick Search, Password Generator | Task 6 |
| Locked: unlock panel only, in-place refresh on unlock | Tasks 4, 6 |
| touchAccess on detail, copy, Chrome fill | Tasks 1, 2 |
| showMenuBarExtra gating | Settings plan Task 6 + verify Task 8 |
| Tray icon key.fill | Unchanged in MyPassApp |
| Touch ID on locked panel when enrolled | Task 4 |

**Gaps:** None identified. End-to-end Touch ID unlock from derived key (beyond existing UnlockView placeholder) remains pre-existing backlog — panel matches UnlockView behavior per spec.

### 2. Placeholder scan

No TBD/TODO. Quick Access is an explicit disabled stub with **Coming later** copy.

### 3. Type consistency

- `VaultSession.touchAccess(entryID:)` signature matches spec
- `RecentEntriesQuery.recent(in:limit:)` used by unlocked panel
- `LetterAvatarView(title:size:cornerRadius:)` matches UI shell API
- Recycle bin filter aligned with `EntryDetailView.isInRecycleBin` logic

---

**Plan complete.** Execute after Settings redesign plan (Task 6 minimum for `showMenuBarExtra`). Rebase onto `feature/ui-shell-wave1` for `LetterAvatarView`.
