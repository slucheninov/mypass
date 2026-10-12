const assert = require('node:assert');
const path = require('node:path');

const elements = {};
function makeEl(id) {
  const el = {
    id,
    hidden: id !== '',
    textContent: '',
    value: '',
    checked: false,
    disabled: false,
    onclick: null,
    className: '',
    style: {},
    children: [],
    listeners: {},
    appendChild(child) { this.children.push(child); },
    addEventListener(name, fn) { (this.listeners[name] = this.listeners[name] || []).push(fn); },
    setAttribute(name, value) { this[name] = value; }
  };
  let innerHTML = '';
  Object.defineProperty(el, 'innerHTML', {
    get() { return innerHTML; },
    set(value) {
      innerHTML = value;
      if (value === '') el.children = [];
    }
  });
  elements[id] = el;
  return el;
}

const sentMessages = [];
const createdTabs = [];
const createdWindows = [];
let activeTab = { url: 'chrome://extensions/', id: 7 };
let settingsResponse = { type: 'ok' };
let lockVaultResponse = { type: 'ok' };
let openAppResponse = { type: 'ok' };
let passkeyStatusResponse = { type: 'passkeyProxyStatus', unlocked: true, paired: true, attachAllowed: true, enabled: true };
let passkeySetResponse = (msg) => ({ type: 'passkeyProxyEnabled', enabled: !!msg.enabled });

global.document = {
  getElementById: (id) => elements[id] || makeEl(id),
  createElement: () => makeEl(`created-${Object.keys(elements).length}`)
};
global.window = {
  close() { elClosed += 1; },
  screen: { availWidth: 1440, availHeight: 900, availLeft: 0, availTop: 0 }
};
let elClosed = 0;

global.chrome = {
  storage: {
    local: {
      get: (_keys, cb) => cb({}),
      set: (_items, cb) => cb && cb(),
      remove: (_keys, cb) => cb && cb()
    },
    session: {
      get: (_keys, cb) => cb({}),
      set: (_items, cb) => cb && cb(),
      remove: (_keys, cb) => cb && cb()
    }
  },
  runtime: {
    lastError: null,
    getURL(path) { return 'chrome-extension://hjijbabodfldconmhdcdphlbgaajkejn/' + path; },
    sendMessage(msg, cb) {
      sentMessages.push(msg);
      if (!cb) return;
      if (msg.type === 'openBrowserSettings') { cb(settingsResponse); return; }
      if (msg.type === 'lockVault') { cb(lockVaultResponse); return; }
      if (msg.type === 'openApp') { cb(openAppResponse); return; }
      if (msg.type === 'getPasskeyProxyStatus') { cb(passkeyStatusResponse); return; }
      if (msg.type === 'setPasskeyProxyEnabled') { cb(passkeySetResponse(msg)); return; }
      if (msg.type === 'listEntries') {
        cb({
          type: 'credentialList',
          credentials: msg.category === 'favorites'
            ? [
                { id: 'fav-1', title: 'Alpha', username: 'ada', url: 'https://alpha.example/login', hasTotp: false, hasPasskey: false },
                { id: 'fav-2', title: 'No Site', username: 'bob', hasTotp: true, hasPasskey: false }
              ]
            : [{ id: 'all-1', title: 'All Item', username: 'sam', url: 'https://all.example', hasTotp: false, hasPasskey: false }]
        });
        return;
      }
      if (msg.type === 'searchEntries') {
        cb({
          type: 'credentialList',
          credentials: [{ id: 's-1', title: 'Search Hit', username: 'sue', url: 'https://search.example', hasTotp: false, hasPasskey: false }]
        });
        return;
      }
      if (msg.type === 'getGeneratedPasswordHistory') {
        cb({
          type: 'generatedPasswordHistory',
          entries: [{ id: 'h1', password: 'secret-history', url: 'https://bank.example/signup', createdAt: 1 }]
        });
        return;
      }
      if (msg.type === 'getCredentials') {
        cb({ type: 'credentialList', credentials: [{ id: 'site-1', title: 'Example', username: 'alice', hasPasskey: false }] });
        return;
      }
      cb({ type: 'ok' });
    }
  },
  tabs: {
    query(_opts, cb) { cb([activeTab]); },
    create(props, cb) {
      createdTabs.push(props);
      if (cb) cb({ id: 42 });
    },
    sendMessage() {}
  },
  windows: {
    create(props, cb) {
      createdWindows.push(props);
      if (cb) cb({ id: 8 });
    }
  }
};

