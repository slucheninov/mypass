# Chrome Extension Popup List Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Redesign the Chrome extension popup to match macOS credential rows (LetterAvatar, ~280 px panel shell, structured states) and stop MyPass from stealing focus when a pairing code is generated so the popup stays open.

**Architecture:** Port `LetterAvatar` letter/hash/palette logic from Swift into pure JS exports in `popup.js`, covered by Node unit tests with the same title vectors as `LetterAvatarTests`. Replace `popup.html` with a single panel shell and a `showPanel()` helper that toggles locked / pairing / app-unavailable / empty / credential-list regions without overlap. Credential rows are built in `renderCredentials()` with 36×36 avatars and existing `fillCredential` IPC. One app-side change removes `MainWindowActivator.request()` from `pairingManager.onCodeGenerated` only.

**Tech Stack:** MV3 Chrome extension (HTML/CSS/vanilla JS), `node:assert` tests (`node ChromeExtension/tests/<file>.js`), SwiftUI macOS app (`MyPass/MyPassApp.swift`), `xcodebuild test` for app regression.

## Global Constraints

- English UI strings in source (Phase 7 localization later).
- No unlock-from-extension, password field, or unlock IPC in the popup.
- No `entryType` card/notes icons in the popup (login letter avatars only; payload stays `id` / `title` / `username`).
- Light theme only (no dark mode).
- No credential payload or host message shape changes.
- No changes to `ChromeHost/`, `background.js` error taxonomy, or `content.js`.
- No native messaging or ChromeHost changes for icons; reuse `ChromeExtension/icons/icon32.png` (or `icon48.png`) for BrandKey in panel headers.
- Touch only `ChromeExtension/popup.html`, `ChromeExtension/popup.js`, `ChromeExtension/tests/*.test.js`, and `MyPass/MyPassApp.swift`.
- Existing `ChromeExtension/tests` must pass (`node ChromeExtension/tests/<file>.js`; also covered by `./scripts/test.sh` when Node is installed).
- Row click must keep sending `chrome.runtime.sendMessage({ type: 'fillCredential', id, url })` then `window.close()`.
- Keep `MainWindowActivator.request()` on `extensionBridgeService.onSaveProposal` and menu-bar / shortcut `showHandler` paths.

---

## File Structure

| Path | Responsibility |
|------|----------------|
| `ChromeExtension/popup.js` | Pure `letterFromTitle` / `colorForTitle` / palette constant; `buildLetterAvatarElement`; `showPanel` state helper; redesigned `renderCredentials`; state copy constants; existing pairing / fallback logic rewired to new DOM |
| `ChromeExtension/popup.html` | ~280 px panel shell CSS, BrandKey header, sections for locked / pairing / app-unavailable / empty / credential list |
| `ChromeExtension/tests/letter-avatar.test.js` | Unit tests for letter, color hash parity vs Swift titles, palette order |
| `ChromeExtension/tests/popup-fallback.test.js` | Update DOM mocks for new element IDs; keep Retry / Open MyPass gating and retry-flow assertions |
| `MyPass/MyPassApp.swift` | Remove `MainWindowActivator.request()` from `onCodeGenerated` only |

**Out of touch:** `ChromeHost/`, `background.js`, `content.js`, `manifest.json`, `RUN.md`, macOS assets beyond `MyPassApp.swift`.

---

### Task 1: LetterAvatar JS helpers (TDD)

**Files:**
- Create: `ChromeExtension/tests/letter-avatar.test.js`
- Modify: `ChromeExtension/popup.js` (add pure helpers before `getPairingStorageArea`, extend `module.exports`)

**Interfaces:**
- Consumes: nothing (pure functions).
- Produces:
  - `LETTER_AVATAR_PALETTE` — `string[]` (10 hex colors, Swift palette order)
  - `letterFromTitle(title)` — `(string) => string`
  - `colorForTitle(title)` — `(string) => string` (hex from palette)

