# Chrome Extension Icon and Popup Fallback Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add BrandKey toolbar icons, wire manifest icon paths, and show Retry / Open MyPass recovery actions on the existing app-not-running popup error path, plus a Ukrainian RUN.md troubleshooting note for ERR_FILE_NOT_FOUND.

**Architecture:** Generate four PNG sizes from `BrandKey@2x.png` into `ChromeExtension/icons/` and reference them from top-level `icons` and `action.default_icon` in `manifest.json`. Extend `popup.html` / `popup.js` with a hidden action row shown only when `classifyGetCredentialsResponse` returns `'error'` (including the no-active-tab-URL early exit); Retry re-runs credential lookup, Open MyPass reveals instructional copy only. Export small pure-JS constants and `shouldShowAppUnavailableActions` for unit tests; DOM show/hide stays in the popup IIFE.

**Tech Stack:** MV3 Chrome extension (HTML/CSS/JS), macOS `sips` for icon downscaling, `node:assert` tests run via `node ChromeExtension/tests/<file>.js`.

## Global Constraints

- English UI strings in source (Phase 7 localization later).
- `RUN.md` troubleshooting note must be Ukrainian only (no English duplicate).
- No custom URL scheme, deep link, or app launch from the extension.
- No changes to macOS app, `ChromeHost/`, native messaging host, `background.js` error taxonomy, or `content.js`.
- BrandKey source: `MyPass/Assets.xcassets/BrandKey.imageset/` (`BrandKey.png`, `BrandKey@2x.png`); downscale from `@2x` for sharp 16px icons.
- Touch only `ChromeExtension/` (icons, manifest, popup, tests) and `RUN.md`.
- Popup assets stay co-located under `ChromeExtension/` with relative manifest paths.
- Unchanged popup states: locked, pairing required, empty credential list, credential list — no action buttons on those paths.
- Existing `ChromeExtension/tests` must pass (`node ChromeExtension/tests/<file>.js`; also covered by `./scripts/test.sh` when Node is installed).

---

## File Structure

| Path | Responsibility |
|------|----------------|
| `ChromeExtension/icons/icon{16,32,48,128}.png` | Generated BrandKey toolbar / store icons |
| `ChromeExtension/manifest.json` | Top-level `icons` + `action.default_icon` maps |
| `ChromeExtension/popup.html` | `#app-unavailable-actions` row + minimal CSS matching pairing buttons |
| `ChromeExtension/popup.js` | Pure exports for copy/gating; DOM helpers `showAppUnavailableActions` / `hideAppUnavailableActions`; wire `'error'` path and hide on other states |
| `ChromeExtension/tests/background.manifest.test.js` | Assert icon manifest keys and on-disk PNG existence |
| `ChromeExtension/tests/popup-fallback.test.js` | Assert exported constants and `shouldShowAppUnavailableActions` |
| `RUN.md` | Ukrainian ERR_FILE_NOT_FOUND / reload note (insert after “Як додати в Chrome” step 7) |

---

### Task 1: BrandKey icons and manifest wiring

**Files:**
- Create: `ChromeExtension/icons/icon16.png`
- Create: `ChromeExtension/icons/icon32.png`
- Create: `ChromeExtension/icons/icon48.png`
- Create: `ChromeExtension/icons/icon128.png`
- Modify: `ChromeExtension/manifest.json`
- Modify: `ChromeExtension/tests/background.manifest.test.js`

**Interfaces:**
- Consumes: `MyPass/Assets.xcassets/BrandKey.imageset/BrandKey@2x.png` (400×400 px).
- Produces: relative paths `icons/icon16.png` … `icons/icon128.png` referenced identically in `manifest.icons` and `manifest.action.default_icon`.

- [ ] **Step 1: Generate icon PNGs with sips**

From repo root:

