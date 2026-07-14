"use strict";

const PROTOCOL_VERSION = 2;
const LOOPBACK_URL = "ws://127.0.0.1:38476";
const HEARTBEAT_INTERVAL_MS = 20_000;
const LOAD_TIMEOUT_MS = 30_000;
const MAX_REQUEST_ID_LENGTH = 256;
const MAX_INCOMING_MESSAGE_LENGTH = 65_536;
const MAX_PENDING_COMMANDS = 20;
const MAX_QUEUED_RESPONSES = 20;
const MAX_CANCELLED_REQUEST_IDS = 100;
// Keep tab data well below Orchard's 128 KiB WebSocket message ceiling so the
// response envelope, request ID, outcome, and future bounded metadata have room.
const MAX_TAB_LIST_BYTES = 90_000;
const AUTHENTICATION_VALUE_LENGTH = 43;
const AUTHENTICATION_NONCE_BYTES = 32;
const AUTHENTICATION_CONTEXT = "orchard-browser-bridge:v2";
const WEBSITE_ORIGINS = Object.freeze(["http://*/*", "https://*/*"]);
const CAPABILITIES = Object.freeze([
  "page.inspect",
  "page.navigate",
  "page.click",
  "page.type",
  "page.select",
  "page.scroll",
  "page.back",
  "page.forward",
  "page.reload",
  "tabs.list",
  "tabs.activate",
  "tabs.close",
]);

const STORAGE_KEYS = Object.freeze({
  token: "pairingToken",
  enabled: "connectionEnabled",
});

const COMMAND_KEYS = Object.freeze({
  "page.inspect": ["action", "tabId", "expectedUrl"],
  "page.navigate": ["action", "tabId", "expectedUrl", "url", "newTab"],
  "page.click": ["action", "tabId", "expectedUrl", "snapshotId", "elementId"],
  "page.type": [
    "action",
    "tabId",
    "expectedUrl",
    "snapshotId",
    "elementId",
    "text",
    "clear",
    "submit",
  ],
  "page.select": ["action", "tabId", "expectedUrl", "snapshotId", "elementId", "value"],
  "page.scroll": ["action", "tabId", "expectedUrl", "direction", "amount"],
  "page.back": ["action", "tabId", "expectedUrl"],
  "page.forward": ["action", "tabId", "expectedUrl"],
  "page.reload": ["action", "tabId", "expectedUrl"],
  "tabs.list": ["action"],
  "tabs.activate": ["action", "tabId", "expectedUrl"],
  "tabs.close": ["action", "tabId", "expectedUrl"],
});

let initialized = false;
let initializePromise = null;
let pairingToken = "";
let connectionEnabled = false;
let websiteAccessEnabled = false;
let socket = null;
let socketGeneration = 0;
let heartbeatTimer = null;
let reconnectTimer = null;
let reconnectAttempt = 0;
let lastError = "";
let connectionState = "disconnected";
let connectionSession = 0;
let pendingHandshake = null;
let commandQueue = Promise.resolve();

const activeCommands = new Map();
const cancelledRequestIds = new Set();
const queuedResponses = [];

void initialize();

chrome.runtime.onStartup.addListener(() => {
  void initialize().then(() => {
    if (connectionEnabled) {
      connect();
    }
  });
});

chrome.runtime.onInstalled.addListener(() => {
  void initialize();
});

chrome.storage.onChanged.addListener((changes, areaName) => {
  if (areaName !== "local" || !initialized) {
    return;
  }

  if (Object.prototype.hasOwnProperty.call(changes, STORAGE_KEYS.token)) {
    pairingToken = normalizeToken(changes[STORAGE_KEYS.token].newValue);
  }

  if (Object.prototype.hasOwnProperty.call(changes, STORAGE_KEYS.enabled)) {
    connectionEnabled = changes[STORAGE_KEYS.enabled].newValue === true;
  }
});

chrome.permissions.onAdded.addListener(() => {
  void refreshWebsiteAccess();
});

chrome.permissions.onRemoved.addListener(() => {
  void refreshWebsiteAccess();
});

chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  void handlePopupMessage(message)
    .then(sendResponse)
    .catch((error) => {
      sendResponse({
        ok: false,
        error: toErrorMessage(error),
        status: getStatusSnapshot(),
      });
    });
  return true;
});

async function initialize() {
  if (initialized) {
    return;
  }
  if (initializePromise) {
    return initializePromise;
  }

  initializePromise = (async () => {
    const stored = await chrome.storage.local.get([
      STORAGE_KEYS.token,
      STORAGE_KEYS.enabled,
    ]);
    pairingToken = normalizeToken(stored[STORAGE_KEYS.token]);
    connectionEnabled = stored[STORAGE_KEYS.enabled] === true;
    websiteAccessEnabled = await hasWebsiteAccess();
    initialized = true;

    if (connectionEnabled && pairingToken) {
      connect();
    } else {
      connectionState = pairingToken ? "disconnected" : "unpaired";
      broadcastStatus();
    }
  })();

  try {
    await initializePromise;
  } finally {
    initializePromise = null;
  }
}

