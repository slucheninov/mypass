# MyPass Favorites Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the `Favorites` smart category end-to-end: a persisted favorite flag on `KdbxEntry`, real filtering/counting for the Favorites sidebar category, and two toggle affordances (entry list context menu, edit view star button).

**Architecture:** Follow the existing `otp` custom-field convention in `KdbxEntry+Convenience.swift` — add an `isFavorite: Bool` computed property backed by presence/absence of a `"Favorite"` custom `KdbxField`. Wire it into the two smart-category stubs (`EntryCategoryFilter`, `SmartCategoryCounts`), then add toggle UI in the two views that already exist.

**Tech Stack:** Swift, SwiftUI, XCTest, XcodeGen (`scripts/generate.sh`), `xcodebuild`.

## Global Constraints

- Storage is a custom KDBX string field (key `"Favorite"`, value `"1"` when present), not a native `<Tags>` element — no changes to `Packages/MyPassKit`.
- `"Favorite"` must be added to `KdbxEntry.standardFieldKeys` so it never appears as a custom-field row in `additionalFields`.
- Favorites is a global (whole-vault) smart category like `.all`/`.codes`/`.deleted` — filtered/counted the same way `.all` excludes Recycle Bin entries (via `RecycleBinEntryFilter.isInRecycleBin(_:database:)`).
- No UI/snapshot tests — this codebase's test suite is logic-layer XCTest only. UI wiring tasks (context menu, edit-view star) are verified by build success plus manual verification via `./scripts/run.sh`, not new XCTest cases.
- Spec: `docs/superpowers/specs/2026-07-29-mypass-favorites-design.md`.

---

### Task 1: `isFavorite` on `KdbxEntry`

**Files:**
- Modify: `MyPass/Models/KdbxEntry+Convenience.swift`
- Test: `MyPassTests/KdbxEntryConvenienceTests.swift`

**Interfaces:**
- Consumes: `KdbxEntry.fields: [KdbxField]` (existing), private `fieldValue(forKey:)`/`setFieldValue(_:forKey:isProtected:)` helpers already defined at the top of `KdbxEntry+Convenience.swift`.
- Produces: `KdbxEntry.isFavorite: Bool` (get/set), and `KdbxEntry.standardFieldKeys` now includes `"Favorite"`. Later tasks (2, 3, 4, 5) read/write `entry.isFavorite` directly.

- [ ] **Step 1: Write the failing tests**

Add these four test functions to `MyPassTests/KdbxEntryConvenienceTests.swift` (inside the existing `final class KdbxEntryConvenienceTests: XCTestCase { ... }`, using the existing `makeEmptyEntry()` helper already in that file):

```swift
func testIsFavoriteDefaultsToFalse() {
    let entry = makeEmptyEntry()
    XCTAssertFalse(entry.isFavorite)
}

func testIsFavoriteSetterAddsAndRemovesField() {
    var entry = makeEmptyEntry()
    entry.isFavorite = true
    XCTAssertTrue(entry.isFavorite)
    XCTAssertEqual(entry.fields.first(where: { $0.key == "Favorite" })?.value, "1")

    entry.isFavorite = false
    XCTAssertFalse(entry.isFavorite)
    XCTAssertNil(entry.fields.first(where: { $0.key == "Favorite" }))
}

func testIsFavoriteSetterFalseWhenAlreadyAbsentIsNoOp() {
    var entry = makeEmptyEntry()
    entry.isFavorite = false
    XCTAssertFalse(entry.isFavorite)
    XCTAssertTrue(entry.fields.isEmpty)
}

func testFavoriteFieldExcludedFromAdditionalFields() {
    var entry = makeEmptyEntry()
    entry.isFavorite = true
    entry.fields.append(KdbxField(key: "Custom Field", value: "custom value", isProtected: false))

    let keys = Set(entry.additionalFields.map(\.key))
    XCTAssertEqual(keys, ["Custom Field"])
    XCTAssertFalse(keys.contains("Favorite"))
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./scripts/generate.sh && xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/KdbxEntryConvenienceTests`
Expected: FAIL — `isFavorite` does not exist on `KdbxEntry` (compile error).

