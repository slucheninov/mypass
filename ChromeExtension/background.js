const NATIVE_HOST_NAME = "com.mypass.chromehost";
const PAIRING_STORAGE_KEY = "pairingSecret";
const knownTypes = [
  "getCredentials", "getFavorites", "listEntries", "searchEntries", "createEntry", "addEntryIdentifier",
  "fillCredential", "getTotp", "proposeSaveLogin", "proposeSaveTotp",
  "startPairing", "completePairing", "requestUnlock",
  "getPasskeyProxyStatus", "setPasskeyProxyEnabled", "passkeyCreateConfirm", "passkeyGetApprove",
  "generatePassword"
];

const PASSKEY_WATCHDOG_MS = 120000;
const PASSKEY_WATCHDOG_ALARM = "passkeyCeremonyWatchdog";
const PASSKEY_REFRESH_ALARM = "passkeyProxyRefresh";
let proxyRefresh = null;
// Last boolean unlock reading in this worker. null means none yet, so the
// first poll after a worker start does not count as an unlock.
let vaultWasUnlocked = null;
let passkeyStateQueue = Promise.resolve();
let proxyOperationQueue = Promise.resolve();

function withPasskeyState(operation) {
  const result = passkeyStateQueue.then(operation);
  passkeyStateQueue = result.catch(() => {});
  return result;
}

function withProxyOperation(operation) {
  const result = proxyOperationQueue.then(operation);
  proxyOperationQueue = result.catch(() => {});
  return result;
}
const dispatchingPasskeys = new Set();
const cancelledPasskeys = new Set();
const PENDING_KEY = "pendingPasskeyCeremony";
const PASSKEY_FAILURE_KEY = "lastPasskeyFailure";
const PASSKEY_ENABLED_KEY = "passkeyProxyEnabled";
const GENERATED_HISTORY_KEY = "generatedPasswordHistory";
let localHistoryMigration = null;
const PENDING_OPEN_FILL_KEY = "pendingOpenFill";
const PENDING_OPEN_FILL_TTL_MS = 20000;

function detectBrowserName() {
  const brands = (navigator.userAgentData && navigator.userAgentData.brands) || [];
  const brand = brands.find((b) => b.brand && b.brand !== "Chromium" && !/Not.?A.?Brand/i.test(b.brand));
  return brand ? brand.brand : "Chromium browser";
}

function attachPairingField(message, pairingSecret) {
  if (!pairingSecret) return message;
  return { ...message, pairing: pairingSecret };
}

function persistPairingResponse(response) {
  return new Promise((resolve) => {
    if (response && response.type === "paired" && response.secret) {
      chrome.storage.local.set({ [PAIRING_STORAGE_KEY]: response.secret }, resolve);
    } else {
      resolve();
    }
  });
}

function clearStaleSecretOnPairingRequired(response, previousSecret) {
  return new Promise((resolve) => {
    if (response && response.type === "pairingRequired" && previousSecret) {
      chrome.storage.local.remove(PAIRING_STORAGE_KEY, resolve);
    } else {
      resolve();
    }
  });
}

function readPairingSecret() {
  return new Promise((resolve) => {
    chrome.storage.local.get(PAIRING_STORAGE_KEY, (result) => {
      resolve(result[PAIRING_STORAGE_KEY] || null);
    });
  });
}

function sendNativeMessage(message) {
  return new Promise((resolve) => {
    chrome.runtime.sendNativeMessage(NATIVE_HOST_NAME, message, (response) => {
      const runtimeError = chrome.runtime.lastError;
      if (runtimeError || !response) {
        // A host exit or a broken loopback connection does not mean the app is
        // absent. Only Chrome's explicit missing-host error proves setup is missing.
        // Keep raw runtime errors out of replies; they can contain local paths.
        const code = runtimeError && /^Specified native messaging host not found\.?$/i.test(runtimeError.message || "")
          ? "native_host_not_found" : "connection_unavailable";
        resolve({ type: "error", code, message: code });
        return;
      }
      resolve(response);
    });
  });
}

async function sendNativeMessageWithPairing(message) {
  const pairingSecret = await readPairingSecret();
  const enriched = attachPairingField(message, pairingSecret);
  const response = await sendNativeMessage(enriched);
  await clearStaleSecretOnPairingRequired(response, pairingSecret);
  await persistPairingResponse(response);
  return response;
}

async function sendPairingCompletion(message) {
  const response = await sendNativeMessage(message);
  await persistPairingResponse(response);
  return response;
}

// hostnameMatches lives in shared/url-match.js, the same function content.js
// uses before it writes into the page. background-loader.js importScripts that
// file before this one, so in the service worker the function is already a
// global. Node tests require this file directly and take the require branch.
// The result stays on `urlMatch`: a top-level binding named hostnameMatches
// here would collide with the function importScripts already declared.
const urlMatch = typeof require === 'function'
  ? require('./shared/url-match.js')
  : globalThis;

// password-generator.js is importScripts'd before this file. The binding stays
// on this object: a top-level name such as generateRandomPassword here would
// collide with the function that script already declared.
const passwordGenerator = typeof require === 'function'
  ? require('./shared/password-generator.js')
  : globalThis;

// security-watch.js is importScripts'd before this file. The bag name stays
// unqualified: a second top-level const of a function from that file would
// collide with the var the classic script already declared.
const securityWatch = typeof require === 'function'
  ? require('./shared/security-watch.js')
  : mypassSecurityWatch;

// notification-settings.js is importScripts'd before this file. The bag name
// stays unqualified so it does not collide with the var that script declared.
const notificationSettings = typeof require === 'function'
  ? require('./shared/notification-settings.js')
  : mypassNotificationSettings;

// Pure decision function so the branch selection is unit-testable without a chrome.tabs
// mock. `manifest.json` grants only `activeTab` (no `host_permissions`), and Chrome only
// grants activeTab after a gesture on the extension itself (toolbar icon, context menu,
// command) — a click on the inline in-page icon does NOT count. That left the old
// chrome.tabs.query({active:true}) path reading an empty activeTab.url on a fresh page,
// so hostnameMatches always failed and nothing filled, until some other gesture (e.g.
// opening the popup) granted activeTab for that tab.
//
// `sender.tab` and `sender.url` on a chrome.runtime.onMessage sender are populated by
// Chrome for any message from a content script's own execution context, with NO
// permission grant required — that's independent of activeTab entirely. So when the
// request came from a content script we already know, with certainty, which tab and
// which origin asked, and chrome.tabs.query/tab.url are not needed at all.
//
// Returns:
//   null                     — no sender.tab (e.g. the popup): caller must fall back to
//                               the chrome.tabs.query({active:true}) path, which works
//                               there because opening the popup granted activeTab.
//   { tabId, ok: true }      — content-script sender, origin verified, safe to target.
//   { tabId, ok: false }     — content-script sender, but requestUrl's host does not
//                               match sender.url's host (or sender.url is empty/absent) —
//                               reject outright, do NOT fall back to the active tab.
function resolveSenderFillTarget(sender, requestUrl) {
  if (!sender || !sender.tab || sender.tab.id === undefined) return null;
  return { tabId: sender.tab.id, ok: urlMatch.hostnameMatches(requestUrl, sender.url) };
}

