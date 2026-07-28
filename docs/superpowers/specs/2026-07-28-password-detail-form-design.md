# Password Detail & Edit Form — Design

**Status:** Approved
**Date:** 2026-07-28
**Repo:** mypass (MyPass, macOS SwiftUI password manager, KDBX4-backed)

## Context

Wave 1 (`docs/superpowers/specs/2026-07-26-mypass-ui-shell-design.md`) and the entry/sidebar polish pass (`docs/superpowers/specs/2026-07-26-mypass-entry-sidebar-polish-design.md`) established the three-column shell, detail-column browse/edit routing, and a card-based **browse** layout in `EntryDetailView`. Edit still uses a bare SwiftUI `Form` in `EntryEditView`, so browse and edit feel visually disconnected. Browse also retains Wave 1 placeholders: a static TOTP ring (22 pt, non-animated), a dashed **Security warning** stub, full URL text in the Website row, and a **Delete** button in browse mode.

Entries today store a single URL in the standard KDBX `<String Key="URL">` field via `KdbxEntry.url`. The Chrome extension matcher (`ExtensionEntryMatcher`) compares only that primary URL. KeePass ecosystem clients commonly store **additional** URLs as a KDBX **`StringArray`** element (not a newline-delimited string). MyPassKit's `KdbxXmlCoder` currently round-trips only `<String>` fields into `[KdbxField]`; `StringArray` is ignored on read and never written.

This spec polishes **browse** (`EntryDetailView`) and visually aligns **edit** (`EntryEditView`) within the existing detail-column presentation model. It does **not** merge browse and edit into Apple Passwords-style inline field editing.

**Parent documents:**

| Document | Relationship |
|---|---|
| `docs/superpowers/specs/2026-07-26-mypass-ui-shell-design.md` | Hero icon, fields card chrome, TOTP row introduction. **This spec supersedes Wave 1 TOTP stub behavior, security warning stub, and browse Delete affordance.** |
| `docs/superpowers/specs/2026-07-26-mypass-entry-sidebar-polish-design.md` | Detail-column edit routing, Cancel/Save toolbar, group picker on Save. **This spec adds browse context menus, immediate group move, Websites sheet, and edit-mode visual reskin; Delete moves to edit only.** |

## Goals

- Polish browse detail: hero, ordered field card, live TOTP countdown ring, domain-only Website display, context menus, Show Large Type popovers.
- Reskin edit to share browse's hero + field-card frame while keeping Cancel/Save toolbar and existing save semantics.
- Add multi-URL storage via real KDBX `StringArray` in MyPassKit, with `entry.urls` convenience API and extension matching against all URLs.
- Provide a **Websites** sheet (Apple Passwords–style) for managing primary + additional URLs from browse and edit.
- Remove the security warning stub; remove Delete from browse; add red text Delete in edit only.

## Non-goals

- Real security audit UI or Security smart-category heuristics (remain stub/no-op elsewhere).
- Share toolbar wiring (disabled stub may remain).
- Apple Passwords–style inline merge of browse and edit (single surface, tap-to-edit fields).
- Menu bar extra panel redesign (optional follow-up; out of scope here).
- Full Public Suffix List domain extraction (keep existing naive registrable-domain heuristic; document limitation).
- Localization catalogs (Phase 7); English strings in source until then.
- List-row inline TOTP or favicon fetch.

## Approach

**Chosen approach: polish browse + visually align edit.**

| Rejected | Reason |
|---|---|
| Full Apple inline-edit detail | Over-scoped; KeePass edit has many fields, group move, OTP reveal, and custom fields better suited to explicit edit mode |
| Edit stays bare `Form` | Fails visual parity with browse card established in Wave 1 |
| Additional URLs as newline-delimited `String` | Not interoperable with KeePass `StringArray`; breaks round-trip with other clients |

Browse remains read-oriented with copy/context-menu actions. Edit remains the explicit mutation surface (Save/Cancel, Delete, field text inputs, password generator, OTP reveal).

## Design

### Shared visual frame (browse and edit)

Both modes render inside the detail column with the same top-level structure:

1. **Hero block** — centered `LetterAvatarView` at `UIShellMetrics.detailHeroIconSize` (72 pt) / `detailHeroIconCornerRadius` (16 pt), entry title below (22 pt bold).
2. **Fields card** — `DetailFieldsCard` styling: white/control background, 12 pt corner radius, subtle border/shadow, max width `UIShellMetrics.cardMaxWidth` (~420 pt), 0.5 pt row dividers.
3. **Below card (browse only)** — **View History** text button (unchanged behavior); **Restore** when entry is in Recycle Bin. No Delete, no security stub.

