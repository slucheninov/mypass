const PAIRING_STARTED_AT_KEY = 'pairingStartedAt';
const PAIRING_CHALLENGE_TTL_MS = 120_000;

const APP_UNAVAILABLE_STATUS_TEXT =
  'MyPass not found. Make sure the app is installed and has been launched at least once (to register the native messaging host).';
const APP_UNAVAILABLE_OPEN_HELPER_TEXT =
  'Open MyPass from Applications or the Dock. Unlock your vault if needed, then tap Retry.';

function shouldShowAppUnavailableActions(kind) {
  return kind === 'error';
}

const LOCKED_TITLE_TEXT = 'MyPass is locked';
const LOCKED_HELPER_TEXT = 'Open MyPass and unlock the vault';
const EMPTY_LIST_TITLE_TEXT = 'No saved logins for this site';
const LIST_HEADER_TEXT = 'Select an entry to autofill:';
const PAIRING_PANEL_TITLE_TEXT = 'Connect browser extension';
const UNLOCK_BUTTON_LABEL = 'Unlock MyPass';
// Must match PAIRING_STORAGE_KEY in background.js — asserted by unlockButton.test.js.
const POPUP_PAIRING_STORAGE_KEY = 'pairingSecret';
// The popup was expected to close when MyPass takes focus, so no waiting state was
// planned. It does not reliably close, so it polls the vault instead of stranding the
// user on a stale locked panel with only Retry.
const UNLOCK_POLL_INTERVAL_MS = 800;
const UNLOCK_POLL_MAX_ATTEMPTS = 75; // 800 ms x 75 = 60 s of real unlocking time
const WAITING_FOR_UNLOCK_TEXT = 'Waiting for you to unlock MyPass\u2026';

function classifyGetCredentialsResponse(response) {
  if (!response || response.type === 'error') return 'error';
  if (response.type === 'locked') return 'locked';
  if (response.type === 'pairingRequired') return 'pairingRequired';
  if (response.type === 'credentialList') return 'credentialList';
  return 'unknown';
}

function shouldShowUnlockButton(pairingSecret) {
  return typeof pairingSecret === 'string' && pairingSecret.length > 0;
}

function classifyRequestUnlockResponse(response) {
  if (!response) return 'unavailable';
  if (response.type === 'unlockPresented') return 'presented';
  if (response.type === 'unlockNotNeeded') return 'notNeeded';
  return 'unavailable';
}

function shouldContinueUnlockPolling(kind, attempt) {
  // Any non-locked outcome is terminal: unlocked means we are done, and an error or a
  // pairing prompt means polling cannot help.
  if (kind !== 'locked') return false;
  return attempt < UNLOCK_POLL_MAX_ATTEMPTS;
}

function isPairingChallengeFresh(startedAt, now) {
  if (startedAt == null || typeof startedAt !== 'number') return false;
  return now - startedAt < PAIRING_CHALLENGE_TTL_MS;
}

function normalizePairingCode(raw) {
  return String(raw).replace(/\D/g, '').slice(0, 6);
}

const LETTER_AVATAR_PALETTE = [
  '#007AFF',
  '#34C759',
  '#FF9500',
  '#AF52DE',
  '#FF2D55',
  '#30B0C7',
  '#5856D6',
  '#00C7BE',
  '#32ADE6',
  '#A2845E'
];

function letterFromTitle(title) {
  const trimmed = title.trim();
  if (!trimmed) return '?';
  return trimmed[0].toUpperCase();
}

function colorForTitle(title) {
  const MASK64 = (1n << 64n) - 1n;
  const SIGNBIT = 1n << 63n;
  const wrap64 = (v) => {
    v &= MASK64;
    return v & SIGNBIT ? v - (1n << 64n) : v;
  };
  let hash = 0n;
  for (const byte of new TextEncoder().encode(title)) {
    hash = wrap64(wrap64(hash + BigInt(byte)) * 31n);
  }
  const len = BigInt(LETTER_AVATAR_PALETTE.length);
  let index = hash % len;
  if (index < 0n) index += len;
  return LETTER_AVATAR_PALETTE[Number(index)];
}

function getPairingStorageArea() {
  if (typeof chrome !== 'undefined' && chrome.storage && chrome.storage.session) {
    return chrome.storage.session;
  }
  return chrome.storage.local;
}

