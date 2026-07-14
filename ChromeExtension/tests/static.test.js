"use strict";

const assert = require("node:assert/strict");
const { createHmac, webcrypto } = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const vm = require("node:vm");

const root = path.resolve(__dirname, "..");
const read = (relativePath) => fs.readFileSync(path.join(root, relativePath), "utf8");

function makeWorkerHarness(page = {}) {
  const listeners = () => ({ addListener() {}, removeListener() {} });
  const storage = {};
  const sockets = [];
  const removedTabs = [];

  class MockWebSocket {
    static CONNECTING = 0;
    static OPEN = 1;
    static CLOSED = 3;

    constructor(url) {
      this.url = url;
      this.readyState = MockWebSocket.CONNECTING;
      this.listeners = new Map();
      this.sent = [];
      sockets.push(this);
    }

    addEventListener(type, callback) {
      this.listeners.set(type, callback);
    }

    emit(type, event = {}) {
      if (type === "open") this.readyState = MockWebSocket.OPEN;
      if (type === "close") this.readyState = MockWebSocket.CLOSED;
      this.listeners.get(type)?.(event);
    }

    send(value) {
      assert.equal(this.readyState, MockWebSocket.OPEN);
      this.sent.push(JSON.parse(value));
    }

    close(code = 1000) {
      this.emit("close", { code });
    }
  }

  const sandbox = {
    URL,
    WebSocket: MockWebSocket,
    TextEncoder,
    btoa: (value) => Buffer.from(value, "binary").toString("base64"),
    crypto: webcrypto,
    document: page.document,
    location: page.location,
    setInterval: () => 1,
    clearInterval() {},
    setTimeout: () => 1,
    clearTimeout() {},
    chrome: {
      runtime: {
        onStartup: listeners(),
        onInstalled: listeners(),
        onMessage: listeners(),
        sendMessage: async () => undefined,
      },
      storage: {
        onChanged: listeners(),
        local: {
          get: async () => ({ ...storage }),
          set: async (values) => Object.assign(storage, values),
        },
      },
      tabs: {
        onUpdated: listeners(),
        onRemoved: listeners(),
        get: async (id) => ({ id, status: "loading" }),
        remove: async (id) => removedTabs.push(id),
      },
      scripting: {},
    },
  };

  vm.createContext(sandbox);
  vm.runInContext(read("service-worker.js"), sandbox, { filename: "service-worker.js" });
  return { context: sandbox, sockets, removedTabs };
}

function authenticationProof(token, role, clientNonce, serverNonce) {
  return createHmac("sha256", token)
    .update(`orchard-browser-bridge:v1:${role}:${clientNonce}:${serverNonce}`)
    .digest("base64url");
}

test("manifest is a narrowly-permissioned Chrome 116 MV3 extension", () => {
  const manifest = JSON.parse(read("manifest.json"));

  assert.equal(manifest.manifest_version, 3);
  assert.equal(manifest.minimum_chrome_version, "116");
  assert.deepEqual(manifest.permissions.sort(), ["scripting", "storage"]);
  assert.ok(!manifest.permissions.includes("tabs"));
  assert.equal(manifest.incognito, "not_allowed");
  assert.deepEqual(manifest.host_permissions.sort(), [
    "http://127.0.0.1/*",
    "https://consent.google.com/*",
    "https://www.google.com/*",
  ]);
  assert.equal(
    manifest.content_security_policy.extension_pages,
    "script-src 'self'; object-src 'self'; connect-src 'self' http://127.0.0.1:38476 ws://127.0.0.1:38476",
  );
  assert.equal(manifest.background.service_worker, "service-worker.js");
});

