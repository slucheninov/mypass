# MyPass Entry / Sidebar Polish Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire live smart-category counts and vault-wide filtering in the sidebar, move New/Edit/Chrome-proposal flows into the detail column (no entry-edit sheets), polish EntryEditView fields (group picker, OTP reveal, title-from-domain), and restyle History as an Apple Passwords–like modal over real `entry.history` only.

**Architecture:** Introduce pure `SmartCategoryCounts` + `EntryCategoryFilter` modules with XCTest coverage first, then wire `NavigationState` category/group mode helpers and live sidebar counts. Add `DetailPresentation` on `NavigationState` so `ContentView` routes the detail column between browse and edit/create. Refactor `EntryEditView` save logic into testable helpers; add `GroupPickerView` excluding Recycle Bin. Restyle `HistoryView` with `NavigationStack`, `HistoryVersionDetailView`, and `EntryHistoryOperations.clearHistory`.

**Tech Stack:** SwiftUI macOS app, MyPassKit KDBX, existing VaultSession/NavigationState, XCTest, XcodeGen (`project.yml` globs `MyPass/`), `./scripts/test.sh` / `./scripts/build.sh`

## Global Constraints
- UI strings English only
- Spec path: docs/superpowers/specs/2026-07-26-mypass-entry-sidebar-polish-design.md
- Favorites stay stub (count 0, empty filter) until favorite field exists
- Security category: count "—", selection does not change list filter
- No entry-edit sheets; detail-column edit only
- History stays sheet; real entry.history only

---

## File structure (created/modified by this plan)

```
MyPass/UI/Shell/
  SmartCategory.swift                 (MODIFY — remove placeholderCount; add countDisplay(for:database:))

MyPass/UI/EntryList/
  SmartCategoryCounts.swift           (NEW — live count computation)
  EntryCategoryFilter.swift           (NEW — vault-wide category predicates)
  EntryListView.swift                 (MODIFY — category filter in displayedEntries; remove create sheet)

MyPass/UI/Sidebar/
  GroupSidebarView.swift              (MODIFY — live counts, Groups + button, category selection helpers)

MyPass/State/
  NavigationState.swift               (MODIFY — isCategoryMode, activeCategoryFilter, detailPresentation)

MyPass/ContentView.swift              (MODIFY — detail column routing; remove proposal sheet)

MyPass/UI/EntryDetail/
  EntryDetailView.swift               (MODIFY — browse vs edit routing; remove edit sheet)
  EntryEditView.swift                 (MODIFY — group picker, OTP reveal, toolbar Cancel/Save, save helpers)
  EntryEditSaveLogic.swift            (NEW — testable title/OTP resolution)
  GroupPickerView.swift               (NEW — tree picker excluding Recycle Bin)
  HistoryView.swift                   (MODIFY — Apple Passwords list chrome, empty state, clear history)
  HistoryVersionDetailView.swift      (NEW — version snapshot detail + Restore)
  EntryHistoryOperations.swift        (MODIFY — move from HistoryView.swift; add clearHistory)

MyPassTests/
  SmartCategoryCountsTests.swift      (NEW)
  EntryCategoryFilterTests.swift      (NEW)
  EntryEditSaveLogicTests.swift       (NEW)
  EntryHistoryOperationsTests.swift   (MODIFY — clearHistory test)
  SmartCategoryTests.swift            (MODIFY — replace placeholderCount tests with countDisplay)
  NavigationStateCategoryModeTests.swift (NEW)
```

Reuse existing `MyPass/UI/MenuBar/RecycleBinEntryFilter.swift` for bin membership checks in counts/filters.

---

### Task 1: SmartCategoryCounts + EntryCategoryFilter (TDD)

**Files:**
- Create: `MyPass/UI/EntryList/SmartCategoryCounts.swift`
- Create: `MyPass/UI/EntryList/EntryCategoryFilter.swift`
- Create: `MyPassTests/SmartCategoryCountsTests.swift`
- Create: `MyPassTests/EntryCategoryFilterTests.swift`
- Modify: `MyPass/UI/Shell/SmartCategory.swift`
- Modify: `MyPassTests/SmartCategoryTests.swift`

**Interfaces:**
- Consumes: `EntrySearch.allEntries(in:)`, `RecycleBinEntryFilter.isInRecycleBin(_:database:)`, `KdbxEntry.totpSecretBase32`
- Produces:
  - `enum SmartCategoryCounts { static func countDisplay(for category: SmartCategory, database: KdbxDatabase) -> String }`
  - `enum EntryCategoryFilter { static func entries(for category: SmartCategory, in database: KdbxDatabase) -> [KdbxEntry] }`
  - `SmartCategory.countDisplay(for database: KdbxDatabase) -> String` (delegates to `SmartCategoryCounts`)

- [ ] **Step 1: Write failing SmartCategoryCounts tests**

