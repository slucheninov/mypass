const PAIRING_STARTED_AT_KEY = 'pairingStartedAt';
const PAIRING_CHALLENGE_TTL_MS = 120_000;

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
  const statusEl = document.getElementById('status');
  const listEl = document.getElementById('list');
  const pairingPanel = document.getElementById('pairing-panel');
  const connectBtn = document.getElementById('connect-btn');
  const codeEntry = document.getElementById('code-entry');
  const codeInput = document.getElementById('code-input');
  const submitCodeBtn = document.getElementById('submit-code-btn');
  const pairingErrorEl = document.getElementById('pairing-error');

  function setStatus(text) {
    statusEl.textContent = text;
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
    statusEl.hidden = true;
    listEl.hidden = true;
    pairingPanel.hidden = false;
  }

  function hidePairingPanel() {
    pairingPanel.hidden = true;
    statusEl.hidden = false;
    listEl.hidden = false;
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

  function renderCredentials(credentials, url) {
    listEl.innerHTML = '';
    credentials.forEach((credential) => {
      const item = document.createElement('li');

      const title = document.createElement('div');
      title.className = 'title';
      title.textContent = credential.title;

      const username = document.createElement('div');
      username.className = 'username';
      username.textContent = credential.username;

      item.appendChild(title);
      item.appendChild(username);
      item.addEventListener('click', () => {
        chrome.runtime.sendMessage({ type: 'fillCredential', id: credential.id, url }, () => {
          window.close();
        });
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

  function handleCredentialsResponse(response, url) {
    const kind = classifyGetCredentialsResponse(response);
    if (kind === 'error') {
      setStatus('MyPass not found. Make sure the app is installed and has been launched at least once (to register the native messaging host).');
      return;
    }
    if (kind === 'locked') {
      setStatus('Open MyPass and unlock the vault');
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
        setStatus('No saved logins for this site');
        return;
      }
      setStatus('Select an entry to autofill:');
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
      setStatus('MyPass not found. Make sure the app is installed and has been launched at least once (to register the native messaging host).');
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
    PAIRING_CHALLENGE_TTL_MS
  };
}
