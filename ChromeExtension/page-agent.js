"use strict";

(() => {
  const AGENT_KEY = "__orchardBrowserControlAgentV2";
  if (globalThis[AGENT_KEY]) {
    return;
  }

  const MAX_VISIBLE_TEXT_LENGTH = 18_000;
  const MAX_ELEMENTS = 60;
  const MAX_NAME_LENGTH = 300;
  const MAX_VALUE_LENGTH = 500;
  const MAX_URL_LENGTH = 4_096;
  const MAX_OPTIONS = 25;
  const MAX_SNAPSHOT_BYTES = 90_000;
  const INTERACTIVE_SELECTOR = [
    "a[href]",
    "button",
    "input:not([type='hidden'])",
    "select",
    "textarea",
    "[contenteditable='true']",
    "[role='button']",
    "[role='link']",
    "[role='checkbox']",
    "[role='radio']",
    "[role='tab']",
    "[role='menuitem']",
    "[role='option']",
    "[tabindex]:not([tabindex='-1'])",
  ].join(",");

  const documentNonce = makeNonce();
  let snapshotSequence = 0;
  let latestSnapshot = null;

  function makeNonce() {
    const bytes = new Uint8Array(16);
    crypto.getRandomValues(bytes);
    return Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
  }

  function normalizeText(value, maximumLength) {
    return String(value ?? "")
      .replace(/\u0000/g, "")
      .replace(/\s+/g, " ")
      .trim()
      .slice(0, maximumLength);
  }

  function isVisible(element) {
    if (!(element instanceof Element)) {
      return false;
    }
    const style = getComputedStyle(element);
    if (
      style.display === "none" ||
      style.visibility === "hidden" ||
      Number.parseFloat(style.opacity || "1") === 0
    ) {
      return false;
    }
    const rectangle = element.getBoundingClientRect();
    return rectangle.width > 0 && rectangle.height > 0;
  }

  function inferredRole(element) {
    const explicitRole = normalizeText(element.getAttribute("role"), 80);
    if (explicitRole) {
      return explicitRole;
    }
    const tag = element.tagName.toLowerCase();
    if (tag === "a") return "link";
    if (tag === "button") return "button";
    if (tag === "select") return "combobox";
    if (tag === "textarea") return "textbox";
    if (tag === "input") {
      const type = String(element.type || "text").toLowerCase();
      if (["button", "submit", "reset", "image"].includes(type)) return "button";
      if (type === "checkbox") return "checkbox";
      if (type === "radio") return "radio";
      if (type === "range") return "slider";
      return "textbox";
    }
    if (element.isContentEditable) return "textbox";
    return "interactive";
  }

  function accessibleName(element) {
    const labelledBy = normalizeText(element.getAttribute("aria-labelledby"), 300);
    if (labelledBy) {
      const text = labelledBy
        .split(/\s+/)
        .map((id) => document.getElementById(id))
        .filter(Boolean)
        .map((node) => node.innerText || node.textContent)
        .join(" ");
      const normalized = normalizeText(text, MAX_NAME_LENGTH);
      if (normalized) return normalized;
    }

    const candidates = [
      element.getAttribute("aria-label"),
      element.labels?.[0]?.innerText,
      element.getAttribute("alt"),
      element.getAttribute("placeholder"),
      element.getAttribute("title"),
      ["button", "submit", "reset"].includes(String(element.type || "").toLowerCase())
        ? element.value
        : "",
      element.innerText,
      element.textContent,
    ];
    for (const candidate of candidates) {
      const normalized = normalizeText(candidate, MAX_NAME_LENGTH);
      if (normalized) return normalized;
    }
    return "";
  }

  function safeHref(element) {
    if (!element.href) {
      return null;
    }
    try {
      const url = new URL(element.href, location.href);
      if (!/^https?:$/.test(url.protocol) || url.username || url.password) {
        return null;
      }
      return url.href.length <= MAX_URL_LENGTH ? url.href : null;
    } catch {
      return null;
    }
  }

  function isEditable(element) {
    if (element.isContentEditable) {
      return true;
    }
    const tag = element.tagName.toLowerCase();
    if (tag === "textarea" || tag === "select") {
      return !element.disabled && !element.readOnly;
    }
    if (tag !== "input") {
      return false;
    }
    const type = String(element.type || "text").toLowerCase();
    return ![
      "button",
      "checkbox",
      "file",
      "hidden",
      "image",
      "password",
      "radio",
      "reset",
      "submit",
    ].includes(type) && !element.disabled && !element.readOnly;
  }

  function exposedValue(element) {
    const tag = element.tagName.toLowerCase();
    const type = String(element.type || "").toLowerCase();
    if (type === "password" || type === "file") {
      return null;
    }
    if (type === "checkbox" || type === "radio") {
      return element.checked ? "checked" : "not checked";
    }
    if (tag === "input" || tag === "textarea" || tag === "select") {
      return normalizeText(element.value, MAX_VALUE_LENGTH);
    }
    if (element.isContentEditable) {
      return normalizeText(element.innerText || element.textContent, MAX_VALUE_LENGTH);
    }
    return null;
  }

  function optionSummaries(element) {
    if (element.tagName.toLowerCase() !== "select") {
      return null;
    }
    return Array.from(element.options || [])
      .slice(0, MAX_OPTIONS)
      .map((option) => ({
        value: normalizeText(option.value, MAX_VALUE_LENGTH),
        label: normalizeText(option.label || option.textContent, MAX_NAME_LENGTH),
        selected: Boolean(option.selected),
        disabled: Boolean(option.disabled),
      }));
  }

  function isInViewport(rectangle) {
    return (
      rectangle.bottom > 0 &&
      rectangle.right > 0 &&
      rectangle.top < window.innerHeight &&
      rectangle.left < window.innerWidth
    );
  }

  function distanceFromViewport(rectangle) {
    const vertical = rectangle.bottom < 0
      ? -rectangle.bottom
      : rectangle.top > window.innerHeight
        ? rectangle.top - window.innerHeight
        : 0;
    const horizontal = rectangle.right < 0
      ? -rectangle.right
      : rectangle.left > window.innerWidth
        ? rectangle.left - window.innerWidth
        : 0;
    return vertical + horizontal;
  }

  function elementFingerprint(element) {
    return JSON.stringify({
      tag: element.tagName.toLowerCase(),
      role: inferredRole(element),
      name: accessibleName(element),
      type: normalizeText(element.getAttribute("type"), 80),
      value: exposedValue(element),
      href: safeHref(element),
      editable: isEditable(element),
      options: optionSummaries(element),
    });
  }

  function snapshotByteLength(snapshot) {
    return new TextEncoder().encode(JSON.stringify(snapshot)).byteLength;
  }

  function boundSnapshot(snapshot, elementMap) {
    if (snapshotByteLength(snapshot) <= MAX_SNAPSHOT_BYTES) {
      return snapshot;
    }

    snapshot.visibleText = snapshot.visibleText.slice(0, 8_000);
    for (let index = snapshot.elements.length - 1; index >= 0; index -= 1) {
      const element = snapshot.elements[index];
      if (Array.isArray(element.options) && element.options.length > 5) {
        element.options = element.options.slice(0, 5);
      }
    }

    for (let index = snapshot.elements.length - 1; index >= 0; index -= 1) {
      if (snapshotByteLength(snapshot) <= MAX_SNAPSHOT_BYTES) {
        break;
      }
      snapshot.elements[index].options = null;
    }

    while (
      snapshot.elements.length > 1 &&
      snapshotByteLength(snapshot) > MAX_SNAPSHOT_BYTES
    ) {
      const removed = snapshot.elements.pop();
      elementMap.delete(removed.id);
    }

    if (snapshotByteLength(snapshot) > MAX_SNAPSHOT_BYTES) {
      snapshot.visibleText = snapshot.visibleText.slice(0, 2_000);
      const element = snapshot.elements[0];
      if (element) {
        element.name = element.name.slice(0, 160);
        element.value = element.value?.slice(0, 160) ?? null;
        element.href = element.href?.slice(0, 512) ?? null;
        element.options = null;
      }
    }

    return snapshot;
  }

  function normalizedPageURL(rawValue) {
    if (
      typeof rawValue !== "string" ||
      rawValue.length === 0 ||
      rawValue.length > MAX_URL_LENGTH
    ) {
      return null;
    }
    try {
      const url = new URL(rawValue);
      if (!/^https?:$/.test(url.protocol) || url.username || url.password) {
        return null;
      }
      return url.href.length <= MAX_URL_LENGTH ? url.href : null;
    } catch {
      return null;
    }
  }

  function validatePageLocation(expectedURL) {
    const currentURL = normalizedPageURL(location.href);
    if (!currentURL) {
      return {
        ok: false,
        code: "invalid_page_url",
        message: "The page URL is unavailable, restricted, or too long to bind safely.",
      };
    }
    if (expectedURL !== undefined) {
      const normalizedExpectedURL = normalizedPageURL(expectedURL);
      if (!normalizedExpectedURL) {
        return {
          ok: false,
          code: "invalid_expected_url",
          message: "The expected Chrome tab URL is missing or invalid.",
        };
      }
      if (currentURL !== normalizedExpectedURL) {
        return {
          ok: false,
          code: "stale_tab",
          message: "The Chrome tab changed after Orchard observed it. Inspect the tab again.",
        };
      }
    }
    return { ok: true, url: currentURL };
  }

  function createSnapshot(pageURL) {
    const elementMap = new Map();
    const elements = [];
    const candidates = Array.from(document.querySelectorAll(INTERACTIVE_SELECTOR))
      .filter(isVisible)
      .map((element, index) => {
        const rectangle = element.getBoundingClientRect();
        return {
          element,
          index,
          rectangle,
          distance: distanceFromViewport(rectangle),
        };
      })
      .sort((left, right) =>
        left.distance - right.distance ||
        left.rectangle.top - right.rectangle.top ||
        left.rectangle.left - right.rectangle.left ||
        left.index - right.index,
      );

    for (const candidate of candidates) {
      if (elements.length >= MAX_ELEMENTS) {
        break;
      }
      const { element, rectangle } = candidate;
      const id = `e${elements.length + 1}`;
      const type = normalizeText(element.getAttribute("type"), 80) || null;
      const disabled =
        Boolean(element.disabled) ||
        element.getAttribute("aria-disabled")?.toLowerCase() === "true";
      elementMap.set(id, {
        element,
        fingerprint: elementFingerprint(element),
      });
      elements.push({
        id,
        role: inferredRole(element),
        name: accessibleName(element),
        tag: element.tagName.toLowerCase().slice(0, 40),
        type,
        value: exposedValue(element),
        href: safeHref(element),
        disabled,
        editable: isEditable(element),
        inViewport: isInViewport(rectangle),
        options: optionSummaries(element),
      });
    }

    const snapshotId = `${documentNonce}:${++snapshotSequence}`;
    const snapshot = boundSnapshot({
      snapshotId,
      title: normalizeText(document.title, 500),
      url: pageURL,
      loading: document.readyState !== "complete",
      visibleText: normalizeText(document.body?.innerText, MAX_VISIBLE_TEXT_LENGTH),
      scrollX: Math.trunc(window.scrollX || 0),
      scrollY: Math.trunc(window.scrollY || 0),
      viewportWidth: Math.max(0, Math.trunc(window.innerWidth || 0)),
      viewportHeight: Math.max(0, Math.trunc(window.innerHeight || 0)),
      elements,
    }, elementMap);

    latestSnapshot = {
      id: snapshotId,
      elements: elementMap,
    };
    return snapshot;
  }

  function resolveElement(command) {
    if (
      !latestSnapshot ||
      command.snapshotId !== latestSnapshot.id
    ) {
      return {
        ok: false,
        code: "stale_snapshot",
        message: "The page changed after it was inspected. Inspect the tab again.",
      };
    }
    const record = latestSnapshot.elements.get(command.elementId);
    const element = record?.element;
    if (!element || !element.isConnected) {
      return {
        ok: false,
        code: "element_not_found",
        message: "That element is no longer available. Inspect the tab again.",
      };
    }
    if (!isVisible(element)) {
      return {
        ok: false,
        code: "element_unavailable",
        message: "That element is not currently visible. Inspect or scroll the tab again.",
      };
    }
    if (record.fingerprint !== elementFingerprint(element)) {
      return {
        ok: false,
        code: "stale_snapshot",
        message: "That control changed after it was inspected. Inspect the tab again.",
      };
    }
    if (element.disabled || element.getAttribute("aria-disabled")?.toLowerCase() === "true") {
      return {
        ok: false,
        code: "element_disabled",
        message: "That element is disabled.",
      };
    }
    return { ok: true, element };
  }

  function setNativeValue(element, value) {
    const prototype = Object.getPrototypeOf(element);
    const descriptor = Object.getOwnPropertyDescriptor(prototype, "value");
    if (descriptor?.set) {
      descriptor.set.call(element, value);
    } else {
      element.value = value;
    }
  }

  function dispatchInputEvents(element) {
    element.dispatchEvent(new Event("input", { bubbles: true, composed: true }));
    element.dispatchEvent(new Event("change", { bubbles: true, composed: true }));
  }

  function run(command) {
    if (!command || typeof command !== "object" || Array.isArray(command)) {
      return { ok: false, code: "invalid_command", message: "Invalid page command." };
    }

    const locationValidation = validatePageLocation(command.expectedUrl);
    if (!locationValidation.ok) {
      return locationValidation;
    }

    if (command.action === "page.inspect") {
      return {
        ok: true,
        snapshot: createSnapshot(locationValidation.url),
        outcome: "Inspected the page.",
      };
    }

    if (command.action === "page.scroll") {
      const amount = Math.max(1, Math.min(5_000, Math.trunc(Number(command.amount) || 700)));
      const offsets = {
        up: [0, -amount],
        down: [0, amount],
        left: [-amount, 0],
        right: [amount, 0],
      };
      const offset = offsets[command.direction];
      if (!offset) {
        return { ok: false, code: "invalid_direction", message: "Invalid scroll direction." };
      }
      window.scrollBy(offset[0], offset[1]);
      return { ok: true, outcome: `Scrolled ${command.direction}.` };
    }

    const resolved = resolveElement(command);
    if (!resolved.ok) {
      return resolved;
    }
    const element = resolved.element;

    if (command.action === "page.click") {
      const type = String(element.type || "").toLowerCase();
      if (type === "password" || type === "file") {
        return {
          ok: false,
          code: "sensitive_input",
          message: "Orchard does not interact with password or file inputs.",
        };
      }
      element.focus?.({ preventScroll: true });
      element.click();
      return { ok: true, outcome: "Clicked the requested element." };
    }

    if (command.action === "page.type") {
      const tag = element.tagName.toLowerCase();
      const type = String(element.type || "").toLowerCase();
      if (type === "password" || type === "file") {
        return {
          ok: false,
          code: "sensitive_input",
          message: "Orchard does not type into password or file inputs.",
        };
      }
      if (!isEditable(element) || tag === "select") {
        return {
          ok: false,
          code: "element_not_editable",
          message: "That element does not accept text input.",
        };
      }
      const suppliedText = String(command.text ?? "").slice(0, 20_000);
      const existingText = element.isContentEditable
        ? element.textContent || ""
        : String(element.value || "");
      const nextText = command.clear === false ? existingText + suppliedText : suppliedText;
      element.focus?.({ preventScroll: true });
      if (element.isContentEditable) {
        element.textContent = nextText;
      } else {
        setNativeValue(element, nextText);
      }
      dispatchInputEvents(element);

      if (command.submit === true) {
        const form = element.closest("form");
        if (form?.requestSubmit) {
          form.requestSubmit();
        } else {
          for (const typeName of ["keydown", "keypress", "keyup"]) {
            element.dispatchEvent(
              new KeyboardEvent(typeName, {
                key: "Enter",
                code: "Enter",
                bubbles: true,
                composed: true,
              }),
            );
          }
        }
      }
      return {
        ok: true,
        outcome: command.submit === true ? "Entered text and submitted the form." : "Entered text.",
      };
    }

    if (command.action === "page.select") {
      if (element.tagName.toLowerCase() !== "select") {
        return {
          ok: false,
          code: "element_not_select",
          message: "That element is not a select control.",
        };
      }
      const requestedValue = normalizeText(command.value, MAX_VALUE_LENGTH);
      const option = Array.from(element.options || []).find(
        (candidate) => normalizeText(candidate.value, MAX_VALUE_LENGTH) === requestedValue,
      );
      if (!option || option.disabled) {
        return {
          ok: false,
          code: "option_not_found",
          message: "That option is not available. Inspect the page again.",
        };
      }
      setNativeValue(element, option.value);
      dispatchInputEvents(element);
      return { ok: true, outcome: "Selected the requested option." };
    }

    return { ok: false, code: "unsupported_action", message: "Unsupported page action." };
  }

  globalThis[AGENT_KEY] = Object.freeze({ run });
})();