test("all extension JavaScript parses and popup scripts remain bundled", () => {
  for (const filename of ["service-worker.js", "popup.js"]) {
    assert.doesNotThrow(() => new vm.Script(read(filename), { filename }));
  }

  const popup = read("popup.html");
  const popupScript = read("popup.js");
  assert.match(popup, /<script src="popup\.js"><\/script>/);
  assert.doesNotMatch(popup, /<script[^>]+src=["']https?:/i);
  assert.doesNotMatch(popup, /on(?:click|load|error)\s*=/i);
  assert.match(popupScript, /fetch\(LOCAL_PERMISSION_PROBE_URL/);
  assert.match(popupScript, /http:\/\/127\.0\.0\.1:38476\//);
});

test("worker pins the authenticated loopback protocol and search bounds", () => {
  const worker = read("service-worker.js");

  assert.match(worker, /ws:\/\/127\.0\.0\.1:38476/);
  assert.match(worker, /HEARTBEAT_INTERVAL_MS\s*=\s*20_000/);
  assert.match(worker, /type:\s*"hello"/);
  assert.match(worker, /case\s+"hello\.challenge"/);
  assert.match(worker, /type:\s*"hello\.authenticate"/);
  assert.match(worker, /case\s+"hello\.ack"/);
  assert.match(worker, /crypto\.subtle\.sign\("HMAC"/);
  assert.match(worker, /case\s+"search\.request"/);
  assert.match(worker, /case\s+"search\.cancel"/);
  assert.match(worker, /type:\s*"search\.response"/);
  assert.match(worker, /MAX_RESULTS\s*=\s*8/);
  assert.match(worker, /MAX_INCOMING_MESSAGE_LENGTH\s*=\s*16_384/);
  assert.match(worker, /MAX_ACTIVE_SEARCHES\s*=\s*2/);
  assert.match(worker, /MAX_VISIBLE_TEXT_LENGTH\s*=\s*20_000/);
  assert.match(worker, /captcha_required/);
  assert.match(worker, /consent_required/);
});

test("mutual handshake proves both peers without sending the pairing token", async () => {
  const { context, sockets } = makeWorkerHarness();

  await context.handleSocketMessage('{"version":1,"type":"hello.ack","ok":true}');
  assert.notEqual(context.getStatusSnapshot().state, "connected");

  await context.handlePopupMessage({ type: "connection.connect", token: "test-token" });
  sockets[0].emit("open");
  const hello = sockets[0].sent[0];
  assert.equal(hello.version, 1);
  assert.equal(hello.type, "hello");
  assert.match(hello.clientNonce, /^[A-Za-z0-9_-]{43}$/);
  assert.equal(Object.hasOwn(hello, "token"), false);
  assert.doesNotMatch(JSON.stringify(hello), /test-token/);

  const serverNonce = context.makeAuthenticationNonce();
  const serverProof = authenticationProof(
    "test-token",
    "server",
    hello.clientNonce,
    serverNonce,
  );
  const challengeMessage = JSON.stringify({
    version: 1,
    type: "hello.challenge",
    serverNonce,
    proof: serverProof,
  });
  await Promise.all([
    context.handleSocketMessage(challengeMessage),
    context.handleSocketMessage(challengeMessage),
  ]);

  const authentication = sockets[0].sent[1];
  assert.equal(sockets[0].sent.length, 2);
  assert.equal(authentication.type, "hello.authenticate");
  assert.equal(
    authentication.proof,
    authenticationProof("test-token", "client", hello.clientNonce, serverNonce),
  );
  assert.equal(Object.hasOwn(authentication, "token"), false);

  await context.handleSocketMessage('{"version":1,"type":"hello.ack","ok":true}');
  assert.equal(context.getStatusSnapshot().state, "connected");
});

test("handshake fails closed when the local listener cannot prove the pairing token", async () => {
  const { context, sockets } = makeWorkerHarness();

  assert.equal(context.isAuthenticationValue("A".repeat(42)), false);
  assert.equal(context.isAuthenticationValue(`${"A".repeat(42)}=`), false);
  assert.equal(context.isAuthenticationValue("A".repeat(43)), true);

  await context.handlePopupMessage({ type: "connection.connect", token: "test-token" });
  sockets[0].emit("open");
  const sentBeforeChallenge = sockets[0].sent.length;
  await context.handleSocketMessage(
    JSON.stringify({
      version: 1,
      type: "hello.challenge",
      serverNonce: context.makeAuthenticationNonce(),
      proof: "A".repeat(43),
    }),
  );

  assert.equal(context.getStatusSnapshot().state, "rejected");
  assert.equal(context.getStatusSnapshot().enabled, false);
  assert.equal(sockets[0].sent.length, sentBeforeChallenge);
});

test("search cancellation closes only loading tabs and suppresses reordered requests", async () => {
  const { context, removedTabs } = makeWorkerHarness();

  vm.runInContext(
    'activeSearches.set("loading", { cancelled: false, tabId: 7, pageLoaded: false })',
    context,
  );
  await context.handleSearchCancellation({ id: "loading" });
  assert.equal(
    vm.runInContext('activeSearches.get("loading").cancelled', context),
    true,
  );
  assert.deepEqual(removedTabs, [7]);

  vm.runInContext(
    'activeSearches.set("loaded", { cancelled: false, tabId: 8, pageLoaded: true })',
    context,
  );
  await context.handleSearchCancellation({ id: "loaded" });
  assert.deepEqual(removedTabs, [7]);

  await context.handleSearchCancellation({ id: "cancel-before-request" });
  assert.equal(
    vm.runInContext('cancelledRequestIds.has("cancel-before-request")', context),
    true,
  );
  await context.handleSearchRequest({ id: "cancel-before-request" });
  assert.equal(
    vm.runInContext('cancelledRequestIds.has("cancel-before-request")', context),
    false,
  );
  assert.equal(
    vm.runInContext('activeSearches.has("cancel-before-request")', context),
    false,
  );
});

test("extractor keeps legitimate Google results without treating query text as an interstitial", () => {
  const container = (snippet) => ({
    innerText: snippet,
    textContent: snippet,
    querySelector: () => ({ innerText: snippet, textContent: snippet }),
  });
  const heading = (title, href, snippet) => {
    const resultContainer = container(snippet);
    const anchor = { href, parentElement: resultContainer };
    return {
      innerText: title,
      textContent: title,
      closest: (selector) => {
        if (selector === "a") return anchor;
        if (selector === ".MjjYud") return resultContainer;
        return null;
      },
    };
  };
  const headings = [
    heading("Chrome docs", "https://developers.google.com/chrome", "Developer documentation"),
    heading("Related search", "https://www.google.com/search?q=related", "Search Google"),
  ];
  for (const query of [
    "error handling",
    "complete the captcha",
    "consent.google",
    "google server error",
    "something went wrong. try again",
    "our systems have detected unusual traffic",
  ]) {
    const { context } = makeWorkerHarness({
      location: {
        hostname: "www.google.com",
        pathname: "/search",
        href: `https://www.google.com/search?q=${encodeURIComponent(query)}`,
      },
      document: {
        title: `${query} - Google Search`,
        body: { innerText: `Search results for ${query}` },
        querySelector: () => null,
        querySelectorAll: () => headings,
      },
    });

    const extraction = context.extractGooglePage(8);
    assert.equal(extraction.ok, true, query);
    assert.equal(extraction.result.results.length, 1, query);
    assert.equal(extraction.result.results[0].url, "https://developers.google.com/chrome");
  }
});
