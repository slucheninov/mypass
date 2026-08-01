const assert = require('node:assert');
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

console.log('popup-fallback.test.js OK');
