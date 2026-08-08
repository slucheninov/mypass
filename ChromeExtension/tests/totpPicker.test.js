const assert = require('node:assert');

// --- copied from popup-fallback.test.js: exact global.document / global.chrome stub
// setup so `require('../popup.js')` runs its top-level DOM-wiring code without throwing. ---

const elements = {};
function makeEl(id) {
  const el = {
    id,
    hidden: false,
    textContent: '',
    innerHTML: '',
    value: '',
    onclick: null,
    className: '',
    style: {},
    children: [],
    appendChild(child) {
      this.children.push(child);
    },
    addEventListener() {},
    setAttribute(name, value) {
      this[name] = value;
    }
  };
  elements[id] = el;
  return el;
}

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
  'pairing-error',
  'add-totp-btn',
  'totp-paste-input',
  'add-totp-error'
].forEach((id) => makeEl(id));

global.document = {
  getElementById: (id) => {
    if (!elements[id]) makeEl(id);
    return elements[id];
  },
  createElement: (tag) => makeEl(tag)
};

let sendMessageCall = 0;
global.chrome = {
  storage: {
    local: {
      get: (_keys, cb) => cb({}),
      set: (_items, cb) => cb && cb(),
      remove: (_keys, cb) => cb && cb()
    },
    session: null
  },
  runtime: {
    sendMessage: (_msg, cb) => {
      sendMessageCall += 1;
      if (sendMessageCall === 1) {
        cb({ type: 'error', message: 'native_host_not_found' });
        return;
      }
      if (sendMessageCall === 2) {
        cb({
          type: 'credentialList',
          credentials: [{ id: '1', title: 'Example', username: 'alice@example.com' }]
        });
      }
    }
  },
  tabs: {
    query: (_opts, cb) => cb([{ url: 'https://example.com' }])
  }
};

const {
  validateTotpPasteInput,
  isBase32PasteSecret,
  renderTotpPicker,
  routeTotpCandidate,
  restorePendingTotpCandidate
} = require('../popup.js');

assert.deepStrictEqual(
  validateTotpPasteInput('otpauth://totp/Example:alice?secret=JBSWY3DP'),
  { valid: true, value: 'otpauth://totp/Example:alice?secret=JBSWY3DP' }
);
assert.deepStrictEqual(validateTotpPasteInput('  JBSW Y3DP EHPK 3PXP  '), { valid: true, value: 'JBSWY3DPEHPK3PXP' });
assert.strictEqual(validateTotpPasteInput('not valid').valid, false);
assert.strictEqual(validateTotpPasteInput('').valid, false);
assert.strictEqual(isBase32PasteSecret('JBSWY3DPEHPK3PXP'), true);
assert.strictEqual(isBase32PasteSecret('short'), false);
console.log('totpPicker.test.js: paste validation OK');

(() => {
  let sentMessage = null;
  global.chrome.runtime.sendMessage = (msg, cb) => { sentMessage = msg; if (cb) cb({ type: 'saveProposalAccepted' }); };

  routeTotpCandidate('https://example.com', 'JBSWY3DP', []);
  assert.strictEqual(sentMessage.type, 'proposeSaveTotp');
  assert.strictEqual(sentMessage.entryId, undefined, 'zero matches sends no entryId');

  routeTotpCandidate('https://example.com', 'JBSWY3DP', [{ id: 'entry-1', title: 'Example', hasTotp: false }]);
  assert.strictEqual(sentMessage.entryId, 'entry-1', 'single match includes entryId');

  console.log('totpPicker.test.js: routeTotpCandidate routing OK');
})();

// --- additive: renderTotpPicker builds one row per credential and only tags
// hasTotp credentials with the 2FA badge. ---
(() => {
  elements.list.children = []; // this fake DOM's innerHTML='' does not clear .children

  renderTotpPicker(
    [
      { id: 'a', title: 'Alpha', hasTotp: true },
      { id: 'b', title: 'Bravo', hasTotp: false }
    ],
    'https://example.com',
    'JBSWY3DP'
  );

  assert.strictEqual(elements.list.children.length, 2, 'renders one row per credential');
  const alphaBadges = elements.list.children[0].children.filter((c) => c.className === 'totp-badge');
  const bravoBadges = elements.list.children[1].children.filter((c) => c.className === 'totp-badge');
  assert.strictEqual(alphaBadges.length, 1, 'hasTotp credential gets a 2FA badge');
  assert.strictEqual(bravoBadges.length, 0, 'credential without hasTotp has no badge');

  console.log('totpPicker.test.js: renderTotpPicker badge rendering OK');
})();

// --- additive: routeTotpCandidate falls through to renderTotpPicker (not a direct
// sendMessage) once there is more than one match. ---
(() => {
  let sentMessage = null;
  global.chrome.runtime.sendMessage = (msg, cb) => { sentMessage = msg; if (cb) cb({}); };
  elements.list.children = [];

  routeTotpCandidate('https://example.com', 'JBSWY3DP', [
    { id: 'entry-1', title: 'Example', hasTotp: false },
    { id: 'entry-2', title: 'Other', hasTotp: false }
  ]);

  assert.strictEqual(sentMessage, null, 'multi-match does not eagerly propose a save');
  assert.strictEqual(elements.list.children.length, 2, 'multi-match renders a picker row per credential');

  console.log('totpPicker.test.js: routeTotpCandidate multi-match delegates to renderTotpPicker OK');
})();

// --- additive: restorePendingTotpCandidate prefills the paste input, renders the
// picker when the re-checked match count is >1, and clears the stored candidate. ---
(() => {
  let removedKeys = null;
  global.chrome.storage.local.get = (_keys, cb) => {
    cb({ pendingTotpCandidate: { url: 'https://pending.example.com', otpauthOrSecret: 'JBSWY3DPEHPK3PXP' } });
  };
  global.chrome.storage.local.remove = (keys, cb) => {
    removedKeys = keys;
    if (cb) cb();
  };
  global.chrome.runtime.sendMessage = (_msg, cb) => {
    cb({
      type: 'credentialList',
      credentials: [
        { id: 'x', title: 'Xray', hasTotp: false },
        { id: 'y', title: 'Yankee', hasTotp: true }
      ]
    });
  };
  elements.list.children = [];
  elements['totp-paste-input'].value = '';

  restorePendingTotpCandidate();

  assert.strictEqual(elements['totp-paste-input'].value, 'JBSWY3DPEHPK3PXP', 'restores pasted secret into input');
  assert.strictEqual(elements.list.children.length, 2, 'multi-match pending candidate renders picker rows');
  assert.deepStrictEqual(removedKeys, ['pendingTotpCandidate'], 'pending candidate cleared after restore');

  console.log('totpPicker.test.js: restorePendingTotpCandidate multi-match OK');
})();

// --- additive: restorePendingTotpCandidate is a no-op when nothing is pending. ---
(() => {
  global.chrome.storage.local.get = (_keys, cb) => cb({});
  let sendMessageCalled = false;
  global.chrome.runtime.sendMessage = () => { sendMessageCalled = true; };

  restorePendingTotpCandidate();

  assert.strictEqual(sendMessageCalled, false, 'no pending candidate means no getCredentials lookup');

  console.log('totpPicker.test.js: restorePendingTotpCandidate no-op when nothing pending OK');
})();