async function handlePopupMessage(message) {
  await initialize();

  if (!isPlainObject(message)) {
    return { ok: false, error: "Invalid command.", status: getStatusSnapshot() };
  }

  switch (message.type) {
    case "status.get":
      await refreshWebsiteAccess(false);
      return { ok: true, status: getStatusSnapshot() };

    case "permissions.refresh":
      await refreshWebsiteAccess();
      return { ok: true, status: getStatusSnapshot() };

    case "token.save": {
      const token = normalizeToken(message.token);
      if (!token) {
        return {
          ok: false,
          error: "Enter the pairing token shown by Orchard.",
          status: getStatusSnapshot(),
        };
      }

      const changed = token !== pairingToken;
      pairingToken = token;
      if (changed) {
        advanceConnectionSession();
      }
      await chrome.storage.local.set({ [STORAGE_KEYS.token]: token });

      if (changed && connectionEnabled) {
        closeSocket(false);
        connect();
      } else {
        if (!connectionEnabled) {
          connectionState = "disconnected";
          lastError = "";
        }
        broadcastStatus();
      }

      return { ok: true, status: getStatusSnapshot() };
    }

    case "connection.connect": {
      const token = normalizeToken(message.token || pairingToken);
      if (!token) {
        return {
          ok: false,
          error: "Enter the pairing token shown by Orchard.",
          status: getStatusSnapshot(),
        };
      }

      const tokenChanged = token !== pairingToken;
      if (!connectionEnabled || tokenChanged) {
        advanceConnectionSession();
      }
      pairingToken = token;
      connectionEnabled = true;
      lastError = "";
      await chrome.storage.local.set({
        [STORAGE_KEYS.token]: token,
        [STORAGE_KEYS.enabled]: true,
      });
      if (tokenChanged && socket) {
        closeSocket(false);
      }
      connect();
      return { ok: true, status: getStatusSnapshot() };
    }

    case "connection.disconnect":
      connectionEnabled = false;
      advanceConnectionSession();
      lastError = "";
      await chrome.storage.local.set({ [STORAGE_KEYS.enabled]: false });
      closeSocket(true);
      return { ok: true, status: getStatusSnapshot() };

    default:
      return { ok: false, error: "Unknown command.", status: getStatusSnapshot() };
  }
}

function connect() {
  if (!initialized || !connectionEnabled) {
    return;
  }
  if (!pairingToken) {
    connectionState = "unpaired";
    lastError = "A pairing token is required.";
    broadcastStatus();
    return;
  }
  if (
    socket &&
    (socket.readyState === WebSocket.OPEN || socket.readyState === WebSocket.CONNECTING)
  ) {
    return;
  }

  clearReconnectTimer();
  connectionState = "connecting";
  lastError = "";
  broadcastStatus();

  const generation = ++socketGeneration;
  let nextSocket;
  try {
    nextSocket = new WebSocket(LOOPBACK_URL);
  } catch (error) {
    connectionState = "reconnecting";
    lastError = `Could not open the local connection: ${toErrorMessage(error)}`;
    broadcastStatus();
    scheduleReconnect();
    return;
  }
  socket = nextSocket;

  nextSocket.addEventListener("open", () => {
    if (generation !== socketGeneration || socket !== nextSocket) {
      nextSocket.close();
      return;
    }

    reconnectAttempt = 0;
    connectionState = "authenticating";
    lastError = "";
    const clientNonce = makeAuthenticationNonce();
    pendingHandshake = {
      generation,
      clientNonce,
      sharedSecret: pairingToken,
      stage: "challenge-pending",
    };
    sendNow({
      version: PROTOCOL_VERSION,
      type: "hello",
      clientNonce,
      capabilities: [...CAPABILITIES],
    });
    broadcastStatus();
  });

  nextSocket.addEventListener("message", (event) => {
    if (generation === socketGeneration && socket === nextSocket) {
      void handleSocketMessage(event.data);
    }
  });

  nextSocket.addEventListener("error", () => {
    if (generation === socketGeneration && socket === nextSocket) {
      lastError = "Could not reach Orchard on this Mac.";
      broadcastStatus();
    }
  });

  nextSocket.addEventListener("close", (event) => {
    if (generation !== socketGeneration || socket !== nextSocket) {
      return;
    }

    socket = null;
    pendingHandshake = null;
    stopHeartbeat();
    if (!connectionEnabled) {
      connectionState =
        event.code === 4003 ? "rejected" : pairingToken ? "disconnected" : "unpaired";
      broadcastStatus();
      return;
    }

    connectionState = "reconnecting";
    if (event.code === 4001 || event.code === 4003) {
      lastError = "Pairing was rejected. Check the token in Orchard.";
    } else if (!lastError) {
      lastError = "Connection closed; retrying locally.";
    }
    broadcastStatus();
    scheduleReconnect();
  });
}

