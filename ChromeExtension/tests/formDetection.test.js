const assert = require('node:assert');
const path = require('node:path');
const { scoreUsernameLikeness, findBestUsernameInput, hostnameMatches, scoreOtpLikeness, findOtpField } = require(path.join(__dirname, '..', 'content.js'));

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

assert.strictEqual(
  hostnameMatches('https://example.com/login', 'https://example.com/account'),
  true,
  'same hostname (different path) should match'
);

assert.strictEqual(
  hostnameMatches('https://evil.example/login', 'https://example.com/account'),
  false,
  'different hostname must not match'
);

assert.strictEqual(
  hostnameMatches('https://example.com', 'https://sub.example.com'),
  false,
  'subdomain vs bare domain must not match (exact hostname comparison, no loose matching)'
);

assert.strictEqual(
  hostnameMatches(null, 'https://example.com'),
  false,
  'missing message URL must be rejected, not treated as a match'
);

assert.strictEqual(
  hostnameMatches('not a url', 'https://example.com'),
  false,
  'malformed message URL must be rejected rather than throwing'
);

console.log('content.js form-detection heuristics OK');

// --- OTP field scoring ---

const otpAutocomplete = fakeInput({ type: 'text', autocomplete: 'one-time-code' });
assert.strictEqual(scoreOtpLikeness(otpAutocomplete), 10, 'autocomplete=one-time-code scores 10');

const otpByName = fakeInput({ type: 'text', name: 'otp-code' });
assert.strictEqual(scoreOtpLikeness(otpByName), 7, 'name matching otp pattern scores 6, plus 1 for type=text');

const otpByNumericMode = fakeInput({ type: 'text', inputmode: 'numeric', maxlength: '6' });
assert.strictEqual(scoreOtpLikeness(otpByNumericMode), 5, 'numeric inputmode + maxlength 6 scores 4, plus 1 for type=text');

const genericText = fakeInput({ type: 'text' });
assert.strictEqual(scoreOtpLikeness(genericText), 1, 'plain text input scores 1 (fallback signal)');

const passwordField = fakeInput({ type: 'password', autocomplete: 'one-time-code' });
assert.strictEqual(scoreOtpLikeness(passwordField), 0, 'password inputs are excluded even with matching autocomplete');

const hiddenField = fakeInput({ type: 'hidden', name: 'otp' });
assert.strictEqual(scoreOtpLikeness(hiddenField), 0, 'hidden inputs are excluded');

const disabledField = fakeInput({ type: 'text', disabled: 'true', name: 'otp' });
assert.strictEqual(scoreOtpLikeness(disabledField), 0, 'disabled inputs are excluded');

const readonlyField = fakeInput({ type: 'text', readonly: 'true', name: 'otp' });
assert.strictEqual(scoreOtpLikeness(readonlyField), 0, 'readonly inputs are excluded');

console.log('formDetection.test.js: OTP scoring OK');

// --- findOtpField ---

const fakeOtpDoc = {
  querySelectorAll: () => [
    fakeInput({ type: 'text' }),
    fakeInput({ type: 'text', autocomplete: 'one-time-code', id: 'best-match' }),
    fakeInput({ type: 'password' }),
  ],
};
const found = findOtpField(fakeOtpDoc);
assert.strictEqual(found.getAttribute('id'), 'best-match', 'findOtpField picks the highest-scoring candidate');

const fakeLoginOnlyDoc = {
  querySelectorAll: () => [
    fakeInput({ type: 'text', name: 'username' }),
    fakeInput({ type: 'password', name: 'password' }),
  ],
};
assert.strictEqual(findOtpField(fakeLoginOnlyDoc), null, 'no OTP-like field on a login-only page');

const fakeOtpOnlyDoc = {
  querySelectorAll: () => [
    fakeInput({ type: 'text', autocomplete: 'one-time-code' }),
  ],
};
assert.notStrictEqual(findOtpField(fakeOtpOnlyDoc), null, 'OTP-only page (no password field) still finds the OTP input');

console.log('formDetection.test.js: findOtpField OK');
