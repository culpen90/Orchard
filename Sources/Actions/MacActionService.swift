import AppKit
import CoreFoundation
import Foundation

enum MacActionKind: Equatable, Sendable {
    case openApplication(url: URL, name: String)
    case openURL(URL)
    case controlBrowser(BrowserCommand)
    case copyToClipboard(String)
}

struct ActionProposal: Identifiable, Equatable, Sendable {
    let id: UUID
    let toolCallID: String
    let title: String
    let detail: String
    let confirmationTitle: String
    let symbolName: String
    let kind: MacActionKind
    let browserConnectionGeneration: UInt64?

    init(
        toolCallID: String,
        title: String,
        detail: String,
        confirmationTitle: String,
        symbolName: String,
        kind: MacActionKind,
        browserConnectionGeneration: UInt64? = nil
    ) {
        id = UUID()
        self.toolCallID = toolCallID
        self.title = title
        self.detail = detail
        self.confirmationTitle = confirmationTitle
        self.symbolName = symbolName
        self.kind = kind
        self.browserConnectionGeneration = browserConnectionGeneration
    }
}

struct MacActionResult: Equatable, Sendable {
    let toolMessage: String
    let activityDescription: String
}

private struct BrowserElementApprovalContext {
    let element: BrowserPageElement
    let expectedURL: String
    let targetLabel: String
    let detail: String
}

private struct BrowserTabApprovalContext {
    let expectedURL: String
    let targetLabel: String
    let detail: String
}

@MainActor
protocol MacActionServicing: AnyObject {
    var toolDefinitions: [OpenRouterToolDefinition] { get }
    func prepare(toolCall: OpenRouterToolCall) throws -> ActionProposal
    func execute(_ proposal: ActionProposal) async throws -> MacActionResult
}

@MainActor
final class MacActionService: MacActionServicing {
    private let browserControl: any BrowserControlling
    private var latestBrowserPages: [Int: BrowserPageSnapshot] = [:]
    private var latestBrowserTabs: [Int: BrowserTabSummary] = [:]
    private var cachedBrowserConnectionGeneration: UInt64?