function closeSocket(wasRequestedByUser) {
  clearReconnectTimer();
  stopHeartbeat();
  socketGeneration += 1;
  pendingHandshake = null;

  const previousSocket = socket;
  socket = null;
  if (previousSocket) {
    try {
      previousSocket.close(1000, wasRequestedByUser ? "Disconnected by user" : "Reconnect");
    } catch {
      // The generation guard ignores stale close events.
    }
  }

  connectionState = connectionEnabled ? "reconnecting" : pairingToken ? "disconnected" : "unpaired";
  broadcastStatus();
}

function scheduleReconnect() {
  if (!connectionEnabled || reconnectTimer) {
    return;
  }

  const delay = Math.min(20_000, 1_000 * 2 ** Math.min(reconnectAttempt, 5));
  reconnectAttempt += 1;
  reconnectTimer = setTimeout(() => {
    reconnectTimer = null;
    connect();
  }, delay);
}

function clearReconnectTimer() {
  if (reconnectTimer) {
    clearTimeout(reconnectTimer);
    reconnectTimer = null;
  }
}

function startHeartbeat() {
  stopHeartbeat();
  heartbeatTimer = setInterval(() => {
    if (!sendNow({ version: PROTOCOL_VERSION, type: "ping" })) {
      stopHeartbeat();
      if (connectionEnabled) {
        scheduleReconnect();
      }
    }
  }, HEARTBEAT_INTERVAL_MS);
}

function stopHeartbeat() {
  if (heartbeatTimer) {
    clearInterval(heartbeatTimer);
    heartbeatTimer = null;
  }
}

async function handleSocketMessage(rawMessage) {
  let message;
  try {
    if (
      typeof rawMessage !== "string" ||
      rawMessage.length === 0 ||
      rawMessage.length > MAX_INCOMING_MESSAGE_LENGTH
    ) {
      return;
    }
    message = JSON.parse(rawMessage);
  } catch {
    return;
  }

  if (!isPlainObject(message) || message.version !== PROTOCOL_VERSION) {
    return;
  }

  switch (message.type) {
    case "hello.challenge": {
      if (
        connectionState !== "authenticating" ||
        !pendingHandshake ||
        pendingHandshake.generation !== socketGeneration ||
        pendingHandshake.stage !== "challenge-pending"
      ) {
        return;
      }

      const serverNonce = message.serverNonce;
      const serverProof = message.proof;
      if (!isAuthenticationValue(serverNonce) || !isAuthenticationValue(serverProof)) {
        rejectPairing("Orchard returned an invalid pairing challenge.");
        return;
      }

      const handshake = pendingHandshake;
      handshake.stage = "challenge-processing";
      try {
        const expectedServerProof = await makeAuthenticationProof(
          handshake.sharedSecret,
          "server",
          handshake.clientNonce,
          serverNonce,
        );
        if (!isCurrentHandshake(handshake, "challenge-processing")) {
          return;
        }
        if (!authenticationValuesMatch(serverProof, expectedServerProof)) {
          rejectPairing("Pairing was rejected. Check the token in Orchard.");
          return;
        }

        const clientProof = await makeAuthenticationProof(
          handshake.sharedSecret,
          "client",
          handshake.clientNonce,
          serverNonce,
        );
        if (!isCurrentHandshake(handshake, "challenge-processing")) {
          return;
        }
        handshake.stage = "response-sent";
        if (
          !sendNow({
            version: PROTOCOL_VERSION,
            type: "hello.authenticate",
            proof: clientProof,
          })
        ) {
          rejectPairing("The local pairing connection closed during authentication.");
        }
      } catch {
        rejectPairing("Chrome could not complete local pairing authentication.");
      }
      return;
    }

    case "hello.ack":
      if (
        connectionState !== "authenticating" ||
        !pendingHandshake ||
        pendingHandshake.stage !== "response-sent"
      ) {
        return;
      }
      if (message.ok !== true) {
        rejectPairing(
          extractRemoteError(message.error, "Orchard returned an invalid pairing response."),
        );
        return;
      }
      pendingHandshake = null;
      connectionState = "connected";
      lastError = "";
      startHeartbeat();
      broadcastStatus();
      flushQueuedResponses();
      return;

    case "ping":
      sendNow({ version: PROTOCOL_VERSION, type: "pong" });
      return;

    case "pong":
      return;

    case "browser.command":
      if (connectionState === "connected") {
        void enqueueBrowserCommand(message);
      }
      return;

    case "browser.cancel":
      if (connectionState === "connected") {
        handleBrowserCancellation(message);
      }
      return;

    default:
      return;
  }
}

