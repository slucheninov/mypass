const assert = require('node:assert');
const path = require('node:path');

// --- background.js: the allowlist gate --------------------------------------------

// background.js registers chrome.runtime.onMessage.addListener at module load time
// (top-level, unconditional — see pairing.test.js's identical stub), so even this
// first, read-only require of `knownTypes` needs a minimal global.chrome in place or
// node throws "chrome is not defined" before the array is ever inspected.
global.chrome = {
  runtime: {
    lastError: null,
    onMessage: { addListener: () => {} }
  }
};

const { knownTypes } = require(path.join(__dirname, '..', 'background.js'));
assert.ok(
  knownTypes.includes('generatePassword'),
  'generatePassword must be in the allowlist or the message is silently dropped before it ever reaches the native host'
);

// --- background.js: handleRuntimeMessage forwards it to the native host ------------

let sentNativeMessage = null;
global.chrome = {
  runtime: {
    lastError: null,
    id: 'test-extension-id',
    sendNativeMessage: (hostName, message, cb) => {
      sentNativeMessage = message;
      cb({ type: 'generatedPassword', password: 'Tr0ub4dor&3' });
    },
    onMessage: { addListener: () => {} }
  },
  storage: {
    local: {
      get: (_key, cb) => cb({}),
      set: (_obj, cb) => cb && cb(),
      remove: (_key, cb) => cb && cb()
    }
  }
};

delete require.cache[require.resolve(path.join(__dirname, '..', 'background.js'))];
const { handleRuntimeMessage } = require(path.join(__dirname, '..', 'background.js'));

// sendNativeMessageWithPairing (the generic-forwarding branch generatePassword falls
// through to) is async — it awaits readPairingSecret, sendNativeMessage,
// clearStaleSecretOnPairingRequired and persistPairingResponse in turn — so sendResponse
// fires on a later microtask even though every stubbed chrome callback above resolves
// synchronously. Wrap in a promise that resolves exactly when sendResponse runs, rather
// than asserting immediately after the synchronous call, so this doesn't race the chain.
(async () => {
  let responded = null;
  let keepChannelOpen;
  await new Promise((resolve) => {
    keepChannelOpen = handleRuntimeMessage(
      { type: 'generatePassword', domain: 'example.com' },
      { tab: undefined },
      (response) => { responded = response; resolve(); }
    );
  });
  assert.strictEqual(keepChannelOpen, true, 'the async response path must keep the message channel open');
  assert.ok(sentNativeMessage, 'generatePassword must be forwarded to the native host');
  assert.strictEqual(sentNativeMessage.type, 'generatePassword');
  assert.strictEqual(sentNativeMessage.domain, 'example.com');
  assert.deepStrictEqual(responded, { type: 'generatedPassword', password: 'Tr0ub4dor&3' });

  console.log('generatePassword.test.js: background.js allowlist + forwarding OK');
})();

// --- content.js: buildNewPasswordFieldQueryResponse ---------------------------------

const { buildNewPasswordFieldQueryResponse } = require(path.join(__dirname, '..', 'content.js'));

function fakeInput(attrs) {
  return {
    getAttribute(name) { return Object.prototype.hasOwnProperty.call(attrs, name) ? attrs[name] : null; },
    closest() { return null; },
    disabled: false,
    readOnly: false,
    offsetParent: {}
  };
}

function fakeRoot(inputs) {
  return {
    querySelectorAll(selector) {
      if (selector === 'input[type="password"]') return inputs.filter((i) => i.getAttribute('type') === 'password');
      return [];
    }
  };
}

{
  const loginOnly = fakeRoot([fakeInput({ type: 'password', autocomplete: 'current-password' })]);
  assert.deepStrictEqual(buildNewPasswordFieldQueryResponse(loginOnly), { hasNewPasswordField: false });
}

{
  const signup = fakeRoot([fakeInput({ type: 'password', autocomplete: 'new-password' })]);
  assert.deepStrictEqual(buildNewPasswordFieldQueryResponse(signup), { hasNewPasswordField: true });
}

console.log('generatePassword.test.js: buildNewPasswordFieldQueryResponse OK');
