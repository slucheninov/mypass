const assert = require('node:assert/strict');
const { describeBrowserCheck } = require('../browser-check.js');

assert.equal(describeBrowserCheck({ permissionState: 'not-granted' }).visible, false);
assert.match(describeBrowserCheck({ permissionState: 'unavailable' }).status, /could not be read/);
const complete = { permissionState: 'granted', extensionScanState: 'complete', passwordSavingEnabled: false, extensions: [], reported: true };
assert.match(describeBrowserCheck(complete).passwordSaving, /manual check/);
assert.match(describeBrowserCheck(complete).extensions, /No known/);
assert.match(describeBrowserCheck({ ...complete, extensionScanState: 'unavailable' }).extensions, /Could not/);
assert.match(describeBrowserCheck({ ...complete, reported: false }).status, /check again/);
assert.equal(describeBrowserCheck({ ...complete, extensions: [{ name: '1Password' }, { name: 'iCloud Passwords' }] }).extensions, '1Password, iCloud Passwords');

const sent = [];
let granted = false;
let managementFails = false;
let privacyFails = false;
let browserSettingsOpened = 0;
global.chrome = {
  runtime: {
    id: 'extension-id', getURL: (path) => 'chrome-extension://extension-id/' + path,
    onMessage: { addListener() {} },
    sendNativeMessage: (_host, message, callback) => {
      sent.push(message);
      if (message.type === 'openBrowserSettings') browserSettingsOpened++;
      callback({ type: 'acknowledged' });
    }
  },
  storage: { local: { get: (_keys, cb) => cb({ pairingSecret: 'test-pairing' }), set: (_items, cb) => cb && cb(), remove: (_keys, cb) => cb && cb() } },
  permissions: { contains: async () => granted },
  privacy: { services: { passwordSavingEnabled: { get: async () => { if (privacyFails) throw Error('denied'); return { value: true }; } } } },
  management: { getAll: async () => {
    if (managementFails) throw Error('denied');
    return [{ id: 'aeblfdkhhhdcdjpifhhbdiojplfjncoa', name: '1Password', enabled: true },
      { id: 'pejdijmoenmkgeppbflobdenhhabjlaj', name: 'iCloud Passwords', enabled: true },
      { id: 'other', name: 'Unrelated', enabled: true }];
  } }
};
const { getBrowserManagerDiagnostics, reportBrowserDiagnostics, handleRuntimeMessage } = require('../background.js');
(async () => {
  let result = await getBrowserManagerDiagnostics();
  assert.equal(result.permissionState, 'not-granted');
  assert.equal(result.extensionScanState, 'not-checked');
  granted = true;
  result = await getBrowserManagerDiagnostics();
  assert.equal(result.extensionScanState, 'complete');
  assert.deepEqual(result.extensions.map((item) => item.name), ['1Password', 'iCloud Passwords']);
  assert.equal(await reportBrowserDiagnostics({ proxyState: 'active' }, result), true);
  assert.deepEqual(sent.at(-1).report, {
    proxyState: 'active', permissionState: 'granted', passwordSavingEnabled: true,
    extensionScanState: 'complete', enabledManagers: ['1Password', 'iCloud Passwords']
  });
  managementFails = true;
  result = await getBrowserManagerDiagnostics();
  assert.equal(result.permissionState, 'granted', 'failed inspection does not imply missing permission');
  assert.equal(result.extensionScanState, 'unavailable');
  assert.equal(result.passwordSavingEnabled, true, 'partial result preserves privacy observation');
  privacyFails = true;
  result = await getBrowserManagerDiagnostics();
  assert.equal(result.passwordSavingEnabled, null);
  const website = { id: 'extension-id', tab: { id: 1 }, url: 'https://example.com' };
  assert.equal(handleRuntimeMessage({ type: 'openBrowserSettings' }, website, () => {}), false);
  assert.equal(handleRuntimeMessage({ type: 'getBrowserManagerDiagnostics' }, website, () => {}), false);
  assert.equal(browserSettingsOpened, 0);
  await new Promise((resolve) => {
    assert.equal(handleRuntimeMessage({ type: 'openBrowserSettings' }, {
      id: 'extension-id', tab: { id: 2 }, url: 'chrome-extension://extension-id/browser-check.html'
    }, (response) => { assert.equal(response.type, 'acknowledged'); resolve(); }), true);
  });
  assert.equal(browserSettingsOpened, 1);
  console.log('browserSettings.test.js: separate permission/results, authenticated report and extension-page boundary OK');
})().catch((error) => { console.error(error); process.exitCode = 1; });