async function enqueueBrowserCommand(message) {
  const id = normalizedRequestID(message.id);
  if (!id) {
    sendBrowserError("invalid", "invalid_request", "The browser command ID is invalid.");
    return;
  }
  if (cancelledRequestIds.delete(id)) {
    return;
  }
  if (activeCommands.has(id)) {
    sendBrowserError(id, "duplicate_request", "A browser command with this ID is already running.");
    return;
  }
  if (activeCommands.size >= MAX_PENDING_COMMANDS) {
    sendBrowserError(id, "busy", "Orchard Browser Control is already handling other commands.");
    return;
  }

  const context = {
    cancelled: false,
    session: connectionSession,
  };
  activeCommands.set(id, context);

  const run = commandQueue
    .catch(() => undefined)
    .then(async () => {
      try {
        if (context.cancelled || context.session !== connectionSession || !connectionEnabled) {
          return;
        }
        const result = await executeBrowserCommand(message.command);
        if (context.cancelled || context.session !== connectionSession || !connectionEnabled) {
          return;
        }
        queueOrSendResponse({
          version: PROTOCOL_VERSION,
          type: "browser.response",
          id,
          ok: true,
          result,
        });
      } catch (error) {
        if (context.cancelled || context.session !== connectionSession || !connectionEnabled) {
          return;
        }
        const normalized = normalizeBrowserError(error);
        sendBrowserError(id, normalized.code, normalized.message);
      } finally {
        activeCommands.delete(id);
      }
    });
  commandQueue = run.catch(() => undefined);
  await run;
}

function handleBrowserCancellation(message) {
  const id = normalizedRequestID(message.id);
  if (!id) {
    return;
  }
  const active = activeCommands.get(id);
  if (active) {
    active.cancelled = true;
    return;
  }
  if (cancelledRequestIds.size >= MAX_CANCELLED_REQUEST_IDS) {
    cancelledRequestIds.delete(cancelledRequestIds.values().next().value);
  }
  cancelledRequestIds.add(id);
}

async function executeBrowserCommand(command) {
  validateCommandShape(command);
  const action = command.action;

  if (action === "tabs.list") {
    return {
      action,
      outcome: "Listed the available normal Chrome tabs.",
      page: null,
      tabs: await listTabs(),
    };
  }

  if (action === "tabs.activate") {
    const tab = await resolveExpectedTab(command);
    const tabId = tab.id;
    await chrome.tabs.update(tabId, { active: true });
    if (Number.isInteger(tab.windowId) && chrome.windows?.update) {
      await chrome.windows.update(tab.windowId, { focused: true }).catch(() => undefined);
    }
    let observation;
    if (!isControllableURL(tab.url)) {
      observation = {
        page: null,
        observationWarning:
          "The tab was activated, but Chrome does not allow Orchard to inspect this page. " +
          "Choose an HTTP or HTTPS tab before using page controls.",
      };
    } else if (!(await hasWebsiteAccess())) {
      observation = {
        page: null,
        observationWarning:
          "The tab was activated, but website control is not enabled. " +
          "Enable Website Control in the extension popup before inspecting it.",
      };
    } else {
      observation = await observePageAfterMutation(tabId, async () => undefined);
    }
    return {
      action,
      outcome: `Activated Chrome tab ${tabId}.`,
      ...observation,
      // A semantic page snapshot and a tab listing are each independently
      // bounded near 90 KiB. Never combine them in one bridge response.
      tabs: null,
    };
  }

  if (action === "tabs.close") {
    const tab = await resolveExpectedTab(command);
    const tabId = tab.id;
    await chrome.tabs.remove(tabId);
    let tabs = null;
    let observationWarning = null;
    try {
      tabs = await listTabs();
    } catch {
      observationWarning =
        "The Chrome tab was closed, but Orchard could not refresh the remaining tab list. " +
        "List Chrome tabs again before using tab IDs.";
    }
    return {
      action,
      outcome: `Closed Chrome tab ${tabId}.`,
      page: null,
      tabs,
      observationWarning,
    };
  }

  if (action === "page.navigate") {
    const url = validatedNavigationURL(command.url);
    await requireWebsiteAccess();
    const newTab = optionalBoolean(command.newTab, false);
    let tab;
    if (newTab) {
      if (command.tabId !== undefined && command.tabId !== null) {
        throw new BrowserCommandError(
          "invalid_command",
          "Do not provide a tab ID when opening a new tab.",
        );
      }
      tab = await chrome.tabs.create({ url, active: true });
    } else {
      const target = await resolveExpectedTab(command);
      tab = await chrome.tabs.update(target.id, { url, active: true });
    }
    if (!Number.isInteger(tab?.id)) {
      throw new BrowserCommandError("tab_unavailable", "Chrome did not return a usable tab.");
    }
    const observation = await observePageAfterMutation(
      tab.id,
      () => waitForTabLoad(tab.id, tab.status),
    );
    return {
      action,
      outcome: `Navigated Chrome to ${url}.`,
      ...observation,
      tabs: null,
    };
  }

  if (["page.back", "page.forward", "page.reload"].includes(action)) {
    await requireWebsiteAccess();
    const tab = await resolveExpectedTab(command);
    if (action === "page.back") {
      await chrome.tabs.goBack(tab.id);
    } else if (action === "page.forward") {
      await chrome.tabs.goForward(tab.id);
    } else {
      await chrome.tabs.reload(tab.id);
    }
    const observation = await observePageAfterMutation(tab.id, () => settleTab(tab.id));
    return {
      action,
      outcome:
        action === "page.back"
          ? "Went back in Chrome history."
          : action === "page.forward"
            ? "Went forward in Chrome history."
            : "Reloaded the Chrome tab.",
      ...observation,
      tabs: null,
    };
  }

  if (action === "page.inspect") {
    const tab = await resolveTab(requiredTabID(command));
    return {
      action,
      outcome: "Inspected the Chrome tab.",
      page: await inspectTab(tab.id, requiredExpectedURL(command)),
      tabs: null,
    };
  }

  if (["page.click", "page.type", "page.select", "page.scroll"].includes(action)) {
    const tabId = requiredTabID(command);
    requiredExpectedURL(command);
    if (action !== "page.scroll") {
      requiredIdentifier(command.snapshotId, "snapshot ID", 128);
      requiredIdentifier(command.elementId, "element ID", 64);
    }
    if (action === "page.type") {
      if (typeof command.text !== "string" || command.text.length > 20_000) {
        throw new BrowserCommandError("invalid_text", "Text must be at most 20000 characters.");
      }
      optionalBoolean(command.clear, true);
      optionalBoolean(command.submit, false);
    }
    if (action === "page.select") {
      if (typeof command.value !== "string" || command.value.length > 500) {
        throw new BrowserCommandError("invalid_value", "The option value is invalid.");
      }
    }
    if (action === "page.scroll") {
      if (!["up", "down", "left", "right"].includes(command.direction)) {
        throw new BrowserCommandError("invalid_direction", "The scroll direction is invalid.");
      }
      if (
        command.amount !== undefined &&
        (!Number.isInteger(command.amount) || command.amount < 1 || command.amount > 5_000)
      ) {
        throw new BrowserCommandError("invalid_amount", "The scroll amount must be 1 through 5000.");
      }
    }

    const pageResult = await runPageAgentCommand(tabId, command);
    if (pageResult.ok !== true) {
      throw new BrowserCommandError(
        typeof pageResult.code === "string" ? pageResult.code : "page_action_failed",
        typeof pageResult.message === "string"
          ? pageResult.message
          : "The page action could not be completed.",
      );
    }
    const observation = await observePageAfterMutation(
      tabId,
      () => settleAfterPageAction(
        tabId,
        action === "page.click" || (action === "page.type" && command.submit === true),
      ),
    );
    return {
      action,
      outcome: String(pageResult.outcome || "Completed the browser action.").slice(0, 1_000),
      ...observation,
      tabs: null,
    };
  }

  throw new BrowserCommandError("unsupported_action", "That browser action is not supported.");
}

