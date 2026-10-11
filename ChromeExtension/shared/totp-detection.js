// TOTP setup-key discovery: otpauth links, page text, QR images, and manual keys.
// The base32 check itself lives in shared/base32.js so the popup paste field
// accepts the same secrets this scanner finds.
//
// `totpBase32` is a namespace on purpose. base32.js declares isBase32Secret as
// a top-level function, and this file is a classic script in that same global
// scope. A const/let here with that name is a load-time SyntaxError.
//
// The browser branch names the functions directly (`isBase32Secret`, not
// `globalThis.isBase32Secret`). In a content script `globalThis` is the page,
// which does not have this extension's functions.

const totpBase32 = typeof require === 'function'
  ? require('./base32.js')
  : { isBase32Secret, normalizeBase32Candidate };

const OTPAUTH_REGEX = /otpauth:\/\/totp\/[^\s"'<>]+/i;
const MANUAL_KEY_LABEL_REGEX = /secret|manual|setup key|authenticator/i;

function detectOtpauthLink(root) {
  const scope = root || document;
  const links = Array.from(scope.querySelectorAll('a[href]'));
  for (const link of links) {
    const href = link.getAttribute('href') || '';
    const match = href.match(OTPAUTH_REGEX);
    if (match) return match[0];
  }
  return null;
}

function detectOtpauthText(root) {
  const scope = root || document;
  const body = scope.body || scope;
  if (!body) return null;
  const text = body.textContent || '';
  const match = text.match(OTPAUTH_REGEX);
  return match ? match[0] : null;
}

// A plain sliding window over every token (including surrounding label words) is unsafe:
// concatenating enough ordinary sentence words (e.g. "Your"+"manual"+"setup"+"key" ->
// "YOURMANUALSETUPKEY") can accidentally satisfy the base32 alphabet+length check before
// the real key is ever reached. Real setup keys are rendered in caps (e.g. "JBSW Y3DP EHPK
// 3PXP"), so restrict the window to maximal runs of tokens that are already all
// uppercase letters/digits as written, which excludes ordinary lowercase/mixed-case words.
const CAPS_TOKEN_REGEX = /^[A-Z0-9]+$/;

function detectManualSetupKey(root) {
  const scope = root || document;
  const body = scope.body || scope;
  if (!body) return null;
  const text = (body.textContent || '').replace(/\s+/g, ' ');
  if (!MANUAL_KEY_LABEL_REGEX.test(text)) return null;
  const tokens = text.split(' ').filter(Boolean);
  let i = 0;
  while (i < tokens.length) {
    if (!CAPS_TOKEN_REGEX.test(tokens[i])) {
      i += 1;
      continue;
    }
    let runEnd = i;
    while (runEnd < tokens.length && CAPS_TOKEN_REGEX.test(tokens[runEnd])) runEnd += 1;
    for (let start = i; start < runEnd; start += 1) {
      for (let span = 1; span <= 8 && start + span <= runEnd; span += 1) {
        const candidate = tokens.slice(start, start + span).join('');
        if (totpBase32.isBase32Secret(candidate)) {
          return totpBase32.normalizeBase32Candidate(candidate);
        }
      }
    }
    i = runEnd;
  }
  return null;
}

// Per-image QR decode memoization. detectQrCandidate re-scans every <img> on the page on
// each debounced mutation sweep (~400ms), and the jsQR decode — not the DOM walk — is the
// expensive part. Keyed on the image element itself (a WeakMap, so a removed <img> is
// simply forgotten rather than pinned in memory) plus a content key so an SPA that reuses
// the same <img> node for a different picture (a src swap) still gets a fresh decode
// instead of a stale cached result. `naturalWidth`/`naturalHeight` are folded into the key
// for the same reason: some sites redraw the same URL at a different size.
const qrDecodeCache = new WeakMap();

function qrImageCacheKey(imgEl) {
  return (imgEl.currentSrc || imgEl.src) + '|' + imgEl.naturalWidth + 'x' + imgEl.naturalHeight;
}

function decodeQrFromImage(imgEl) {
  try {
    if (!imgEl.complete || !imgEl.naturalWidth) return null;
    const key = qrImageCacheKey(imgEl);
    const cached = qrDecodeCache.get(imgEl);
    if (cached && cached.key === key) return cached.result;
    const canvas = document.createElement('canvas');
    canvas.width = imgEl.naturalWidth;
    canvas.height = imgEl.naturalHeight;
    const ctx = canvas.getContext('2d');
    ctx.drawImage(imgEl, 0, 0);
    const imageData = ctx.getImageData(0, 0, canvas.width, canvas.height);
    const result = typeof jsQR === 'function' ? jsQR(imageData.data, imageData.width, imageData.height) : null;
    const decoded = result ? result.data : null;
    qrDecodeCache.set(imgEl, { key, result: decoded });
    return decoded;
  } catch (error) {
    // getImageData throws on a CORS-tainted canvas (cross-origin image) —
    // skip rather than treat as a hard failure. Not cached: a CORS failure is about the
    // canvas/context, not the image's content, so nothing here is safe to remember.
    return null;
  }
}

function detectQrCandidate(root) {
  const scope = root || document;
  const images = Array.from(scope.querySelectorAll('img'));
  for (const img of images) {
    if ((img.naturalWidth || 0) < 40 || (img.naturalHeight || 0) < 40) continue;
    const decoded = decodeQrFromImage(img);
    if (decoded && OTPAUTH_REGEX.test(decoded)) {
      return decoded.match(OTPAUTH_REGEX)[0];
    }
  }
  return null;
}

function detectTotpCandidateWithPriority(root) {
  const link = detectOtpauthLink(root);
  if (link) return { candidate: link, priority: 1 };
  const text = detectOtpauthText(root);
  if (text) return { candidate: text, priority: 2 };
  const qr = detectQrCandidate(root);
  if (qr) return { candidate: qr, priority: 3 };
  const manual = detectManualSetupKey(root);
  if (manual) return { candidate: manual, priority: 4 };
  return null;
}

function shouldShowTotpBanner(detected, state) {
  if (!detected) return false;
  if (state.vaultLocked) return false;
  if (!state.totpBannerDismissed) return true;
  return detected.priority < state.totpBannerDismissed.priority;
}

function forgetDecodedQr(imgEl) {
  if (imgEl) qrDecodeCache.delete(imgEl);
}

var mypassTotpDetection = {
  detectOtpauthLink,
  detectOtpauthText,
  detectManualSetupKey,
  decodeQrFromImage,
  detectQrCandidate,
  detectTotpCandidateWithPriority,
  shouldShowTotpBanner,
  forgetDecodedQr,
};

if (typeof module !== 'undefined') {
  module.exports = {
    detectOtpauthLink,
    detectOtpauthText,
    detectManualSetupKey,
    decodeQrFromImage,
    detectQrCandidate,
    detectTotpCandidateWithPriority,
    shouldShowTotpBanner,
    forgetDecodedQr,
    isBase32Secret: totpBase32.isBase32Secret,
  };
}
