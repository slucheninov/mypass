const assert = require('node:assert');

// Same DOM stub shape as popup-fallback.test.js: getElementById mints elements on
// demand, so the popup's whole top-level wiring block runs under Node.
const elements = {};
function makeEl(id) {
  const el = {
    id,
    hidden: false,
    textContent: '',
    value: '',
    checked: false,
    disabled: false,
    onclick: null,
    className: '',
    style: {},
    children: [],
    listeners: {},
    appendChild(child) { this.children.push(child); },
    addEventListener(name, fn) { (this.listeners[name] = this.listeners[name] || []).push(fn); },
    setAttribute(name, value) { this[name] = value; }
  };
  let innerHTML = '';
  // Real DOM `.innerHTML = ''` (what renderPasskeyPicker uses to clear the list before
  // re-rendering) tears down existing children too — without mirroring that, `.children`
  // from an earlier render call would linger and be picked up by a later test's row-click
  // assertions, attributing an old, unrelated click handler to a "new" row.
  Object.defineProperty(el, 'innerHTML', {
    get() { return innerHTML; },
    set(value) {
      innerHTML = value;
      if (value === '') el.children = [];
    }
  });
  elements[id] = el;
  return el;
}

global.document = {
  getElementById: (id) => elements[id] || makeEl(id),
  createElement: () => makeEl(`created-${Object.keys(elements).length}`)
};

// The pending ceremony written by background.js lives in chrome.storage.session, which
// is what getPairingStorageArea() prefers.
let sessionStore = {};
const sentMessages = [];
let closed = 0;
global.window = { close: () => { closed += 1; } };

global.chrome = {
  storage: {
    local: {
      get: (_keys, cb) => cb({ passkeyProxyEnabled: true }),
      set: (_items, cb) => cb && cb(),
      remove: (_keys, cb) => cb && cb()
    },
    session: {
      get: (keys, cb) => {
        const result = {};
        for (const key of (Array.isArray(keys) ? keys : [keys])) {
          if (sessionStore[key] !== undefined) result[key] = sessionStore[key];
        }
        cb(result);
      },
      set: (items, cb) => { Object.assign(sessionStore, items); if (cb) cb(); },
      remove: (keys, cb) => {
        for (const key of (Array.isArray(keys) ? keys : [keys])) delete sessionStore[key];
        if (cb) cb();
      }
    }
  },
  runtime: {
    sendMessage: (msg, cb) => {
      sentMessages.push(msg);
      if (cb) cb({ type: 'ok' });
    }
  },
  tabs: { query: (_opts, cb) => cb([{ url: 'https://example.com', id: 1 }]) }
};

const {
  choosePasskeyPanel,
  passkeyCeremonySummary,
  passkeyTargetSummary,
  renderPasskeyCeremonyPanel,
  rehydratePendingPasskeyCeremony,
  sendPasskeyCancel,
  PENDING_PASSKEY_KEY,
  initPasskeySettingsToggle,
  initPasskeyPopupUI,
  renderCredentials
} = require('../popup.js');

// --- pure routing -----------------------------------------------------------
const withPasskey = { id: 'e1', title: 'Example', username: 'alice', hasPasskey: true };
const withoutPasskey = { id: 'e2', title: 'Example', username: 'bob', hasPasskey: false };

assert.strictEqual(choosePasskeyPanel({ kind: 'create', matches: [] }), 'passkey-save');
assert.strictEqual(choosePasskeyPanel({ kind: 'create', matches: [withoutPasskey] }), 'passkey-save');
assert.strictEqual(choosePasskeyPanel({ kind: 'create', matches: [withPasskey] }), 'passkey-replace');
assert.strictEqual(choosePasskeyPanel({ kind: 'create', matches: [withPasskey, withoutPasskey] }), 'passkey-picker');
assert.strictEqual(choosePasskeyPanel({ kind: 'get', matches: [withPasskey] }), 'passkey-use');
assert.strictEqual(choosePasskeyPanel({ kind: 'get', matches: [withPasskey, withoutPasskey] }), 'passkey-picker');
assert.strictEqual(choosePasskeyPanel({ kind: 'get', matches: [] }), null);
assert.strictEqual(choosePasskeyPanel(null), null);
assert.strictEqual(choosePasskeyPanel({ kind: 'nonsense', matches: [] }), null);
console.log('passkeyPopup.test.js: choosePasskeyPanel routing OK');