function buildApplyFillMessage(credentialResponse, requestUrl) {
  const message = {
    type: "applyFill",
    username: credentialResponse.username,
    password: credentialResponse.password,
    totp: credentialResponse.totp || null,
    url: requestUrl
  };
  // A generated password must land in the page's NEW-password field, never wherever
  // content.js's fallback happens to look first. Without this flag a popup-originated
  // fill has no pending click target, so applyFill resolved its destination with
  // findLoginForm() — the first visible password input in document order — and wrote the
  // new secret over the CURRENT-password box on a change-password form. The popup
  // correctly detected the new-password field in order to offer the button at all, then
  // discarded that knowledge before the fill. The flag rides on the message rather than
  // being threaded through relayFillToActiveTab/sendApplyFill/sendApplyFillToSender as a
  // fourth argument, because it is a property of WHAT is being filled, not of how it is
  // being delivered — and the response type already says which.
  if (credentialResponse.type === "generatedPassword") {
    message.fillTarget = "newPassword";
  }
  return message;
}

// The popup branch. The popup has no sender.frameId/documentId of its own, but it is
// always acting on the top-level document of the active tab — that is the only page it
// can show entries for — so delivery is scoped to frameId 0.
//
// This is NOT cosmetic. Before content_scripts gained `all_frames: true`, only the top
// frame ran content.js, so only the top frame had an applyFill listener and the 3-arg
// (unscoped) call was a broadcast with exactly one possible recipient. With all_frames
// EVERY frame has that listener: a tab-wide broadcast hands the decrypted password to
// every subframe at once. A subframe sharing the top page's hostname passes content.js's
// hostnameMatches check (which compares hostname only — not scheme, not port), has no
// pending fill target, and falls through to findLoginForm()/findOtpField(), writing the
// password into a field the user never chose. frameId: 0 keeps the credential in the one
// document the popup was actually acting on.
function sendApplyFill(tabId, credentialResponse, requestUrl) {
  chrome.tabs.sendMessage(
    tabId,
    buildApplyFillMessage(credentialResponse, requestUrl),
    { frameId: 0 },
    () => {
      if (chrome.runtime.lastError) {
        console.warn("MyPass: applyFill delivery failed — " + chrome.runtime.lastError.message);
      }
    }
  );
}

// Scopes delivery to the exact frame/document that sent the fillCredential request,
// rather than the tab as a whole. This closes a TOCTOU window: sender.tab.id/sender.url
// are captured when the request arrives, but delivery happens after an async
// native-messaging round-trip, during which the tab can navigate to a different
// (possibly attacker) origin. Without frameId/documentId, chrome.tabs.sendMessage would
// broadcast tab-wide and land in whatever document now occupies that tab. documentId is
// what actually closes the hole: a navigated document gets a fresh documentId, so a
// stale delivery targets a document that no longer exists and simply fails — the
// resulting chrome.runtime.lastError is the SUCCESS case for this guard, not a delivery
// bug. frameId additionally stops the tab-wide broadcast to other frames in the same
// tab. Both options require Chrome 106+; manifest.json pins minimum_chrome_version 127,
// so no version guard is needed. Only used on the sender (content-script) branch — the
// popup branch has no sender.frameId/documentId and scopes to frameId 0 instead, see
// sendApplyFill above.
function sendApplyFillToSender(tabId, sender, credentialResponse, requestUrl) {
  chrome.tabs.sendMessage(
    tabId,
    buildApplyFillMessage(credentialResponse, requestUrl),
    { frameId: sender.frameId, documentId: sender.documentId },
    () => {
      if (chrome.runtime.lastError) {
        // Expected whenever the tab navigated away between request and delivery: the
        // targeted document no longer exists, so Chrome correctly drops the message
        // instead of letting it land in whatever document replaced it.
        console.warn(
          "MyPass: applyFill delivery to sender document skipped (tab likely navigated away) — " +
          chrome.runtime.lastError.message
        );
      }
    }
  );
}

function readGeneratorSettings() {
  return new Promise((resolve) => {
    const fallback = passwordGenerator.defaultGeneratorSettings();
    if (!chrome.storage || !chrome.storage.local) {
      resolve(fallback);
      return;
    }
    chrome.storage.local.get([passwordGenerator.GENERATOR_SETTINGS_KEY], (stored) => {
      resolve(passwordGenerator.normalizeGeneratorSettings(stored && stored[passwordGenerator.GENERATOR_SETTINGS_KEY]));
    });
  });
}

function readSecuritySettings() {
  return new Promise((resolve) => {
    const fallback = securityWatch.defaultSecuritySettings();
    if (!chrome.storage || !chrome.storage.local) {
      resolve(fallback);
      return;
    }
    chrome.storage.local.get([securityWatch.SECURITY_SETTINGS_KEY], (stored) => {
      resolve(securityWatch.normalizeSecuritySettings(stored && stored[securityWatch.SECURITY_SETTINGS_KEY]));
    });
  });
}

function readNotificationSettings() {
  return new Promise((resolve) => {
    const fallback = notificationSettings.defaultNotificationSettings();
    if (!chrome.storage || !chrome.storage.local) {
      resolve(fallback);
      return;
    }
    chrome.storage.local.get([notificationSettings.NOTIFICATION_SETTINGS_KEY], (stored) => {
      resolve(notificationSettings.normalizeNotificationSettings(
        stored && stored[notificationSettings.NOTIFICATION_SETTINGS_KEY]
      ));
    });
  });
}

function readSecurityWatches() {
  return new Promise((resolve) => {
    if (!chrome.storage || !chrome.storage.session) {
      resolve([]);
      return;
    }
    chrome.storage.session.get([securityWatch.SECURITY_WATCH_KEY], (stored) => {
      const watches = stored && stored[securityWatch.SECURITY_WATCH_KEY];
      resolve(Array.isArray(watches) ? watches : []);
    });
  });
}

function writeSecurityWatches(watches) {
  return new Promise((resolve) => {
    if (!chrome.storage || !chrome.storage.session) {
      resolve();
      return;
    }
    const area = chrome.storage.session;
    const done = () => resolve();
    if (!watches || !watches.length) {
      area.remove([securityWatch.SECURITY_WATCH_KEY], done);
      return;
    }
    area.set({ [securityWatch.SECURITY_WATCH_KEY]: watches }, done);
  });
}

function noteFilledCredential(response, requestUrl) {
  return readSecurityWatches().then((watches) => {
    return writeSecurityWatches(securityWatch.rememberFilledCredential(watches, response, requestUrl, Date.now()));
  });
}

function deliverGeneratedOrFilled(message, sender, sendResponse, response, preview) {
  const recorded = response && response.type === "generatedPassword"
    ? rememberGeneratedPassword(response.password, (message && message.url) || "")
    : message && message.type === "fillCredential" && response && response.type === "credential"
      ? noteFilledCredential(response, message.url)
      : Promise.resolve();
  recorded.then(() => {
    if (message.type === "fillCredential" && response && response.type === "credential") {
      relayFillToActiveTab(response, message.url, sender);
      sendResponse(stripCredentialSecrets(response));
      return;
    }
    // A generator window is an extension page: no sender.tab, same as the popup.
    // preview returns the password and does not type it into the page. A content
    // script always has sender.tab, so this branch never runs for it and preview
    // cannot turn a page request into a copy of the secret beyond the fill that
    // script already performs itself.
    if (message.type === "generatePassword" && response && response.type === "generatedPassword" && !(sender && sender.tab)) {
      if (preview) {
        sendResponse(response);
        return;
      }
      relayFillToActiveTab(response, message.url, sender);
      sendResponse(stripCredentialSecrets(response));
      return;
    }
    sendResponse(response);
  });
}

