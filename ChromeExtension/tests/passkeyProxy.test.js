const assert = require('node:assert');

// `chrome.storage.local`/`.session` are stubbed callback-style, matching both the real
// MV3 API surface background.js wraps and pairing.test.js's existing stub shape.
const localStore = { passkeyProxyEnabled: true };
let sessionStore = {};
const sentNativeMessages = [];
const alarms = {};
let nativeResponder = () => ({ type: 'passkeyProxyStatus', unlocked: true, paired: true, attachAllowed: true });

function makeArea(store) {
  return {
    get: (keys, cb) => {
      const result = {};
      for (const key of (Array.isArray(keys) ? keys : [keys])) {
        if (store[key] !== undefined) result[key] = store[key];
      }
      cb(result);
    },
    set: (items, cb) => {
      Object.assign(store, items);
      if (cb) cb();
    },
    remove: (keys, cb) => {
      for (const key of (Array.isArray(keys) ? keys : [keys])) delete store[key];
      if (cb) cb();
    }
  };
}

let attachCalled = false;
let detachCalled = false;
let completedCreate = null;
let completedGet = null;
let completedIsUvpaa = null;
let popupOpened = 0;
let notified = 0;
let openPopupResult = () => Promise.resolve();

global.chrome = {
  storage: { local: makeArea(localStore), session: makeArea(sessionStore) },
  runtime: {
    lastError: null,
    onMessage: { addListener: () => {} },
    sendNativeMessage: (_host, message, cb) => {
      sentNativeMessages.push(message);
      cb(nativeResponder(message));
    }
  },
  // The watchdog runs on chrome.alarms, not setTimeout — a setTimeout does not
  // survive service-worker termination.
  alarms: {
    create: (name, info) => { alarms[name] = info; },
    clear: (name) => { delete alarms[name]; },
    onAlarm: { addListener: () => {} }
  },
  webAuthenticationProxy: {
    attach: () => { attachCalled = true; return Promise.resolve(); },
    detach: () => { detachCalled = true; return Promise.resolve(); },
    onCreateRequest: { addListener: () => {} },
    onGetRequest: { addListener: () => {} },
    onIsUvpaaRequest: { addListener: () => {} },
    onRequestCanceled: { addListener: () => {} },
    completeCreateRequest: (details) => { completedCreate = details; },
    completeGetRequest: (details) => { completedGet = details; },
    completeIsUvpaaRequest: (details) => { completedIsUvpaa = details; }
  },
  action: { openPopup: () => { popupOpened += 1; return openPopupResult(); } },
  notifications: { create: () => { notified += 1; } },
  tabs: { query: (_opts, cb) => cb([{ url: 'https://example.com' }]) }
};

const {
  attachPasskeyProxyIfEligible,
  handlePasskeyRequest,
  completePasskeyRequest,
  passkeyNotAllowedError,
  originFromRequestDetails,
  readPending,
  writePending,
  clearPending,
  answerIsUvpaa,
  handleRuntimeMessage,
  knownTypes,
  PASSKEY_WATCHDOG_ALARM
} = require('../background.js');

function resetState() {
  sessionStore = {};
  global.chrome.storage.session = makeArea(sessionStore);
  for (const key of Object.keys(alarms)) delete alarms[key];
  sentNativeMessages.length = 0;
  attachCalled = false;
  detachCalled = false;
  completedCreate = null;
  completedGet = null;
  completedIsUvpaa = null;
  popupOpened = 0;
  notified = 0;
  localStore.passkeyProxyEnabled = true;
  openPopupResult = () => Promise.resolve();
  nativeResponder = () => ({ type: 'passkeyProxyStatus', unlocked: true, paired: true, attachAllowed: true });
}

assert.deepStrictEqual(passkeyNotAllowedError('x'), { name: 'NotAllowedError', message: 'x' });
console.log('passkeyProxy.test.js: passkeyNotAllowedError OK');

// The origin is authoritative from the payload, never guessed from the active tab —
// a ceremony can start in a background tab, and originUrl feeds the app's domain gate.
assert.strictEqual(
  originFromRequestDetails(JSON.stringify({
    challenge: 'AA',
    extensions: { remoteDesktopClientOverride: { origin: 'https://example.com' } }
  })),
  'https://example.com'
);
assert.strictEqual(originFromRequestDetails('{"challenge":"AA"}'), null, 'missing override must fail closed');
assert.strictEqual(originFromRequestDetails('not json'), null, 'unparseable payload must fail closed');
console.log('passkeyProxy.test.js: originFromRequestDetails OK');