#### Hero letter sizing

Increase the letter glyph so it fills the rounded square better than today's `size * 0.42` ratio. Target: visually centered, semibold rounded letter occupying ~55–60% of the square height (adjust `LetterAvatarView` font scale or add a detail-hero-specific metric in `UIShellMetrics`). List-row avatars (36 pt) keep current sizing.

### Browse field card — row order and content

Rows appear in this order when their data is present (always show Username, Password, Modified; others conditional):

| # | Label | Value / behavior |
|---|---|---|
| 1 | Username | Entry login; empty string shows blank value area |
| 2 | Password | Bullets or revealed text; existing show/hide eye control |
| 3 | Verification Code | Only when `totpSecretBase32` is non-empty |
| 4 | Website | Only when `entry.urls` is non-empty (see Multi-URL) |
| 5 | Group | Current group name |
| 6 | Modified | `lastModificationTime`, abbreviated date + short time |
| 7 | Notes | Only when notes non-empty |
| 8+ | Custom fields | Existing additional non-standard fields, excluding the StringArray storage key (see Multi-URL) |

**Website display:** show **registrable domain only** — no scheme, path, query, or fragment. Use a shared helper (extend or wrap `ExtensionEntryMatcher.registrableDomain(from:)`):

- `https://login.example.com/path?q=1` → `example.com`
- `example.co.uk` → `example.co.uk` (naive last-two-labels heuristic; known limitation, no PSL)
- When multiple URLs exist, the card shows the **primary** URL's domain only (`entry.url` / first element of `urls`).

Link styling (accent color) applies to the domain text even though the displayed string is not a full URL.

### TOTP row (browse)

Replace `TOTPRingChrome` static stub with a **live** countdown:

- Code from `TOTPCode.currentCode(...)` with existing defaults (6 digits, 30 s period, SHA-1).
- Trailing **green** circular progress ring driven by `TOTPCode.secondsRemaining(period:now:)` — arc animates smoothly as seconds elapse; ring diameter **16–18 pt** (down from current 22 pt).
- Refresh code and ring every **1 s** via the existing `Timer.publish(every: 1, ...)` on `EntryDetailView` (or shared helper if extracted).
- Hide ring while the row shows **Copied** flash (same as today).
- Monospaced code font retained.

### Interactions — primary click (browse)

Unchanged from current behavior for Username, Password, and Verification Code:

- **Left click** (plain button row) → copy field value to pasteboard, schedule `ClipboardAutoClear`, brief **Copied** label (~1.2 s), `vaultSession.touchAccess`.
- Password row keeps separate show/hide control; clicking the value area copies without toggling reveal.

Website and Group rows do **not** copy on primary click (actions live in context menu).

### Interactions — context menus (browse)

Attach `.contextMenu` to interactive field rows. Trigger via standard macOS **secondary click** (right-click / two-finger tap). **No** double-click menu.

| Row | Menu items |
|---|---|
| Username | **Copy Username** · **Show Large Type** |
| Password | **Copy Password** · **Show Large Type** |
| Verification Code | **Copy Code** · **Show Large Type** |
| Website | **Open Website** · **Copy Website** · **Change Website** |
| Group | Submenu listing all groups **except Recycle Bin**; current group checked; selecting another group **moves the entry immediately** via `GroupTreeOperations.moveEntry(withID:to:in:)` + `vaultSession.mutate` (no Save required) |

**Show Large Type:** `popover` anchored near the field row (not a sheet). Large monospaced or rounded system font, generous padding. Password popover **always shows cleartext** regardless of browse reveal state. TOTP popover shows the **current** code (same 1 s refresh while open). Dismiss on click outside or Escape.

**Website actions:**

- **Open Website** — `NSWorkspace.shared.open` with the **full primary URL** string (`entry.url`). Prepend `https://` when the stored value lacks a scheme (same normalization as today for bare hosts).
- **Copy Website** — pasteboard receives the **full primary URL**, not the displayed domain.
- **Change Website** — presents the **Websites sheet** (below).

### Delete and Recycle Bin (browse)

- **Remove** the browse-mode **Delete** button entirely.
- **Remove** `SecurityWarningStubView` and all references.
- **Restore** button when entry is in Recycle Bin: unchanged behavior (soft-deleted entry → restore to root group, clear selection as today).

### Edit mode (`EntryEditView`)