function loadPopup() {
  const resolved = require.resolve(path.join(__dirname, '..', 'popup.js'));
  delete require.cache[resolved];
  sentMessages.length = 0;
  createdTabs.length = 0;
  createdWindows.length = 0;
  elClosed = 0;
  for (const key of Object.keys(elements)) delete elements[key];
  return require(resolved);
}

const siteProbe = loadPopup();
assert.strictEqual(siteProbe.isSiteUrl('https://example.com/login'), true);
assert.strictEqual(siteProbe.isSiteUrl('http://example.com'), true);
assert.strictEqual(siteProbe.isSiteUrl('chrome://extensions/'), false);
assert.strictEqual(siteProbe.isSiteUrl('chrome://newtab/'), false);
assert.strictEqual(siteProbe.isSiteUrl('about:blank'), false);
assert.strictEqual(siteProbe.isSiteUrl(''), false);
assert.strictEqual(siteProbe.isSiteUrl(undefined), false);
assert.strictEqual(siteProbe.FAVORITES_HEADER_TEXT, 'Favorites');
assert.strictEqual(siteProbe.NO_FAVORITES_TEXT, 'No favorites');

assert.ok(
  sentMessages.some((message) => message.type === 'listEntries' && message.category === 'favorites'),
  'chrome://extensions asks for favorites'
);
assert.ok(!sentMessages.some((message) => message.type === 'getCredentials'), 'a browser page does not look up a site');
assert.strictEqual(elements['category-btn'].textContent, 'Favorites ▾');
assert.strictEqual(elements['list-panel'].hidden, false);
assert.strictEqual(elements['browser-chrome'].hidden, false);
assert.strictEqual(elements['app-unavailable-panel'].hidden, true);
assert.strictEqual(elements['settings-panel'], undefined, 'settings are hosted by the native app');
assert.strictEqual(elements['popup-menu'].hidden, true, 'the menu stays closed on the credential list');
assert.strictEqual(elements['browser-chrome'].hidden, false, 'the gear stays with the search field');

const rows = elements['list'].children;
assert.strictEqual(rows.length, 2);
rows[0].listeners.click[0]();
assert.deepStrictEqual(createdTabs, [{ url: 'https://alpha.example/login', active: true }]);
assert.strictEqual(elClosed, 1);
assert.ok(
  sentMessages.some((message) => message.type === 'armOpenAndFill' && message.tabId === 42 && message.id === 'fav-1'),
  'opening a favorite arms a fill for the new tab'
);
assert.ok(!sentMessages.some((message) => message.type === 'fillCredential'), 'the popup does not fill the chrome:// tab');

rows[1].listeners.click[0]();
assert.strictEqual(createdTabs.length, 1, 'a favorite with no http(s) URL is not opened');
assert.strictEqual(rows[1].children.some((child) => child.className === 'totp-circle'), false, 'TOTP needs a site URL to ask the app');

elements['open-settings-btn'].listeners.click[0]();
assert.deepStrictEqual(sentMessages.at(-1), { type: 'openBrowserSettings' });
assert.strictEqual(elements['settings-open-error'].hidden, true, 'native acknowledgement confirms settings opened');
assert.strictEqual(elements['list-panel'].hidden, false, 'opening native settings preserves the browse panel');
assert.strictEqual(elements['category-btn'].textContent, 'Favorites ▾');
assert.strictEqual(elements['popup-menu'].hidden, true, 'opening native settings leaves the menu closed');
assert.strictEqual(elements['passkey-proxy-toggle'], undefined, 'no duplicate native toggle in the popup');
settingsResponse = { type: 'error', code: 'app_not_running' };
elements['open-settings-btn'].listeners.click[0]();
assert.strictEqual(elements['settings-open-error'].hidden, false);
assert.match(elements['settings-open-error'].textContent, /Open MyPass.*Settings → Browser/);
assert.strictEqual(elements['list-panel'].hidden, false, 'failed settings launch does not hide favorites');
settingsResponse = { type: 'ok' };
elements['open-settings-btn'].listeners.click[0]();
assert.strictEqual(elements['settings-open-error'].hidden, true, 'successful retry clears the recovery message');

function hasText(node, text) {
  if (!node) return false;
  if (node.textContent === text) return true;
  return (node.children || []).some((child) => hasText(child, text));
}

elements['vault-search'].value = 'ada';
elements['vault-search'].listeners.input[0]();
assert.ok(sentMessages.some((message) => message.type === 'searchEntries' && message.query === 'ada'));
assert.ok(hasText(elements['list'].children[0], 'Search Hit'));

