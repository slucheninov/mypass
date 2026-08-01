# Chrome Extension — Toolbar Icon and Popup Fallback

**Date:** 2026-08-01  
**Status:** Approved

Follow-up to [2026-07-25-mypass-phase4-chrome-extension-design.md](./2026-07-25-mypass-phase4-chrome-extension-design.md). Minimal polish for extension discoverability and recovery when MyPass is not running — no IPC, host, or app changes.

## Problem / context

Two related issues show up during normal extension development and first use:

1. **Gray “M” toolbar icon** — `manifest.json` has no `icons` or `action.default_icon`, so Chrome falls back to a generic letter badge instead of the MyPass brand mark.
2. **Popup load failure after folder moves** — If the unpacked extension path moves or is deleted, opening the popup shows Chrome’s **ERR_FILE_NOT_FOUND** (e.g. missing `popup.html`). Developers must reload the unpacked extension from the correct folder; this is undocumented today.

When MyPass is quit or the native messaging host is unavailable, the popup already shows a static status line (`MyPass not found. Make sure the app is installed…`) with no way to retry without closing and reopening the popup. Users who launch MyPass after opening the popup have no guided recovery path.

## Goals

- Show the **BrandKey** icon in the Chrome toolbar after a proper unpacked load.
- Keep popup assets **co-located** under `ChromeExtension/` so relative manifest paths resolve reliably.
- Document **Reload unpacked** in `RUN.md` when ERR_FILE_NOT_FOUND appears after a moved/deleted folder.
- On the existing **app-not-running / host-unavailable** error path only, add **Retry** (re-query credentials) and **Open MyPass** (instructional copy; does not launch the app).

## Non-goals

- Custom URL scheme or deep link to open MyPass from the extension.
- Changes to the macOS app, ChromeHost, or native messaging host registration.
- New error taxonomy, sub-states, or background error classification.
- In-field autofill button, match-count badge, or toolbar badge text.
- Safari / shared WebExtension work (Phase 4b).
- Phase 7 localization (UI strings stay English in source for now).

## Design

### Approach

**Minimal:** BrandKey icons + reliable popup load + RUN.md note + Retry / instructional Open MyPass on app-not-running state. Reuse existing `classifyGetCredentialsResponse` → `'error'` path; no new response types.

### Toolbar icons

**Source:** `MyPass/Assets.xcassets/BrandKey.imageset/` (`BrandKey.png`, `BrandKey@2x.png`).

**Output:** Generate and commit PNGs under `ChromeExtension/icons/`:

| File | Size (px) |
|------|-----------|
| `icon16.png` | 16 |
| `icon32.png` | 32 |
| `icon48.png` | 48 |
| `icon128.png` | 128 |

Downscale from `@2x` where needed so edges stay sharp at 16px.

**Manifest wiring** (`ChromeExtension/manifest.json`):

- Top-level `"icons"` map: `"16"`, `"32"`, `"48"`, `"128"` → relative paths under `icons/`.
- `"action"."default_icon"`: same four sizes (toolbar uses 16/32 depending on DPI).

No other manifest fields change for this work.

### Popup load reliability

All popup entry points remain under `ChromeExtension/`:

- `popup.html` (referenced by `action.default_popup`)
- `popup.js`
- Icon assets referenced only from manifest (not from popup HTML for this change)

Relative paths in `manifest.json` must match on-disk layout. After moving or recloning the repo, **Load unpacked** again from `ChromeExtension/` and use **Reload** on `chrome://extensions` — do not rely on Chrome remembering an old absolute path.

### Popup fallback UI (app-not-running only)

**Trigger:** Same conditions as today’s `'error'` branch in `handleCredentialsResponse`:

- `classifyGetCredentialsResponse(response) === 'error'` (null response, `type: 'error'`, etc.).
- Early exit when active tab has no URL (same status string as credential error today).

**Unchanged states:** locked, pairing required, empty credential list, credential list rendering — no action buttons added.

**Layout:** Below the existing status text, show a small action row (new container in `popup.html`, styled consistently with pairing buttons):

