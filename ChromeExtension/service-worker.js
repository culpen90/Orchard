"use strict";

const PROTOCOL_VERSION = 1;
const LOOPBACK_URL = "ws://127.0.0.1:38476";
const HEARTBEAT_INTERVAL_MS = 20_000;
const LOAD_TIMEOUT_MS = 30_000;
const MAX_RESULTS = 8;
const MAX_QUERY_LENGTH = 1_000;
const MAX_REQUEST_ID_LENGTH = 256;
const MAX_INCOMING_MESSAGE_LENGTH = 16_384;
const MAX_ACTIVE_SEARCHES = 2;
const MAX_QUEUED_RESPONSES = 20;
const MAX_CANCELLED_REQUEST_IDS = 100;
const AUTHENTICATION_VALUE_LENGTH = 43;
const AUTHENTICATION_NONCE_BYTES = 32;
const AUTHENTICATION_CONTEXT = "orchard-browser-bridge:v1";

const STORAGE_KEYS = Object.freeze({
  token: "pairingToken",
  enabled: "connectionEnabled",
});

let initialized = false;
let initializePromise = null;
let pairingToken = "";
let connectionEnabled = false;
let socket = null;
let socketGeneration = 0;
let heartbeatTimer = null;
let reconnectTimer = null;
let reconnectAttempt = 0;
let lastError = "";
let connectionState = "disconnected";
let connectionSession = 0;
let pendingHandshake = null;

const activeSearches = new Map();
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
      // Closing is best-effort; the generation guard ignores stale events.
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

    case "search.request":
      if (connectionState !== "connected") {
        return;
      }
      await handleSearchRequest(message);
      return;

    case "search.cancel":
      if (connectionState !== "connected") {
        return;
      }
      await handleSearchCancellation(message);
      return;

    default:
      return;
  }
}

async function handleSearchRequest(message) {
  const id = typeof message.id === "string" ? message.id.trim() : "";
  if (!id || id.length > MAX_REQUEST_ID_LENGTH) {
    sendSearchError("invalid", "invalid_request", "The search request ID is invalid.");
    return;
  }

  if (cancelledRequestIds.delete(id)) {
    return;
  }

  if (activeSearches.has(id)) {
    sendSearchError(id, "duplicate_request", "A search with this ID is already running.");
    return;
  }
  if (activeSearches.size >= MAX_ACTIVE_SEARCHES) {
    sendSearchError(id, "busy", "Orchard Browser Search is already handling other searches.");
    return;
  }

  const query = typeof message.query === "string" ? message.query.trim() : "";
  if (!query || query.length > MAX_QUERY_LENGTH) {
    sendSearchError(
      id,
      "invalid_query",
      `The query must contain 1 to ${MAX_QUERY_LENGTH} characters.`,
    );
    return;
  }

  const requestedMax = Number.isFinite(message.maxResults)
    ? Math.trunc(message.maxResults)
    : MAX_RESULTS;
  const maxResults = Math.max(1, Math.min(MAX_RESULTS, requestedMax));
  const requestSession = connectionSession;
  const activeSearch = {
    cancelled: false,
    tabId: null,
    pageLoaded: false,
  };

  activeSearches.set(id, activeSearch);
  try {
    const result = await searchGoogle(query, maxResults, activeSearch);
    if (activeSearch.cancelled || !connectionEnabled || requestSession !== connectionSession) {
      return;
    }
    queueOrSendResponse({
      version: PROTOCOL_VERSION,
      type: "search.response",
      id,
      ok: true,
      result,
    });
  } catch (error) {
    if (
      activeSearch.cancelled ||
      !connectionEnabled ||
      requestSession !== connectionSession
    ) {
      return;
    }
    const normalized = normalizeSearchError(error);
    sendSearchError(id, normalized.code, normalized.message);
  } finally {
    activeSearches.delete(id);
  }
}

async function handleSearchCancellation(message) {
  const id = typeof message.id === "string" ? message.id.trim() : "";
  if (!id || id.length > MAX_REQUEST_ID_LENGTH) {
    return;
  }

  const activeSearch = activeSearches.get(id);
  if (!activeSearch) {
    if (cancelledRequestIds.size >= MAX_CANCELLED_REQUEST_IDS) {
      cancelledRequestIds.delete(cancelledRequestIds.values().next().value);
    }
    cancelledRequestIds.add(id);
    return;
  }
  activeSearch.cancelled = true;

  if (!Number.isInteger(activeSearch.tabId) || activeSearch.pageLoaded) {
    return;
  }

  try {
    const tab = await chrome.tabs.get(activeSearch.tabId);
    if (tab.status === "complete") {
      activeSearch.pageLoaded = true;
      return;
    }
    await chrome.tabs.remove(activeSearch.tabId);
  } catch {
    // The tab may have loaded or been closed while cancellation was propagating.
  }
}