Replace bare `Form` with the **same hero + fields card** visual frame. Field **controls** remain editable (text fields, secure field, group picker integration, notes editor, OTP section, custom fields, password generator entry point).

| Element | Specification |
|---|---|
| Toolbar | **Cancel** / **Save** unchanged (`NavigationState` detail presentation, `EntryEditSaveLogic`) |
| Layout | Hero + card wrapping edit controls styled like browse rows (label left, control right) |
| Group | `GroupPickerView` inside card row; move on **Save** when group changes (existing polish spec behavior) |
| URL field | Primary URL text field remains in edit form; **Change Website** / multi-URL management via **Websites sheet** (toolbar button or context menu equivalent on URL row — implementer may add an **Edit Websites…** affordance beside the URL field) |
| Delete | **Red text** button (**Delete**, destructive plain text style — not a filled red pill), placed below the card (mirror prior browse Delete placement). Soft-deletes to Recycle Bin via `GroupTreeOperations.softDeleteEntry`. On success, exit edit mode and clear selection. **Only in edit**, never in browse |
| OTP / custom fields | Existing reveal/save rules from polish spec unchanged |

Browse **Edit** toolbar button continues to call `navigationState.presentEdit(entryID:)`.

### Multi-URL model and KDBX `StringArray`

#### Storage (MyPassKit)

| Concept | KDBX representation |
|---|---|
| Primary URL | Existing `<String Key="URL">` — unchanged |
| Additional URLs | `<StringArray Key="KP2A_URL">` with one `<Value>` child per extra URL |

**Key name:** `KP2A_URL` — de facto KeePass ecosystem convention (Keepass2Android origin; KeePassXC reads/writes this key for additional URLs). Document in code comments on the model property.

**Not allowed:** encoding extras as newline-separated text in a custom `String` field, or any reserved-string workaround.

#### Model changes

Extend `KdbxEntry` (MyPassKit) with structured StringArray support:

- Internal representation: e.g. `additionalURLs: [String]` on entry or parallel to `fields`, serialized only through `KdbxXmlCoder`.
- **`KdbxXmlCoder`:** on decode, parse `<StringArray>` elements; on encode, emit `StringArray` when additional URLs non-empty. Unknown StringArray keys may be preserved opaquely or ignored — **`KP2A_URL` is the only key MyPass reads/writes for URLs**.
- Round-trip tests required (see Testing).

#### App convenience API (`KdbxEntry+Convenience`)

```swift
var urls: [String]  // primary (if non-empty) + KP2A_URL extras, deduplicated, order preserved
```

- **Getter:** if `url` (primary) is non-empty, it is `urls[0]`; append `KP2A_URL` values excluding duplicates of primary.
- **Setter:** first element → primary `URL` field; remainder → `KP2A_URL` StringArray; empty setter clears primary and removes StringArray.
- Existing `var url: String` remains primary-only get/set for call sites that need a single URL.

#### UI filtering

The StringArray storage key **`KP2A_URL` must not appear** in browse custom-field rows or edit **Additional Fields** UI. Exclude it (and the primary `URL` key) from `additionalFields` / `extraFields` filters.

#### Extension matching

Update `ExtensionEntryMatcher.matchingEntries` to compare the page URL's registrable domain against **every** URL in `entry.urls`, not only `entry.url`.

### Websites sheet

Modal sheet shared by browse (**Change Website** context menu) and edit (URL management affordance).

| Element | Specification |
|---|---|
| Title | **Websites** |
| Header copy | Short autofill explanation referencing entry title, e.g. "These websites will be used to autofill **{title}**." |
| List | One row per URL in `entry.urls`; primary URL visually indicated (e.g. "Primary" badge or first-row default) |
| Add / Remove | **+** appends empty editable row; **−** removes row; zero URLs after save is valid |
| Primary promotion | List order is authoritative: after trim/drop-blanks, **first remaining row is primary** (`URL`); subsequent rows are `KP2A_URL` extras. Reorder by editing values (move text), not a separate “Set as Primary” control |
| **Done** | Trims each row, drops blank entries, writes the remaining list via `entry.urls` setter (may be empty), **`vaultSession.mutate` immediately** (browse and edit — no waiting for edit Save) |
| Cancel | Dismiss without persisting (edit draft URLs unchanged until Done) |

Style: compact form/list resembling Apple Passwords URL editor (inset grouped list, minimal chrome).

## Architecture notes

### Files likely touched

