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

const { classifyGetCredentialsResponse, isPairingChallengeFresh, normalizePairingCode, PAIRING_CHALLENGE_TTL_MS } = require('../popup.js');

assert.strictEqual(classifyGetCredentialsResponse(null), 'error');
assert.strictEqual(classifyGetCredentialsResponse({ type: 'error', message: 'x' }), 'error');
assert.strictEqual(classifyGetCredentialsResponse({ type: 'locked' }), 'locked');
assert.strictEqual(classifyGetCredentialsResponse({ type: 'pairingRequired' }), 'pairingRequired');
assert.strictEqual(classifyGetCredentialsResponse({ type: 'credentialList', credentials: [] }), 'credentialList');
assert.strictEqual(classifyGetCredentialsResponse({ type: 'unexpected' }), 'unknown');

const now = 1_000_000;
assert.strictEqual(isPairingChallengeFresh(now - 60_000, now), true);
assert.strictEqual(isPairingChallengeFresh(now - PAIRING_CHALLENGE_TTL_MS, now), false);
assert.strictEqual(isPairingChallengeFresh(undefined, now), false);
assert.strictEqual(isPairingChallengeFresh(null, now), false);

assert.strictEqual(normalizePairingCode('123 456'), '123456');
assert.strictEqual(normalizePairingCode('1234567'), '123456');
assert.strictEqual(normalizePairingCode('12a3b4c'), '1234');

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

  {
    const { knownTypes } = require('../background.js');
    assert.ok(knownTypes.includes('getTotp'), 'getTotp must be a known routed message type');
    console.log('pairing.test.js: getTotp knownTypes OK');
  }

  console.log('pairing.test.js OK');
})();
