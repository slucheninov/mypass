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
    addEventListener(type, handler) {
      this._listeners = this._listeners || {};
      this._listeners[type] = handler;
    },
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
  'add-totp-section',
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
    // Popup init also fires getPasskeyProxyStatus (answered generically below) and the
    // fire-and-forget refreshPasskeyProxy (no callback at all) — only getCredentials
    // calls are counted here, matching popup-fallback.test.js's stub shape.
    sendMessage: (msg, cb) => {
      if (!msg || msg.type !== 'getCredentials') {
        if (cb) cb({ type: 'passkeyProxyStatus', unlocked: true, paired: true, attachAllowed: false, enabled: false });
        return;
      }
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
    query: (_opts, cb) => cb([{ id: 1, url: 'https://example.com' }])
    // sendMessage is intentionally absent at module-load time: requestPageTotpCandidate
    // guards on `typeof chrome.tabs.sendMessage !== 'function'` so popup init doesn't
    // crash on it, and every test below installs its own stub before calling it directly.
  }
};

const {
  validateTotpPasteInput,
  isBase32PasteSecret,
  renderTotpPicker,
  routeTotpCandidate,
  restorePendingTotpCandidate,
  handleAddTotpClick,
  requestPageTotpCandidate
} = require('../popup.js');

// --- additive: the Add-2FA section (popup.html's `#add-totp-section`) must start
// hidden — it only appears once there is an actual 2FA candidate in context. ---
assert.strictEqual(elements['add-totp-section'].hidden, true, 'Add 2FA section starts hidden');
console.log('totpPicker.test.js: add-totp-section hidden by default OK');

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

// --- additive: a picker row click reports the actual proposeSaveTotp outcome instead of
// always claiming success (Finding 3). ---
(() => {
  global.chrome.runtime.sendMessage = (msg, cb) => { if (cb) cb({ type: 'locked' }); };
  elements.list.children = [];
  elements['add-totp-error'].hidden = true;
  elements['add-totp-error'].textContent = '';

  renderTotpPicker([{ id: 'a', title: 'Alpha', hasTotp: false }], 'https://example.com', 'JBSWY3DP');
  elements.list.children[0]._listeners.click();

  assert.strictEqual(elements['add-totp-error'].hidden, false, 'error shown on locked outcome');
  assert.strictEqual(elements['add-totp-error'].textContent, 'Unlock MyPass first');

  console.log('totpPicker.test.js: picker row click reports locked outcome OK');
})();

(() => {
  global.chrome.runtime.sendMessage = (msg, cb) => { if (cb) cb({ type: 'saveProposalAccepted' }); };
  elements.list.children = [];
  elements['add-totp-error'].hidden = true;
  elements['add-totp-error'].textContent = '';

  renderTotpPicker([{ id: 'a', title: 'Alpha', hasTotp: false }], 'https://example.com', 'JBSWY3DP');
  elements.list.children[0]._listeners.click();

  assert.strictEqual(elements['add-totp-error'].hidden, false);
  assert.strictEqual(elements['add-totp-error'].textContent, 'Opened in MyPass');

  console.log('totpPicker.test.js: picker row click reports success outcome OK');
})();

// --- additive: restorePendingTotpCandidate is sequenced after the primary
// getCredentials flow, not raced against it — it now takes the primary flow's
// classified response kind and only acts when that kind is 'credentialList'
// (vault unlocked and paired for the *current* tab). ---

// (b) primary=credentialList + pending candidate with >1 matches for the pending URL:
// prefills the input, renders the picker, and removes the stored key.
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
  elements['add-totp-section'].hidden = true;

  restorePendingTotpCandidate('credentialList');

  assert.strictEqual(elements['totp-paste-input'].value, 'JBSWY3DPEHPK3PXP', 'restores pasted secret into input');
  assert.strictEqual(elements.list.children.length, 2, 'multi-match pending candidate renders picker rows');
  assert.deepStrictEqual(removedKeys, ['pendingTotpCandidate'], 'pending candidate cleared after restore');
  assert.strictEqual(elements['add-totp-section'].hidden, false, 'restore proceed path unhides the Add 2FA section');

  console.log('totpPicker.test.js: restorePendingTotpCandidate(credentialList) multi-match OK');
})();

// (b2) primary=credentialList, but the inner re-check getCredentials for the *pending*
// URL comes back locked (vault re-locked mid-flight): must not render a picker and must
// NOT remove the stored key — same "never drop a pending candidate on anything but a
// confirmed credentialList response" rule as the outer locked-path semantics (Finding 5).
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
    cb({ type: 'locked' });
  };
  elements.list.children = [];
  elements['add-totp-section'].hidden = true;

  restorePendingTotpCandidate('credentialList');

  assert.strictEqual(elements.list.children.length, 0, 'no picker rendered when the inner re-check is locked');
  assert.strictEqual(removedKeys, null, 'candidate key is kept when the vault re-locks mid-flight');
  assert.strictEqual(
    elements['add-totp-section'].hidden,
    false,
    'section still unhides on the prefill step, even though the inner re-check later found the vault locked'
  );

  console.log('totpPicker.test.js: restorePendingTotpCandidate keeps key when inner re-check is locked OK');
})();

