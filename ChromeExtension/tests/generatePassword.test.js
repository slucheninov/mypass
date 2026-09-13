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
// ------ and relays a successful popup-originated response to the active tab -------

let sentNativeMessage = null;
let tabsQueryCalls = [];
let tabsSendMessageCalls = [];
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
  },
  // Only reached by the popup-sender scenario below — a content-script sender must never
  // touch chrome.tabs at all (background.js gates the relay on !sender.tab), which the
  // second scenario proves by asserting these arrays stayed empty.
  tabs: {
    query: (opts, cb) => { tabsQueryCalls.push(opts); cb([{ id: 99, url: 'https://example.com/account' }]); },
    sendMessage: (tabId, message, options, cb) => {
      tabsSendMessageCalls.push({ tabId, message, options });
      if (cb) cb();
    }
  }
};

delete require.cache[require.resolve(path.join(__dirname, '..', 'background.js'))];
const { handleRuntimeMessage } = require(path.join(__dirname, '..', 'background.js'));

// sendNativeMessageWithPairing (the generic-forwarding branch generatePassword falls
// through to) is async — it awaits readPairingSecret, sendNativeMessage,
// clearStaleSecretOnPairingRequired and persistPairingResponse in turn — so sendResponse
// fires on a later microtask even though every stubbed chrome callback above resolves
// synchronously. Wrap each scenario in a promise that resolves exactly when sendResponse
// runs, rather than asserting immediately after the synchronous call, so this doesn't
// race the chain. Both scenarios below share `sentNativeMessage`/`tabsQueryCalls`/
// `tabsSendMessageCalls`, so they run sequentially inside one async IIFE rather than as
// two independent ones — two independent async IIFEs would interleave their synchronous
// prologues (the second scenario's reset stomping the first scenario's in-flight state)
// before either one's response promise had a chance to settle.
(async () => {
  // Scenario 1: a popup-originated request (no sender.tab — the popup is not injected
  // into any tab) whose success must be relayed to the active tab.
  {
    let responded = null;
    let keepChannelOpen;
    await new Promise((resolve) => {
      keepChannelOpen = handleRuntimeMessage(
        // `url` travels alongside `domain` for the same reason popup.js's real request
        // does: the relay needs a page URL to hostname-match against the active tab
        // before it will forward the password anywhere.
        { type: 'generatePassword', domain: 'example.com', url: 'https://example.com/signup' },
        {},
        (response) => { responded = response; resolve(); }
      );
    });
    assert.strictEqual(keepChannelOpen, true, 'the async response path must keep the message channel open');
    assert.ok(sentNativeMessage, 'generatePassword must be forwarded to the native host');
    assert.strictEqual(sentNativeMessage.type, 'generatePassword');
    assert.strictEqual(sentNativeMessage.domain, 'example.com');
    assert.deepStrictEqual(responded, { type: 'generatedPassword', password: 'Tr0ub4dor&3' });

    // The popup has no DOM access of its own, so a successful response must be relayed
    // to the active tab through the exact same relayFillToActiveTab/sendApplyFill path
    // fillCredential already uses — hostname pre-check included — rather than a second,
    // less careful copy of that sequence living in popup.js.
    assert.strictEqual(tabsQueryCalls.length, 1, 'a popup-originated generatePassword success queries the active tab');
    assert.strictEqual(tabsSendMessageCalls.length, 1, 'and relays exactly one applyFill to it');
    const relayed = tabsSendMessageCalls[0];
    assert.strictEqual(relayed.tabId, 99);
    assert.strictEqual(relayed.message.type, 'applyFill');
    assert.strictEqual(relayed.message.password, 'Tr0ub4dor&3');
    assert.deepStrictEqual(relayed.options, { frameId: 0 }, 'scoped to the top frame, exactly like the fillCredential relay');

    console.log('generatePassword.test.js: background.js allowlist + forwarding + popup relay OK');
  }

  // Scenario 2: a content-script-originated request (sender.tab present — the exact
  // signal resolveSenderFillTarget already keys on elsewhere in this file) must never
  // ALSO be relayed. The content script already wrote the password directly into the
  // field the user clicked (content.js's own setNativeValue fill); relaying it here too
  // would be a second, uncoordinated write into the same page.
  {
    sentNativeMessage = null;
    tabsQueryCalls = [];
    tabsSendMessageCalls = [];
    let responded = null;
    await new Promise((resolve) => {
      handleRuntimeMessage(
        { type: 'generatePassword', domain: 'example.com', url: 'https://example.com/signup' },
        { tab: { id: 7 }, url: 'https://example.com/signup', frameId: 0, documentId: 'doc-1' },
        (response) => { responded = response; resolve(); }
      );
    });
    assert.deepStrictEqual(responded, { type: 'generatedPassword', password: 'Tr0ub4dor&3' });
    assert.strictEqual(tabsQueryCalls.length, 0, 'a content-script-originated request must never trigger the relay');
    assert.strictEqual(tabsSendMessageCalls.length, 0, 'and must never send a second applyFill');

    console.log('generatePassword.test.js: background.js content-script sender is never relayed OK');
  }
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

// --- content.js: the inline panel's generate-password failure path ------------------
// Covers exactly what previously shipped untested: togglePanel's generate-row click
// handler used to act only on a successful response and otherwise close the panel with
// no explanation at all. classifyGeneratePasswordResponse is the extracted decision
// logic that click handler now calls; showGeneratePasswordMessage is how it renders a
// failure using the panel's own vocabulary.

const { classifyGeneratePasswordResponse, showGeneratePasswordMessage } = require(path.join(__dirname, '..', 'content.js'));

assert.deepStrictEqual(
  classifyGeneratePasswordResponse({ type: 'generatedPassword', password: 'Tr0ub4dor&3' }),
  { action: 'fill', password: 'Tr0ub4dor&3' }
);
assert.deepStrictEqual(
  classifyGeneratePasswordResponse({ type: 'locked' }),
  { action: 'showMessage', message: 'MyPass is locked' }
);
assert.deepStrictEqual(
  classifyGeneratePasswordResponse({ type: 'pairingRequired' }),
  { action: 'showMessage', message: 'Pair MyPass to use it here' }
);
// The two distinct messages Task 11 split apart — one about the user's own generator
// settings, one about the site's requirements — must each reach the user verbatim,
// never collapsed into one generic string.
assert.deepStrictEqual(
  classifyGeneratePasswordResponse({
    type: 'error',
    message: 'Your password generator has no character types enabled. Turn on at least one in Settings and try again.'
  }),
  {
    action: 'showMessage',
    message: 'Your password generator has no character types enabled. Turn on at least one in Settings and try again.'
  }
);
assert.deepStrictEqual(
  classifyGeneratePasswordResponse({ type: 'error', message: "This site's password requirements could not be satisfied" }),
  { action: 'showMessage', message: "This site's password requirements could not be satisfied" }
);
// No usable response at all (extension context lost, native host unreachable with no
// message attached, or a malformed "success" missing its password) falls back to the
// panel's own generic "not running" message rather than throwing or showing nothing.
assert.deepStrictEqual(classifyGeneratePasswordResponse(null), { action: 'showMessage', message: 'MyPass is not running' });
assert.deepStrictEqual(classifyGeneratePasswordResponse({ type: 'error' }), { action: 'showMessage', message: 'MyPass is not running' });
assert.deepStrictEqual(
  classifyGeneratePasswordResponse({ type: 'generatedPassword' }),
  { action: 'showMessage', message: 'MyPass is not running' }
);

console.log('generatePassword.test.js: classifyGeneratePasswordResponse OK');

function fakeMessageDoc() {
  return {
    createElement(tag) {
      return {
        tagName: tag.toUpperCase(),
        attrs: {},
        textContent: '',
        setAttribute(name, value) { this.attrs[name] = value; },
        getAttribute(name) { return Object.prototype.hasOwnProperty.call(this.attrs, name) ? this.attrs[name] : null; }
      };
    }
  };
}

function fakeMessageRoot() {
  const children = [];
  return {
    children,
    appendChild(el) {
      children.push(el);
      el.remove = () => {
        const index = children.indexOf(el);
        if (index !== -1) children.splice(index, 1);
      };
      return el;
    },
    querySelector(selector) {
      const cls = selector.replace('.', '');
      return children.find((el) => (el.attrs.class || '').split(' ').includes(cls)) || null;
    }
  };
}

{
  const doc = fakeMessageDoc();
  const root = fakeMessageRoot();
  showGeneratePasswordMessage(doc, root, 'MyPass is locked');
  assert.strictEqual(root.children.length, 1, 'renders exactly one message element');
  assert.strictEqual(root.children[0].getAttribute('class'), 'message generate-password-message');
  assert.strictEqual(root.children[0].textContent, 'MyPass is locked');

  showGeneratePasswordMessage(doc, root, 'Pair MyPass to use it here');
  assert.strictEqual(root.children.length, 1, 'a later failure replaces the earlier message rather than stacking it');
  assert.strictEqual(root.children[0].textContent, 'Pair MyPass to use it here');
}

console.log('generatePassword.test.js: showGeneratePasswordMessage OK');
