"use strict";

const assert = require("node:assert/strict");
const { createHmac, webcrypto } = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const vm = require("node:vm");

const root = path.resolve(__dirname, "..");
const read = (relativePath) => fs.readFileSync(path.join(root, relativePath), "utf8");

function eventHook() {
  const callbacks = new Set();
  return {
    addListener(callback) {
      callbacks.add(callback);
    },
    removeListener(callback) {
      callbacks.delete(callback);
    },
    emit(...args) {
      for (const callback of callbacks) callback(...args);
    },
  };
}

function makeWorkerHarness({
  websiteAccess = true,
  inspectionFails = false,
  pageActionFails = false,
  settleFailsAfterMutation = false,
  tabListFailsAfterClose = false,
  snapshotText = "Visible page text",
} = {}) {
  const storage = {};
  const sockets = [];
  const removedTabs = [];
  const tabUpdates = [];
  const tabs = new Map([
    [
      1,
      {
        id: 1,
        windowId: 10,
        active: true,
        title: "Example",
        url: "https://example.com/",
        status: "complete",
      },
    ],
    [
      2,
      {
        id: 2,
        windowId: 10,
        active: false,
        title: "Internal",
        url: "chrome://settings/",
        status: "complete",
      },
    ],
  ]);
  let nextTabId = 3;
  let pageActionCompleted = false;

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

  const runtime = {
    onStartup: eventHook(),
    onInstalled: eventHook(),
    onMessage: eventHook(),
    sendMessage: async () => undefined,
  };
  const tabsAPI = {
    onUpdated: eventHook(),
    onRemoved: eventHook(),
    async get(id) {
      if (settleFailsAfterMutation && pageActionCompleted) {
        throw new Error("The tab became unavailable after the page action.");
      }
      const tab = tabs.get(id);
      if (!tab) throw new Error("No tab");
      return { ...tab };
    },
    async query(query) {
      if (tabListFailsAfterClose && removedTabs.length > 0) {
        throw new Error("The tab list became unavailable after the close.");
      }
      let values = [...tabs.values()];
      if (query.active) values = values.filter((tab) => tab.active);
      return values.map((tab) => ({ ...tab }));
    },
    async create({ url, active }) {
      const tab = {
        id: nextTabId++,
        windowId: 10,
        active,
        title: "Created",
        url,
        status: "complete",
      };
      if (active) {
        for (const existing of tabs.values()) existing.active = false;
      }
      tabs.set(tab.id, tab);
      return { ...tab };
    },
    async update(id, changes) {
      const tab = tabs.get(id);
      if (!tab) throw new Error("No tab");
      if (changes.active) {
        for (const existing of tabs.values()) existing.active = false;
      }
      Object.assign(tab, changes, { status: "complete" });
      tabUpdates.push({ id, changes: { ...changes } });
      return { ...tab };
    },
    async remove(id) {
      if (!tabs.delete(id)) throw new Error("No tab");
      removedTabs.push(id);
      tabsAPI.onRemoved.emit(id);
    },
    async goBack(id) {
      const tab = tabs.get(id);
      tab.url = "https://example.com/back";
      return { ...tab };
    },
    async goForward(id) {
      const tab = tabs.get(id);
      tab.url = "https://example.com/forward";
      return { ...tab };
    },
    async reload(id) {
      return tabsAPI.get(id);
    },
  };

  const snapshot = (tabId) => ({
    snapshotId: `snapshot:${tabId}`,
    title: "Example",
    url: tabs.get(tabId)?.url || "https://example.com/",
    loading: false,
    visibleText: snapshotText,
    scrollX: 0,
    scrollY: 0,
    viewportWidth: 1280,
    viewportHeight: 720,
    elements: [
      {
        id: "e1",
        role: "button",
        name: "Continue",
        tag: "button",
        type: null,
        value: null,
        href: null,
        disabled: false,
        editable: false,
        inViewport: true,
        options: null,
      },
    ],
  });

  const sandbox = {
    URL,
    WebSocket: MockWebSocket,
    TextEncoder,
    btoa: (value) => Buffer.from(value, "binary").toString("base64"),
    crypto: webcrypto,
    setInterval: () => 1,
    clearInterval() {},
    setTimeout(callback, milliseconds) {
      if (milliseconds < 1_000) queueMicrotask(callback);
      return 1;
    },
    clearTimeout() {},
    chrome: {
      runtime,
      storage: {
        onChanged: eventHook(),
        local: {
          get: async () => ({ ...storage }),
          set: async (values) => Object.assign(storage, values),
        },
      },
      permissions: {
        onAdded: eventHook(),
        onRemoved: eventHook(),
        contains: async () => websiteAccess,
      },
      tabs: tabsAPI,
      windows: { update: async () => undefined },
      scripting: {
        async executeScript(details) {
          if (details.files) return [{ result: null }];
          const command = details.args[0];
          if (
            command.expectedUrl !== undefined &&
            new URL(command.expectedUrl).href !== new URL(tabs.get(details.target.tabId).url).href
          ) {
            return [{
              result: {
                ok: false,
                code: "stale_tab",
                message: "The Chrome tab changed after Orchard observed it.",
              },
            }];
          }
          if (command.action === "page.inspect") {
            if (inspectionFails) {
              return [{
                result: {
                  ok: false,
                  code: "inspection_failed",
                  message: "The test page could not be inspected.",
                },
              }];
            }
            return [{ result: { ok: true, outcome: "Inspected", snapshot: snapshot(details.target.tabId) } }];
          }
          if (pageActionFails) {
            return [{
              result: {
                ok: false,
                code: "page_action_denied",
                message: "The page rejected the requested action.",
              },
            }];
          }
          pageActionCompleted = true;
          return [{ result: { ok: true, outcome: `Completed ${command.action}.` } }];
        },
      },
    },
  };

  vm.createContext(sandbox);
  vm.runInContext(read("service-worker.js"), sandbox, { filename: "service-worker.js" });
  return { context: sandbox, sockets, removedTabs, tabUpdates, tabs };
}