// (a) primary=locked: must not prefill, must not render a picker, and must NOT remove
// the stored candidate — it has to survive to the next popup open after unlock.
(() => {
  let removeCalled = false;
  global.chrome.storage.local.get = (_keys, cb) => {
    cb({ pendingTotpCandidate: { url: 'https://pending.example.com', otpauthOrSecret: 'JBSWY3DPEHPK3PXP' } });
  };
  global.chrome.storage.local.remove = (_keys, cb) => {
    removeCalled = true;
    if (cb) cb();
  };
  let sendMessageCalled = false;
  global.chrome.runtime.sendMessage = () => { sendMessageCalled = true; };
  elements.list.children = [];
  elements['totp-paste-input'].value = '';
  elements['add-totp-section'].hidden = true;

  restorePendingTotpCandidate('locked');

  assert.strictEqual(elements['totp-paste-input'].value, '', 'locked primary flow does not prefill the input');
  assert.strictEqual(elements.list.children.length, 0, 'locked primary flow does not render a picker');
  assert.strictEqual(sendMessageCalled, false, 'locked primary flow does not re-check getCredentials for the pending URL');
  assert.strictEqual(removeCalled, false, 'locked primary flow leaves the stored candidate in place');
  assert.strictEqual(elements['add-totp-section'].hidden, true, 'locked primary flow leaves the Add 2FA section hidden');

  console.log('totpPicker.test.js: restorePendingTotpCandidate(locked) leaves candidate untouched OK');
})();

// Same gating for pairingRequired and error primary kinds — the candidate must survive.
['pairingRequired', 'error'].forEach((primaryKind) => {
  let removeCalled = false;
  global.chrome.storage.local.get = (_keys, cb) => {
    cb({ pendingTotpCandidate: { url: 'https://pending.example.com', otpauthOrSecret: 'JBSWY3DPEHPK3PXP' } });
  };
  global.chrome.storage.local.remove = (_keys, cb) => {
    removeCalled = true;
    if (cb) cb();
  };
  global.chrome.runtime.sendMessage = () => {};

  restorePendingTotpCandidate(primaryKind);

  assert.strictEqual(removeCalled, false, `${primaryKind} primary flow leaves the stored candidate in place`);
});
console.log('totpPicker.test.js: restorePendingTotpCandidate(pairingRequired/error) leaves candidate untouched OK');

// --- additive: restorePendingTotpCandidate is a no-op when nothing is pending. ---
(() => {
  global.chrome.storage.local.get = (_keys, cb) => cb({});
  let sendMessageCalled = false;
  global.chrome.runtime.sendMessage = () => { sendMessageCalled = true; };

  restorePendingTotpCandidate('credentialList');

  assert.strictEqual(sendMessageCalled, false, 'no pending candidate means no getCredentials lookup');

  console.log('totpPicker.test.js: restorePendingTotpCandidate no-op when nothing pending OK');
})();

// --- additive: handleAddTotpClick must never fire a blind proposeSaveTotp when the
// vault is locked or unpaired — same trust model as the password-save flow (Global
// Constraints: pairing secret required, vault must be unlocked). ---
(() => {
  elements['totp-paste-input'].value = 'JBSWY3DPEHPK3PXP';
  elements['add-totp-error'].hidden = true;
  elements['add-totp-error'].textContent = '';
  let sentMessage = null;
  global.chrome.runtime.sendMessage = (msg, cb) => {
    if (msg.type === 'proposeSaveTotp') sentMessage = msg;
    if (msg.type === 'getCredentials') cb({ type: 'locked' });
  };

  handleAddTotpClick('https://example.com');

  assert.strictEqual(sentMessage, null, 'locked vault must not trigger proposeSaveTotp');
  assert.strictEqual(elements['add-totp-error'].hidden, false, 'error shown when locked');
  assert.strictEqual(elements['add-totp-error'].textContent, 'Unlock MyPass first');

  console.log('totpPicker.test.js: handleAddTotpClick locked gate OK');
})();

(() => {
  elements['totp-paste-input'].value = 'JBSWY3DPEHPK3PXP';
  elements['add-totp-error'].hidden = true;
  elements['add-totp-error'].textContent = '';
  let sentMessage = null;
  global.chrome.runtime.sendMessage = (msg, cb) => {
    if (msg.type === 'proposeSaveTotp') sentMessage = msg;
    if (msg.type === 'getCredentials') cb({ type: 'pairingRequired' });
  };

  handleAddTotpClick('https://example.com');

  assert.strictEqual(sentMessage, null, 'unpaired browser must not trigger proposeSaveTotp');
  assert.strictEqual(elements['add-totp-error'].hidden, false, 'error shown when pairing required');
  assert.strictEqual(elements['add-totp-error'].textContent, 'Connect to MyPass first');

  console.log('totpPicker.test.js: handleAddTotpClick pairingRequired gate OK');
})();