Known Swift-aligned test vectors (computed with Swift `LetterAvatar.color(for:)` algorithm — `title.utf8.reduce(0) { ($0 &+ Int($1)) &* 31 }`):

| Title | Letter | Color hex | Palette index |
|-------|--------|-----------|---------------|
| `GitHub` | `G` | `#A2845E` | 9 (brown) |
| `amazon` | `A` | `#5856D6` | 6 (indigo) |
| `Example Service` | `E` | `#00C7BE` | 7 (mint) |
| `Alpha` | `A` | `#5856D6` | 6 |
| `Beta` | `B` | `#007AFF` | 0 (blue) |

- [ ] **Step 1: Write the failing test**

Create `ChromeExtension/tests/letter-avatar.test.js`:

```javascript
const assert = require('node:assert');

const {
  letterFromTitle,
  colorForTitle,
  LETTER_AVATAR_PALETTE
} = require('../popup.js');

assert.strictEqual(letterFromTitle('GitHub'), 'G');
assert.strictEqual(letterFromTitle('amazon'), 'A');
assert.strictEqual(letterFromTitle(''), '?');
assert.strictEqual(letterFromTitle('   '), '?');

assert.strictEqual(colorForTitle('GitHub'), '#A2845E');
assert.strictEqual(colorForTitle('amazon'), '#5856D6');
assert.strictEqual(colorForTitle('Example Service'), '#00C7BE');
assert.strictEqual(colorForTitle('Alpha'), '#5856D6');
assert.strictEqual(colorForTitle('Beta'), '#007AFF');
assert.notStrictEqual(colorForTitle('Alpha'), colorForTitle('Beta'));

assert.strictEqual(LETTER_AVATAR_PALETTE.length, 10);
assert.deepStrictEqual(LETTER_AVATAR_PALETTE, [
  '#007AFF',
  '#34C759',
  '#FF9500',
  '#AF52DE',
  '#FF2D55',
  '#30B0C7',
  '#5856D6',
  '#00C7BE',
  '#32ADE6',
  '#A2845E'
]);

console.log('letter-avatar.test.js OK');
```

- [ ] **Step 2: Run test to verify it fails**

Run: `node ChromeExtension/tests/letter-avatar.test.js`

Expected: FAIL — `letterFromTitle is not a function` or export missing.

- [ ] **Step 3: Write minimal implementation**

Insert in `ChromeExtension/popup.js` after `normalizePairingCode` (line 28) and before `getPairingStorageArea`:

```javascript
const LETTER_AVATAR_PALETTE = [
  '#007AFF',
  '#34C759',
  '#FF9500',
  '#AF52DE',
  '#FF2D55',
  '#30B0C7',
  '#5856D6',
  '#00C7BE',
  '#32ADE6',
  '#A2845E'
];

function letterFromTitle(title) {
  const trimmed = title.trim();
  if (!trimmed) return '?';
  return trimmed[0].toUpperCase();
}

function colorForTitle(title) {
  let hash = 0;
  for (const byte of new TextEncoder().encode(title)) {
    hash = ((hash + byte) * 31) >>> 0;
  }
  const index =
    ((hash % LETTER_AVATAR_PALETTE.length) + LETTER_AVATAR_PALETTE.length) %
    LETTER_AVATAR_PALETTE.length;
  return LETTER_AVATAR_PALETTE[index];
}
```

Extend `module.exports` at the bottom of `popup.js`:

