# MyPass UI Shell Design (Apple Passwords–inspired)

Date: 2026-07-26  
Status: approved

## Goal and Context

MyPass is a personal KeePass KDBX4 password manager for macOS. The app already uses a functional three-column `NavigationSplitView` shell (sidebar, entry list, detail) built with stock SwiftUI and no design system.

This spec defines **Wave 1: visual framework only** — restyling the existing shell to match an Apple Passwords–inspired look. New feature logic (smart filters, live counts, favorites storage, TOTP countdown behavior, security audit heuristics, menu bar redesign, and similar) is explicitly deferred to later specs and implementation plans.

**References reviewed:** 17 screenshots of Apple Passwords and 1Password (2026-07-26). **Visual direction:** closer to Apple Passwords (native, restrained, detail cards, category accent colors) — not 1Password marketing polish as the primary aesthetic.

**Parent design:** `docs/superpowers/specs/2026-07-21-mypass-design.md` (architecture, security, sync). This spec does not change product scope beyond UI presentation.

## Approach

**Chosen approach: "Apple shell + stub chrome" (Approach 2).**

| Rejected | Reason |
|---|---|
| Full Apple Passwords clone | Over-scoped; MyPass is KeePass-backed with a group tree, not Apple’s vault model |
| Minimal Form reskin | Too little visual lift; does not establish the target shell |

**What this means:**

- Adopt Apple Passwords layout, typography rhythm, spacing, and component shapes.
- Add **visual stubs** for Apple-only concepts (smart categories, security banner, inline TOTP chrome) where MyPass does not yet have backing logic.
- Preserve all existing KeePass behavior: group tree, entry CRUD, search, sync, and vault session lifecycle.

## Wave 1 Screens

| Screen | In Wave 1 | Notes |
|---|---|---|
| Main window (sidebar + list + detail) | Yes | Primary deliverable |
| Unlock | Yes | Restyle only |
| Settings | Yes | Single scrolling pane with helper subtext |
| Menu bar extra | No | Backlog item 7 |

## Main Window — Three-Column Shell

Keep `NavigationSplitView` with three columns. Restyle in place; do not replace the navigation model.

### Left sidebar (`GroupSidebarView`)

**Layout (top to bottom):**

1. **Smart categories section** — visual stubs only (see below).
2. **Divider.**
3. **Groups section** — real KeePass group tree (existing behavior).
4. **Recycle Bin** — pinned at bottom (existing group; same behavior as today).

**Smart categories (stubs):**

| Category | Accent color (pill background tint) | Placeholder count | Wave 1 behavior |
|---|---|---|---|
| All | System blue (`#007AFF` family) | Static placeholder (e.g. `58`) | Selecting shows all entries (same as today’s unfiltered list for the selected group context) |
| Favorites | Yellow (`#FFCC00` family) | `0` | No-op: selection falls back to All or keeps current group filter; no favorites data exists yet |
| Codes | Orange (`#FF9500` family) | Static fake (e.g. `15`) | No-op until TOTP filter exists |
| Security | Red (`#FF3B30` family) | Em dash (`—`) | No-op until audit logic exists |
| Deleted | Gray (`#8E8E93` family) | `0` or static fake | No-op; Recycle Bin remains the real deleted-items path |

Each category row: colored dot + label + trailing count, rounded pill background on selection, uppercase **Categories** section header (11 pt, secondary label color).

**Groups section:** uppercase **Groups** header; existing hierarchical tree with indentation. Group selection continues to drive the entry list. Do not replace groups with a 2×3 tile-only sidebar.

**Stub signaling:** Category rows are clickable for visual polish but must not imply working filters. Implementation may map all stub selections to the same data path as All, or ignore selection changes beyond highlight state — either is acceptable if behavior is consistent and documented in code comments.

### Center column — entry list (`EntryListView`)

**Header row:**

- Leading: section title (matches selected smart category label or selected group name).
- Trailing: existing sort and add-entry affordances (restyled, not removed).

**Search:** existing search field, restyled (rounded gray background, inset padding).

**List rows:**

| Element | Specification |
|---|---|
| Leading icon | 36×36 pt rounded square (8 pt corner radius). Wave 1: **letter avatar** — first letter of entry title, white text on a deterministic color derived from title hash. No favicon fetch. |
| Title | Semibold body text, primary label color |
| Subtitle | Username field if present; otherwise empty or secondary identifier; 12 pt secondary gray |
| Selection | Light blue row background + 3 pt leading accent bar (system blue) |
| TOTP inline slot | **Not rendered in Wave 1.** Do not reserve trailing countdown space in list rows yet (backlog item 4). |

Existing list sorting, selection binding, and keyboard navigation must continue to work.

### Right column — detail (`EntryDetailView`)

Two states: **empty** (no entry selected) and **filled** (entry selected).

#### Empty state