function readPairingStartedAt(cb) {
  getPairingStorageArea().get(PAIRING_STARTED_AT_KEY, (result) => {
    cb(result[PAIRING_STARTED_AT_KEY]);
  });
}

function writePairingStartedAt(cb) {
  getPairingStorageArea().set({ [PAIRING_STARTED_AT_KEY]: Date.now() }, cb);
}

function clearPairingStartedAt(cb) {
  getPairingStorageArea().remove(PAIRING_STARTED_AT_KEY, cb);
}

const TOTP_AUTO_HIDE_MS = 5000;

// Live countdown ring, mirroring MyPass/UI/EntryDetail/TOTPCountdownRingView.swift:
// a green stroke whose arc length equals the REMAINING fraction of the 30 s TOTP
// window, shrinking clockwise from 12 o'clock and resetting to full each window.
const TOTP_RING_PERIOD_SECONDS = 30;
const TOTP_RING_CIRCUMFERENCE = 2 * Math.PI * 14;

function totpRemainingFraction(nowMs, periodSeconds = TOTP_RING_PERIOD_SECONDS) {
  const remaining = periodSeconds - ((nowMs / 1000) % periodSeconds);
  return remaining / periodSeconds;
}

function totpRingDashOffset(fraction, circumference) {
  return circumference * (1 - fraction);
}

// Single shared 1 Hz ticker for every ring currently on screen, started lazily
// when the first ring registers and torn down once the last one disconnects.
let totpRingRegistry = [];
let totpRingInterval = null;

function applyTotpRingOffset(entry, fraction, snap) {
  const offset = totpRingDashOffset(fraction, entry.circumference);
  const style = entry.svgCircleEl.style;
  if (snap) {
    // Window rollover: jump back to (near) full without animating backwards.
    style.transition = 'none';
    style.strokeDashoffset = String(offset);
    // Force a reflow so the "no transition" write lands before the class's own
    // 1 s linear transition is restored on the next line.
    void entry.svgCircleEl.offsetWidth;
    style.transition = '';
  } else {
    style.strokeDashoffset = String(offset);
  }
}

function tickTotpRings(nowMs = Date.now()) {
  // Self-clean mirroring the outside-click listener pattern: drop rings whose
  // host circle has left the DOM (list re-rendered), and once the registry is
  // empty stop the interval so node tests (and idle popups) don't keep ticking.
  totpRingRegistry = totpRingRegistry.filter((entry) => entry.hostEl.isConnected !== false);
  if (totpRingRegistry.length === 0) {
    if (totpRingInterval !== null) {
      clearInterval(totpRingInterval);
      totpRingInterval = null;
    }
    return;
  }

  const fraction = totpRemainingFraction(nowMs, TOTP_RING_PERIOD_SECONDS);
  const windowIndex = Math.floor(nowMs / 1000 / TOTP_RING_PERIOD_SECONDS);

  totpRingRegistry.forEach((entry) => {
    const rolledOver = windowIndex !== entry.lastWindowIndex;
    applyTotpRingOffset(entry, fraction, rolledOver);
    // The window rolled over while digits were revealed (not the copied flash) —
    // the shown code is now stale, so re-request it in place without touching
    // the auto-hide timer.
    if (rolledOver && entry.hostEl.classList.contains('revealed')) {
      entry.requestTotp().then((code) => {
        if (code) (entry.textEl || entry.hostEl).textContent = code;
      }).catch(() => {});
    }
    entry.lastWindowIndex = windowIndex;
  });
}

function registerTotpRing(entry, nowMs = Date.now()) {
  totpRingRegistry.push({
    ...entry,
    lastWindowIndex: Math.floor(nowMs / 1000 / TOTP_RING_PERIOD_SECONDS)
  });
  if (totpRingInterval === null) {
    totpRingInterval = setInterval(() => tickTotpRings(Date.now()), 1000);
  }
}

function shouldShowTotpCircle(hasTotp) {
  return hasTotp === true;
}