```javascript
if (typeof module !== 'undefined') {
  module.exports = {
    classifyGetCredentialsResponse,
    isPairingChallengeFresh,
    normalizePairingCode,
    PAIRING_CHALLENGE_TTL_MS,
    APP_UNAVAILABLE_STATUS_TEXT,
    APP_UNAVAILABLE_OPEN_HELPER_TEXT,
    shouldShowAppUnavailableActions,
    LETTER_AVATAR_PALETTE,
    letterFromTitle,
    colorForTitle
  };
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run:

```bash
node ChromeExtension/tests/letter-avatar.test.js
node ChromeExtension/tests/popup-fallback.test.js
node ChromeExtension/tests/pairing.test.js
node ChromeExtension/tests/background.manifest.test.js
node ChromeExtension/tests/formDetection.test.js
```

Expected: all print `OK` / `manifest.json OK` with exit code 0.

- [ ] **Step 5: Commit**

```bash
git add ChromeExtension/popup.js ChromeExtension/tests/letter-avatar.test.js
git commit -m "feat(chrome): port LetterAvatar helpers with unit tests"
```

---

### Task 2: Popup shell, credential rows, and state wiring

**Files:**
- Modify: `ChromeExtension/popup.html` (full shell + CSS replacement)
- Modify: `ChromeExtension/popup.js` (panel helpers, `buildLetterAvatarElement`, `renderCredentials`, state handlers)
- Modify: `ChromeExtension/tests/popup-fallback.test.js` (DOM mocks for new element IDs)

**Interfaces:**
- Consumes from Task 1: `letterFromTitle`, `colorForTitle`, `LETTER_AVATAR_PALETTE`.
- Produces (DOM-only, not exported):
  - `showPanel(panelName)` — `'locked' | 'pairing' | 'app-unavailable' | 'empty' | 'credential-list'`
  - `buildLetterAvatarElement(title)` — returns `HTMLElement` (36×36 avatar)
  - `renderCredentials(credentials, url)` — list rows with avatars; click → `fillCredential`
- Produces (exported copy constants for tests, add to `module.exports`):
  - `LOCKED_TITLE_TEXT` — `'MyPass is locked'`
  - `LOCKED_HELPER_TEXT` — `'Open MyPass and unlock the vault'`
  - `EMPTY_LIST_TITLE_TEXT` — `'No saved logins for this site'`
  - `LIST_HEADER_TEXT` — `'Select an entry to autofill:'`
  - `PAIRING_PANEL_TITLE_TEXT` — `'Connect browser extension'`

- [ ] **Step 1: Replace popup.html with panel shell**

Replace the entire contents of `ChromeExtension/popup.html`:

```html
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <title>MyPass</title>
  <style>
    body {
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
      width: 280px;
      margin: 0;
      padding: 18px 16px;
      box-sizing: border-box;
      color: #1d1d1f;
      background: #fff;
    }
    .brand-key {
      display: block;
      width: 32px;
      height: 32px;
      margin: 0 auto 12px;
    }
    .brand-key--leading {
      margin: 0 0 12px;
    }
    h1.panel-title {
      font-size: 15px;
      font-weight: 600;
      margin: 0 0 6px;
      line-height: 1.3;
    }
    p.panel-helper {
      font-size: 13px;
      color: #6e6e73;
      margin: 0 0 12px;
      line-height: 1.35;
    }
    p.list-header {
      font-size: 13px;
      font-weight: 600;
      color: #1d1d1f;
      margin: 0 0 8px;
    }
    .btn-primary,
    .btn-secondary {
      font-size: 13px;
      line-height: 1.2;
      padding: 7px 12px;
      border-radius: 6px;
      cursor: pointer;
      border: 1px solid transparent;
    }
    .btn-primary {
      background: #007aff;
      color: #fff;
      border-color: #007aff;
    }
    .btn-secondary {
      background: #f5f5f7;
      color: #1d1d1f;
      border-color: #d2d2d7;
      margin-left: 8px;
    }
    .btn-row {
      margin-top: 4px;
    }
    ul {
      list-style: none;
      margin: 0;
      padding: 0;
    }
    li.credential-row {
      display: flex;
      align-items: center;
      gap: 12px;
      padding: 4px 6px;
      border-radius: 8px;
      cursor: pointer;
    }
    li.credential-row:hover {
      background: #f5f5f7;
    }
    .letter-avatar {
      width: 36px;
      height: 36px;
      border-radius: 8px;
      display: flex;
      align-items: center;
      justify-content: center;
      flex-shrink: 0;
    }
    .letter-avatar-letter {
      color: #ffffff;
      font-size: 15px;
      font-weight: 600;
      line-height: 1;
    }
    .credential-text {
      min-width: 0;
      flex: 1;
    }
    .credential-title {
      font-size: 14px;
      font-weight: 600;
      line-height: 1.25;
    }
    .credential-username {
      font-size: 12px;
      color: #6e6e73;
      line-height: 1.25;
      margin-top: 2px;
      overflow: hidden;
      text-overflow: ellipsis;
      white-space: nowrap;
    }
    #pairing-panel .panel-title {
      margin-bottom: 12px;
    }
    #code-entry {
      margin-top: 12px;
    }
    #code-hint {
      margin: 0 0 6px;
      font-size: 12px;
      color: #6e6e73;
    }
    #code-input {
      width: 100%;
      box-sizing: border-box;
      font-size: 16px;
      letter-spacing: 2px;
      margin-bottom: 8px;
    }
    #pairing-error {
      color: #c00;
      font-size: 12px;
      margin: 8px 0 0;
    }
    #open-mypass-helper {
      margin: 8px 0 0;
      font-size: 12px;
      color: #6e6e73;
    }
    [hidden] {
      display: none !important;
    }
  </style>