// A single get match must still land on the Approve panel — never an auto-sign path.
assert.notStrictEqual(choosePasskeyPanel({ kind: 'get', matches: [withPasskey] }), null);

// --- summary carries both RP id and origin (phishing resistance) -------------
assert.strictEqual(
  passkeyCeremonySummary({ rpId: 'example.com', originUrl: 'https://login.example.com' }),
  'example.com — https://login.example.com'
);
assert.ok(passkeyCeremonySummary({ rpId: 'example.com' }).includes('unknown origin'));
assert.strictEqual(passkeyCeremonySummary(null), '');
console.log('passkeyPopup.test.js: summary shows rpId and origin OK');

// --- passkeyTargetSummary: which entry is the save/replace target -----------
const basePending = { rpId: 'example.com', originUrl: 'https://example.com' };

// Gate 6 regression: zero matches must read as "a new entry will be created", not the
// bare rpId/origin pair that looked identical to the 1-match case.
assert.deepStrictEqual(passkeyTargetSummary({ ...basePending, matches: [] }), {
  headline: 'New entry for example.com',
  detail: 'example.com — https://example.com'
});

// One match with a username: headline names both the entry and the account on it.
assert.deepStrictEqual(passkeyTargetSummary({ ...basePending, matches: [withoutPasskey] }), {
  headline: 'Save passkey to "Example" (bob)?',
  detail: 'example.com — https://example.com'
});

// One match without a username: the "()" segment is omitted rather than left empty.
const noUsername = { id: 'e3', title: 'No Username Entry', username: '', hasPasskey: false };
assert.deepStrictEqual(passkeyTargetSummary({ ...basePending, matches: [noUsername] }), {
  headline: 'Save passkey to "No Username Entry"?',
  detail: 'example.com — https://example.com'
});

// One match that already has a passkey: Replace wording, not Save.
assert.deepStrictEqual(passkeyTargetSummary({ ...basePending, matches: [withPasskey] }), {
  headline: 'Replace passkey in "Example" (alice)?',
  detail: 'example.com — https://example.com'
});

// The picker path passes an explicit override (the row the user clicked) rather than
// relying on matches[0], since the picker's own matches list always has more than one.
assert.deepStrictEqual(
  passkeyTargetSummary({ ...basePending, matches: [withPasskey, withoutPasskey] }, withoutPasskey),
  { headline: 'Save passkey to "Example" (bob)?', detail: 'example.com — https://example.com' }
);

// The get flow was left behind when the create flow got a named headline: a single get
// match must also name the entry ("Sign in as ..."), not just repeat the bare rpId/origin.
assert.deepStrictEqual(passkeyTargetSummary({ ...basePending, kind: 'get', matches: [withPasskey] }), {
  headline: 'Sign in as "Example" (alice)?',
  detail: 'example.com — https://example.com'
});
const noUsernameWithPasskey = { id: 'e4', title: 'No Username Passkey', username: '', hasPasskey: true };
assert.deepStrictEqual(passkeyTargetSummary({ ...basePending, kind: 'get', matches: [noUsernameWithPasskey] }), {
  headline: 'Sign in as "No Username Passkey"?',
  detail: 'example.com — https://example.com'
});
console.log('passkeyPopup.test.js: passkeyTargetSummary headline/detail OK');

// --- rendering --------------------------------------------------------------
function resetPanels() {
  for (const el of Object.values(elements)) el.hidden = false;
  sentMessages.length = 0;
  closed = 0;
}