- [ ] **Step 3: Write minimal implementation**

In `MyPass/Models/KdbxEntry+Convenience.swift`, add the following computed property to the existing (non-public) `extension KdbxEntry { ... }` block that already contains `title`, `login`, `password`, `url`, `notes`, `totpSecretBase32` — add it right after `totpSecretBase32`:

```swift
    var isFavorite: Bool {
        get { fields.contains { $0.key == "Favorite" } }
        set {
            if newValue {
                setFieldValue("1", forKey: "Favorite", isProtected: false)
            } else {
                fields.removeAll { $0.key == "Favorite" }
            }
        }
    }
```

Then update the `public extension KdbxEntry { ... }` block's `standardFieldKeys` from:

```swift
    static let standardFieldKeys: Set<String> = ["Title", "UserName", "Password", "URL", "Notes", "otp"]
```

to:

```swift
    static let standardFieldKeys: Set<String> = ["Title", "UserName", "Password", "URL", "Notes", "otp", "Favorite"]
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/KdbxEntryConvenienceTests`
Expected: PASS (all tests in the class, including the 4 new ones).

- [ ] **Step 5: Commit**

```bash
git add MyPass/Models/KdbxEntry+Convenience.swift MyPassTests/KdbxEntryConvenienceTests.swift
git commit -m "feat(mypass): add isFavorite property to KdbxEntry"
```

---

### Task 2: Real Favorites filtering in `EntryCategoryFilter`

**Files:**
- Modify: `MyPass/UI/EntryList/EntryCategoryFilter.swift`
- Test: `MyPassTests/EntryCategoryFilterTests.swift`

**Interfaces:**
- Consumes: `KdbxEntry.isFavorite: Bool` (Task 1), `RecycleBinEntryFilter.isInRecycleBin(_:database:) -> Bool` (existing, in `MyPass/UI/MenuBar/RecycleBinEntryFilter.swift`).
- Produces: `EntryCategoryFilter.entries(for: .favorites, in:)` now returns real favorited, non-deleted entries instead of `[]`.

- [ ] **Step 1: Write the failing test**

In `MyPassTests/EntryCategoryFilterTests.swift`, DELETE the existing `testFavoritesFilterEmptyUntilFieldExists` function (it locks in the old stub behavior) and REPLACE it with:

```swift
func testFavoritesFilterIncludesOnlyFavoritedLiveEntries() {
    var favorite = makeEntry(title: "Favorite")
    favorite.isFavorite = true
    let plain = makeEntry(title: "Plain")
    var favoriteInBin = makeEntry(title: "FavoriteDeleted")
    favoriteInBin.isFavorite = true

    let db = makeDatabase(rootEntries: [favorite, plain], binEntries: [favoriteInBin])

    XCTAssertEqual(EntryCategoryFilter.entries(for: .favorites, in: db).map(\.title), ["Favorite"])
}
```

This uses the file's existing `makeEntry(title:totp:)` and `makeDatabase(rootEntries:binEntries:)` private helpers unchanged.

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/EntryCategoryFilterTests/testFavoritesFilterIncludesOnlyFavoritedLiveEntries`
Expected: FAIL — filter still returns `[]` (stub), assertion mismatch (`[] != ["Favorite"]`).

- [ ] **Step 3: Write minimal implementation**

In `MyPass/UI/EntryList/EntryCategoryFilter.swift`, replace:

```swift
        case .favorites:
            return [] // stub until KDBX favorite field exists