assert.ok(knownTypes.includes('getPasskeyProxyStatus'));
assert.ok(knownTypes.includes('setPasskeyProxyEnabled'));
assert.ok(knownTypes.includes('passkeyCreateConfirm'));
assert.ok(knownTypes.includes('passkeyGetApprove'));
console.log('passkeyProxy.test.js: knownTypes includes the passkey relays OK');

const detailsFor = (origin) => JSON.stringify({
  challenge: 'AA',
  rp: { id: 'example.com', name: 'Example' },
  extensions: { remoteDesktopClientOverride: { origin } }
});

(async () => {
  // --- attach gating -------------------------------------------------------
  resetState();
  await attachPasskeyProxyIfEligible();
  assert.strictEqual(attachCalled, true, 'attach() called when setting enabled and status allows it');
  console.log('passkeyProxy.test.js: attachPasskeyProxyIfEligible attaches when eligible OK');

  resetState();
  localStore.passkeyProxyEnabled = false;
  await attachPasskeyProxyIfEligible();
  assert.strictEqual(attachCalled, false, 'attach() not called when setting disabled');
  assert.strictEqual(sentNativeMessages.length, 0, 'a disabled proxy must not even ask the app for status');
  console.log('passkeyProxy.test.js: attachPasskeyProxyIfEligible skips when disabled OK');

  resetState();
  nativeResponder = () => ({ type: 'passkeyProxyStatus', unlocked: false, paired: true, attachAllowed: false });
  await attachPasskeyProxyIfEligible();
  assert.strictEqual(attachCalled, false, 'attach() not called when status.attachAllowed is false (locked)');
  console.log('passkeyProxy.test.js: attachPasskeyProxyIfEligible skips when locked OK');

  // sendNativeMessage resolves an {type:"error"} envelope rather than rejecting when
  // the host is unreachable, so the guard has to test the envelope, not just catch.
  resetState();
  nativeResponder = () => ({ type: 'error', message: 'app_not_running' });
  await attachPasskeyProxyIfEligible();
  assert.strictEqual(attachCalled, false, 'attach() not called when MyPass is not running');
  console.log('passkeyProxy.test.js: attachPasskeyProxyIfEligible skips when app unavailable OK');

  // --- ceremony relay ------------------------------------------------------
  resetState();
  nativeResponder = (msg) => (msg.type === 'passkeyCreate'
    ? { type: 'passkeyCreatePending', requestId: 1, rpId: 'example.com', rpName: 'Example', matches: [] }
    : null);
  await handlePasskeyRequest('create', 1, detailsFor('https://example.com'));
  assert.strictEqual(completedCreate, null, 'pending response must not auto-complete the ceremony');
  const pending = await readPending();
  assert.strictEqual(pending.requestId, 1);
  assert.strictEqual(pending.kind, 'create');
  assert.strictEqual(pending.originUrl, 'https://example.com');
  assert.ok(alarms[PASSKEY_WATCHDOG_ALARM], 'watchdog alarm must be armed while a ceremony is pending');
  assert.strictEqual(popupOpened, 1, 'the confirm popup must open');
  console.log('passkeyProxy.test.js: handlePasskeyRequest pending does not auto-complete OK');

  await completePasskeyRequest('create', { requestId: 1, responseJson: '{}' });
  assert.deepStrictEqual(completedCreate, { requestId: 1, responseJson: '{}' });
  console.log('passkeyProxy.test.js: completePasskeyRequest calls completeCreateRequest OK');

  // A second concurrent ceremony is rejected outright, and must not disturb the first's
  // bookkeeping — the pending record still belongs to requestId 1.
  resetState();
  await writePending({ kind: 'create', requestId: 1, originUrl: 'https://example.com', rpId: 'example.com', matches: [] });
  await handlePasskeyRequest('get', 2, detailsFor('https://example.com'));
  assert.strictEqual(completedGet.requestId, 2);
  assert.strictEqual(completedGet.error.name, 'AbortError');
  assert.strictEqual((await readPending()).requestId, 1, 'rejecting a second ceremony must not clear the first');
  console.log('passkeyProxy.test.js: second concurrent ceremony rejected with AbortError OK');

  // Fail closed when the payload carries no trustworthy origin.
  resetState();
  await handlePasskeyRequest('create', 3, '{"challenge":"AA"}');
  assert.strictEqual(completedCreate.error.name, 'NotAllowedError');
  assert.strictEqual(await readPending(), null);
  assert.strictEqual(sentNativeMessages.length, 0, 'nothing may be sent to the app without an origin');
  console.log('passkeyProxy.test.js: missing origin fails closed OK');

  // `locked` is the most likely real-world reply and must complete the ceremony rather
  // than fall through and hang the page until Chrome's own 180 s timeout.
  for (const [replyType, fragment] of [['locked', 'locked'], ['pairingRequired', 'not paired'], ['error', 'unavailable']]) {
    resetState();
    nativeResponder = () => ({ type: replyType, message: 'app_not_running' });
    await handlePasskeyRequest('get', 4, detailsFor('https://example.com'));
    assert.strictEqual(completedGet.requestId, 4, `${replyType} must complete the ceremony`);
    assert.strictEqual(completedGet.error.name, 'NotAllowedError');
    assert.ok(
      completedGet.error.message.includes(fragment),
      `${replyType} message should explain the cause, got "${completedGet.error.message}"`
    );
    assert.strictEqual(await readPending(), null, `${replyType} must leave no pending record`);
    assert.strictEqual(alarms[PASSKEY_WATCHDOG_ALARM], undefined, `${replyType} must not arm the watchdog`);
  }
  console.log('passkeyProxy.test.js: locked / pairingRequired / error all complete the ceremony OK');

  // An app-side error envelope on the ceremony itself is forwarded verbatim, since
  // PasskeyErrorDetails already mirrors Chrome's DOMExceptionDetails shape.
  resetState();
  nativeResponder = () => ({
    type: 'passkeyCreateComplete',
    requestId: 5,
    error: { name: 'NotSupportedError', message: 'MyPass passkeys require ES256' }
  });
  await handlePasskeyRequest('create', 5, detailsFor('https://example.com'));
  assert.deepStrictEqual(completedCreate.error, { name: 'NotSupportedError', message: 'MyPass passkeys require ES256' });
  console.log('passkeyProxy.test.js: app error details forwarded verbatim OK');

  // --- completion bookkeeping ---------------------------------------------
  resetState();
  await writePending({ kind: 'create', requestId: 1, originUrl: 'https://example.com', rpId: 'example.com', matches: [] });
  await completePasskeyRequest('create', { requestId: 99, error: passkeyNotAllowedError('other') });
  assert.strictEqual((await readPending()).requestId, 1, 'completing a different requestId must not clear the pending record');
  await completePasskeyRequest('create', { requestId: 1, responseJson: '{}' });
  assert.strictEqual(await readPending(), null);
  assert.strictEqual(alarms[PASSKEY_WATCHDOG_ALARM], undefined, 'completing must disarm the watchdog');
  console.log('passkeyProxy.test.js: completePasskeyRequest clears only its own record OK');

  // --- isUvpaa ------------------------------------------------------------
  // Every isUvpaa request MUST be answered; an early return leaves Chrome waiting.
  resetState();
  localStore.passkeyProxyEnabled = false;
  await answerIsUvpaa(11);
  assert.deepStrictEqual(completedIsUvpaa, { requestId: 11, isUvpaa: false }, 'disabled proxy must still answer');
  console.log('passkeyProxy.test.js: isUvpaa answered false when disabled OK');

  resetState();
  await answerIsUvpaa(12);
  assert.deepStrictEqual(completedIsUvpaa, { requestId: 12, isUvpaa: true });

  resetState();
  nativeResponder = () => ({ type: 'passkeyProxyStatus', unlocked: false, paired: true, attachAllowed: false });
  await answerIsUvpaa(13);
  assert.deepStrictEqual(completedIsUvpaa, { requestId: 13, isUvpaa: false }, 'attached-but-locked must answer false');

  // Unlocked but turned off app-side: attachAllowed is the authority, not `unlocked`.
  resetState();
  nativeResponder = () => ({ type: 'passkeyProxyStatus', unlocked: true, paired: true, attachAllowed: false });
  await answerIsUvpaa(14);
  assert.deepStrictEqual(completedIsUvpaa, { requestId: 14, isUvpaa: false });

  resetState();
  nativeResponder = () => ({ type: 'error', message: 'app_not_running' });
  await answerIsUvpaa(15);
  assert.deepStrictEqual(completedIsUvpaa, { requestId: 15, isUvpaa: false }, 'an unreachable app must still answer');
  console.log('passkeyProxy.test.js: isUvpaa reflects attach eligibility OK');

  // --- popup-driven confirm / cancel --------------------------------------
  resetState();
  await writePending({ kind: 'create', requestId: 7, originUrl: 'https://example.com', rpId: 'example.com', matches: [] });
  nativeResponder = () => ({ type: 'passkeyCreateComplete', requestId: 7, responseJson: '{"id":"abc"}' });
  await new Promise((resolve) => {
    handleRuntimeMessage({ type: 'passkeyCreateConfirm', requestId: 7, entryId: 'e1', replace: false }, {}, resolve);
  });
  assert.deepStrictEqual(completedCreate, { requestId: 7, responseJson: '{"id":"abc"}', error: undefined });
  assert.strictEqual(await readPending(), null);
  console.log('passkeyProxy.test.js: passkeyCreateConfirm completes the ceremony OK');

  resetState();
  await writePending({ kind: 'get', requestId: 8, originUrl: 'https://example.com', rpId: 'example.com', matches: [] });
  nativeResponder = () => ({ type: 'passkeyCancelled', requestId: 8 });
  await new Promise((resolve) => {
    handleRuntimeMessage({ type: 'passkeyCancelUI', requestId: 8 }, {}, resolve);
  });
  assert.strictEqual(completedGet.error.name, 'NotAllowedError', 'cancel must complete the get ceremony, not the create one');
  assert.strictEqual(await readPending(), null);
  console.log('passkeyProxy.test.js: passkeyCancelUI cancels the pending ceremony kind OK');

  // --- settings toggle -----------------------------------------------------
  resetState();
  localStore.passkeyProxyEnabled = false;
  nativeResponder = (msg) => (msg.type === 'setPasskeyProxyEnabled'
    ? { type: 'passkeyProxyEnabled', enabled: true }
    : { type: 'passkeyProxyStatus', unlocked: true, paired: true, attachAllowed: true });
  await new Promise((resolve) => {
    handleRuntimeMessage({ type: 'setPasskeyProxyEnabled', enabled: true }, {}, resolve);
  });
  assert.strictEqual(localStore.passkeyProxyEnabled, true, 'the toggle must persist locally too');
  assert.strictEqual(attachCalled, true, 'enabling attaches');

  resetState();
  nativeResponder = () => ({ type: 'passkeyProxyEnabled', enabled: false });
  await new Promise((resolve) => {
    handleRuntimeMessage({ type: 'setPasskeyProxyEnabled', enabled: false }, {}, resolve);
  });
  assert.strictEqual(localStore.passkeyProxyEnabled, false);
  assert.strictEqual(detachCalled, true, 'disabling detaches');
  console.log('passkeyProxy.test.js: setPasskeyProxyEnabled persists and attaches/detaches OK');

  // --- popup fallback ------------------------------------------------------
  resetState();
  openPopupResult = () => Promise.reject(new Error('kOpenPopupInactiveWindow'));
  nativeResponder = () => ({ type: 'passkeyGetPending', requestId: 9, rpId: 'example.com', matches: [] });
  await handlePasskeyRequest('get', 9, detailsFor('https://example.com'));
  await new Promise((resolve) => setTimeout(resolve, 0));
  assert.strictEqual(notified, 1, 'a backgrounded Chrome falls back to a notification');
  assert.strictEqual((await readPending()).requestId, 9, 'the ceremony stays pending behind the notification');
  console.log('passkeyProxy.test.js: openPopup rejection falls back to a notification OK');

  console.log('passkeyProxy.test.js OK');
})().catch((error) => {
  console.error(error);
  process.exit(1);
});