resetPanels();
assert.strictEqual(
  renderPasskeyCeremonyPanel({ kind: 'create', requestId: 1, rpId: 'example.com', originUrl: 'https://example.com', matches: [] }),
  true
);
assert.strictEqual(elements['passkey-save-panel'].hidden, false);
assert.strictEqual(elements['passkey-replace-panel'].hidden, true);
assert.strictEqual(elements['list-panel'].hidden, true, 'a ceremony hides the ordinary credential list');
assert.strictEqual(elements['add-totp-section'].hidden, true, 'a ceremony hides the Add-2FA section');
assert.strictEqual(elements['passkey-settings-footer'].hidden, true, 'a ceremony hides the settings toggle');
assert.strictEqual(elements['passkey-save-summary'].textContent, 'New entry for example.com');
assert.strictEqual(elements['passkey-save-detail'].textContent, 'example.com — https://example.com', 'origin line stays visible as a secondary line');
console.log('passkeyPopup.test.js: create panel renders and owns the popup OK');

resetPanels();
renderPasskeyCeremonyPanel({ kind: 'create', requestId: 1.5, rpId: 'example.com', originUrl: 'https://example.com', matches: [withoutPasskey] });
assert.strictEqual(elements['passkey-save-panel'].hidden, false);
assert.strictEqual(elements['passkey-save-summary'].textContent, 'Save passkey to "Example" (bob)?', 'single match names the target entry');
assert.strictEqual(elements['passkey-save-detail'].textContent, 'example.com — https://example.com');
console.log('passkeyPopup.test.js: single-match save panel names the target entry OK');

resetPanels();
renderPasskeyCeremonyPanel({ kind: 'create', requestId: 2, rpId: 'example.com', originUrl: 'https://example.com', matches: [withPasskey] });
assert.strictEqual(elements['passkey-replace-panel'].hidden, false);
assert.strictEqual(elements['passkey-replace-summary'].textContent, 'Replace passkey in "Example" (alice)?');
assert.strictEqual(elements['passkey-replace-detail'].textContent, 'example.com — https://example.com');
elements['passkey-replace-btn'].onclick();
assert.deepStrictEqual(sentMessages[0], { type: 'passkeyCreateConfirm', requestId: 2, entryId: 'e1', replace: true });
assert.strictEqual(closed, 1, 'confirming closes the popup');
assert.strictEqual(sessionStore[PENDING_PASSKEY_KEY], undefined, 'confirming clears the pending record');
console.log('passkeyPopup.test.js: replace panel sends replace:true and names the target entry OK');

resetPanels();
renderPasskeyCeremonyPanel({ kind: 'get', requestId: 3, rpId: 'example.com', originUrl: 'https://example.com', matches: [withPasskey] });
assert.strictEqual(elements['passkey-use-panel'].hidden, false);
// Gate: the "Use passkey" panel used to render only the bare rpId/origin summary, never
// naming which entry it was about to sign in as.
assert.strictEqual(elements['passkey-use-summary'].textContent, 'Sign in as "Example" (alice)?', 'the use panel must name the target entry');
assert.strictEqual(elements['passkey-use-detail'].textContent, 'example.com — https://example.com', 'the rpId/origin line stays visible for phishing resistance');
elements['passkey-approve-btn'].onclick();
assert.deepStrictEqual(sentMessages[0], { type: 'passkeyGetApprove', requestId: 3, entryId: 'e1' });
console.log('passkeyPopup.test.js: use panel names the target entry and approves with the matched entry OK');

resetPanels();
renderPasskeyCeremonyPanel({ kind: 'get', requestId: 4, rpId: 'example.com', originUrl: 'https://example.com', matches: [withPasskey, withoutPasskey] });
assert.strictEqual(elements['passkey-picker-panel'].hidden, false);
assert.strictEqual(elements['passkey-picker-list'].children.length, 2, 'one row per match');
elements['passkey-picker-cancel-btn'].onclick();
assert.deepStrictEqual(sentMessages[0], { type: 'passkeyCancelUI', requestId: 4 });
console.log('passkeyPopup.test.js: picker renders every match and can be cancelled OK');

