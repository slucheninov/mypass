# Chrome Extension — Popup List and Panel Redesign

**Date:** 2026-08-01  
**Status:** Approved

Follow-up to [2026-08-01-chrome-extension-icon-and-popup-fallback-design.md](./2026-08-01-chrome-extension-icon-and-popup-fallback-design.md) and [2026-07-25-mypass-phase4-chrome-extension-design.md](./2026-07-25-mypass-phase4-chrome-extension-design.md). Full popup visual redesign plus macOS-aligned credential rows; one small app-side pairing focus fix. No host protocol, credential payload, or unlock-from-extension work.

## Problem

The extension popup is a minimal status + plain-text list. It does not match the macOS app’s `EntryListRow` / `LetterAvatar` look, reads as unfinished next to the menu-bar panel (~280 pt family), and gives locked / pairing / empty states only a single line of copy with no structured layout.

During pairing, MyPass calls `MainWindowActivator.request()` when a code is generated. That steals focus from Chrome and **closes the popup**, forcing the user to reopen the extension and hunt for the code sheet while MyPass is in front — the opposite of the intended “see code in app, type in popup” flow.

## Goals

- Render credential list rows like macOS login entries: **36×36** letter avatar (corner radius **8**), **semibold** title, **12 px** secondary username (hidden when empty). Click → `fillCredential` unchanged.
- Redesign all popup states with a compact **~280 px** panel shell (padding **16–20 px**), **BrandKey** mark, clear titles, primary/secondary buttons. English strings only.
- **Locked:** BrandKey + headline + helper + **Retry** (re-query). No password field; no unlock IPC.
- **Pairing:** Title “Connect browser extension”; existing Connect → code entry flow with styled errors.
- **App not running:** BrandKey + status + **Retry** / **Open MyPass** (instructional only), as today but visually integrated.
- **Empty list:** Dedicated empty state copy in the new shell.
- **App fix:** Stop activating the main window when a pairing code is generated; keep activation for save-proposal path.

## Non-goals

- Unlock-from-extension (password → native host) — separate future spec.
- `entryType` card/notes icons in the popup (login letter avatars only; payload stays `id` / `title` / `username`).
- Dark mode (light theme only).
- Credential payload or host message shape changes.
- `background.js` error taxonomy or `content.js` changes.
- Phase 7 localization.

## Design

### Approach

**CSS + client-side LetterAvatar port** in `popup.js` / `popup.html`. Pure functions for letter, color hash, and row DOM construction; export hash/letter helpers for unit tests. Reuse BrandKey PNG from `ChromeExtension/icons/` (e.g. `icon32.png` or `icon48.png`) in panel headers. No native messaging or ChromeHost changes for icons.

### Panel shell (all states)

| Property | Value |
|----------|-------|
| Width | **280 px** (match current popup; same family as menu-bar panel) |
| Body padding | **16–20 px** (use consistent value, e.g. 16 px horizontal / 18 px vertical) |
| Font stack | System UI (`-apple-system`, `BlinkMacSystemFont`, `Segoe UI`, sans-serif) |
| Primary text | ~13–15 px, `#1d1d1f` or equivalent |
| Secondary text | **12 px**, `#6e6e73` |
| Primary button | Filled accent (system blue ~`#007AFF`), white label, 6–8 px vertical padding, border-radius 6 px |
| Secondary button | Neutral border or subtle fill, same sizing |
| Row hover | Light gray background `#eee` or `#f5f5f7`, border-radius 6–8 px |
| BrandKey header | Centered or leading; **32 px** display size in status panels |

Each state hides unrelated regions (`#list`, `#pairing-panel`, `#app-unavailable-actions`, state-specific blocks) via a single “show panel X” helper pattern to avoid overlapping UI.

### Credential list

**Row layout** (mirror `EntryListRow` login branch in `MyPass/UI/EntryList/EntryListView.swift`):

```
[ 36×36 avatar ]  Title (semibold, ~13–15 px)
                  Username (12 px secondary, omit if empty)
```

- Row: flex/horizontal, **12 px** gap between avatar and text column, **4 px** vertical padding per row.
- Click: existing `chrome.runtime.sendMessage({ type: 'fillCredential', id, url })` then `window.close()`.
- List header above rows: **“Select an entry to autofill:”** (secondary or semibold subhead).

**Empty list:** BrandKey optional; title **“No saved logins for this site”**; no list rows; no Retry unless user would benefit from re-query — show none (static empty state only).

### LetterAvatar port (JavaScript)

Port logic from `MyPass/UI/Shell/LetterAvatar.swift` exactly:

**Letter**

```javascript
function letterFromTitle(title) {
  const trimmed = title.trim();
  if (!trimmed) return '?';
  return trimmed[0].toUpperCase();
}
```

**Hash → palette index**

```javascript
function colorForTitle(title) {
  let hash = 0;
  for (const byte of new TextEncoder().encode(title)) {
    hash = ((hash + byte) * 31) >>> 0; // uint32 wrap like Swift &+ / &*
  }
  const index = ((hash % palette.length) + palette.length) % palette.length;
  return palette[index];
}
```

Use UTF-8 code units via `TextEncoder` so multi-byte titles hash consistently with Swift `title.utf8`.

**Palette** — same order as Swift: blue, green, orange, purple, pink, teal, indigo, mint, cyan, brown. Approximate **macOS light-mode system color** hex values for popup CSS (visual parity, not pixel-perfect):

