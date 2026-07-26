(function () {
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

  function findLoginForm() {
    const passwordInput = document.querySelector('input[type="password"]');
    if (!passwordInput) return null;
    const form = passwordInput.closest('form');
    if (!form) return null;
    const candidates = Array.from(
      form.querySelectorAll('input[type="text"], input[type="email"], input[autocomplete*="username"]')
    );
    const usernameInput = findBestUsernameInput(candidates);
    return { form, passwordInput, usernameInput };
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
    banner.textContent = 'Сохранить пароль в MyPass?';

    const saveButton = document.createElement('button');
    saveButton.textContent = 'Сохранить';
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
    const state = { lastCredentialList: [], bannerShown: false, vaultLocked: false };

    function requestCredentials() {
      chrome.runtime.sendMessage({ type: 'getCredentials', url: location.href }, (response) => {
        // Track lock-state separately from "empty list": a `locked` response
        // also carries no credentials, but is NOT the same as "genuinely no
        // matches for this site" — conflating the two lets the save-banner
        // logic below offer to save a duplicate when the vault was simply
        // locked at page-load time.
        state.vaultLocked = !!(response && response.type === 'locked');
        state.lastCredentialList = (response && response.type === 'credentialList') ? response.credentials : [];
      });
    }

    function attachSubmitListener(loginForm) {
      loginForm.form.addEventListener('submit', () => {
        if (!state.vaultLocked && state.lastCredentialList.length === 0) {
          const username = loginForm.usernameInput ? loginForm.usernameInput.value : '';
          const password = loginForm.passwordInput.value;
          if (password) {
            showSaveBanner(location.href, username, password, state);
          }
        }
      });
    }

    chrome.runtime.onMessage.addListener((message) => {
      if (message.type === 'applyFill') {
        if (!hostnameMatches(message.url, location.href)) {
          console.warn('MyPass: applyFill rejected — message URL does not match the current page hostname');
          return;
        }
        const loginForm = findLoginForm();
        if (!loginForm) return;
        if (loginForm.usernameInput && message.username) {
          setNativeValue(loginForm.usernameInput, message.username);
        }
        setNativeValue(loginForm.passwordInput, message.password);
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
  }

  if (typeof module !== 'undefined') {
    module.exports = { scoreUsernameLikeness, findBestUsernameInput, hostnameMatches };
  }
})();