function validateCommandShape(command) {
  if (!isPlainObject(command) || typeof command.action !== "string") {
    throw new BrowserCommandError("invalid_command", "The browser command is invalid.");
  }
  const allowedKeys = COMMAND_KEYS[command.action];
  if (!allowedKeys) {
    throw new BrowserCommandError("unsupported_action", "That browser action is not supported.");
  }
  const allowed = new Set(allowedKeys);
  if (Object.keys(command).some((key) => !allowed.has(key))) {
    throw new BrowserCommandError(
      "unexpected_argument",
      "The browser command contained an unexpected argument.",
    );
  }
  const opensNewTab = command.action === "page.navigate" && command.newTab === true;
  if (command.action === "tabs.list" || opensNewTab) {
    if (Object.prototype.hasOwnProperty.call(command, "expectedUrl")) {
      throw new BrowserCommandError(
        "unexpected_argument",
        "This browser command must not include an expected tab URL.",
      );
    }
  } else if (command.tabId !== undefined && command.tabId !== null) {
    requiredExpectedURL(command);
  }
}

async function resolveTab(tabId) {
  if (tabId !== null && tabId !== undefined) {
    return chrome.tabs.get(tabId);
  }
  const tabs = await chrome.tabs.query({ active: true, lastFocusedWindow: true });
  const tab = tabs.find((candidate) => Number.isInteger(candidate.id));
  if (!tab) {
    throw new BrowserCommandError("tab_unavailable", "Chrome has no active tab to control.");
  }
  return tab;
}

async function resolveExpectedTab(command) {
  const tab = await chrome.tabs.get(requiredTabID(command));
  assertExpectedTabURL(tab, requiredExpectedURL(command));
  return tab;
}

function assertExpectedTabURL(tab, expectedURL) {
  const currentURL = normalizedTabURL(tab?.url);
  if (!currentURL || currentURL !== expectedURL) {
    throw new BrowserCommandError(
      "stale_tab",
      "The Chrome tab changed after Orchard observed it. List or inspect tabs again.",
    );
  }
}