function makePageAgentHarness({ largePage = false, viewportOverflow = false } = {}) {
  class MockEvent {
    constructor(type, options = {}) {
      this.type = type;
      Object.assign(this, options);
    }
  }

  class MockElement {
    constructor(tagName, attributes = {}) {
      this.tagName = tagName.toUpperCase();
      this.attributes = { ...attributes };
      this.type = attributes.type || "";
      this.value = attributes.value || "";
      this.innerText = attributes.text || "";
      this.textContent = attributes.text || "";
      this.href = attributes.href || "";
      this.disabled = Boolean(attributes.disabled);
      this.readOnly = Boolean(attributes.readOnly);
      this.checked = Boolean(attributes.checked);
      this.isContentEditable = Boolean(attributes.contenteditable);
      this.isConnected = true;
      this.labels = attributes.label ? [{ innerText: attributes.label }] : [];
      this.options = attributes.options || [];
      this.clicked = false;
      this.events = [];
    }

    getAttribute(name) {
      if (name === "type") return this.type || null;
      if (name === "href") return this.href || null;
      if (name === "contenteditable") return this.isContentEditable ? "true" : null;
      return this.attributes[name] ?? null;
    }

    getBoundingClientRect() {
      const top = Number(this.attributes.top ?? 20);
      const left = Number(this.attributes.left ?? 20);
      return { width: 120, height: 32, top, left, right: left + 120, bottom: top + 32 };
    }

    focus() {}
    click() {
      this.clicked = true;
    }
    dispatchEvent(event) {
      this.events.push(event.type);
      return true;
    }
    closest() {
      return null;
    }
  }

  const button = new MockElement("button", { text: "Continue" });
  const input = new MockElement("input", { type: "text", value: "Old", label: "Name" });
  const password = new MockElement("input", { type: "password", value: "secret", label: "Password" });
  const file = new MockElement("input", { type: "file", value: "/tmp/private", label: "Upload" });
  const select = new MockElement("select", {
    label: "Country",
    value: "ca",
    options: [
      { value: "ca", label: "Canada", textContent: "Canada", selected: true, disabled: false },
      { value: " us ", label: "United States", textContent: "United States", selected: false, disabled: false },
    ],
  });
  const largeOptions = Array.from({ length: 25 }, (_, index) => ({
    value: `value-${index}-${"v".repeat(480)}`,
    label: `Option ${index} ${"n".repeat(280)}`,
    textContent: `Option ${index}`,
    selected: index === 0,
    disabled: false,
  }));
  const largeElements = Array.from(
    { length: 60 },
    (_, index) => new MockElement("select", {
      label: `Large select ${index}`,
      value: largeOptions[0].value,
      options: largeOptions,
    }),
  );
  const overflowElements = [
    ...Array.from(
      { length: 60 },
      (_, index) => new MockElement("button", {
        text: `Offscreen ${index}`,
        top: 2_000 + index * 40,
      }),
    ),
    new MockElement("button", { text: "Visible priority", top: 20 }),
  ];
  const elements = largePage
    ? largeElements
    : viewportOverflow
      ? overflowElements
      : [button, input, password, file, select];
  const windowObject = {
    innerWidth: 1280,
    innerHeight: 720,
    scrollX: 0,
    scrollY: 0,
    scrollBy(x, y) {
      this.scrollX += x;
      this.scrollY += y;
    },
  };
  const document = {
    documentElement: {},
    title: "Test page",
    readyState: "complete",
    body: { innerText: "Visible content" },
    querySelectorAll: () => elements,
    getElementById: () => null,
  };
  const sandbox = {
    URL,
    Uint8Array,
    TextEncoder,
    crypto: webcrypto,
    Element: MockElement,
    Event: MockEvent,
    KeyboardEvent: MockEvent,
    document,
    location: { href: "https://example.com/form" },
    window: windowObject,
    getComputedStyle: () => ({ display: "block", visibility: "visible", opacity: "1" }),
  };
  vm.createContext(sandbox);
  vm.runInContext(read("page-agent.js"), sandbox, { filename: "page-agent.js" });
  return {
    agent: sandbox.__orchardBrowserControlAgentV2,
    button,
    input,
    password,
    file,
    select,
    windowObject,
    document,
    location: sandbox.location,
  };
}

