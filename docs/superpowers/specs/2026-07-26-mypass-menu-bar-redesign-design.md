# MyPass Menu Bar Redesign — Design

Date: 2026-07-26  
Status: approved

## Goal and Context

The menu bar extra today is a minimal 240 pt popover (`MenuBarExtraContent`): locked/unlocked status text, a Quick Search field bound to `NavigationState.searchText`, Lock, and a Password Generator sheet. It does not match Apple Passwords–style quick access and duplicates main-window affordances poorly.

This spec defines **Problem 2: Menu Bar** — a custom `MenuBarExtra` panel with recent entries when unlocked, a compact unlock prompt when locked, and standard app actions. It supersedes backlog item 7 in the UI shell spec and the placeholder `MenuBarExtraContent` called out in the Settings redesign spec.

**Parent documents:**

| Document | Relationship |
|---|---|
| `docs/superpowers/specs/2026-07-21-mypass-design.md` | Product architecture, vault session, auto-lock, Chrome extension bridge. Menu bar must respect lock state and not expose secrets while locked. |
| `docs/superpowers/specs/2026-07-26-mypass-ui-shell-design.md` | Letter avatar sizing/color rules for list rows; Wave 1 visual direction. Menu bar reuses `LetterAvatarView` at a smaller size. |
| `docs/superpowers/specs/2026-07-26-mypass-settings-redesign-design.md` | **Approved.** General pane controls menu bar **presence** (`showMenuBarExtra`) and placeholder **Click the icon to** picker; keyboard shortcut recorders for Show MyPass and Lock MyPass. This spec owns panel content and click behavior when the extra is visible. |

**Problem 1 boundary:** Settings General does not redesign `MenuBarExtraContent`; it only hides/shows the extra and stores forward-compatible click-mode preference (`menuBarClickAction = "menu"`).

## Approach

**Chosen:** Custom **`MenuBarExtra` window-style panel** (`.menuBarExtraStyle(.window)`), not a system `.menu`-only dropdown.

**Tray icon:** `key.fill` (unchanged from `MyPassApp`).

**Rejected:** Keeping Quick Search and Password Generator in the menu bar (removed — belong in main window); showing locked/unlocked status headline (redundant with panel mode); security warning badges on recent rows (deferred).

### Visibility (Settings dependency)

When `@AppStorage("showMenuBarExtra")` is `false`, `MyPassApp` does not register `MenuBarExtra` at all (per Settings spec). When `true`, clicking the tray icon opens this panel. The **Click the icon to** picker remains **Show a menu** only until Quick Access ships; no alternate click behavior in this phase.

## Panel States

### Locked

Clicking the tray icon shows **only** the unlock panel — no recent entries, no app-action menu.

| Element | Specification |
|---|---|
| Width | ~280 pt (same width family as unlocked panel) |
| Header | **MyPass is locked** — headline weight, centered or leading per Apple Passwords lock prompt rhythm |
| Icon | `key.fill`, secondary tint (~32–40 pt), optional |
| Touch ID | Shown when `BiometricKeyStore` has enrolled key for account `"master"` (same detection as `UnlockView`). Button: **Touch ID** with `touchid` symbol. Invokes existing biometric retrieve + unlock path (complete end-to-end unlock if Settings Security enrollment is done). |
| Password | Secure field placeholder **Enter Password**; primary **Unlock** button (bordered prominent). `onSubmit` on field triggers unlock. |
| Error | Inline caption below field on wrong password or biometric failure (reuse `UnlockView` messaging patterns). |
| Helper | Optional 11 pt secondary line: vault remains locked until unlocked manually. |

Visual reference: Apple Passwords menu bar / lock prompt screenshot (2026-07-26) — compact card, restrained spacing, no status toggle text.

On successful unlock, the panel **refreshes in place** to the unlocked layout (do not require a second click on the tray icon).

### Unlocked

Custom panel, fixed width **~280–320 pt**, vertical stack, no sheet modals.

**Layout (top to bottom):**

1. **Recent entries block** — up to 5 rows (see below). Hidden entirely when zero qualifying entries (no placeholder text).
2. **Divider** — only when ≥1 recent row is shown.
3. **Open MyPass** — button or menu-style row. Activates app (`NSApp.activate(ignoringOtherApps: true)`) and brings main window key/front.
4. **Open Quick Access** — row visible but **disabled**; trailing or subtitle **Coming later** (Quick Access implementation is out of scope).
5. **Divider**
6. **Lock** — calls `vaultSession.lock()`; disabled when already locked (defensive; panel should not appear unlocked if state is locked).
7. **Settings…** — opens the Settings scene (`SettingsLink` or `NSApp.sendAction(Selector(("showSettingsWindow:")), …)`).
8. **Quit MyPass** — terminates app (`NSApplication.shared.terminate(nil)`).

