const NATIVE_HOST_NAME = "com.mypass.chromehost";
const PAIRING_STORAGE_KEY = "pairingSecret";
const knownTypes = [
  "getCredentials", "fillCredential", "getTotp", "proposeSaveLogin", "proposeSaveTotp",
  "startPairing", "completePairing", "requestUnlock",
  "getPasskeyProxyStatus", "setPasskeyProxyEnabled", "passkeyCreateConfirm", "passkeyGetApprove"
];

const PASSKEY_WATCHDOG_MS = 120000;
const PASSKEY_WATCHDOG_ALARM = "passkeyCeremonyWatchdog";
const PENDING_KEY = "pendingPasskeyCeremony";
const PASSKEY_ENABLED_KEY = "passkeyProxyEnabled";

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
      if (chrome.runtime.lastError || !response) {
        resolve({ type: "error", message: "app_not_running" });
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

// Mirrors content.js's `hostnameMatches` — duplicated rather than shared
// because a service worker and a content script don't share a module system
// in this MV3 extension without a build step.
function hostnameMatches(messageUrl, pageUrl) {
  if (!messageUrl || !pageUrl) return false;
  try {
    const messageHost = new URL(messageUrl).hostname.toLowerCase();
    const pageHost = new URL(pageUrl).hostname.toLowerCase();
    return messageHost === pageHost;
  } catch (e) {
    return false;
  }
}

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
  return { tabId: sender.tab.id, ok: hostnameMatches(requestUrl, sender.url) };
}