const allButton = elements['category-menu'].children.find((child) => child.textContent === 'All');
allButton.listeners.click[0]();
assert.ok(sentMessages.some((message) => message.type === 'listEntries' && message.category === 'all'));
assert.strictEqual(elements['category-btn'].textContent, 'All ▾');
assert.strictEqual(elements['vault-search'].value, '');

elements['add-entry-btn'].listeners.click[0]();
assert.strictEqual(elements['add-entry-menu'].hidden, false);
const loginChoice = elements['add-entry-menu'].children.find((child) => hasText(child, 'New login'));
loginChoice.listeners.click[0]();
assert.strictEqual(createdWindows.length, 1);
assert.strictEqual(createdWindows[0].type, 'popup');
assert.strictEqual(createdWindows[0].width, 520);
assert.strictEqual(createdWindows[0].height, 760);
assert.strictEqual(createdWindows[0].left, Math.round((1440 - 520) / 2));
assert.ok(createdWindows[0].url.includes('create.html?'));
assert.ok(createdWindows[0].url.includes('type=Login'));
assert.strictEqual(elClosed, 2, 'the popup closes after the create window opens');

elements['open-generator-btn'].listeners.click[0]();
assert.ok(createdWindows[1].url.includes('generator.html?'));
assert.ok(createdWindows[1].url.includes('purpose=autofill'));
assert.strictEqual(createdWindows[1].width, 420);
assert.strictEqual(createdWindows[1].left, Math.round((1440 - 420) / 2));

activeTab = { id: 1 };
loadPopup();
assert.ok(
  sentMessages.some((message) => message.type === 'listEntries' && message.category === 'favorites'),
  'a tab with no URL asks for favorites'
);

activeTab = { url: 'chrome://newtab/', id: 2 };
loadPopup();
assert.ok(
  sentMessages.some((message) => message.type === 'listEntries' && message.category === 'favorites'),
  'the new tab asks for favorites'
);

activeTab = { url: 'https://example.com/login', id: 3 };
loadPopup();
assert.ok(sentMessages.some((message) => message.type === 'getCredentials'), 'a website still asks for matching logins');
assert.ok(!sentMessages.some((message) => message.type === 'listEntries' && message.category === 'favorites'));
assert.strictEqual(elements['category-btn'].textContent, 'This site ▾');

elements['add-entry-btn'].listeners.click[0]();
elements['add-entry-menu'].children.find((child) => hasText(child, 'New login')).listeners.click[0]();
assert.ok(decodeURIComponent(createdWindows[0].url).includes('type=Login'));
assert.ok(decodeURIComponent(createdWindows[0].url).includes('https://example.com/login'));
elements['add-entry-menu'].children.find((child) => hasText(child, 'New card')).listeners.click[0]();
assert.ok(createdWindows[1].url.includes('type=Card'));
assert.strictEqual(createdWindows[1].height, 680);
elements['add-entry-menu'].children.find((child) => hasText(child, 'New note')).listeners.click[0]();
assert.ok(createdWindows[2].url.includes('type=Notes'));
assert.strictEqual(createdWindows[2].height, 640);
elements['open-generator-btn'].listeners.click[0]();
assert.ok(decodeURIComponent(createdWindows[3].url).includes('https://example.com/login'));

const background = require('node:fs').readFileSync(path.join(__dirname, '..', 'background.js'), 'utf8');
assert.ok(background.includes('"listEntries"'), 'background.js forwards listEntries to the app');
assert.ok(background.includes('"searchEntries"'));
assert.ok(background.includes('"createEntry"'));