</head>
<body>
  <div id="panel-shell">
    <section id="locked-panel" hidden>
      <img class="brand-key" src="icons/icon32.png" width="32" height="32" alt="">
      <h1 class="panel-title" id="locked-title"></h1>
      <p class="panel-helper" id="locked-helper"></p>
      <button id="locked-retry-btn" type="button" class="btn-primary">Retry</button>
    </section>

    <section id="app-unavailable-panel" hidden>
      <img class="brand-key" src="icons/icon32.png" width="32" height="32" alt="">
      <p class="panel-helper" id="app-unavailable-status"></p>
      <div id="app-unavailable-actions">
        <button id="retry-btn" type="button" class="btn-primary">Retry</button>
        <button id="open-mypass-btn" type="button" class="btn-secondary">Open MyPass</button>
        <p id="open-mypass-helper" hidden></p>
      </div>
    </section>

    <section id="empty-panel" hidden>
      <h1 class="panel-title" id="empty-title"></h1>
    </section>

    <section id="list-panel" hidden>
      <p class="list-header" id="list-header"></p>
      <ul id="list"></ul>
    </section>

    <section id="pairing-panel" hidden>
      <h1 class="panel-title" id="pairing-title"></h1>
      <button id="connect-btn" type="button" class="btn-primary">Connect</button>
      <div id="code-entry" hidden>
        <p id="code-hint">Enter the code shown in MyPass</p>
        <input id="code-input" type="text" inputmode="numeric" maxlength="7" pattern="[0-9]{6}" />
        <button id="submit-code-btn" type="button" class="btn-primary">Submit</button>
      </div>
      <p id="pairing-error" hidden></p>
    </section>
  </div>
  <script src="popup.js"></script>
</body>
</html>
```

- [ ] **Step 2: Add copy constants and panel helper exports**

Add after `shouldShowAppUnavailableActions` in `ChromeExtension/popup.js`:

```javascript
const LOCKED_TITLE_TEXT = 'MyPass is locked';
const LOCKED_HELPER_TEXT = 'Open MyPass and unlock the vault';
const EMPTY_LIST_TITLE_TEXT = 'No saved logins for this site';
const LIST_HEADER_TEXT = 'Select an entry to autofill:';
const PAIRING_PANEL_TITLE_TEXT = 'Connect browser extension';
```

Add to `module.exports`:

```javascript
    LOCKED_TITLE_TEXT,
    LOCKED_HELPER_TEXT,
    EMPTY_LIST_TITLE_TEXT,
    LIST_HEADER_TEXT,
    PAIRING_PANEL_TITLE_TEXT,
