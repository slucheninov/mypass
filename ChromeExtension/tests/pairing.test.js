const assert = require('node:assert');

const storage = {};
const sentNativeMessages = [];
global.chrome = {
  storage: {
    local: {
      get: (keys, cb) => {
        const result = {};
        for (const key of (Array.isArray(keys) ? keys : [keys])) {
          if (storage[key] !== undefined) result[key] = storage[key];
        }
        cb(result);
      },
      set: (items, cb) => {
        Object.assign(storage, items);
        if (cb) cb();
      },
      remove: (keys, cb) => {
        for (const key of (Array.isArray(keys) ? keys : [keys])) delete storage[key];
        if (cb) cb();
      }
    }
  },
  runtime: {
    lastError: null,
    onMessage: { addListener: () => {} },
    sendNativeMessage: (_host, message, cb) => {
      sentNativeMessages.push(message);
      cb({ type: 'paired', secret: 'newSecret' });
    }
  }
};

const {
  PAIRING_STORAGE_KEY,
  attachPairingField,
  persistPairingResponse,
  clearStaleSecretOnPairingRequired,
  detectBrowserName,
  sendPairingCompletion
} = require('../background.js');

const { classifyGetCredentialsResponse } = require('../popup.js');

assert.strictEqual(classifyGetCredentialsResponse(null), 'error');
assert.strictEqual(classifyGetCredentialsResponse({ type: 'error', message: 'x' }), 'error');
assert.strictEqual(classifyGetCredentialsResponse({ type: 'locked' }), 'locked');
assert.strictEqual(classifyGetCredentialsResponse({ type: 'pairingRequired' }), 'pairingRequired');
assert.strictEqual(classifyGetCredentialsResponse({ type: 'credentialList', credentials: [] }), 'credentialList');
assert.strictEqual(classifyGetCredentialsResponse({ type: 'unexpected' }), 'unknown');

assert.strictEqual(attachPairingField({ type: 'getCredentials', url: 'https://example.com' }, 'sec').pairing, 'sec');
assert.strictEqual(attachPairingField({ type: 'getCredentials', url: 'https://example.com' }, null).pairing, undefined);

delete global.navigator;
global.navigator = {
  userAgentData: {
    brands: [
      { brand: 'Google Chrome' },
      { brand: 'Chromium' },
      { brand: 'Not.A/Brand' }
    ]
  }
};
assert.strictEqual(detectBrowserName(), 'Google Chrome');

delete global.navigator.userAgentData;
assert.strictEqual(detectBrowserName(), 'Chromium browser');

(async () => {
  await persistPairingResponse({ type: 'paired', secret: 'YWJj' });
  assert.strictEqual(storage[PAIRING_STORAGE_KEY], 'YWJj');
  storage[PAIRING_STORAGE_KEY] = 'stale';
  await clearStaleSecretOnPairingRequired({ type: 'pairingRequired' }, 'stale');
  assert.strictEqual(storage[PAIRING_STORAGE_KEY], undefined);

  storage[PAIRING_STORAGE_KEY] = 'stale';
  sentNativeMessages.length = 0;
  await sendPairingCompletion({ type: 'completePairing', code: '123456' });
  assert.strictEqual(sentNativeMessages.length, 1);
  assert.strictEqual(sentNativeMessages[0].type, 'completePairing');
  assert.strictEqual(sentNativeMessages[0].code, '123456');
  assert.strictEqual(sentNativeMessages[0].pairing, undefined);
  assert.strictEqual(storage[PAIRING_STORAGE_KEY], 'newSecret');

  console.log('pairing.test.js OK');
})();