```swift
import XCTest
import MyPassKit
@testable import MyPass

final class SmartCategoryCountsTests: XCTestCase {
    private func makeEntry(title: String, totp: String? = nil) -> KdbxEntry {
        let now = Date()
        var entry = KdbxEntry(
            uuid: UUID(), iconID: 0, fields: [],
            creationTime: now, lastModificationTime: now, lastAccessTime: now, locationChanged: now, history: []
        )
        entry.title = title
        entry.totpSecretBase32 = totp
        return entry
    }

    private func makeDatabase(rootEntries: [KdbxEntry] = [], binEntries: [KdbxEntry] = []) -> KdbxDatabase {
        let now = Date()
        let root = KdbxGroup(
            uuid: UUID(), name: "Root", iconID: 0,
            creationTime: now, lastModificationTime: now, locationChanged: now,
            entries: rootEntries, subgroups: []
        )
        var db = KdbxDatabase(rootGroup: root, deletedObjects: [])
        let bin = GroupTreeOperations.recycleBinGroup(in: root, recycleBinGroupUUID: &db.recycleBinGroupUUID)
        bin.entries.append(contentsOf: binEntries)
        return db
    }

    func testAllCountExcludesRecycleBin() {
        let db = makeDatabase(
            rootEntries: [makeEntry(title: "A"), makeEntry(title: "B")],
            binEntries: [makeEntry(title: "Deleted")]
        )
        XCTAssertEqual(SmartCategoryCounts.countDisplay(for: .all, database: db), "2")
    }

    func testCodesCountNonEmptyTOTP() {
        let db = makeDatabase(rootEntries: [
            makeEntry(title: "WithOTP", totp: "JBSWY3DPEHPK3PXP"),
            makeEntry(title: "NoOTP")
        ])
        XCTAssertEqual(SmartCategoryCounts.countDisplay(for: .codes, database: db), "1")
    }

    func testDeletedCountBinOnly() {
        let db = makeDatabase(
            rootEntries: [makeEntry(title: "Live")],
            binEntries: [makeEntry(title: "D1"), makeEntry(title: "D2")]
        )
        XCTAssertEqual(SmartCategoryCounts.countDisplay(for: .deleted, database: db), "2")
    }

    func testFavoritesAlwaysZero() {
        let db = makeDatabase(rootEntries: [makeEntry(title: "A"), makeEntry(title: "B")])
        XCTAssertEqual(SmartCategoryCounts.countDisplay(for: .favorites, database: db), "0")
    }

    func testSecurityAlwaysEmDash() {
        let db = makeDatabase(rootEntries: [makeEntry(title: "A")])
        XCTAssertEqual(SmartCategoryCounts.countDisplay(for: .security, database: db), "—")
    }
}
```

- [ ] **Step 2: Write failing EntryCategoryFilter tests**

```swift
import XCTest
import MyPassKit
@testable import MyPass

final class EntryCategoryFilterTests: XCTestCase {
    private func makeEntry(title: String, totp: String? = nil) -> KdbxEntry {
        let now = Date()
        var entry = KdbxEntry(
            uuid: UUID(), iconID: 0, fields: [],
            creationTime: now, lastModificationTime: now, lastAccessTime: now, locationChanged: now, history: []
        )
        entry.title = title
        entry.totpSecretBase32 = totp
        return entry
    }

    private func makeDatabase(rootEntries: [KdbxEntry] = [], binEntries: [KdbxEntry] = []) -> KdbxDatabase {
        let now = Date()
        let root = KdbxGroup(
            uuid: UUID(), name: "Root", iconID: 0,
            creationTime: now, lastModificationTime: now, locationChanged: now,
            entries: rootEntries, subgroups: []
        )
        var db = KdbxDatabase(rootGroup: root, deletedObjects: [])
        let bin = GroupTreeOperations.recycleBinGroup(in: root, recycleBinGroupUUID: &db.recycleBinGroupUUID)
        bin.entries.append(contentsOf: binEntries)
        return db
    }

    func testAllFilterExcludesBin() {
        let live = makeEntry(title: "Live")
        let deleted = makeEntry(title: "Deleted")
        let db = makeDatabase(rootEntries: [live], binEntries: [deleted])
        let result = EntryCategoryFilter.entries(for: .all, in: db)
        XCTAssertEqual(result.map(\.title), ["Live"])
    }

    func testCodesFilterNonEmptyTOTP() {
        let withOTP = makeEntry(title: "OTP", totp: "SECRET")
        let db = makeDatabase(rootEntries: [withOTP, makeEntry(title: "Plain")])
        XCTAssertEqual(EntryCategoryFilter.entries(for: .codes, in: db).map(\.title), ["OTP"])
    }

    func testDeletedFilterBinOnly() {
        let deleted = makeEntry(title: "Bin")
        let db = makeDatabase(rootEntries: [makeEntry(title: "Live")], binEntries: [deleted])
        XCTAssertEqual(EntryCategoryFilter.entries(for: .deleted, in: db).map(\.title), ["Bin"])
    }

    func testFavoritesFilterEmptyUntilFieldExists() {
        let db = makeDatabase(rootEntries: [makeEntry(title: "A"), makeEntry(title: "B")])
        XCTAssertTrue(EntryCategoryFilter.entries(for: .favorites, in: db).isEmpty)
    }

    func testSearchIntersectionViaEntrySearch() {
        let db = makeDatabase(rootEntries: [
            makeEntry(title: "GitHub"),
            makeEntry(title: "GitLab")
        ])
        let filtered = EntryCategoryFilter.entries(for: .all, in: db)
            .filter { EntrySearch.matches(entry: $0, query: "hub") }
        XCTAssertEqual(filtered.map(\.title), ["GitHub"])
    }
}
```

- [ ] **Step 3: Run tests — expect FAIL**

Run: `./scripts/generate.sh && xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/SmartCategoryCountsTests -only-testing:MyPassTests/EntryCategoryFilterTests 2>&1 | tail -25`

- [ ] **Step 4: Implement SmartCategoryCounts.swift**

```swift
import Foundation
import MyPassKit

enum SmartCategoryCounts {
    static func countDisplay(for category: SmartCategory, database: KdbxDatabase) -> String {
        switch category {
        case .security:
            return "—"
        case .favorites:
            return "0"
        case .all:
            return String(allCount(in: database))
        case .codes:
            return String(codesCount(in: database))
        case .deleted:
            return String(deletedCount(in: database))
        }
    }

    private static func allEntries(in database: KdbxDatabase) -> [KdbxEntry] {
        EntrySearch.allEntries(in: database.rootGroup)
    }

    private static func allCount(in database: KdbxDatabase) -> Int {
        allEntries(in: database).filter { !RecycleBinEntryFilter.isInRecycleBin($0, database: database) }.count
    }

    private static func codesCount(in database: KdbxDatabase) -> Int {
        allEntries(in: database).filter {
            guard let secret = $0.totpSecretBase32 else { return false }
            return !secret.isEmpty
        }.count
    }

    private static func deletedCount(in database: KdbxDatabase) -> Int {
        guard let binUUID = database.recycleBinGroupUUID,
              let bin = database.rootGroup.subgroups.first(where: { $0.uuid == binUUID }) else { return 0 }
        return bin.entries.count
    }
}
```

