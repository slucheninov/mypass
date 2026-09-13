const assert = require('node:assert');
const path = require('node:path');
const { findFillableFields, isNewPasswordCandidate } = require(path.join(__dirname, '..', 'content.js'));

function fakeInput(attrs) {
  return {
    getAttribute(name) {
      return Object.prototype.hasOwnProperty.call(attrs, name) ? attrs[name] : null;
    },
    closest() {
      return null;
    },
    disabled: false,
    readOnly: false,
    offsetParent: {}
  };
}

// --- isNewPasswordCandidate: the pure classification decision ------------------------

{
  const field = fakeInput({ type: 'password', autocomplete: 'new-password' });
  assert.strictEqual(isNewPasswordCandidate(field, [field]), true, 'autocomplete=new-password is decisive');
}

{
  const field = fakeInput({ type: 'password', autocomplete: 'current-password' });
  assert.strictEqual(
    isNewPasswordCandidate(field, [field]),
    false,
    'autocomplete=current-password is decisive the other way, even with no sibling'
  );
}

{
  // No decisive attribute, only one password field on the page: treated as a login field.
  const field = fakeInput({ type: 'password' });
  assert.strictEqual(
    isNewPasswordCandidate(field, [field]),
    false,
    'a single unhinted password field is a login field, not a new-password field'
  );
}

{
  // No decisive attribute, two password fields (the confirm-password shape): both count.
  const newField = fakeInput({ type: 'password' });
  const confirmField = fakeInput({ type: 'password' });
  const all = [newField, confirmField];
  assert.strictEqual(isNewPasswordCandidate(newField, all), true, 'the confirm-password shape marks the first field as new-password');
  assert.strictEqual(isNewPasswordCandidate(confirmField, all), true, 'the confirm-password shape marks the second field as new-password too');
}

console.log('newPasswordDetection.test.js: isNewPasswordCandidate OK');

// --- findFillableFields: isNewPassword threaded onto each password descriptor --------

function fakeScope(inputs) {
  return {
    querySelectorAll(selector) {
      if (selector === 'input[type="password"]') return inputs.filter((i) => i.getAttribute('type') === 'password');
      return [];
    }
  };
}

{
  const loginField = fakeInput({ type: 'password', autocomplete: 'current-password' });
  const fields = findFillableFields(fakeScope([loginField]));
  const passwordField = fields.find((f) => f.kind === 'password');
  assert.ok(passwordField, 'expected a password field descriptor');
  assert.strictEqual(passwordField.isNewPassword, false, 'a login field must not be offered password generation');
}

{
  const signupField = fakeInput({ type: 'password', autocomplete: 'new-password' });
  const fields = findFillableFields(fakeScope([signupField]));
  const passwordField = fields.find((f) => f.kind === 'password');
  assert.ok(passwordField, 'expected a password field descriptor');
  assert.strictEqual(passwordField.isNewPassword, true, 'autocomplete=new-password must be offered password generation');
}

console.log('newPasswordDetection.test.js: findFillableFields isNewPassword wiring OK');