function requiredExpectedURL(command) {
  const expectedURL = normalizedTabURL(command.expectedUrl);
  if (!expectedURL) {
    throw new BrowserCommandError(
      "invalid_expected_url",
      "The expected Chrome tab URL is missing or invalid.",
    );
  }
  return expectedURL;
}

function normalizedTabURL(rawValue) {
  if (typeof rawValue !== "string" || rawValue.length === 0 || rawValue.length > 4_096) {
    return null;
  }
  try {
    const url = new URL(rawValue);
    return url.href.length <= 4_096 ? url.href : null;
  } catch {
    return null;
  }
}

function requiredTabID(command) {
  const tabId = optionalTabID(command);
  if (tabId === null) {
    throw new BrowserCommandError("missing_tab", "A Chrome tab ID is required.");
  }
  return tabId;
}

function optionalTabID(command) {
  if (command.tabId === undefined || command.tabId === null) {
    return null;
  }
  if (!Number.isInteger(command.tabId) || command.tabId < 0) {
    throw new BrowserCommandError("invalid_tab", "The Chrome tab ID is invalid.");
  }
  return command.tabId;
}

function requiredIdentifier(value, label, maximumLength) {
  if (
    typeof value !== "string" ||
    value.length === 0 ||
    value.length > maximumLength ||
    !/^[A-Za-z0-9._:-]+$/.test(value)
  ) {
    throw new BrowserCommandError("invalid_identifier", `The ${label} is invalid.`);
  }
  return value;
}

function optionalBoolean(value, fallback) {
  if (value === undefined || value === null) {
    return fallback;
  }
  if (typeof value !== "boolean") {
    throw new BrowserCommandError("invalid_command", "A browser command flag is invalid.");
  }
  return value;
}

function validatedNavigationURL(rawValue) {
  if (typeof rawValue !== "string" || rawValue.length === 0 || rawValue.length > 4_096) {
    throw new BrowserCommandError("invalid_url", "The navigation URL is invalid.");
  }
  let url;
  try {
    url = new URL(rawValue);
  } catch {
    throw new BrowserCommandError("invalid_url", "The navigation URL is invalid.");
  }
  if (!/^https?:$/.test(url.protocol) || !url.hostname || url.username || url.password) {
    throw new BrowserCommandError(
      "unsafe_url",
      "Only complete HTTP or HTTPS URLs without embedded credentials are allowed.",
    );
  }
  return url.href;
}

async function listTabs() {
  const tabs = await chrome.tabs.query({ windowType: "normal" });
  const candidates = tabs
    .filter((tab) => Number.isInteger(tab.id) && Number.isInteger(tab.windowId))
    .sort((left, right) => Number(right.active) - Number(left.active))
    .slice(0, 40)
    .map((tab) => ({
      id: tab.id,
      windowId: tab.windowId,
      active: Boolean(tab.active),
      title: normalizedText(tab.title, 500),
      url: sanitizedTabURL(tab.url),
      controllable: isControllableURL(tab.url),
    }));

  const encoder = new TextEncoder();
  const boundedTabs = [];
  let encodedBytes = 2; // Opening and closing JSON array brackets.
  for (const tab of candidates) {
    const tabBytes = encoder.encode(JSON.stringify(tab)).byteLength;
    const delimiterBytes = boundedTabs.length === 0 ? 0 : 1;
    if (encodedBytes + delimiterBytes + tabBytes > MAX_TAB_LIST_BYTES) {
      break;
    }
    boundedTabs.push(tab);
    encodedBytes += delimiterBytes + tabBytes;
  }
  return boundedTabs;
}

function sanitizedTabURL(rawValue) {
  if (typeof rawValue !== "string" || rawValue.length === 0 || rawValue.length > 4_096) {
    return "";
  }
  const value = rawValue.replace(/\u0000/g, "").trim();
  try {
    const url = new URL(value);
    if (/^https?:$/.test(url.protocol)) {
      url.username = "";
      url.password = "";
      return url.href.length <= 4_096 ? url.href : "";
    }
    return url.href.length <= 4_096 ? url.href : "";
  } catch {
    return "";
  }
}

function isControllableURL(rawValue) {
  try {
    const url = new URL(rawValue);
    return /^https?:$/.test(url.protocol) && !url.username && !url.password;
  } catch {
    return false;
  }
}