    let toolDefinitions: [OpenRouterToolDefinition] = [
        OpenRouterToolDefinition(
            function: OpenRouterFunctionDefinition(
                name: "open_application",
                description: "Open a macOS application that Launch Services can find, regardless of where it is installed.",
                parameters: OpenRouterToolParameters(
                    properties: [
                        "name": .string("The human-readable application name, not a file path, such as Safari."),
                        "bundle_id": .string("The macOS bundle identifier when known, such as com.apple.Safari.")
                    ],
                    required: ["name"]
                )
            )
        ),
        OpenRouterToolDefinition(
            function: OpenRouterFunctionDefinition(
                name: "open_url",
                description: "Open a specific secure HTTPS web page in the user's default browser.",
                parameters: OpenRouterToolParameters(
                    properties: [
                        "url": .string("A complete HTTPS URL.")
                    ],
                    required: ["url"]
                )
            )
        ),
        OpenRouterToolDefinition(
            function: OpenRouterFunctionDefinition(
                name: "browser_inspect",
                description: "Inspect an observed controllable Chrome tab and return its current URL, visible text, and fresh interactive element IDs. List tabs first, then pass the exact tab ID. Always inspect before clicking, typing, or selecting; element IDs are snapshot-scoped and expire when the page changes.",
                parameters: OpenRouterToolParameters(
                    properties: [
                        "tab_id": .integer("Observed Chrome tab ID from a prior tab list.", minimum: 0)
                    ],
                    required: ["tab_id"]
                )
            )
        ),
        OpenRouterToolDefinition(
            function: OpenRouterFunctionDefinition(
                name: "browser_navigate",
                description: "Navigate a Chrome tab directly to a complete HTTP or HTTPS URL. This controls Chrome; it is not a web-search shortcut. Inspect the returned page before interacting.",
                parameters: OpenRouterToolParameters(
                    properties: [
                        "url": .string("Complete HTTP or HTTPS URL without embedded credentials."),
                        "tab_id": .integer("Observed Chrome tab ID. Required unless new_tab is true; list or inspect tabs first.", minimum: 0),
                        "new_tab": .boolean("Open the URL in a new active tab instead of reusing a tab.")
                    ],
                    required: ["url"]
                )
            )
        ),
        OpenRouterToolDefinition(
            function: OpenRouterFunctionDefinition(
                name: "browser_click",
                description: "Click one interactive element from the latest browser result. Pass the exact tab, snapshot, and element IDs; inspect again if the snapshot is stale.",
                parameters: OpenRouterToolParameters(
                    properties: [
                        "tab_id": .integer("Chrome tab ID from the latest snapshot.", minimum: 0),
                        "snapshot_id": .string("Snapshot ID from the latest inspection."),
                        "element_id": .string("Opaque element ID from the latest inspection.")
                    ],
                    required: ["tab_id", "snapshot_id", "element_id"]
                )
            )
        ),
        OpenRouterToolDefinition(
            function: OpenRouterFunctionDefinition(
                name: "browser_type",
                description: "Type text into an editable element from the latest browser result, optionally submitting its form. Password and file inputs are never allowed.",
                parameters: OpenRouterToolParameters(
                    properties: [
                        "tab_id": .integer("Chrome tab ID from the latest snapshot.", minimum: 0),
                        "snapshot_id": .string("Snapshot ID from the latest inspection."),
                        "element_id": .string("Opaque editable element ID from the latest inspection."),
                        "text": .string("Text to enter, up to 20000 characters."),
                        "clear": .boolean("Replace existing text when true; append when false. Defaults to true."),
                        "submit": .boolean("Submit the containing form after typing. Defaults to false.")
                    ],
                    required: ["tab_id", "snapshot_id", "element_id", "text"]
                )
            )
        ),
        OpenRouterToolDefinition(
            function: OpenRouterFunctionDefinition(
                name: "browser_select",
                description: "Choose an option in a select control from the latest browser result. Use an option value returned in that snapshot.",
                parameters: OpenRouterToolParameters(
                    properties: [
                        "tab_id": .integer("Chrome tab ID from the latest snapshot.", minimum: 0),
                        "snapshot_id": .string("Snapshot ID from the latest inspection."),
                        "element_id": .string("Opaque select element ID from the latest inspection."),
                        "value": .string("Exact option value returned in the element's options list.")
                    ],
                    required: ["tab_id", "snapshot_id", "element_id", "value"]
                )
            )
        ),
        OpenRouterToolDefinition(
            function: OpenRouterFunctionDefinition(
                name: "browser_scroll",
                description: "Scroll a Chrome page, then return a fresh page snapshot.",
                parameters: OpenRouterToolParameters(
                    properties: [
                        "tab_id": .integer("Observed Chrome tab ID from a prior list or inspection.", minimum: 0),
                        "direction": .string(
                            "Scroll direction.",
                            allowedValues: ["up", "down", "left", "right"]
                        ),
                        "amount": .integer("Distance in CSS pixels, from 1 through 5000. Defaults to 700.", minimum: 1, maximum: 5_000)
                    ],
                    required: ["tab_id", "direction"]
                )
            )
        ),
        OpenRouterToolDefinition(
            function: OpenRouterFunctionDefinition(
                name: "browser_history",
                description: "Move a Chrome tab backward or forward in history, or reload it, then inspect the resulting page.",
                parameters: OpenRouterToolParameters(
                    properties: [
                        "action": .string(
                            "History action.",
                            allowedValues: ["back", "forward", "reload"]
                        ),
                        "tab_id": .integer("Observed Chrome tab ID from a prior list or inspection.", minimum: 0)
                    ],
                    required: ["action", "tab_id"]
                )
            )
        ),
        OpenRouterToolDefinition(
            function: OpenRouterFunctionDefinition(
                name: "browser_tabs",
                description: "List Chrome tabs, activate a tab, or close a tab. You must use list first; activate and close only accept a tab ID from the latest observed list.",
                parameters: OpenRouterToolParameters(
                    properties: [
                        "action": .string(
                            "Tab action.",
                            allowedValues: ["list", "activate", "close"]
                        ),
                        "tab_id": .integer("Required for activate or close.", minimum: 0)
                    ],
                    required: ["action"]
                )
            )
        ),
        OpenRouterToolDefinition(
            function: OpenRouterFunctionDefinition(
                name: "copy_to_clipboard",
                description: "Copy useful text to the macOS clipboard when the user asks for it.",
                parameters: OpenRouterToolParameters(
                    properties: [
                        "text": .string("The exact text to copy.")
                    ],
                    required: ["text"]
                )
            )
        )
    ]

    init(browserControl: any BrowserControlling = BrowserBridgeService.shared) {
        self.browserControl = browserControl
    }

