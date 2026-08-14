const assert = require('node:assert');

// Minimal chrome stub — background.js registers chrome.runtime.onMessage.addListener at
// module load time (top-level, not inside a conditional), so a global.chrome with at
// least that shape must exist before require(). chrome.webAuthenticationProxy is left
// undefined so the passkey-proxy listener block (guarded by a typeof check) is skipped.
const sentMessages = [];
const queriedTabs = [];
let activeTabQueryResult = [];
let nextSendMessageLastError = null;

global.chrome = {
  runtime: {
    lastError: null,
    onMessage: { addListener: () => {} }
  },
  tabs: {
    query: (opts, cb) => {
      queriedTabs.push(opts);
      cb(activeTabQueryResult);
    },
    // Real chrome.tabs.sendMessage is called either as (tabId, message, callback) — the
    // popup branch, unchanged — or (tabId, message, options, callback) — the sender
    // branch, which now scopes delivery with { frameId, documentId }. Detect which
    // shape was used by checking whether the 3rd argument is the callback.
    sendMessage: (tabId, message, optionsOrCallback, maybeCallback) => {
      const hasOptions = typeof optionsOrCallback !== 'function';
      const options = hasOptions ? optionsOrCallback : undefined;
      const callback = hasOptions ? maybeCallback : optionsOrCallback;
      sentMessages.push({ tabId, message, options });
      global.chrome.runtime.lastError = nextSendMessageLastError;
      if (callback) callback();
      global.chrome.runtime.lastError = null;
    }
  }
};

const { resolveSenderFillTarget, relayFillToActiveTab, hostnameMatches } = require('../background.js');

// --- resolveSenderFillTarget: the pure branch-selection decision ---------------------

// Content-script sender with a matching origin: target sender.tab.id directly.
{
  const sender = { tab: { id: 42 }, url: 'https://example.com/login' };
  const result = resolveSenderFillTarget(sender, 'https://example.com/');
  assert.deepStrictEqual(result, { tabId: 42, ok: true });
}

// Content-script sender whose origin does NOT match requestUrl: rejected.
{
  const sender = { tab: { id: 42 }, url: 'https://evil.example/login' };
  const result = resolveSenderFillTarget(sender, 'https://example.com/');
  assert.ok(result, 'a content-script sender must still produce a result object');
  assert.strictEqual(result.ok, false, 'mismatched sender origin must not be accepted');
}

// Content-script sender with an empty/absent sender.url: this is the exact failure mode
// that started the original bug (an empty URL silently passing the origin check) — it
// must never pass here either.
{
  const senderEmptyUrl = { tab: { id: 7 }, url: '' };
  const resultEmpty = resolveSenderFillTarget(senderEmptyUrl, 'https://example.com/');
  assert.ok(resultEmpty, 'a content-script sender must still produce a result object');
  assert.strictEqual(resultEmpty.ok, false, 'an empty sender.url must never pass the origin check');

  const senderNoUrl = { tab: { id: 7 } };
  const resultMissing = resolveSenderFillTarget(senderNoUrl, 'https://example.com/');
  assert.ok(resultMissing);
  assert.strictEqual(resultMissing.ok, false, 'an absent sender.url must never pass the origin check');
}

// Popup sender (no sender.tab at all): signal the caller to fall back to the
// active-tab lookup, which is the only path that works for the popup (opening it is the
// gesture that grants activeTab).
{
  assert.strictEqual(resolveSenderFillTarget(undefined, 'https://example.com/'), null);
  assert.strictEqual(resolveSenderFillTarget({}, 'https://example.com/'), null);
  assert.strictEqual(resolveSenderFillTarget({ tab: undefined }, 'https://example.com/'), null);
}

// --- relayFillToActiveTab: end-to-end branch wiring -----------------------------------