async function inspectTab(tabId, expectedURL = null) {
  const tab = await chrome.tabs.get(tabId);
  if (!isControllableURL(tab.url)) {
    throw new BrowserCommandError(
      "restricted_page",
      "Chrome does not allow Orchard to control this page. Use an HTTP or HTTPS tab.",
    );
  }
  await requireWebsiteAccess();

  const command = expectedURL === null
    ? { action: "page.inspect" }
    : { action: "page.inspect", expectedUrl: expectedURL };
  const response = await runPageAgentCommand(tabId, command);
  if (response.ok !== true || !isPlainObject(response.snapshot)) {
    throw new BrowserCommandError(
      typeof response.code === "string" ? response.code : "inspection_failed",
      typeof response.message === "string"
        ? response.message
        : "The extension could not inspect this page.",
    );
  }
  return {
    tabId,
    ...response.snapshot,
    loading: tab.status !== "complete" || response.snapshot.loading === true,
  };
}

async function observePageAfterMutation(tabId, settle) {
  try {
    await settle();
    return {
      page: await inspectTab(tabId),
      observationWarning: null,
    };
  } catch {
    return {
      page: null,
      observationWarning:
        "The browser action succeeded, but Orchard could not inspect the resulting page. " +
        "Inspect the tab again before using page or element IDs.",
    };
  }
}

async function requireWebsiteAccess() {
  if (!(await hasWebsiteAccess())) {
    throw new BrowserCommandError(
      "website_access_required",
      "Open the extension popup and choose Enable Website Control first.",
    );
  }
}

async function runPageAgentCommand(tabId, command) {
  try {
    await chrome.scripting.executeScript({
      target: { tabId },
      world: "ISOLATED",
      files: ["page-agent.js"],
    });
    const results = await chrome.scripting.executeScript({
      target: { tabId },
      world: "ISOLATED",
      func: invokePageAgent,
      args: [command],
    });
    const result = results?.[0]?.result;
    if (!isPlainObject(result)) {
      throw new BrowserCommandError(
        "page_agent_unavailable",
        "The page did not return a usable browser-control result.",
      );
    }
    return result;
  } catch (error) {
    if (error instanceof BrowserCommandError) {
      throw error;
    }
    throw new BrowserCommandError(
      "page_unavailable",
      `Chrome could not control this page: ${toErrorMessage(error)}`,
    );
  }
}

function invokePageAgent(command) {
  const agent = globalThis.__orchardBrowserControlAgentV2;
  if (!agent || typeof agent.run !== "function") {
    return {
      ok: false,
      code: "page_agent_unavailable",
      message: "The Orchard page controller is unavailable.",
    };
  }
  return agent.run(command);
}

async function settleAfterPageAction(tabId, mayNavigate) {
  await delay(mayNavigate ? 300 : 120);
  const tab = await chrome.tabs.get(tabId);
  if (tab.status === "loading") {
    await waitForTabLoad(tabId, tab.status);
  } else {
    await delay(120);
  }
}

async function settleTab(tabId) {
  await delay(100);
  const tab = await chrome.tabs.get(tabId);
  await waitForTabLoad(tabId, tab.status);
}

function waitForTabLoad(tabId, initialStatus) {
  if (initialStatus === "complete") {
    return Promise.resolve();
  }

  return new Promise((resolve, reject) => {
    let settled = false;
    const cleanup = () => {
      chrome.tabs.onUpdated.removeListener(onUpdated);
      chrome.tabs.onRemoved.removeListener(onRemoved);
      clearTimeout(timeout);
    };
    const finish = (callback) => {
      if (settled) return;
      settled = true;
      cleanup();
      callback();
    };
    const onUpdated = (updatedTabId, changeInfo) => {
      if (updatedTabId === tabId && changeInfo.status === "complete") {
        finish(resolve);
      }
    };
    const onRemoved = (removedTabId) => {
      if (removedTabId === tabId) {
        finish(() => reject(new BrowserCommandError("tab_closed", "The Chrome tab was closed.")));
      }
    };
    const timeout = setTimeout(() => {
      finish(() =>
        reject(new BrowserCommandError("load_timeout", "The Chrome page took too long to load.")),
      );
    }, LOAD_TIMEOUT_MS);

    chrome.tabs.onUpdated.addListener(onUpdated);
    chrome.tabs.onRemoved.addListener(onRemoved);
    void chrome.tabs
      .get(tabId)
      .then((currentTab) => {
        if (currentTab.status === "complete") {
          finish(resolve);
        }
      })
      .catch(() => {
        finish(() => reject(new BrowserCommandError("tab_closed", "The Chrome tab is gone.")));
      });
  });
}