```bash
mkdir -p ChromeExtension/icons
SOURCE="MyPass/Assets.xcassets/BrandKey.imageset/BrandKey@2x.png"
for size in 16 32 48 128; do
  sips -z "$size" "$size" "$SOURCE" --out "ChromeExtension/icons/icon${size}.png"
done
```

Expected: four files exist; `sips -g pixelWidth -g pixelHeight ChromeExtension/icons/icon16.png` reports `pixelWidth: 16`, `pixelHeight: 16` (likewise 32/48/128 for the other files).

- [ ] **Step 2: Wire manifest.json**

Replace the existing `"action"` block in `ChromeExtension/manifest.json` and add top-level `"icons"` immediately after `"description"`:

```json
  "description": "Autofill and save logins from MyPass",
  "icons": {
    "16": "icons/icon16.png",
    "32": "icons/icon32.png",
    "48": "icons/icon48.png",
    "128": "icons/icon128.png"
  },
  "permissions": ["nativeMessaging", "activeTab", "storage"],
```

```json
  "action": {
    "default_popup": "popup.html",
    "default_icon": {
      "16": "icons/icon16.png",
      "32": "icons/icon32.png",
      "48": "icons/icon48.png",
      "128": "icons/icon128.png"
    }
  },
```

No other manifest fields change.

- [ ] **Step 3: Extend manifest test (write assertions before relying on them)**

Append to `ChromeExtension/tests/background.manifest.test.js` before the final `console.log`:

```javascript
const iconsDir = path.join(__dirname, '..', 'icons');
const expectedSizes = ['16', '32', '48', '128'];
assert.ok(manifest.icons, 'manifest must define top-level icons');
assert.ok(manifest.action.default_icon, 'manifest.action must define default_icon');
for (const size of expectedSizes) {
  const relPath = `icons/icon${size}.png`;
  assert.strictEqual(manifest.icons[size], relPath, `manifest.icons["${size}"] must be ${relPath}`);
  assert.strictEqual(manifest.action.default_icon[size], relPath, `action.default_icon["${size}"] must be ${relPath}`);
  const absPath = path.join(__dirname, '..', relPath);
  assert.ok(fs.existsSync(absPath), `${relPath} must exist on disk`);
  const stat = fs.statSync(absPath);
  assert.ok(stat.size > 0, `${relPath} must be non-empty`);
}
```

- [ ] **Step 4: Run tests**

Run:

```bash
node ChromeExtension/tests/background.manifest.test.js
node ChromeExtension/tests/formDetection.test.js
node ChromeExtension/tests/pairing.test.js
```

Expected: all three print `OK` / `manifest.json OK` with exit code 0.

- [ ] **Step 5: Manual toolbar check (quick)**

1. Open `chrome://extensions`, enable Developer mode.
2. **Load unpacked** → select `<repo>/ChromeExtension/`.
3. Pin MyPass on the toolbar.

Expected: BrandKey key icon visible (not gray letter “M”). Clicking opens `popup.html` without ERR_FILE_NOT_FOUND.

- [ ] **Step 6: Commit**

```bash
git add ChromeExtension/icons/icon16.png ChromeExtension/icons/icon32.png ChromeExtension/icons/icon48.png ChromeExtension/icons/icon128.png ChromeExtension/manifest.json ChromeExtension/tests/background.manifest.test.js
git commit -m "feat(chrome): add BrandKey toolbar icons and manifest wiring"
```

---

### Task 2: Popup Retry / Open MyPass fallback UI

**Files:**
- Modify: `ChromeExtension/popup.html`
- Modify: `ChromeExtension/popup.js`
- Create: `ChromeExtension/tests/popup-fallback.test.js`

**Interfaces:**
- Consumes: `classifyGetCredentialsResponse` (existing), `queryCredentials(url)` (existing popup closure).
- Produces (exported from `popup.js` for tests):
  - `APP_UNAVAILABLE_STATUS_TEXT` — `string`
  - `APP_UNAVAILABLE_OPEN_HELPER_TEXT` — `string`
  - `shouldShowAppUnavailableActions(kind)` — `(string) => boolean`, true only when `kind === 'error'`

