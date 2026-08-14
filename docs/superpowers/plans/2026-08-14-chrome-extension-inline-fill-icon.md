# Inline Fill Icon Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Put a key glyph inside recognised username / password / OTP fields that opens a panel listing this domain's entries and fills the form on selection.

**Architecture:** All work is inside `ChromeExtension/content.js` plus one new test suite. Pure decision functions (`findFillableFields`, `chooseInlinePanel`, the activation handlers) are written first and tested with fake DOM objects, exactly as `totpDetection.test.js` already does. Rendering sits on top of them behind a closed shadow root, positioned by absolute overlay so the page's own inputs are never mutated. The fill itself reuses the existing `fillCredential` → `relayFillToActiveTab` → `applyFill` path with no change to `background.js`.

**Tech Stack:** Plain ES5-compatible browser JS (no build step, no bundler), `node:assert` test scripts run directly by `node`, Chrome MV3 content script.

**Spec:** [`docs/superpowers/specs/2026-08-14-chrome-extension-inline-fill-icon-design.md`](../specs/2026-08-14-chrome-extension-inline-fill-icon-design.md)

## Global Constraints

- **No secret may appear in any message the content script sends.** The only fill message is `{ type: 'fillCredential', id, url }` — identical to `popup.js:617`.
- **No change to `background.js`, `popup.js`, `manifest.json`, or any Swift.** If a task appears to need one, stop — the design was wrong.
- **The site's own input elements must not be mutated.** No added padding, no wrapper element, no changed attributes. Position by absolute overlay only.
- **Every user-facing handler requires `event.isTrusted`.** A synthetic event performs no action and sends no message.
- **The icon renders on every recognised field**, regardless of match count or lock state. Conditional visibility would leak account existence to the site.
- **Panel UI is created inside `attachShadow({ mode: 'closed' })`.** Never `'open'`.
- **The icon glyph is an inline SVG path.** Never a `chrome-extension://` URL — `web_accessible_resources` is unset and must stay unset.
- **All new code lives inside the existing IIFE in `content.js`** and is added to its `module.exports` block so tests can reach it.
- **Test output style:** `console.log('inlineIcon.test.js: <section> OK')` at the end of each section, matching the existing suites.
- **English everywhere** except `RUN.md`, which is Ukrainian.

---

### Task 1: `findFillableFields` and a safe `findLoginForm` rewrite

`findLoginForm` has **no test coverage today** — `formDetection.test.js` covers only `findBestUsernameInput`, `hostnameMatches`, `scoreOtpLikeness` and `findOtpField`. So this task first pins the current behaviour with characterisation tests, then rewrites on top of the new finder. Without that first step the rewrite is unfalsifiable.

**Files:**
- Modify: `ChromeExtension/content.js:88-98` (`findLoginForm`), export block at `:459-468`
- Test: `ChromeExtension/tests/inlineIcon.test.js` (create)

**Interfaces:**
- Consumes: `findBestUsernameInput`, `findOtpField`, `scoreUsernameLikeness` (already in `content.js`)
- Produces:
  - `isFieldVisible(input) -> boolean`
  - `findFillableFields(root) -> Array<{ input: Element, kind: 'username'|'password'|'otp' }>`
  - `findLoginForm()` — unchanged signature `{ form, passwordInput, usernameInput } | null`, but `form` may now be `null`

- [ ] **Step 1: Write the characterisation tests for today's `findLoginForm`**

Create `ChromeExtension/tests/inlineIcon.test.js`:

```js
const assert = require('node:assert');

function fakeInput(attrs = {}, extra = {}) {
  return {
    getAttribute: (name) => (Object.prototype.hasOwnProperty.call(attrs, name) ? attrs[name] : null),
    offsetParent: extra.hidden ? null : {},
    disabled: !!extra.disabled,
    readOnly: !!extra.readOnly,
    closest: (sel) => (sel === 'form' ? extra.form || null : null),
    tagName: 'INPUT',
  };
}

function fakeScope(inputs, formScope) {
  return {
    querySelectorAll: (selector) => {
      if (selector === 'input[type="password"]') {
        return inputs.filter((i) => i.getAttribute('type') === 'password');
      }
      if (selector === 'input, textarea') return inputs;
      // the username selector
      return inputs.filter((i) => {
        const t = i.getAttribute('type');
        return t === 'text' || t === 'email' || (i.getAttribute('autocomplete') || '').includes('username');
      });
    },
    __formScope: formScope,
  };
}

const { isFieldVisible, findFillableFields } = require('../content.js');

// isFieldVisible
assert.strictEqual(isFieldVisible(fakeInput({ type: 'text' })), true, 'plain visible input is fillable');
assert.strictEqual(isFieldVisible(fakeInput({ type: 'text' }, { hidden: true })), false, 'offsetParent null is not fillable');
assert.strictEqual(isFieldVisible(fakeInput({ type: 'text', disabled: '' })), false, 'disabled attribute excluded');
assert.strictEqual(isFieldVisible(fakeInput({ type: 'text' }, { readOnly: true })), false, 'readOnly property excluded');
console.log('inlineIcon.test.js: isFieldVisible OK');
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `node ChromeExtension/tests/inlineIcon.test.js`
Expected: `TypeError: isFieldVisible is not a function`

- [ ] **Step 3: Implement `isFieldVisible`**

In `content.js`, immediately after `findOtpField` (currently ending at `:86`):

```js
  function isFieldVisible(input) {
    if (!input) return false;
    if (input.offsetParent === null) return false;
    const disabled = input.getAttribute('disabled') !== null || input.disabled === true;
    const readOnly = input.getAttribute('readonly') !== null || input.readOnly === true;
    return !disabled && !readOnly;
  }
