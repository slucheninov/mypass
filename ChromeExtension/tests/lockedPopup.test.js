const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');

const html = fs.readFileSync(path.join(__dirname, '..', 'popup.html'), 'utf8');
const source = fs.readFileSync(path.join(__dirname, '..', 'popup.js'), 'utf8');

// --- popup.html: the locked panel is only the key, title, subtitle and Unlock. ---
const start = html.indexOf('<section id="locked-panel"');
assert.ok(start >= 0, 'locked panel exists');
const block = html.slice(start, html.indexOf('</section>', start));
assert.ok(block.includes('id="locked-unlock-btn"'), 'unlock button present');
assert.ok(!block.includes('locked-retry-btn'), 'no retry button');
assert.ok(!/<input/i.test(block), 'no input in locked panel');
assert.ok(!/<svg/i.test(block), 'no svg (gear) in locked panel');
assert.ok(!/settings/i.test(block), 'no settings text in locked panel');
assert.ok(!/id="locked-unlock-btn"[^>]*\bhidden\b/.test(block), 'unlock button always visible');

assert.ok(!source.includes('lockedRetryBtn'), 'popup.js no longer binds a retry button');

// --- Fake DOM harness (same style as popup-fallback.test.js). ---
const elements = {};
function makeEl(id) {
  const el = {
    id, hidden: false, textContent: '', innerHTML: '', value: '', onclick: null,
    className: '', style: {}, children: [], disabled: false,
    appendChild(child) { this.children.push(child); },
    addEventListener() {},
    setAttribute(name, value) { this[name] = value; }
  };
  elements[id] = el;
  return el;
}
global.document = {
  getElementById: (id) => elements[id] || makeEl(id),
  createElement: (tag) => makeEl(tag)
};
global.addEventListener = () => {};
global.window = global;

// Fake timers: record registrations so leaks are observable.
const intervals = [];
const cleared = [];
global.setInterval = (fn, delay) => { const h = { fn, delay }; intervals.push(h); return h; };
global.clearInterval = (h) => { cleared.push(h); };

global.chrome = {
  storage: {
    local: { get: (_k, cb) => cb({}), set: (_i, cb) => cb && cb(), remove: (_k, cb) => cb && cb() },
    session: null
  },
  runtime: {
    sendMessage: (msg, cb) => {
      if (msg && msg.type === 'getCredentials') { cb({ type: 'locked' }); return; }
      if (cb) cb({ type: 'passkeyProxyStatus', unlocked: true, paired: true, attachAllowed: false });
    }
  },
  tabs: { query: (_o, cb) => cb([{ url: 'https://example.com' }]) }
};

const popup = require('../popup.js');
const {
  LOCKED_TITLE_TEXT, LOCKED_HELPER_TEXT, UNLOCK_BUTTON_LABEL,
  LOCKED_POLL_INTERVAL_MS, startLockedPolling, stopLockedPolling
} = popup;

assert.strictEqual(LOCKED_TITLE_TEXT, 'MyPass is locked');
assert.strictEqual(LOCKED_HELPER_TEXT, 'Open MyPass and unlock the vault');
assert.strictEqual(UNLOCK_BUTTON_LABEL, 'Unlock MyPass');
assert.strictEqual(LOCKED_POLL_INTERVAL_MS, 2000);

// The popup init already presented the locked panel (getCredentials -> locked).
assert.strictEqual(elements['locked-panel'].hidden, false, 'locked panel shown');
assert.strictEqual(elements['add-totp-section'].hidden, true, 'add-totp hidden when locked');
const afterInit = intervals.length;
assert.strictEqual(afterInit, 1, 'showing the locked panel registers one poll');
assert.strictEqual(intervals[0].delay, 2000);

// Repeated starts do not stack timers.
let calls = 0;
startLockedPolling(() => { calls += 1; });
startLockedPolling(() => { calls += 1; });
assert.strictEqual(intervals.length, afterInit, 'start is a no-op while running');

stopLockedPolling();
assert.strictEqual(cleared.length, 1, 'stop clears the single timer');
stopLockedPolling();
assert.strictEqual(cleared.length, 1, 'stop when idle does not clear again');

startLockedPolling(() => { calls += 1; });
assert.strictEqual(intervals.length, afterInit + 1, 'start after stop registers a new timer');
intervals[intervals.length - 1].fn();
assert.strictEqual(calls, 1, 'tick invokes reload');
stopLockedPolling();

console.log('lockedPopup.test.js passed');