const html = require('node:fs').readFileSync(path.join(__dirname, '..', 'popup.html'), 'utf8');
const generalHtml = html.split('id="popup-menu-general"')[1].split('id="popup-menu-help"')[0];
assert.ok(!html.includes('Use MyPass for Chrome passkeys'));
assert.ok(!html.includes('id="settings-panel"') && !html.includes('id="passkey-proxy-toggle"'));
assert.ok(!html.includes('id="passkey-settings-footer"'));
assert.ok(generalHtml.includes('id="open-settings-btn"') && generalHtml.includes('MyPass settings'));
assert.ok(generalHtml.includes('id="check-browser-managers-btn"') && generalHtml.includes('Check this browser'));
const securityHtml = html.split('id="popup-menu-security"')[1].split('id="popup-menu-help"')[0];
assert.ok(securityHtml.includes('id="open-mypass-app-btn"') && securityHtml.includes('Open MyPass'));
assert.ok(securityHtml.includes('id="warn-unrecognized-paste"'));
assert.ok(securityHtml.includes('id="warn-unrecognized-copy"'));
assert.ok(!securityHtml.includes('Ask before filling'));
const autofillHtml = html.split('id="popup-menu-autofill"')[1].split('id="popup-menu-help"')[0];
assert.ok(autofillHtml.includes('id="offer-save-login"') && autofillHtml.includes('Offer to save new logins'));
assert.ok(autofillHtml.includes('id="offer-save-totp"') && autofillHtml.includes('Offer to save a 2FA code'));
assert.ok(autofillHtml.includes('id="show-field-icon"'));
assert.ok(autofillHtml.includes('id="autofill-auto-submit"') && autofillHtml.includes('Sign in after filling'));
assert.ok(autofillHtml.includes('id="autofill-passkey-signin"') && autofillHtml.includes('Offer to sign in with a passkey'));
assert.ok(autofillHtml.includes('id="suggest-logins"') && autofillHtml.includes('id="suggest-cards"') && autofillHtml.includes('id="suggest-addresses"'));
assert.ok(!autofillHtml.includes('SSH') && !autofillHtml.includes('cache') && !html.includes('passkey-proxy-toggle'));
const notificationsHtml = html.split('id="popup-menu-notifications"')[1].split('id="popup-menu-placeholder"')[0];
assert.ok(notificationsHtml.includes('id="notify-passkey-confirmation"') && notificationsHtml.includes('Notify when a passkey needs confirmation'));
assert.ok(notificationsHtml.includes('id="notify-vault-unlocked"') && notificationsHtml.includes('Notify when MyPass is unlocked'));
assert.ok(notificationsHtml.includes('‹ Notifications'));
assert.ok(!notificationsHtml.includes('Watchtower') && !html.includes('Watchtower'));
assert.ok(!notificationsHtml.includes('breach'));
const appearanceHtml = html.split('id="popup-menu-appearance"')[1];
assert.ok(appearanceHtml.includes('id="appearance-theme"') && appearanceHtml.includes('Match system'));
assert.ok(appearanceHtml.includes('>Light</option>') && appearanceHtml.includes('>Dark</option>'));
assert.ok(appearanceHtml.includes('id="shortcut-open"') && appearanceHtml.includes('Open MyPass'));
assert.ok(appearanceHtml.includes('id="shortcut-lock"') && appearanceHtml.includes('Lock MyPass'));
assert.ok(appearanceHtml.includes('id="open-shortcut-settings"') && appearanceHtml.includes('Chrome shortcuts page'));
assert.ok(!appearanceHtml.includes('Language') && !html.includes('favicon'));
assert.ok(html.includes('Lock MyPass'));
assert.ok(html.includes('>Settings</button>'));
assert.ok(html.includes('>Help</button>'));
const searchAt = html.indexOf('id="vault-search"');
const gearAt = html.indexOf('id="popup-menu-btn"');
const generatorAt = html.indexOf('id="open-generator-btn"');
assert.ok(gearAt !== -1 && gearAt < searchAt && searchAt < generatorAt, 'the gear sits to the left of search');
assert.ok(html.includes('id="vault-search"'));
assert.ok(html.includes('id="open-generator-btn"'));
assert.ok(html.includes('id="add-entry-btn"'));
assert.ok(html.includes('aria-label="Password generator"'));
assert.ok(html.includes('aria-label="MyPass menu"'));