DOM-only (not exported): `showAppUnavailableActions(url | null)`, `hideAppUnavailableActions()`.

**Note:** Show/hide helpers depend on `document` and `chrome.tabs`; they stay inside the `if (typeof document !== 'undefined')` block. Tests cover the pure copy/gating exports only — manual steps below verify Retry / Open MyPass behavior per spec.

- [ ] **Step 1: Write the failing test**

Create `ChromeExtension/tests/popup-fallback.test.js`:

```javascript
const assert = require('node:assert');
const {
  APP_UNAVAILABLE_STATUS_TEXT,
  APP_UNAVAILABLE_OPEN_HELPER_TEXT,
  shouldShowAppUnavailableActions
} = require('../popup.js');

assert.strictEqual(
  APP_UNAVAILABLE_STATUS_TEXT,
  'MyPass not found. Make sure the app is installed and has been launched at least once (to register the native messaging host).'
);
assert.strictEqual(
  APP_UNAVAILABLE_OPEN_HELPER_TEXT,
  'Open MyPass from Applications or the Dock. Unlock your vault if needed, then tap Retry.'
);

assert.strictEqual(shouldShowAppUnavailableActions('error'), true);
assert.strictEqual(shouldShowAppUnavailableActions('locked'), false);
assert.strictEqual(shouldShowAppUnavailableActions('pairingRequired'), false);
assert.strictEqual(shouldShowAppUnavailableActions('credentialList'), false);
assert.strictEqual(shouldShowAppUnavailableActions('unknown'), false);

console.log('popup-fallback.test.js OK');
```

- [ ] **Step 2: Run test to verify it fails**

Run: `node ChromeExtension/tests/popup-fallback.test.js`

Expected: FAIL — `Cannot read properties of undefined` or export missing (`APP_UNAVAILABLE_STATUS_TEXT is not exported`).

- [ ] **Step 3: Add popup.html action row**

Insert CSS in `ChromeExtension/popup.html` `<style>` after the `#pairing-error` rule:

```css
    #app-unavailable-actions { margin-top: 8px; }
    #app-unavailable-actions button { margin-right: 8px; margin-top: 4px; cursor: pointer; }
    #open-mypass-helper { margin: 8px 0 0; font-size: 12px; color: #666; }
```

Insert HTML after `<div id="status"></div>` and before `<ul id="list"></ul>`:

```html
  <div id="app-unavailable-actions" hidden>
    <button id="retry-btn" type="button">Retry</button>
    <button id="open-mypass-btn" type="button">Open MyPass</button>
    <p id="open-mypass-helper" hidden></p>
  </div>
```

- [ ] **Step 4: Add pure exports and DOM wiring in popup.js**

Add near the top of `ChromeExtension/popup.js` (after `PAIRING_CHALLENGE_TTL_MS`, before `classifyGetCredentialsResponse`):

```javascript
const APP_UNAVAILABLE_STATUS_TEXT =
  'MyPass not found. Make sure the app is installed and has been launched at least once (to register the native messaging host).';
const APP_UNAVAILABLE_OPEN_HELPER_TEXT =
  'Open MyPass from Applications or the Dock. Unlock your vault if needed, then tap Retry.';

function shouldShowAppUnavailableActions(kind) {
  return kind === 'error';
}
```

Inside the `if (typeof document !== 'undefined')` block, after existing element lookups (line ~50), add:

```javascript
  const appUnavailableActions = document.getElementById('app-unavailable-actions');
  const retryBtn = document.getElementById('retry-btn');
  const openMypassBtn = document.getElementById('open-mypass-btn');
  const openMypassHelper = document.getElementById('open-mypass-helper');
  openMypassHelper.textContent = APP_UNAVAILABLE_OPEN_HELPER_TEXT;
```

Add helpers before `handleCredentialsResponse`:

