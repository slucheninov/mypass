const assert = require('node:assert');
const {
  detectOtpauthLink, detectOtpauthText, isBase32Secret, detectManualSetupKey,
  detectTotpCandidateWithPriority, shouldShowTotpBanner, routeBannerCredentialsResponse,
  buildTotpCandidateQueryResponse,
} = require('../content.js');

function fakeAnchor(href) {
  return { getAttribute: (name) => (name === 'href' ? href : null) };
}

function fakeDoc({ links = [], bodyText = '' }) {
  return {
    querySelectorAll: (selector) => (selector === 'a[href]' ? links : []),
    body: { textContent: bodyText },
  };
}

// detectOtpauthLink
const linkDoc = fakeDoc({ links: [fakeAnchor('https://example.com'), fakeAnchor('otpauth://totp/Example:alice?secret=JBSWY3DP')] });
assert.strictEqual(detectOtpauthLink(linkDoc), 'otpauth://totp/Example:alice?secret=JBSWY3DP');
assert.strictEqual(detectOtpauthLink(fakeDoc({ links: [fakeAnchor('https://example.com')] })), null);

// detectOtpauthText
const textDoc = fakeDoc({ bodyText: 'Scan this: otpauth://totp/Example:bob?secret=ABCDEFGH please' });
assert.strictEqual(detectOtpauthText(textDoc), 'otpauth://totp/Example:bob?secret=ABCDEFGH');
assert.strictEqual(detectOtpauthText(fakeDoc({ bodyText: 'no link here' })), null);

// isBase32Secret
assert.strictEqual(isBase32Secret('JBSWY3DPEHPK3PXP'), true);
assert.strictEqual(isBase32Secret('jbswy3dp ehpk3pxp'), true, 'lowercase and spaces normalize');
assert.strictEqual(isBase32Secret('short'), false);
assert.strictEqual(isBase32Secret('has1and9digits'), false);

// detectManualSetupKey
const manualDoc = fakeDoc({ bodyText: 'Your manual setup key is JBSW Y3DP EHPK 3PXP — enter it in your app' });
assert.strictEqual(detectManualSetupKey(manualDoc), 'JBSWY3DPEHPK3PXP');
assert.strictEqual(detectManualSetupKey(fakeDoc({ bodyText: 'JBSWY3DPEHPK3PXP with no label nearby' })), null, 'requires a label keyword present');

// priority ordering
const combinedDoc = fakeDoc({
  links: [fakeAnchor('otpauth://totp/Example:alice?secret=JBSWY3DP')],
  bodyText: 'manual setup key JBSWY3DPEHPK3PXP',
});
assert.strictEqual(detectTotpCandidateWithPriority(combinedDoc).priority, 1, 'otpauth link wins over manual key');

// shouldShowTotpBanner
assert.strictEqual(shouldShowTotpBanner(null, {}), false);
assert.strictEqual(shouldShowTotpBanner({ candidate: 'x', priority: 1 }, { vaultLocked: true }), false);
assert.strictEqual(shouldShowTotpBanner({ candidate: 'x', priority: 1 }, { vaultLocked: false, totpBannerDismissed: null }), true);
assert.strictEqual(shouldShowTotpBanner({ candidate: 'x', priority: 4 }, { vaultLocked: false, totpBannerDismissed: { priority: 1 } }), false, 'weaker candidate stays suppressed');
assert.strictEqual(shouldShowTotpBanner({ candidate: 'x', priority: 1 }, { vaultLocked: false, totpBannerDismissed: { priority: 4 } }), true, 'stronger candidate re-shows');

// dismissal stores the ACTUAL priority of the dismissed candidate (not a hardcoded weakest
// priority) — a priority-1 dismissal must suppress a subsequent priority-1 candidate too,
// per the plan's "session-dismiss suppresses only equal-or-weaker-priority candidates" rule.
assert.strictEqual(shouldShowTotpBanner({ candidate: 'x', priority: 1 }, { vaultLocked: false, totpBannerDismissed: { priority: 1 } }), false, 'dismissed priority-1 candidate stays suppressed for an equal-priority re-detection');

console.log('totpDetection.test.js: OK');

// --- routeBannerCredentialsResponse: gates the Save-banner's proposeSaveTotp send on the
// actual getCredentials response (Finding 1), and records the dismissed priority on every
// Save click so the MutationObserver's redetection of the banner.remove() mutation doesn't
// re-show the same banner (Finding 2). ---

(() => {
  const state = { vaultLocked: false, totpBannerDismissed: null };
  const sent = [];
  routeBannerCredentialsResponse(
    { type: 'locked' }, 'https://example.com', 'JBSWY3DP', state, 1,
    (message) => sent.push(message)
  );
  assert.strictEqual(sent.length, 0, 'locked response must not send proposeSaveTotp');
  assert.strictEqual(state.vaultLocked, true, 'locked response marks the vault locked');
  assert.deepStrictEqual(state.totpBannerDismissed, { priority: 1 }, 'Save click records the dismissed priority even when locked');
})();

