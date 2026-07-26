const assert = require('node:assert');

const storage = {};
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
    onMessage: { addListener: () => {} }
  }
};

const {
  PAIRING_STORAGE_KEY,
  attachPairingField,
  persistPairingResponse,
  clearStaleSecretOnPairingRequired,
  detectBrowserName
} = require('../background.js');

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
  console.log('pairing.test.js OK');
})();
