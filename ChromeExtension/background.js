const NATIVE_HOST_NAME = "com.mypass.chromehost";

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

function relayFillToActiveTab(credentialResponse, requestUrl) {
  chrome.tabs.query({ active: true, currentWindow: true }, (tabs) => {
    const activeTab = tabs[0];
    if (!activeTab || activeTab.id === undefined) return;
    chrome.tabs.sendMessage(activeTab.id, {
      type: "applyFill",
      username: credentialResponse.username,
      password: credentialResponse.password,
      totp: credentialResponse.totp || null,
      url: requestUrl
    });
  });
}

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  const knownTypes = ["getCredentials", "fillCredential", "proposeSaveLogin"];
  if (!message || !knownTypes.includes(message.type)) {
    return false;
  }

  sendNativeMessage(message).then((response) => {
    if (message.type === "fillCredential" && response && response.type === "credential") {
      relayFillToActiveTab(response, message.url);
    }
    sendResponse(response);
  });

  return true; // keep the message channel open for the async sendNativeMessage response
});
