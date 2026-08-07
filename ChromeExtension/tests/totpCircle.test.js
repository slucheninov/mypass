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

global.document = {
  getElementById: (id) => {
    if (!elements[id]) makeEl(id);
    return elements[id];
  },
  createElement: (tag) => makeEl(tag),
  addEventListener: () => {}
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

function makeFakeCircleElement() {
  const classes = new Set();
  const listeners = {};
  return {
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
})();