- [ ] **Step 5: Implement EntryCategoryFilter.swift**

```swift
import Foundation
import MyPassKit

enum EntryCategoryFilter {
    static func entries(for category: SmartCategory, in database: KdbxDatabase) -> [KdbxEntry] {
        let all = EntrySearch.allEntries(in: database.rootGroup)
        switch category {
        case .all:
            return all.filter { !RecycleBinEntryFilter.isInRecycleBin($0, database: database) }
        case .favorites:
            return [] // stub until KDBX favorite field exists
        case .codes:
            return all.filter {
                guard let secret = $0.totpSecretBase32 else { return false }
                return !secret.isEmpty
            }
        case .security:
            return all // callers must not use Security for filtering; kept for completeness
        case .deleted:
            guard let binUUID = database.recycleBinGroupUUID,
                  let bin = database.rootGroup.subgroups.first(where: { $0.uuid == binUUID }) else { return [] }
            return bin.entries
        }
    }
}
```

- [ ] **Step 6: Update SmartCategory.swift — replace placeholderCount**

Remove `placeholderCount` property. Add:

```swift
func countDisplay(for database: KdbxDatabase) -> String {
    SmartCategoryCounts.countDisplay(for: self, database: database)
}
```

- [ ] **Step 7: Update SmartCategoryTests.swift**

Replace `testPlaceholderCounts` with:

```swift
func testCountDisplayDelegatesToSmartCategoryCounts() throws {
    let now = Date()
    var entry = KdbxEntry(
        uuid: UUID(), iconID: 0, fields: [],
        creationTime: now, lastModificationTime: now, lastAccessTime: now, locationChanged: now, history: []
    )
    entry.title = "One"
    let root = KdbxGroup(
        uuid: UUID(), name: "Root", iconID: 0,
        creationTime: now, lastModificationTime: now, locationChanged: now,
        entries: [entry], subgroups: []
    )
    let db = KdbxDatabase(rootGroup: root, deletedObjects: [])
    XCTAssertEqual(SmartCategory.all.countDisplay(for: db), "1")
    XCTAssertEqual(SmartCategory.security.countDisplay(for: db), "—")
}
```

- [ ] **Step 8: Run tests — expect PASS**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/SmartCategoryCountsTests -only-testing:MyPassTests/EntryCategoryFilterTests -only-testing:MyPassTests/SmartCategoryTests 2>&1 | tail -25`

- [ ] **Step 9: Commit**

```bash
git add MyPass/UI/EntryList/SmartCategoryCounts.swift MyPass/UI/EntryList/EntryCategoryFilter.swift MyPass/UI/Shell/SmartCategory.swift MyPassTests/SmartCategoryCountsTests.swift MyPassTests/EntryCategoryFilterTests.swift MyPassTests/SmartCategoryTests.swift
git commit -m "feat(categories): live SmartCategoryCounts and EntryCategoryFilter"
```

---

### Task 2: NavigationState category mode + wire sidebar counts and list filtering

**Files:**
- Modify: `MyPass/State/NavigationState.swift`
- Modify: `MyPass/UI/Sidebar/GroupSidebarView.swift`
- Modify: `MyPass/UI/EntryList/EntryListView.swift`
- Create: `MyPassTests/NavigationStateCategoryModeTests.swift`

**Interfaces:**
- Consumes: `SmartCategoryCounts`, `EntryCategoryFilter`, `EntrySearch.matches`, `VaultSession.currentDatabase`
- Produces:
  - `@Published var isCategoryMode: Bool`
  - `@Published var activeCategoryFilter: SmartCategory` (filter applied when `isCategoryMode`; Security selection does **not** update this)
  - `func selectSmartCategory(_ category: SmartCategory)`
  - `func exitCategoryModeForGroupSelection()`
  - `GroupSidebarView` passes `database` for live `category.countDisplay(for: database)`
  - `EntryListView.displayedEntries` branches on `isCategoryMode`

- [ ] **Step 1: Write failing NavigationStateCategoryModeTests**

```swift
import XCTest
@testable import MyPass

final class NavigationStateCategoryModeTests: XCTestCase {
    func testSelectSmartCategoryEntersCategoryMode() {
        let state = NavigationState()
        state.selectSmartCategory(.codes)
        XCTAssertTrue(state.isCategoryMode)
        XCTAssertEqual(state.selectedSmartCategory, .codes)
        XCTAssertEqual(state.activeCategoryFilter, .codes)
    }

    func testSelectSecurityDoesNotChangeActiveCategoryFilter() {
        let state = NavigationState()
        state.selectSmartCategory(.all)
        state.selectSmartCategory(.security)
        XCTAssertEqual(state.selectedSmartCategory, .security)
        XCTAssertEqual(state.activeCategoryFilter, .all)
    }

    func testGroupSelectionExitsCategoryMode() {
        let state = NavigationState()
        state.selectSmartCategory(.deleted)
        state.exitCategoryModeForGroupSelection()
        XCTAssertFalse(state.isCategoryMode)
        XCTAssertEqual(state.selectedSmartCategory, .all)
    }
}
```

- [ ] **Step 2: Run test — expect FAIL**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/NavigationStateCategoryModeTests 2>&1 | tail -20`

- [ ] **Step 3: Extend NavigationState.swift**

```swift
@Published var isCategoryMode: Bool = false
@Published var activeCategoryFilter: SmartCategory = .all

func selectSmartCategory(_ category: SmartCategory) {
    selectedSmartCategory = category
    isCategoryMode = true
    if category != .security {
        activeCategoryFilter = category
    }
}

func exitCategoryModeForGroupSelection() {
    isCategoryMode = false
    selectedSmartCategory = .all
}
```