    func prepare(toolCall: OpenRouterToolCall) throws -> ActionProposal {
        synchronizeBrowserCacheGeneration()
        let arguments = try decodeArguments(toolCall.function.arguments)

        switch toolCall.function.name {
        case "open_application":
            try requireOnly(arguments, keys: ["name", "bundle_id"])
            let name = try requiredString("name", in: arguments, maximumLength: 160)
            let bundleID = optionalString("bundle_id", in: arguments, maximumLength: 255)
            let appURL = try resolveApplication(name: name, bundleID: bundleID)
            return ActionProposal(
                toolCallID: toolCall.id,
                title: "Open \(name)?",
                detail: appURL.path,
                confirmationTitle: "Open App",
                symbolName: "app.dashed",
                kind: .openApplication(url: appURL, name: name)
            )

        case "open_url":
            try requireOnly(arguments, keys: ["url"])
            let rawURL = try requiredString("url", in: arguments, maximumLength: 4_096)
            guard
                let components = URLComponents(string: rawURL),
                components.scheme?.lowercased() == "https",
                let host = components.host,
                !host.isEmpty,
                components.user == nil,
                components.password == nil,
                let url = components.url
            else {
                throw MacActionError.invalidURL
            }
            return ActionProposal(
                toolCallID: toolCall.id,
                title: "Open this website?",
                detail: url.absoluteString,
                confirmationTitle: "Open Website",
                symbolName: "safari",
                kind: .openURL(url)
            )

        case "browser_inspect":
            try requireOnly(arguments, keys: ["tab_id"])
            let tabID = try requiredInteger("tab_id", in: arguments, minimum: 0)
            let tabContext = try browserTabApprovalContext(
                tabID: tabID,
                requireListedTab: false
            )
            return browserProposal(
                toolCallID: toolCall.id,
                title: "Read \(tabContext.targetLabel) in Chrome?",
                detail: tabContext.detail,
                confirmationTitle: "Inspect Tab",
                symbolName: "safari",
                command: BrowserCommand(
                    action: .inspect,
                    tabID: tabID,
                    expectedURL: tabContext.expectedURL
                )
            )

        case "browser_navigate":
            try requireOnly(arguments, keys: ["url", "tab_id", "new_tab"])
            let rawURL = try requiredString("url", in: arguments, maximumLength: 4_096)
            let url = try validatedBrowserURL(rawURL)
            let tabID = try optionalInteger("tab_id", in: arguments, minimum: 0)
            let newTab = try optionalBoolean("new_tab", in: arguments) ?? false
            guard !newTab || tabID == nil else {
                throw MacActionError.invalidArguments
            }
            if newTab {
                return browserProposal(
                    toolCallID: toolCall.id,
                    title: "Open this page in a new Chrome tab?",
                    detail: url.absoluteString,
                    confirmationTitle: "Navigate",
                    symbolName: "arrow.right.circle",
                    command: BrowserCommand(
                        action: .navigate,
                        url: url.absoluteString,
                        newTab: true
                    )
                )
            }
            guard let tabID else {
                throw MacActionError.missingArgument("tab_id")
            }
            let tabContext = try browserTabApprovalContext(
                tabID: tabID,
                requireListedTab: false
            )
            return browserProposal(
                toolCallID: toolCall.id,
                title: "Navigate \(tabContext.targetLabel) in Chrome?",
                detail: "\(tabContext.detail)\nDestination: \(url.absoluteString)",
                confirmationTitle: "Navigate",
                symbolName: "arrow.right.circle",
                command: BrowserCommand(
                    action: .navigate,
                    tabID: tabID,
                    expectedURL: tabContext.expectedURL,
                    url: url.absoluteString,
                    newTab: false
                )
            )

        case "browser_click":
            try requireOnly(arguments, keys: ["tab_id", "snapshot_id", "element_id"])
            let tabID = try requiredInteger("tab_id", in: arguments, minimum: 0)
            let snapshotID = try browserIdentifier("snapshot_id", in: arguments, maximumLength: 128)
            let elementID = try browserIdentifier("element_id", in: arguments, maximumLength: 64)
            let context = try browserApprovalContext(
                tabID: tabID,
                snapshotID: snapshotID,
                elementID: elementID
            )
            return browserProposal(
                toolCallID: toolCall.id,
                title: "Click \(context.targetLabel) in Chrome?",
                detail: context.detail,
                confirmationTitle: "Click",
                symbolName: "cursorarrow.click",
                command: BrowserCommand(
                    action: .click,
                    tabID: tabID,
                    expectedURL: context.expectedURL,
                    snapshotID: snapshotID,
                    elementID: elementID
                )
            )

        case "browser_type":
            try requireOnly(
                arguments,
                keys: ["tab_id", "snapshot_id", "element_id", "text", "clear", "submit"]
            )
            let tabID = try requiredInteger("tab_id", in: arguments, minimum: 0)
            let snapshotID = try browserIdentifier("snapshot_id", in: arguments, maximumLength: 128)
            let elementID = try browserIdentifier("element_id", in: arguments, maximumLength: 64)
            let text = try requiredText("text", in: arguments, maximumLength: 20_000)
            let clear = try optionalBoolean("clear", in: arguments) ?? true
            let submit = try optionalBoolean("submit", in: arguments) ?? false
            let preview = text.count > 180 ? String(text.prefix(180)) + "…" : text
            let context = try browserApprovalContext(
                tabID: tabID,
                snapshotID: snapshotID,
                elementID: elementID
            )
            return browserProposal(
                toolCallID: toolCall.id,
                title: submit
                    ? "Type into \(context.targetLabel) and submit?"
                    : "Type into \(context.targetLabel)?",
                detail: "\(context.detail)\nText: \(preview)",
                confirmationTitle: submit ? "Type & Submit" : "Type",
                symbolName: "keyboard",
                command: BrowserCommand(
                    action: .type,
                    tabID: tabID,
                    expectedURL: context.expectedURL,
                    snapshotID: snapshotID,
                    elementID: elementID,
                    text: text,
                    clear: clear,
                    submit: submit
                )
            )

        case "browser_select":
            try requireOnly(arguments, keys: ["tab_id", "snapshot_id", "element_id", "value"])
            let tabID = try requiredInteger("tab_id", in: arguments, minimum: 0)
            let snapshotID = try browserIdentifier("snapshot_id", in: arguments, maximumLength: 128)
            let elementID = try browserIdentifier("element_id", in: arguments, maximumLength: 64)
            let value = try requiredText("value", in: arguments, maximumLength: 500)
            let context = try browserApprovalContext(
                tabID: tabID,
                snapshotID: snapshotID,
                elementID: elementID
            )
            let optionLabel = context.element.options?
                .first(where: { $0.value == value })?
                .label
            let rawSelectionLabel: String
            if let optionLabel, !optionLabel.isEmpty {
                rawSelectionLabel = optionLabel
            } else {
                rawSelectionLabel = value.isEmpty ? "empty option" : value
            }
            let selectionLabel = confirmationText(
                rawSelectionLabel,
                maximumLength: 180
            )
            return browserProposal(
                toolCallID: toolCall.id,
                title: "Choose “\(selectionLabel)” in \(context.targetLabel)?",
                detail: context.detail,
                confirmationTitle: "Select",
                symbolName: "checklist",
                command: BrowserCommand(
                    action: .select,
                    tabID: tabID,
                    expectedURL: context.expectedURL,
                    snapshotID: snapshotID,
                    elementID: elementID,
                    value: value
                )
            )

        case "browser_scroll":
            try requireOnly(arguments, keys: ["tab_id", "direction", "amount"])
            let tabID = try requiredInteger("tab_id", in: arguments, minimum: 0)
            let tabContext = try browserTabApprovalContext(
                tabID: tabID,
                requireListedTab: false
            )
            let direction = try requiredString("direction", in: arguments, maximumLength: 10)
            guard ["up", "down", "left", "right"].contains(direction) else {
                throw MacActionError.invalidArguments
            }
            let amount = try optionalInteger(
                "amount",
                in: arguments,
                minimum: 1,
                maximum: 5_000
            ) ?? 700
            return browserProposal(
                toolCallID: toolCall.id,
                title: "Scroll \(tabContext.targetLabel) \(direction)?",
                detail: "\(tabContext.detail)\nDistance: \(amount) pixels",
                confirmationTitle: "Scroll",
                symbolName: "arrow.up.and.down",
                command: BrowserCommand(
                    action: .scroll,
                    tabID: tabID,
                    expectedURL: tabContext.expectedURL,
                    direction: direction,
                    amount: amount
                )
            )

        case "browser_history":
            try requireOnly(arguments, keys: ["action", "tab_id"])
            let action = try requiredString("action", in: arguments, maximumLength: 10)
            let browserAction: BrowserCommandAction
            switch action {
            case "back": browserAction = .back
            case "forward": browserAction = .forward
            case "reload": browserAction = .reload
            default: throw MacActionError.invalidArguments
            }
            let tabID = try requiredInteger("tab_id", in: arguments, minimum: 0)
            let tabContext = try browserTabApprovalContext(
                tabID: tabID,
                requireListedTab: false
            )
            return browserProposal(
                toolCallID: toolCall.id,
                title: "\(action.capitalized) in \(tabContext.targetLabel)?",
                detail: tabContext.detail,
                confirmationTitle: action.capitalized,
                symbolName: "arrow.trianglehead.counterclockwise",
                command: BrowserCommand(
                    action: browserAction,
                    tabID: tabID,
                    expectedURL: tabContext.expectedURL
                )
            )

        case "browser_tabs":
            try requireOnly(arguments, keys: ["action", "tab_id"])
            let action = try requiredString("action", in: arguments, maximumLength: 10)
            let tabID = try optionalInteger("tab_id", in: arguments, minimum: 0)
            let commandAction: BrowserCommandAction
            let title: String
            let detail: String
            let confirmationTitle: String
            let expectedURL: String?
            switch action {
            case "list":
                guard tabID == nil else { throw MacActionError.unexpectedArguments }
                commandAction = .listTabs
                title = "List your Chrome tabs?"
                detail = "All normal Chrome tabs"
                confirmationTitle = "List Tabs"
                expectedURL = nil
            case "activate":
                guard let tabID else { throw MacActionError.missingArgument("tab_id") }
                let tabContext = try browserTabApprovalContext(
                    tabID: tabID,
                    requireListedTab: true
                )
                commandAction = .activateTab
                title = "Activate \(tabContext.targetLabel) in Chrome?"
                detail = tabContext.detail
                confirmationTitle = "Activate Tab"
                expectedURL = tabContext.expectedURL
            case "close":
                guard let tabID else { throw MacActionError.missingArgument("tab_id") }
                let tabContext = try browserTabApprovalContext(
                    tabID: tabID,
                    requireListedTab: true
                )
                commandAction = .closeTab
                title = "Close \(tabContext.targetLabel) in Chrome?"
                detail = tabContext.detail
                confirmationTitle = "Close Tab"
                expectedURL = tabContext.expectedURL
            default:
                throw MacActionError.invalidArguments
            }
            return browserProposal(
                toolCallID: toolCall.id,
                title: title,
                detail: detail,
                confirmationTitle: confirmationTitle,
                symbolName: "rectangle.on.rectangle",
                command: BrowserCommand(
                    action: commandAction,
                    tabID: tabID,
                    expectedURL: expectedURL
                )
            )

        case "copy_to_clipboard":
            try requireOnly(arguments, keys: ["text"])
            let text = try requiredString("text", in: arguments, maximumLength: 20_000)
            return ActionProposal(
                toolCallID: toolCall.id,
                title: "Copy this to the clipboard?",
                detail: text.count > 180 ? String(text.prefix(180)) + "…" : text,
                confirmationTitle: "Copy",
                symbolName: "doc.on.doc",
                kind: .copyToClipboard(text)
            )

        default:
            throw MacActionError.unsupportedTool(toolCall.function.name)
        }
    }