```

Add `isFieldVisible` to `module.exports`.

- [ ] **Step 4: Run the test — expect PASS**

Run: `node ChromeExtension/tests/inlineIcon.test.js`
Expected: `inlineIcon.test.js: isFieldVisible OK`

- [ ] **Step 5: Write the failing `findFillableFields` tests**

Append to `inlineIcon.test.js`:

```js
// findFillableFields
const pw = fakeInput({ type: 'password' });
const user = fakeInput({ type: 'text', name: 'username' });
const kinds = (fields) => fields.map((f) => f.kind).sort();

assert.deepStrictEqual(
  kinds(findFillableFields(fakeScope([user, pw]))),
  ['password', 'username'],
  'password outside any form still yields both fields'
);

const userOnly = findFillableFields(fakeScope([fakeInput({ type: 'email', name: 'email' })]));
assert.deepStrictEqual(kinds(userOnly), ['username'], 'identifier-first page with no password field still gets a username field');

assert.deepStrictEqual(
  findFillableFields(fakeScope([fakeInput({ type: 'password' }, { hidden: true })])),
  [],
  'hidden password field yields nothing'
);

// An OTP field also matches the username selector — OTP must win, and the field
// must appear exactly once.
const otp = fakeInput({ type: 'text', autocomplete: 'one-time-code' });
const otpFields = findFillableFields(fakeScope([otp]));
assert.deepStrictEqual(kinds(otpFields), ['otp'], 'one-time-code field is classified otp, not username');
assert.strictEqual(otpFields.length, 1, 'a field is never emitted twice');
console.log('inlineIcon.test.js: findFillableFields OK');
```

- [ ] **Step 6: Run it to make sure it fails**

Run: `node ChromeExtension/tests/inlineIcon.test.js`
Expected: `TypeError: findFillableFields is not a function`

- [ ] **Step 7: Implement `findFillableFields`**

```js
  // Returns every field the inline icon may attach to. Deliberately looser than the old
  // findLoginForm: a password field no longer has to sit inside a <form>, and a username
  // field is emitted even when no password field exists, so identifier-first login screens
  // (username on step 1, password on step 2) are covered.
  function findFillableFields(root) {
    const scope = root || document;
    const fields = [];

    const passwords = Array.from(scope.querySelectorAll('input[type="password"]')).filter(isFieldVisible);
    for (const password of passwords) {
      fields.push({ input: password, kind: 'password' });
    }

    const formScope = (passwords[0] && passwords[0].closest && passwords[0].closest('form')) || scope;
    const usernameCandidates = Array.from(
      formScope.querySelectorAll('input[type="text"], input[type="email"], input[autocomplete*="username"]')
    ).filter(isFieldVisible);
    const username = findBestUsernameInput(usernameCandidates);
    if (username) {
      fields.push({ input: username, kind: 'username' });
    }

    // An OTP input is type=text or type=tel, so it also satisfies the username selector
    // above and can win findBestUsernameInput on a 2FA-only page. Classify it as otp and
    // drop the duplicate rather than letting one element carry two icons.
    const otp = findOtpField(scope);
    if (otp) {
      const duplicate = fields.findIndex((field) => field.input === otp);
      if (duplicate >= 0) fields.splice(duplicate, 1);
      fields.push({ input: otp, kind: 'otp' });
    }

    return fields;
  }
