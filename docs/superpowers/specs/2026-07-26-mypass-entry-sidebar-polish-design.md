# MyPass Entry / Sidebar Polish — Design

Date: 2026-07-26  
Status: approved

## Goal and Context

MyPass Wave 1 (`docs/superpowers/specs/2026-07-26-mypass-ui-shell-design.md`) restyled the three-column shell with **stub** smart categories (static counts, no filtering) and **sheet-based** New/Edit entry flows. This spec defines a single polish pass that wires real sidebar behavior and moves editing into the detail column — without redesigning the overall shell or tackling deferred backlog items (security audit, favorites persistence, menu bar, localization).

**Parent documents:**

| Document | Relationship |
|---|---|
| `docs/superpowers/specs/2026-07-21-mypass-design.md` | KeePass KDBX model, group tree, Recycle Bin, entry history semantics |
| `docs/superpowers/specs/2026-07-26-mypass-ui-shell-design.md` | Visual shell, category chrome, detail card layout. **This spec supersedes Wave 1 stub behavior for categories (counts + filters), edit presentation, and history styling.** Category accent colors and row chrome from Wave 1 remain. |

## Approach

**Single polish pass** covering three areas:

1. **Sidebar** — live category counts over the whole vault; category selection filters the entry list; Groups header **+** button; group selection exits category mode.
2. **Edit panel** — New/Edit (including Chrome extension save proposals) replace the detail column instead of presenting sheets.
3. **History** — keep modal presentation; restyle to an Apple Passwords–like list of real `entry.history` versions only.

Rejected for this pass: fake sharing/AirDrop history rows; full Security category filtering; smart-category icon redesign beyond count/filter wiring; localization.

## §1 Sidebar — Categories + Groups

### Live category counts

Counts recompute whenever vault data changes (mutate/save/reload). Source: all entries under `database.rootGroup` via `EntrySearch.allEntries(in:)`.

| Category | Count display | Count rule |
|---|---|---|
| **All** | Integer string | Entries **not** in the Recycle Bin group |
| **Favorites** | Integer string, or `0` when no favorite field exists yet | Entries with favorite flag set (see Favorites stub below) |
| **Codes** | Integer string | Entries where `totpSecretBase32` is non-empty |
| **Security** | Em dash (`—`) always | Not computed; stub only |
| **Deleted** | Integer string | Entries currently in the Recycle Bin group |

Display formatting: use plain decimal strings (e.g. `12`). Security always shows `—`, never a number.

### Favorites stub

No KDBX favorite field exists today. Until favorites storage lands (UI shell backlog item 3):

- **Favorites count** is always `0`.
- **Favorites filter** returns an empty list (count and list stay consistent).
- When a favorite field is added in a future spec, count and filter logic switch to real data without changing sidebar chrome.

### Category selection → filter list (option B)

Selecting a smart category sets **category mode** and filters the center entry list **across the whole vault** (not limited to the currently highlighted group). Search (`navigationState.searchText`) applies on top of the category filter.

| Category | List contents when selected |
|---|---|
| All | All non-deleted entries (exclude Recycle Bin) |
| Favorites | Favorite-flagged entries only (empty until favorites field exists) |
| Codes | Entries with non-empty `totpSecretBase32` |
| Security | **No filter change** — selection updates highlight and header title only; list keeps prior contents (stub) |
| Deleted | Entries in Recycle Bin only |

**List header title** matches the selected category label while in category mode (existing `headerTitle` behavior in `EntryListView`).

**Group selection exits category mode:** when the user selects a group in the tree (including Recycle Bin), clear category-mode filtering and show that group's entries only. Reset `selectedSmartCategory` to `.all` for highlight consistency (same as today's `onChange(of: selectedGroupID)`), but entry list is driven by **group scope**, not the All category filter. List header shows the group name.

Category rows remain visually unchanged from Wave 1 (colored dot, pill selection, uppercase **Categories** header).

### Groups header — add subgroup

Add a trailing **+** control on the **Groups** section header (same uppercase header row as **Categories**).

| Action | Behavior |
|---|---|
| Tap **+** | `GroupTreeOperations.addSubgroup(named: "New Group", to: parent)` |
| Parent target | If a **non–Recycle Bin** group is selected in the tree, add under that group; otherwise add under `rootGroup` |
| Recycle Bin guard | Never use Recycle Bin as the parent for **+** |
| Context menu | Existing **New Subgroup** on group rows stays unchanged (same default name `"New Group"`) |

After creation, optionally select the new group (implementation plan may choose; default: select new group so user can rename via future rename UX or immediate edit — not required in this spec).

## §2 Edit Panel + Fields

### Detail-column edit (option A)

Replace `.sheet` presentation for New/Edit entry with **detail-column replacement** in the main window `NavigationSplitView`:

| Trigger | Today | After |
|---|---|---|
| Entry list **Add** | Sheet with `EntryEditView` | Detail column → create form |
| Detail **Edit** toolbar | Sheet with `EntryEditView` | Detail column → edit form |
| Chrome `pendingSaveProposal` | Sheet in `ContentView` | Detail column → pre-filled create form (same code path as Add) |

