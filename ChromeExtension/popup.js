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

// letterFromTitle/colorForTitle (and the palette colorForTitle hashes into) moved to
// shared/entry-visuals.js so the inline panel can share them without drifting — see that
// file's header comment. popup.html loads entry-visuals.js as a <script> immediately before
// this one, so both names would already be globals in the browser — but several node tests
// (totpCircle, popup-fallback, totpPicker, passkeyPopup) require this file directly and drive
// it all the way into renderCredentials, so a bare global reference throws under node. require
// them there instead — the same three-world seam entry-visuals.js itself is built for.
// Bound as a namespace object, NOT destructured into `letterFromTitle`/`colorForTitle`
// names: popup.html loads entry-visuals.js as a classic <script> immediately before this
// one, so both scripts share ONE global scope, and entry-visuals.js declares those two
// names as top-level function declarations there. A top-level `const`/`let` here with the
// SAME names would be a lexical redeclaration of names the earlier script already put in
// the global environment — that is a load-time SyntaxError under
// GlobalDeclarationInstantiation, thrown before a single statement of this file runs (see
// ChromeExtension/tests/scriptScopes.test.js). Node can't see this: under `require`, this
// file is a CommonJS module with its own scope, so no collision exists there. Do not
// "simplify" this back into `const { letterFromTitle, colorForTitle } = ...`.
const entryVisuals = typeof require === 'function'
  ? require('./shared/entry-visuals.js')
  : { letterFromTitle: window.letterFromTitle, colorForTitle: window.colorForTitle };

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

// Shared by the picker row click handler and routeTotpCandidate's zero/one-match
// branches so a proposeSaveTotp round-trip's actual outcome is reported instead of
// always claiming success.
function describeSaveProposalOutcome(response) {
  if (response && response.type === 'saveProposalAccepted') return 'Opened in MyPass';
  if (response && response.type === 'locked') return 'Unlock MyPass first';
  if (response && response.type === 'pairingRequired') return 'Connect to MyPass first';
  if (response && response.message) return response.message;
  return "Couldn't reach MyPass";
}

// Assigned once the DOM is wired up below: renderTotpPicker needs `listEl` and
// `buildLetterAvatarElement`, routeTotpCandidate needs renderTotpPicker, and
// restorePendingTotpCandidate needs `totpPasteInput`/`showPanel`. Declared here (rather
// than only inside the DOM block) so module.exports at the bottom of this file can see them.
let renderTotpPicker = null;
let routeTotpCandidate = null;
let restorePendingTotpCandidate = null;
let handleAddTotpClick = null;
let requestPageTotpCandidate = null;
let rehydratePendingPasskeyCeremony = null;
let renderPasskeyCeremonyPanel = null;
let renderPasskeyPicker = null;
let sendPasskeyCreateConfirm = null;
let sendPasskeyGetApprove = null;
let sendPasskeyCancel = null;
let initPasskeySettingsToggle = null;

const PENDING_PASSKEY_KEY = 'pendingPasskeyCeremony';

/// Both values are shown on every confirm panel: the relying party the credential will
/// be bound to, and the origin the ceremony actually came from. A mismatch between them
/// is what a phishing attempt looks like, so the user has to be able to see both.
function passkeyCeremonySummary(pending) {
  if (!pending) return '';
  const origin = pending.originUrl || 'unknown origin';
  return `${pending.rpId} — ${origin}`;
}

/// Which panel a pending ceremony maps to. Pure so the routing can be tested without a
/// DOM: more than one match always means the picker, a create onto an entry that already
/// carries a passkey means the Replace confirm, and a get always requires an explicit
/// Approve — there is no silent auto-sign path even with exactly one match.
function choosePasskeyPanel(pending) {
  if (!pending || (pending.kind !== 'create' && pending.kind !== 'get')) return null;
  const matches = pending.matches || [];
  if (matches.length > 1) return 'passkey-picker';
  if (pending.kind === 'get') {
    return matches.length === 1 ? 'passkey-use' : null;
  }
  return matches.length === 1 && matches[0].hasPasskey ? 'passkey-replace' : 'passkey-save';
}