async function searchGoogle(query, maxResults, activeSearch) {
  const searchURL = new URL("https://www.google.com/search");
  searchURL.searchParams.set("q", query);
  searchURL.searchParams.set("hl", "en");
  searchURL.searchParams.set("pws", "0");

  let tab;
  try {
    tab = await chrome.tabs.create({ url: searchURL.href, active: true });
  } catch (error) {
    throw new SearchError("tab_open_failed", `Could not open a search tab: ${toErrorMessage(error)}`);
  }

  if (!Number.isInteger(tab.id)) {
    throw new SearchError("tab_open_failed", "Chrome did not return a usable search tab.");
  }

  activeSearch.tabId = tab.id;
  activeSearch.pageLoaded = tab.status === "complete";
  if (activeSearch.cancelled) {
    if (!activeSearch.pageLoaded) {
      try {
        await chrome.tabs.remove(tab.id);
      } catch {
        // Cancellation is already complete even if Chrome closed the tab first.
      }
    }
    throw new SearchError("cancelled", "The browser search was cancelled.");
  }

  await waitForTabLoad(tab.id, tab.status);
  activeSearch.pageLoaded = true;
  if (activeSearch.cancelled) {
    throw new SearchError("cancelled", "The browser search was cancelled.");
  }

  let injectionResults;
  try {
    injectionResults = await chrome.scripting.executeScript({
      target: { tabId: tab.id },
      world: "ISOLATED",
      func: extractGooglePage,
      args: [maxResults],
    });
  } catch (error) {
    throw new SearchError(
      "page_unavailable",
      `The Google page could not be read. It may have redirected to a consent or error page. ${toErrorMessage(error)}`,
    );
  }

  if (activeSearch.cancelled) {
    throw new SearchError("cancelled", "The browser search was cancelled.");
  }

  const extraction = injectionResults?.[0]?.result;
  if (!isPlainObject(extraction)) {
    throw new SearchError("extraction_failed", "The search page returned no readable content.");
  }
  if (extraction.ok !== true) {
    throw new SearchError(
      typeof extraction.code === "string" ? extraction.code : "extraction_failed",
      typeof extraction.message === "string"
        ? extraction.message
        : "The search page could not be used.",
    );
  }

  return extraction.result;
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
      if (settled) {
        return;
      }
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
        finish(() => reject(new SearchError("tab_closed", "The search tab was closed before it loaded.")));
      }
    };
    const timeout = setTimeout(() => {
      finish(() => reject(new SearchError("load_timeout", "The Google search page took too long to load.")));
    }, LOAD_TIMEOUT_MS);

    chrome.tabs.onUpdated.addListener(onUpdated);
    chrome.tabs.onRemoved.addListener(onRemoved);

    // The tab can finish between tabs.create() resolving and listener registration.
    // Re-reading its status after the listeners are attached closes that race.
    void chrome.tabs
      .get(tabId)
      .then((currentTab) => {
        if (currentTab.status === "complete") {
          finish(resolve);
        }
      })
      .catch(() => {
        finish(() =>
          reject(new SearchError("tab_closed", "The search tab is no longer available.")),
        );
      });
  });
}