```

- [ ] **Step 3: Rewrite DOM block element lookups and panel helpers**

Replace the `if (typeof document !== 'undefined') {` block's element lookups and status/panel helpers. Keep storage/pairing pure functions above unchanged.

New lookups at the start of the DOM block:

```javascript
if (typeof document !== 'undefined') {
  const lockedPanel = document.getElementById('locked-panel');
  const lockedTitleEl = document.getElementById('locked-title');
  const lockedHelperEl = document.getElementById('locked-helper');
  const lockedRetryBtn = document.getElementById('locked-retry-btn');

  const appUnavailablePanel = document.getElementById('app-unavailable-panel');
  const appUnavailableStatusEl = document.getElementById('app-unavailable-status');
  const appUnavailableActions = document.getElementById('app-unavailable-actions');
  const retryBtn = document.getElementById('retry-btn');
  const openMypassBtn = document.getElementById('open-mypass-btn');
  const openMypassHelper = document.getElementById('open-mypass-helper');
  openMypassHelper.textContent = APP_UNAVAILABLE_OPEN_HELPER_TEXT;

  const emptyPanel = document.getElementById('empty-panel');
  const emptyTitleEl = document.getElementById('empty-title');
  emptyTitleEl.textContent = EMPTY_LIST_TITLE_TEXT;

  const listPanel = document.getElementById('list-panel');
  const listHeaderEl = document.getElementById('list-header');
  listHeaderEl.textContent = LIST_HEADER_TEXT;
  const listEl = document.getElementById('list');

  const pairingPanel = document.getElementById('pairing-panel');
  const pairingTitleEl = document.getElementById('pairing-title');
  pairingTitleEl.textContent = PAIRING_PANEL_TITLE_TEXT;
  const connectBtn = document.getElementById('connect-btn');
  const codeEntry = document.getElementById('code-entry');
  const codeInput = document.getElementById('code-input');
  const submitCodeBtn = document.getElementById('submit-code-btn');
  const pairingErrorEl = document.getElementById('pairing-error');

  lockedTitleEl.textContent = LOCKED_TITLE_TEXT;
  lockedHelperEl.textContent = LOCKED_HELPER_TEXT;

  const PANEL_SECTIONS = [
    lockedPanel,
    appUnavailablePanel,
    emptyPanel,
    listPanel,
    pairingPanel
  ];

  function showPanel(name) {
    for (const section of PANEL_SECTIONS) {
      section.hidden = true;
    }
    openMypassHelper.hidden = true;
    switch (name) {
      case 'locked':
        lockedPanel.hidden = false;
        break;
      case 'app-unavailable':
        appUnavailablePanel.hidden = false;
        break;
      case 'empty':
        emptyPanel.hidden = false;
        break;
      case 'credential-list':
        listPanel.hidden = false;
        break;
      case 'pairing':
        pairingPanel.hidden = false;
        break;
      default:
        break;
    }
  }
```

Remove the old `statusEl`, `setStatus`, and `hidePairingPanel`/`showPairingPanel` patterns that toggled `#status` visibility. Replace `showPairingPanel` / `hidePairingPanel` with:

```javascript
  function showPairingPanel() {
    showPanel('pairing');
  }

  function hidePairingPanel() {
    codeEntry.hidden = true;
    codeInput.value = '';
    setPairingError('');
  }
```

Keep `setPairingError` unchanged.

- [ ] **Step 4: Add buildLetterAvatarElement and renderCredentials**

Insert before `startPairingFlow`:

```javascript
  function buildLetterAvatarElement(title) {
    const avatar = document.createElement('div');
    avatar.className = 'letter-avatar';
    avatar.style.backgroundColor = colorForTitle(title);
    avatar.setAttribute('role', 'img');
    avatar.setAttribute(
      'aria-label',
      title.trim() ? `Icon for ${title}` : 'Icon for untitled entry'
    );
    const letter = document.createElement('span');
    letter.className = 'letter-avatar-letter';
    letter.textContent = letterFromTitle(title);
    avatar.appendChild(letter);
    return avatar;
  }

  function renderCredentials(credentials, url) {
    listEl.innerHTML = '';
    credentials.forEach((credential) => {
      const item = document.createElement('li');
      item.className = 'credential-row';

      item.appendChild(buildLetterAvatarElement(credential.title));

      const textCol = document.createElement('div');
      textCol.className = 'credential-text';

      const title = document.createElement('div');
      title.className = 'credential-title';
      title.textContent = credential.title;
      textCol.appendChild(title);

      if (credential.username) {
        const username = document.createElement('div');
        username.className = 'credential-username';
        username.textContent = credential.username;
        textCol.appendChild(username);
      }

      item.appendChild(textCol);
      item.addEventListener('click', () => {
        chrome.runtime.sendMessage(
          { type: 'fillCredential', id: credential.id, url },
          () => {
            window.close();
          }
        );
      });
      listEl.appendChild(item);
    });
  }
```

- [ ] **Step 5: Rewire app-unavailable, locked, empty, list, and pairing handlers**

Replace `hideAppUnavailableActions`, `showAppUnavailableActions`, and `handleCredentialsResponse` with:

```javascript
  function hideAppUnavailableActions() {
    openMypassHelper.hidden = true;
  }

  function retryCredentialsForActiveTab() {
    listEl.innerHTML = '';
    chrome.tabs.query({ active: true, currentWindow: true }, (tabs) => {
      const activeTab = tabs[0];
      if (!activeTab || !activeTab.url) {
        appUnavailableStatusEl.textContent = APP_UNAVAILABLE_STATUS_TEXT;
        showAppUnavailableActions(null);
        return;
      }
      queryCredentials(activeTab.url);
    });
  }

  function showAppUnavailableActions(url) {
    hidePairingPanel();
    listEl.innerHTML = '';
    appUnavailableStatusEl.textContent = APP_UNAVAILABLE_STATUS_TEXT;
    showPanel('app-unavailable');
    openMypassHelper.hidden = true;
    retryBtn.onclick = () => {
      if (url) {
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

  function handleCredentialsResponse(response, url) {
    const kind = classifyGetCredentialsResponse(response);
    if (kind === 'error') {
      if (shouldShowAppUnavailableActions(kind)) {
        showAppUnavailableActions(url);
      }
      return;
    }
    hideAppUnavailableActions();
    if (kind === 'locked') {
      showPanel('locked');
      lockedRetryBtn.onclick = () => queryCredentials(url);
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
        showPanel('empty');
        return;
      }
      showPanel('credential-list');
      renderCredentials(response.credentials, url);
    }
  }
```

Update `submitPairingCode` success path — after `hidePairingPanel()`, the next `queryCredentials` call will `showPanel` appropriately; no extra status calls needed.

Update bottom `chrome.tabs.query` early exit:

```javascript
  chrome.tabs.query({ active: true, currentWindow: true }, (tabs) => {
    const activeTab = tabs[0];
    if (!activeTab || !activeTab.url) {
      appUnavailableStatusEl.textContent = APP_UNAVAILABLE_STATUS_TEXT;
      showAppUnavailableActions(null);
      return;
    }
    queryCredentials(activeTab.url);
  });
```

- [ ] **Step 6: Update popup-fallback.test.js DOM mocks**

Replace the element ID list in `ChromeExtension/tests/popup-fallback.test.js` (lines 23–36) with:

```javascript
[
  'locked-panel',
  'locked-title',
  'locked-helper',
  'locked-retry-btn',
  'app-unavailable-panel',
  'app-unavailable-status',
  'app-unavailable-actions',
  'retry-btn',
  'open-mypass-btn',
  'open-mypass-helper',
  'empty-panel',
  'empty-title',
  'list-panel',
  'list-header',
  'list',
  'pairing-panel',
  'pairing-title',
  'connect-btn',
  'code-entry',
  'code-input',
  'submit-code-btn',
  'pairing-error'
].forEach((id) => makeEl(id));
```

Replace assertions at lines 101–109 with:

```javascript
assert.strictEqual(sendMessageCall, 1, 'initial load should query credentials once');
assert.strictEqual(elements['app-unavailable-panel'].hidden, false, 'app-unavailable panel visible on error');
assert.strictEqual(elements['list-panel'].hidden, true, 'list panel hidden on error');

retryBtn.onclick();
assert.strictEqual(sendMessageCall, 2, 'retry should re-query credentials');
assert.strictEqual(elements['list-panel'].hidden, false, 'list panel visible after credentialList');
assert.strictEqual(elements['app-unavailable-panel'].hidden, true, 'app-unavailable panel hidden after success');
assert.strictEqual(listEl.children.length, 1, 'credential rendered in list');
```

Add copy constant assertions after existing `shouldShowAppUnavailableActions` checks:

```javascript
const {
  APP_UNAVAILABLE_STATUS_TEXT,
  APP_UNAVAILABLE_OPEN_HELPER_TEXT,
  shouldShowAppUnavailableActions,
  LOCKED_TITLE_TEXT,
  LOCKED_HELPER_TEXT,
  EMPTY_LIST_TITLE_TEXT,
  LIST_HEADER_TEXT,
  PAIRING_PANEL_TITLE_TEXT
} = require('../popup.js');

assert.strictEqual(LOCKED_TITLE_TEXT, 'MyPass is locked');
assert.strictEqual(LOCKED_HELPER_TEXT, 'Open MyPass and unlock the vault');
assert.strictEqual(EMPTY_LIST_TITLE_TEXT, 'No saved logins for this site');
assert.strictEqual(LIST_HEADER_TEXT, 'Select an entry to autofill:');
assert.strictEqual(PAIRING_PANEL_TITLE_TEXT, 'Connect browser extension');
```

(Merge the destructuring into the existing `require` block — do not duplicate `require('../popup.js')`.)

- [ ] **Step 7: Run all ChromeExtension tests**

Run:

```bash
node ChromeExtension/tests/letter-avatar.test.js
node ChromeExtension/tests/popup-fallback.test.js
node ChromeExtension/tests/pairing.test.js
node ChromeExtension/tests/background.manifest.test.js
node ChromeExtension/tests/formDetection.test.js
```

Expected: all pass with exit code 0.

- [ ] **Step 8: Manual popup verification**

Prerequisites: load unpacked extension from `ChromeExtension/`; MyPass running and paired unless testing a specific state.

1. **Credential list** — open popup on a site with saved logins: 280 px panel, list header “Select an entry to autofill:”, rows show 36×36 colored letter avatars, semibold title, 12 px username; row click autofills and closes popup.
2. **Empty list** — site with no logins: “No saved logins for this site”; no Retry button.
3. **Locked** — lock vault, open popup: BrandKey, “MyPass is locked”, helper copy, **Retry** re-queries (does not show app-unavailable actions).
4. **Pairing** — unpair extension: “Connect browser extension”, **Connect** → code entry, styled errors on failure; successful pair returns to list or empty state.
5. **App not running** — quit MyPass: BrandKey, status text, **Retry** / **Open MyPass** with helper; Open MyPass does not launch the app.

- [ ] **Step 9: Commit**

```bash
git add ChromeExtension/popup.html ChromeExtension/popup.js ChromeExtension/tests/popup-fallback.test.js
git commit -m "feat(chrome): redesign popup shell and credential rows"
```

---

### Task 3: Pairing focus fix (macOS app)

**Files:**
- Modify: `MyPass/MyPassApp.swift:185-189`

**Interfaces:**
- Consumes: existing `pairingManager.onCodeGenerated` closure.
- Produces: same `pendingPairingCode` assignment without `MainWindowActivator.request()` on code generation. Save-proposal and menu-bar activation unchanged.

- [ ] **Step 1: Remove main-window activation from onCodeGenerated**

In `MyPass/MyPassApp.swift`, replace:

```swift
        pairingManager.onCodeGenerated = { [weak navigationState] code in
            DispatchQueue.main.async {
                navigationState?.pendingPairingCode = code
                MainWindowActivator.request()
            }
        }
```

with:

```swift
        pairingManager.onCodeGenerated = { [weak navigationState] code in
            DispatchQueue.main.async {
                navigationState?.pendingPairingCode = code
            }
        }
```

Do **not** remove `MainWindowActivator.request()` from `extensionBridgeService.onSaveProposal` (line ~208) or `showHandler` (line ~316).

- [ ] **Step 2: Run app unit tests (regression)**

Run:

```bash
xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/LetterAvatarTests
```

Expected: `LetterAvatarTests` passes (sanity check on related avatar logic; no automated test covers window activation).

Full suite (optional, slower):

```bash
./scripts/test.sh
```

Expected: exit code 0.

- [ ] **Step 3: Manual acceptance — pairing popup stays open**

No existing Swift test hook for `MainWindowActivator` / pairing focus. Verify manually:

1. Build and run MyPass; unlock vault; ensure extension is **unpaired** (or reset pairing secret).
2. Open Chrome on any https page; click MyPass toolbar icon → pairing panel visible.
3. Click **Connect**; pairing code sheet appears in MyPass **without** MyPass jumping in front of Chrome (popup stays open).
4. Enter the 6-digit code in the popup → pairing succeeds.
5. **Save-proposal still activates:** with extension paired, trigger a save prompt from a login form → MyPass main window still comes forward for the save sheet.

- [ ] **Step 4: Commit**

```bash
git add MyPass/MyPassApp.swift
git commit -m "fix(app): stop raising main window on pairing code generated"
```

---

## Self-review (spec coverage)

| Spec requirement | Task |
|------------------|------|
| 36×36 letter avatar, radius 8, semibold title, 12 px username | Task 2 (`buildLetterAvatarElement`, `renderCredentials`, CSS) |
| Colors match Swift `LetterAvatar.color(for:)` for ≥3 titles | Task 1 (5 titles in `letter-avatar.test.js`) |
| `fillCredential` + `window.close()` unchanged | Task 2 (`renderCredentials` click handler) |
| Locked: BrandKey, title, helper, Retry; no password / no unlock IPC | Task 2 (`locked-panel`, `handleCredentialsResponse`) |
| Pairing: “Connect browser extension”, Connect/code/Submit, styled errors | Task 2 (`pairing-panel`, existing pairing flow) |
| App not running: BrandKey, status, Retry/Open MyPass, no launch | Task 2 (`app-unavailable-panel`, existing fallback wiring) |
| Empty: “No saved logins for this site”, no spurious buttons | Task 2 (`empty-panel`) |
| Shell 280 px, 16–20 px padding, light theme, consistent buttons | Task 2 (`popup.html` CSS) |
| Focus fix: no `MainWindowActivator` on code generated; keep on save proposal | Task 3 |
| Existing + new ChromeExtension tests pass | Tasks 1–2 |
| Out of scope: background.js, content.js, ChromeHost, payload changes | Global Constraints |

**Placeholder scan:** No TBD/TODO/implement-later steps.

**Type consistency:** `letterFromTitle` / `colorForTitle` / `LETTER_AVATAR_PALETTE` defined in Task 1, consumed in Task 2 `buildLetterAvatarElement`. `showPanel` string literals match section IDs in `popup.html`.

**Gaps / optional follow-ups (out of scope):**

- Add `node ChromeExtension/tests/letter-avatar.test.js` and `popup-fallback.test.js` to `scripts/test.sh` — not required by spec; `./scripts/test.sh` still passes without them today.
- No automated UI test for popup layout; manual AC in Task 2 Step 8 and Task 3 Step 3 cover visual and focus behavior.
- `buildLetterAvatarElement` is not exported (spec: optional); DOM builder stays inside the document block.
