# MyPass Favorites Design

Date: 2026-07-29  
Status: approved

## Goal and Context

MyPass's sidebar already lists a `Favorites` smart category (added as a visual stub in the UI Shell wave, see `docs/superpowers/specs/2026-07-26-mypass-ui-shell-design.md`), but it has no backing implementation: `EntryCategoryFilter.favorites` always returns an empty array, and `SmartCategoryCounts` always shows `"0"`. There is no favorite flag anywhere on `KdbxEntry`, and no UI to set one.

This spec defines the real implementation: a persisted favorite flag on each entry, real filtering/counting for the Favorites category, and two toggle affordances (entry list row context menu, edit view star button).

**Parent design:** `docs/superpowers/specs/2026-07-26-mypass-ui-shell-design.md` (introduced the Favorites stub as backlog item 3, "Favorites (entry flag / KDBX storage)").

## Approach

**Chosen approach: custom KDBX string field, following the existing `otp` field convention.**

| Rejected | Reason |
|---|---|
| Native KDBX `<Tags>` XML element | MyPass's XML parser/writer has no `<Tags>` support at all today (not even round-trip); building that from scratch is a much larger, unrelated change for a feature that's currently entirely absent. A custom field needs zero XML-layer work since custom fields already round-trip generically. |
| Separate app-local favorites list (UUIDs stored outside the KDBX file) | Would not sync with the vault file itself (breaks cross-device/cross-app consistency, which KDBX-native storage gives for free); also a new persistence mechanism to maintain. |

`KdbxEntry+Convenience.swift` already establishes the pattern of representing KeePass-adjacent concepts (e.g. `otp` for TOTP secrets) as plain custom fields accessed via computed properties. Favorites follows the same pattern: presence of a `"Favorite"` field key means favorited; absence means not.

## Data Model

In `MyPass/Models/KdbxEntry+Convenience.swift`, add:

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

Add `"Favorite"` to `KdbxEntry.standardFieldKeys` (currently `["Title", "UserName", "Password", "URL", "Notes", "otp"]`) so the field never renders as a custom-field row in `additionalFields` (used by both the detail view's extra-fields list and the edit view's extra-fields form).

No changes to `Packages/MyPassKit` are needed — `KdbxField`/`fields` already round-trip through the XML layer generically regardless of key.

## Filtering and Counts

`MyPass/UI/EntryList/EntryCategoryFilter.swift`, `.favorites` case:

```swift
case .favorites:
    return all.filter { $0.isFavorite && !RecycleBinEntryFilter.isInRecycleBin($0, database: database) }
```

This mirrors `.all`'s recycle-bin exclusion exactly: a favorited entry that gets soft-deleted (moved to the Recycle Bin) drops out of the Favorites list, consistent with how `.all` already excludes recycle-bin entries. Favorites is a global (whole-vault) smart category, same as `.all`, `.codes`, and `.deleted` — it is not scoped to the currently selected group.

`MyPass/UI/EntryList/SmartCategoryCounts.swift`: replace the hardcoded `"0"` for `.favorites` with a real count using the same filter predicate (add a private `favoritesCount(in:)` helper mirroring the existing `codesCount`/`deletedCount` helpers).

## Toggle UI

**1. Entry list row context menu** (`MyPass/UI/EntryList/EntryListView.swift`)

Add a `.contextMenu` to each row in the `List(displayedEntries, ...)` (rows currently have no context menu at all). Menu shows a single toggle button:
- If `entry.isFavorite` is `false`: "Add to Favorites"
- If `entry.isFavorite` is `true`: "Remove from Favorites"

Action mutates through the existing `vaultSession.mutate { }` + `EntryPersistence.replaceEntry(...)` pattern already used by `HistoryView`'s restore flow and `EntryDetailView`'s group-move context menu:

```swift
vaultSession.mutate { database in
    var updated = entry
    updated.isFavorite.toggle()
    EntryPersistence.replaceEntry(updated, in: database.rootGroup)
}
```

**2. Edit view star toggle** (`MyPass/UI/EntryDetail/EntryEditView.swift`)

Add `@State private var isFavorite: Bool`, initialized in `init()` from `existingEntry?.isFavorite ?? false` (same pattern as the other `@State` properties initialized from `existingEntry`).

Add a toolbar button next to Cancel/Save showing a star icon (`star.fill` when favorited, `star` when not), toggling the state on tap. In `save()`, set `entry.isFavorite = isFavorite` before calling `onSave`.

Works identically for new entries (defaults to not-favorited) and existing entries.

**Out of scope for this spec** (not requested, avoid scope creep):
- A permanent star indicator drawn inline in list rows (state is discoverable via the edit-view star and via membership in the Favorites category itself).
- A favorite toggle in the read-only detail/browse view's toolbar (`EntryDetailView`) — only the edit view gets the star.

## Testing

- `MyPassTests/KdbxEntryConvenienceTests.swift`: add coverage for `isFavorite` get (absent field → `false`, present `"Favorite"` field → `true`) and set (`true` adds the field, `false` removes it; setting `false` when already absent is a no-op; the field never appears in `additionalFields`).
- `MyPassTests/EntryCategoryFilterTests.swift`: replace `testFavoritesFilterEmptyUntilFieldExists` (which asserted the old always-empty stub) with a test asserting: favorited entries are included, non-favorited entries are excluded, and a favorited entry inside the Recycle Bin group is excluded.
- `MyPassTests/SmartCategoryCountsTests.swift`: replace `testFavoritesAlwaysZero` (which asserted the old hardcoded `"0"`) with a test asserting the count reflects the actual number of favorited, non-deleted entries.

No new UI/snapshot tests — this codebase's test suite is logic-layer XCTest only (matching existing conventions in `SmartCategoryTests`, `EntryCategoryFilterTests`, `SmartCategoryCountsTests`, `KdbxEntryConvenienceTests`); toggle-button wiring in `EntryListView`/`EntryEditView` is covered indirectly through the `isFavorite` property tests plus manual verification via `./scripts/run.sh`.