- [ ] **Step 4: Update GroupSidebarView — live counts + selectSmartCategory**

Add parameters or read database from environment:

```swift
@EnvironmentObject var vaultSession: VaultSession
```

In category row action:

```swift
navigationState.selectSmartCategory(category)
```

Replace `category.placeholderCount` in `SmartCategorySidebarRow` with a `countText: String` parameter. Parent computes:

```swift
private func countText(for category: SmartCategory) -> String {
    guard let database = vaultSession.currentDatabase else { return "0" }
    return category.countDisplay(for: database)
}
```

Update `onChange(of: navigationState.selectedGroupID)`:

```swift
.onChange(of: navigationState.selectedGroupID) { _, _ in
    navigationState.exitCategoryModeForGroupSelection()
}
```

- [ ] **Step 5: Update EntryListView.displayedEntries**

```swift
private var displayedEntries: [KdbxEntry] {
    if navigationState.isCategoryMode, let database = vaultSession.currentDatabase {
        let scoped = EntryCategoryFilter.entries(for: navigationState.activeCategoryFilter, in: database)
        if navigationState.searchText.isEmpty {
            return scoped
        }
        return scoped.filter { EntrySearch.matches(entry: $0, query: navigationState.searchText) }
    }
    if navigationState.searchText.isEmpty {
        return currentGroup.entries
    }
    return EntrySearch.entries(in: rootGroup, matching: navigationState.searchText)
}

private var headerTitle: String {
    if navigationState.isCategoryMode {
        return navigationState.selectedSmartCategory.title
    }
    return currentGroup.name
}
```

- [ ] **Step 6: Run tests — expect PASS**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/NavigationStateCategoryModeTests -only-testing:MyPassTests/EntryCategoryFilterTests 2>&1 | tail -25`

- [ ] **Step 7: Build**

Run: `./scripts/build.sh 2>&1 | tail -15`

Expected: BUILD SUCCEEDED

- [ ] **Step 8: Commit**

```bash
git add MyPass/State/NavigationState.swift MyPass/UI/Sidebar/GroupSidebarView.swift MyPass/UI/EntryList/EntryListView.swift MyPassTests/NavigationStateCategoryModeTests.swift
git commit -m "feat(sidebar): category mode, live counts, vault-wide list filter"
```

---

### Task 3: Groups header + button

**Files:**
- Modify: `MyPass/UI/Sidebar/GroupSidebarView.swift`

**Interfaces:**
- Consumes: `GroupTreeOperations.addSubgroup(named:to:)`, `GroupTreeOperations.isRecycleBinGroup`, `vaultSession.mutate`, `navigationState.selectedGroupID`
- Produces: Trailing **+** on **Groups** section header; creates `"New Group"` under selected non-bin group or root; selects new group

- [ ] **Step 1: Extend SidebarSectionHeader with optional trailing action**

```swift
private struct SidebarSectionHeader: View {
    let title: String
    var trailing: (() -> AnyView)? = nil

    var body: some View {
        HStack {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            if let trailing { trailing() }
        }
    }
}
```

For Groups section header:

```swift
} header: {
    SidebarSectionHeader(title: "Groups") {
        AnyView(
            Button {
                addSubgroupFromHeader()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .help("New Group")
        )
    }
}
```

- [ ] **Step 2: Implement addSubgroupFromHeader()**

```swift
private func addSubgroupFromHeader() {
    vaultSession.mutate { database in
        let parent: KdbxGroup
        if let selectedID = navigationState.selectedGroupID,
           let selected = findGroup(uuid: selectedID, in: database.rootGroup),
           !GroupTreeOperations.isRecycleBinGroup(selected) {
            parent = selected
        } else {
            parent = database.rootGroup
        }
        let created = GroupTreeOperations.addSubgroup(named: "New Group", to: parent)
        DispatchQueue.main.async {
            navigationState.selectedGroupID = created.uuid
            navigationState.exitCategoryModeForGroupSelection()
        }
    }
}

private func findGroup(uuid: UUID, in group: KdbxGroup) -> KdbxGroup? {
    if group.uuid == uuid { return group }
    for sub in group.subgroups {
        if let found = findGroup(uuid: uuid, in: sub) { return found }
    }
    return nil
}
```

Note: `mutate` closure should stay synchronous; set `selectedGroupID` after mutate returns on main:

```swift
private func addSubgroupFromHeader() {
    var newGroupID: UUID?
    vaultSession.mutate { database in
        let parent: KdbxGroup = /* same parent logic */
        let created = GroupTreeOperations.addSubgroup(named: "New Group", to: parent)
        newGroupID = created.uuid
    }
    if let newGroupID {
        navigationState.selectedGroupID = newGroupID
        navigationState.exitCategoryModeForGroupSelection()
    }
}
```

- [ ] **Step 3: Build**

Run: `./scripts/build.sh 2>&1 | tail -15`

- [ ] **Step 4: Commit**

```bash
git add MyPass/UI/Sidebar/GroupSidebarView.swift
git commit -m "feat(sidebar): Groups header + creates New Group under selection"
```

---

### Task 4: DetailPresentation on NavigationState + detail-column routing

**Files:**
- Modify: `MyPass/State/NavigationState.swift`
- Modify: `MyPass/ContentView.swift`
- Modify: `MyPass/UI/EntryDetail/EntryDetailView.swift`
- Modify: `MyPass/UI/EntryList/EntryListView.swift`

**Interfaces:**
- Consumes: `PendingSaveProposal`, `VaultSession.mutate`, existing `replaceEntry` / `addEntry` patterns
- Produces:
  - `enum DetailPresentation: Equatable { case browse; case edit(entryID: UUID); case create(defaultGroupID: UUID?); case createFromProposal(PendingSaveProposal) }`
  - `@Published var detailPresentation: DetailPresentation = .browse`
  - `func presentBrowse()`, `func presentEdit(entryID:)`, `func presentCreate(defaultGroupID:)`, `func presentCreateFromProposal(_:)`
  - `ContentView` detail column switches on `detailPresentation`
  - Remove `.sheet` for create/edit/proposal from `EntryListView`, `EntryDetailView`, `ContentView`

- [ ] **Step 1: Add DetailPresentation to NavigationState**

Make `PendingSaveProposal` conform to `Equatable` (compare `url`, `username`, `password`; ignore generated `id` or compare all fields except `id`):

```swift
extension PendingSaveProposal: Equatable {
    static func == (lhs: PendingSaveProposal, rhs: PendingSaveProposal) -> Bool {
        lhs.url == rhs.url && lhs.username == rhs.username && lhs.password == rhs.password
    }
}

enum DetailPresentation: Equatable {
    case browse
    case edit(entryID: UUID)
    case create(defaultGroupID: UUID?)
    case createFromProposal(PendingSaveProposal)
}

@Published var detailPresentation: DetailPresentation = .browse

func presentBrowse() { detailPresentation = .browse }

func presentEdit(entryID: UUID) { detailPresentation = .edit(entryID: entryID) }

func presentCreate(defaultGroupID: UUID?) {
    detailPresentation = .create(defaultGroupID: defaultGroupID)
}

func presentCreateFromProposal(_ proposal: PendingSaveProposal) {
    detailPresentation = .createFromProposal(proposal)
}
```

- [ ] **Step 2: Refactor ContentView detail column**

```swift
} detail: {
    DetailColumnView(rootGroup: database.rootGroup)
}
.onChange(of: navigationState.pendingSaveProposal) { _, proposal in
    if let proposal {
        navigationState.presentCreateFromProposal(proposal)
        navigationState.pendingSaveProposal = nil
    }
}
```

Remove `.sheet(item: $navigationState.pendingSaveProposal)`.

Create `DetailColumnView` in `ContentView.swift` (or separate file):

```swift
private struct DetailColumnView: View {
    let rootGroup: KdbxGroup
    @EnvironmentObject var navigationState: NavigationState
    @EnvironmentObject var vaultSession: VaultSession