(() => {
  const state = { vaultLocked: true, totpBannerDismissed: null };
  const sent = [];
  routeBannerCredentialsResponse(
    { type: 'credentialList', credentials: [] }, 'https://example.com', 'JBSWY3DP', state, 2,
    (message) => sent.push(message)
  );
  assert.strictEqual(sent.length, 1, 'a real credentialList response with zero matches still proposes a save');
  assert.strictEqual(sent[0].type, 'proposeSaveTotp');
  assert.strictEqual(sent[0].entryId, undefined, 'zero matches sends no entryId');
  assert.strictEqual(state.vaultLocked, false, 'credentialList response clears vaultLocked');
  assert.deepStrictEqual(state.totpBannerDismissed, { priority: 2 }, 'Save click records the dismissed priority');
})();

(() => {
  const state = { vaultLocked: false, totpBannerDismissed: null };
  const sent = [];
  routeBannerCredentialsResponse(
    { type: 'pairingRequired' }, 'https://example.com', 'JBSWY3DP', state, 1,
    (message) => sent.push(message)
  );
  assert.strictEqual(sent.length, 0, 'pairingRequired must not send proposeSaveTotp');
  assert.strictEqual(state.vaultLocked, false, 'pairingRequired does not change vaultLocked');
})();

console.log('totpDetection.test.js: routeBannerCredentialsResponse gating OK');

// --- buildTotpCandidateQueryResponse: what the content script's onMessage listener
// answers a popup's `{ type: 'queryTotpCandidate' }` request with. The listener itself
// lives inside content.js's browser-only wiring guard (chrome/document both defined) and
// isn't reachable from this require (chrome/document are undefined at this point in the
// file), so this exercises the extracted response-building logic directly — same pattern
// as routeBannerCredentialsResponse above. ---

assert.deepStrictEqual(
  buildTotpCandidateQueryResponse(combinedDoc),
  detectTotpCandidateWithPriority(combinedDoc),
  'queryTotpCandidate response mirrors detectTotpCandidateWithPriority for a page with a candidate'
);
assert.strictEqual(
  buildTotpCandidateQueryResponse(fakeDoc({})),
  null,
  'queryTotpCandidate response is null for a page with no TOTP candidate'
);

console.log('totpDetection.test.js: buildTotpCandidateQueryResponse OK');

// --- QR detection ---

function fakeCanvasContext(imageDataResult) {
  return { drawImage: () => {}, getImageData: () => imageDataResult };
}

function fakeCanvas(imageDataResult, shouldThrow) {
  return {
    width: 0,
    height: 0,
    getContext: () => {
      if (shouldThrow) throw new Error('SecurityError: tainted canvas');
      return fakeCanvasContext(imageDataResult);
    },
  };
}

global.document = global.document || {};
global.document.createElement = (tag) => (tag === 'canvas' ? fakeCanvas({ data: [], width: 1, height: 1 }, global.__fakeCanvasThrows) : {});
global.jsQR = () => global.__fakeQrResult || null;

const { decodeQrFromImage, detectQrCandidate } = require('../content.js');

// Each assertion below uses its own <img> (distinct `src`) rather than reusing one object:
// decodeQrFromImage now memoizes per image (see the dedicated memoization test further down),
// so re-using the same element/src pair here would return the FIRST call's cached result
// instead of exercising the fresh-decode path each assertion is actually testing.
global.__fakeQrResult = { data: 'otpauth://totp/Example:alice?secret=JBSWY3DP' };
const decodableImg = { complete: true, naturalWidth: 200, naturalHeight: 200, src: 'https://example.com/qr-alice.png' };
assert.strictEqual(decodeQrFromImage(decodableImg), 'otpauth://totp/Example:alice?secret=JBSWY3DP');

global.__fakeQrResult = null;
const noPayloadImg = { complete: true, naturalWidth: 200, naturalHeight: 200, src: 'https://example.com/qr-no-payload.png' };
assert.strictEqual(decodeQrFromImage(noPayloadImg), null, 'no QR payload decodes to null');

global.__fakeCanvasThrows = true;
const taintedImg = { complete: true, naturalWidth: 200, naturalHeight: 200, src: 'https://example.com/qr-tainted.png' };
assert.strictEqual(decodeQrFromImage(taintedImg), null, 'CORS-tainted canvas is caught and skipped, not thrown');
global.__fakeCanvasThrows = false;

const incompleteImg = { complete: false, naturalWidth: 0, naturalHeight: 0 };
assert.strictEqual(decodeQrFromImage(incompleteImg), null, 'unloaded image is skipped');

global.__fakeQrResult = { data: 'otpauth://totp/Example:carol?secret=ABCDEFGH' };
const carolImg = { complete: true, naturalWidth: 200, naturalHeight: 200, src: 'https://example.com/qr-carol.png' };
const qrDoc = { querySelectorAll: (sel) => (sel === 'img' ? [carolImg] : []) };
assert.strictEqual(detectQrCandidate(qrDoc), 'otpauth://totp/Example:carol?secret=ABCDEFGH');

console.log('totpDetection.test.js: QR detection OK');