**Removed from current implementation (do not ship):**

- Locked/Unlocked status headline text
- Quick Search `TextField` bound to `navigationState.searchText`
- Password Generator button and sheet

## Recent Entries Block

### Eligibility and ranking

| Rule | Detail |
|---|---|
| Source | All entries in the unlocked vault (`EntrySearch.allEntries(in: database.rootGroup)`) |
| Exclude | Entries whose containing group is the Recycle Bin (`database.recycleBinGroupUUID` + `GroupTreeOperations.isRecycleBinGroup`, same logic as `EntryDetailView.isInRecycleBin`) |
| Sort | `lastAccessTime` descending |
| Limit | Top 5 |
| Empty | If no entries qualify, omit the entire block and its trailing divider |

### Row layout

Each row is a single clickable control (button or `NavigationLink`-style row):

| Column | Content |
|---|---|
| Leading | `LetterAvatarView` — **28×28 pt**, **6 pt** corner radius; title = entry title (empty → `(untitled)` for avatar letter, same as list) |
| Center | **Title** — semibold, single line, truncate tail. **Username** — 12 pt secondary, single line; show entry `login` when non-empty, otherwise omit subtitle line |
| Trailing | Chevron (`chevron.right`), tertiary tint |

Row height ~44–48 pt; hover highlight consistent with macOS menu extras (subtle gray fill).

**Not in scope:** security `!` badges, TOTP codes, favicons.

### Row action

On click:

1. Navigate **inside the menu bar panel** to a compact entry detail view (Apple Passwords–style) with **Back** returning to the recent-entries list and app-action menu.
2. Call `vaultSession.touchAccess(entryID:)` (see Access Tracking) — selecting from recents counts as access.

**Open MyPass** still activates the main window and brings it key/front; it does not open in-panel detail.

Do not change `selectedGroupID`, `selectedEntryID`, or search text when opening in-panel detail from recents.

## Access Tracking

Recent ranking depends on **`KdbxEntry.lastAccessTime`**, persisted to the vault on each touch.

### `VaultSession.touchAccess(entryID:)`

Add a small public API on `VaultSession`:

```swift
/// Bumps `lastAccessTime` for the entry and schedules a background persist.
/// No-op when vault is locked or entry ID is not found.
func touchAccess(entryID: UUID)
```

**Implementation:** Inside `mutate`, locate the entry in `rootGroup` (depth-first, same traversal as entry replacement). Set `lastAccessTime = Date()`. Do not alter `lastModificationTime` unless an existing convention requires it (KeePass touch-only updates access time only). `mutate` already triggers `persist`.

### Call sites (must all invoke `touchAccess`)

| Trigger | Location |
|---|---|
| User views entry in detail | `EntryDetailView` — on appear when bound entry ID matches displayed entry (or when selection settles on an entry) |
| Copy username | `EntryDetailView.copy(_:)` paths for username |
| Copy password | Same for password |
| Copy TOTP / OTP code | Same when TOTP copy affordance exists |
| Chrome extension fill | `ExtensionBridgeService` — after successful `.fillCredential` match, before returning `.credential(...)` |

**Not tracked in v1:** list selection alone without detail visible; search highlighting; password generator copy; failed extension fill.

## Architecture Notes

### Files

| Area | Path / action |
|---|---|
| Panel root | Replace body of `MyPass/UI/MenuBar/MenuBarExtraContent.swift` or split into `MenuBarPanelView`, `MenuBarUnlockPanelView`, `MenuBarRecentEntryRow` |
| App registration | `MyPass/MyPassApp.swift` — keep `MenuBarExtra("MyPass", systemImage: "key.fill")`; add `.menuBarExtraStyle(.window)`; gate on `showMenuBarExtra` per Settings spec |
| Access API | `MyPass/State/VaultSession.swift` — `touchAccess(entryID:)` |
| Extension bridge | `MyPass/State/ExtensionBridge/ExtensionBridgeService.swift` — touch on fill |
| Detail copies | `MyPass/UI/EntryDetail/EntryDetailView.swift` — touch on copy + detail appear |
| Shared avatar | Reuse `MyPass/UI/Shell/LetterAvatar.swift` (`LetterAvatarView`) |