**Navigation state:** introduce a detail presentation mode (e.g. `DetailPresentation`: `.browse`, `.edit(existing: KdbxEntry?)`, `.create`, `.createFromProposal(PendingSaveProposal)`) owned by `NavigationState` or a small coordinator observed by `ContentView` / `EntryDetailView`.

**Toolbar:** Cancel and Save in the edit form's toolbar (primary actions). **Cancel** discards draft state and returns to browse mode — restored detail for the previously selected entry if still valid, otherwise empty detail. **Save** persists via existing `vaultSession.mutate` paths, then returns to browse mode with the saved entry selected.

Remove `.sheet(isPresented:)` / `.sheet(item:)` for entry edit from `EntryListView`, `EntryDetailView`, and `ContentView` once detail routing works. Password generator may remain a nested sheet from the edit form.

### Field specifications

Reuse `EntryEditView` field logic; adjust layout for detail column (Form or grouped controls consistent with Wave 1 detail styling).

| Field | Behavior |
|---|---|
| **Title** | Optional text field |
| **Title default on Save** | If title is empty **and** URL is non-empty → set `title = ExtensionEntryMatcher.registrableDomain(from: url) ?? url` (same helper as `PendingSaveProposal.registrableDomain`) |
| **Username** | Unchanged |
| **Password** | Unchanged; **Generate** opens existing password generator |
| **URL** | Unchanged |
| **Group** | Tree picker; Recycle Bin **excluded** as create/move target; on edit, user may move entry to another group; on Save, if selected group differs from current location, call `GroupTreeOperations.moveEntry(withID:to:in:)` |
| **Notes** | Multiline — `TextField` with vertical axis and minimum height, or `TextEditor`; must support several lines comfortably |
| **OTP** | **Hidden by default.** Show field when entry already has TOTP **or** user taps **+ Add one-time password**. Do not write/clear `totpSecretBase32` when OTP input is empty on Save (leave existing secret intact on edit; omit on create). Parsing unchanged: `otpauth://` via `TOTPCode.parse`, else treat as raw Base32 |
| **+ Add Field** | Unchanged this pass (additional custom fields section) |

### Detail view (browse mode)

- Show **Verification Code** row only when `totpSecretBase32` is non-empty (already true).
- Notes row when non-empty (already true).

### Chrome extension save proposal

When `ExtensionBridgeService` sets `navigationState.pendingSaveProposal`:

1. Bring main window forward (existing behavior).
2. Switch detail column to create form pre-filled from proposal (title may start as `registrableDomain`, URL, username, password).
3. Clear `pendingSaveProposal` on Save or Cancel.
4. Do **not** present a separate sheet.

## §3 History

Keep **modal sheet** presentation from detail **View History** (do not embed history in the detail column).

Restyle `HistoryView` to an Apple Passwords–like list using **only real** `entry.history` snapshots — no fake sharing or AirDrop rows.

### List rows

Each history version (`KdbxEntry` snapshot in `entry.history`):

| Element | Specification |
|---|---|
| Leading | Pencil icon inside a circle (SF Symbol `pencil` in circular secondary background) |
| Title | **Password updated** when the version differs from current entry mainly in password; otherwise use version title if non-empty, else **Password updated** |
| Subtitle | Relative time from `version.lastModificationTime` (e.g. "2 days ago" via `RelativeDateTimeFormatter`) |
| Trailing | Chevron (`chevron.right`) indicating navigation |

Row tap pushes (or presents inline within the sheet) a **version detail** showing key fields from that snapshot and a **Restore** action. **Restore** uses existing `EntryHistoryOperations.restoreVersion(_:into:)` and dismisses or pops back to list after success.

### Sheet chrome

| Element | Behavior |
|---|---|
| Navigation title | **History** (or entry title + History — implementation may use inline title) |
| Footer | **Clear History…** (destructive confirmation) + **Done** (dismiss sheet) |
| Empty state | Centered **No previous versions** when `entry.history.isEmpty` |

**Clear History…** removes all elements from `entry.history` on the live entry and persists via `vaultSession.mutate`. Confirm with alert: title **Clear History?**, message explaining versions cannot be recovered, actions **Cancel** / **Clear History** (destructive).

## Architecture Notes

### New / extended modules

| Area | Suggested location |
|---|---|
| Category counts | `SmartCategoryCounts` or extensions on `SmartCategory` + vault snapshot |
| Category filter | `EntryCategoryFilter` applied in `EntryListView.displayedEntries` |
| Detail presentation | `NavigationState.detailPresentation` (or equivalent) |
| Group picker | `GroupPickerView` — tree without Recycle Bin |
| History styling | Refactor `HistoryView` + optional `HistoryVersionDetailView` |

### Files likely touched