elements['popup-menu-btn'].listeners.click[0]();
assert.strictEqual(elements['popup-menu'].hidden, false);
assert.strictEqual(elements['popup-menu-root'].hidden, false);
assert.strictEqual(elements['popup-menu-settings'].hidden, true);
assert.strictEqual(elements['popup-menu-btn']['aria-expanded'], 'true');
elements['popup-menu-settings-btn'].listeners.click[0]();
assert.strictEqual(elements['popup-menu-settings'].hidden, false);
assert.strictEqual(elements['popup-menu-root'].hidden, true);
elements['popup-menu-open-general'].listeners.click[0]();
assert.strictEqual(elements['popup-menu-general'].hidden, false);
elements['popup-menu-general-back'].listeners.click[0]();
assert.strictEqual(elements['popup-menu-settings'].hidden, false);
elements['popup-menu-open-security'].listeners.click[0]();
assert.strictEqual(elements['popup-menu-security'].hidden, false);
assert.strictEqual(elements['popup-menu-placeholder'].hidden, true);
assert.strictEqual(elements['warn-unrecognized-paste'].checked, true, 'paste warning starts on');
assert.strictEqual(elements['warn-unrecognized-copy'].checked, true, 'copy warning starts on');
let savedSecurity;
const previousSet = chrome.storage.local.set;
chrome.storage.local.set = (items, cb) => { savedSecurity = items; if (cb) cb(); };
elements['warn-unrecognized-paste'].checked = false;
elements['warn-unrecognized-paste'].listeners.change[0]();
assert.strictEqual(savedSecurity.mypassSecuritySettings.warnPaste, false);
assert.strictEqual(savedSecurity.mypassSecuritySettings.warnCopy, true);
chrome.storage.local.set = previousSet;
elements['open-mypass-app-btn'].listeners.click[0]();
assert.strictEqual(sentMessages.at(-1).type, 'openApp');
assert.strictEqual(elements['open-mypass-app-error'].hidden, true);
openAppResponse = { type: 'pairingRequired' };
elements['open-mypass-app-btn'].listeners.click[0]();
assert.match(elements['open-mypass-app-error'].textContent, /Connect this browser/);
assert.strictEqual(elements['open-mypass-app-error'].hidden, false);
elements['popup-menu-security-back'].listeners.click[0]();
elements['popup-menu-open-autofill'].listeners.click[0]();
assert.strictEqual(elements['popup-menu-autofill'].hidden, false);
assert.strictEqual(elements['popup-menu-placeholder'].hidden, true);
assert.strictEqual(elements['offer-save-login'].checked, true, 'saving a login stays on');
assert.strictEqual(elements['offer-save-totp'].checked, true);
assert.strictEqual(elements['show-field-icon'].checked, true);
assert.strictEqual(elements['suggest-logins'].checked, true);
assert.strictEqual(elements['suggest-cards'].checked, true);
assert.strictEqual(elements['suggest-addresses'].checked, true);
assert.strictEqual(elements['autofill-auto-submit'].checked, false, 'signing in after a fill stays off');
assert.strictEqual(elements['autofill-passkey-signin'].checked, true, 'the passkey switch follows the app');
let savedAutofill;
const previousAutofillSet = chrome.storage.local.set;
chrome.storage.local.set = (items, cb) => { savedAutofill = items; if (cb) cb(); };
elements['offer-save-login'].checked = false;
elements['autofill-auto-submit'].checked = true;
elements['offer-save-login'].listeners.change[0]();
assert.strictEqual(savedAutofill.mypassAutofillSettings.offerSaveLogin, false);
assert.strictEqual(savedAutofill.mypassAutofillSettings.autoSubmit, true);
assert.strictEqual(savedAutofill.mypassAutofillSettings.offerSaveTotp, true);
assert.strictEqual(savedAutofill.mypassAutofillSettings.showCards, true);
assert.ok(!Object.prototype.hasOwnProperty.call(savedAutofill.mypassAutofillSettings, 'passkeyProxyEnabled'));
chrome.storage.local.set = previousAutofillSet;
elements['autofill-passkey-signin'].checked = false;
elements['autofill-passkey-signin'].listeners.change[0]();
assert.deepStrictEqual(sentMessages.at(-1), { type: 'setPasskeyProxyEnabled', enabled: false });
assert.strictEqual(elements['autofill-passkey-error'].hidden, true);
passkeySetResponse = () => ({ type: 'locked' });
elements['autofill-passkey-signin'].checked = true;
elements['autofill-passkey-signin'].listeners.change[0]();
assert.strictEqual(elements['autofill-passkey-signin'].checked, false, 'a locked vault puts the switch back');
assert.match(elements['autofill-passkey-error'].textContent, /Unlock MyPass/);
elements['popup-menu-autofill-back'].listeners.click[0]();
assert.strictEqual(elements['popup-menu-settings'].hidden, false);
elements['popup-menu-open-notifications'].listeners.click[0]();
assert.strictEqual(elements['popup-menu-notifications'].hidden, false);
assert.strictEqual(elements['popup-menu-placeholder'].hidden, true);
assert.strictEqual(elements['notify-passkey-confirmation'].checked, true, 'passkey notifications start on');
assert.strictEqual(elements['notify-vault-unlocked'].checked, true, 'unlock notifications start on');
let savedNotifications;
const previousNotificationSet = chrome.storage.local.set;
chrome.storage.local.set = (items, cb) => { savedNotifications = items; if (cb) cb(); };
elements['notify-passkey-confirmation'].checked = false;
elements['notify-passkey-confirmation'].listeners.change[0]();
assert.strictEqual(savedNotifications.mypassNotificationSettings.passkeyConfirmation, false);
assert.strictEqual(savedNotifications.mypassNotificationSettings.vaultUnlocked, true);
chrome.storage.local.set = previousNotificationSet;
elements['popup-menu-notifications-back'].listeners.click[0]();
assert.strictEqual(elements['popup-menu-settings'].hidden, false);
elements['popup-menu-open-appearance'].listeners.click[0]();
assert.strictEqual(elements['popup-menu-appearance'].hidden, false);
assert.strictEqual(elements['popup-menu-placeholder'].hidden, true);
assert.strictEqual(elements['appearance-theme'].value, 'system', 'theme starts by matching the system');
assert.strictEqual(elements['shortcut-open'].textContent, 'Not set');
assert.strictEqual(elements['shortcut-lock'].textContent, 'Not set');
let savedAppearance;
const previousAppearanceSet = chrome.storage.local.set;
chrome.storage.local.set = (items, cb) => { savedAppearance = items; if (cb) cb(); };
elements['appearance-theme'].value = 'dark';
elements['appearance-theme'].listeners.change[0]();
assert.strictEqual(savedAppearance.mypassAppearanceSettings.theme, 'dark');
chrome.storage.local.set = previousAppearanceSet;
elements['open-shortcut-settings'].listeners.click[0]();
assert.strictEqual(createdTabs.at(-1).url, 'chrome://extensions/shortcuts');
elements['popup-menu-appearance-back'].listeners.click[0]();
assert.strictEqual(elements['popup-menu-settings'].hidden, false);
elements['popup-menu-open-about'].listeners.click[0]();
assert.strictEqual(elements['popup-menu-placeholder'].hidden, false);
assert.strictEqual(elements['popup-menu-placeholder-back'].textContent, '‹ About');
elements['popup-menu-placeholder-back'].listeners.click[0]();
elements['popup-menu-settings-back'].listeners.click[0]();
elements['popup-menu-help-btn'].listeners.click[0]();
assert.strictEqual(elements['popup-menu-help'].hidden, false);
elements['popup-menu-help-back'].listeners.click[0]();
assert.strictEqual(elements['popup-menu-root'].hidden, false);
lockVaultResponse = { type: 'pairingRequired' };
elements['lock-vault-btn'].listeners.click[0]();
assert.strictEqual(sentMessages.at(-1).type, 'lockVault');
assert.strictEqual(elements['lock-vault-error'].hidden, false);
assert.match(elements['lock-vault-error'].textContent, /Connect this browser/);
assert.strictEqual(elements['list-panel'].hidden, false, 'a refused lock keeps the list');
lockVaultResponse = { type: 'ok' };
elements['lock-vault-btn'].listeners.click[0]();
assert.strictEqual(elements['locked-panel'].hidden, false);
assert.strictEqual(elements['popup-menu'].hidden, true, 'locking closes the menu');