function createTotpCircleController(circleEl, requestTotp, options = {}) {
  const textEl = options.textEl || circleEl;
  let hideTimer = null;
  // "active" covers both the revealed-digits state and the copied-flash state — either
  // one must be dismissible by a second left-click or by clicking outside the circle.
  let active = false;

  function clearHideTimer() {
    if (hideTimer) {
      clearTimeout(hideTimer);
      hideTimer = null;
    }
  }

  function showIdle() {
    clearHideTimer();
    active = false;
    textEl.textContent = '';
    circleEl.classList.remove('revealed', 'copied');
  }

  function showDigits(code) {
    active = true;
    textEl.textContent = code;
    circleEl.classList.add('revealed');
    circleEl.classList.remove('copied');
    clearHideTimer();
    hideTimer = setTimeout(showIdle, TOTP_AUTO_HIDE_MS);
  }

  function showCopiedFlash() {
    active = true;
    textEl.textContent = 'Copied';
    circleEl.classList.add('copied');
    circleEl.classList.remove('revealed');
    clearHideTimer();
    hideTimer = setTimeout(showIdle, TOTP_AUTO_HIDE_MS);
  }

  function handleLeftClick(event) {
    event.stopPropagation();
    if (active) {
      showIdle();
      return;
    }
    requestTotp().then((code) => {
      if (code) showDigits(code);
    }).catch(() => {});
  }

  function handleContextMenu(event) {
    event.preventDefault();
    event.stopPropagation();
    requestTotp().then((code) => {
      if (!code) return;
      navigator.clipboard.writeText(code).then(showCopiedFlash).catch(() => {});
    }).catch(() => {});
  }

  function handleMouseDown(event) {
    event.stopPropagation();
  }

  function handleOutsideClick(event) {
    // Self-clean once this row's circle has been removed from the DOM (e.g.
    // renderCredentials re-rendered the list on retry/unlock) — otherwise this
    // document-level listener would accumulate across every re-render.
    if (circleEl.isConnected === false) {
      document.removeEventListener('click', handleOutsideClick, true);
      return;
    }
    if (active && !circleEl.contains(event.target)) {
      showIdle();
    }
  }

  circleEl.addEventListener('mousedown', handleMouseDown);
  circleEl.addEventListener('click', handleLeftClick);
  circleEl.addEventListener('contextmenu', handleContextMenu);
  // Capture phase: a sibling circle's own click handler calls stopPropagation on the
  // bubble phase, which would otherwise stop this document-level listener from ever
  // seeing clicks on OTHER circles/rows. Capture runs before that stopPropagation.
  document.addEventListener('click', handleOutsideClick, true);

  return { showIdle, showDigits, showCopiedFlash };
}

const SVG_NS = 'http://www.w3.org/2000/svg';

function buildTotpRingSvg() {
  const ring = document.createElementNS(SVG_NS, 'svg');
  ring.setAttribute('viewBox', '0 0 32 32');
  ring.setAttribute('class', 'totp-ring');
  ring.setAttribute('aria-hidden', 'true');
  ring.setAttribute('focusable', 'false');

  const ringCircle = document.createElementNS(SVG_NS, 'circle');
  ringCircle.setAttribute('cx', '16');
  ringCircle.setAttribute('cy', '16');
  ringCircle.setAttribute('r', '14');
  ringCircle.setAttribute('fill', 'none');
  ringCircle.setAttribute('stroke', '#34c759');
  ringCircle.setAttribute('stroke-width', '2');
  ringCircle.setAttribute('stroke-linecap', 'round');
  ringCircle.setAttribute('transform', 'rotate(-90 16 16)');
  ringCircle.setAttribute('stroke-dasharray', String(TOTP_RING_CIRCUMFERENCE));
  const initialFraction = totpRemainingFraction(Date.now(), TOTP_RING_PERIOD_SECONDS);
  ringCircle.style.strokeDashoffset = String(totpRingDashOffset(initialFraction, TOTP_RING_CIRCUMFERENCE));

  ring.appendChild(ringCircle);
  return { ring, ringCircle };
}

function buildTotpCircleElement(credential, url) {
  const circle = document.createElement('div');
  circle.className = 'totp-circle';
  circle.setAttribute('role', 'button');
  circle.setAttribute('aria-label', 'Reveal or copy verification code');

  const requestTotp = () => new Promise((resolve, reject) => {
    chrome.runtime.sendMessage({ type: 'getTotp', id: credential.id, url }, (response) => {
      if (response && response.type === 'totp' && response.code) {
        resolve(response.code);
      } else {
        reject(new Error('getTotp failed'));
      }
    });
  });

  // The ring lives underneath as its own SVG (pointer-events: none, so it never
  // intercepts clicks) and the digits/"Copied" text live in a sibling label span
  // above it — kept separate so revealing/hiding the code (which replaces
  // textContent) never wipes out the ring.
  const { ring, ringCircle } = buildTotpRingSvg();
  circle.appendChild(ring);

  const label = document.createElement('span');
  label.className = 'totp-circle-label';
  circle.appendChild(label);

  createTotpCircleController(circle, requestTotp, { textEl: label });

  registerTotpRing({
    hostEl: circle,
    textEl: label,
    svgCircleEl: ringCircle,
    circumference: TOTP_RING_CIRCUMFERENCE,
    requestTotp
  });

  return circle;
}