// A real get ceremony's matches always have hasPasskey === true (that's what made them
// match), so both rows must carry the green badge — it used to be gated on
// `pending.kind === 'create'` and never showed for the get flow at all.
const withPasskeyAlice = { id: 'e5', title: 'Alice Site', username: 'alice', hasPasskey: true };
const withPasskeyCarol = { id: 'e6', title: 'Carol Site', username: 'carol', hasPasskey: true };
resetPanels();
renderPasskeyCeremonyPanel({ kind: 'get', requestId: 4.5, rpId: 'example.com', originUrl: 'https://example.com', matches: [withPasskeyAlice, withPasskeyCarol] });
const [getRowWithBadge, getRowAlsoWithBadge] = elements['passkey-picker-list'].children;
assert.ok(
  getRowWithBadge.children.some((c) => c.className === 'passkey-badge'),
  'a get-flow picker row for a passkey-bearing entry must show the passkey badge'
);
assert.ok(
  getRowAlsoWithBadge.children.some((c) => c.className === 'passkey-badge'),
  'every get-flow picker row (all of which have a passkey) must show the badge'
);
console.log('passkeyPopup.test.js: get-flow picker rows show the passkey badge OK');

// Gate 6 regression: picking a row that already has a passkey must land on the Replace
// confirm, not silently overwrite it via a direct passkeyCreateConfirm call.
resetPanels();
renderPasskeyCeremonyPanel({ kind: 'create', requestId: 12, rpId: 'example.com', originUrl: 'https://example.com', matches: [withPasskey, withoutPasskey] });
const [passkeyRow, plainRowNoBadge] = elements['passkey-picker-list'].children;
assert.ok(
  passkeyRow.children.some((c) => c.className === 'passkey-badge'),
  'a create-flow row for an entry that already has a passkey must show the badge'
);
assert.ok(
  !plainRowNoBadge.children.some((c) => c.className === 'passkey-badge'),
  'a create-flow row with no existing passkey must not show the badge'
);
passkeyRow.listeners.click[0]();
assert.strictEqual(sentMessages.length, 0, 'selecting an entry that already has a passkey must not confirm directly');
assert.strictEqual(elements['passkey-replace-panel'].hidden, false, 'it must route to the Replace confirm panel instead');
assert.strictEqual(elements['passkey-replace-summary'].textContent, 'Replace passkey in "Example" (alice)?');
elements['passkey-replace-btn'].onclick();
assert.deepStrictEqual(sentMessages[0], { type: 'passkeyCreateConfirm', requestId: 12, entryId: 'e1', replace: true });
console.log('passkeyPopup.test.js: picker routes an existing-passkey row to Replace confirm OK');

// A plain row (no existing passkey) still goes through an explicit Save confirm, naming
// that specific entry — not an immediate write either.
resetPanels();
renderPasskeyCeremonyPanel({ kind: 'create', requestId: 13, rpId: 'example.com', originUrl: 'https://example.com', matches: [withPasskey, withoutPasskey] });
const [, plainRowAgain] = elements['passkey-picker-list'].children;
plainRowAgain.listeners.click[0]();
assert.strictEqual(sentMessages.length, 0, 'selecting a plain entry must not confirm directly either');
assert.strictEqual(elements['passkey-save-panel'].hidden, false);
assert.strictEqual(elements['passkey-save-summary'].textContent, 'Save passkey to "Example" (bob)?');
elements['passkey-save-btn'].onclick();
assert.deepStrictEqual(sentMessages[0], { type: 'passkeyCreateConfirm', requestId: 13, entryId: 'e2', replace: false });
console.log('passkeyPopup.test.js: picker routes a plain row to a named Save confirm OK');

resetPanels();
sendPasskeyCancel(9);
assert.deepStrictEqual(sentMessages[0], { type: 'passkeyCancelUI', requestId: 9 });
assert.strictEqual(closed, 1);
console.log('passkeyPopup.test.js: cancel sends passkeyCancelUI and closes OK');