```

Add `findFillableFields` to `module.exports`.

- [ ] **Step 8: Run the test — expect PASS**

Run: `node ChromeExtension/tests/inlineIcon.test.js`
Expected: both sections print OK

- [ ] **Step 9: Rewrite `findLoginForm` on top of the new finder**

Replace `content.js:88-98` entirely:

```js
  // Kept for applyFill's existing contract. Rebuilt on findFillableFields so the two
  // cannot drift apart. `form` is now nullable: a password field outside any <form> used
  // to make this return null, which meant applyFill silently did nothing on such pages.
  function findLoginForm() {
    const fields = findFillableFields(document);
    const passwordField = fields.find((field) => field.kind === 'password');
    if (!passwordField) return null;
    const usernameField = fields.find((field) => field.kind === 'username');
    const form = passwordField.input.closest ? passwordField.input.closest('form') : null;
    return {
      form,
      passwordInput: passwordField.input,
      usernameInput: usernameField ? usernameField.input : null,
    };
  }
```

- [ ] **Step 10: Guard the one caller that assumes `form` is non-null**

`attachSubmitListener` at `content.js:403` calls `loginForm.form.addEventListener`. It now must tolerate a null form:

```js
    function attachSubmitListener(loginForm) {
      if (!loginForm.form) return;
      loginForm.form.addEventListener('submit', () => {
```

- [ ] **Step 11: Run the full JS suite — nothing may regress**

Run: `node ChromeExtension/tests/formDetection.test.js && node ChromeExtension/tests/totpDetection.test.js && node ChromeExtension/tests/inlineIcon.test.js`
Expected: all print their OK lines, no assertion failures

- [ ] **Step 12: Commit**

```bash
git add ChromeExtension/content.js ChromeExtension/tests/inlineIcon.test.js
git commit -m "feat(extension): detect every fillable field, not just forms with a password"
```

---

### Task 2: `chooseInlinePanel` — pure panel routing

**Files:**
- Modify: `ChromeExtension/content.js` (add near `classifyGetCredentialsResponse` at `:220`), export block
- Test: `ChromeExtension/tests/inlineIcon.test.js`

**Interfaces:**
- Consumes: `classifyGetCredentialsResponse` (exists at `content.js:220`)
- Produces: `chooseInlinePanel(response, fieldKind) -> { panel: 'entries'|'empty'|'locked'|'pairingRequired'|'unavailable', entries: Array }`

- [ ] **Step 1: Write the failing tests**

Append to `inlineIcon.test.js`:

```js
const { chooseInlinePanel } = require('../content.js');

const withTotp = { id: '1', title: 'Example', username: 'alice', hasTotp: true };
const noTotp = { id: '2', title: 'Other', username: 'bob', hasTotp: false };
const listResponse = { type: 'credentialList', credentials: [withTotp, noTotp] };

assert.deepStrictEqual(
  chooseInlinePanel(listResponse, 'password'),
  { panel: 'entries', entries: [withTotp, noTotp] },
  'password field lists every match'
);

assert.deepStrictEqual(
  chooseInlinePanel(listResponse, 'otp'),
  { panel: 'entries', entries: [withTotp] },
  'otp field lists only entries that have a TOTP secret'
);

assert.deepStrictEqual(
  chooseInlinePanel({ type: 'credentialList', credentials: [noTotp] }, 'otp'),
  { panel: 'empty', entries: [] },
  'a non-empty list with no TOTP entries renders empty on an otp field'
);

assert.deepStrictEqual(
  chooseInlinePanel({ type: 'credentialList', credentials: [] }, 'password'),
  { panel: 'empty', entries: [] },
  'no matches for this site'
);

assert.strictEqual(chooseInlinePanel({ type: 'locked' }, 'password').panel, 'locked');
assert.strictEqual(chooseInlinePanel({ type: 'pairingRequired' }, 'password').panel, 'pairingRequired');
assert.strictEqual(chooseInlinePanel({ type: 'error' }, 'password').panel, 'unavailable');
assert.strictEqual(chooseInlinePanel(null, 'password').panel, 'unavailable', 'no response is treated as app unavailable');
assert.strictEqual(chooseInlinePanel({ type: 'somethingNew' }, 'password').panel, 'unavailable', 'unknown response never renders entries');
console.log('inlineIcon.test.js: chooseInlinePanel OK');
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `node ChromeExtension/tests/inlineIcon.test.js`
Expected: `TypeError: chooseInlinePanel is not a function`

- [ ] **Step 3: Implement it**

```js
  // Panel state is a function of the connection state and the field kind, never of which
  // element was clicked. Extracted as a pure function for the same reason Stage 6 extracted
  // choosePasskeyPanel: routing is the part worth testing, and a DOM makes it untestable.
  function chooseInlinePanel(response, fieldKind) {
    const kind = classifyGetCredentialsResponse(response);
    if (kind === 'locked') return { panel: 'locked', entries: [] };
    if (kind === 'pairingRequired') return { panel: 'pairingRequired', entries: [] };
    if (kind !== 'credentialList') return { panel: 'unavailable', entries: [] };

    const all = response.credentials || [];
    const entries = fieldKind === 'otp' ? all.filter((entry) => entry.hasTotp) : all;
    return entries.length === 0 ? { panel: 'empty', entries: [] } : { panel: 'entries', entries };
  }
```

Add `chooseInlinePanel` to `module.exports`.

- [ ] **Step 4: Run the test — expect PASS**

Run: `node ChromeExtension/tests/inlineIcon.test.js`
Expected: `inlineIcon.test.js: chooseInlinePanel OK`

- [ ] **Step 5: Commit**

```bash
git add ChromeExtension/content.js ChromeExtension/tests/inlineIcon.test.js
git commit -m "feat(extension): route the inline panel by connection state and field kind"
```

---

### Task 3: Trusted-event gate and the fill message

This is the security core. Both handlers take their dependencies as parameters so they are testable with no DOM and no `chrome` global.

**Files:**
- Modify: `ChromeExtension/content.js`, export block
- Test: `ChromeExtension/tests/inlineIcon.test.js`

**Interfaces:**
- Produces:
  - `isTrustedActivation(event) -> boolean`
  - `handleEntrySelect(event, entryId, url, sendMessage) -> boolean` — returns whether it acted
  - `handleIconActivate(event, requestPanel) -> boolean`

- [ ] **Step 1: Write the failing tests**

Append to `inlineIcon.test.js`:

```js
const { isTrustedActivation, handleEntrySelect, handleIconActivate } = require('../content.js');

assert.strictEqual(isTrustedActivation({ isTrusted: true }), true);
assert.strictEqual(isTrustedActivation({ isTrusted: false }), false, 'synthetic events are rejected');
assert.strictEqual(isTrustedActivation({}), false, 'a missing isTrusted is rejected, not assumed true');
assert.strictEqual(isTrustedActivation(null), false, 'no event is rejected');

// handleEntrySelect: the ONLY message it may send, and only on a trusted event.
const sent = [];
const record = (message) => sent.push(message);

assert.strictEqual(
  handleEntrySelect({ isTrusted: false }, 'entry-1', 'https://example.com', record),
  false,
  'synthetic click does not fill'
);
assert.deepStrictEqual(sent, [], 'synthetic click sends nothing at all');

assert.strictEqual(handleEntrySelect({ isTrusted: true }, 'entry-1', 'https://example.com', record), true);
assert.deepStrictEqual(
  sent,
  [{ type: 'fillCredential', id: 'entry-1', url: 'https://example.com' }],
  'fill message is exactly what popup.js sends — no secret, no extra field'
);

// handleIconActivate
let opened = 0;
assert.strictEqual(handleIconActivate({ isTrusted: false }, () => { opened += 1; }), false);
assert.strictEqual(opened, 0, 'synthetic click does not open the panel');
assert.strictEqual(handleIconActivate({ isTrusted: true }, () => { opened += 1; }), true);
assert.strictEqual(opened, 1);
console.log('inlineIcon.test.js: trusted-event gate OK');
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `node ChromeExtension/tests/inlineIcon.test.js`
Expected: `TypeError: isTrustedActivation is not a function`

- [ ] **Step 3: Implement the three functions**

```js
  // The inline icon is a control the PAGE can see and dispatch events at, unlike the popup.
  // Every activation path therefore requires a user-generated event. This is not defence in
  // depth: relayFillToActiveTab in background.js resolves its target with
  // chrome.tabs.query({active: true}) rather than sender.tab.id, which is only sound because
  // a trusted click implies the tab is the one the user is looking at.
  function isTrustedActivation(event) {
    return !!(event && event.isTrusted === true);
  }

  function handleIconActivate(event, requestPanel) {
    if (!isTrustedActivation(event)) return false;
    requestPanel();
    return true;
  }

  // Sends the identical message popup.js:617 sends. The content script never learns the
  // secret: background.js resolves it natively and delivers it straight back as applyFill.
  function handleEntrySelect(event, entryId, url, sendMessage) {
    if (!isTrustedActivation(event)) return false;
    sendMessage({ type: 'fillCredential', id: entryId, url });
    return true;
  }
```

Add all three to `module.exports`.

- [ ] **Step 4: Run the test — expect PASS**

Run: `node ChromeExtension/tests/inlineIcon.test.js`
Expected: `inlineIcon.test.js: trusted-event gate OK`

- [ ] **Step 5: Commit**

```bash
git add ChromeExtension/content.js ChromeExtension/tests/inlineIcon.test.js
git commit -m "feat(extension): require a trusted event before opening or filling"
```

---

### Task 4: The icon host — closed shadow root, inline SVG, no page mutation

**Files:**
- Modify: `ChromeExtension/content.js`, export block
- Test: `ChromeExtension/tests/inlineIcon.test.js`

**Interfaces:**
- Produces:
  - `KEY_ICON_SVG` — string constant
  - `buildIconHost(documentRef) -> { host, shadow, button }`
  - `positionHostToField(host, rect, viewport)` — sets `host.style` only

- [ ] **Step 1: Write the failing tests**

Append to `inlineIcon.test.js`:

```js
const { buildIconHost, positionHostToField, KEY_ICON_SVG } = require('../content.js');

function fakeElement(tag) {
  const el = {
    tagName: tag.toUpperCase(),
    style: {},
    children: [],
    attributes: {},
    shadowMode: null,
    setAttribute(name, value) { this.attributes[name] = value; },
    getAttribute(name) { return Object.prototype.hasOwnProperty.call(this.attributes, name) ? this.attributes[name] : null; },
    appendChild(child) { this.children.push(child); return child; },
    addEventListener() {},
    attachShadow(options) {
      this.shadowMode = options.mode;
      const root = fakeElement('shadow-root');
      this.__shadow = root;
      return root;
    },
  };
  return el;
}

const fakeDocument = { createElement: (tag) => fakeElement(tag) };

const built = buildIconHost(fakeDocument);
assert.strictEqual(built.host.shadowMode, 'closed', 'shadow root MUST be closed so the page cannot read the panel');
assert.ok(built.shadow, 'a shadow root is returned');
assert.ok(built.button, 'a clickable button lives inside the shadow root');
assert.ok(/svg/i.test(KEY_ICON_SVG), 'the glyph is inline SVG markup');
assert.ok(!/chrome-extension:/.test(KEY_ICON_SVG), 'the glyph never references an extension URL');

// positioning writes only to the host's own style — the page's input is untouched
const host = fakeElement('div');
positionHostToField(host, { top: 100, left: 50, width: 200, height: 30 }, { scrollX: 0, scrollY: 0 });
assert.strictEqual(host.style.position, 'absolute');
assert.ok(host.style.top, 'a top offset is written');
assert.ok(host.style.left, 'a left offset is written');
console.log('inlineIcon.test.js: icon host OK');
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `node ChromeExtension/tests/inlineIcon.test.js`
Expected: `TypeError: buildIconHost is not a function`

- [ ] **Step 3: Implement the host builder**

```js
  // web_accessible_resources is unset in the manifest and must stay unset: declaring the
  // PNGs would let any page probe for them. The glyph is therefore inline markup, drawn to
  // read as the same object as the app's menu-bar key.fill SF Symbol.
  const KEY_ICON_SVG =
    '<svg viewBox="0 0 16 16" width="14" height="14" aria-hidden="true">' +
    '<path fill="currentColor" d="M10.5 1a4.5 4.5 0 0 0-4.3 5.9L1 12.1V15h2.9l.6-.6v-1.3h1.3l.9-.9v-1.3h1.3l1.2-1.2A4.5 4.5 0 1 0 10.5 1zm1.4 3.6a1 1 0 1 1 1.4-1.4 1 1 0 0 1-1.4 1.4z"/>' +
    '</svg>';

  const ICON_HOST_STYLE =
    ':host{all:initial}' +
    'button{all:unset;cursor:pointer;display:flex;align-items:center;justify-content:center;' +
    'width:20px;height:20px;border-radius:4px;color:#6b7280;opacity:0.65;}' +
    'button:hover,button:focus-visible{opacity:1;background:rgba(127,127,127,0.15);}';

  function buildIconHost(documentRef) {
    const doc = documentRef || document;
    const host = doc.createElement('div');
    // z-index one below the banners' 2147483647 so a save banner still wins if they overlap.
    host.setAttribute('data-mypass-inline-icon', '');
    host.style.position = 'absolute';
    host.style.zIndex = '2147483646';
    host.style.pointerEvents = 'auto';

    const shadow = host.attachShadow({ mode: 'closed' });
    const style = doc.createElement('style');
    style.textContent = ICON_HOST_STYLE;
    shadow.appendChild(style);

    const button = doc.createElement('button');
    button.setAttribute('type', 'button');
    button.setAttribute('aria-label', 'Fill from MyPass');
    button.innerHTML = KEY_ICON_SVG;
    shadow.appendChild(button);

    return { host, shadow, button };
  }

  // Writes to the overlay host only. The page's own input is never given padding, a
  // wrapper, or any attribute — that is the whole reason for the overlay approach.
  function positionHostToField(host, rect, viewport) {
    const scrollX = viewport && typeof viewport.scrollX === 'number' ? viewport.scrollX : 0;
    const scrollY = viewport && typeof viewport.scrollY === 'number' ? viewport.scrollY : 0;
    const size = 20;
    const inset = 6;
    host.style.position = 'absolute';
    host.style.top = String(rect.top + scrollY + (rect.height - size) / 2) + 'px';
    host.style.left = String(rect.left + scrollX + rect.width - size - inset) + 'px';
  }
```

Add `buildIconHost`, `positionHostToField`, `KEY_ICON_SVG` to `module.exports`.

- [ ] **Step 4: Run the test — expect PASS**

Run: `node ChromeExtension/tests/inlineIcon.test.js`
Expected: `inlineIcon.test.js: icon host OK`

- [ ] **Step 5: Commit**

```bash
git add ChromeExtension/content.js ChromeExtension/tests/inlineIcon.test.js
git commit -m "feat(extension): build the inline key icon in a closed shadow root"
```

---

### Task 5: The panel — render the routed state and wire the fill

**Files:**
- Modify: `ChromeExtension/content.js`, export block
- Test: `ChromeExtension/tests/inlineIcon.test.js`

**Interfaces:**
- Consumes: `chooseInlinePanel`, `handleEntrySelect`, `buildIconHost` (its shadow-root pattern)
- Produces: `buildPanelContent(documentRef, routed, callbacks) -> { root, rows }` where `callbacks = { onSelect(event, entryId), onUnlock(event) }`

- [ ] **Step 1: Write the failing tests**

Append to `inlineIcon.test.js`:

```js
const { buildPanelContent } = require('../content.js');

const entriesPanel = buildPanelContent(
  fakeDocument,
  { panel: 'entries', entries: [withTotp, noTotp] },
  { onSelect: () => {}, onUnlock: () => {} }
);
assert.strictEqual(entriesPanel.rows.length, 2, 'one row per entry');

const emptyPanel = buildPanelContent(fakeDocument, { panel: 'empty', entries: [] }, { onSelect: () => {}, onUnlock: () => {} });
assert.strictEqual(emptyPanel.rows.length, 0, 'the empty state has no selectable rows');

const lockedPanel = buildPanelContent(fakeDocument, { panel: 'locked', entries: [] }, { onSelect: () => {}, onUnlock: () => {} });
assert.strictEqual(lockedPanel.rows.length, 0, 'the locked state offers no entries');
assert.ok(lockedPanel.unlockButton, 'the locked state offers an unlock button');

const pairingPanel = buildPanelContent(fakeDocument, { panel: 'pairingRequired', entries: [] }, { onSelect: () => {}, onUnlock: () => {} });
assert.strictEqual(pairingPanel.unlockButton, null, 'the pairing state offers no unlock button');
console.log('inlineIcon.test.js: panel content OK');
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `node ChromeExtension/tests/inlineIcon.test.js`
Expected: `TypeError: buildPanelContent is not a function`

- [ ] **Step 3: Implement it**

```js
  const PANEL_MESSAGES = {
    empty: 'No entries for this site',
    locked: 'MyPass is locked',
    pairingRequired: 'Pair MyPass to use it here',
    unavailable: 'MyPass is not running',
  };

  function buildPanelContent(documentRef, routed, callbacks) {
    const doc = documentRef || document;
    const root = doc.createElement('div');
    const rows = [];
    let unlockButton = null;

    if (routed.panel === 'entries') {
      for (const entry of routed.entries) {
        const row = doc.createElement('button');
        row.setAttribute('type', 'button');
        row.setAttribute('data-entry-id', entry.id);
        row.textContent = entry.title + (entry.username ? ' — ' + entry.username : '');
        row.addEventListener('click', (event) => callbacks.onSelect(event, entry.id));
        root.appendChild(row);
        rows.push(row);
      }
    } else {
      const message = doc.createElement('div');
      message.textContent = PANEL_MESSAGES[routed.panel] || PANEL_MESSAGES.unavailable;
      root.appendChild(message);

      if (routed.panel === 'locked') {
        unlockButton = doc.createElement('button');
        unlockButton.setAttribute('type', 'button');
        unlockButton.textContent = 'Unlock MyPass';
        unlockButton.addEventListener('click', (event) => callbacks.onUnlock(event));
        root.appendChild(unlockButton);
      }
    }

    return { root, rows, unlockButton };
  }
```

Add `buildPanelContent` to `module.exports`.

- [ ] **Step 4: Run the test — expect PASS**

Run: `node ChromeExtension/tests/inlineIcon.test.js`
Expected: `inlineIcon.test.js: panel content OK`

- [ ] **Step 5: Commit**

```bash
git add ChromeExtension/content.js ChromeExtension/tests/inlineIcon.test.js
git commit -m "feat(extension): render the inline panel for every routed state"
```

---

### Task 6: Lifecycle — attach icons, keep them aligned, open and close the panel

This task has no new unit tests: it is the DOM wiring the previous five tasks were extracted *out of* so they could be tested. Its verification is the manual walk in Task 7.

**Files:**
- Modify: `ChromeExtension/content.js` (browser-only block at `:382-457`)

**Interfaces:**
- Consumes: everything produced by Tasks 1–5

- [ ] **Step 1: Add the attach/sync manager**

Inside the `if (typeof chrome !== 'undefined' && typeof document !== 'undefined')` block, after `requestCredentials`:

```js
    const attachedIcons = new Map();
    let openPanel = null;
    let syncScheduled = false;

    function syncIconPositions() {
      syncScheduled = false;
      attachedIcons.forEach((record, input) => {
        const rect = input.getBoundingClientRect();
        const offscreen = rect.bottom < 0 || rect.top > window.innerHeight || rect.width === 0;
        record.host.style.display = offscreen ? 'none' : 'block';
        if (!offscreen) positionHostToField(record.host, rect, window);
      });
    }

    function scheduleSync() {
      if (syncScheduled) return;
      syncScheduled = true;
      window.requestAnimationFrame(syncIconPositions);
    }

    function attachIconTo(input, kind) {
      if (attachedIcons.has(input)) return;
      const { host, button } = buildIconHost(document);
      button.addEventListener('click', (event) => {
        handleIconActivate(event, () => togglePanel(input, kind));
      });
      document.body.appendChild(host);
      attachedIcons.set(input, { host, kind });

      const resizeObserver = new ResizeObserver(scheduleSync);
      resizeObserver.observe(input);
      attachedIcons.get(input).resizeObserver = resizeObserver;
      scheduleSync();
    }

    function attachIcons() {
      for (const field of findFillableFields(document)) {
        attachIconTo(field.input, field.kind);
      }
    }
```

- [ ] **Step 2: Add panel open/close**

```js
    function closePanel() {
      if (!openPanel) return;
      openPanel.host.remove();
      openPanel = null;
    }

    function togglePanel(input, kind) {
      if (openPanel && openPanel.input === input) {
        closePanel();
        return;
      }
      closePanel();
      // Always re-ask rather than trusting state.lastCredentialList: the vault may have
      // been unlocked since page load, and a stale locked panel is the exact failure
      // Stage 3 shipped and had to fix.
      chrome.runtime.sendMessage({ type: 'getCredentials', url: location.href }, (response) => {
        const routed = chooseInlinePanel(response, kind);
        const { host, shadow } = buildIconHost(document);
        const content = buildPanelContent(document, routed, {
          onSelect: (event, entryId) => {
            if (handleEntrySelect(event, entryId, location.href, (m) => chrome.runtime.sendMessage(m))) {
              closePanel();
            }
          },
          onUnlock: (event) => {
            if (isTrustedActivation(event)) {
              chrome.runtime.sendMessage({ type: 'requestUnlock' });
              closePanel();
            }
          },
        });
        shadow.appendChild(content.root);
        const rect = input.getBoundingClientRect();
        host.style.top = String(rect.bottom + window.scrollY + 4) + 'px';
        host.style.left = String(rect.left + window.scrollX) + 'px';
        document.body.appendChild(host);
        openPanel = { host, input };
      });
    }
```

- [ ] **Step 3: Wire the listeners**

Replace the bootstrap at `content.js:446-450`:

```js
    const loginForm = findLoginForm();
    if (loginForm) {
      requestCredentials();
      attachSubmitListener(loginForm);
    }
    attachIcons();

    window.addEventListener('scroll', scheduleSync, { capture: true, passive: true });
    window.addEventListener('resize', scheduleSync, { passive: true });
    document.addEventListener('click', (event) => {
      if (openPanel && event.target !== openPanel.host) closePanel();
    }, true);
    document.addEventListener('keydown', (event) => {
      if (event.key === 'Escape') closePanel();
    }, true);
```

- [ ] **Step 4: Re-attach on DOM changes**

Extend `observeTotpCandidates`'s debounced callback (`content.js:321-326`) to also call `attachIcons()`:

```js
      debounceTimer = setTimeout(() => {
        attachIcons();
        const detected = detectTotpCandidateWithPriority(document);
        if (shouldShowTotpBanner(detected, state)) {
          showTotpSaveBanner(location.href, detected.candidate, state, detected.priority);
        }
      }, 400);
```

Note: `observeTotpCandidates` is defined outside the browser-only block but only called inside it. Move the `attachIcons` call in by passing it as a parameter: `observeTotpCandidates(state, attachIcons)` and give the function an `onMutation` parameter defaulting to a no-op, so the exported function stays callable from tests.

- [ ] **Step 5: Run the full JS suite**

Run: `for f in ChromeExtension/tests/*.test.js; do node "$f" || break; done`
Expected: every suite prints its OK lines

- [ ] **Step 6: Commit**

```bash
git add ChromeExtension/content.js
git commit -m "feat(extension): attach inline icons and keep them aligned to their fields"
```

---

### Task 7: Wire the suite, document the manual walk, record the stage

**Files:**
- Modify: `scripts/test.sh:29-39`
- Modify: `RUN.md`
- Modify: `docs/implementation/ROADMAP.md`

- [ ] **Step 1: Wire the new suite**

In `scripts/test.sh`, after the `passkeyPopup.test.js` line:

```bash
  node ChromeExtension/tests/inlineIcon.test.js
```

- [ ] **Step 2: Run the full suite**

Run: `test -f /tmp/citadel_smoke_key || ssh-keygen -t ed25519 -N "correct-horse-battery-staple" -f /tmp/citadel_smoke_key -C "smoketest@mypass"; ./scripts/test.sh; echo "EXIT=$?"`
Expected: `EXIT=0` and `** TEST SUCCEEDED **`. Never judge this by `| tail` — the pipeline reports tail's exit code.

- [ ] **Step 3: Add the manual checklist to `RUN.md` (Ukrainian)**

Append to the Chrome section:

```markdown
   - [ ] Іконка-ключ з'являється в полях логіна, пароля і 2FA-коду; вона є навіть коли для сайту немає записів і коли сховище заблоковане
   - [ ] Сторінка без `<form>` (пароль поза формою) — іконка все одно з'являється і заповнення працює
   - [ ] Identifier-first вхід (спочатку логін, пароль на другому кроці) — іконка є на обох кроках
   - [ ] Клік по іконці відкриває панель; клік поза нею і Escape закривають
   - [ ] Вибір запису заповнює логін і пароль, а для запису з 2FA — ще й поле коду
   - [ ] На полі 2FA у списку лише записи, що мають 2FA
   - [ ] Заблоковане сховище → панель «MyPass заблоковано» з кнопкою розблокування; після розблокування панель показує записи **без перезавантаження сторінки**
   - [ ] Прокрутка, зміна розміру вікна і зум не зсувають іконку відносно поля
   - [ ] Сайт із власною іконкою «око» в полі пароля — сайтом можна далі користуватись
   - [ ] У DevTools перевірити, що `<input>` сайту не змінений: без доданого padding, без обгортки, без нових атрибутів
   - [ ] У консолі сторінки виконати `document.querySelector('[data-mypass-inline-icon]').shadowRoot` → має бути `null` (closed shadow root)
   - [ ] У консолі сторінки синтетичний клік `document.querySelector('[data-mypass-inline-icon]').click()` не відкриває панель і нічого не заповнює
```

- [ ] **Step 4: Add the stage to `docs/implementation/ROADMAP.md`**

Add a Stage 7 section with items `I1`–`I7` mapping to Tasks 1–7 of this plan, and a row in the Progress table. Mark the gate open until the manual walk is done.

- [ ] **Step 5: Commit**

```bash
git add scripts/test.sh RUN.md docs/implementation/ROADMAP.md
git commit -m "test(extension): wire the inline-icon suite and document its manual walk"
```

---

## Self-Review

**Spec coverage.** Every spec section maps to a task: isolation → Task 4; positioning → Tasks 4 and 6; field recognition → Task 1; panel contents → Tasks 2 and 5; fill → Task 3; icon asset → Task 4; testing → Tasks 1–5 automated, Task 7 manual. Acceptance criteria 1–4 and 7–9 are covered by the manual bullets; 5 and 10–11 have both an automated assertion and a manual bullet; 6 is manual only.

**Known deviation from the spec.** The spec claimed a green `formDetection.test.js` would prove the `findLoginForm` rewrite preserves behaviour. It would not — that suite never touched `findLoginForm`. Task 1 therefore adds the missing coverage first. The spec should be read with that correction.

**Type consistency.** `chooseInlinePanel` returns `{ panel, entries }` in Task 2 and is consumed with those exact keys in Tasks 5 and 6. `buildIconHost` returns `{ host, shadow, button }` in Task 4 and is destructured as such in Task 6. `handleEntrySelect(event, entryId, url, sendMessage)` keeps its argument order between Tasks 3 and 6. `findFillableFields` returns `{ input, kind }` in Task 1 and is read as such in Task 6.

**Deliberate gap.** Task 6 ships without unit tests by design — it is the DOM shell the testable logic was extracted from. Its gate is the Task 7 manual walk, which is why that walk is written as twelve specific bullets rather than "verify it works".
