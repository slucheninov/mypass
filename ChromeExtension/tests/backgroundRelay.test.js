const assert = require('node:assert');

// Minimal chrome stub — background.js registers chrome.runtime.onMessage.addListener at
// module load time (top-level, not inside a conditional), so a global.chrome with at
// least that shape must exist before require(). chrome.webAuthenticationProxy is left
// undefined so the passkey-proxy listener block (guarded by a typeof check) is skipped.
const sentMessages = [];
const queriedTabs = [];
let activeTabQueryResult = [];

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
    sendMessage: (tabId, message, cb) => {
      sentMessages.push({ tabId, message });
      if (cb) cb();
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

// Content-script sender: message goes straight to sender.tab.id, no chrome.tabs.query.
{
  sentMessages.length = 0;
  queriedTabs.length = 0;
  const sender = { tab: { id: 99 }, url: 'https://example.com/login' };
  relayFillToActiveTab({ username: 'u', password: 'p', totp: null }, 'https://example.com/', sender);
  assert.strictEqual(queriedTabs.length, 0, 'content-script path must not call chrome.tabs.query');
  assert.strictEqual(sentMessages.length, 1);
  assert.strictEqual(sentMessages[0].tabId, 99);
  assert.strictEqual(sentMessages[0].message.type, 'applyFill');
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

// No sender.tab (popup): falls back to chrome.tabs.query({active:true, currentWindow:true}).
{
  sentMessages.length = 0;
  queriedTabs.length = 0;
  activeTabQueryResult = [{ id: 5, url: 'https://example.com/account' }];
  relayFillToActiveTab({ username: 'u', password: 'p', totp: null }, 'https://example.com/', undefined);
  assert.strictEqual(queriedTabs.length, 1);
  assert.strictEqual(sentMessages.length, 1);
  assert.strictEqual(sentMessages[0].tabId, 5);
}

// Sanity: hostnameMatches itself still rejects an empty page URL (defense-in-depth check
// this whole fix relies on remains intact).
assert.strictEqual(hostnameMatches('https://example.com/', ''), false);

console.log('background.js: relay target selection OK');