function rememberGeneratedPassword(password, pageUrl) {
  return migrateLocalPasswordHistory().then(() =>
    recordVaultPasswordHistory(password, pageUrl, Date.now())
  );
}

function recordVaultPasswordHistory(password, pageUrl, createdAt) {
  if (!password) return Promise.resolve({ type: "error" });
  return sendNativeMessageWithPairing({
    type: "recordGeneratedPassword",
    password: password,
    url: pageUrl || "",
    createdAt: createdAt
  }).catch(() => ({ type: "error" }));
}

function readLocalPasswordHistory() {
  return new Promise((resolve) => {
    if (!chrome.storage || !chrome.storage.local) {
      resolve([]);
      return;
    }
    chrome.storage.local.get([GENERATED_HISTORY_KEY], (stored) => {
      const history = stored && stored[GENERATED_HISTORY_KEY];
      resolve(Array.isArray(history) ? history : []);
    });
  });
}

function clearLocalPasswordHistory() {
  return new Promise((resolve) => {
    if (!chrome.storage || !chrome.storage.local) {
      resolve();
      return;
    }
    chrome.storage.local.remove([GENERATED_HISTORY_KEY], () => resolve());
  });
}

// Older builds kept generator history in the browser profile. Move that list into
// the vault once, oldest first, and leave it in place if the vault cannot take it yet.
function migrateLocalPasswordHistory() {
  if (!localHistoryMigration) {
    localHistoryMigration = migrateLocalPasswordHistoryOnce().finally(() => {
      localHistoryMigration = null;
    });
  }
  return localHistoryMigration;
}

async function migrateLocalPasswordHistoryOnce() {
  const local = await readLocalPasswordHistory();
  if (!local.length) return;
  const oldestFirst = local.slice().reverse();
  for (const entry of oldestFirst) {
    if (!entry || !entry.password) continue;
    const response = await recordVaultPasswordHistory(entry.password, entry.url || "", entry.createdAt || Date.now());
    if (!response || response.type !== "ok") return;
  }
  await clearLocalPasswordHistory();
}

function relayFillToActiveTab(credentialResponse, requestUrl, sender) {
  const senderTarget = resolveSenderFillTarget(sender, requestUrl);

  if (senderTarget) {
    // The request came from a content script — target it directly, no chrome.tabs.query
    // and no reliance on "the active tab is the tab that asked" (it might not be).
    if (!senderTarget.ok) {
      console.warn("MyPass: relayFillToActiveTab aborted — sender origin does not match request origin");
      return;
    }
    // Chrome treats an undefined optional property as absent, so
    // {frameId: undefined, documentId: undefined} would silently degrade
    // chrome.tabs.sendMessage back into the unscoped, tab-wide broadcast this scoping
    // exists to prevent — reaching the exact TOCTOU hole by omission rather than by
    // attack. A security guard must refuse rather than downgrade, so bail here rather
    // than let sendApplyFillToSender fall back to an unscoped send.
    if (!sender.documentId) {
      console.warn("MyPass: applyFill aborted — no documentId on the sender; refusing an unscoped tab-wide delivery");
      return;
    }
    sendApplyFillToSender(senderTarget.tabId, sender, credentialResponse, requestUrl);
    return;
  }

  // No sender.tab — the request came from the popup, which has no content-script
  // sender info at all. Fall back to the original active-tab lookup; this only works
  // because opening the popup is itself the user gesture that granted activeTab.
  chrome.tabs.query({ active: true, currentWindow: true }, (tabs) => {
    const activeTab = tabs[0];
    if (!activeTab || activeTab.id === undefined) return;

    // First line of defense: verify the active tab's origin matches the
    // request's origin BEFORE the secret-bearing message is ever sent to
    // that tab's content-script runtime. content.js's own hostnameMatches
    // check stays in place too, as defense-in-depth — this only stops the
    // secret from being *delivered* to a mismatched tab in the first place.
    if (!urlMatch.hostnameMatches(requestUrl, activeTab.url)) {
      console.warn("MyPass: relayFillToActiveTab aborted — active tab origin does not match request origin");
      return;
    }

    sendApplyFill(activeTab.id, credentialResponse, requestUrl);
  });
}

// Strips secret fields (username/password/totp) from a native-messaging
// response before it's handed back to whichever UI surface sent the
// fillCredential request (the popup). The popup only needs to know
// success/failure — the actual fill happens via relayFillToActiveTab's
// direct message to content.js, so the popup's JS runtime never needs to
// see the plaintext credential.
//
// The generatedPassword branch is the same rule applied to the same situation: once a
// popup-originated generate is relayed to the tab, the popup has no remaining use for
// the plaintext — it only closes itself — so it must not receive it either. It shipped
// once without this, with a test pinning the unstripped shape, because
// "relayFillToActiveTab is used here too" was read as parity with the fillCredential
// path when only half of that path was actually reused. A content-script-originated
// generatePassword is NOT stripped and must not be: nothing relays for it, the content
// script does the fill itself, and the caller in that case is the page-adjacent script
// that is about to type the secret into the field anyway.
function stripCredentialSecrets(response) {
  if (!response) return response;
  if (response.type === "credential") {
    return { type: "ok", message: response.message };
  }
  if (response.type === "generatedPassword") {
    return { type: "generatedPasswordFilled" };
  }
  return response;
}

// MV3 terminates the service worker after ~30 s idle, while the user has up to 120 s to
// confirm. Nothing about a pending ceremony may therefore live only in a module-scope
// Map or a setTimeout — both evaporate on termination, taking the "one ceremony at a
// time" guard and the watchdog with them. chrome.storage.session is the source of truth
// and chrome.alarms is the timer, because both survive a service-worker restart.
// Completion itself is safe either way: the proxy API is keyed on requestId, not on a
// callback we hold.
//
// Note: Chrome rewrites the page's requested timeout to 180 s, so this 120 s watchdog
// deliberately fires first and we control the failure mode.
function readPending() {
  return new Promise((resolve) => {
    chrome.storage.session.get([PENDING_KEY], (stored) => resolve((stored && stored[PENDING_KEY]) || null));
  });
}

function writePending(record) {
  return new Promise((resolve) => chrome.storage.session.set({ [PENDING_KEY]: record }, () => resolve()));
}

function clearPending() {
  return new Promise((resolve) => chrome.storage.session.remove([PENDING_KEY], () => resolve()));
}

function readPasskeyProxyEnabled() {
  return new Promise((resolve) => {
    chrome.storage.local.get([PASSKEY_ENABLED_KEY], (stored) => resolve(!!(stored && stored[PASSKEY_ENABLED_KEY])));
  });
}

function passkeyNotAllowedError(message) {
  return { name: "NotAllowedError", message };
}

// The proxy event carries only { requestId, requestDetailsJson } — no tab, no origin.
// Chrome puts the true origin inside the payload as a WebAuthn extension. Read it from
// there rather than guessing the initiating tab with chrome.tabs.query: a ceremony can
// start in a background tab, and originUrl feeds the app's domain-match gate.
function originFromRequestDetails(requestDetailsJson) {
  try {
    const details = JSON.parse(requestDetailsJson);
    const override = details && details.extensions && details.extensions.remoteDesktopClientOverride;
    return (override && override.origin) || null;
  } catch (error) {
    return null;
  }
}

