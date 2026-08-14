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

  // onMutation defaults to a no-op so this stays callable from tests without a DOM;
  // the browser-only wiring below passes attachIcons so newly-inserted fields get an
  // icon on the same debounce that re-checks for TOTP candidates.
  function observeTotpCandidates(state, onMutation) {
    const notifyMutation = typeof onMutation === 'function' ? onMutation : () => {};
    let debounceTimer = null;
    const observer = new MutationObserver(() => {
      if (debounceTimer) clearTimeout(debounceTimer);
      debounceTimer = setTimeout(() => {
        notifyMutation();
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

    const attachedIcons = new Map();
    let openPanel = null;
    let syncScheduled = false;

    function syncIconPositions() {
      syncScheduled = false;
      attachedIcons.forEach((record, input) => {
        const rect = input.getBoundingClientRect();
        const offscreen = rect.bottom < 0 || rect.top > window.innerHeight || rect.width === 0;
        // important for the same reason as buildIconHost/positionHostToField: a plain
        // assignment here would silently drop the !important flag those set initially.
        record.host.style.setProperty('display', offscreen ? 'none' : 'block', 'important');
        if (!offscreen) positionHostToField(record.host, rect, window);
      });
    }

    function scheduleSync() {
      if (syncScheduled) return;
      syncScheduled = true;
      window.requestAnimationFrame(syncIconPositions);
    }

    function attachIconTo(input, kind) {
      if (attachedIcons.has(input)) return;
      const { host, button } = buildIconHost(document);
      button.addEventListener('click', (event) => {
        handleIconActivate(event, () => togglePanel(input, kind));
      });
      document.body.appendChild(host);
      attachedIcons.set(input, { host, kind });

      const resizeObserver = new ResizeObserver(scheduleSync);
      resizeObserver.observe(input);
      attachedIcons.get(input).resizeObserver = resizeObserver;
      scheduleSync();
    }

    function attachIcons() {
      for (const field of findFillableFields(document)) {
        attachIconTo(field.input, field.kind);
      }
    }

    function closePanel() {
      if (!openPanel) return;
      openPanel.host.remove();
      openPanel = null;
    }

    function togglePanel(input, kind) {
      if (openPanel && openPanel.input === input) {
        closePanel();
        return;
      }
      closePanel();
      // Always re-ask rather than trusting state.lastCredentialList: the vault may have
      // been unlocked since page load, and a stale locked panel is the exact failure
      // Stage 3 shipped and had to fix.
      chrome.runtime.sendMessage({ type: 'getCredentials', url: location.href }, (response) => {
        const routed = chooseInlinePanel(response, kind);
        // Handle for manual verification only (RUN.md) — never used as logic. Identity
        // against `host` is what closePanel/isOwnHost actually rely on. The panel is a
        // list, not a button, so it gets the bare scaffolding — no icon glyph inside it.
        const { host, shadow } = buildShadowHost(document, 'data-mypass-inline-panel');
        const content = buildPanelContent(document, routed, {
          onSelect: (event, entryId) => {
            if (handleEntrySelect(event, entryId, location.href, (m) => chrome.runtime.sendMessage(m))) {
              closePanel();
            }
          },
          onUnlock: (event) => {
            if (isTrustedActivation(event)) {
              chrome.runtime.sendMessage({ type: 'requestUnlock' });
              closePanel();
            }
          },
        });
        shadow.appendChild(content.root);
        const rect = input.getBoundingClientRect();
        host.style.setProperty('position', 'absolute', 'important');
        host.style.setProperty('top', String(rect.bottom + window.scrollY + 4) + 'px', 'important');
        host.style.setProperty('left', String(rect.left + window.scrollX) + 'px', 'important');
        document.body.appendChild(host);
        openPanel = { host, input };
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
    attachIcons();

    window.addEventListener('scroll', scheduleSync, { capture: true, passive: true });
    window.addEventListener('resize', scheduleSync, { passive: true });

    function isOwnHost(node) {
      if (!node) return false;
      if (openPanel && node === openPanel.host) return true;
      for (const record of attachedIcons.values()) {
        if (node === record.host) return true;
      }
      return false;
    }

    document.addEventListener('click', (event) => {
      if (!openPanel) return;
      // Our own control: let its own handler decide (the icon toggles, a row fills).
      // Identity, not the marker attribute — a page can forge the attribute on its
      // own elements, but it cannot forge a reference to a node we created. This runs
      // in the capture phase (before the icon/panel's own bubble-phase handlers), so
      // returning early here — rather than closing — is what keeps toggle-to-close
      // working: the icon's own click handler still gets to run and close the panel.
      if (isOwnHost(event.target)) return;
      closePanel();
    }, true);
    document.addEventListener('keydown', (event) => {
      if (event.key === 'Escape') closePanel();
    }, true);

    const detected = detectTotpCandidateWithPriority(document);
    if (shouldShowTotpBanner(detected, state)) {
      showTotpSaveBanner(location.href, detected.candidate, state, detected.priority);
    }
    observeTotpCandidates(state, attachIcons);
  }

  // Built from DOM nodes rather than an innerHTML string: sites that enforce the
  // require-trusted-types-for 'script' CSP directive throw on any innerHTML assignment,
  // and those are exactly the sites this feature most needs to work on.
  const SVG_NS = 'http://www.w3.org/2000/svg';
  const KEY_ICON_PATH_D =
    'M10.5 1a4.5 4.5 0 0 0-4.3 5.9L1 12.1V15h2.9l.6-.6v-1.3h1.3l.9-.9v-1.3h1.3l1.2-1.2A4.5 4.5 0 1 0 10.5 1zm1.4 3.6a1 1 0 1 1 1.4-1.4 1 1 0 0 1-1.4 1.4z';

  function buildKeyGlyph(doc) {
    const svg = doc.createElementNS(SVG_NS, 'svg');
    svg.setAttribute('viewBox', '0 0 16 16');
    svg.setAttribute('width', '14');
    svg.setAttribute('height', '14');
    svg.setAttribute('aria-hidden', 'true');
    const path = doc.createElementNS(SVG_NS, 'path');
    path.setAttribute('fill', 'currentColor');
    path.setAttribute('d', KEY_ICON_PATH_D);
    svg.appendChild(path);
    return svg;
  }

  const ICON_HOST_STYLE =
    ':host{all:initial}' +
    'button{all:unset;cursor:pointer;display:flex;align-items:center;justify-content:center;' +
    'width:20px;height:20px;border-radius:4px;color:#6b7280;opacity:0.65;}' +
    'button:hover,button:focus-visible{opacity:1;background:rgba(127,127,127,0.15);}';

  // The shared scaffolding behind both surfaces: a light-DOM host carrying our marker,
  // an isolating closed shadow root, and the layout styles marked important so a page
  // rule cannot hide or move the control. The icon adds a button on top of this; the
  // panel adds its rows. Neither should carry the other's contents.
  function buildShadowHost(documentRef, markerAttribute) {
    const doc = documentRef || document;
    const host = doc.createElement('div');
    // z-index one below the banners' 2147483647 so a save banner still wins if they overlap.
    host.setAttribute(markerAttribute, '');
    // setProperty(..., 'important') because a page's own `!important` CSS rule (e.g.
    // [data-mypass-inline-icon]{display:none!important}) would otherwise beat a plain
    // inline style and could hide or mislocate the control.
    host.style.setProperty('position', 'absolute', 'important');
    host.style.setProperty('z-index', '2147483646', 'important');
    host.style.setProperty('display', 'block', 'important');
    host.style.pointerEvents = 'auto';

    const shadow = host.attachShadow({ mode: 'closed' });
    const style = doc.createElement('style');
    style.textContent = ICON_HOST_STYLE;
    shadow.appendChild(style);

    return { host, shadow };
  }

  function buildIconHost(documentRef) {
    const doc = documentRef || document;
    const { host, shadow } = buildShadowHost(doc, 'data-mypass-inline-icon');
    const button = doc.createElement('button');
    button.setAttribute('type', 'button');
    button.setAttribute('aria-label', 'Fill from MyPass');
    button.appendChild(buildKeyGlyph(doc));
    shadow.appendChild(button);
    return { host, shadow, button };
  }

  // Writes to the overlay host only. The page's own input is never given padding, a
  // wrapper, or any attribute — that is the whole reason for the overlay approach.
  function positionHostToField(host, rect, viewport) {
    const scrollX = viewport && typeof viewport.scrollX === 'number' ? viewport.scrollX : 0;
    const scrollY = viewport && typeof viewport.scrollY === 'number' ? viewport.scrollY : 0;
    const size = 20;
    const inset = 6;
    // important: see the comment in buildIconHost — same page-CSS threat applies here.
    host.style.setProperty('position', 'absolute', 'important');
    host.style.setProperty('top', String(rect.top + scrollY + (rect.height - size) / 2) + 'px', 'important');
    host.style.setProperty('left', String(rect.left + scrollX + rect.width - size - inset) + 'px', 'important');
  }

  const PANEL_MESSAGES = {
    empty: 'No entries for this site',
    locked: 'MyPass is locked',
    pairingRequired: 'Pair MyPass to use it here',
    unavailable: 'MyPass is not running',
  };

  function buildPanelContent(documentRef, routed, callbacks) {
    const doc = documentRef || document;
    const root = doc.createElement('div');
    const rows = [];
    let unlockButton = null;

    if (routed.panel === 'entries') {
      for (const entry of routed.entries) {
        const row = doc.createElement('button');
        row.setAttribute('type', 'button');
        row.setAttribute('data-entry-id', entry.id);
        row.textContent = entry.title + (entry.username ? ' — ' + entry.username : '');
        row.addEventListener('click', (event) => callbacks.onSelect(event, entry.id));
        root.appendChild(row);
        rows.push(row);
      }
    } else {
      const message = doc.createElement('div');
      message.textContent = PANEL_MESSAGES[routed.panel] || PANEL_MESSAGES.unavailable;
      root.appendChild(message);

      if (routed.panel === 'locked') {
        unlockButton = doc.createElement('button');
        unlockButton.setAttribute('type', 'button');
        unlockButton.textContent = 'Unlock MyPass';
        unlockButton.addEventListener('click', (event) => callbacks.onUnlock(event));
        root.appendChild(unlockButton);
      }
    }

    return { root, rows, unlockButton };
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
      KEY_ICON_PATH_D, buildKeyGlyph, buildShadowHost, buildIconHost, positionHostToField,
      buildPanelContent,
    };
  }
})();
