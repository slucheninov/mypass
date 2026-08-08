const assert = require('node:assert');
const {
  detectOtpauthLink, detectOtpauthText, isBase32Secret, detectManualSetupKey,
  detectTotpCandidateWithPriority, shouldShowTotpBanner,
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

global.__fakeQrResult = { data: 'otpauth://totp/Example:alice?secret=JBSWY3DP' };
const decodableImg = { complete: true, naturalWidth: 200, naturalHeight: 200 };
assert.strictEqual(decodeQrFromImage(decodableImg), 'otpauth://totp/Example:alice?secret=JBSWY3DP');

global.__fakeQrResult = null;
assert.strictEqual(decodeQrFromImage(decodableImg), null, 'no QR payload decodes to null');

global.__fakeCanvasThrows = true;
assert.strictEqual(decodeQrFromImage(decodableImg), null, 'CORS-tainted canvas is caught and skipped, not thrown');
global.__fakeCanvasThrows = false;

const incompleteImg = { complete: false, naturalWidth: 0, naturalHeight: 0 };
assert.strictEqual(decodeQrFromImage(incompleteImg), null, 'unloaded image is skipped');

global.__fakeQrResult = { data: 'otpauth://totp/Example:carol?secret=ABCDEFGH' };
const qrDoc = { querySelectorAll: (sel) => (sel === 'img' ? [decodableImg] : []) };
assert.strictEqual(detectQrCandidate(qrDoc), 'otpauth://totp/Example:carol?secret=ABCDEFGH');

console.log('totpDetection.test.js: QR detection OK');