async function fetchPasskeyProxyStatus() {
  const status = await sendNativeMessageWithPairing({ type: "getPasskeyProxyStatus" });
  // sendNativeMessage resolves an {type:"error"} envelope rather than rejecting when the
  // host is unreachable, so testing the envelope is the real guard here.
  return status && status.type === "passkeyProxyStatus" ? status : null;
}

function writePasskeyProxyEnabledCache(enabled) {
  return new Promise((resolve) => {
    chrome.storage.local.set({ [PASSKEY_ENABLED_KEY]: !!enabled }, () => resolve());
  });
}

// The app is authoritative; the extension's local cache is only a mirror of the last
// known status. Every status fetch — not just the popup toggle — must resync both the
// cache and the actual attach/detach state, or the app's Settings toggle only takes
// effect after the next service-worker restart (the bug this closes).
async function observeVaultUnlock(status) {
  const decision = notificationSettings.noteVaultUnlock(vaultWasUnlocked, status && status.unlocked);
  vaultWasUnlocked = decision.previous;
  if (!decision.notify) return;
  try {
    const settings = await readNotificationSettings();
    if (!settings.vaultUnlocked) return;
    showBasicNotification("mypass-unlocked", "MyPass is unlocked.");
  } catch (_) {}
}

async function syncPasskeyProxyFromStatus(status) {
  await observeVaultUnlock(status);
  const result = { ...status, proxyState: "unavailable" };
  if (!chrome.webAuthenticationProxy || status.enabled === undefined) return result;
  await writePasskeyProxyEnabledCache(status.enabled);
  if (!status.enabled) {
    try {
      await chrome.webAuthenticationProxy.detach();
      result.proxyState = "disabled";
    } catch (_) { result.proxyState = "attachment-error"; }
  } else if (!status.paired) {
    result.proxyState = "unpaired";
  } else if (!status.unlocked || !status.attachAllowed) {
    result.proxyState = "locked";
  } else {
    try {
      await chrome.webAuthenticationProxy.attach();
      result.proxyState = "active";
    } catch (_) {
      // A checked preference is not proof of interception. Another extension can own
      // the proxy, and Chrome refuses attach() in that case. Expose that failure.
      result.proxyState = "attachment-error";
    }
  }
  return result;
}

async function attachPasskeyProxyIfEligible() {
  if (proxyRefresh) return proxyRefresh;
  proxyRefresh = withProxyOperation(async () => {
    const status = await sendNativeMessageWithPairing({ type: "getPasskeyProxyStatus" });
    const result = status && status.type === "passkeyProxyStatus"
      ? await syncPasskeyProxyFromStatus(status)
      : {
        type: "passkeyProxyStatus", unlocked: false, paired: false,
        proxyState: status && status.type === "pairingRequired" ? "unpaired" : "unavailable"
      };
    await reportBrowserDiagnostics(result);
    return result;
  });
  try { return await proxyRefresh; } finally { proxyRefresh = null; }
}

// Optional diagnostics deliberately stay read-only. Chrome's password-saving setting
// says nothing about OS passkey providers or password autofill, and getAll() cannot
// reliably identify every manager. Never turn these observations into "exclusive".
const KNOWN_PASSWORD_MANAGERS = new Set([
  "nngceckbapebfimnlniiiahkandclblb", // Bitwarden
  "aeblfdkhhhdcdjpifhhbdiojplfjncoa", // 1Password
  "hdokiejnpimakedhajhdlcegeplioahd", // LastPass
  "fdjamakpfbbddfjaooikfcpapjohcfmg", // Dashlane
  "oboonakemofpalcgghocfoadofidjkkk", // KeePassXC
  "pejdijmoenmkgeppbflobdenhhabjlaj" // iCloud Passwords (Apple Chrome Web Store listing)
]);

async function getBrowserManagerDiagnostics() {
  const result = {
    checked: false, permissionState: "unavailable", passwordSavingEnabled: null,
    extensionScanState: "not-checked", extensions: []
  };
  try {
    if (!chrome.permissions) return result;
    const granted = await chrome.permissions.contains({ permissions: ["privacy", "management"] });
    result.permissionState = granted ? "granted" : "not-granted";
    if (!granted) return result;
  } catch (_) { return result; }
  result.checked = true;
  try {
    const setting = await chrome.privacy.services.passwordSavingEnabled.get({});
    if (typeof setting.value === "boolean") result.passwordSavingEnabled = setting.value;
  } catch (_) { /* unavailable settings stay unknown */ }
  try {
    const extensions = await chrome.management.getAll();
    result.extensions = extensions.filter((extension) => extension.enabled && extension.id !== chrome.runtime.id
      && (KNOWN_PASSWORD_MANAGERS.has(extension.id) || (extension.permissions || []).includes("webAuthenticationProxy")))
      .map(({ name }) => ({ name }));
    result.extensionScanState = "complete";
  } catch (_) {
    result.checked = false;
    result.extensionScanState = "unavailable";
  }
  return result;
}

// Only observations leave the browser. A report cannot grant permission, change a
// preference, unlock the vault or claim that every system provider was inspected.
async function reportBrowserDiagnostics(status, diagnostics) {
  const result = diagnostics || await getBrowserManagerDiagnostics();
  const report = {
    proxyState: status && status.proxyState || "unavailable",
    permissionState: result.permissionState,
    passwordSavingEnabled: result.passwordSavingEnabled,
    extensionScanState: result.extensionScanState,
    enabledManagers: result.extensions.slice(0, 20).map(({ name }) =>
      Array.from(String(name).replace(/[\u0000-\u001f\u007f-\u009f]/g, "")).slice(0, 120).join("")
    ).filter(Boolean)
  };
  try {
    const response = await sendNativeMessageWithPairing({ type: "reportBrowserDiagnostics", report });
    // The app encodes ExtensionBridgeResponse.acknowledged as {"type":"ok"}.
    return !!(response && response.type === "ok");
  } catch (_) { return false; }
}

// tabs.create extension pages have sender.tab too. Permit only our own page origin;
// a content script retains the website's sender.url and cannot open native settings.
function isMyPassPage(sender) {
  return !!(sender && sender.id === chrome.runtime.id && typeof sender.url === "string"
    && sender.url.startsWith(chrome.runtime.getURL("")));
}

function showPasskeyBadge(text) {
  if (chrome.action && chrome.action.setBadgeText) chrome.action.setBadgeText({ text }).catch(() => {});
}

function showBasicNotification(id, message) {
  if (!chrome.notifications || typeof chrome.notifications.create !== "function") return;
  try {
    Promise.resolve(chrome.notifications.create(id, {
      type: "basic",
      iconUrl: "icons/icon48.png",
      title: "MyPass",
      message
    })).catch(() => {});
  } catch (_) {}
}

function openPasskeyPopup() {
  showPasskeyBadge("KEY");
  const notify = () => {
    readNotificationSettings().then((settings) => {
      if (!settings.passkeyConfirmation) return;
      showBasicNotification(
        "mypass-passkey",
        "Passkey confirmation needed. Open the MyPass extension to continue."
      );
    }).catch(() => {});
  };
  if (chrome.action && typeof chrome.action.openPopup === "function") {
    chrome.action.openPopup().catch(notify);
  } else notify();
}