/// `{ headline, detail }` for the Save / Replace panels, so the user can see *which*
/// entry is about to be written to (or, with zero matches, that a new entry will be
/// created) rather than only the generic rpId/origin pair. `detail` is always the same
/// `passkeyCeremonySummary` line — kept as a second, secondary line so the phishing-
/// relevant rpId/origin comparison stays visible no matter which headline is shown.
///
/// `overrideMatch` lets the picker ask for the headline of a specific row the user just
/// clicked, rather than `pending.matches[0]` (which is only meaningful when there is
/// exactly one match — the picker path always has more than one).
function passkeyTargetSummary(pending, overrideMatch) {
  const detail = passkeyCeremonySummary(pending);
  if (!pending) return { headline: '', detail };
  const matches = pending.matches || [];
  const match = overrideMatch || (matches.length === 1 ? matches[0] : null);
  if (!match) {
    return { headline: `New entry for ${pending.rpId}`, detail };
  }
  const who = match.username ? `"${match.title}" (${match.username})` : `"${match.title}"`;
  const headline = match.hasPasskey ? `Replace passkey in ${who}?` : `Save passkey to ${who}?`;
  return { headline, detail };
}

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

  const passkeySavePanel = document.getElementById('passkey-save-panel');
  const passkeyReplacePanel = document.getElementById('passkey-replace-panel');
  const passkeyUsePanel = document.getElementById('passkey-use-panel');
  const passkeyPickerPanel = document.getElementById('passkey-picker-panel');
  const passkeyPickerListEl = document.getElementById('passkey-picker-list');
  const passkeySettingsFooter = document.getElementById('passkey-settings-footer');
  const passkeyProxyToggle = document.getElementById('passkey-proxy-toggle');

  const addTotpSection = document.getElementById('add-totp-section');
  const addTotpBtn = document.getElementById('add-totp-btn');
  const totpPasteInput = document.getElementById('totp-paste-input');
  const addTotpErrorEl = document.getElementById('add-totp-error');
  // Belt-and-suspenders alongside popup.html's static `hidden` attribute (same idiom as
  // PANEL_SECTIONS/showPanel always setting `.hidden = true` before selectively revealing):
  // the section must only appear once a real 2FA candidate is in context.
  addTotpSection.hidden = true;

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
    pairingPanel,
    passkeySavePanel,
    passkeyReplacePanel,
    passkeyUsePanel,
    passkeyPickerPanel
  ];

  const PASSKEY_PANELS = ['passkey-save', 'passkey-replace', 'passkey-use', 'passkey-picker'];

  function showPanel(name) {
    for (const section of PANEL_SECTIONS) {
      section.hidden = true;
    }
    openMypassHelper.hidden = true;
    // A ceremony owns the whole popup: the Add-2FA input and the settings toggle would
    // both be distractions next to a confirmation the user is being asked to make.
    if (PASSKEY_PANELS.includes(name)) {
      addTotpSection.hidden = true;
      passkeySettingsFooter.hidden = true;
    }
    switch (name) {
      case 'passkey-save':
        passkeySavePanel.hidden = false;
        break;
      case 'passkey-replace':
        passkeyReplacePanel.hidden = false;
        break;
      case 'passkey-use':
        passkeyUsePanel.hidden = false;
        break;
      case 'passkey-picker':
        passkeyPickerPanel.hidden = false;
        break;
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
    avatar.style.backgroundColor = entryVisuals.colorForTitle(title);
    avatar.setAttribute('role', 'img');
    avatar.setAttribute(
      'aria-label',
      title.trim() ? `Icon for ${title}` : 'Icon for untitled entry'
    );
    const letter = document.createElement('span');
    letter.className = 'letter-avatar-letter';
    letter.textContent = entryVisuals.letterFromTitle(title);
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
      restorePendingTotpCandidate(kind);
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
      restorePendingTotpCandidate(kind);
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
      restorePendingTotpCandidate(kind);
      return;
    }
    if (kind === 'credentialList') {
      if (response.credentials.length === 0) {
        showPanel('empty');
        restorePendingTotpCandidate(kind);
        return;
      }
      showPanel('credential-list');
      renderCredentials(response.credentials, url);
    }
    // Only reached for a non-empty credentialList — the primary panel is already
    // showing the current tab's credentials by the time this runs, so a picker
    // rendered below (for a *different*, pending URL) cannot race it.
    restorePendingTotpCandidate(kind);
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
          (response) => {
            addTotpErrorEl.hidden = false;
            addTotpErrorEl.textContent = describeSaveProposalOutcome(response);
          }
        );
      });
      listEl.appendChild(item);
    });
  };

  routeTotpCandidate = function (url, otpauthOrSecret, credentials) {
    const reportOutcome = (response) => {
      addTotpErrorEl.hidden = false;
      addTotpErrorEl.textContent = describeSaveProposalOutcome(response);
    };
    if (credentials.length === 0) {
      chrome.runtime.sendMessage({ type: 'proposeSaveTotp', url, otpauthOrSecret }, reportOutcome);
    } else if (credentials.length === 1) {
      chrome.runtime.sendMessage({ type: 'proposeSaveTotp', url, otpauthOrSecret, entryId: credentials[0].id }, reportOutcome);
    } else {
      renderTotpPicker(credentials, url, otpauthOrSecret);
    }
  };

  handleAddTotpClick = function (activeTabUrl) {
    const raw = totpPasteInput.value;
    const validation = validateTotpPasteInput(raw);
    if (!validation.valid) {
      addTotpErrorEl.textContent = 'Enter a valid authenticator URL or secret key';
      addTotpErrorEl.hidden = false;
      return;
    }
    addTotpErrorEl.hidden = true;
    chrome.runtime.sendMessage({ type: 'getCredentials', url: activeTabUrl }, (response) => {
      // Same trust model as the password-save flow: never fire a save/picker proposal
      // unless the vault is actually unlocked and paired. A locked/pairingRequired/error
      // response must surface a status here, not silently fall through to a blind
      // proposeSaveTotp (that would happen if we treated "not credentialList" as "zero
      // matches", since routeTotpCandidate's zero-match branch sends the proposal anyway).
      const kind = classifyGetCredentialsResponse(response);
      if (kind === 'locked') {
        addTotpErrorEl.textContent = 'Unlock MyPass first';
        addTotpErrorEl.hidden = false;
        return;
      }
      if (kind === 'pairingRequired') {
        addTotpErrorEl.textContent = 'Connect to MyPass first';
        addTotpErrorEl.hidden = false;
        return;
      }
      if (kind !== 'credentialList') {
        addTotpErrorEl.textContent = "Couldn't reach MyPass";
        addTotpErrorEl.hidden = false;
        return;
      }
      routeTotpCandidate(activeTabUrl, validation.value, response.credentials);
    });
  };

  // Sequenced (not raced) with the primary getCredentials flow: called from
  // handleCredentialsResponse once the panel for the *current* tab has already been
  // decided and shown, with that decision's classified kind passed in. Running this
  // concurrently with the primary flow (e.g. both fired from popup init) let whichever
  // chrome.runtime.sendMessage callback resolved last silently win — a late pending-
  // candidate lookup could override a just-shown locked/pairing panel, or the primary
  // flow could wipe an already-rendered picker.
  restorePendingTotpCandidate = function (primaryKind) {
    const area = getPairingStorageArea();
    if (!area || !area.get) return;
    area.get(['pendingTotpCandidate'], (result) => {
      const pending = result && result.pendingTotpCandidate;
      if (!pending) return;
      if (primaryKind !== 'credentialList') {
        // Vault isn't unlocked/paired for the current tab yet — leave the stored
        // candidate and the paste input untouched so it survives to the next popup
        // open (after the user unlocks/pairs) instead of fighting the locked/
        // pairing/error panel that was just shown.
        return;
      }
      totpPasteInput.value = pending.otpauthOrSecret;
      addTotpSection.hidden = false;
      chrome.runtime.sendMessage({ type: 'getCredentials', url: pending.url }, (response) => {
        if (!response || response.type !== 'credentialList') {
          // The vault re-locked (or otherwise stopped being unlocked/paired) between
          // this popup opening and this inner re-check resolving — keep the stored
          // candidate so it survives to the next popup open, same as the outer
          // locked-path semantics above.
          return;
        }
        if (response.credentials.length > 1) {
          renderTotpPicker(response.credentials, pending.url, pending.otpauthOrSecret);
        }
        area.remove(['pendingTotpCandidate']);
      });
    });
  };

  // --- Passkey ceremony panels ---------------------------------------------------
  // The pending record lives in chrome.storage.session (written by background.js), not
  // in this popup's memory: the popup is opened fresh by chrome.action.openPopup() after
  // the ceremony has already started, and may be closed and reopened mid-ceremony.

  function clearPendingPasskeyCeremony(cb) {
    const area = getPairingStorageArea();
    if (!area || !area.remove) {
      if (cb) cb();
      return;
    }
    area.remove([PENDING_PASSKEY_KEY], () => {
      if (cb) cb();
    });
  }

  sendPasskeyCreateConfirm = function (requestId, entryId, replace) {
    chrome.runtime.sendMessage(
      { type: 'passkeyCreateConfirm', requestId, entryId, replace: !!replace },
      () => clearPendingPasskeyCeremony(() => window.close())
    );
  };

  sendPasskeyGetApprove = function (requestId, entryId) {
    chrome.runtime.sendMessage(
      { type: 'passkeyGetApprove', requestId, entryId },
      () => clearPendingPasskeyCeremony(() => window.close())
    );
  };

  sendPasskeyCancel = function (requestId) {
    chrome.runtime.sendMessage(
      { type: 'passkeyCancelUI', requestId },
      () => clearPendingPasskeyCeremony(() => window.close())
    );
  };

  renderPasskeyPicker = function (pending) {
    passkeyPickerListEl.innerHTML = '';
    (pending.matches || []).forEach((credential) => {
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

      if (pending.kind === 'create' && credential.hasPasskey) {
        const badge = document.createElement('span');
        badge.className = 'passkey-badge';
        badge.textContent = 'Passkey';
        item.appendChild(badge);
      }

      item.addEventListener('click', () => {
        if (pending.kind === 'create') {
          // An entry that already carries a passkey must go through the same "Replace
          // passkey?" confirm every other route to that panel uses — never straight to
          // `sendPasskeyCreateConfirm`, which would silently overwrite it.
          if (credential.hasPasskey) {
            showPasskeySaveOrReplacePanel(pending, 'passkey-replace', credential.id, credential);
          } else {
            showPasskeySaveOrReplacePanel(pending, 'passkey-save', credential.id, credential);
          }
        } else {
          sendPasskeyGetApprove(pending.requestId, credential.id);
        }
      });
      passkeyPickerListEl.appendChild(item);
    });
  };

  /// Shared by the direct 0/1-match routing in `renderPasskeyCeremonyPanel` and by the
  /// picker's row click handler (which needs to show Save/Replace for the entry the user
  /// just picked, rather than confirming immediately).
  function showPasskeySaveOrReplacePanel(pending, panel, entryId, overrideMatch) {
    const isReplace = panel === 'passkey-replace';
    const { headline, detail } = passkeyTargetSummary(pending, overrideMatch);
    document.getElementById(isReplace ? 'passkey-replace-summary' : 'passkey-save-summary').textContent = headline;
    document.getElementById(isReplace ? 'passkey-replace-detail' : 'passkey-save-detail').textContent = detail;
    document.getElementById(isReplace ? 'passkey-replace-btn' : 'passkey-save-btn').onclick =
      () => sendPasskeyCreateConfirm(pending.requestId, entryId, isReplace);
    document.getElementById(isReplace ? 'passkey-replace-cancel-btn' : 'passkey-cancel-btn').onclick =
      () => sendPasskeyCancel(pending.requestId);
    showPanel(panel);
  }

  renderPasskeyCeremonyPanel = function (pending) {
    const panel = choosePasskeyPanel(pending);
    if (!panel) return false;

    const summaryText = passkeyCeremonySummary(pending);
    const matches = pending.matches || [];
    const entryId = matches.length === 1 ? matches[0].id : undefined;

    if (panel === 'passkey-picker') {
      document.getElementById('passkey-picker-summary').textContent = summaryText;
      renderPasskeyPicker(pending);
      document.getElementById('passkey-picker-cancel-btn').onclick = () => sendPasskeyCancel(pending.requestId);
      showPanel('passkey-picker');
      return true;
    }

    if (panel === 'passkey-use') {
      document.getElementById('passkey-use-summary').textContent = summaryText;
      document.getElementById('passkey-approve-btn').onclick = () => sendPasskeyGetApprove(pending.requestId, entryId);
      document.getElementById('passkey-use-cancel-btn').onclick = () => sendPasskeyCancel(pending.requestId);
      showPanel('passkey-use');
      return true;
    }

    showPasskeySaveOrReplacePanel(pending, panel, entryId);
    return true;
  };

  // Returns whether a ceremony took over the popup, so the caller can skip the ordinary
  // credential-list flow entirely rather than racing it — the same sequencing mistake
  // restorePendingTotpCandidate was fixed for.
  rehydratePendingPasskeyCeremony = function (cb) {
    const area = getPairingStorageArea();
    if (!area || !area.get) {
      cb(false);
      return;
    }
    area.get([PENDING_PASSKEY_KEY], (result) => {
      const pending = result && result[PENDING_PASSKEY_KEY];
      if (!pending) {
        cb(false);
        return;
      }
      cb(renderPasskeyCeremonyPanel(pending));
    });
  };

  // The app is authoritative (2026-08-23 fix): `checked` is set from a fresh
  // `status.enabled` whenever the app answers, and only falls back to the extension's
  // stored flag while the app cannot be reached (matching the 2026-08-09 "C popup toggle
  // state" decision for the unreachable case). `attachAllowed`/`unlocked` still only
  // decide whether the control itself is enabled, not its checked state.
  initPasskeySettingsToggle = function () {
    passkeySettingsFooter.hidden = false;
    // `statusApplied` guards against the async chrome.storage.local.get callback below
    // clobbering a fresher value already set from the app's status — the two callbacks
    // race with no ordering guarantee between them.
    let statusApplied = false;
    chrome.storage.local.get(['passkeyProxyEnabled'], (stored) => {
      if (statusApplied) return;
      passkeyProxyToggle.checked = !!(stored && stored.passkeyProxyEnabled);
    });
    chrome.runtime.sendMessage({ type: 'getPasskeyProxyStatus' }, (status) => {
      const reachable = !!(status && status.type === 'passkeyProxyStatus');
      // A pre-`enabled` app (old wire shape) reports no opt-in at all; that is not
      // authoritative, so fall back to whatever the stored cache/checkbox already shows.
      if (reachable && status.enabled !== undefined) {
        passkeyProxyToggle.checked = !!status.enabled;
        statusApplied = true;
      }
      passkeyProxyToggle.disabled = !(reachable && status.unlocked && status.paired);
    });
    // Fire-and-forget: lets the background service worker resync its cache and
    // attach/detach against the app's current status on every popup open, rather than
    // only at service-worker startup. The no-op callback reads chrome.runtime.lastError
    // so Chrome doesn't log an "Unchecked runtime.lastError" warning if the message port
    // closes before a response (the handler never sends one for this message).
    chrome.runtime.sendMessage({ type: 'refreshPasskeyProxy' }, () => { void chrome.runtime.lastError; });
    passkeyProxyToggle.addEventListener('change', () => {
      chrome.runtime.sendMessage({ type: 'setPasskeyProxyEnabled', enabled: passkeyProxyToggle.checked });
    });
  };

  addTotpBtn.onclick = () => handleAddTotpClick(currentTabUrl);

  // The Add-2FA section starts hidden (popup.html) and only appears when there is an
  // actual 2FA candidate in context: either detected on the current page (this function)
  // or restored from a pending multi-match picker (restorePendingTotpCandidate). It must
  // stay hidden on ordinary pages, chrome:// pages, and tabs with no content script.
  requestPageTotpCandidate = function (tabId) {
    if (typeof tabId !== 'number' || typeof chrome.tabs.sendMessage !== 'function') return;
    chrome.tabs.sendMessage(tabId, { type: 'queryTotpCandidate' }, (resp) => {
      // Reading lastError marks it "checked" so Chrome doesn't log an "Unchecked
      // runtime.lastError" warning when the tab has no content script listening
      // (chrome:// pages, the Web Store, etc.).
      const lastError = chrome.runtime.lastError;
      if (lastError || !resp || !resp.candidate) return;
      totpPasteInput.value = resp.candidate;
      addTotpSection.hidden = false;
    });
  };

  // A pending ceremony is checked first and, when present, owns the popup outright: the
  // popup was opened *by* that ceremony, and the user is being asked to make a security
  // decision. Running the ordinary credential lookup alongside it would let whichever
  // callback resolved last win the panel.
  rehydratePendingPasskeyCeremony((tookOver) => {
    if (tookOver) return;
    initPasskeySettingsToggle();
    chrome.tabs.query({ active: true, currentWindow: true }, (tabs) => {
      const activeTab = tabs[0];
      if (!activeTab || !activeTab.url) {
        appUnavailableStatusEl.textContent = APP_UNAVAILABLE_STATUS_TEXT;
        showAppUnavailableActions(null);
        return;
      }
      queryCredentials(activeTab.url);
      requestPageTotpCandidate(activeTab.id);
    });
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
    describeSaveProposalOutcome,
    renderTotpPicker,
    routeTotpCandidate,
    restorePendingTotpCandidate,
    handleAddTotpClick,
    requestPageTotpCandidate,
    PENDING_PASSKEY_KEY,
    passkeyCeremonySummary,
    passkeyTargetSummary,
    choosePasskeyPanel,
    rehydratePendingPasskeyCeremony,
    renderPasskeyCeremonyPanel,
    renderPasskeyPicker,
    sendPasskeyCreateConfirm,
    sendPasskeyGetApprove,
    sendPasskeyCancel,
    initPasskeySettingsToggle
  };
}