    var body: some View {
        switch navigationState.detailPresentation {
        case .browse:
            EntryDetailView()
        case .edit(let entryID):
            entryEdit(existingID: entryID)
        case .create(let defaultGroupID):
            entryEdit(existingID: nil, defaultGroupID: defaultGroupID)
        case .createFromProposal(let proposal):
            entryEdit(existingID: nil, proposal: proposal)
        }
    }

    @ViewBuilder
    private func entryEdit(existingID: UUID?, defaultGroupID: UUID? = nil, proposal: PendingSaveProposal? = nil) -> some View {
        // EntryEditView wired in Task 5; stub routes here with onCancel/onSave calling presentBrowse()
    }
}
```

- [ ] **Step 3: EntryListView — remove create sheet; use detail presentation**

Remove `@State private var isCreatingEntry` and `.sheet(isPresented: $isCreatingEntry)`.

Toolbar Add button:

```swift
Button("Add", systemImage: "plus") {
    navigationState.presentCreate(defaultGroupID: currentGroup.uuid)
}
```

- [ ] **Step 4: EntryDetailView — remove edit sheet; Edit toolbar sets presentation**

Remove `@State private var showEdit` and `.sheet(isPresented: $showEdit)`.

```swift
Button("Edit", systemImage: "square.and.pencil") {
    navigationState.presentEdit(entryID: entry.uuid)
}
```

Keep `.sheet(isPresented: $showHistory)` — history stays modal per spec.

Browse body only renders when `detailPresentation == .browse` (handled by ContentView routing — EntryDetailView no longer needs to check).

- [ ] **Step 5: Wire Cancel/Save stubs returning to browse**

In `DetailColumnView`, minimal `EntryEditView` wiring until Task 5:

```swift
EntryEditView(
    existingEntry: resolvedEntry(existingID: existingID, proposal: proposal),
    defaultGroupID: defaultGroupID ?? navigationState.selectedGroupID ?? rootGroup.uuid,
    onCancel: { navigationState.presentBrowse() },
    onSave: { saved in
        vaultSession.mutate { database in
            if existingID != nil {
                replaceEntry(saved, in: database.rootGroup)
            } else {
                addEntry(saved, toGroupWithID: /* selected group from edit view */, in: database.rootGroup)
            }
        }
        navigationState.selectedEntryID = saved.uuid
        navigationState.presentBrowse()
    }
)
```

Copy `replaceEntry` / `addEntry` helpers from `EntryDetailView` / `EntryListView` into shared private helpers on `DetailColumnView` or a small `EntryPersistence` enum.

- [ ] **Step 6: Build**

Run: `./scripts/build.sh 2>&1 | tail -15`

- [ ] **Step 7: Commit**

```bash
git add MyPass/State/NavigationState.swift MyPass/ContentView.swift MyPass/UI/EntryDetail/EntryDetailView.swift MyPass/UI/EntryList/EntryListView.swift
git commit -m "feat(detail): DetailPresentation routes edit/create in detail column"
```

---

### Task 5: EntryEditView polish — group picker, multiline notes, OTP reveal, save logic

**Files:**
- Create: `MyPass/UI/EntryDetail/EntryEditSaveLogic.swift`
- Create: `MyPass/UI/EntryDetail/GroupPickerView.swift`
- Modify: `MyPass/UI/EntryDetail/EntryEditView.swift`
- Modify: `MyPass/ContentView.swift` (DetailColumnView save/move wiring)
- Create: `MyPassTests/EntryEditSaveLogicTests.swift`

**Interfaces:**
- Consumes: `ExtensionEntryMatcher.registrableDomain(from:)`, `TOTPCode.parse`, `GroupTreeOperations.moveEntry(withID:to:in:)`, `GroupTreeOperations.isRecycleBinGroup`
- Produces:
  - `enum EntryEditSaveLogic { static func resolvedTitle(draftTitle:url:) -> String; static func applyOTP(to:otpauthInput:isEditingExisting:) }`
  - `struct GroupPickerView: View` — `Binding<UUID>` selected group, excludes Recycle Bin subtree
  - `EntryEditView(existingEntry:defaultGroupID:onCancel:onSave:)` — no `@Environment(\.dismiss)`; toolbar Cancel/Save

- [ ] **Step 1: Write failing EntryEditSaveLogicTests**

```swift
import XCTest
import MyPassKit
@testable import MyPass