| File | Change |
|---|---|
| `MyPass/UI/EntryDetail/EntryDetailView.swift` | Row order, domain display, menus, popovers, TOTP ring, remove Delete/security stub |
| `MyPass/UI/EntryDetail/EntryEditView.swift` | Card layout reskin, Delete button, Websites entry point |
| `MyPass/UI/Shell/LetterAvatar.swift` | Detail hero letter scale |
| `MyPass/UI/Shell/UIShellMetrics.swift` | Optional detail-hero font ratio constant |
| `MyPass/UI/EntryDetail/GroupPickerView.swift` | Reuse for Group context submenu or extract group list builder |
| `MyPass/Models/KdbxEntry+Convenience.swift` | `urls` computed property |
| `Packages/MyPassKit/.../KdbxEntry.swift` | StringArray / additional URL storage |
| `Packages/MyPassKit/.../KdbxXmlCoder.swift` | StringArray read/write |
| `MyPass/State/ExtensionBridge/ExtensionEntryMatcher.swift` | Match all `urls` |
| `MyPass/ContentView.swift` | Detail column hosts sheet if presented at shell level |
| `MyPass/Models/TOTPCode.swift` | `secondsRemaining` used by ring (no API change required) |
| `MyPass/UI/EntryDetail/ClipboardAutoClear.swift` | Unchanged; still used by copy paths |
| New: `WebsitesSheet.swift`, `LargeTypePopover.swift`, `TOTPCountdownRingView.swift` | Optional extraction |

### Domain display helper

Add `EntryURLDisplay.domain(from:)` (or extend `ExtensionEntryMatcher`) used by browse Website row and anywhere domain-only text is shown. **Display** uses domain; **Open/Copy** use full primary URL.

## Testing

### Unit tests (required)

| Area | Cases |
|---|---|
| `KdbxXmlCoder` StringArray | Encode/decode entry with `KP2A_URL` multiple values; entry with only primary URL has no StringArray element; round-trip with obfuscated protected fields unaffected |
| `urls` convenience | Getter merges primary + extras deduped; setter splits primary vs extras; clearing empties both |
| Domain helper | `https` URL, bare host, empty, path/query stripped via registrable domain |
| `ExtensionEntryMatcher` | Entry matches page when **any** url in `urls` shares registrable domain; no match when only extras differ by domain from primary |

Extend `KdbxXmlCoderTests`, `KdbxEntryConvenienceTests`, `ExtensionEntryMatcherTests` accordingly.

### Manual verification

- Browse/edit visual parity (hero + card).
- Context menus on all specified rows; group move immediate in browse.
- Large Type popover for username/password/TOTP.
- TOTP ring animates green countdown at ~17 pt.
- Websites sheet add/remove/Done persists in browse without entering edit Save.
- Delete only in edit (red text); Restore still works in Recycle Bin browse.
- Security stub absent.
- `KP2A_URL` not shown as custom field.

## Acceptance criteria

- Browse and edit share hero + `DetailFieldsCard` visual frame; edit no longer uses a bare full-width `Form` as the primary layout.
- Browse field card row order: Username, Password, Verification Code (when present), Website (domain only), Group, Modified, Notes (when present), then custom fields.
- Username, Password, and Verification Code: left click copies with brief **Copied** flash; context menu offers Copy + Show Large Type popover (password cleartext in popover; TOTP live code).
- Website row displays primary domain only; context menu Open/Copy use full primary URL; Change Website opens Websites sheet.
- TOTP row shows green animated countdown ring (~16–18 pt) using `TOTPCode.secondsRemaining`, refreshing every 1 s.
- Multi-URL: additional URLs stored as KDBX `StringArray` key **`KP2A_URL`**; `entry.urls` API; codec round-trip; `ExtensionEntryMatcher` matches all URLs; StringArray hidden from Additional Fields UI.
- Websites sheet: title **Websites**, autofill explanation, list with +/−, **Done** persists immediately via `vaultSession.mutate`.
- Group context menu lists groups excluding Recycle Bin; selection moves entry immediately in browse.
- Delete removed from browse; red text Delete only in edit; security warning stub removed entirely.
- Recycle Bin browse still shows **Restore** when applicable.
- Unit tests cover StringArray codec, `urls` convenience, domain helper, and matcher all-URLs behavior.

## Out of scope (explicit)

| Item | Notes |
|---|---|
| Security audit UI | No replacement for removed stub in this pass |
| Share toolbar | Stays disabled or unchanged |
| Inline browse/edit merge | Future consideration only |
| Menu bar panel | See menu bar redesign spec; optional later |
| Public Suffix List | Registrable-domain heuristic remains naive |