```

with:

```swift
        case .favorites:
            return all.filter { $0.isFavorite && !RecycleBinEntryFilter.isInRecycleBin($0, database: database) }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/EntryCategoryFilterTests`
Expected: PASS (all tests in the class, including the replaced one).

- [ ] **Step 5: Commit**

```bash
git add MyPass/UI/EntryList/EntryCategoryFilter.swift MyPassTests/EntryCategoryFilterTests.swift
git commit -m "feat(mypass): filter Favorites category to real favorited entries"
```

---

### Task 3: Real Favorites count in `SmartCategoryCounts`

**Files:**
- Modify: `MyPass/UI/EntryList/SmartCategoryCounts.swift`
- Test: `MyPassTests/SmartCategoryCountsTests.swift`

**Interfaces:**
- Consumes: `KdbxEntry.isFavorite: Bool` (Task 1), `RecycleBinEntryFilter.isInRecycleBin(_:database:) -> Bool` (existing), `allEntries(in:) -> [KdbxEntry]` (existing private helper in this file).
- Produces: `SmartCategoryCounts.countDisplay(for: .favorites, database:)` now returns a real count instead of the hardcoded `"0"`.

- [ ] **Step 1: Write the failing test**

In `MyPassTests/SmartCategoryCountsTests.swift`, DELETE the existing `testFavoritesAlwaysZero` function and REPLACE it with:

```swift
func testFavoritesCountExcludesRecycleBin() {
    var favorite1 = makeEntry(title: "F1")
    favorite1.isFavorite = true
    var favorite2 = makeEntry(title: "F2")
    favorite2.isFavorite = true
    var favoriteInBin = makeEntry(title: "FavDeleted")
    favoriteInBin.isFavorite = true

    let db = makeDatabase(
        rootEntries: [favorite1, favorite2, makeEntry(title: "Plain")],
        binEntries: [favoriteInBin]
    )
    XCTAssertEqual(SmartCategoryCounts.countDisplay(for: .favorites, database: db), "2")
}
```

This uses the file's existing `makeEntry(title:totp:)` and `makeDatabase(rootEntries:binEntries:)` private helpers unchanged.

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/SmartCategoryCountsTests/testFavoritesCountExcludesRecycleBin`
Expected: FAIL — count still hardcoded to `"0"`, assertion mismatch (`"0" != "2"`).

- [ ] **Step 3: Write minimal implementation**

In `MyPass/UI/EntryList/SmartCategoryCounts.swift`, replace:

```swift
        case .favorites:
            return "0"
```

with:

```swift
        case .favorites:
            return String(favoritesCount(in: database))
```

Then add a new private helper, placed next to the existing `codesCount`/`deletedCount` helpers:

```swift
    private static func favoritesCount(in database: KdbxDatabase) -> Int {
        allEntries(in: database).filter {
            $0.isFavorite && !RecycleBinEntryFilter.isInRecycleBin($0, database: database)
        }.count
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/SmartCategoryCountsTests`
Expected: PASS (all tests in the class, including the replaced one).

- [ ] **Step 5: Commit**

```bash
git add MyPass/UI/EntryList/SmartCategoryCounts.swift MyPassTests/SmartCategoryCountsTests.swift
git commit -m "feat(mypass): show real Favorites count instead of hardcoded 0"
```

---

### Task 4: Favorite toggle in entry list context menu

**Files:**
- Modify: `MyPass/UI/EntryList/EntryListView.swift`

**Interfaces:**
- Consumes: `KdbxEntry.isFavorite: Bool` (Task 1), `vaultSession.mutate(_:)` (existing, used elsewhere in this file for CSV import), `EntryPersistence.replaceEntry(_:in:)` (existing, defined in `MyPass/ContentView.swift`, same module so no import needed).
- Produces: no new public API — internal View wiring only. Right-clicking (or Control-clicking) any row in the entry list shows "Add to Favorites" / "Remove from Favorites".

- [ ] **Step 1: Add the context menu and toggle function**

In `MyPass/UI/EntryList/EntryListView.swift`, inside the `body`'s `List(displayedEntries, selection: $navigationState.selectedEntryID) { entry in ... }` closure, add a `.contextMenu` modifier after the existing `.draggable(...)` modifier:

```swift
            EntryListRow(
                title: displayTitle(for: entry),
                subtitle: entry.login
            )
            .tag(entry.uuid)
            .listRowBackground(EntryListRowBackground(isSelected: isSelected))
            .draggable(entry.uuid.uuidString) // full drag-and-drop wiring completed in Task 15
            .contextMenu {
                Button(entry.isFavorite ? "Remove from Favorites" : "Add to Favorites") {
                    toggleFavorite(entry)
                }
            }
```