function delay(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

function sendBrowserError(id, code, message) {
  queueOrSendResponse({
    version: PROTOCOL_VERSION,
    type: "browser.response",
    id,
    ok: false,
    error: {
      code: normalizedErrorCode(code),
      message: normalizedText(message, 500) || "The browser command failed.",
    },
  });
}

function queueOrSendResponse(response) {
  if (connectionState === "connected" && sendNow(response)) {
    return;
  }
  if (queuedResponses.length >= MAX_QUEUED_RESPONSES) {
    queuedResponses.shift();
  }
  queuedResponses.push(response);
}

function flushQueuedResponses() {
  while (queuedResponses.length > 0 && connectionState === "connected") {
    if (!sendNow(queuedResponses[0])) {
      return;
    }
    queuedResponses.shift();
  }
}

function sendNow(message) {
  if (!socket || socket.readyState !== WebSocket.OPEN) {
    return false;
  }
  try {
    socket.send(JSON.stringify(message));
    return true;
  } catch {
    return false;
  }
}

function getStatusSnapshot() {
  return {
    state: connectionState,
    enabled: connectionEnabled,
    hasToken: Boolean(pairingToken),
    websiteAccess: websiteAccessEnabled,
    error: lastError,
    endpoint: LOOPBACK_URL,
  };
}

function broadcastStatus() {
  void chrome.runtime
    .sendMessage({ type: "status.changed", status: getStatusSnapshot() })
    .catch(() => {
      // The popup is usually closed, so no receiver is expected.
    });
}

async function hasWebsiteAccess() {
  try {
    return await chrome.permissions.contains({ origins: [...WEBSITE_ORIGINS] });
  } catch {
    return false;
  }
}

async function refreshWebsiteAccess(shouldBroadcast = true) {
  const nextValue = await hasWebsiteAccess();
  const changed = websiteAccessEnabled !== nextValue;
  websiteAccessEnabled = nextValue;
  if (shouldBroadcast && changed) {
    broadcastStatus();
  }
}

function normalizeToken(value) {
  return typeof value === "string" ? value.trim().slice(0, 512) : "";
}

function normalizedRequestID(value) {
  if (typeof value !== "string") return "";
  const id = value.trim();
  return id && id.length <= MAX_REQUEST_ID_LENGTH ? id : "";
}

function normalizedText(value, maximumLength) {
  return typeof value === "string"
    ? value.replace(/\u0000/g, "").replace(/\s+/g, " ").trim().slice(0, maximumLength)
    : "";
}

function normalizedErrorCode(value) {
  const code = String(value || "browser_error")
    .replace(/[^A-Za-z0-9._-]/g, "")
    .slice(0, 64);
  return code || "browser_error";
}

function makeAuthenticationNonce() {
  const bytes = new Uint8Array(AUTHENTICATION_NONCE_BYTES);
  crypto.getRandomValues(bytes);
  return base64URLEncode(bytes);
}

async function makeAuthenticationProof(token, role, clientNonce, serverNonce) {
  const encoder = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(token),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const payload = `${AUTHENTICATION_CONTEXT}:${role}:${clientNonce}:${serverNonce}`;
  const signature = await crypto.subtle.sign("HMAC", key, encoder.encode(payload));
  return base64URLEncode(new Uint8Array(signature));
}

function base64URLEncode(bytes) {
  return btoa(String.fromCharCode(...bytes))
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/g, "");
}

function isAuthenticationValue(value) {
  return (
    typeof value === "string" &&
    value.length === AUTHENTICATION_VALUE_LENGTH &&
    /^[A-Za-z0-9_-]+$/.test(value)
  );
}

function authenticationValuesMatch(supplied, expected) {
  if (!isAuthenticationValue(supplied) || !isAuthenticationValue(expected)) {
    return false;
  }
  let difference = 0;
  for (let index = 0; index < supplied.length; index += 1) {
    difference |= supplied.charCodeAt(index) ^ expected.charCodeAt(index);
  }
  return difference === 0;
}

function isCurrentHandshake(handshake, stage) {
  return (
    pendingHandshake === handshake &&
    pendingHandshake.stage === stage &&
    pendingHandshake.generation === socketGeneration &&
    connectionState === "authenticating"
  );
}

function rejectPairing(message) {
  pendingHandshake = null;
  lastError = message;
  connectionState = "rejected";
  connectionEnabled = false;
  stopHeartbeat();
  advanceConnectionSession();
  void chrome.storage.local.set({ [STORAGE_KEYS.enabled]: false });
  broadcastStatus();
  if (socket) {
    socket.close(4003, "Pairing rejected");
  }
}

function advanceConnectionSession() {
  connectionSession += 1;
  queuedResponses.length = 0;
  cancelledRequestIds.clear();
  for (const command of activeCommands.values()) {
    command.cancelled = true;
  }
}

function isPlainObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function extractRemoteError(error, fallback) {
  if (typeof error === "string" && error.trim()) {
    return error.trim();
  }
  if (isPlainObject(error) && typeof error.message === "string" && error.message.trim()) {
    return error.message.trim();
  }
  return fallback;
}

function toErrorMessage(error) {
  return error instanceof Error && error.message ? error.message : String(error || "Unknown error");
}

function normalizeBrowserError(error) {
  if (error instanceof BrowserCommandError) {
    return { code: error.code, message: error.message };
  }
  return { code: "browser_failed", message: toErrorMessage(error) };
}

class BrowserCommandError extends Error {
  constructor(code, message) {
    super(message);
    this.name = "BrowserCommandError";
    this.code = code;
  }
}