// Content-script sender: message goes straight to sender.tab.id, scoped to the exact
// frame/document that asked (frameId/documentId), no chrome.tabs.query. The scoping is
// what closes the TOCTOU window between capturing sender.url and delivering after the
// async native round-trip: a stale documentId simply fails to deliver instead of landing
// in whatever (possibly attacker) document now occupies the tab.
{
  sentMessages.length = 0;
  queriedTabs.length = 0;
  const sender = { tab: { id: 99 }, url: 'https://example.com/login', frameId: 0, documentId: 'doc-abc' };
  relayFillToActiveTab({ username: 'alice', password: 'hunter2', totp: '123456' }, 'https://example.com/', sender);
  assert.strictEqual(queriedTabs.length, 0, 'content-script path must not call chrome.tabs.query');
  assert.strictEqual(sentMessages.length, 1);
  assert.strictEqual(sentMessages[0].tabId, 99);
  assert.deepStrictEqual(sentMessages[0].options, { frameId: 0, documentId: 'doc-abc' },
    'sender-branch delivery must be scoped to the exact frame/document that sent the request');
  // Full applyFill payload, not just `type` — pins field names so a regression in
  // sendApplyFill/sendApplyFillToSender's message shape fails loudly, not silently.
  assert.deepStrictEqual(sentMessages[0].message, {
    type: 'applyFill',
    username: 'alice',
    password: 'hunter2',
    totp: '123456',
    url: 'https://example.com/'
  });
}

// Content-script sender, but the tab navigated away before delivery: chrome.tabs.sendMessage
// with a stale documentId fails with chrome.runtime.lastError — that is the SUCCESS case
// for this guard (the message correctly did not land in the new document), not a bug, so
// it must not throw.
{
  sentMessages.length = 0;
  nextSendMessageLastError = { message: 'No tab with id: 99, or frame no longer exists.' };
  const sender = { tab: { id: 99 }, url: 'https://example.com/login', frameId: 0, documentId: 'doc-stale' };
  assert.doesNotThrow(() => {
    relayFillToActiveTab({ username: 'alice', password: 'hunter2', totp: null }, 'https://example.com/', sender);
  });
  assert.strictEqual(sentMessages.length, 1, 'delivery is still attempted — only the callback observes the error');
  nextSendMessageLastError = null;
}

// Content-script sender with a mismatched origin: nothing is sent anywhere.
{
  sentMessages.length = 0;
  queriedTabs.length = 0;
  const sender = { tab: { id: 99 }, url: 'https://evil.example/' };
  relayFillToActiveTab({ username: 'u', password: 'p', totp: null }, 'https://example.com/', sender);
  assert.strictEqual(queriedTabs.length, 0);
  assert.strictEqual(sentMessages.length, 0);
}

// No sender.tab (popup): falls back to chrome.tabs.query({active:true, currentWindow:true}),
// unchanged from before this fix — including its own hostnameMatches(requestUrl, activeTab.url)
// guard and the plain 3-arg chrome.tabs.sendMessage call (no frameId/documentId options).
{
  sentMessages.length = 0;
  queriedTabs.length = 0;
  activeTabQueryResult = [{ id: 5, url: 'https://example.com/account' }];
  relayFillToActiveTab({ username: 'u', password: 'p', totp: null }, 'https://example.com/', undefined);
  assert.strictEqual(queriedTabs.length, 1);
  assert.strictEqual(sentMessages.length, 1);
  assert.strictEqual(sentMessages[0].tabId, 5);
  assert.strictEqual(sentMessages[0].options, undefined,
    'the popup branch must keep the original 3-arg chrome.tabs.sendMessage call, no options object');
}

// Popup path, active tab on a DIFFERENT host than the request: the origin guard must
// reject it and send nothing. Without `if (!hostnameMatches(...)) return;` in the popup
// branch this test fails — see mutation verification in the report.
{
  sentMessages.length = 0;
  queriedTabs.length = 0;
  activeTabQueryResult = [{ id: 5, url: 'https://evil.example/' }];
  relayFillToActiveTab({ username: 'u', password: 'p', totp: null }, 'https://example.com/', undefined);
  assert.strictEqual(queriedTabs.length, 1);
  assert.strictEqual(sentMessages.length, 0, 'a mismatched active-tab host must not receive the credential');
}

// Popup path, active tab url is EMPTY: this is the exact shape that caused the original
// bug (activeTab.url === '' before activeTab was granted) — it must still be rejected on
// this branch, not just on the sender branch.
{
  sentMessages.length = 0;
  queriedTabs.length = 0;
  activeTabQueryResult = [{ id: 5, url: '' }];
  relayFillToActiveTab({ username: 'u', password: 'p', totp: null }, 'https://example.com/', undefined);
  assert.strictEqual(queriedTabs.length, 1);
  assert.strictEqual(sentMessages.length, 0, 'an empty active-tab url must never pass the origin check');
}

// Sanity: hostnameMatches itself still rejects an empty page URL (defense-in-depth check
// this whole fix relies on remains intact).
assert.strictEqual(hostnameMatches('https://example.com/', ''), false);

console.log('background.js: relay target selection OK');