- `MyPass/UI/Shell/SmartCategory.swift` — replace `placeholderCount` with computed counts API
- `MyPass/UI/Sidebar/GroupSidebarView.swift` — live counts, Groups **+**
- `MyPass/UI/EntryList/EntryListView.swift` — category filter, remove edit sheet
- `MyPass/UI/EntryDetail/EntryDetailView.swift` — browse vs edit routing, remove edit sheet
- `MyPass/UI/EntryDetail/EntryEditView.swift` — group picker, OTP reveal, title default, toolbar Cancel/Save, dismiss via presentation binding
- `MyPass/UI/EntryDetail/HistoryView.swift` — restyle, empty state, clear history, version detail
- `MyPass/ContentView.swift` — detail column hosts edit/create; remove proposal sheet
- `MyPass/State/NavigationState.swift` — detail presentation + category/group mode helpers

### Preserved behavior

- Recycle Bin soft-delete / restore / permanent delete semantics unchanged.
- Search, sort, drag-and-drop, import toolbar items unchanged unless category filter intersects.
- Wave 1 visual tokens (`UIShellMetrics`, letter avatars, detail card in browse mode).
- English UI strings until Phase 7.

## Acceptance Criteria

1. **Category counts** reflect live vault data per rules above; Security shows `—`; counts update after entry/group mutations.
2. **Category filters:** All / Favorites / Codes / Deleted filter the list vault-wide; Security selects without filtering; group selection exits category mode and scopes list to that group.
3. **Groups +** creates `"New Group"` under selected non-bin group or root; context-menu **New Subgroup** still works.
4. **Edit panel:** Add, Edit, and extension save proposal open in the **detail column** (no entry edit sheets). Cancel/Save toolbar works; Cancel returns to browse/empty.
5. **Save title default:** empty title + non-empty URL → registrable domain on Save.
6. **Group picker:** tree without Recycle Bin; move on Save when group changes.
7. **OTP:** hidden until existing secret or **+ Add one-time password**; empty OTP input does not clear existing secret; detail shows TOTP only when secret exists.
8. **History sheet:** styled list of real versions, relative dates, version detail + Restore, empty state, **Clear History…** with confirmation, **Done** dismisses.
9. **No regressions:** vault session, unlock, sync, Chrome bridge (aside from proposal presentation path), and browse-mode detail card remain functional.

## Out of Scope

| Item | Notes |
|---|---|
| Fake sharing / AirDrop history rows | Explicitly rejected |
| Full Security category filtering / audit heuristics | UI shell backlog item 5 |
| Favorites KDBX field persistence | Count/filter stub only; real storage is backlog item 3 |
| Smart category icon / pill redesign | Wave 1 visuals kept |
| Inline TOTP in list rows; live countdown redesign | Backlog item 4 |
| Menu bar panel changes | Separate menu bar spec |
| Localization (en / uk / de catalogs) | Phase 7 |
| Entry rename in sidebar, group rename UX | Not part of this pass |
| Settings or unlock screen changes | Other specs |

## Testing Notes

### Unit tests

| Area | Cases |
|---|---|
| Category counts | All excludes bin; Codes counts TOTP entries; Deleted counts bin entries; Favorites returns 0 without field; Security not counted |
| Category filters | All/Codes/Deleted/Favorites filter predicates; Security no-op; search ∩ filter |
| Title on Save | Empty title + URL → domain; empty title + empty URL → empty title; explicit title preserved |
| Group move on Save | Edit changes group → `moveEntry` called; same group → no move; Recycle Bin not offered in picker |
| OTP save | Empty input on edit leaves secret; new secret saved; create without OTP leaves nil |
| Clear history | Clears `entry.history` array |

Extend or replace `SmartCategoryTests` placeholder-count tests with live count/filter tests. Add `EntryCategoryFilterTests`, `EntryEditSaveTests` (title default, OTP, group move) as appropriate.

### Manual verification

- Sidebar counts match filtered list lengths for All, Codes, Deleted.
- Favorites shows `0` and empty list.
- **+** creates group; context menu still creates subgroup.
- Add / Edit / extension proposal use detail panel; Cancel and Save behave correctly.
- OTP field hidden until revealed; detail TOTP row matches secret presence.
- History list, restore, clear, empty state, Done.

## Implementation Handoff

Proceed via `writing-plans` → `executing-plans`. Plans must reference this spec by path, note supersession of UI shell category stubs and edit sheets, and stay within the single polish pass scope above.

## References

| Resource | Path |
|---|---|
| Master product design | `docs/superpowers/specs/2026-07-21-mypass-design.md` |
| UI shell (superseded stubs) | `docs/superpowers/specs/2026-07-26-mypass-ui-shell-design.md` |
| Smart categories | `MyPass/UI/Shell/SmartCategory.swift` |
| Sidebar | `MyPass/UI/Sidebar/GroupSidebarView.swift` |
| Entry list | `MyPass/UI/EntryList/EntryListView.swift` |
| Entry detail / edit | `MyPass/UI/EntryDetail/EntryDetailView.swift`, `EntryEditView.swift` |
| History | `MyPass/UI/EntryDetail/HistoryView.swift` |
| Navigation / proposals | `MyPass/State/NavigationState.swift`, `MyPass/ContentView.swift` |
| Domain helper | `MyPass/State/ExtensionBridge/ExtensionEntryMatcher.swift` |
| Group tree ops | `MyPass/UI/Sidebar/GroupTreeOperations.swift` |
| Entry search / flatten | `MyPass/UI/EntryList/EntrySearch.swift` |
