"use strict";

const LOCAL_PERMISSION_PROBE_URL = "http://127.0.0.1:38476/";
const WEBSITE_ORIGINS = ["http://*/*", "https://*/*"];

const tokenInput = document.querySelector("#pairing-token");
const toggleTokenButton = document.querySelector("#toggle-token");
const saveTokenButton = document.querySelector("#save-token");
const connectButton = document.querySelector("#connect");
const disconnectButton = document.querySelector("#disconnect");
const statusDot = document.querySelector("#status-dot");
const statusLabel = document.querySelector("#status-label");
const statusDetail = document.querySelector("#status-detail");
const feedback = document.querySelector("#feedback");
const accessStatus = document.querySelector("#access-status");
const enableAccessButton = document.querySelector("#enable-access");
const disableAccessButton = document.querySelector("#disable-access");
let latestStatus = {
  state: "disconnected",
  enabled: false,
  hasToken: false,
  websiteAccess: false,
  error: "",
};

void loadPopup();

toggleTokenButton.addEventListener("click", () => {
  const reveal = tokenInput.type === "password";
  tokenInput.type = reveal ? "text" : "password";
  toggleTokenButton.textContent = reveal ? "Hide" : "Show";
  toggleTokenButton.setAttribute("aria-label", reveal ? "Hide pairing token" : "Show pairing token");
});

saveTokenButton.addEventListener("click", () => {
  void runCommand({ type: "token.save", token: tokenInput.value }, "Pairing token saved.");
});

connectButton.addEventListener("click", () => {
  // Chrome 147+ gates local WebSockets on Local Network Access. Starting this
  // harmless request from the popup's click gesture gives Chrome a document in
  // which to show that permission prompt. Orchard is WebSocket-only, so the
  // expected HTTP failure is intentionally ignored.
  primeLocalNetworkAccess();
  void runCommand(
    { type: "connection.connect", token: tokenInput.value },
    "Connecting to Orchard…",
  );
});

function primeLocalNetworkAccess() {
  void fetch(LOCAL_PERMISSION_PROBE_URL, {
    method: "GET",
    mode: "no-cors",
    cache: "no-store",
    credentials: "omit",
  }).catch(() => {});
}

disconnectButton.addEventListener("click", () => {
  void runCommand({ type: "connection.disconnect" }, "Disconnected.");
});

enableAccessButton.addEventListener("click", () => {
  void updateWebsiteAccess(true);
});

disableAccessButton.addEventListener("click", () => {
  void updateWebsiteAccess(false);
});

tokenInput.addEventListener("keydown", (event) => {
  if (event.key === "Enter") {
    event.preventDefault();
    connectButton.click();
  }
});

chrome.runtime.onMessage.addListener((message) => {
  if (message?.type === "status.changed" && message.status) {
    renderStatus(message.status);
  }
});

async function loadPopup() {
  try {
    const stored = await chrome.storage.local.get("pairingToken");
    if (typeof stored.pairingToken === "string") {
      tokenInput.value = stored.pairingToken;
    }
    const response = await chrome.runtime.sendMessage({ type: "status.get" });
    if (response?.status) {
      renderStatus(response.status);
    }
  } catch (error) {
    showFeedback(toMessage(error), true);
    renderStatus({ state: "disconnected", enabled: false, hasToken: false, error: "" });
  }
}

async function runCommand(message, successMessage) {
  setBusy(true);
  showFeedback("");
  try {
    const response = await chrome.runtime.sendMessage(message);
    if (response?.status) {
      renderStatus(response.status);
    }
    if (!response?.ok) {
      throw new Error(response?.error || "The extension could not complete that action.");
    }
    showFeedback(successMessage);
  } catch (error) {
    showFeedback(toMessage(error), true);
  } finally {
    setBusy(false);
  }
}

async function updateWebsiteAccess(enable) {
  setBusy(true);
  showFeedback("");
  try {
    const changed = enable
      ? await chrome.permissions.request({ origins: WEBSITE_ORIGINS })
      : await chrome.permissions.remove({ origins: WEBSITE_ORIGINS });
    if (enable && !changed) {
      throw new Error("Chrome did not grant website control.");
    }
    const response = await chrome.runtime.sendMessage({ type: "permissions.refresh" });
    if (response?.status) {
      renderStatus(response.status);
    }
    showFeedback(enable ? "Website control enabled." : "Website control revoked.");
  } catch (error) {
    showFeedback(toMessage(error), true);
  } finally {
    setBusy(false);
  }
}

function renderStatus(status) {
  latestStatus = status;
  const state = status.state || "disconnected";
  statusDot.className = "status-dot";
  renderAccess(status.websiteAccess === true);

  switch (state) {
    case "connected":
      statusDot.classList.add("connected");
      statusLabel.textContent = "Connected";
      statusDetail.textContent = status.websiteAccess
        ? "Paired with Orchard; website control is ready"
        : "Paired with Orchard; enable website control below";
      break;

    case "connecting":
      statusDot.classList.add("pending");
      statusLabel.textContent = "Connecting…";
      statusDetail.textContent = "Opening the local connection";
      break;

    case "authenticating":
      statusDot.classList.add("pending");
      statusLabel.textContent = "Pairing…";
      statusDetail.textContent = "Waiting for Orchard to accept the token";
      break;

    case "reconnecting":
      statusDot.classList.add("pending");
      statusLabel.textContent = "Reconnecting…";
      statusDetail.textContent = status.error || "Waiting for Orchard";
      break;

    case "rejected":
      statusDot.classList.add("error");
      statusLabel.textContent = "Pairing rejected";
      statusDetail.textContent = status.error || "Check the token in Orchard";
      break;

    case "unpaired":
      statusDot.classList.add("disconnected");
      statusLabel.textContent = "Pairing required";
      statusDetail.textContent = status.error || "Paste the token shown by Orchard";
      break;

    default:
      statusDot.classList.add(status.error ? "error" : "disconnected");
      statusLabel.textContent = "Disconnected";
      statusDetail.textContent = status.error || "127.0.0.1 only";
      break;
  }

  connectButton.disabled = state === "connected" || state === "connecting" || state === "authenticating";
  disconnectButton.disabled = !status.enabled && state !== "connected";
}

function renderAccess(enabled) {
  accessStatus.textContent = enabled
    ? "Enabled for HTTP and HTTPS pages"
    : "Not enabled";
  enableAccessButton.disabled = enabled;
  disableAccessButton.disabled = !enabled;
}

function setBusy(busy) {
  saveTokenButton.disabled = busy;
  enableAccessButton.disabled = busy;
  disableAccessButton.disabled = busy;
  if (busy) {
    connectButton.disabled = true;
    disconnectButton.disabled = true;
  } else {
    renderStatus(latestStatus);
  }
}

function showFeedback(message, isError = false) {
  feedback.textContent = message;
  feedback.classList.toggle("error", isError);
}

function toMessage(error) {
  return error instanceof Error && error.message ? error.message : String(error || "Unknown error");
}
