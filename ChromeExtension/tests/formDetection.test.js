const assert = require('node:assert');
const path = require('node:path');
const { scoreUsernameLikeness, findBestUsernameInput, hostnameMatches } = require(path.join(__dirname, '..', 'content.js'));

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
