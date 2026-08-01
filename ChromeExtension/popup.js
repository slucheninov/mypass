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

function classifyGetCredentialsResponse(response) {
  if (!response || response.type === 'error') return 'error';
  if (response.type === 'locked') return 'locked';
  if (response.type === 'pairingRequired') return 'pairingRequired';
  if (response.type === 'credentialList') return 'credentialList';
  return 'unknown';
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

if (typeof document !== 'undefined') {
  const lockedPanel = document.getElementById('locked-panel');
  const lockedTitleEl = document.getElementById('locked-title');
  const lockedHelperEl = document.getElementById('locked-helper');
  const lockedRetryBtn = document.getElementById('locked-retry-btn');

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

  function queryCredentials(url) {
    chrome.runtime.sendMessage({ type: 'getCredentials', url }, (response) => {
      handleCredentialsResponse(response, url);
    });
  }

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
    PAIRING_PANEL_TITLE_TEXT
  };
}