function validateTotpPasteInput(raw) {
  const trimmed = (raw || '').trim();
  if (trimmed.toLowerCase().startsWith('otpauth://totp/')) {
    return { valid: true, value: trimmed };
  }
  if (isBase32PasteSecret(trimmed)) {
    return { valid: true, value: trimmed.replace(/\s+/g, '').toUpperCase() };
  }
  return { valid: false, value: null };
}

function isBase32PasteSecret(candidate) {
  const normalized = (candidate || '').replace(/\s+/g, '');
  return /^[A-Z2-7]{16,128}$/i.test(normalized);
}

// Assigned once the DOM is wired up below: renderTotpPicker needs `listEl` and
// `buildLetterAvatarElement`, routeTotpCandidate needs renderTotpPicker, and
// restorePendingTotpCandidate needs `totpPasteInput`/`showPanel`. Declared here (rather
// than only inside the DOM block) so module.exports at the bottom of this file can see them.
let renderTotpPicker = null;
let routeTotpCandidate = null;
let restorePendingTotpCandidate = null;

if (typeof document !== 'undefined') {
  const lockedPanel = document.getElementById('locked-panel');
  const lockedTitleEl = document.getElementById('locked-title');
  const lockedHelperEl = document.getElementById('locked-helper');
  const lockedRetryBtn = document.getElementById('locked-retry-btn');
  const lockedUnlockBtn = document.getElementById('locked-unlock-btn');

  const appUnavailablePanel = document.getElementById('app-unavailable-panel');
  const appUnavailableStatusEl = document.getElementById('app-unavailable-status');
  const appUnavailableActions = document.getElementById('app-unavailable-actions');
  const retryBtn = document.getElementById('retry-btn');
  const openMypassBtn = document.getElementById('open-mypass-btn');
  const openMypassHelper = document.getElementById('open-mypass-helper');
  openMypassHelper.textContent = APP_UNAVAILABLE_OPEN_HELPER_TEXT;

  const emptyPanel = document.getElementById('empty-panel');
  const emptyTitleEl = document.getElementById('empty-title');
  emptyTitleEl.textContent = EMPTY_LIST_TITLE_TEXT;

  const listPanel = document.getElementById('list-panel');
  const listHeaderEl = document.getElementById('list-header');
  listHeaderEl.textContent = LIST_HEADER_TEXT;
  const listEl = document.getElementById('list');

  const pairingPanel = document.getElementById('pairing-panel');
  const pairingTitleEl = document.getElementById('pairing-title');
  pairingTitleEl.textContent = PAIRING_PANEL_TITLE_TEXT;
  const connectBtn = document.getElementById('connect-btn');
  const codeEntry = document.getElementById('code-entry');
  const codeInput = document.getElementById('code-input');
  const submitCodeBtn = document.getElementById('submit-code-btn');
  const pairingErrorEl = document.getElementById('pairing-error');

  const addTotpBtn = document.getElementById('add-totp-btn');
  const totpPasteInput = document.getElementById('totp-paste-input');
  const addTotpErrorEl = document.getElementById('add-totp-error');

  // Set by queryCredentials for every credential lookup (initial load, retries, and
  // post-pairing/post-unlock re-checks) so the Add-2FA button can reuse the active tab's
  // URL without re-querying chrome.tabs itself.
  let currentTabUrl = null;

  lockedTitleEl.textContent = LOCKED_TITLE_TEXT;
  lockedHelperEl.textContent = LOCKED_HELPER_TEXT;

  const PANEL_SECTIONS = [
    lockedPanel,
    appUnavailablePanel,
    emptyPanel,
    listPanel,
    pairingPanel
  ];

  function showPanel(name) {
    for (const section of PANEL_SECTIONS) {
      section.hidden = true;
    }
    openMypassHelper.hidden = true;
    switch (name) {
      case 'locked':
        lockedPanel.hidden = false;
        break;
      case 'app-unavailable':
        appUnavailablePanel.hidden = false;
        break;
      case 'empty':
        emptyPanel.hidden = false;
        break;
      case 'credential-list':
        listPanel.hidden = false;
        break;
      case 'pairing':
        pairingPanel.hidden = false;
        break;
      default:
        break;
    }
  }

  function setPairingError(text) {
    if (text) {
      pairingErrorEl.textContent = text;
      pairingErrorEl.hidden = false;
    } else {
      pairingErrorEl.textContent = '';
      pairingErrorEl.hidden = true;
    }
  }

  function showPairingPanel() {
    showPanel('pairing');
  }

  function hidePairingPanel() {
    codeEntry.hidden = true;
    codeInput.value = '';
    setPairingError('');
  }

  function resetPairingFlow() {
    codeEntry.hidden = true;
    codeInput.value = '';
    setPairingError('');
  }

  function revealCodeEntry() {
    codeEntry.hidden = false;
  }

  function buildLetterAvatarElement(title) {
    const avatar = document.createElement('div');
    avatar.className = 'letter-avatar';
    avatar.style.backgroundColor = colorForTitle(title);
    avatar.setAttribute('role', 'img');
    avatar.setAttribute(
      'aria-label',
      title.trim() ? `Icon for ${title}` : 'Icon for untitled entry'
    );
    const letter = document.createElement('span');
    letter.className = 'letter-avatar-letter';
    letter.textContent = letterFromTitle(title);
    avatar.appendChild(letter);
    return avatar;
  }

  function renderCredentials(credentials, url) {
    listEl.innerHTML = '';
    credentials.forEach((credential) => {
      const item = document.createElement('li');
      item.className = 'credential-row';

      item.appendChild(buildLetterAvatarElement(credential.title));

      const textCol = document.createElement('div');
      textCol.className = 'credential-text';

      const title = document.createElement('div');
      title.className = 'credential-title';
      title.textContent = credential.title;
      textCol.appendChild(title);

      if (credential.username) {
        const username = document.createElement('div');
        username.className = 'credential-username';
        username.textContent = credential.username;
        textCol.appendChild(username);
      }

      item.appendChild(textCol);

      if (shouldShowTotpCircle(credential.hasTotp)) {
        item.appendChild(buildTotpCircleElement(credential, url));
      }

      item.addEventListener('click', () => {
        chrome.runtime.sendMessage(
          { type: 'fillCredential', id: credential.id, url },
          () => {
            window.close();
          }
        );
      });
      listEl.appendChild(item);
    });
  }

  function startPairingFlow() {
    resetPairingFlow();
    chrome.runtime.sendMessage({ type: 'startPairing' }, (startResp) => {
      if (startResp && startResp.type === 'pairingStarted') {
        writePairingStartedAt(() => {
          revealCodeEntry();
        });
        return;
      }
      if (startResp && startResp.type === 'locked') {
        setPairingError('MyPass is locked.');
        return;
      }
      setPairingError('Could not start pairing. Is MyPass running and unlocked?');
    });
  }

  function submitPairingCode(url) {
    setPairingError('');
    const code = normalizePairingCode(codeInput.value);
    chrome.runtime.sendMessage({ type: 'completePairing', code }, (completeResp) => {
      if (completeResp && completeResp.type === 'paired') {
        clearPairingStartedAt(() => {
          hidePairingPanel();
          queryCredentials(url);
        });
        return;
      }
      if (completeResp && completeResp.type === 'error' && completeResp.message === 'invalid_code') {
        clearPairingStartedAt(() => {
          setPairingError('Invalid code. Tap Connect to try again.');
        });
        return;
      }
      setPairingError('Could not complete pairing. Is MyPass running and unlocked?');
    });
  }

  function hideAppUnavailableActions() {
    openMypassHelper.hidden = true;
  }

  function retryCredentialsForActiveTab() {
    listEl.innerHTML = '';
    chrome.tabs.query({ active: true, currentWindow: true }, (tabs) => {
      const activeTab = tabs[0];
      if (!activeTab || !activeTab.url) {
        appUnavailableStatusEl.textContent = APP_UNAVAILABLE_STATUS_TEXT;
        showAppUnavailableActions(null);
        return;
      }
      queryCredentials(activeTab.url);
    });
  }

  function showAppUnavailableActions(url) {
    hidePairingPanel();
    listEl.innerHTML = '';
    appUnavailableStatusEl.textContent = APP_UNAVAILABLE_STATUS_TEXT;
    showPanel('app-unavailable');
    openMypassHelper.hidden = true;
    retryBtn.onclick = () => {
      if (url) {
        listEl.innerHTML = '';
        queryCredentials(url);
      } else {
        retryCredentialsForActiveTab();
      }
    };
    openMypassBtn.onclick = () => {
      openMypassHelper.hidden = false;
    };
  }

  function handleCredentialsResponse(response, url) {
    const kind = classifyGetCredentialsResponse(response);
    if (kind === 'error') {
      if (shouldShowAppUnavailableActions(kind)) {
        showAppUnavailableActions(url);
      }
      return;
    }
    hideAppUnavailableActions();
    if (kind === 'locked') {
      showPanel('locked');
      lockedRetryBtn.onclick = () => queryCredentials(url);
      lockedUnlockBtn.textContent = UNLOCK_BUTTON_LABEL;
      lockedUnlockBtn.onclick = () => requestUnlock(url);
      chrome.storage.local.get(POPUP_PAIRING_STORAGE_KEY, (stored) => {
        lockedUnlockBtn.hidden = !shouldShowUnlockButton(stored[POPUP_PAIRING_STORAGE_KEY]);
      });
      return;
    }
    if (kind === 'pairingRequired') {
      showPairingPanel();
      connectBtn.onclick = startPairingFlow;
      submitCodeBtn.onclick = () => submitPairingCode(url);
      readPairingStartedAt((startedAt) => {
        if (isPairingChallengeFresh(startedAt, Date.now())) {
          revealCodeEntry();
        }
      });
      return;
    }
    if (kind === 'credentialList') {
      if (response.credentials.length === 0) {
        showPanel('empty');
        return;
      }
      showPanel('credential-list');
      renderCredentials(response.credentials, url);
    }
  }

  let unlockPollTimer = null;

  function stopUnlockPolling() {
    if (unlockPollTimer !== null) {
      clearTimeout(unlockPollTimer);
      unlockPollTimer = null;
    }
  }

  function endUnlockWait(response, url) {
    stopUnlockPolling();
    lockedHelperEl.textContent = LOCKED_HELPER_TEXT;
    lockedUnlockBtn.disabled = false;
    handleCredentialsResponse(response, url);
  }

  function pollForUnlock(url, attempt) {
    chrome.runtime.sendMessage({ type: 'getCredentials', url }, (response) => {
      if (!shouldContinueUnlockPolling(classifyGetCredentialsResponse(response), attempt)) {
        endUnlockWait(response, url);
        return;
      }
      unlockPollTimer = setTimeout(() => pollForUnlock(url, attempt + 1), UNLOCK_POLL_INTERVAL_MS);
    });
  }

  function requestUnlock(url) {
    chrome.runtime.sendMessage({ type: 'requestUnlock' }, (response) => {
      const kind = classifyRequestUnlockResponse(response);
      if (kind === 'notNeeded') {
        queryCredentials(url);
        return;
      }
      if (kind !== 'presented') return;
      // MyPass is now showing its unlock screen. Wait for it rather than leaving the
      // user on a stale panel whose only action is Retry.
      lockedHelperEl.textContent = WAITING_FOR_UNLOCK_TEXT;
      lockedUnlockBtn.disabled = true;
      pollForUnlock(url, 0);
    });
  }

  function queryCredentials(url) {
    currentTabUrl = url;
    stopUnlockPolling();
    chrome.runtime.sendMessage({ type: 'getCredentials', url }, (response) => {
      handleCredentialsResponse(response, url);
    });
  }

  renderTotpPicker = function (credentials, url, otpauthOrSecret) {
    showPanel('credential-list');
    listEl.innerHTML = '';
    credentials.forEach((credential) => {
      const item = document.createElement('li');
      item.className = 'credential-row';
      item.appendChild(buildLetterAvatarElement(credential.title));

      const textCol = document.createElement('div');
      textCol.className = 'credential-text';
      const title = document.createElement('div');
      title.className = 'credential-title';
      title.textContent = credential.title;
      textCol.appendChild(title);
      item.appendChild(textCol);

      if (credential.hasTotp) {
        const badge = document.createElement('span');
        badge.className = 'totp-badge';
        badge.textContent = '2FA';
        item.appendChild(badge);
      }

      item.addEventListener('click', () => {
        chrome.runtime.sendMessage(
          { type: 'proposeSaveTotp', url, otpauthOrSecret, entryId: credential.id },
          () => {
            addTotpErrorEl.hidden = false;
            addTotpErrorEl.textContent = 'Opened in MyPass';
          }
        );
      });
      listEl.appendChild(item);
    });
  };

  routeTotpCandidate = function (url, otpauthOrSecret, credentials) {
    if (credentials.length === 0) {
      chrome.runtime.sendMessage({ type: 'proposeSaveTotp', url, otpauthOrSecret });
    } else if (credentials.length === 1) {
      chrome.runtime.sendMessage({ type: 'proposeSaveTotp', url, otpauthOrSecret, entryId: credentials[0].id });
    } else {
      renderTotpPicker(credentials, url, otpauthOrSecret);
    }
  };

  function handleAddTotpClick(activeTabUrl) {
    const raw = totpPasteInput.value;
    const validation = validateTotpPasteInput(raw);
    if (!validation.valid) {
      addTotpErrorEl.textContent = 'Enter a valid authenticator URL or secret key';
      addTotpErrorEl.hidden = false;
      return;
    }
    addTotpErrorEl.hidden = true;
    chrome.runtime.sendMessage({ type: 'getCredentials', url: activeTabUrl }, (response) => {
      const credentials = (response && response.type === 'credentialList') ? response.credentials : [];
      routeTotpCandidate(activeTabUrl, validation.value, credentials);
    });
  }

  restorePendingTotpCandidate = function () {
    const area = getPairingStorageArea();
    if (!area || !area.get) return;
    area.get(['pendingTotpCandidate'], (result) => {
      const pending = result && result.pendingTotpCandidate;
      if (!pending) return;
      totpPasteInput.value = pending.otpauthOrSecret;
      chrome.runtime.sendMessage({ type: 'getCredentials', url: pending.url }, (response) => {
        const credentials = (response && response.type === 'credentialList') ? response.credentials : [];
        if (credentials.length > 1) {
          renderTotpPicker(credentials, pending.url, pending.otpauthOrSecret);
        }
      });
      area.remove(['pendingTotpCandidate']);
    });
  };

  addTotpBtn.onclick = () => handleAddTotpClick(currentTabUrl);
  restorePendingTotpCandidate();

  chrome.tabs.query({ active: true, currentWindow: true }, (tabs) => {
    const activeTab = tabs[0];
    if (!activeTab || !activeTab.url) {
      appUnavailableStatusEl.textContent = APP_UNAVAILABLE_STATUS_TEXT;
      showAppUnavailableActions(null);
      return;
    }
    queryCredentials(activeTab.url);
  });
}

