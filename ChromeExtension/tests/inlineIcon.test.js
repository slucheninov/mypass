const assert = require('node:assert');

function fakeInput(attrs = {}, extra = {}) {
  return {
    getAttribute: (name) => (Object.prototype.hasOwnProperty.call(attrs, name) ? attrs[name] : null),
    offsetParent: extra.hidden ? null : {},
    disabled: !!extra.disabled,
    readOnly: !!extra.readOnly,
    closest: (sel) => (sel === 'form' ? extra.form || null : null),
    tagName: 'INPUT',
  };
}

function fakeScope(inputs) {
  return {
    querySelectorAll: (selector) => {
      if (selector === 'input[type="password"]') {
        return inputs.filter((i) => i.getAttribute('type') === 'password');
      }
      // findOtpField's selector — unfiltered, exercised on every findFillableFields/
      // findLoginForm call below since both call findOtpField internally.
      if (selector === 'input, textarea') return inputs;
      // the username selector
      return inputs.filter((i) => {
        const t = i.getAttribute('type');
        return t === 'text' || t === 'email' || (i.getAttribute('autocomplete') || '').includes('username');
      });
    },
  };
}

const { isFieldVisible, findFillableFields, findLoginForm } = require('../content.js');

// isFieldVisible
assert.strictEqual(isFieldVisible(fakeInput({ type: 'text' })), true, 'plain visible input is fillable');
assert.strictEqual(isFieldVisible(fakeInput({ type: 'text' }, { hidden: true })), false, 'offsetParent null is not fillable');
assert.strictEqual(isFieldVisible(fakeInput({ type: 'text', disabled: '' })), false, 'disabled attribute excluded');
assert.strictEqual(isFieldVisible(fakeInput({ type: 'text' }, { readOnly: true })), false, 'readOnly property excluded');
console.log('inlineIcon.test.js: isFieldVisible OK');

// findFillableFields
const pw = fakeInput({ type: 'password' });
const user = fakeInput({ type: 'text', name: 'username' });
const kinds = (fields) => fields.map((f) => f.kind).sort();

assert.deepStrictEqual(
  kinds(findFillableFields(fakeScope([user, pw]))),
  ['password', 'username'],
  'password outside any form still yields both fields'
);

const userOnly = findFillableFields(fakeScope([fakeInput({ type: 'email', name: 'email' })]));
assert.deepStrictEqual(kinds(userOnly), ['username'], 'identifier-first page with no password field still gets a username field');

assert.deepStrictEqual(
  findFillableFields(fakeScope([fakeInput({ type: 'password' }, { hidden: true })])),
  [],
  'hidden password field yields nothing'
);

// An OTP field also matches the username selector — OTP must win, and the field
// must appear exactly once.
const otp = fakeInput({ type: 'text', autocomplete: 'one-time-code' });
const otpFields = findFillableFields(fakeScope([otp]));
assert.deepStrictEqual(kinds(otpFields), ['otp'], 'one-time-code field is classified otp, not username');
assert.strictEqual(otpFields.length, 1, 'a field is never emitted twice');
console.log('inlineIcon.test.js: findFillableFields OK');

// findLoginForm — reads the global `document`, so stub it per case and restore it after.
const originalDocument = global.document;

// 1. Password field inside a <form> yields {form, passwordInput, usernameInput} with a
// non-null form and both inputs identified correctly.
const formInputs = [];
const formEl = Object.assign(fakeScope(formInputs), { tagName: 'FORM' });
const pwInForm = fakeInput({ type: 'password' }, { form: formEl });
const userInForm = fakeInput({ type: 'text', name: 'username' }, { form: formEl });
formInputs.push(pwInForm, userInForm);
global.document = fakeScope([userInForm, pwInForm]);
const withForm = findLoginForm();
assert.notStrictEqual(withForm, null, 'password field inside a form yields a result');
assert.strictEqual(withForm.form, formEl, 'form is the enclosing <form> element');
assert.strictEqual(withForm.passwordInput, pwInForm, 'passwordInput is the password field');
assert.strictEqual(withForm.usernameInput, userInForm, 'usernameInput is the username field');

// 2. Password field with NO enclosing <form> — deliberate behaviour change from the old
// findLoginForm, which returned null here and silently made applyFill do nothing on such
// pages. The new findLoginForm returns a non-null result with form: null so applyFill can
// still fill the password.
const pwNoForm = fakeInput({ type: 'password' });
global.document = fakeScope([pwNoForm]);
const withoutForm = findLoginForm();
assert.notStrictEqual(withoutForm, null, 'password field with no enclosing form still yields a result');
assert.strictEqual(
  withoutForm.form,
  null,
  'deliberate behaviour change: a password field outside any <form> now returns form: null instead of the old null result, so applyFill can still fill it'
);
assert.strictEqual(withoutForm.passwordInput, pwNoForm, 'passwordInput is set even without a form');

// 3. No password field on the page.
global.document = fakeScope([fakeInput({ type: 'text', name: 'username' })]);
assert.strictEqual(findLoginForm(), null, 'no password field on the page yields null');

// 4. Password plus a username field — usernameInput must be the username field, not the
// password field.
const pw2 = fakeInput({ type: 'password' });
const user2 = fakeInput({ type: 'text', name: 'username' });
global.document = fakeScope([pw2, user2]);
const withUsername = findLoginForm();
assert.strictEqual(withUsername.usernameInput, user2, 'usernameInput is the username field, not the password field');
assert.notStrictEqual(withUsername.usernameInput, withUsername.passwordInput, 'password and username inputs are distinct fields');

global.document = originalDocument;
console.log('inlineIcon.test.js: findLoginForm OK');

const { chooseInlinePanel } = require('../content.js');

