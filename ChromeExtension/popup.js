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
    setStatus('MyPass не найден. Убедитесь, что приложение установлено и один раз запущено (для регистрации native messaging хоста).');
    return;
  }
  const url = activeTab.url;

  chrome.runtime.sendMessage({ type: 'getCredentials', url }, (response) => {
    if (!response || response.type === 'error') {
      setStatus('MyPass не найден. Убедитесь, что приложение установлено и один раз запущено (для регистрации native messaging хоста).');
      return;
    }
    if (response.type === 'locked') {
      setStatus('Откройте MyPass и разблокируйте хранилище');
      return;
    }
    if (response.type === 'credentialList') {
      if (response.credentials.length === 0) {
        setStatus('Нет сохранённых логинов для этого сайта');
        return;
      }
      setStatus('Выберите запись для автозаполнения:');
      renderCredentials(response.credentials, url);
    }
  });
});