// This fixed, bundled function is serialized by chrome.scripting. It never evaluates
// text from Orchard or from the page as code.
function extractGooglePage(requestedMaxResults) {
  const MAX_VISIBLE_TEXT_LENGTH = 20_000;
  const MAX_TITLE_LENGTH = 300;
  const MAX_URL_LENGTH = 2_048;
  const MAX_SNIPPET_LENGTH = 1_200;

  const normalizeText = (value, limit) =>
    String(value || "")
      .replace(/\s+/g, " ")
      .trim()
      .slice(0, limit);
  const isSearchGoogleHost = (value) => value === "google.com" || value === "www.google.com";
  const isInternalGoogleURL = (value) =>
    isSearchGoogleHost(value.hostname) &&
    ["/search", "/url", "/aclk", "/imgres", "/preferences", "/setprefs"].includes(
      value.pathname,
    );

  const bodyText = normalizeText(document.body?.innerText, MAX_VISIBLE_TEXT_LENGTH);
  const hostname = location.hostname.toLowerCase();
  const pathname = location.pathname.toLowerCase();
  const hasPageMarker = (...selectors) =>
    selectors.some((selector) => Boolean(document.querySelector?.(selector)));

  if (
    hostname === "consent.google.com" ||
    hasPageMarker(
      "form[action*='consent.google.com']",
      "form[action*='/consent']",
      "#consent-bump",
    )
  ) {
    return {
      ok: false,
      code: "consent_required",
      message: "Google is asking for consent. Complete that page in the visible tab, then try again.",
    };
  }

  if (
    pathname.startsWith("/sorry/") ||
    hasPageMarker(
      "form[action*='/sorry/']",
      "#captcha-form",
      "iframe[src*='recaptcha']",
      "textarea[name='g-recaptcha-response']",
    )
  ) {
    return {
      ok: false,
      code: "captcha_required",
      message: "Google requires a CAPTCHA. Complete it in the visible tab, then try again.",
    };
  }

  if (hostname !== "www.google.com" || pathname !== "/search") {
    return {
      ok: false,
      code: "unexpected_page",
      message: "Google redirected the search to an unsupported page.",
    };
  }

  if (
    pathname === "/error" ||
    /^error\s+\d{3}\s+\(server error\)(?:!!1)?$/i.test((document.title || "").trim())
  ) {
    return {
      ok: false,
      code: "search_page_error",
      message: "Google returned an error page. Try the search again.",
    };
  }

  const maxResults = Math.max(1, Math.min(8, Number(requestedMaxResults) || 8));
  const results = [];
  const seenURLs = new Set();
  const headings = document.querySelectorAll("#search a > h3, #rso a > h3");

  for (const heading of headings) {
    if (results.length >= maxResults) {
      break;
    }

    const anchor = heading.closest("a");
    const title = normalizeText(heading.innerText || heading.textContent, MAX_TITLE_LENGTH);
    if (!anchor || !title) {
      continue;
    }

    let url;
    try {
      const candidate = new URL(anchor.href, location.href);
      if (isSearchGoogleHost(candidate.hostname) && candidate.pathname === "/url") {
        const unwrapped = candidate.searchParams.get("q") || candidate.searchParams.get("url");
        if (!unwrapped) {
          continue;
        }
        url = new URL(unwrapped);
      } else {
        url = candidate;
      }
    } catch {
      continue;
    }

    if (!/^https?:$/.test(url.protocol) || isInternalGoogleURL(url)) {
      continue;
    }

    url.username = "";
    url.password = "";
    url.hash = "";
    if (url.href.length > MAX_URL_LENGTH) {
      continue;
    }
    const normalizedURL = url.href;
    if (seenURLs.has(normalizedURL)) {
      continue;
    }

    const container =
      heading.closest(".MjjYud") ||
      heading.closest(".g") ||
      heading.closest("[data-hveid]") ||
      anchor.parentElement;
    const snippetElement = container?.querySelector(
      ".VwiC3b, [data-sncf], .IsZvec, .aCOpRe, [data-content-feature='1']",
    );
    let snippet = normalizeText(
      snippetElement?.innerText || snippetElement?.textContent,
      MAX_SNIPPET_LENGTH,
    );

    if (!snippet && container) {
      snippet = normalizeText(container.innerText || container.textContent, MAX_SNIPPET_LENGTH);
      if (snippet.startsWith(title)) {
        snippet = normalizeText(snippet.slice(title.length), MAX_SNIPPET_LENGTH);
      }
    }

    seenURLs.add(normalizedURL);
    results.push({ title, url: normalizedURL, snippet });
  }

  return {
    ok: true,
    result: {
      pageTitle: normalizeText(document.title, MAX_TITLE_LENGTH),
      pageURL: location.href.slice(0, MAX_URL_LENGTH),
      visibleText: bodyText,
      results,
    },
  };
}

function sendSearchError(id, code, message) {
  queueOrSendResponse({
    version: PROTOCOL_VERSION,
    type: "search.response",
    id,
    ok: false,
    error: { code, message },
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

function normalizeToken(value) {
  return typeof value === "string" ? value.trim().slice(0, 512) : "";
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
  for (const activeSearch of activeSearches.values()) {
    activeSearch.cancelled = true;
    if (Number.isInteger(activeSearch.tabId) && !activeSearch.pageLoaded) {
      void chrome.tabs.remove(activeSearch.tabId).catch(() => {
        // The tab may already be gone.
      });
    }
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

function normalizeSearchError(error) {
  if (error instanceof SearchError) {
    return { code: error.code, message: error.message };
  }
  return { code: "search_failed", message: toErrorMessage(error) };
}

class SearchError extends Error {
  constructor(code, message) {
    super(message);
    this.name = "SearchError";
    this.code = code;
  }
}