const withTotp = { id: '1', title: 'Example', username: 'alice', hasTotp: true };
const noTotp = { id: '2', title: 'Other', username: 'bob', hasTotp: false };
const listResponse = { type: 'credentialList', credentials: [withTotp, noTotp] };

assert.deepStrictEqual(
  chooseInlinePanel(listResponse, 'password'),
  { panel: 'entries', entries: [withTotp, noTotp] },
  'password field lists every match'
);

assert.deepStrictEqual(
  chooseInlinePanel(listResponse, 'otp'),
  { panel: 'entries', entries: [withTotp] },
  'otp field lists only entries that have a TOTP secret'
);

assert.deepStrictEqual(
  chooseInlinePanel({ type: 'credentialList', credentials: [noTotp] }, 'otp'),
  { panel: 'empty', entries: [] },
  'a non-empty list with no TOTP entries renders empty on an otp field'
);

assert.deepStrictEqual(
  chooseInlinePanel({ type: 'credentialList', credentials: [] }, 'password'),
  { panel: 'empty', entries: [] },
  'no matches for this site'
);

assert.strictEqual(chooseInlinePanel({ type: 'locked' }, 'password').panel, 'locked');
assert.strictEqual(chooseInlinePanel({ type: 'pairingRequired' }, 'password').panel, 'pairingRequired');
assert.strictEqual(chooseInlinePanel({ type: 'error' }, 'password').panel, 'unavailable');
assert.strictEqual(chooseInlinePanel(null, 'password').panel, 'unavailable', 'no response is treated as app unavailable');
assert.strictEqual(chooseInlinePanel({ type: 'somethingNew' }, 'password').panel, 'unavailable', 'unknown response never renders entries');
console.log('inlineIcon.test.js: chooseInlinePanel OK');

const { isTrustedActivation, handleEntrySelect, handleIconActivate } = require('../content.js');

assert.strictEqual(isTrustedActivation({ isTrusted: true }), true);
assert.strictEqual(isTrustedActivation({ isTrusted: false }), false, 'synthetic events are rejected');
assert.strictEqual(isTrustedActivation({}), false, 'a missing isTrusted is rejected, not assumed true');
assert.strictEqual(isTrustedActivation(null), false, 'no event is rejected');

// handleEntrySelect: the ONLY message it may send, and only on a trusted event.
const sent = [];
const record = (message) => sent.push(message);

assert.strictEqual(
  handleEntrySelect({ isTrusted: false }, 'entry-1', 'https://example.com', record),
  false,
  'synthetic click does not fill'
);
assert.deepStrictEqual(sent, [], 'synthetic click sends nothing at all');

assert.strictEqual(handleEntrySelect({ isTrusted: true }, 'entry-1', 'https://example.com', record), true);
assert.deepStrictEqual(
  sent,
  [{ type: 'fillCredential', id: 'entry-1', url: 'https://example.com' }],
  'fill message is exactly what popup.js sends — no secret, no extra field'
);

// handleIconActivate
let opened = 0;
assert.strictEqual(handleIconActivate({ isTrusted: false }, () => { opened += 1; }), false);
assert.strictEqual(opened, 0, 'synthetic click does not open the panel');
assert.strictEqual(handleIconActivate({ isTrusted: true }, () => { opened += 1; }), true);
assert.strictEqual(opened, 1);
console.log('inlineIcon.test.js: trusted-event gate OK');

const { buildIconHost, positionHostToField, KEY_ICON_PATH_D } = require('../content.js');

const SVG_NS_EXPECTED = 'http://www.w3.org/2000/svg';

function fakeElement(tag) {
  const el = {
    tagName: tag.toUpperCase(),
    style: {},
    children: [],
    attributes: {},
    shadowMode: null,
    setAttribute(name, value) { this.attributes[name] = value; },
    getAttribute(name) { return Object.prototype.hasOwnProperty.call(this.attributes, name) ? this.attributes[name] : null; },
    appendChild(child) { this.children.push(child); return child; },
    addEventListener() {},
    attachShadow(options) {
      this.shadowMode = options.mode;
      const root = fakeElement('shadow-root');
      this.__shadow = root;
      return root;
    },
  };
  return el;
}

const fakeDocument = {
  createElement: (tag) => fakeElement(tag),
  createElementNS: (ns, tag) => {
    const el = fakeElement(tag);
    el.namespaceURI = ns;
    return el;
  },
};

const built = buildIconHost(fakeDocument);
assert.strictEqual(built.host.shadowMode, 'closed', 'shadow root MUST be closed so the page cannot read the panel');
assert.ok(built.shadow, 'a shadow root is returned');
assert.ok(built.button, 'a clickable button lives inside the shadow root');
assert.ok(/^M/.test(KEY_ICON_PATH_D), 'the glyph is SVG path data');
assert.ok(!/chrome-extension:/.test(KEY_ICON_PATH_D), 'the glyph never references an extension URL');
const glyph = built.button.children[0];
assert.strictEqual(glyph.namespaceURI, SVG_NS_EXPECTED, 'the svg element is namespaced, not an HTML element');
assert.strictEqual(glyph.children[0].getAttribute('d'), KEY_ICON_PATH_D, 'the path carries the key glyph data');
assert.strictEqual(built.button.innerHTML, undefined, 'the icon is built from DOM nodes, never innerHTML — Trusted Types sites throw on innerHTML');

// positioning writes only to the host's own style — the page's input is untouched
const host = fakeElement('div');
positionHostToField(host, { top: 100, left: 50, width: 200, height: 30 }, { scrollX: 0, scrollY: 0 });
assert.strictEqual(host.style.position, 'absolute');
assert.ok(host.style.top, 'a top offset is written');
assert.ok(host.style.left, 'a left offset is written');
console.log('inlineIcon.test.js: icon host OK');
