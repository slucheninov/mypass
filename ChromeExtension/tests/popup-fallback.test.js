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
    children: [],
    appendChild(child) {
      this.children.push(child);
    },
    addEventListener() {}
  };
  elements[id] = el;
  return el;
}

[
  'status',
  'list',
  'pairing-panel',
  'connect-btn',
  'code-entry',
  'code-input',
  'submit-code-btn',
  'pairing-error',
  'app-unavailable-actions',
  'retry-btn',
  'open-mypass-btn',
  'open-mypass-helper'
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

const listEl = elements.list;
const retryBtn = elements['retry-btn'];
const appUnavailableActions = elements['app-unavailable-actions'];

assert.strictEqual(sendMessageCall, 1, 'initial load should query credentials once');
assert.strictEqual(listEl.hidden, true, 'list hidden while app-unavailable actions shown');
assert.strictEqual(appUnavailableActions.hidden, false, 'action row visible on error');

retryBtn.onclick();
assert.strictEqual(sendMessageCall, 2, 'retry should re-query credentials');
assert.strictEqual(listEl.hidden, false, 'list visible after leaving app-unavailable error state');
assert.strictEqual(appUnavailableActions.hidden, true, 'action row hidden after successful credentialList');
assert.strictEqual(listEl.children.length, 1, 'credential rendered in list');

console.log('popup-fallback.test.js OK');