console.log('favoritesPopup.test.js: OK');

// Passkeys browsing opens the relying-party site without arming password injection.
const passkeyPopup = loadPopup();
const passkeysButton = elements['category-menu'].children.find((child) => child.textContent === 'Passkeys');
passkeysButton.listeners.click[0]();
assert.ok(sentMessages.some((message) => message.type === 'listEntries' && message.category === 'passkeys'));
assert.strictEqual(elements['site-passkey-hint'].hidden, false);
assert.strictEqual(elements['site-passkey-hint'].textContent, 'Select an entry to open its website.');
sentMessages.length = 0;
elements['list'].children[0].listeners.click[0]();
assert.deepStrictEqual(createdTabs, [{ url: 'https://all.example', active: true }]);
assert.ok(!sentMessages.some((message) => ['armOpenAndFill', 'fillCredential'].includes(message.type)));
passkeyPopup.renderCredentials([{ id: 'unsafe', title: 'Unsafe', url: 'javascript:alert(1)', hasPasskey: true }], null, { openSavedUrl: true, passkeyOnly: true });
elements['list'].children[0].listeners.click[0]();
assert.strictEqual(createdTabs.length, 1, 'passkey navigation rejects non-http(s) URLs');
console.log('favoritesPopup.test.js: passkeys open safe websites without password fill OK');
