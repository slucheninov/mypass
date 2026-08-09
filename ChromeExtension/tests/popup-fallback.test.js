const assert = require('node:assert');

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
  'pairing-error'
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
    // Counts getCredentials only: popup init also fires getPasskeyProxyStatus for the
    // passkey settings toggle, which is not a credential lookup.
    sendMessage: (msg, cb) => {
      if (!msg || msg.type !== 'getCredentials') {
        if (cb) cb({ type: 'passkeyProxyStatus', unlocked: true, paired: true, attachAllowed: false });
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
    query: (_opts, cb) => cb([{ url: 'https://example.com' }])
  }
};

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

assert.strictEqual(LOCKED_TITLE_TEXT, 'MyPass is locked');
assert.strictEqual(LOCKED_HELPER_TEXT, 'Open MyPass and unlock the vault');
assert.strictEqual(EMPTY_LIST_TITLE_TEXT, 'No saved logins for this site');
assert.strictEqual(LIST_HEADER_TEXT, 'Select an entry to autofill:');
assert.strictEqual(PAIRING_PANEL_TITLE_TEXT, 'Connect browser extension');

const listEl = elements.list;
const retryBtn = elements['retry-btn'];

assert.strictEqual(sendMessageCall, 1, 'initial load should query credentials once');
assert.strictEqual(elements['app-unavailable-panel'].hidden, false, 'app-unavailable panel visible on error');
assert.strictEqual(elements['list-panel'].hidden, true, 'list panel hidden on error');

retryBtn.onclick();
assert.strictEqual(sendMessageCall, 2, 'retry should re-query credentials');
assert.strictEqual(elements['list-panel'].hidden, false, 'list panel visible after credentialList');
assert.strictEqual(elements['app-unavailable-panel'].hidden, true, 'app-unavailable panel hidden after success');
assert.strictEqual(listEl.children.length, 1, 'credential rendered in list');

console.log('popup-fallback.test.js OK');