```javascript
  function hideAppUnavailableActions() {
    appUnavailableActions.hidden = true;
    openMypassHelper.hidden = true;
  }

  function retryCredentialsForActiveTab() {
    hideAppUnavailableActions();
    listEl.innerHTML = '';
    chrome.tabs.query({ active: true, currentWindow: true }, (tabs) => {
      const activeTab = tabs[0];
      if (!activeTab || !activeTab.url) {
        setStatus(APP_UNAVAILABLE_STATUS_TEXT);
        showAppUnavailableActions(null);
        return;
      }
      queryCredentials(activeTab.url);
    });
  }

  function showAppUnavailableActions(url) {
    hidePairingPanel();
    listEl.innerHTML = '';
    listEl.hidden = true;
    statusEl.hidden = false;
    appUnavailableActions.hidden = false;
    openMypassHelper.hidden = true;
    retryBtn.onclick = () => {
      if (url) {
        hideAppUnavailableActions();
        listEl.innerHTML = '';
        queryCredentials(url);
      } else {
        retryCredentialsForActiveTab();
      }
    };
    openMypassBtn.onclick = () => {
      openMypassHelper.hidden = false;
    };
  }
```

Update `handleCredentialsResponse` — call `hideAppUnavailableActions()` at the start of every non-error branch, and replace the `'error'` branch:

```javascript
  function handleCredentialsResponse(response, url) {
    const kind = classifyGetCredentialsResponse(response);
    if (kind === 'error') {
      setStatus(APP_UNAVAILABLE_STATUS_TEXT);
      showAppUnavailableActions(url);
      return;
    }
    hideAppUnavailableActions();
    if (kind === 'locked') {
      setStatus('Open MyPass and unlock the vault');
      return;
    }
    if (kind === 'pairingRequired') {
      showPairingPanel();
      connectBtn.onclick = startPairingFlow;
      submitCodeBtn.onclick = () => submitPairingCode(url);
      readPairingStartedAt((startedAt) => {
        if (isPairingChallengeFresh(startedAt, Date.now())) {
          revealCodeEntry();
        }
      });
      return;
    }
    if (kind === 'credentialList') {
      if (response.credentials.length === 0) {
        setStatus('No saved logins for this site');
        return;
      }
      setStatus('Select an entry to autofill:');
      renderCredentials(response.credentials, url);
    }
  }
```

Update the bottom `chrome.tabs.query` early exit (lines ~190–196):

```javascript
  chrome.tabs.query({ active: true, currentWindow: true }, (tabs) => {
    const activeTab = tabs[0];
    if (!activeTab || !activeTab.url) {
      setStatus(APP_UNAVAILABLE_STATUS_TEXT);
      showAppUnavailableActions(null);
      return;
    }
    queryCredentials(activeTab.url);
  });
```

Extend `module.exports` at the bottom:

```javascript
if (typeof module !== 'undefined') {
  module.exports = {
    classifyGetCredentialsResponse,
    isPairingChallengeFresh,
    normalizePairingCode,
    PAIRING_CHALLENGE_TTL_MS,
    APP_UNAVAILABLE_STATUS_TEXT,
    APP_UNAVAILABLE_OPEN_HELPER_TEXT,
    shouldShowAppUnavailableActions
  };
}
```

- [ ] **Step 5: Run test to verify it passes**

Run:

```bash
node ChromeExtension/tests/popup-fallback.test.js
node ChromeExtension/tests/pairing.test.js
node ChromeExtension/tests/background.manifest.test.js
node ChromeExtension/tests/formDetection.test.js
```

Expected: all pass; `popup-fallback.test.js OK` printed.

- [ ] **Step 6: Manual app-not-running verification**

Prerequisites: extension loaded unpacked from `ChromeExtension/`; MyPass **quit** (or native host unavailable).