### Environment

`MenuBarExtraContent` continues to receive `vaultSession` and `navigationState` via `@EnvironmentObject`. Unlock panel needs `BiometricKeyStoring` (default `BiometricKeyStore()`), injectable for tests.

### Keyboard shortcuts (dependency only)

Settings General defines **Show MyPass** and **Lock MyPass** global shortcuts. Wiring those hotkeys to the same actions as **Open MyPass** and **Lock** is implemented in the Settings/MyPassApp integration plan, not duplicated here. Menu bar panel buttons must remain functional when shortcuts are unset.

### Localization

English literals in source until Phase 7 (`2026-07-26-mypass-phase7-localization-design.md`).

## Acceptance Criteria

1. With vault **unlocked** and `showMenuBarExtra == true`, clicking the tray icon opens a **~280–320 pt window-style panel** (not a bare NSMenu).
2. Panel shows up to **5 recent entries** ranked by `lastAccessTime` descending; **Recycle Bin entries are excluded**; block and its divider are **hidden** when there are zero recents.
3. Each recent row shows **LetterAvatarView** (28×28, 6 pt radius), **title**, **username** (when present), and **chevron**; click opens **in-panel entry detail** with **Back**; **Open MyPass** still activates the main window.
4. Panel includes **Open MyPass**, **Open Quick Access** (disabled, **Coming later**), **Lock**, **Settings…**, and **Quit MyPass** in the specified order with dividers as above.
5. **Removed:** status text, Quick Search field, Password Generator — none appear in the menu bar panel.
6. With vault **locked**, clicking the tray shows **only** the unlock panel: **MyPass is locked**, optional **Touch ID**, **Enter Password** + **Unlock**; **no** recent entries or action menu until unlock succeeds.
7. **`VaultSession.touchAccess(entryID:)`** persists `lastAccessTime` and vault save on: detail view of entry, copy username/password/TOTP, and successful Chrome `.fillCredential`.
8. **`showMenuBarExtra == false`** hides the tray icon entirely (Settings spec behavior unchanged).
9. Tray icon remains **`key.fill`**.

## Out of Scope

| Item | Notes |
|---|---|
| Quick Access panel / **Open Quick Access** behavior | Disabled stub only; future spec |
| **Show Quick Access** keyboard shortcut (enabled) | Settings General — disabled until Quick Access exists |
| Menu bar search | Use main window search |
| Password generator in menu bar | Main window / entry editor only |
| Security `!` badges on recent rows | Future audit UI |
| Favicons in menu bar | UI shell backlog item 9 |
| **Click the icon to → Show Quick Access** picker option | Settings forward compatibility only |
| Global shortcut registration implementation | Settings redesign + `MyPassApp` plan |
| String Catalog / uk / de localization | Phase 7 |

## Implementation Handoff

Proceed via `writing-plans` → `executing-plans`. Plans must reference this spec by path, implement `touchAccess` before or with menu bar UI, and note dependency on approved Settings spec for `showMenuBarExtra` gating.

Suggested task split: (1) `VaultSession.touchAccess` + call-site wiring; (2) unlock panel; (3) unlocked panel + recents query; (4) `MyPassApp` style/gating; (5) tests for recents ranking, recycle-bin exclusion, and touchAccess persistence.

## References

| Resource | Path |
|---|---|
| Master product design | `docs/superpowers/specs/2026-07-21-mypass-design.md` |
| UI shell (letter avatar, backlog item 7) | `docs/superpowers/specs/2026-07-26-mypass-ui-shell-design.md` |
| Settings redesign (menu bar toggle, shortcuts) | `docs/superpowers/specs/2026-07-26-mypass-settings-redesign-design.md` |
| Current menu bar implementation | `MyPass/UI/MenuBar/MenuBarExtraContent.swift` |
| Letter avatar component | `MyPass/UI/Shell/LetterAvatar.swift` |
| Unlock UI patterns | `MyPass/UI/Unlock/UnlockView.swift` |
| Entry enumeration | `MyPass/UI/EntryList/EntrySearch.swift` |
| Recycle Bin detection | `MyPass/UI/Sidebar/GroupTreeOperations.swift`, `EntryDetailView.isInRecycleBin` |
| Chrome fill bridge | `MyPass/State/ExtensionBridge/ExtensionBridgeService.swift` |
| Navigation / selection | `MyPass/State/NavigationState.swift` |
