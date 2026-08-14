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

function fakeScope(inputs, formScope) {
  return {
    querySelectorAll: (selector) => {
      if (selector === 'input[type="password"]') {
        return inputs.filter((i) => i.getAttribute('type') === 'password');
      }
      if (selector === 'input, textarea') return inputs;
      // the username selector
      return inputs.filter((i) => {
        const t = i.getAttribute('type');
        return t === 'text' || t === 'email' || (i.getAttribute('autocomplete') || '').includes('username');
      });
    },
    __formScope: formScope,
  };
}

const { isFieldVisible, findFillableFields } = require('../content.js');

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