    func execute(_ proposal: ActionProposal) async throws -> MacActionResult {
        switch proposal.kind {
        case .openApplication(let url, let name):
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            try await openApplication(at: url, configuration: configuration)
            return MacActionResult(
                toolMessage: "Opened the installed application \(name).",
                activityDescription: "Opened \(name)"
            )

        case .openURL(let url):
            guard NSWorkspace.shared.open(url) else {
                throw MacActionError.couldNotOpen
            }
            return MacActionResult(
                toolMessage: "Opened \(url.absoluteString) in the default browser.",
                activityDescription: "Opened \(url.host ?? "website")"
            )

        case .controlBrowser(let command):
            guard let expectedGeneration = proposal.browserConnectionGeneration else {
                invalidateBrowserCaches()
                throw BrowserBridgeError.staleConnection
            }
            guard browserControl.connectionGeneration == expectedGeneration else {
                invalidateBrowserCaches()
                throw BrowserBridgeError.staleConnection
            }
            let result: BrowserCommandResult
            do {
                result = try await browserControl.perform(
                    command,
                    expectedConnectionGeneration: expectedGeneration
                )
                    .validated(for: command.action)
                guard browserControl.connectionGeneration == expectedGeneration else {
                    throw BrowserBridgeError.connectionChanged
                }
            } catch let error as BrowserBridgeError {
                if error == .staleConnection || error.actionOutcomeMayBeUnknown {
                    invalidateBrowserCaches()
                } else if case .remote(let code, _) = error,
                          code == "stale_tab",
                          let tabID = command.tabID {
                    latestBrowserPages.removeValue(forKey: tabID)
                    latestBrowserTabs.removeValue(forKey: tabID)
                }
                throw error
            }
            cachedBrowserConnectionGeneration = expectedGeneration
            if let tabs = result.tabs {
                let updatedTabs = Dictionary(
                    uniqueKeysWithValues: tabs.map { ($0.id, $0) }
                )
                latestBrowserPages = latestBrowserPages.filter {
                    guard let tab = updatedTabs[$0.key] else {
                        return false
                    }
                    return tab.url == $0.value.url && tab.title == $0.value.title
                }
                latestBrowserTabs = updatedTabs
            }
            if let page = result.page {
                latestBrowserPages[page.tabID] = page
            } else if result.observationWarning != nil, let tabID = command.tabID {
                latestBrowserPages.removeValue(forKey: tabID)
                latestBrowserTabs.removeValue(forKey: tabID)
            }
            if command.action == .closeTab, let tabID = command.tabID {
                latestBrowserPages.removeValue(forKey: tabID)
                latestBrowserTabs.removeValue(forKey: tabID)
            }
            return MacActionResult(
                toolMessage: try result.toolMessage(),
                activityDescription: command.activityDescription
            )

        case .copyToClipboard(let text):
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            guard pasteboard.setString(text, forType: .string) else {
                throw MacActionError.couldNotCopy
            }
            return MacActionResult(
                toolMessage: "Copied the requested text to the clipboard.",
                activityDescription: "Copied to clipboard"
            )
        }
    }