| Control | Role | Behavior |
|---------|------|----------|
| **Retry** | Primary button | Clear `#list` and any error-action UI; re-run `queryCredentials` for the current active tab URL (same as popup open). |
| **Open MyPass** | Secondary button | Does **not** launch MyPass. On click, expand or replace helper copy: open MyPass from Applications or the Dock, unlock the vault if needed, then tap **Retry**. |

**Copy (English, Phase 7 later):**

- Status (unchanged): `MyPass not found. Make sure the app is installed and has been launched at least once (to register the native messaging host).`
- Open MyPass helper (shown after secondary click): e.g. `Open MyPass from Applications or the Dock. Unlock your vault if needed, then tap Retry.`

Hide the action row whenever the popup transitions to locked, pairing, list, or empty-list states.

**Implementation sketch:** Extract a `showAppUnavailableActions(url)` / `hideAppUnavailableActions()` pair called from the `'error'` path and cleared at the start of successful state handlers. Retry calls existing `queryCredentials(url)`; preserve active tab URL in closure or re-query tab on click.

### RUN.md (Ukrainian)

Add a short troubleshooting note (file stays Ukrainian per project rules):

- If the popup shows **ERR_FILE_NOT_FOUND** or Chrome reports a missing file, the unpacked extension path was moved or deleted — open `chrome://extensions`, **Load unpacked** again from the repo’s `ChromeExtension/` folder, then **Reload**.
- Optional one-liner: after a correct load, the toolbar shows the MyPass key (BrandKey) icon instead of a gray letter.

No English duplicate in RUN.md for this note.

## Files touched

| Path | Change |
|------|--------|
| `ChromeExtension/icons/icon{16,32,48,128}.png` | **Add** — generated from BrandKey assets |
| `ChromeExtension/manifest.json` | **Edit** — `icons`, `action.default_icon` |
| `ChromeExtension/popup.html` | **Edit** — action row container + minimal CSS |
| `ChromeExtension/popup.js` | **Edit** — show/hide Retry + Open MyPass on `'error'` path |
| `ChromeExtension/tests/*.test.js` | **Edit only if** a clear pure-JS hook exists (e.g. exported render helper for error actions) |
| `RUN.md` | **Edit** — Ukrainian ERR_FILE_NOT_FOUND / reload note |

**Out of touch:** `ChromeHost/`, `MyPass/` app targets, `background.js` error taxonomy, `content.js`, native host manifest.

## Acceptance criteria

1. **Manifest paths** — Every icon path in `manifest.json` exists on disk under `ChromeExtension/`.
2. **Toolbar icon** — Load unpacked from `ChromeExtension/` → toolbar shows BrandKey key icon (not gray “M”).
3. **Popup opens** — Click extension action → `popup.html` loads without ERR_FILE_NOT_FOUND when path is valid.
4. **App quit recovery** — With MyPass quit, popup shows existing status plus **Retry** and **Open MyPass**; **Open MyPass** shows instructional copy only (no app launch); after launching MyPass and unlocking, **Retry** loads credentials or the appropriate next state (locked / pairing / list).
5. **Other states unchanged** — Locked, pairing, empty list, and credential list UIs behave as before; no action buttons on those paths.
6. **Tests** — Existing `ChromeExtension/tests` pass (`node --test` or project convention). Add a small pure-JS test only if error-action rendering is exported with a stable hook; otherwise manual verification suffices.
7. **RUN.md** — Ukrainian note documents reload-after-move and mentions BrandKey toolbar icon after proper load.

## Out of scope / follow-ups

- **URL scheme** — `mypass://` or equivalent to open the app from the extension (future product decision).
- **macOS / host** — Auto-register or repair native messaging host from the extension; app-side host install changes.
- **Richer errors** — Distinguish host missing vs app locked vs network; new `background.js` message types.
- **Toolbar badge** — Per-site match count or “!” indicator.
- **In-page fill button** — Content-script UI on login forms.
- **Phase 7** — Localize popup strings (`en` / `uk` / `de` catalogs).