function sendApplyFill(tabId, credentialResponse, requestUrl) {
  chrome.tabs.sendMessage(
    tabId,
    {
      type: "applyFill",
      username: credentialResponse.username,
      password: credentialResponse.password,
      totp: credentialResponse.totp || null,
      url: requestUrl
    },
    () => {
      if (chrome.runtime.lastError) {
        console.warn("MyPass: applyFill delivery failed — " + chrome.runtime.lastError.message);
      }
    }
  );
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
    sendApplyFill(senderTarget.tabId, credentialResponse, requestUrl);
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
    if (!hostnameMatches(requestUrl, activeTab.url)) {
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
function stripCredentialSecrets(response) {
  if (!response) return response;
  if (response.type === "credential") {
    return { type: "ok", message: response.message };
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

async function attachPasskeyProxyIfEligible() {
  if (!(await readPasskeyProxyEnabled())) return;
  if (!chrome.webAuthenticationProxy) return;
  const status = await fetchPasskeyProxyStatus();
  if (!status || !status.attachAllowed) return;
  try {
    await chrome.webAuthenticationProxy.attach();
  } catch (error) {
    console.warn("MyPass: passkey proxy attach failed", error);
  }
}

function openPasskeyPopup() {
  // No user gesture is required, but chrome.action.openPopup() rejects unless a Chrome
  // window is OS-level focused. In the normal flow the user is on the page that started
  // the ceremony, so this succeeds; the notification is the backgrounded-Chrome fallback.
  if (chrome.action && typeof chrome.action.openPopup === "function") {
    chrome.action.openPopup().catch(() => {
      chrome.notifications.create({
        type: "basic",
        iconUrl: "icons/icon48.png",
        title: "MyPass",
        message: "MyPass passkey confirmation needed"
      });
    });
  }
}

// Clears the pending record only when it belongs to this requestId, so rejecting a
// second concurrent ceremony cannot cancel the first one's bookkeeping.
async function completePasskeyRequest(kind, details) {
  const pending = await readPending();
  if (pending && pending.requestId === details.requestId) {
    await clearPending();
    chrome.alarms.clear(PASSKEY_WATCHDOG_ALARM);
  }
  if (kind === "create") {
    chrome.webAuthenticationProxy.completeCreateRequest(details);
  } else {
    chrome.webAuthenticationProxy.completeGetRequest(details);
  }
}

async function handlePasskeyRequest(kind, requestId, requestDetailsJson) {
  if (await readPending()) {
    await completePasskeyRequest(kind, {
      requestId,
      error: { name: "AbortError", message: "Another passkey ceremony is already pending" }
    });
    return;
  }

  const originUrl = originFromRequestDetails(requestDetailsJson);
  if (!originUrl) {
    // Fail closed: without a trustworthy origin the app cannot run its domain check.
    await completePasskeyRequest(kind, {
      requestId,
      error: passkeyNotAllowedError("Could not determine the ceremony origin")
    });
    return;
  }

  const messageType = kind === "create" ? "passkeyCreate" : "passkeyGet";
  const response = await sendNativeMessageWithPairing({ type: messageType, requestId, requestDetailsJson, originUrl });

  if (response && response.error) {
    await completePasskeyRequest(kind, { requestId, error: response.error });
    return;
  }

  if (response && (response.type === "passkeyCreatePending" || response.type === "passkeyGetPending")) {
    await writePending({
      kind,
      requestId,
      originUrl,
      rpId: response.rpId,
      rpName: response.rpName,
      matches: response.matches || []
    });
    chrome.alarms.create(PASSKEY_WATCHDOG_ALARM, { delayInMinutes: PASSKEY_WATCHDOG_MS / 60000 });
    openPasskeyPopup();
    return;
  }

  // Every other reply — `locked`, `pairingRequired`, `error`, an unknown type, or no
  // reply at all — must still complete the request. Falling through here would hang the
  // ceremony on the page with no watchdog armed, and `locked` is the most likely
  // real-world reply.
  const reason = !response ? "MyPass did not respond"
    : response.type === "locked" ? "MyPass is locked"
    : response.type === "pairingRequired" ? "MyPass is not paired with this browser"
    : response.type === "error" ? "MyPass is unavailable"
    : `Unexpected MyPass response: ${response.type}`;
  await completePasskeyRequest(kind, { requestId, error: passkeyNotAllowedError(reason) });
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
  await new Promise((resolve) => chrome.storage.local.set({ [PASSKEY_ENABLED_KEY]: !!message.enabled }, () => resolve()));
  const response = await sendNativeMessageWithPairing(message);
  if (message.enabled) {
    await attachPasskeyProxyIfEligible();
  } else if (chrome.webAuthenticationProxy) {
    await chrome.webAuthenticationProxy.detach().catch(() => {});
  }
  return response;
}

function handleRuntimeMessage(message, sender, sendResponse) {
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

  if (!message || !knownTypes.includes(message.type)) {
    return false;
  }

  if (message.type === "setPasskeyProxyEnabled") {
    setPasskeyProxyEnabled(message).then(sendResponse);
    return true;
  }

  if (message.type === "passkeyCreateConfirm" || message.type === "passkeyGetApprove") {
    const kind = message.type === "passkeyCreateConfirm" ? "create" : "get";
    sendNativeMessageWithPairing(message).then((response) => {
      if (response && (response.type === "passkeyCreateComplete" || response.type === "passkeyGetComplete")) {
        return completePasskeyRequest(kind, {
          requestId: message.requestId,
          responseJson: response.responseJson,
          error: response.error
        }).then(() => sendResponse(response));
      }
      // The app refused (locked, pairing lost, no pending request). Complete the
      // ceremony anyway so the page is not left hanging on a popup that has closed.
      return completePasskeyRequest(kind, {
        requestId: message.requestId,
        error: passkeyNotAllowedError("MyPass could not complete the passkey request")
      }).then(() => sendResponse(response));
    });
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
      sendResponse(response);
    });
    return true;
  }

  sendNativeMessageWithPairing(message).then((response) => {
    if (message.type === "fillCredential" && response && response.type === "credential") {
      relayFillToActiveTab(response, message.url, sender);
      sendResponse(stripCredentialSecrets(response));
      return;
    }
    sendResponse(response);
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
    readPending().then((pending) => {
      if (pending && pending.requestId === requestId) {
        clearPending();
        chrome.alarms.clear(PASSKEY_WATCHDOG_ALARM);
      }
    });
    sendNativeMessageWithPairing({ type: "passkeyCancel", requestId }).catch(() => {});
  });

  chrome.alarms.onAlarm.addListener((alarm) => {
    if (alarm.name !== PASSKEY_WATCHDOG_ALARM) return;
    readPending().then((pending) => {
      if (!pending) return;
      completePasskeyRequest(pending.kind, {
        requestId: pending.requestId,
        error: passkeyNotAllowedError("Timed out waiting for confirmation")
      });
    });
  });

  attachPasskeyProxyIfEligible();
}

if (typeof module !== "undefined") {
  module.exports = {
    PAIRING_STORAGE_KEY,
    PASSKEY_WATCHDOG_ALARM,
    PENDING_KEY,
    knownTypes,
    attachPasskeyProxyIfEligible,
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
    hostnameMatches,
    resolveSenderFillTarget,
    relayFillToActiveTab
  };
}