// --- rehydration takeover ----------------------------------------------------
sessionStore = {};
rehydratePendingPasskeyCeremony((tookOver) => {
  assert.strictEqual(tookOver, false, 'no pending ceremony means the ordinary flow proceeds');
});

sessionStore[PENDING_PASSKEY_KEY] = {
  kind: 'create', requestId: 5, rpId: 'example.com', originUrl: 'https://example.com', matches: []
};
rehydratePendingPasskeyCeremony((tookOver) => {
  assert.strictEqual(tookOver, true, 'a pending ceremony takes over the popup');
});

// A malformed record must not strand the popup on a blank panel.
sessionStore[PENDING_PASSKEY_KEY] = { kind: 'get', requestId: 6, rpId: 'example.com', matches: [] };
rehydratePendingPasskeyCeremony((tookOver) => {
  assert.strictEqual(tookOver, false, 'an unroutable record falls through to the ordinary flow');
});
console.log('passkeyPopup.test.js: rehydration takeover OK');

// --- refreshPasskeyProxy resync trigger --------------------------------------
// Regression coverage for the bug where the only resync send lived inside
// initPasskeySettingsToggle, which is skipped whenever a ceremony takes over the
// popup — meaning the proxy almost never resynced/detached during real passkey use.
//
// These drive the *production* call site directly via the exported `initPasskeyPopupUI`
// (the exact function popup.js itself invokes on load), rather than re-composing
// rehydrate/refresh/tookOver by hand in the test — a hand-rolled copy would not notice a
// regression such as `refreshPasskeyProxy()` moving back below `if (tookOver) return;`.
resetPanels();
sessionStore[PENDING_PASSKEY_KEY] = {
  kind: 'create', requestId: 30, rpId: 'example.com', originUrl: 'https://example.com', matches: []
};
initPasskeyPopupUI();
assert.strictEqual(elements['passkey-save-panel'].hidden, false, 'the ceremony must still take over the popup');
assert.strictEqual(
  sentMessages.filter((m) => m.type === 'refreshPasskeyProxy').length, 1,
  'refreshPasskeyProxy must fire even while a ceremony panel is being shown'
);
console.log('passkeyPopup.test.js: refreshPasskeyProxy fires during an active ceremony OK');

resetPanels();
sessionStore = {};
elements['passkey-settings-footer'].hidden = true;
initPasskeyPopupUI();
assert.strictEqual(
  sentMessages.filter((m) => m.type === 'refreshPasskeyProxy').length, 1,
  'refreshPasskeyProxy must still fire when there is no pending ceremony'
);
assert.strictEqual(
  elements['passkey-settings-footer'].hidden, false,
  'initPasskeySettingsToggle must still show the footer when idle'
);
assert.strictEqual(elements['passkey-proxy-toggle'].checked, true, 'checkbox still synced from stored cache');
console.log('passkeyPopup.test.js: refreshPasskeyProxy fires and settings footer/checkbox still initialize when idle OK');

// --- ordinary credential list: passkey badge --------------------------------
// Gate: the plain #list-panel rows never surfaced credential.hasPasskey at all, even
// though the summary the extension already receives carries it.
resetPanels();
renderCredentials(
  [
    { id: 'e1', title: 'Example', username: 'alice', hasPasskey: true },
    { id: 'e2', title: 'Other', username: 'bob', hasPasskey: false }
  ],
  'https://example.com'
);
const [listRowWithPasskey, listRowWithoutPasskey] = elements['list'].children;
assert.ok(
  listRowWithPasskey.children.some((c) => c.className === 'passkey-badge'),
  'a list row for an entry with a passkey must show the badge'
);
assert.ok(
  !listRowWithoutPasskey.children.some((c) => c.className === 'passkey-badge'),
  'a list row for an entry without a passkey must not show the badge'
);
console.log('passkeyPopup.test.js: ordinary credential list shows the passkey badge OK');

console.log('passkeyPopup.test.js OK');