final class EntryEditSaveLogicTests: XCTestCase {
    func testResolvedTitleUsesRegistrableDomainWhenTitleEmpty() {
        XCTAssertEqual(
            EntryEditSaveLogic.resolvedTitle(draftTitle: "", url: "https://login.example.com"),
            "example.com"
        )
    }

    func testResolvedTitlePreservesExplicitTitle() {
        XCTAssertEqual(
            EntryEditSaveLogic.resolvedTitle(draftTitle: "My Login", url: "https://example.com"),
            "My Login"
        )
    }

    func testResolvedTitleEmptyWhenBothEmpty() {
        XCTAssertEqual(EntryEditSaveLogic.resolvedTitle(draftTitle: "", url: ""), "")
    }

    func testApplyOTPEmptyInputOnEditLeavesExistingSecret() {
        let now = Date()
        var entry = KdbxEntry(
            uuid: UUID(), iconID: 0, fields: [],
            creationTime: now, lastModificationTime: now, lastAccessTime: now, locationChanged: now, history: []
        )
        entry.totpSecretBase32 = "EXISTING"
        EntryEditSaveLogic.applyOTP(to: &entry, otpauthInput: "", isEditingExisting: true)
        XCTAssertEqual(entry.totpSecretBase32, "EXISTING")
    }

    func testApplyOTPEmptyInputOnCreateLeavesNil() {
        let now = Date()
        var entry = KdbxEntry(
            uuid: UUID(), iconID: 0, fields: [],
            creationTime: now, lastModificationTime: now, lastAccessTime: now, locationChanged: now, history: []
        )
        EntryEditSaveLogic.applyOTP(to: &entry, otpauthInput: "", isEditingExisting: false)
        XCTAssertNil(entry.totpSecretBase32)
    }

    func testApplyOTPSavesRawBase32() {
        let now = Date()
        var entry = KdbxEntry(
            uuid: UUID(), iconID: 0, fields: [],
            creationTime: now, lastModificationTime: now, lastAccessTime: now, locationChanged: now, history: []
        )
        EntryEditSaveLogic.applyOTP(to: &entry, otpauthInput: "JBSWY3DPEHPK3PXP", isEditingExisting: false)
        XCTAssertEqual(entry.totpSecretBase32, "JBSWY3DPEHPK3PXP")
    }
}
```

- [ ] **Step 2: Run test — expect FAIL**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/EntryEditSaveLogicTests 2>&1 | tail -20`

- [ ] **Step 3: Implement EntryEditSaveLogic.swift**

```swift
import Foundation
import MyPassKit

enum EntryEditSaveLogic {
    static func resolvedTitle(draftTitle: String, url: String) -> String {
        let trimmed = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        guard !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        return ExtensionEntryMatcher.registrableDomain(from: url) ?? url
    }

    static func applyOTP(to entry: inout KdbxEntry, otpauthInput: String, isEditingExisting: Bool) {
        guard !otpauthInput.isEmpty else { return }
        if let parsed = TOTPCode.parse(otpauthURL: otpauthInput) {
            entry.totpSecretBase32 = TOTPCode.base32Encode(parsed.secret)
        } else {
            entry.totpSecretBase32 = otpauthInput
        }
    }
}
```

- [ ] **Step 4: Implement GroupPickerView.swift**

```swift
import SwiftUI
import MyPassKit

struct GroupPickerView: View {
    let rootGroup: KdbxGroup
    let recycleBinGroupUUID: UUID?
    @Binding var selectedGroupID: UUID

    var body: some View {
        Picker("Group", selection: $selectedGroupID) {
            ForEach(selectableGroups, id: \.uuid) { group in
                Text(group.name).tag(group.uuid)
            }
        }
    }

    private var selectableGroups: [KdbxGroup] {
        flatten(rootGroup).filter { group in
            !GroupTreeOperations.isRecycleBinGroup(group)
        }
    }

    private func flatten(_ group: KdbxGroup) -> [KdbxGroup] {
        [group] + group.subgroups.flatMap { flatten($0) }
    }
}
```

Indent group names in picker labels if desired (optional polish): prefix nested groups with `"  "` repeated by depth.

- [ ] **Step 5: Refactor EntryEditView**

Replace `onSave` + `dismiss` with:

```swift
struct EntryEditView: View {
    let existingEntry: KdbxEntry?
    let defaultGroupID: UUID
    let onCancel: () -> Void
    let onSave: (KdbxEntry, UUID) -> Void  // entry + target group ID

    @State private var selectedGroupID: UUID
    @State private var showOTPField: Bool
    // ... existing field state ...

    init(existingEntry: KdbxEntry?, defaultGroupID: UUID, onCancel: @escaping () -> Void, onSave: @escaping (KdbxEntry, UUID) -> Void) {
        self.existingEntry = existingEntry
        self.defaultGroupID = defaultGroupID
        self.onCancel = onCancel
        self.onSave = onSave
        _selectedGroupID = State(initialValue: defaultGroupID)
        _showOTPField = State(initialValue: existingEntry?.totpSecretBase32?.isEmpty == false)
        // ... existing initializers ...
    }
```

Form changes:
- Notes: `TextField("Notes", text: $notes, axis: .vertical).lineLimit(3...8).frame(minHeight: 80)`
- OTP: only when `showOTPField`; else `Button("+ Add one-time password") { showOTPField = true }`
- Group: `GroupPickerView(rootGroup: ..., recycleBinGroupUUID: ..., selectedGroupID: $selectedGroupID)` — pass root/recycleBin from `@EnvironmentObject vaultSession`
- Remove bottom HStack Cancel/Save; add `.toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onCancel) }; ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).keyboardShortcut(.return, modifiers: .command) } }`
- Remove `dismiss()` calls from `save()`