if (typeof module !== 'undefined') {
  module.exports = {
    classifyGetCredentialsResponse,
    isPairingChallengeFresh,
    normalizePairingCode,
    PAIRING_CHALLENGE_TTL_MS,
    APP_UNAVAILABLE_STATUS_TEXT,
    APP_UNAVAILABLE_OPEN_HELPER_TEXT,
    shouldShowAppUnavailableActions,
    LETTER_AVATAR_PALETTE,
    letterFromTitle,
    colorForTitle,
    LOCKED_TITLE_TEXT,
    LOCKED_HELPER_TEXT,
    EMPTY_LIST_TITLE_TEXT,
    LIST_HEADER_TEXT,
    PAIRING_PANEL_TITLE_TEXT,
    shouldShowUnlockButton,
    classifyRequestUnlockResponse,
    UNLOCK_BUTTON_LABEL,
    POPUP_PAIRING_STORAGE_KEY,
    shouldContinueUnlockPolling,
    UNLOCK_POLL_INTERVAL_MS,
    UNLOCK_POLL_MAX_ATTEMPTS,
    WAITING_FOR_UNLOCK_TEXT,
    shouldShowTotpCircle,
    createTotpCircleController,
    buildTotpCircleElement,
    totpRemainingFraction,
    totpRingDashOffset,
    tickTotpRings,
    registerTotpRing,
    TOTP_RING_PERIOD_SECONDS,
    TOTP_RING_CIRCUMFERENCE,
    validateTotpPasteInput,
    isBase32PasteSecret,
    renderTotpPicker,
    routeTotpCandidate,
    restorePendingTotpCandidate
  };
}
