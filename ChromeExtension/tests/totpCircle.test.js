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
    style: {},
    children: [],
    appendChild(child) {
      this.children.push(child);
    },
    addEventListener() {},
    setAttribute(name, value) {
      this[name] = value;
    }
  };
  elements[id] = el;
  return el;
}

[
  'locked-panel',
  'locked-title',
  'locked-helper',
  'locked-retry-btn',
  'app-unavailable-panel',
  'app-unavailable-status',
  'app-unavailable-actions',
  'retry-btn',
  'open-mypass-btn',
  'open-mypass-helper',
  'empty-panel',
  'empty-title',
  'list-panel',
  'list-header',
  'list',
  'pairing-panel',
  'pairing-title',
  'connect-btn',
  'code-entry',
  'code-input',
  'submit-code-btn',
  'pairing-error'
].forEach((id) => makeEl(id));

const documentListeners = [];
const documentRemovedListeners = [];

global.document = {
  getElementById: (id) => {
    if (!elements[id]) makeEl(id);
    return elements[id];
  },
  createElement: (tag) => makeEl(tag),
  addEventListener: (type, handler, capture) => {
    documentListeners.push({ type, handler, capture });
  },
  removeEventListener: (type, handler, capture) => {
    documentRemovedListeners.push({ type, handler, capture });
  }
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

function makeFakeCircleElement(options = {}) {
  const classes = new Set();
  const listeners = {};
  return {
    isConnected: options.isConnected !== undefined ? options.isConnected : true,
    classList: {
      add(...names) { names.forEach((n) => classes.add(n)); },
      remove(...names) { names.forEach((n) => classes.delete(n)); },
      contains(name) { return classes.has(name); },
    },
    textContent: '',
    addEventListener(type, handler) {
      listeners[type] = listeners[type] || [];
      listeners[type].push(handler);
    },
    dispatch(type, event) {
      (listeners[type] || []).forEach((handler) => handler(event));
    },
    contains() { return false; },
  };
}

function lastDocumentClickListener() {
  for (let i = documentListeners.length - 1; i >= 0; i -= 1) {
    if (documentListeners[i].type === 'click') return documentListeners[i];
  }
  return undefined;
}

const { shouldShowTotpCircle, createTotpCircleController } = require('../popup.js');

assert.strictEqual(shouldShowTotpCircle(true), true);
assert.strictEqual(shouldShowTotpCircle(false), false);
assert.strictEqual(shouldShowTotpCircle(undefined), false);
console.log('totpCircle.test.js: shouldShowTotpCircle OK');

(async () => {
  const circle = makeFakeCircleElement();
  let requestCount = 0;
  const requestTotp = () => {
    requestCount += 1;
    return Promise.resolve('123456');
  };
  createTotpCircleController(circle, requestTotp);

  let stopped = false;
  circle.dispatch('click', { stopPropagation: () => { stopped = true; } });
  await Promise.resolve();
  await Promise.resolve();

  assert.strictEqual(stopped, true, 'circle click must stopPropagation so it never bubbles to the row click handler');
  assert.strictEqual(circle.textContent, '123456', 'left-click reveals the code');
  assert.strictEqual(requestCount, 1);

  circle.dispatch('click', { stopPropagation: () => {} });
  assert.strictEqual(circle.textContent, '', 'second left-click hides the code');

  console.log('totpCircle.test.js: createTotpCircleController reveal/hide OK');

  // --- (a) copied flash dismissal: a second left-click during the "Copied" flash
  // must hide immediately, without issuing a new getTotp request. ---
  // Node ships a read-only, getter-only `navigator` global (no setter) — plain
  // assignment silently no-ops, so redefine the property to install the stub.
  Object.defineProperty(global, 'navigator', {
    value: { clipboard: { writeText: () => Promise.resolve() } },
    configurable: true,
    writable: true
  });

  const copyCircle = makeFakeCircleElement();
  let copyRequestCount = 0;
  const copyRequestTotp = () => {
    copyRequestCount += 1;
    return Promise.resolve('654321');
  };
  createTotpCircleController(copyCircle, copyRequestTotp);

  copyCircle.dispatch('contextmenu', { preventDefault: () => {}, stopPropagation: () => {} });
  await Promise.resolve();
  await Promise.resolve();
  await Promise.resolve();
  await Promise.resolve();

  assert.strictEqual(copyCircle.textContent, 'Copied', 'right-click copies and shows the flash');
  assert.strictEqual(copyRequestCount, 1);

  copyCircle.dispatch('click', { stopPropagation: () => {} });
  assert.strictEqual(copyCircle.textContent, '', 'second left-click during copied flash hides, not re-reveals');
  assert.strictEqual(copyRequestCount, 1, 'second left-click during copied flash must not issue a new getTotp request');

  console.log('totpCircle.test.js: copied flash second-click dismissal OK');

  // --- (b) outside-click handler is registered in the capture phase, and hides a
  // revealed circle when the click target is outside it. ---
  const outsideCircle = makeFakeCircleElement();
  const outsideRequestTotp = () => Promise.resolve('111222');
  createTotpCircleController(outsideCircle, outsideRequestTotp);

  const outsideListener = lastDocumentClickListener();
  assert.ok(outsideListener, 'createTotpCircleController must register a document click listener');
  assert.strictEqual(outsideListener.capture, true, 'outside-click listener must be registered on the capture phase');

  outsideCircle.dispatch('click', { stopPropagation: () => {} });
  await Promise.resolve();
  await Promise.resolve();
  assert.strictEqual(outsideCircle.textContent, '111222', 'left-click reveals before the outside-click check');

  outsideListener.handler({ target: {} });
  assert.strictEqual(outsideCircle.textContent, '', 'invoking the captured outside-click handler with a foreign target hides the revealed code');

  console.log('totpCircle.test.js: outside-click capture-phase dismissal OK');

  // --- (c) self-clean: once the circle is no longer in the DOM, the outside-click
  // handler removes itself instead of accumulating across re-renders. ---
  const disconnectedCircle = makeFakeCircleElement({ isConnected: false });
  const disconnectedRequestTotp = () => Promise.resolve('999000');
  createTotpCircleController(disconnectedCircle, disconnectedRequestTotp);

  const disconnectedListener = lastDocumentClickListener();
  assert.ok(disconnectedListener, 'createTotpCircleController must register a document click listener');

  const removedBefore = documentRemovedListeners.length;
  disconnectedListener.handler({ target: {} });
  assert.strictEqual(documentRemovedListeners.length, removedBefore + 1, 'a disconnected circle must remove its own outside-click listener');
  const removedCall = documentRemovedListeners[documentRemovedListeners.length - 1];
  assert.strictEqual(removedCall.type, 'click');
  assert.strictEqual(removedCall.handler, disconnectedListener.handler);
  assert.strictEqual(removedCall.capture, true);
  assert.strictEqual(disconnectedCircle.textContent, '', 'a disconnected circle must not reveal/hide as a side effect of self-cleaning');

  console.log('totpCircle.test.js: stale listener self-clean on disconnect OK');
})();