    private func openApplication(
        at url: URL,
        configuration: NSWorkspace.OpenConfiguration
    ) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            NSWorkspace.shared.openApplication(
                at: url,
                configuration: configuration
            ) { application, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if application != nil {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: MacActionError.couldNotOpen)
                }
            }
        }
    }

    private func browserProposal(
        toolCallID: String,
        title: String,
        detail: String,
        confirmationTitle: String,
        symbolName: String,
        command: BrowserCommand
    ) -> ActionProposal {
        let usesObservedTab = command.action != .listTabs && !(
            command.action == .navigate && command.newTab == true
        )
        let generation = usesObservedTab
            ? cachedBrowserConnectionGeneration ?? browserControl.connectionGeneration
            : browserControl.connectionGeneration
        return ActionProposal(
            toolCallID: toolCallID,
            title: title,
            detail: detail,
            confirmationTitle: confirmationTitle,
            symbolName: symbolName,
            kind: .controlBrowser(command),
            browserConnectionGeneration: generation
        )
    }

    private func synchronizeBrowserCacheGeneration() {
        guard let cachedBrowserConnectionGeneration else {
            return
        }
        if cachedBrowserConnectionGeneration != browserControl.connectionGeneration {
            invalidateBrowserCaches()
        }
    }

    private func invalidateBrowserCaches() {
        latestBrowserPages.removeAll()
        latestBrowserTabs.removeAll()
        cachedBrowserConnectionGeneration = nil
    }

    private func browserApprovalContext(
        tabID: Int,
        snapshotID: String,
        elementID: String
    ) throws -> BrowserElementApprovalContext {
        guard
            let page = latestBrowserPages[tabID],
            page.snapshotID == snapshotID,
            let element = page.elements.first(where: { $0.id == elementID })
        else {
            throw MacActionError.browserSnapshotUnavailable
        }

        let role = confirmationText(
            element.role.isEmpty ? element.tag : element.role,
            maximumLength: 80
        )
        let name = confirmationText(element.name, maximumLength: 180)
        let site = URLComponents(string: page.url)?.host ?? "unknown website"
        let observedURL = confirmationText(page.url, maximumLength: 500)
        let targetLabel = name.isEmpty ? "\(role) \(element.id)" : "“\(name)”"
        let observedControl = name.isEmpty ? role : "\(role): \(name)"
        return BrowserElementApprovalContext(
            element: element,
            expectedURL: page.url,
            targetLabel: targetLabel,
            detail: "Website: \(site)\nObserved URL: \(observedURL)\nObserved control: \(observedControl)"
        )
    }

    private func browserTabApprovalContext(
        tabID: Int,
        requireListedTab: Bool
    ) throws -> BrowserTabApprovalContext {
        let title: String
        let rawURL: String

        if requireListedTab, let tab = latestBrowserTabs[tabID] {
            title = tab.title
            rawURL = tab.url
        } else if !requireListedTab, let page = latestBrowserPages[tabID] {
            title = page.title
            rawURL = page.url
        } else if !requireListedTab, let tab = latestBrowserTabs[tabID] {
            title = tab.title
            rawURL = tab.url
        } else if requireListedTab {
            throw MacActionError.browserTabListUnavailable
        } else {
            throw MacActionError.browserTabUnavailable
        }

        guard
            !rawURL.isEmpty,
            rawURL.count <= 4_096,
            let components = URLComponents(string: rawURL),
            let scheme = components.scheme,
            !scheme.isEmpty,
            components.url != nil
        else {
            throw requireListedTab
                ? MacActionError.browserTabListUnavailable
                : MacActionError.browserTabUnavailable
        }

        let observedTitle = confirmationText(title, maximumLength: 180)
        let website = browserLocationDescription(rawURL)
        let observedURL = confirmationText(rawURL, maximumLength: 500)
        let targetLabel = observedTitle.isEmpty
            ? "Chrome tab \(tabID)"
            : "“\(observedTitle)”"
        return BrowserTabApprovalContext(
            expectedURL: rawURL,
            targetLabel: targetLabel,
            detail: "Website: \(website)\nObserved URL: \(observedURL)\nChrome tab: \(tabID)"
        )
    }

    private func browserLocationDescription(_ rawURL: String) -> String {
        guard let components = URLComponents(string: rawURL) else {
            return "unknown website"
        }
        if let host = components.host, !host.isEmpty {
            return confirmationText(host, maximumLength: 255)
        }
        let scheme = confirmationText(components.scheme ?? "", maximumLength: 40)
        return scheme.isEmpty ? "unknown website" : "\(scheme) page"
    }

    private func confirmationText(_ value: String, maximumLength: Int) -> String {
        let normalized = value
            .replacingOccurrences(of: "\u{0000}", with: "")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return String(normalized.prefix(maximumLength))
    }

    private func validatedBrowserURL(_ rawValue: String) throws -> URL {
        guard
            let components = URLComponents(string: rawValue),
            let scheme = components.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            let host = components.host,
            !host.isEmpty,
            components.user == nil,
            components.password == nil,
            let url = components.url
        else {
            throw MacActionError.invalidURL
        }
        return url
    }

    private func browserIdentifier(
        _ key: String,
        in arguments: [String: Any],
        maximumLength: Int
    ) throws -> String {
        let value = try requiredString(key, in: arguments, maximumLength: maximumLength)
        do {
            return try BrowserCommandResult.validatedIdentifier(
                value,
                maximumLength: maximumLength
            )
        } catch {
            throw MacActionError.invalidArguments
        }
    }

    private func decodeArguments(_ rawArguments: String) throws -> [String: Any] {
        guard let data = rawArguments.data(using: .utf8) else {
            throw MacActionError.invalidArguments
        }
        let object = try JSONSerialization.jsonObject(with: data)
        guard let arguments = object as? [String: Any] else {
            throw MacActionError.invalidArguments
        }
        return arguments
    }

    private func requireOnly(
        _ arguments: [String: Any],
        keys: Set<String>
    ) throws {
        guard Set(arguments.keys).isSubset(of: keys) else {
            throw MacActionError.unexpectedArguments
        }
    }

    private func requiredString(
        _ key: String,
        in arguments: [String: Any],
        maximumLength: Int
    ) throws -> String {
        guard let value = optionalString(key, in: arguments, maximumLength: maximumLength) else {
            throw MacActionError.missingArgument(key)
        }
        return value
    }

    private func requiredText(
        _ key: String,
        in arguments: [String: Any],
        maximumLength: Int
    ) throws -> String {
        guard let value = arguments[key] as? String else {
            throw MacActionError.missingArgument(key)
        }
        guard value.count <= maximumLength else {
            throw MacActionError.invalidArguments
        }
        return value.replacingOccurrences(of: "\u{0000}", with: "")
    }

    private func optionalString(
        _ key: String,
        in arguments: [String: Any],
        maximumLength: Int
    ) -> String? {
        guard let rawValue = arguments[key] as? String else {
            return nil
        }
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= maximumLength else {
            return nil
        }
        return value
    }

    private func requiredInteger(
        _ key: String,
        in arguments: [String: Any],
        minimum: Int,
        maximum: Int = Int.max
    ) throws -> Int {
        guard let value = try optionalInteger(
            key,
            in: arguments,
            minimum: minimum,
            maximum: maximum
        ) else {
            throw MacActionError.missingArgument(key)
        }
        return value
    }

    private func optionalInteger(
        _ key: String,
        in arguments: [String: Any],
        minimum: Int,
        maximum: Int = Int.max
    ) throws -> Int? {
        guard let rawValue = arguments[key] else {
            return nil
        }
        guard let number = rawValue as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite,
              number.doubleValue.rounded(.towardZero) == number.doubleValue
        else {
            throw MacActionError.invalidArguments
        }
        let value = number.intValue
        guard value >= minimum, value <= maximum else {
            throw MacActionError.invalidArguments
        }
        return value
    }

    private func optionalBoolean(
        _ key: String,
        in arguments: [String: Any]
    ) throws -> Bool? {
        guard let rawValue = arguments[key] else {
            return nil
        }
        guard let value = rawValue as? Bool else {
            throw MacActionError.invalidArguments
        }
        return value
    }

    private func resolveApplication(name: String, bundleID: String?) throws -> URL {
        guard !name.contains("/") else {
            throw MacActionError.invalidApplicationName
        }

        let url: URL?
        if let bundleID {
            url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
                ?? applicationURL(named: name)
        } else {
            url = applicationURL(named: name)
        }

        guard let url else {
            throw MacActionError.applicationNotFound(name)
        }

        return try validatedApplicationURL(url)
    }

    func validatedApplicationURL(_ url: URL) throws -> URL {
        let resolvedURL = url.resolvingSymlinksInPath().standardizedFileURL
        // Launch Services can return apps from user folders, developer build
        // directories, external volumes, and Apple's sealed system Cryptexes.
        // Restrict the item type instead of imposing an installation location.
        guard
            resolvedURL.isFileURL,
            resolvedURL.pathExtension.localizedCaseInsensitiveCompare("app") == .orderedSame
        else {
            throw MacActionError.invalidApplication
        }
        return resolvedURL
    }

    private func applicationURL(named name: String) -> URL? {
        let fileManager = FileManager.default
        let requestedName = name.hasSuffix(".app") ? String(name.dropLast(4)) : name
        if let launchServicesURL = launchServicesApplicationURL(named: requestedName) {
            return launchServicesURL
        }

        let searchDirectories = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/Applications/Utilities", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications/Utilities", isDirectory: true)
        ]

        for directory in searchDirectories {
            let directURL = directory.appendingPathComponent(requestedName + ".app")
            if fileManager.fileExists(atPath: directURL.path) {
                return directURL
            }

            guard let entries = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }
            if let match = entries.first(where: {
                $0.pathExtension == "app"
                    && $0.deletingPathExtension().lastPathComponent
                        .localizedCaseInsensitiveCompare(requestedName) == .orderedSame
            }) {
                return match
            }
        }
        return nil
    }

    private func launchServicesApplicationURL(named name: String) -> URL? {
        // LaunchServices remains the only sandbox-safe name lookup for apps in
        // nested user Applications folders. Invoke the deprecated Objective-C
        // selector dynamically while macOS has no typed replacement by name.
        let selector = NSSelectorFromString("fullPathForApplication:")
        guard
            NSWorkspace.shared.responds(to: selector),
            let result = NSWorkspace.shared.perform(selector, with: name),
            let path = result.takeUnretainedValue() as? String
        else {
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
}

private extension BrowserCommand {
    var activityDescription: String {
        switch action {
        case .inspect:
            "Inspected Chrome tab"
        case .navigate:
            "Navigated Chrome"
        case .click:
            "Clicked in Chrome"
        case .type:
            submit == true ? "Typed and submitted in Chrome" : "Typed in Chrome"
        case .select:
            "Selected an option in Chrome"
        case .scroll:
            "Scrolled Chrome"
        case .back:
            "Went back in Chrome"
        case .forward:
            "Went forward in Chrome"
        case .reload:
            "Reloaded Chrome tab"
        case .listTabs:
            "Listed Chrome tabs"
        case .activateTab:
            "Activated Chrome tab"
        case .closeTab:
            "Closed Chrome tab"
        }
    }
}

enum MacActionError: LocalizedError, Sendable {
    case invalidArguments
    case unexpectedArguments
    case missingArgument(String)
    case invalidURL
    case unsupportedTool(String)
    case applicationNotFound(String)
    case invalidApplicationName
    case invalidApplication
    case browserSnapshotUnavailable
    case browserTabUnavailable
    case browserTabListUnavailable
    case couldNotOpen
    case couldNotCopy

    var errorDescription: String? {
        switch self {
        case .invalidArguments:
            "The action arguments were invalid."
        case .unexpectedArguments:
            "The action included arguments Orchard does not allow."
        case .missingArgument(let name):
            "The action is missing the required \(name) value."
        case .invalidURL:
            "Orchard only accepts complete HTTP or HTTPS web addresses without embedded credentials."
        case .unsupportedTool(let name):
            "Orchard does not allow the \(name) action."
        case .applicationNotFound(let name):
            "Orchard could not find an application named \(name)."
        case .invalidApplicationName:
            "Provide an application name, not a file path."
        case .invalidApplication:
            "The resolved item is not a macOS application."
        case .browserSnapshotUnavailable:
            "Inspect the Chrome tab again before interacting with a page control."
        case .browserTabUnavailable:
            "List or inspect Chrome tabs again before changing an existing tab."
        case .browserTabListUnavailable:
            "List Chrome tabs again before activating or closing one."
        case .couldNotOpen:
            "macOS could not open that item."
        case .couldNotCopy:
            "macOS could not write to the clipboard."
        }
    }
}
