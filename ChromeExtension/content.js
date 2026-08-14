(function () {
  // Minimum OTP field score threshold for selection. The weakest intentional OTP signal
  // (inputmode=numeric + maxlength ∈ [6,7,8]) scores 4. A bare type=text input scores 1
  // and must not be selected on a login-only page. Score >= 4 ensures only deliberate OTP
  // candidates are picked.
  const MIN_OTP_FIELD_SCORE = 4;

  function scoreUsernameLikeness(input) {
    let score = 0;
    const autocomplete = (input.getAttribute('autocomplete') || '').toLowerCase();
    const name = (input.getAttribute('name') || '').toLowerCase();
    const id = (input.getAttribute('id') || '').toLowerCase();
    const type = (input.getAttribute('type') || 'text').toLowerCase();

    if (autocomplete.includes('username')) score += 5;
    if (type === 'email') score += 3;
    if (/user|login|email/.test(name)) score += 2;
    if (/user|login|email/.test(id)) score += 2;
    if (type === 'text' || type === 'email') score += 1;
    return score;
  }

  function findBestUsernameInput(candidates) {
    if (candidates.length === 0) return null;
    let best = candidates[0];
    let bestScore = scoreUsernameLikeness(best);
    for (let i = 1; i < candidates.length; i++) {
      const score = scoreUsernameLikeness(candidates[i]);
      if (score > bestScore) {
        best = candidates[i];
        bestScore = score;
      }
    }
    return best;
  }

  function scoreOtpLikeness(input) {
    if (!input) return 0;
    const type = (input.getAttribute('type') || 'text').toLowerCase();
    const isDisabled = input.getAttribute('disabled') !== null || input.disabled === true;
    const isReadOnly = input.getAttribute('readonly') !== null || input.readOnly === true;
    if (type === 'password' || type === 'hidden' || isDisabled || isReadOnly) {
      return 0;
    }

    let score = 0;
    const autocomplete = (input.getAttribute('autocomplete') || '').toLowerCase();
    if (autocomplete === 'one-time-code') {
      // autocomplete=one-time-code is a decisive browser signal for OTP fields, not stacked
      // with other bonuses. Scores 10 alone, not 11 (avoiding +1 type bonus).
      return 10;
    }

    const nameOrId = `${input.getAttribute('name') || ''} ${input.getAttribute('id') || ''}`.toLowerCase();
    if (/otp|totp|2fa|two.?factor|verification.?code|auth.?code|security.?code/.test(nameOrId)) {
      score += 6;
    }

    const inputMode = (input.getAttribute('inputmode') || '').toLowerCase();
    const maxLength = parseInt(input.getAttribute('maxlength') || '', 10);
    if (inputMode === 'numeric' && [6, 7, 8].includes(maxLength)) {
      score += 4;
    }

    if (type === 'tel' || type === 'text') {
      score += 1;
    }

    return score;
  }

  function findOtpField(root) {
    const scope = root || document;
    const candidates = Array.from(scope.querySelectorAll('input, textarea'));
    let best = null;
    let bestScore = 0;
    for (const candidate of candidates) {
      if (candidate.offsetParent === null) continue;
      const score = scoreOtpLikeness(candidate);
      if (score > bestScore) {
        bestScore = score;
        best = candidate;
      }
    }
    return bestScore >= MIN_OTP_FIELD_SCORE ? best : null;
  }

  function isFieldVisible(input) {
    if (!input) return false;
    if (input.offsetParent === null) return false;
    const disabled = input.getAttribute('disabled') !== null || input.disabled === true;
    const readOnly = input.getAttribute('readonly') !== null || input.readOnly === true;
    return !disabled && !readOnly;
  }

  // Returns every field the inline icon may attach to. Deliberately looser than the old
  // findLoginForm: a password field no longer has to sit inside a <form>, and a username
  // field is emitted even when no password field exists, so identifier-first login screens
  // (username on step 1, password on step 2) are covered.
  function findFillableFields(root) {
    const scope = root || document;
    const fields = [];

    const passwords = Array.from(scope.querySelectorAll('input[type="password"]')).filter(isFieldVisible);
    for (const password of passwords) {
      fields.push({ input: password, kind: 'password' });
    }

    const formScope = (passwords[0] && passwords[0].closest && passwords[0].closest('form')) || scope;
    const usernameCandidates = Array.from(
      formScope.querySelectorAll('input[type="text"], input[type="email"], input[autocomplete*="username"]')
    ).filter(isFieldVisible);
    const username = findBestUsernameInput(usernameCandidates);
    if (username) {
      fields.push({ input: username, kind: 'username' });
    }

    // An OTP input is type=text or type=tel, so it also satisfies the username selector
    // above and can win findBestUsernameInput on a 2FA-only page. Classify it as otp and
    // drop the duplicate rather than letting one element carry two icons.
    const otp = findOtpField(scope);
    if (otp) {
      const duplicate = fields.findIndex((field) => field.input === otp);
      if (duplicate >= 0) fields.splice(duplicate, 1);
      fields.push({ input: otp, kind: 'otp' });
    }

    return fields;
  }

  // Kept for applyFill's existing contract. Rebuilt on findFillableFields so the two
  // cannot drift apart. `form` is now nullable: a password field outside any <form> used
  // to make this return null, which meant applyFill silently did nothing on such pages.
  function findLoginForm() {
    const fields = findFillableFields(document);
    const passwordField = fields.find((field) => field.kind === 'password');
    if (!passwordField) return null;
    const usernameField = fields.find((field) => field.kind === 'username');
    const form = passwordField.input.closest ? passwordField.input.closest('form') : null;
    return {
      form,
      passwordInput: passwordField.input,
      usernameInput: usernameField ? usernameField.input : null,
    };
  }

  const OTPAUTH_REGEX = /otpauth:\/\/totp\/[^\s"'<>]+/i;
  const BASE32_REGEX = /^[A-Z2-7]{16,128}$/;
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

  function normalizeBase32Candidate(raw) {
    return (raw || '').replace(/\s+/g, '').toUpperCase();
  }

  function isBase32Secret(candidate) {
    return BASE32_REGEX.test(normalizeBase32Candidate(candidate));
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
          if (isBase32Secret(candidate)) {
            return normalizeBase32Candidate(candidate);
          }
        }
      }
      i = runEnd;
    }
    return null;
  }

  function decodeQrFromImage(imgEl) {
    try {
      if (!imgEl.complete || !imgEl.naturalWidth) return null;
      const canvas = document.createElement('canvas');
      canvas.width = imgEl.naturalWidth;
      canvas.height = imgEl.naturalHeight;
      const ctx = canvas.getContext('2d');
      ctx.drawImage(imgEl, 0, 0);
      const imageData = ctx.getImageData(0, 0, canvas.width, canvas.height);
      const result = typeof jsQR === 'function' ? jsQR(imageData.data, imageData.width, imageData.height) : null;
      return result ? result.data : null;
    } catch (error) {
      // getImageData throws on a CORS-tainted canvas (cross-origin image) —
      // skip rather than treat as a hard failure.
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

  // Mirrors popup.js's classifyGetCredentialsResponse — kept as a separate local copy
  // since content.js and popup.js are independent scripts with no shared module.
  function classifyGetCredentialsResponse(response) {
    if (!response || response.type === 'error') return 'error';
    if (response.type === 'locked') return 'locked';
    if (response.type === 'pairingRequired') return 'pairingRequired';
    if (response.type === 'credentialList') return 'credentialList';
    return 'unknown';
  }

  // Panel state is a function of the connection state and the field kind, never of which
  // element was clicked. Extracted as a pure function for the same reason Stage 6 extracted
  // choosePasskeyPanel: routing is the part worth testing, and a DOM makes it untestable.
  function chooseInlinePanel(response, fieldKind) {
    const kind = classifyGetCredentialsResponse(response);
    if (kind === 'locked') return { panel: 'locked', entries: [] };
    if (kind === 'pairingRequired') return { panel: 'pairingRequired', entries: [] };
    if (kind !== 'credentialList') return { panel: 'unavailable', entries: [] };

    const all = response.credentials || [];
    const entries = fieldKind === 'otp' ? all.filter((entry) => entry.hasTotp) : all;
    return entries.length === 0 ? { panel: 'empty', entries: [] } : { panel: 'entries', entries };
  }

  // The inline icon is a control the PAGE can see and dispatch events at, unlike the popup.
  // Every activation path therefore requires a user-generated event. This is not defence in
  // depth: relayFillToActiveTab in background.js resolves its target with
  // chrome.tabs.query({active: true}) rather than sender.tab.id, which is only sound because
  // a trusted click implies the tab is the one the user is looking at.
  function isTrustedActivation(event) {
    return !!(event && event.isTrusted === true);
  }

  function handleIconActivate(event, requestPanel) {
    if (!isTrustedActivation(event)) return false;
    requestPanel();
    return true;
  }

  // Sends the identical message popup.js:617 sends. The content script never learns the
  // secret: background.js resolves it natively and delivers it straight back as applyFill.
  function handleEntrySelect(event, entryId, url, sendMessage) {
    if (!isTrustedActivation(event)) return false;
    sendMessage({ type: 'fillCredential', id: entryId, url });
    return true;
  }

  // Gates the Save-banner's proposeSaveTotp send on the actual getCredentials response
  // instead of treating locked/pairingRequired/error as "zero matches" (which used to fire
  // a blind proposal even while locked or unpaired). Same trust model as the password-save
  // flow and popup.js's Add-2FA gating: only a real credentialList response may route to a
  // proposal or the multi-match picker; anything else neither sends proposeSaveTotp nor
  // touches storage. Also records this click's dismissal (same as the x button) up front,
  // independent of the async response, since banner.remove() in the caller is itself a
  // childList mutation the MutationObserver will redetect ~400ms later — without this, the
  // still-present candidate would re-show the banner and a second Save would duplicate the
  // proposal.
  function routeBannerCredentialsResponse(response, url, otpauthOrSecret, state, priority, sendMessage) {
    state.totpBannerDismissed = { priority };

    const kind = classifyGetCredentialsResponse(response);
    if (kind === 'locked') {
      state.vaultLocked = true;
      return;
    }
    if (kind !== 'credentialList') {
      // pairingRequired / error / unknown: never fire a blind save proposal.
      return;
    }
    state.vaultLocked = false;
    const credentials = response.credentials;
    if (credentials.length === 0) {
      sendMessage({ type: 'proposeSaveTotp', url, otpauthOrSecret });
    } else if (credentials.length === 1) {
      sendMessage({ type: 'proposeSaveTotp', url, otpauthOrSecret, entryId: credentials[0].id });
    } else {
      chrome.storage.session.set({ pendingTotpCandidate: { url, otpauthOrSecret } }, () => {
        sendMessage({ type: 'openPopupForTotpPicker' });
      });
    }
  }

  // What the content script answers a popup's `{ type: 'queryTotpCandidate' }` request
  // with — the current page's strongest TOTP candidate (or null), so the popup's Add-2FA
  // section can prefill itself and reveal only when there is something to act on. Extracted
  // as its own (unguarded, exported) function — like routeBannerCredentialsResponse above —
  // since the chrome.runtime.onMessage listener that calls it lives inside the browser-only
  // wiring guard below and isn't reachable from tests without a full DOM/chrome stub.
  function buildTotpCandidateQueryResponse(root) {
    return detectTotpCandidateWithPriority(root);
  }

  // `priority` is the detected candidate's own priority (1=link, 2=text, 3=QR, 4=manual key),
  // threaded in from the caller's detection result. On
  // dismiss we store that ACTUAL priority — not a hardcoded weakest value — so that
  // `shouldShowTotpBanner`'s "session-dismiss suppresses only equal-or-weaker-priority
  // candidates" rule holds even when the dismissed candidate was already the strongest kind.
  function showTotpSaveBanner(url, otpauthOrSecret, state, priority) {
    if (state.totpBannerShown) return;
    state.totpBannerShown = true;

    const banner = document.createElement('div');
    banner.style.cssText =
      'position:fixed;bottom:16px;right:16px;z-index:2147483647;background:#134e4a;' +
      'color:#f0fdfa;padding:12px 16px;border-radius:8px;font-family:sans-serif;' +
      'font-size:13px;box-shadow:0 2px 8px rgba(0,0,0,0.3);display:flex;align-items:center;gap:8px;';
    banner.textContent = 'Save 2FA to MyPass?';

    const saveButton = document.createElement('button');
    saveButton.textContent = 'Save';
    saveButton.style.cssText = 'margin-left:8px;cursor:pointer;';
    saveButton.addEventListener('click', () => {
      chrome.runtime.sendMessage({ type: 'getCredentials', url }, (response) => {
        routeBannerCredentialsResponse(
          response, url, otpauthOrSecret, state, priority,
          (message) => chrome.runtime.sendMessage(message)
        );
      });
      banner.remove();
      state.totpBannerShown = false;
    });

    const closeButton = document.createElement('button');
    closeButton.textContent = '×';
    closeButton.style.cssText = 'margin-left:8px;cursor:pointer;background:none;border:none;color:inherit;';
    closeButton.addEventListener('click', () => {
      banner.remove();
      state.totpBannerShown = false;
      state.totpBannerDismissed = { priority };
    });

    banner.appendChild(saveButton);
    banner.appendChild(closeButton);
    document.body.appendChild(banner);
  }

  function observeTotpCandidates(state) {
    let debounceTimer = null;
    const observer = new MutationObserver(() => {
      if (debounceTimer) clearTimeout(debounceTimer);
      debounceTimer = setTimeout(() => {
        const detected = detectTotpCandidateWithPriority(document);
        if (shouldShowTotpBanner(detected, state)) {
          showTotpSaveBanner(location.href, detected.candidate, state, detected.priority);
        }
      }, 400);
    });
    observer.observe(document.body, { childList: true, subtree: true });
    return observer;
  }

  function hostnameMatches(messageUrl, pageUrl) {
    if (!messageUrl) return false;
    try {
      const messageHost = new URL(messageUrl).hostname.toLowerCase();
      const pageHost = new URL(pageUrl).hostname.toLowerCase();
      return messageHost === pageHost;
    } catch (e) {
      return false;
    }
  }

  function setNativeValue(input, value) {
    input.value = value;
    input.dispatchEvent(new Event('input', { bubbles: true }));
    input.dispatchEvent(new Event('change', { bubbles: true }));
  }

  function showSaveBanner(url, username, password, state) {
    if (state.bannerShown) return;
    state.bannerShown = true;

    const banner = document.createElement('div');
    banner.style.cssText =
      'position:fixed;bottom:16px;right:16px;z-index:2147483647;background:#1f2937;' +
      'color:#f9fafb;padding:12px 16px;border-radius:8px;font-family:sans-serif;' +
      'font-size:13px;box-shadow:0 2px 8px rgba(0,0,0,0.3);display:flex;align-items:center;gap:8px;';
    banner.textContent = 'Save password to MyPass?';

    const saveButton = document.createElement('button');
    saveButton.textContent = 'Save';
    saveButton.style.cssText = 'margin-left:8px;cursor:pointer;';
    saveButton.addEventListener('click', () => {
      chrome.runtime.sendMessage({ type: 'proposeSaveLogin', url, username, password });
      banner.remove();
      state.bannerShown = false;
    });

    const closeButton = document.createElement('button');
    closeButton.textContent = '×';
    closeButton.style.cssText = 'margin-left:8px;cursor:pointer;background:none;border:none;color:inherit;';
    closeButton.addEventListener('click', () => {
      banner.remove();
      state.bannerShown = false;
    });

    banner.appendChild(saveButton);
    banner.appendChild(closeButton);
    document.body.appendChild(banner);
  }

  if (typeof chrome !== 'undefined' && typeof document !== 'undefined') {
    const state = {
      lastCredentialList: [],
      bannerShown: false,
      vaultLocked: false,
      totpBannerShown: false,
      totpBannerDismissed: null,
    };

    function requestCredentials() {
      chrome.runtime.sendMessage({ type: 'getCredentials', url: location.href }, (response) => {
        // Track lock-state separately from "empty list": a `locked` response
        // also carries no credentials, but is NOT the same as "genuinely no
        // matches for this site" — conflating the two lets the save-banner
        // logic below offer to save a duplicate when the vault was simply
        // locked at page-load time.
        state.vaultLocked = !!(response && (response.type === 'locked' || response.type === 'pairingRequired'));
        state.lastCredentialList = (response && response.type === 'credentialList') ? response.credentials : [];
      });
    }

    function attachSubmitListener(loginForm) {
      if (!loginForm.form) return;
      loginForm.form.addEventListener('submit', () => {
        if (!state.vaultLocked && !state.totpBannerShown && state.lastCredentialList.length === 0) {
          const username = loginForm.usernameInput ? loginForm.usernameInput.value : '';
          const password = loginForm.passwordInput.value;
          if (password) {
            showSaveBanner(location.href, username, password, state);
          }
        }
      });
    }

    chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
      if (message.type === 'queryTotpCandidate') {
        sendResponse(buildTotpCandidateQueryResponse(document));
        return;
      }
      if (message.type === 'applyFill') {
        if (!hostnameMatches(message.url, location.href)) {
          console.warn('MyPass: applyFill rejected — message URL does not match the current page hostname');
          return;
        }
        const loginForm = findLoginForm();
        if (loginForm) {
          if (loginForm.usernameInput && message.username) {
            setNativeValue(loginForm.usernameInput, message.username);
          }
          if (loginForm.passwordInput && message.password) {
            setNativeValue(loginForm.passwordInput, message.password);
          }
        }
        if (message.totp) {
          const otpField = findOtpField();
          if (otpField) {
            setNativeValue(otpField, message.totp);
          }
        }
      }
    });

    // Detect the form and request the current domain's credential list on
    // load, but NEVER auto-fill here — filling only happens in response to
    // an explicit "applyFill" message triggered by a popup click (Task 12).
    const loginForm = findLoginForm();
    if (loginForm) {
      requestCredentials();
      attachSubmitListener(loginForm);
    }

    const detected = detectTotpCandidateWithPriority(document);
    if (shouldShowTotpBanner(detected, state)) {
      showTotpSaveBanner(location.href, detected.candidate, state, detected.priority);
    }
    observeTotpCandidates(state);
  }

  if (typeof module !== 'undefined') {
    module.exports = {
      scoreUsernameLikeness, findBestUsernameInput, hostnameMatches, scoreOtpLikeness, findOtpField,
      isFieldVisible, findFillableFields, findLoginForm,
      detectOtpauthLink, detectOtpauthText, isBase32Secret, detectManualSetupKey,
      decodeQrFromImage, detectQrCandidate,
      detectTotpCandidateWithPriority, shouldShowTotpBanner,
      classifyGetCredentialsResponse, chooseInlinePanel, routeBannerCredentialsResponse,
      isTrustedActivation, handleIconActivate, handleEntrySelect,
      buildTotpCandidateQueryResponse,
    };
  }
})();