Updated `save()`:

```swift
private func save() {
    let now = Date()
    var entry = existingEntry ?? KdbxEntry(/* same as today */)
    entry.title = EntryEditSaveLogic.resolvedTitle(draftTitle: title, url: url)
    entry.login = login
    entry.password = password
    entry.url = url
    entry.notes = notes
    entry.lastModificationTime = now
    entry.lastAccessTime = now
    EntryEditSaveLogic.applyOTP(to: &entry, otpauthInput: otpauthInput, isEditingExisting: existingEntry != nil)
    // extra fields unchanged
    onSave(entry, selectedGroupID)
}
```

Keep password generator nested `.sheet`.

- [ ] **Step 6: DetailColumnView — group move on Save**

```swift
onSave: { saved, targetGroupID in
    vaultSession.mutate { database in
        if let existingID = existingID {
            replaceEntry(saved, in: database.rootGroup)
            if let location = GroupTreeOperations.entryLocation(entryID: existingID, in: database.rootGroup),
               location.group.uuid != targetGroupID {
                GroupTreeOperations.moveEntry(withID: saved.uuid, to: targetGroupID, in: database.rootGroup)
            }
        } else {
            addEntry(saved, toGroupWithID: targetGroupID, in: database.rootGroup)
        }
    }
    navigationState.selectedEntryID = saved.uuid
    navigationState.presentBrowse()
}
```

For `createFromProposal`, seed draft via `ContentView.draftEntry(from:)` logic moved into `EntryEditView` initializer or passed as pre-filled `existingEntry` template with new UUID on save.

- [ ] **Step 7: Run tests**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/EntryEditSaveLogicTests 2>&1 | tail -20`

- [ ] **Step 8: Build**

Run: `./scripts/build.sh 2>&1 | tail -15`

- [ ] **Step 9: Commit**

```bash
git add MyPass/UI/EntryDetail/EntryEditSaveLogic.swift MyPass/UI/EntryDetail/GroupPickerView.swift MyPass/UI/EntryDetail/EntryEditView.swift MyPass/ContentView.swift MyPassTests/EntryEditSaveLogicTests.swift
git commit -m "feat(edit): group picker, OTP reveal, title-from-domain on save"
```

---

### Task 6: HistoryView restyle + version detail + Clear History

**Files:**
- Modify: `MyPass/UI/EntryDetail/HistoryView.swift`
- Create: `MyPass/UI/EntryDetail/HistoryVersionDetailView.swift`
- Create: `MyPass/UI/EntryDetail/EntryHistoryOperations.swift` (move enum out of HistoryView.swift)
- Modify: `MyPassTests/EntryHistoryOperationsTests.swift`

**Interfaces:**
- Consumes: `EntryHistoryOperations.restoreVersion(_:into:)`, `RelativeDateTimeFormatter`, `VaultSession.mutate`
- Produces:
  - `EntryHistoryOperations.clearHistory(on entry: inout KdbxEntry)`
  - `HistoryView` with `NavigationStack`, empty state, footer **Clear History…** + **Done**
  - `HistoryVersionDetailView(version:liveEntry:onRestore:)`

- [ ] **Step 1: Write failing clearHistory test**

Add to `EntryHistoryOperationsTests.swift`:

```swift
func testClearHistoryRemovesAllVersions() {
    let now = Date()
    var entry = KdbxEntry(
        uuid: UUID(), iconID: 0, fields: [],
        creationTime: now, lastModificationTime: now, lastAccessTime: now, locationChanged: now,
        history: []
    )
    var snapshot = entry
    snapshot.title = "Old"
    entry.history = [snapshot, snapshot]
    EntryHistoryOperations.clearHistory(on: &entry)
    XCTAssertTrue(entry.history.isEmpty)
}
```

Move `EntryHistoryOperations` enum to `MyPass/UI/EntryDetail/EntryHistoryOperations.swift` and add:

```swift
static func clearHistory(on entry: inout KdbxEntry) {
    entry.history = []
    entry.lastModificationTime = Date()
}
```

- [ ] **Step 2: Run test — expect FAIL until clearHistory exists**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/EntryHistoryOperationsTests 2>&1 | tail -20`

- [ ] **Step 3: Implement HistoryVersionDetailView.swift**

```swift
import SwiftUI
import MyPassKit

struct HistoryVersionDetailView: View {
    let version: KdbxEntry
    let liveEntry: KdbxEntry
    let onRestore: (KdbxEntry) -> Void

    var body: some View {
        Form {
            LabeledContent("Title", value: version.title.isEmpty ? "(untitled)" : version.title)
            LabeledContent("Username", value: version.login)
            LabeledContent("Password", value: String(repeating: "•", count: max(version.password.count, 8)))
            if !version.url.isEmpty { LabeledContent("URL", value: version.url) }
        }
        .navigationTitle("Version")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Restore") {
                    var updated = liveEntry
                    EntryHistoryOperations.restoreVersion(version, into: &updated)
                    onRestore(updated)
                }
            }
        }
    }
}
```

- [ ] **Step 4: Restyle HistoryView.swift**