// --- additive: any other non-credentialList response (error / undefined / unreachable
// native host) must also not fire a blind proposeSaveTotp. ---
(() => {
  elements['totp-paste-input'].value = 'JBSWY3DPEHPK3PXP';
  elements['add-totp-error'].hidden = true;
  elements['add-totp-error'].textContent = '';
  let sentMessage = null;
  global.chrome.runtime.sendMessage = (msg, cb) => {
    if (msg.type === 'proposeSaveTotp') sentMessage = msg;
    if (msg.type === 'getCredentials') cb({ type: 'error', message: 'native_host_not_found' });
  };

  handleAddTotpClick('https://example.com');

  assert.strictEqual(sentMessage, null, 'unreachable MyPass must not trigger proposeSaveTotp');
  assert.strictEqual(elements['add-totp-error'].hidden, false, 'error shown when unreachable');
  assert.strictEqual(elements['add-totp-error'].textContent, "Couldn't reach MyPass");

  console.log('totpPicker.test.js: handleAddTotpClick unreachable-host gate OK');
})();

// --- additive: a real credentialList response still proceeds to routeTotpCandidate. ---
(() => {
  elements['totp-paste-input'].value = 'JBSWY3DPEHPK3PXP';
  elements['add-totp-error'].hidden = true;
  elements['add-totp-error'].textContent = '';
  let sentMessage = null;
  global.chrome.runtime.sendMessage = (msg, cb) => {
    if (msg.type === 'proposeSaveTotp') sentMessage = msg;
    if (msg.type === 'getCredentials') {
      cb({ type: 'credentialList', credentials: [{ id: 'entry-1', title: 'Example', hasTotp: false }] });
    }
  };

  handleAddTotpClick('https://example.com');

  assert.strictEqual(sentMessage && sentMessage.type, 'proposeSaveTotp', 'unlocked+paired single match still proposes a save');
  assert.strictEqual(sentMessage.entryId, 'entry-1');

  console.log('totpPicker.test.js: handleAddTotpClick credentialList proceeds OK');
})();

// --- additive: requestPageTotpCandidate gates the Add-2FA section's visibility on
// whether the active tab's content script actually reports a 2FA candidate. ---

// A page candidate response unhides the section and prefills the paste input.
(() => {
  elements['add-totp-section'].hidden = true;
  elements['totp-paste-input'].value = '';
  global.chrome.runtime.lastError = undefined;
  global.chrome.tabs.sendMessage = (tabId, msg, cb) => {
    assert.strictEqual(tabId, 7);
    assert.strictEqual(msg.type, 'queryTotpCandidate');
    cb({ candidate: 'otpauth://totp/Example:alice?secret=JBSWY3DP', priority: 1 });
  };

  requestPageTotpCandidate(7);

  assert.strictEqual(elements['add-totp-section'].hidden, false, 'candidate found unhides the Add 2FA section');
  assert.strictEqual(
    elements['totp-paste-input'].value,
    'otpauth://totp/Example:alice?secret=JBSWY3DP',
    'candidate prefills the paste input'
  );

  console.log('totpPicker.test.js: requestPageTotpCandidate candidate found OK');
})();

// chrome.runtime.lastError (no content script — e.g. a chrome:// page) must not un-hide
// the section, and must not throw/log despite the callback firing with no response.
(() => {
  elements['add-totp-section'].hidden = true;
  elements['totp-paste-input'].value = '';
  global.chrome.tabs.sendMessage = (_tabId, _msg, cb) => {
    global.chrome.runtime.lastError = { message: 'Could not establish connection. Receiving end does not exist.' };
    cb(undefined);
  };

  requestPageTotpCandidate(7);

  assert.strictEqual(elements['add-totp-section'].hidden, true, 'lastError keeps the section hidden');
  global.chrome.runtime.lastError = undefined;

  console.log('totpPicker.test.js: requestPageTotpCandidate lastError stays hidden OK');
})();

// A null/no-candidate response (content script present, nothing detected on the page)
// also leaves the section hidden.
(() => {
  elements['add-totp-section'].hidden = true;
  global.chrome.tabs.sendMessage = (_tabId, _msg, cb) => { cb(null); };

  requestPageTotpCandidate(7);

  assert.strictEqual(elements['add-totp-section'].hidden, true, 'no candidate keeps the section hidden');

  console.log('totpPicker.test.js: requestPageTotpCandidate no-candidate stays hidden OK');
})();
