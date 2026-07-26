const statusEl = document.getElementById('status');
const listEl = document.getElementById('list');

function setStatus(text) {
  statusEl.textContent = text;
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

chrome.tabs.query({ active: true, currentWindow: true }, (tabs) => {
  const activeTab = tabs[0];
  if (!activeTab || !activeTab.url) {
    setStatus('MyPass not found. Make sure the app is installed and has been launched at least once (to register the native messaging host).');
    return;
  }
  const url = activeTab.url;

  chrome.runtime.sendMessage({ type: 'getCredentials', url }, (response) => {
    if (!response || response.type === 'error') {
      setStatus('MyPass not found. Make sure the app is installed and has been launched at least once (to register the native messaging host).');
      return;
    }
    if (response.type === 'locked') {
      setStatus('Open MyPass and unlock the vault');
      return;
    }
    if (response.type === 'credentialList') {
      if (response.credentials.length === 0) {
        setStatus('No saved logins for this site');
        return;
      }
      setStatus('Select an entry to autofill:');
      renderCredentials(response.credentials, url);
    }
  });
});
