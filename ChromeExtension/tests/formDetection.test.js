const assert = require('node:assert');
const path = require('node:path');
const { scoreUsernameLikeness, findBestUsernameInput } = require(path.join(__dirname, '..', 'content.js'));

function fakeInput(attrs) {
  return {
    getAttribute(name) {
      return Object.prototype.hasOwnProperty.call(attrs, name) ? attrs[name] : null;
    }
  };
}

const usernameField = fakeInput({ type: 'text', autocomplete: 'username', name: 'user' });
const genericTextField = fakeInput({ type: 'text', name: 'promo-code' });
assert.ok(
  scoreUsernameLikeness(usernameField) > scoreUsernameLikeness(genericTextField),
  'autocomplete=username field should score higher than an unrelated text field'
);

const emailField = fakeInput({ type: 'email', name: 'email' });
assert.ok(
  scoreUsernameLikeness(emailField) > scoreUsernameLikeness(genericTextField),
  'email field should score higher than an unrelated text field'
);

const best = findBestUsernameInput([genericTextField, usernameField, emailField]);
assert.strictEqual(best, usernameField, 'expected the autocomplete=username field to win');

assert.strictEqual(findBestUsernameInput([]), null, 'empty candidate list must return null, not throw');

console.log('content.js form-detection heuristics OK');
