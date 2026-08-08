const NATIVE_HOST_NAME = "com.mypass.chromehost";
const PAIRING_STORAGE_KEY = "pairingSecret";
const knownTypes = ["getCredentials", "fillCredential", "getTotp", "proposeSaveLogin", "proposeSaveTotp", "startPairing", "completePairing", "requestUnlock"];

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

function relayFillToActiveTab(credentialResponse, requestUrl) {
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

    chrome.tabs.sendMessage(
      activeTab.id,
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

function handleRuntimeMessage(message, sender, sendResponse) {
  if (message && message.type === "openPopupForTotpPicker") {
    if (chrome.action && typeof chrome.action.openPopup === "function") {
      chrome.action.openPopup().catch(() => {});
    }
    return false;
  }

  if (!message || !knownTypes.includes(message.type)) {
    return false;
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
      relayFillToActiveTab(response, message.url);
      sendResponse(stripCredentialSecrets(response));
      return;
    }
    sendResponse(response);
  });

  return true; // keep the message channel open for the async sendNativeMessage response
}

chrome.runtime.onMessage.addListener(handleRuntimeMessage);

if (typeof module !== "undefined") {
  module.exports = {
    PAIRING_STORAGE_KEY,
    knownTypes,
    attachPairingField,
    persistPairingResponse,
    clearStaleSecretOnPairingRequired,
    detectBrowserName,
    sendPairingCompletion,
    handleRuntimeMessage
  };
}