// Chrome rejects malformed responseJson without settling the website's request.
// Keep the watchdog and UI reservation until Chrome acknowledges completion; a
// native save alone does not mean the browser accepted the credential. Never log
// responseJson or raw API errors here: they can contain credential material.
async function completePasskeyRequest(kind, details) {
  const complete = kind === "create"
    ? (value) => chrome.webAuthenticationProxy.completeCreateRequest(value)
    : (value) => chrome.webAuthenticationProxy.completeGetRequest(value);
  let completionError = null;
  let acknowledged = false;
  // Diagnostic only: sites such as Google hide the real reason behind a generic
  // "no passkey" screen, so record which ceremony failed and why. Deliberately
  // limited to kind, error name and message — never the challenge, user handle,
  // credential material or requestDetailsJson.
  if (details.error) {
    console.warn(`MyPass: passkey ${kind} completed with error — ${details.error.name}: ${details.error.message}`);
  }
  try {
    await complete(details);
    acknowledged = true;
  } catch (_) {
    completionError = {
      name: "OperationError",
      message: kind === "create"
        ? "The browser could not finish passkey registration. A passkey may already be saved in MyPass. Cancel the website request and retry; check the website before replacing the local key."
        : "The browser could not finish passkey sign-in. Cancel the website request and try again."
    };
    await withPasskeyState(async () => {
      const pending = await readPending();
      // Chrome can reject an old completion after canceling its request and
      // delivering the next ceremony. A stale failure must not cover that UI or
      // reappear after a cancellation; publish only while we still own the slot.
      if (!pending || pending.requestId !== details.requestId || pending.kind !== kind) return;
      await new Promise((resolve) => chrome.storage.session.set({
        [PASSKEY_FAILURE_KEY]: { requestId: details.requestId, kind, error: completionError }
      }, resolve));
    });
    try {
      // A DOMException completion needs no credential JSON parsing and explicitly
      // rejects navigator.credentials.create/get instead of leaving it spinning.
      await complete({ requestId: details.requestId, error: completionError });
      acknowledged = true;
    } catch (_) {
      // Chrome may have canceled the request, or the proxy may be unavailable.
      // Keep our watchdog if it is still pending; never claim browser success.
    }
  }
  await withPasskeyState(async () => {
    const pending = await readPending();
    if (acknowledged && pending && pending.requestId === details.requestId) {
      await clearPending();
      chrome.alarms.clear(PASSKEY_WATCHDOG_ALARM);
      showPasskeyBadge("");
    }
  });
  return completionError ? { error: completionError } : {};
}

async function handlePasskeyRequest(kind, requestId, requestDetailsJson) {
  const originUrl = originFromRequestDetails(requestDetailsJson);
  if (!originUrl) {
    await completePasskeyRequest(kind, {
      requestId, error: passkeyNotAllowedError("Could not determine the ceremony origin")
    });
    return;
  }
  dispatchingPasskeys.add(requestId);
  try {
    // Reserve before the native round trip. All state transitions share a queue with
    // cancellation/completion so simultaneous sites cannot overwrite each other, and
    // a late native reply cannot resurrect a ceremony Chrome already canceled.
    const reserved = await withPasskeyState(async () => {
      if (await readPending() || cancelledPasskeys.has(requestId)) return false;
      await new Promise((resolve) => chrome.storage.session.remove([PASSKEY_FAILURE_KEY], resolve));
      await writePending({ kind, requestId, originUrl, phase: "checking" });
      chrome.alarms.create(PASSKEY_WATCHDOG_ALARM, { delayInMinutes: PASSKEY_WATCHDOG_MS / 60000 });
      return true;
    });
    if (!reserved) {
      if (!cancelledPasskeys.has(requestId)) await completePasskeyRequest(kind, {
        requestId, error: { name: "AbortError", message: "Another passkey ceremony is already pending" }
      });
      return;
    }
    const messageType = kind === "create" ? "passkeyCreate" : "passkeyGet";
    const response = await sendNativeMessageWithPairing({ type: messageType, requestId, requestDetailsJson, originUrl });
    const stillPending = await withPasskeyState(async () => {
      const current = await readPending();
      return !cancelledPasskeys.has(requestId) && current && current.requestId === requestId;
    });
    if (!stillPending) {
      await sendNativeMessageWithPairing({ type: "passkeyCancel", requestId });
      return;
    }
    if (response && response.error) {
      await completePasskeyRequest(kind, { requestId, error: response.error });
      return;
    }
    if (response && response.type === (kind === "create" ? "passkeyCreatePending" : "passkeyGetPending")) {
      await withPasskeyState(async () => {
        const current = await readPending();
        if (cancelledPasskeys.has(requestId) || !current || current.requestId !== requestId) return;
        await writePending({ kind, requestId, originUrl, rpId: response.rpId, rpName: response.rpName, matches: response.matches || [] });
        if (!cancelledPasskeys.has(requestId)) openPasskeyPopup();
      });
      return;
    }
    const reason = !response ? "MyPass did not respond"
      : response.type === "locked" ? "MyPass is locked"
      : response.type === "pairingRequired" ? "MyPass is not paired with this browser"
      : response.type === "error" ? "MyPass is unavailable"
      : `Unexpected MyPass response: ${response.type}`;
    await completePasskeyRequest(kind, { requestId, error: passkeyNotAllowedError(reason) });
  } finally {
    dispatchingPasskeys.delete(requestId);
    cancelledPasskeys.delete(requestId);
  }
}

// Answers `true` only while enabled AND unlocked; attached-but-locked answers `false`
// rather than claiming to be a usable authenticator. Every request must be answered —
// an early return leaves Chrome waiting forever.
async function answerIsUvpaa(requestId) {
  const answer = (isUvpaa) => chrome.webAuthenticationProxy.completeIsUvpaaRequest({ requestId, isUvpaa });
  if (!(await readPasskeyProxyEnabled())) {
    answer(false);
    return;
  }
  // attachAllowed, not unlocked: it also folds in the app-side opt-in, so a vault that
  // is unlocked with the feature turned off still answers false.
  const status = await fetchPasskeyProxyStatus();
  answer(!!(status && status.attachAllowed));
}

async function setPasskeyProxyEnabled(message) {
  return withProxyOperation(async () => {
    const response = await sendNativeMessageWithPairing(message);
    // A failed or refused setting change must not change interception or its cache.
    if (response && response.type === "passkeyProxyEnabled") {
      await writePasskeyProxyEnabledCache(response.enabled);
      if (!response.enabled && chrome.webAuthenticationProxy) {
        await chrome.webAuthenticationProxy.detach().catch(() => {});
      } else {
        const status = await fetchPasskeyProxyStatus();
        if (status) await syncPasskeyProxyFromStatus(status);
      }
    }
    return response;
  });
}

// Address data is domain-independent, so content scripts must never request it.
// Only our popup can start this two-step flow. A challenged content-script report
// supplies Chrome's authenticated documentId before any native address is read.
const addressScans = new Map();
const addressTargets = new Map();
const ADDRESS_TARGET_TTL_MS = 120000;