function authenticationProof(token, role, clientNonce, serverNonce) {
  return createHmac("sha256", token)
    .update(`orchard-browser-bridge:v2:${role}:${clientNonce}:${serverNonce}`)
    .digest("base64url");
}

test("manifest is protocol-v2 browser control with explicit optional website access", () => {
  const manifest = JSON.parse(read("manifest.json"));

  assert.equal(manifest.manifest_version, 3);
  assert.equal(manifest.minimum_chrome_version, "116");
  assert.equal(manifest.name, "Orchard Browser Control");
  assert.deepEqual(manifest.permissions.sort(), ["scripting", "storage"]);
  assert.deepEqual(manifest.host_permissions, ["http://127.0.0.1/*"]);
  assert.deepEqual(manifest.optional_host_permissions.sort(), ["http://*/*", "https://*/*"]);
  assert.ok(!manifest.permissions.includes("tabs"));
  assert.ok(!manifest.permissions.includes("debugger"));
  assert.ok(!manifest.permissions.includes("cookies"));
  assert.equal(manifest.incognito, "not_allowed");
  assert.equal(manifest.background.service_worker, "service-worker.js");
});

test("all bundled JavaScript parses and popup exposes website-access controls", () => {
  for (const filename of ["service-worker.js", "page-agent.js", "popup.js"]) {
    assert.doesNotThrow(() => new vm.Script(read(filename), { filename }));
  }

  const popup = read("popup.html");
  const popupScript = read("popup.js");
  assert.match(popup, /Orchard Browser Control/);
  assert.match(popup, /id="enable-access"/);
  assert.match(popup, /id="disable-access"/);
  assert.match(popup, /<script src="popup\.js"><\/script>/);
  assert.doesNotMatch(popup, /<script[^>]+src=["']https?:/i);
  assert.doesNotMatch(popup, /on(?:click|load|error)\s*=/i);
  assert.match(popupScript, /chrome\.permissions\.request/);
  assert.match(popupScript, /chrome\.permissions\.remove/);
  assert.match(popupScript, /fetch\(LOCAL_PERMISSION_PROBE_URL/);
});

test("worker exposes browser commands and contains no search-only protocol", () => {
  const worker = read("service-worker.js");

  assert.match(worker, /PROTOCOL_VERSION\s*=\s*2/);
  assert.match(worker, /orchard-browser-bridge:v2/);
  assert.match(worker, /case\s+"browser\.command"/);
  assert.match(worker, /case\s+"browser\.cancel"/);
  assert.match(worker, /type:\s*"browser\.response"/);
  for (const capability of [
    "page.inspect",
    "page.navigate",
    "page.click",
    "page.type",
    "page.select",
    "page.scroll",
    "tabs.list",
    "tabs.activate",
    "tabs.close",
  ]) {
    assert.match(worker, new RegExp(capability.replace(".", "\\.")));
  }
  assert.doesNotMatch(worker, /search\.request|search\.response|searchGoogle|extractGooglePage/);
  assert.match(worker, /Only complete HTTP or HTTPS URLs/);
});

test("mutual protocol-v2 handshake proves both peers and advertises capabilities", async () => {
  const { context, sockets } = makeWorkerHarness();
  await context.initialize();

  await context.handlePopupMessage({ type: "connection.connect", token: "test-token" });
  sockets[0].emit("open");
  const hello = sockets[0].sent[0];
  assert.equal(hello.version, 2);
  assert.equal(hello.type, "hello");
  assert.ok(hello.capabilities.includes("page.inspect"));
  assert.ok(hello.capabilities.includes("page.click"));
  assert.equal(Object.hasOwn(hello, "token"), false);

  const serverNonce = context.makeAuthenticationNonce();
  const challenge = JSON.stringify({
    version: 2,
    type: "hello.challenge",
    serverNonce,
    proof: authenticationProof("test-token", "server", hello.clientNonce, serverNonce),
  });
  await context.handleSocketMessage(challenge);

  const authentication = sockets[0].sent[1];
  assert.equal(authentication.type, "hello.authenticate");
  assert.equal(
    authentication.proof,
    authenticationProof("test-token", "client", hello.clientNonce, serverNonce),
  );
  assert.equal(Object.hasOwn(authentication, "token"), false);

  await context.handleSocketMessage('{"version":2,"type":"hello.ack","ok":true}');
  assert.equal(context.getStatusSnapshot().state, "connected");
});

test("handshake fails closed when Orchard cannot prove the pairing token", async () => {
  const { context, sockets } = makeWorkerHarness();
  await context.initialize();
  await context.handlePopupMessage({ type: "connection.connect", token: "test-token" });
  sockets[0].emit("open");

  await context.handleSocketMessage(
    JSON.stringify({
      version: 2,
      type: "hello.challenge",
      serverNonce: context.makeAuthenticationNonce(),
      proof: "A".repeat(43),
    }),
  );

  assert.equal(context.getStatusSnapshot().state, "rejected");
  assert.equal(context.getStatusSnapshot().enabled, false);
});

test("tab and navigation commands use only validated HTTP(S) targets", async () => {
  const { context, removedTabs, tabs } = makeWorkerHarness();
  await context.initialize();

  const listed = await context.executeBrowserCommand({ action: "tabs.list" });
  assert.equal(listed.tabs.length, 2);
  assert.equal(listed.tabs[0].id, 1);
  assert.equal(listed.tabs[1].controllable, false);

  const navigated = await context.executeBrowserCommand({
    action: "page.navigate",
    url: "https://example.org/form",
    newTab: true,
  });
  assert.equal(navigated.action, "page.navigate");
  assert.equal(navigated.page.url, "https://example.org/form");
  assert.equal(tabs.size, 3);

  await assert.rejects(
    context.executeBrowserCommand({ action: "page.navigate", url: "javascript:alert(1)" }),
    (error) => error.code === "unsafe_url",
  );
  await assert.rejects(
    context.executeBrowserCommand({
      action: "page.navigate",
      url: "https://example.com",
      javascript: "alert(1)",
    }),
    (error) => error.code === "unexpected_argument",
  );
  await assert.rejects(
    context.executeBrowserCommand({
      action: "page.navigate",
      url: "https://example.com",
      newTab: true,
      expectedUrl: null,
    }),
    (error) => error.code === "unexpected_argument",
  );

  const closed = await context.executeBrowserCommand({
    action: "tabs.close",
    tabId: 2,
    expectedUrl: "chrome://settings/",
  });
  assert.deepEqual(removedTabs, [2]);
  assert.ok(closed.tabs.every((tab) => tab.id !== 2));
});

test("tab close reports success when the post-close tab refresh fails", async () => {
  const { context, removedTabs, tabs } = makeWorkerHarness({
    tabListFailsAfterClose: true,
  });
  await context.initialize();

  const result = await context.executeBrowserCommand({
    action: "tabs.close",
    tabId: 2,
    expectedUrl: "chrome://settings/",
  });

  assert.deepEqual(removedTabs, [2]);
  assert.equal(tabs.has(2), false);
  assert.equal(result.outcome, "Closed Chrome tab 2.");
  assert.equal(result.page, null);
  assert.equal(result.tabs, null);
  assert.match(result.observationWarning, /tab was closed.*could not refresh/i);
  assert.ok(result.observationWarning.length <= 1_000);
});

test("worst-case tab listings stay below the bridge WebSocket message limit", async () => {
  const { context, tabs } = makeWorkerHarness();
  await context.initialize();

  tabs.clear();
  for (let index = 0; index < 40; index += 1) {
    tabs.set(index + 1, {
      id: index + 1,
      windowId: 10,
      active: index === 0,
      title: '"'.repeat(500),
      url: `chrome://settings/${"\ud83d\ude00".repeat(2_100)}-${index}`,
      status: "complete",
    });
  }

  const result = await context.executeBrowserCommand({ action: "tabs.list" });
  const tabBytes = new TextEncoder().encode(JSON.stringify(result.tabs)).byteLength;
  const response = {
    version: 2,
    type: "browser.response",
    id: "r".repeat(256),
    ok: true,
    result,
  };
  const responseBytes = new TextEncoder().encode(JSON.stringify(response)).byteLength;

  assert.ok(result.tabs.length > 0);
  assert.equal(result.tabs.length, 40);
  assert.ok(result.tabs.every((tab) => tab.url === ""));
  assert.equal(result.tabs[0].active, true);
  assert.ok(tabBytes <= 90_000, `tab listing used ${tabBytes} bytes`);
  assert.ok(responseBytes <= 100_000, `browser response used ${responseBytes} bytes`);
  assert.ok(responseBytes < 131_072);
});

test("tab activation returns only one large bounded observation payload", async () => {
  const { context, tabs } = makeWorkerHarness({ snapshotText: "p".repeat(88_000) });
  await context.initialize();

  tabs.clear();
  for (let index = 0; index < 40; index += 1) {
    tabs.set(index + 1, {
      id: index + 1,
      windowId: 10,
      active: index === 0,
      title: '"'.repeat(500),
      url: index === 0
        ? "https://example.com/large-page"
        : `chrome://settings/${"\ud83d\ude00".repeat(2_100)}-${index}`,
      status: "complete",
    });
  }

  const listed = await context.executeBrowserCommand({ action: "tabs.list" });
  const activated = await context.executeBrowserCommand({
    action: "tabs.activate",
    tabId: 1,
    expectedUrl: "https://example.com/large-page",
  });
  const envelope = (result) => ({
    version: 2,
    type: "browser.response",
    id: "r".repeat(256),
    ok: true,
    result,
  });
  const actualBytes = new TextEncoder().encode(JSON.stringify(envelope(activated))).byteLength;
  const unsafeCombinedBytes = new TextEncoder().encode(JSON.stringify(envelope({
    ...activated,
    tabs: listed.tabs,
  }))).byteLength;

  assert.ok(activated.page);
  assert.equal(activated.tabs, null);
  assert.ok(actualBytes < 131_072, `activation response used ${actualBytes} bytes`);
  assert.ok(
    unsafeCombinedBytes >= 131_072,
    `test fixture should expose the prior aggregate overflow, got ${unsafeCombinedBytes} bytes`,
  );
});

test("tab activation reports when the activated page cannot be observed", async () => {
  const { context } = makeWorkerHarness({ websiteAccess: false });
  await context.initialize();

  const result = await context.executeBrowserCommand({
    action: "tabs.activate",
    tabId: 1,
    expectedUrl: "https://example.com/",
  });

  assert.equal(result.outcome, "Activated Chrome tab 1.");
  assert.equal(result.page, null);
  assert.equal(result.tabs, null);
  assert.match(result.observationWarning, /activated.*website control is not enabled/i);
});

test("missing website permission fails before navigation changes a tab", async () => {
  const { context, tabs, tabUpdates } = makeWorkerHarness({ websiteAccess: false });
  await context.initialize();

  await assert.rejects(
    context.executeBrowserCommand({
      action: "page.navigate",
      tabId: 1,
      expectedUrl: "https://example.com/",
      url: "https://example.org/should-not-open",
    }),
    (error) => error.code === "website_access_required",
  );
  assert.equal(tabs.get(1).url, "https://example.com/");
  assert.deepEqual(tabUpdates, []);
});

test("existing-tab page commands require an explicit tab target", async () => {
  const { context, tabs, tabUpdates } = makeWorkerHarness();
  await context.initialize();

  for (const command of [
    { action: "page.inspect" },
    { action: "page.navigate", url: "https://example.org/untargeted" },
    { action: "page.scroll", direction: "down", amount: 100 },
    { action: "page.back" },
    { action: "page.forward" },
    { action: "page.reload" },
  ]) {
    await assert.rejects(
      context.executeBrowserCommand(command),
      (error) => error.code === "missing_tab",
    );
  }

  assert.equal(tabs.get(1).url, "https://example.com/");
  assert.deepEqual(tabUpdates, []);
});

test("navigation and history mutations report success when follow-up inspection fails", async () => {
  const { context, tabs, tabUpdates } = makeWorkerHarness({ inspectionFails: true });
  await context.initialize();

  const navigated = await context.executeBrowserCommand({
    action: "page.navigate",
    tabId: 1,
    expectedUrl: "https://example.com/",
    url: "https://example.org/mutated",
  });
  assert.equal(tabs.get(1).url, "https://example.org/mutated");
  assert.equal(tabUpdates.length, 1);
  assert.equal(navigated.outcome, "Navigated Chrome to https://example.org/mutated.");
  assert.equal(navigated.page, null);
  assert.match(navigated.observationWarning, /action succeeded.*could not inspect/i);

  for (const [action, observedURL, resultingURL] of [
    ["page.back", "https://example.org/mutated", "https://example.com/back"],
    ["page.forward", "https://example.com/back", "https://example.com/forward"],
    ["page.reload", "https://example.com/forward", "https://example.com/forward"],
  ]) {
    const result = await context.executeBrowserCommand({
      action,
      tabId: 1,
      expectedUrl: observedURL,
    });
    assert.equal(tabs.get(1).url, resultingURL);
    assert.equal(result.action, action);
    assert.equal(result.page, null);
    assert.match(result.observationWarning, /Inspect the tab again/i);
  }
});

test("page mutations report success when their follow-up inspection fails", async () => {
  const { context } = makeWorkerHarness({ inspectionFails: true });
  await context.initialize();

  for (const command of [
    {
      action: "page.click",
      tabId: 1,
      expectedUrl: "https://example.com/",
      snapshotId: "snapshot:1",
      elementId: "e1",
    },
    {
      action: "page.type",
      tabId: 1,
      expectedUrl: "https://example.com/",
      snapshotId: "snapshot:1",
      elementId: "e1",
      text: "hello",
      submit: true,
    },
    {
      action: "page.select",
      tabId: 1,
      expectedUrl: "https://example.com/",
      snapshotId: "snapshot:1",
      elementId: "e1",
      value: "option",
    },
    {
      action: "page.scroll",
      tabId: 1,
      expectedUrl: "https://example.com/",
      direction: "down",
      amount: 100,
    },
  ]) {
    const result = await context.executeBrowserCommand(command);
    assert.equal(result.action, command.action);
    assert.match(result.outcome, new RegExp(`Completed ${command.action}`));
    assert.equal(result.page, null);
    assert.equal(result.tabs, null);
    assert.match(result.observationWarning, /action succeeded.*could not inspect/i);
  }
});

test("page mutations report success when settling the resulting page fails", async () => {
  const { context } = makeWorkerHarness({ settleFailsAfterMutation: true });
  await context.initialize();

  const result = await context.executeBrowserCommand({
    action: "page.click",
    tabId: 1,
    expectedUrl: "https://example.com/",
    snapshotId: "snapshot:1",
    elementId: "e1",
  });

  assert.equal(result.action, "page.click");
  assert.equal(result.page, null);
  assert.match(result.observationWarning, /action succeeded.*could not inspect/i);
});

test("page-agent action failures remain browser command errors", async () => {
  const { context } = makeWorkerHarness({ pageActionFails: true });
  await context.initialize();

  await assert.rejects(
    context.executeBrowserCommand({
      action: "page.click",
      tabId: 1,
      expectedUrl: "https://example.com/",
      snapshotId: "snapshot:1",
      elementId: "e1",
    }),
    (error) =>
      error.code === "page_action_denied" &&
      error.message === "The page rejected the requested action.",
  );
});

test("page commands require scoped IDs and return a fresh semantic snapshot", async () => {
  const { context } = makeWorkerHarness();
  await context.initialize();

  const inspected = await context.executeBrowserCommand({
    action: "page.inspect",
    tabId: 1,
    expectedUrl: "https://example.com/",
  });
  assert.equal(inspected.page.snapshotId, "snapshot:1");
  assert.equal(inspected.page.elements[0].id, "e1");

  const clicked = await context.executeBrowserCommand({
    action: "page.click",
    tabId: 1,
    expectedUrl: "https://example.com/",
    snapshotId: "snapshot:1",
    elementId: "e1",
  });
  assert.equal(clicked.action, "page.click");
  assert.equal(clicked.page.tabId, 1);

  await assert.rejects(
    context.executeBrowserCommand({
      action: "page.click",
      tabId: 1,
      expectedUrl: "https://example.com/",
      elementId: "e1",
    }),
    (error) => error.code === "invalid_identifier",
  );
});

test("existing-tab commands reject a changed URL before reading or mutating", async () => {
  const { context, removedTabs, tabUpdates, tabs } = makeWorkerHarness();
  await context.initialize();

  for (const command of [
    {
      action: "page.inspect",
      tabId: 1,
      expectedUrl: "https://stale.example/",
    },
    {
      action: "page.click",
      tabId: 1,
      expectedUrl: "https://stale.example/",
      snapshotId: "snapshot:1",
      elementId: "e1",
    },
    {
      action: "page.navigate",
      tabId: 1,
      expectedUrl: "https://stale.example/",
      url: "https://example.org/mutated",
    },
    {
      action: "page.back",
      tabId: 1,
      expectedUrl: "https://stale.example/",
    },
    {
      action: "tabs.activate",
      tabId: 1,
      expectedUrl: "https://stale.example/",
    },
    {
      action: "tabs.close",
      tabId: 1,
      expectedUrl: "https://stale.example/",
    },
  ]) {
    await assert.rejects(
      context.executeBrowserCommand(command),
      (error) => error.code === "stale_tab",
    );
  }

  assert.equal(tabs.get(1).url, "https://example.com/");
  assert.deepEqual(tabUpdates, []);
  assert.deepEqual(removedTabs, []);
});

test("page agent binds actions to the exact current URL before touching the page", () => {
  const { agent, button, location } = makePageAgentHarness();
  const inspected = agent.run({
    action: "page.inspect",
    expectedUrl: "https://example.com/form",
  });
  assert.equal(inspected.ok, true);
  assert.equal(inspected.snapshot.url, "https://example.com/form");

  location.href = "https://example.com/other";
  const staleClick = agent.run({
    action: "page.click",
    expectedUrl: "https://example.com/form",
    snapshotId: inspected.snapshot.snapshotId,
    elementId: "e1",
  });
  assert.equal(staleClick.ok, false);
  assert.equal(staleClick.code, "stale_tab");
  assert.equal(button.clicked, false);

  location.href = `https://example.com/${"x".repeat(4_096)}`;
  const oversized = agent.run({ action: "page.inspect", expectedUrl: location.href });
  assert.equal(oversized.ok, false);
  assert.equal(oversized.code, "invalid_page_url");
});

test("page agent bounds observations, redacts sensitive values, and rejects stale IDs", () => {
  const { agent, button, input, password, file, select, windowObject, document } =
    makePageAgentHarness();
  const first = agent.run({ action: "page.inspect" });
  assert.equal(first.ok, true);
  assert.equal(first.snapshot.visibleText, "Visible content");
  assert.equal(first.snapshot.elements.length, 5);
  assert.equal(first.snapshot.elements[2].value, null);
  assert.equal(first.snapshot.elements[3].value, null);
  assert.equal(first.snapshot.elements[2].editable, false);

  const second = agent.run({ action: "page.inspect" });
  const staleClick = agent.run({
    action: "page.click",
    snapshotId: first.snapshot.snapshotId,
    elementId: "e1",
  });
  assert.equal(staleClick.code, "stale_snapshot");

  document.body.innerText = "Unrelated live-region update";
  const click = agent.run({
    action: "page.click",
    snapshotId: second.snapshot.snapshotId,
    elementId: "e1",
  });
  assert.equal(click.ok, true);
  assert.equal(button.clicked, true);

  const typed = agent.run({
    action: "page.type",
    snapshotId: second.snapshot.snapshotId,
    elementId: "e2",
    text: "New",
    clear: true,
  });
  assert.equal(typed.ok, true);
  assert.equal(input.value, "New");
  assert.deepEqual(input.events, ["input", "change"]);

  const sensitive = agent.run({
    action: "page.type",
    snapshotId: second.snapshot.snapshotId,
    elementId: "e3",
    text: "do not enter",
  });
  assert.equal(sensitive.code, "sensitive_input");
  assert.equal(password.value, "secret");
  assert.equal(file.value, "/tmp/private");

  const fileClick = agent.run({
    action: "page.click",
    snapshotId: second.snapshot.snapshotId,
    elementId: "e4",
  });
  assert.equal(fileClick.ok, false);
  assert.equal(fileClick.code, "sensitive_input");

  const selected = agent.run({
    action: "page.select",
    snapshotId: second.snapshot.snapshotId,
    elementId: "e5",
    value: "us",
  });
  assert.equal(selected.ok, true);
  assert.equal(select.value, " us ");

  const scrolled = agent.run({ action: "page.scroll", direction: "down", amount: 500 });
  assert.equal(scrolled.ok, true);
  assert.equal(windowObject.scrollY, 500);

  const changedTargetSnapshot = agent.run({ action: "page.inspect" });
  button.innerText = "Delete account";
  button.textContent = "Delete account";
  const changedTargetClick = agent.run({
    action: "page.click",
    snapshotId: changedTargetSnapshot.snapshot.snapshotId,
    elementId: "e1",
  });
  assert.equal(changedTargetClick.ok, false);
  assert.equal(changedTargetClick.code, "stale_snapshot");
});

test("page agent keeps worst-case semantic snapshots below the bridge limit", () => {
  const { agent } = makePageAgentHarness({ largePage: true });
  const result = agent.run({ action: "page.inspect" });

  assert.equal(result.ok, true);
  assert.ok(new TextEncoder().encode(JSON.stringify(result.snapshot)).byteLength <= 90_000);
  assert.ok(result.snapshot.elements.length > 0);
});

test("page snapshots prioritize viewport controls beyond the first 60 DOM elements", () => {
  const { agent } = makePageAgentHarness({ viewportOverflow: true });
  const result = agent.run({ action: "page.inspect" });

  assert.equal(result.ok, true);
  assert.equal(result.snapshot.elements.length, 60);
  assert.equal(result.snapshot.elements[0].name, "Visible priority");
  assert.equal(result.snapshot.elements[0].inViewport, true);
});