1. Open any normal https page, click the MyPass toolbar icon.
2. Confirm status text matches `APP_UNAVAILABLE_STATUS_TEXT` and **Retry** + **Open MyPass** buttons appear below it.
3. Click **Open MyPass** — helper copy appears; MyPass does **not** launch.
4. Launch MyPass, unlock vault, click **Retry** — popup transitions to credential list, pairing panel, locked message, or empty list (no stuck action row).
5. With MyPass running and paired: popup shows list/pairing/locked as before — **no** Retry/Open MyPass buttons on those states.

- [ ] **Step 7: Commit**

```bash
git add ChromeExtension/popup.html ChromeExtension/popup.js ChromeExtension/tests/popup-fallback.test.js
git commit -m "feat(chrome): add Retry and Open MyPass on app-unavailable popup"
```

---

### Task 3: RUN.md Ukrainian troubleshooting note

**Files:**
- Modify: `RUN.md` (insert after line 79, before `### Chrome e2e (ручна перевірка)`)

**Interfaces:**
- Consumes: Task 1 toolbar icon behavior (BrandKey mention).
- Produces: standalone Ukrainian subsection documenting ERR_FILE_NOT_FOUND recovery.

- [ ] **Step 1: Insert troubleshooting subsection**

In `RUN.md`, after step 7 (“Після змін у JS-файлах: … reload …”) and **before** `### Chrome e2e (ручна перевірка)`, insert:

```markdown
### Якщо popup не відкривається (ERR_FILE_NOT_FOUND)

Якщо при кліку на іконку розширення Chrome показує **ERR_FILE_NOT_FOUND** або повідомлення про відсутній файл, шлях до розпакованого розширення був переміщений або видалений. Відкрийте `chrome://extensions`, знову натисніть **Завантажити розпаковане розширення** і оберіть актуальну теку [`ChromeExtension/`](ChromeExtension/) у репозиторії, потім натисніть **Оновити** (reload) на картці MyPass.

Після коректного завантаження на панелі інструментів відображається іконка ключа MyPass (BrandKey), а не сіра літера «M».
```

Do not add an English duplicate elsewhere in the file.

- [ ] **Step 2: Verify insertion point**

Run: `rg -n "ERR_FILE_NOT_FOUND|BrandKey" RUN.md`

Expected: two matching lines inside the new subsection only.

- [ ] **Step 3: Run JS tests (sanity — no RUN.md test exists)**

Run:

```bash
node ChromeExtension/tests/background.manifest.test.js
node ChromeExtension/tests/formDetection.test.js
node ChromeExtension/tests/pairing.test.js
node ChromeExtension/tests/popup-fallback.test.js
```

Expected: all pass.

- [ ] **Step 4: Commit**

```bash
git add RUN.md
git commit -m "docs: add Ukrainian Chrome extension reload troubleshooting"
```

---

## Self-review (spec coverage)

| Spec requirement | Task |
|------------------|------|
| BrandKey icons 16/32/48/128 under `ChromeExtension/icons/` | Task 1 |
| `manifest.json` `icons` + `action.default_icon` | Task 1 |
| Manifest paths exist on disk | Task 1 (test + sips output) |
| Popup co-located; relative paths | Task 1 (no popup path changes) |
| Retry + Open MyPass on `'error'` path only | Task 2 |
| Open MyPass instructional copy only (no launch) | Task 2 |
| Hide actions on locked / pairing / list / empty | Task 2 (`hideAppUnavailableActions` on non-error branches) |
| English UI strings | Task 2 |
| RUN.md Ukrainian ERR_FILE_NOT_FOUND + BrandKey note | Task 3 |
| Existing tests pass; small pure-JS test if clean hook | Task 2 (`popup-fallback.test.js`) |
| Out of scope: app, ChromeHost, background taxonomy, URL scheme | Global Constraints |

**Optional follow-up (out of scope):** add `node ChromeExtension/tests/popup-fallback.test.js` to `scripts/test.sh` — not required by spec; existing `./scripts/test.sh` still passes without it.