- Centered vertically and horizontally on light gray detail background (`#FAFAFA` family).
- SF Symbol or custom line-art illustration (~64 pt, ~35% opacity secondary gray) — person/key motif acceptable.
- Title: **Nothing Selected** (17 pt semibold, `#636366`).
- Hint: **Select an entry from the list** (13 pt secondary).

#### Filled state

**Top toolbar (trailing):**

- **Share** — disabled/greyed stub button (no share vault feature).
- **Edit** — wired to existing edit flow.

**Hero block (centered):**

- Large service icon: 72×72 pt, 16 pt corner radius, letter avatar (same letter/color rules as list, larger type).
- Entry title below icon: 22 pt bold, tight tracking.

**Fields card:**

- White rounded rectangle (12 pt radius), subtle border/shadow, max width ~420 pt centered in column.
- Rows: label left (secondary gray) / value right (primary). Standard rows: Username, Password (bullets + show/copy if already implemented), Website (link styling if URL present), Modified (formatted date), Notes (multiline, right-aligned text).
- **TOTP row:** when the entry has an OTP/TOTP field, show a row with a static placeholder code (or the current code if already computed by existing UI) and a **non-animated** circular ring as visual chrome only. Do not implement a live countdown timer in Wave 1 (timer animation and refresh behavior = backlog item 4).
- Row separators: 0.5 pt light divider between rows.

**History affordance:**

- Text button below card: **View History** — wired to existing history view if present; otherwise styled button that navigates to the same destination as today’s history entry point.

**Security warning card (visual stub only):**

- Below history button, full card width (max ~420 pt).
- Dashed border (`#C7C7CC`), light background, centered italic secondary text: **Security warning (coming later)**.
- Not interactive. No audit logic in Wave 1.

Password show/copy and field copy behaviors that already exist in the app remain functional inside the new card layout.

## Unlock Screen (`UnlockView`)

**Layout:** airy, centered column inside the unlock window — not a dense form.

| Element | Specification |
|---|---|
| App name | **MyPass**, 28 pt semibold, centered |
| Icon | Key SF Symbol or equivalent, secondary gray, below title |
| Master password field | Full-width secure field, rounded border, left-aligned placeholder **Master Password** |
| Primary button | **Unlock**, full-width, system blue |
| Secondary button | **Touch ID** with fingerprint icon — visual affordance; wire to existing Touch ID path if implemented |
| Helper text | 11 pt secondary, centered: **Vault is locked. Enter your master password or use Touch ID.** |

**Existing gap (not new backlog):** Touch ID unlock may be partially implemented in code (`VaultSession`, Keychain-derived key per master design). Wave 1 restyles the button; end-to-end biometric completion is backlog item 10, not invented here.

## Settings Screen (`SettingsView`)

**Layout:** single scrolling pane in Apple System Settings style — **not** a 1Password-style icon sidebar.

**Section pattern (repeat for each settings group):**

1. Section title (13 pt semibold).
2. Control row(s): label left, control right (toggle, stepper, segmented picker, button).
3. **Helper subtext** under each control or control group: 11 pt secondary gray, 1.45 line height, explains *why* the setting matters.

**Sections to restyle (preserve existing bindings):**

- Auto-lock (toggle + interval stepper + subtext)
- Clipboard clearing (interval stepper + subtext)
- Backups (folder picker + subtext)
- Sync (backend picker + Sync Now + subtext)
- Chrome extension (extension ID field + folder picker + subtext)

**Density:** Wave 1 does **not** add a Comfortable/Compact control. Only restyle existing settings sections. Density UI and layout behavior = backlog item 6 only.

## Optional Visual Tokens

Keep minimal — no heavy design system or token file required.

If shared constants reduce duplication, a small enum or struct is acceptable (e.g. `UIShellMetrics`):

| Token | Value |
|---|---|
| List row icon size | 36 pt |
| Detail hero icon size | 72 pt |
| Icon corner radius (list) | 8 pt |
| Icon corner radius (detail) | 16 pt |
| Card corner radius | 12 pt |
| Detail column background | `#FAFAFA` (adapt to light/dark via semantic colors where possible) |
| Sidebar width | ~200 pt (match current split behavior; avoid hard-blocking resize) |
| List column min width | ~240–280 pt |

Prefer SwiftUI semantic colors (`.secondary`, `.quaternary`, accent) over hard-coded hex in production code; hex values above are mockup references.

## Architecture Notes

- **Navigation:** retain `NavigationSplitView` three-column shell; restyle existing views rather than introducing parallel UI modules.
- **Views in scope:** `GroupSidebarView`, `EntryListView`, `EntryDetailView`, `UnlockView`, `SettingsView`.
- **KeePass model:** do not break group tree semantics, Recycle Bin, or entry field mapping.
- **Stubs:** non-functional chrome must be obvious — dashed security card, disabled Share, static category counts, no-op category filters, detail TOTP ring without live countdown — or documented in view code as intentional no-ops.
- **Localization:** Phase 7 (`docs/superpowers/specs/2026-07-26-mypass-phase7-localization-design.md`) is separate. English literal strings in Wave 1 shell work are acceptable until catalogs land.
- **Dark Mode:** use semantic/adaptive colors so light and dark variants remain readable without a separate mockup pass.