function addressError(code) { return { type: 'error', code }; }
function isAddressPopup(sender) {
  return !!(sender && sender.id === chrome.runtime.id
    && sender.url === chrome.runtime.getURL('popup.html'));
}
function activeAddressTab() {
  return new Promise((resolve) => chrome.tabs.query({ active: true, currentWindow: true }, (tabs) => {
    if (chrome.runtime.lastError) { resolve(null); return; }
    const tab = tabs && tabs[0];
    resolve(tab && typeof tab.id === 'number' && /^https?:\/\//.test(tab.url || '') ? tab : null);
  }));
}
function sendAddressToDocument(target, message) {
  return new Promise((resolve) => chrome.tabs.sendMessage(target.tabId, message,
    { frameId: 0, documentId: target.documentId }, (response) => {
      resolve(chrome.runtime.lastError ? addressError('address_page_changed') : response);
    }));
}
async function prepareAddressFill() {
  const tab = await activeAddressTab();
  if (!tab) return addressError('address_no_form');
  for (const [key, target] of addressTargets) {
    if (Date.now() - target.at > ADDRESS_TARGET_TTL_MS) addressTargets.delete(key);
  }
  if (addressTargets.size > 50 || addressScans.size > 10) return addressError('address_retry');
  const challenge = crypto.randomUUID();
  return new Promise((resolve) => {
    const finish = (result) => {
      clearTimeout(timer);
      addressScans.delete(challenge);
      resolve(result);
    };
    const timer = setTimeout(() => finish(addressError('address_no_form')), 5000);
    addressScans.set(challenge, { tabId: tab.id, url: tab.url, finish });
    chrome.tabs.sendMessage(tab.id, { type: 'queryAddressForm', url: tab.url, challenge },
      { frameId: 0 }, () => {
        if (chrome.runtime.lastError) finish(addressError('address_no_form'));
      });
  });
}
function acceptAddressReport(message, sender) {
  const scan = addressScans.get(message.challenge);
  if (!scan || !sender || sender.id !== chrome.runtime.id || !sender.tab
    || sender.tab.id !== scan.tabId || sender.frameId !== 0 || !sender.documentId
    || sender.url !== scan.url) return addressError('address_page_changed');
  const forms = Array.isArray(message.forms) ? message.forms.filter((form) => form
    && typeof form.id === 'string' && /^\d+$/.test(form.id)
    && typeof form.label === 'string' && form.label.length <= 80
    && Number.isInteger(form.fields) && form.fields > 0 && form.fields < 100
    && typeof form.focused === 'boolean').slice(0, 30) : [];
  if (!forms.length) {
    scan.finish(addressError('address_no_form'));
    return { type: 'ok' };
  }
  const target = { tabId: scan.tabId, url: scan.url, documentId: sender.documentId,
    forms, at: Date.now(), challenge: message.challenge };
  addressTargets.set(message.challenge, target);
  scan.finish({ type: 'addressForms', token: message.challenge, url: scan.url, forms });
  return { type: 'ok' };
}
async function fillSelectedAddress(message) {
  const target = addressTargets.get(message.token);
  addressTargets.delete(message.token); // never replay a user's confirmation
  if (!target || Date.now() - target.at > ADDRESS_TARGET_TTL_MS
    || typeof message.id !== 'string' || !target.forms.some((form) => form.id === message.groupId)) {
    return addressError('address_page_changed');
  }
  const sameTab = (tab) => tab && tab.id === target.tabId && tab.url === target.url;
  if (!sameTab(await activeAddressTab())) return addressError('address_page_changed');
  const response = await sendNativeMessageWithPairing({ type: 'fillAddress', id: message.id, url: target.url });
  if (!response || response.type !== 'address') {
    if (response && ['locked', 'pairingRequired'].includes(response.type)) return response;
    return addressError('address_unavailable');
  }
  if (!response.address || typeof response.address.id !== 'string'
    || response.address.id.toLowerCase() !== message.id.toLowerCase()) return addressError('address_unavailable');
  if (!sameTab(await activeAddressTab())) return addressError('address_page_changed');
  const result = await sendAddressToDocument(target, { type: 'applyAddress', url: target.url,
    challenge: target.challenge, groupId: message.groupId, address: response.address });
  // Never forward arbitrary content-script/native data back to the popup.
  return result && result.type === 'addressFilled' && Number.isInteger(result.filled) && result.filled > 0
    ? { type: 'addressFilled', filled: result.filled }
    : addressError(result && ['address_form_changed', 'address_no_values'].includes(result.code)
      ? result.code : 'address_page_changed');
}

function handleRuntimeMessage(message, sender, sendResponse) {
  if (message && message.type === 'addressFormReport') {
    sendResponse(acceptAddressReport(message, sender));
    return true;
  }
  if (message && ['prepareAddressFill', 'fillAddress'].includes(message.type)) {
    if (!isAddressPopup(sender)) {
      sendResponse(addressError('address_unauthorized'));
      return true;
    }
    const operation = message.type === 'prepareAddressFill' ? prepareAddressFill() : fillSelectedAddress(message);
    operation.then(sendResponse).catch(() => sendResponse(addressError('address_unavailable')));
    return true;
  }

  if (sender && sender.tab && message && ["setPasskeyProxyEnabled", "passkeyCreateConfirm", "passkeyGetApprove", "passkeyCancelUI"].includes(message.type)) return false;
  if (message && message.type === "openBrowserSettings") {
    if (!isMyPassPage(sender)) return false;
    sendNativeMessageWithPairing({ type: "openBrowserSettings" }).then(sendResponse);
    return true;
  }
  // Popup gesture only. A content script and the browser-check page cannot lock the vault.
  if (message && message.type === "lockVault") {
    if (!isAddressPopup(sender)) return false;
    sendNativeMessageWithPairing({ type: "lockVault" }).then((response) => {
      const cleared = response && (response.type === "ok" || response.type === "locked")
        ? writeSecurityWatches([])
        : Promise.resolve();
      cleared.then(() => sendResponse(response));
    });
    return true;
  }
  // Popup gesture only. A page must not be able to pull the vault window forward.
  if (message && message.type === "openApp") {
    if (!isAddressPopup(sender)) return false;
    sendNativeMessageWithPairing({ type: "openApp" }).then(sendResponse);
    return true;
  }
  // The pasted or copied text stays inside the extension. The reply is only
  // whether to warn. sender.url is the page, so the message cannot name a
  // different host. Not added to knownTypes: the native app must not receive it.
  if (message && message.type === "checkSecurityUse") {
    if (!sender || !sender.tab || !sender.url) return false;
    if (!urlMatch.hostnameMatches(message.url, sender.url)) {
      sendResponse({ warn: false });
      return true;
    }
    const action = message.action === "paste" || message.action === "copy" ? message.action : "";
    const text = typeof message.text === "string" ? message.text : "";
    Promise.all([readSecuritySettings(), readSecurityWatches()]).then(([settings, watches]) => {
      const result = securityWatch.evaluateSecurityUse(settings, watches, action, text, sender.url, Date.now());
      return writeSecurityWatches(result.watches).then(() => sendResponse({ warn: result.warn === true }));
    });
    return true;
  }
  if (message && message.type === "getBrowserManagerDiagnostics") {
    if (sender && sender.tab && !isMyPassPage(sender)) return false;
    getBrowserManagerDiagnostics().then(async (result) => {
      const status = await attachPasskeyProxyIfEligible();
      const reported = await reportBrowserDiagnostics(status, result);
      sendResponse({ ...result, reported });
    });
    return true;
  }
  if (message && message.type === "getPasskeyProxyStatus") {
    attachPasskeyProxyIfEligible().then(sendResponse);
    return true;
  }
  if (message && message.type === "openPopupForTotpPicker") {
    if (chrome.action && typeof chrome.action.openPopup === "function") {
      chrome.action.openPopup().catch(() => {});
    }
    return false;
  }

  // UI-only message — never forwarded to the app as-is, so it sits ahead of the
  // knownTypes gate alongside openPopupForTotpPicker.
  if (message && message.type === "passkeyCancelUI") {
    readPending().then((pending) => {
      const kind = pending && pending.requestId === message.requestId ? pending.kind : "create";
      return sendNativeMessageWithPairing({ type: "passkeyCancel", requestId: message.requestId })
        .catch(() => null)
        .then(() => completePasskeyRequest(kind, {
          requestId: message.requestId,
          error: passkeyNotAllowedError("User cancelled")
        }))
        .then(() => sendResponse({ type: "ok" }));
    });
    return true;
  }

  // Fire-and-forget internal message the popup sends on every open — not a native-message
  // type, so it sits ahead of the knownTypes gate alongside passkeyCancelUI. This is the
  // re-check trigger that closes the gap between the app-side toggle and a service-worker
  // restart: popup open is a much more frequent event than a restart.
  if (message && message.type === "refreshPasskeyProxy") {
    attachPasskeyProxyIfEligible();
    return false;
  }

  // Extension-page only. A content script must not be able to read generator history.
  // The list itself is in the vault.
  if (message && message.type === "getGeneratedPasswordHistory") {
    if (sender && sender.tab) {
      sendResponse({ type: "generatedPasswordHistory", entries: [] });
      return true;
    }
    migrateLocalPasswordHistory()
      .then(() => sendNativeMessageWithPairing({ type: "getGeneratedPasswordHistory" }))
      .then((response) => {
        sendResponse(response && response.type ? response : { type: "error", message: "MyPass is unavailable." });
      })
      .catch(() => sendResponse({ type: "error", message: "MyPass is unavailable." }));
    return true;
  }

  // Random, memorable, and PIN passwords are made in the extension page. Only
  // that page may write them into history. A content script already gets its
  // password from generatePassword, which records on its own.
  if (message && message.type === "recordGeneratedPassword") {
    if ((sender && sender.tab) || !message.password) {
      sendResponse({ type: "error" });
      return true;
    }
    migrateLocalPasswordHistory()
      .then(() => recordVaultPasswordHistory(message.password, message.url || "", message.createdAt || Date.now()))
      .then((response) => {
        sendResponse(response && response.type === "ok" ? { type: "ok" } : (response || { type: "error" }));
      });
    return true;
  }

  if (message && message.type === "deleteGeneratedPassword") {
    if ((sender && sender.tab) || !message.id) {
      sendResponse({ type: "error" });
      return true;
    }
    sendNativeMessageWithPairing({ type: "deleteGeneratedPassword", id: message.id })
      .then((response) => {
        sendResponse(response && response.type === "ok" ? { type: "ok" } : (response || { type: "error" }));
      })
      .catch(() => sendResponse({ type: "error" }));
    return true;
  }

  // The generator window already shows the password. Autofill types that same
  // value into the active site. It does not ask the app for a new one.
  if (message && message.type === "fillGeneratedPassword") {
    if ((sender && sender.tab) || !message.password) {
      sendResponse({ type: "error" });
      return true;
    }
    relayFillToActiveTab({ type: "generatedPassword", password: message.password }, message.url, sender);
    sendResponse({ type: "generatedPasswordFilled" });
    return true;
  }

  // The popup opened a tab for a vault row. The new tab's content script claims
  // this record once it loads, because activeTab does not cover a tab the popup
  // just created, so the popup cannot push the fill itself.
  if (message && message.type === "armOpenAndFill") {
    if (sender && sender.tab) {
      sendResponse({ type: "error" });
      return true;
    }
    if (typeof message.tabId !== "number" || !message.id || !message.url) {
      sendResponse({ type: "error" });
      return true;
    }
    chrome.storage.session.set({
      [PENDING_OPEN_FILL_KEY]: {
        tabId: message.tabId,
        id: message.id,
        url: message.url,
        at: Date.now()
      }
    }, () => sendResponse({ type: "ok" }));
    return true;
  }

  if (message && message.type === "claimPendingFill") {
    if (!sender || !sender.tab || sender.frameId !== 0) {
      sendResponse({ type: "none" });
      return true;
    }
    chrome.storage.session.get([PENDING_OPEN_FILL_KEY], (stored) => {
      const pending = stored && stored[PENDING_OPEN_FILL_KEY];
      if (!pending || pending.tabId !== sender.tab.id || Date.now() - pending.at > PENDING_OPEN_FILL_TTL_MS) {
        sendResponse({ type: "none" });
        return;
      }
      if (!urlMatch.hostnameMatches(pending.url, message.url)) {
        sendResponse({ type: "none" });
        return;
      }
      chrome.storage.session.remove([PENDING_OPEN_FILL_KEY], () => {
        sendNativeMessageWithPairing({ type: "fillCredential", id: pending.id, url: pending.url }).then((response) => {
          const noted = response && response.type === "credential"
            ? noteFilledCredential(response, pending.url)
            : Promise.resolve();
          noted.then(() => {
            if (response && response.type === "credential") {
              sendApplyFill(sender.tab.id, response, pending.url);
            }
            sendResponse({ type: "ok" });
          });
        });
      });
    });
    return true;
  }

  if (!message || !knownTypes.includes(message.type)) {
    return false;
  }

  if (message.type === "setPasskeyProxyEnabled") {
    setPasskeyProxyEnabled(message).then(sendResponse);
    return true;
  }

  if (message.type === "passkeyCreateConfirm" || message.type === "passkeyGetApprove") {
    const kind = message.type === "passkeyCreateConfirm" ? "create" : "get";
    const completeType = kind === "create" ? "passkeyCreateComplete" : "passkeyGetComplete";
    (async () => {
      const claimed = await withPasskeyState(async () => {
        const pending = await readPending();
        if (!pending || pending.requestId !== message.requestId || pending.kind !== kind
          || pending.phase === "checking" || pending.phase === "completing") return false;
        await writePending({ ...pending, phase: "completing" });
        return true;
      });
      if (!claimed) return { type: completeType, requestId: message.requestId,
        error: passkeyNotAllowedError("This passkey request is no longer awaiting confirmation") };
      const response = await sendNativeMessageWithPairing(message);
      const pending = await readPending();
      if (!pending || pending.requestId !== message.requestId || pending.kind !== kind) {
        return { type: completeType, requestId: message.requestId,
          error: passkeyNotAllowedError("The website canceled this passkey request. Try again on the website.") };
      }
      if (response && response.type === completeType && response.requestId === message.requestId) {
        const result = await completePasskeyRequest(kind, {
          requestId: message.requestId,
          responseJson: response.responseJson,
          error: response.error
        });
        return result.error ? { type: completeType, requestId: message.requestId, error: result.error } : response;
      }
      // The app refused (locked, pairing lost, no pending request). Complete the
      // ceremony anyway so the page is not left hanging on a popup that has closed.
      const error = passkeyNotAllowedError("MyPass could not complete the passkey request. Unlock MyPass and try again on the website.");
      const result = await completePasskeyRequest(kind, {
        requestId: message.requestId,
        error
      });
      return { type: completeType, requestId: message.requestId, error: result.error || error };
    })().catch(async () => {
      const error = passkeyNotAllowedError("MyPass could not complete the passkey request. Try again on the website.");
      const result = await completePasskeyRequest(kind, { requestId: message.requestId, error });
      return { type: completeType, requestId: message.requestId, error: result.error || error };
    }).then(sendResponse);
    return true;
  }

  if (message.type === "startPairing") {
    sendNativeMessage({ type: "startPairing", browser: detectBrowserName() }).then((response) => {
      sendResponse(response);
    });
    return true;
  }

  if (message.type === "completePairing") {
    sendPairingCompletion(message).then((response) => {
      attachPasskeyProxyIfEligible();
      sendResponse(response);
    });
    return true;
  }

  if (message.type === "generatePassword") {
    const preview = message.preview === true && !(sender && sender.tab);
    readGeneratorSettings().then((settings) => {
      // "Use by default for suggestions" replaces the app generator for the
      // in-page Generate button and the popup's one-click Generate. Smart, and
      // a generator window asking to preview a smart password, still go to the app.
      if (!preview && settings.useAsDefault && settings.type !== "smart") {
        const password = passwordGenerator.generateFromSettings(settings);
        deliverGeneratedOrFilled(
          message, sender, sendResponse, { type: "generatedPassword", password: password }, false
        );
        return;
      }
      sendNativeMessageWithPairing(message).then((response) => {
        deliverGeneratedOrFilled(message, sender, sendResponse, response, preview);
      });
    });
    return true;
  }

  sendNativeMessageWithPairing(message).then((response) => {
    deliverGeneratedOrFilled(message, sender, sendResponse, response, false);
  });

  return true; // keep the message channel open for the async sendNativeMessage response
}

chrome.runtime.onMessage.addListener(handleRuntimeMessage);

// MV3 requires proxy listeners to be registered synchronously in the first turn of the
// event loop — never inside a callback — or Chrome will not deliver events to a worker
// it had to wake up.
if (typeof chrome !== "undefined" && chrome.webAuthenticationProxy) {
  chrome.webAuthenticationProxy.onCreateRequest.addListener((requestInfo) => {
    handlePasskeyRequest("create", requestInfo.requestId, requestInfo.requestDetailsJson);
  });

  chrome.webAuthenticationProxy.onGetRequest.addListener((requestInfo) => {
    handlePasskeyRequest("get", requestInfo.requestId, requestInfo.requestDetailsJson);
  });

  chrome.webAuthenticationProxy.onIsUvpaaRequest.addListener((requestInfo) => {
    answerIsUvpaa(requestInfo.requestId);
  });

  chrome.webAuthenticationProxy.onRequestCanceled.addListener((requestId) => {
    if (dispatchingPasskeys.has(requestId)) cancelledPasskeys.add(requestId);
    withPasskeyState(async () => {
      const pending = await readPending();
      if (pending && pending.requestId === requestId) {
        await clearPending();
        chrome.alarms.clear(PASSKEY_WATCHDOG_ALARM);
        showPasskeyBadge("");
      }
    });
    sendNativeMessageWithPairing({ type: "passkeyCancel", requestId }).catch(() => {});
  });

  chrome.alarms.onAlarm.addListener((alarm) => {
    if (alarm.name === PASSKEY_REFRESH_ALARM) {
      attachPasskeyProxyIfEligible();
      return;
    }
    if (alarm.name !== PASSKEY_WATCHDOG_ALARM) return;
    readPending().then((pending) => {
      if (!pending) return;
      sendNativeMessageWithPairing({ type: "passkeyCancel", requestId: pending.requestId });
      completePasskeyRequest(pending.kind, {
        requestId: pending.requestId,
        error: passkeyNotAllowedError("Timed out waiting for confirmation")
      });
    });
  });

  // Alarms survive worker suspension but may be cleared by a browser restart.
  // Recreate only when absent so frequent worker starts do not postpone the retry.
  if (chrome.alarms.get) chrome.alarms.get(PASSKEY_REFRESH_ALARM).then((alarm) => {
    if (!alarm) chrome.alarms.create(PASSKEY_REFRESH_ALARM, { periodInMinutes: 0.5 });
  });
  if (chrome.runtime.onStartup) chrome.runtime.onStartup.addListener(attachPasskeyProxyIfEligible);
  if (chrome.notifications && chrome.notifications.onClicked) {
    chrome.notifications.onClicked.addListener((id) => {
      if (id === "mypass-passkey") openPasskeyPopup();
      // Opening the popup is enough. A failed open must not post the notification again,
      // and this click must not ask the app to come forward.
      else if (id === "mypass-unlocked" && chrome.action && typeof chrome.action.openPopup === "function") {
        chrome.action.openPopup().catch(() => {});
      }
    });
  }
  attachPasskeyProxyIfEligible();
}

if (typeof chrome !== "undefined" && chrome.runtime) {
  const diagnosticEvents = [];
  if (chrome.permissions) diagnosticEvents.push(chrome.permissions.onAdded, chrome.permissions.onRemoved);
  if (chrome.management) diagnosticEvents.push(chrome.management.onEnabled, chrome.management.onDisabled,
    chrome.management.onInstalled, chrome.management.onUninstalled);
  if (chrome.privacy && chrome.privacy.services && chrome.privacy.services.passwordSavingEnabled) {
    diagnosticEvents.push(chrome.privacy.services.passwordSavingEnabled.onChange);
  }
  diagnosticEvents.forEach((event) => {
    if (event) event.addListener(() => { attachPasskeyProxyIfEligible().catch(() => {}); });
  });
}

// A keyboard command is a user gesture in this extension, not a page message.
// The page-facing lockVault handler stays limited to popup.html.
function lockVaultFromCommand() {
  sendNativeMessageWithPairing({ type: "lockVault" }).then((response) => {
    if (!(response && (response.type === "ok" || response.type === "locked"))) return;
    writeSecurityWatches([]).then(() => {
      if (chrome.storage && chrome.storage.session) {
        chrome.storage.session.set({ vaultLockedNotice: Date.now() });
      }
    });
  }).catch(() => {});
}

if (typeof chrome !== "undefined" && chrome.commands && chrome.commands.onCommand) {
  chrome.commands.onCommand.addListener((command) => {
    if (command === "lock-vault") lockVaultFromCommand();
  });
}

if (typeof module !== "undefined") {
  module.exports = {
    PAIRING_STORAGE_KEY,
    PASSKEY_WATCHDOG_ALARM,
    PASSKEY_REFRESH_ALARM,
    getBrowserManagerDiagnostics,
    reportBrowserDiagnostics,
    PENDING_KEY,
    knownTypes,
    attachPasskeyProxyIfEligible,
    syncPasskeyProxyFromStatus,
    handlePasskeyRequest,
    completePasskeyRequest,
    passkeyNotAllowedError,
    originFromRequestDetails,
    answerIsUvpaa,
    readPending,
    writePending,
    clearPending,
    attachPairingField,
    persistPairingResponse,
    clearStaleSecretOnPairingRequired,
    detectBrowserName,
    sendPairingCompletion,
    handleRuntimeMessage,
    noteFilledCredential,
    hostnameMatches: urlMatch.hostnameMatches,
    resolveSenderFillTarget,
    relayFillToActiveTab
  };
}