```swift
struct HistoryView: View {
    let entry: KdbxEntry
    let onRestore: (KdbxEntry) -> Void
    let onClearHistory: (KdbxEntry) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var showClearConfirm = false

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    var body: some View {
        NavigationStack {
            Group {
                if entry.history.isEmpty {
                    ContentUnavailableView("No previous versions", systemImage: "clock.arrow.circlepath")
                } else {
                    List(entry.history.indices, id: \.self) { index in
                        let version = entry.history[index]
                        NavigationLink {
                            HistoryVersionDetailView(version: version, liveEntry: entry, onRestore: onRestore)
                        } label: {
                            HistoryVersionRow(version: version, currentEntry: entry)
                        }
                    }
                }
            }
            .navigationTitle("History")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !entry.history.isEmpty {
                    Button("Clear History…", role: .destructive) { showClearConfirm = true }
                        .frame(maxWidth: .infinity)
                        .padding()
                }
            }
            .alert("Clear History?", isPresented: $showClearConfirm) {
                Button("Cancel", role: .cancel) {}
                Button("Clear History", role: .destructive) {
                    var cleared = entry
                    EntryHistoryOperations.clearHistory(on: &cleared)
                    onClearHistory(cleared)
                }
            } message: {
                Text("Previous versions cannot be recovered.")
            }
        }
        .frame(minWidth: 420, minHeight: 400)
    }
}

private struct HistoryVersionRow: View {
    let version: KdbxEntry
    let currentEntry: KdbxEntry

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Color.secondary.opacity(0.15)).frame(width: 32, height: 32)
                Image(systemName: "pencil").font(.system(size: 14)).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(rowTitle)
                    .font(.body.weight(.medium))
                Text(HistoryView.relativeFormatter.localizedString(for: version.lastModificationTime, relativeTo: Date()))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }

    private var rowTitle: String {
        if version.password != currentEntry.password { return "Password updated" }
        if !version.title.isEmpty { return version.title }
        return "Password updated"
    }
}
```

- [ ] **Step 5: Update EntryDetailView history sheet**

```swift
.sheet(isPresented: $showHistory) {
    HistoryView(
        entry: entry,
        onRestore: { updated in
            vaultSession.mutate { database in
                replaceEntry(updated, in: database.rootGroup)
            }
            showHistory = false
        },
        onClearHistory: { updated in
            vaultSession.mutate { database in
                replaceEntry(updated, in: database.rootGroup)
            }
            showHistory = false
        }
    )
}
```

- [ ] **Step 6: Run tests**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/EntryHistoryOperationsTests 2>&1 | tail -20`

- [ ] **Step 7: Build**

Run: `./scripts/build.sh 2>&1 | tail -15`

- [ ] **Step 8: Commit**

```bash
git add MyPass/UI/EntryDetail/HistoryView.swift MyPass/UI/EntryDetail/HistoryVersionDetailView.swift MyPass/UI/EntryDetail/EntryHistoryOperations.swift MyPass/UI/EntryDetail/EntryDetailView.swift MyPassTests/EntryHistoryOperationsTests.swift
git commit -m "feat(history): Passwords-style list, version detail, clear history"
```

---

### Task 7: Manual smoke checklist + full test run

**Files:** none (verification only)

- [ ] **Step 1: Category counts and filters**

Run: `./scripts/run.sh`

Verify sidebar counts match list lengths for **All**, **Codes**, **Deleted** after adding/moving/deleting entries. **Favorites** shows `0` and empty list. **Security** shows `—`; selecting it changes header to **Security** but list contents unchanged.

- [ ] **Step 2: Group vs category mode**

Select **Codes** → list vault-wide TOTP entries. Select a group in tree → category highlight resets to **All**, header shows group name, list scoped to group entries.

- [ ] **Step 3: Groups + button**

Tap **+** on **Groups** header → `"New Group"` created under selected group (or root). Recycle Bin never parent. Context menu **New Subgroup** still works.

- [ ] **Step 4: Detail-column edit flows**

**Add** → detail column create form (no sheet). **Edit** toolbar → edit form in detail column. Chrome save proposal → detail column pre-filled form (no sheet). **Cancel** returns to browse; **Save** persists and selects entry.

- [ ] **Step 5: EntryEditView fields**

Empty title + URL → Save sets title to registrable domain. Group picker excludes Recycle Bin; changing group on edit moves entry. OTP hidden until **+ Add one-time password** or existing secret; empty OTP on edit does not clear secret. Notes field multiline.

- [ ] **Step 6: History sheet**

**View History** → styled list with relative dates; tap row → version detail → **Restore**. Empty history → **No previous versions**. **Clear History…** confirms and clears. **Done** dismisses.

- [ ] **Step 7: Full automated test suite**

Run: `./scripts/test.sh 2>&1 | tail -40`

Expected: all MyPassTests PASS; package tests PASS.

- [ ] **Step 8: Document verification**

No code commit required if all checks pass. Note results in PR test plan when opening merge request.

---

## Self-Review

### 1. Spec coverage

| Acceptance criterion | Task |
|---|---|
| Live category counts; Security `—`; update on mutate | Task 1, 2 |
| Category filters All/Favorites/Codes/Deleted; Security no-op; group exits category mode | Task 1, 2 |
| Groups **+** creates under selection/root; context menu unchanged | Task 3 |
| Edit panel in detail column; no entry edit sheets; Cancel/Save | Task 4, 5 |
| Title default empty title + URL → domain | Task 5 |
| Group picker without bin; move on Save | Task 5 |
| OTP hidden/reveal; empty OTP preserves secret | Task 5 |
| History styled list, restore, clear, empty, Done | Task 6 |
| No regressions vault/unlock/sync/Chrome browse detail | Task 7 |

### 2. Placeholder scan

No TBD/TODO/similar-to-task references. Every test step names an exact `-only-testing:` filter or `./scripts/test.sh`.

### 3. Type consistency

- `SmartCategoryCounts.countDisplay(for:database:)` / `SmartCategory.countDisplay(for:)` used in sidebar
- `EntryCategoryFilter.entries(for:in:)` used with `navigationState.activeCategoryFilter`
- `DetailPresentation` cases match `NavigationState.present*` helpers
- `EntryEditView` save signature `(KdbxEntry, UUID)` for group move
- `EntryHistoryOperations.clearHistory(on:)` matches test and HistoryView alert

---

**Plan complete.** Execute via `superpowers:subagent-driven-development` (one task per subagent) or `superpowers:executing-plans` (batched with checkpoints). Supersedes UI shell Wave 1 stub category counts, category filtering, and entry-edit sheets per spec.