Add this new private method to the `EntryListView` struct (near `find(uuid:in:)`):

```swift
    private func toggleFavorite(_ entry: KdbxEntry) {
        vaultSession.mutate { database in
            var updated = entry
            updated.isFavorite.toggle()
            EntryPersistence.replaceEntry(updated, in: database.rootGroup)
        }
    }
```

- [ ] **Step 2: Build to verify it compiles**

Run: `./scripts/generate.sh && xcodebuild build -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS'`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Manual verification**

Run: `./scripts/run.sh`
In the running app: select any group with entries, right-click (or Control-click) an entry row, click "Add to Favorites", confirm the menu now reads "Remove from Favorites" on the next right-click, then click the `Favorites` sidebar category and confirm the entry appears there with an updated count.

- [ ] **Step 4: Commit**

```bash
git add MyPass/UI/EntryList/EntryListView.swift
git commit -m "feat(mypass): add favorite toggle to entry list context menu"
```

---

### Task 5: Favorite star toggle in edit view

**Files:**
- Modify: `MyPass/UI/EntryDetail/EntryEditView.swift`

**Interfaces:**
- Consumes: `KdbxEntry.isFavorite: Bool` (Task 1).
- Produces: no new public API — internal View wiring only. The edit view toolbar shows a star button that toggles favorite state; `save()` persists it via `entry.isFavorite`.

- [ ] **Step 1: Add `isFavorite` state, initialize it, wire it into `save()`, and add the toolbar button**

In `MyPass/UI/EntryDetail/EntryEditView.swift`, add a new `@State` property next to the other `@State` declarations:

```swift
    @State private var isFavorite: Bool
```

In `init(...)`, add this line next to the other `_xxx = State(initialValue: ...)` assignments (after `_extraFields = State(initialValue: ...)`):

```swift
        _isFavorite = State(initialValue: existingEntry?.isFavorite ?? false)
```

In `save()`, add this line next to the other `entry.xxx = ...` assignments (after `entry.notes = notes`):

```swift
        entry.isFavorite = isFavorite
```

In the `.toolbar { ... }` block, add a new `ToolbarItem` between the existing `.cancellationAction` and `.confirmationAction` items:

```swift
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", action: onCancel)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isFavorite.toggle()
                } label: {
                    Image(systemName: isFavorite ? "star.fill" : "star")
                }
                .accessibilityLabel(isFavorite ? "Remove from Favorites" : "Add to Favorites")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save)
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
```

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodebuild build -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS'`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Manual verification**

Run: `./scripts/run.sh`
In the running app: open an existing entry, click Edit, click the star button in the toolbar and confirm it fills in (`star.fill`), click Save, reopen the same entry's edit view and confirm the star is still filled (state persisted), then toggle it off, Save, and confirm it's back to the outline star on reopen.

- [ ] **Step 4: Commit**

```bash
git add MyPass/UI/EntryDetail/EntryEditView.swift
git commit -m "feat(mypass): add favorite star toggle to edit view"
```

---

### Task 6: Full verification

**Files:** none (verification only)

**Interfaces:**
- Consumes: everything produced by Tasks 1–5.
- Produces: confidence that the full test suite and app build are green end-to-end.

- [ ] **Step 1: Run the full test suite**

Run: `./scripts/test.sh`
Expected: all `MyPassTests` targets pass (including `KdbxEntryConvenienceTests`, `EntryCategoryFilterTests`, `SmartCategoryCountsTests`), and all three Swift packages (`MyPassKit`, `SyncKit`, `ExtensionBridgeKit`) pass their own `swift test` runs.

- [ ] **Step 2: End-to-end manual smoke test**

Run: `./scripts/run.sh`
Confirm in the running app: favoriting an entry via the list context menu updates the edit view's star on next open; favoriting via the edit view star updates the context menu label on next right-click; the `Favorites` sidebar count matches the number of favorited, non-deleted entries; moving a favorited entry to the Recycle Bin removes it from the Favorites list and decrements the count.