## Wave 1 In Scope

- Restyle the five views listed above.
- Smart category chrome (All, Favorites, Codes, Security, Deleted) with static placeholder counts.
- Empty detail state with illustration and hint copy.
- Filled detail card layout with hero icon, field rows, history affordance, dashed security stub.
- Detail TOTP row stub (static code + non-animated ring) when entry has an OTP/TOTP field; no inline TOTP in list rows.
- Settings helper subtext under controls.
- Optional lightweight shared metrics (spacing, icon sizes) if needed.

## Explicitly Out of Wave 1

| Item | Rationale |
|---|---|
| Wiring smart category filters | No backing data model |
| Live category counts | Requires filter + favorites + TOTP detection |
| Favorites flag / KDBX storage | New field semantics |
| Inline TOTP in list rows; live detail TOTP countdown timer | List badge, animated ring, and periodic code refresh |
| Security audit banner logic | Heuristics spec needed |
| Comfortable/Compact density UI + behavior | Settings control and layout rules not defined |
| Menu bar Quick Access redesign | Separate screen backlog |
| Entry list grouping by `lastModified` month | List model change |
| Favicon fetching / avatar cache | Network + cache layer |
| Watchtower/HIBP integration | External service |
| Shared vaults UI | Not in product scope |
| Passkeys UI | Later phase per master design |
| 2×3 tile-only sidebar replacing groups | Rejected layout |

## Feature Backlog

Numbered items for later implementation plans. Source column indicates primary UX reference.

| # | Feature | Source | Notes |
|---|---|---|---|
| 1 | Smart category filters | Apple Passwords | All/Favorites/Codes/Security/Deleted query semantics over KDBX entries |
| 2 | Live category counts | Apple Passwords | Recompute on vault change; Security count depends on audit rules |
| 3 | Favorites (entry flag / KDBX storage) | Apple Passwords | Persist favorite state in entry custom data or standard field per KeePass conventions |
| 4 | Inline TOTP in list + live detail countdown timer | Apple Passwords | RFC 6238 already in MyPassKit; animated ring refresh + list badge — Wave 1 detail stub is static/non-animated only |
| 5 | Security alert card (local heuristics first) | Apple Passwords | Duplicate, weak, and old-password detection before any HIBP |
| 6 | List density Comfortable/Compact | 1Password | Row height, icon size, and spacing presets |
| 7 | Menu bar: Open / Quick Access / Lock / Settings + shortcuts | 1Password | Redesign `MenuBarExtraContent`; not part of shell wave |
| 8 | Entry list grouping by lastModified month | Apple Passwords | Section headers in list column |
| 9 | Favicons / letter avatars with cache/fallback | 1Password | Fetch by URL, disk cache, letter fallback |
| 10 | Touch ID unlock end-to-end completion | Apple Passwords | Keychain access control, reboot fallback, error states — may partially exist |

## Acceptance Criteria (Wave 1 Shell)

1. **Main window structure** matches approved mockups: smart category stubs on top, real group tree below, Recycle Bin at bottom, restyled entry list, detail empty state or filled card.
2. **Unlock** presents centered airy layout with master password field, Unlock button, Touch ID affordance, and helper text.
3. **Settings** is a single scrolling pane with explanatory subtext under each control group; no icon sidebar navigation; no Comfortable/Compact density control added.
4. **Existing functionality preserved:** vault unlock/lock, group selection, entry open/edit/delete, search, sync, and Chrome extension settings continue to work without regression.
5. **Stub honesty:** smart categories do not filter data; security card is visibly non-functional; Share is disabled; static or fake counts are acceptable; detail TOTP row (when OTP field present) shows static/non-animated chrome only; list rows omit inline TOTP.
6. **No new feature logic** from the backlog table is required for Wave 1 sign-off.

## References

| Resource | Path |
|---|---|
| Main window mockup | `.superpowers/brainstorm/71545-1785057125/content/main-window-shell.html` |
| Entry detail card mockup | `.superpowers/brainstorm/74775-1785057243/content/entry-detail-card.html` (also `71545-…/entry-detail-card.html`) |
| Unlock and Settings mockup | `.superpowers/brainstorm/77686-1785057352/content/unlock-and-settings.html` |
| Master product design | `docs/superpowers/specs/2026-07-21-mypass-design.md` |
| Localization design | `docs/superpowers/specs/2026-07-26-mypass-phase7-localization-design.md` |
| Competitor screenshots (human reference) | User `Pictures/screenshots` folder, 2026-07-26 capture set |

## Implementation Handoff

Implementation proceeds via `writing-plans` → `executing-plans`. Plans should reference this spec by path and touch only the five views plus optional shared metrics — no backlog features unless a separate spec is approved.