| Index | SwiftUI | Hex (popup) |
|-------|---------|-------------|
| 0 | `.blue` | `#007AFF` |
| 1 | `.green` | `#34C759` |
| 2 | `.orange` | `#FF9500` |
| 3 | `.purple` | `#AF52DE` |
| 4 | `.pink` | `#FF2D55` |
| 5 | `.teal` | `#30B0C7` |
| 6 | `.indigo` | `#5856D6` |
| 7 | `.mint` | `#00C7BE` |
| 8 | `.cyan` | `#32ADE6` |
| 9 | `.brown` | `#A2845E` |

**Avatar DOM**

- Container: `36×36 px`, `border-radius: 8px`, background = palette color, flex center.
- Letter: white `#FFFFFF`, **semibold**, font size ≈ `36 * 0.42 ≈ 15 px`, rounded feel via system font (no custom webfont required).
- `aria-label`: `Icon for {title}` or `Icon for untitled entry` when title empty.

Export `letterFromTitle`, `colorForTitle`, and optionally `buildLetterAvatarElement(title)` from the testable module surface (`module.exports` block at bottom of `popup.js`, same pattern as existing exports).

### Locked state

| Element | Copy / behavior |
|---------|-----------------|
| BrandKey | Header mark |
| Title | **MyPass is locked** |
| Helper | **Open MyPass and unlock the vault** |
| Primary | **Retry** — re-run `queryCredentials` for active tab URL |

No password field. No unlock IPC. Do not show app-unavailable Retry/Open row on this path.

### Pairing state

| Element | Copy / behavior |
|---------|-----------------|
| Title | **Connect browser extension** |
| Primary | **Connect** — existing `startPairing` flow |
| Code entry | Shown after successful `pairingStarted`; hint **Enter the code shown in MyPass**; numeric input (6 digits, existing `normalizePairingCode`); **Submit** |
| Errors | Styled `#c00` or destructive red block below controls (existing messages: locked, invalid code, generic failure) |

Wire behavior unchanged: TTL 120 s, session storage for `pairingStartedAt`, `completePairing` → refresh credentials on success.

### App not running state

Integrate [icon-and-popup-fallback](./2026-08-01-chrome-extension-icon-and-popup-fallback-design.md) behavior into the new shell:

| Element | Copy / behavior |
|---------|-----------------|
| BrandKey | Header mark |
| Status | **MyPass not found. Make sure the app is installed and has been launched at least once (to register the native messaging host).** |
| Primary | **Retry** |
| Secondary | **Open MyPass** — reveals helper: **Open MyPass from Applications or the Dock. Unlock your vault if needed, then tap Retry.** |

Does not launch MyPass.

### Pairing focus fix (macOS app)

**File:** `MyPass/MyPassApp.swift`

In `pairingManager.onCodeGenerated`, **remove** `MainWindowActivator.request()`. Keep:

```swift
navigationState?.pendingPairingCode = code
```

The pairing code sheet continues to appear via `pendingPairingCode` binding elsewhere in the app UI.

**Keep** `MainWindowActivator.request()` in:

- `extensionBridgeService.onSaveProposal` — user should see the save prompt.
- Menu bar / shortcut `showHandler` paths — unchanged.

**Rationale:** Chrome extension popups close when the browser loses focus. Showing the code sheet without raising MyPass lets the user read digits in the app (already visible or via Dock click) while the popup stays open for entry.

## Files touched

| Path | Change |
|------|--------|
| `ChromeExtension/popup.html` | **Edit** — panel structure, state sections, CSS for shell, rows, buttons, avatars |
| `ChromeExtension/popup.js` | **Edit** — LetterAvatar port, `renderCredentials` row builder, state panel helpers, exports for tests |
| `ChromeExtension/tests/*.test.js` | **Edit** — tests for `letterFromTitle`, `colorForTitle` (deterministic titles), hash parity spot-checks vs known Swift outputs if documented |
| `MyPass/MyPassApp.swift` | **Edit** — remove `MainWindowActivator.request()` from `onCodeGenerated` only |
| `ChromeExtension/icons/icon32.png` (or 48) | **Reuse** — BrandKey in popup headers (no new asset generation required) |

**Out of touch:** `ChromeHost/`, `background.js`, `content.js`, native host manifest, credential IPC types.

## Acceptance criteria

1. **Credential rows** — Each login row shows 36×36 letter avatar (radius 8), semibold title, 12 px username when non-empty; colors match Swift `LetterAvatar.color(for:)` for a fixed set of test titles (at least 3 titles verified in JS tests).
2. **Fill unchanged** — Row click sends `fillCredential` with same `id` / `url` and closes popup.
3. **Locked panel** — BrandKey, “MyPass is locked”, helper copy, Retry re-queries; no password UI.
4. **Pairing panel** — “Connect browser extension”, Connect/code/Submit flow works; errors visible and styled; successful pair returns to credential list or empty state.
5. **App not running** — BrandKey, status, Retry and Open MyPass with instructional helper; no app launch.
6. **Empty list** — “No saved logins for this site” in redesigned shell; no spurious buttons.
7. **Shell** — 280 px width, 16–20 px padding, consistent buttons across states; light theme only.
8. **Focus fix** — With MyPass unlocked and pairing started from popup: popup stays open when code sheet appears in app (no `MainWindowActivator` on code generated); save-proposal path still activates main window.
9. **Tests** — Existing `ChromeExtension/tests` pass; new unit tests cover LetterAvatar helpers.

## Follow-ups

- **Unlock from extension** — Password field + secure IPC to native host / vault session; separate spec; not part of this work.
- **Dark mode** — Popup theme matching macOS dark appearance.
- **Entry type icons** — Card/notes rows if payload gains `entryType`.
- **Phase 7** — Localize popup strings (`en` / `uk` / `de`).
