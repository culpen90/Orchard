import AppKit
import Darwin
import Foundation

enum MacActionKind: Equatable, Sendable {
    case openApplication(url: URL, name: String)
    case openURL(URL)
    case searchWeb(url: URL, query: String)
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

    init(
        toolCallID: String,
        title: String,
        detail: String,
        confirmationTitle: String,
        symbolName: String,
        kind: MacActionKind
    ) {
        id = UUID()
        self.toolCallID = toolCallID
        self.title = title
        self.detail = detail
        self.confirmationTitle = confirmationTitle
        self.symbolName = symbolName
        self.kind = kind
    }
}

struct MacActionResult: Equatable, Sendable {
    let toolMessage: String
    let activityDescription: String
}

@MainActor
protocol MacActionServicing: AnyObject {
    var toolDefinitions: [OpenRouterToolDefinition] { get }
    func prepare(toolCall: OpenRouterToolCall) throws -> ActionProposal
    func execute(_ proposal: ActionProposal) async throws -> MacActionResult
}

@MainActor
final class MacActionService: MacActionServicing {
    let toolDefinitions: [OpenRouterToolDefinition] = [
        OpenRouterToolDefinition(
            function: OpenRouterFunctionDefinition(
                name: "open_application",
                description: "Open an installed macOS application when the user asks to launch or switch to it.",
                parameters: OpenRouterToolParameters(
                    properties: [
                        "name": .string("The human-readable application name, such as Safari."),
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
                name: "search_web",
                description: "Search the web in the user's default browser.",
                parameters: OpenRouterToolParameters(
                    properties: [
                        "query": .string("The search query.")
                    ],
                    required: ["query"]
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

    func prepare(toolCall: OpenRouterToolCall) throws -> ActionProposal {
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

        case "search_web":
            try requireOnly(arguments, keys: ["query"])
            let query = try requiredString("query", in: arguments, maximumLength: 1_000)
            var components = URLComponents(string: "https://www.google.com/search")
            components?.queryItems = [URLQueryItem(name: "q", value: query)]
            guard let url = components?.url else {
                throw MacActionError.invalidURL
            }
            return ActionProposal(
                toolCallID: toolCall.id,
                title: "Search the web?",
                detail: query,
                confirmationTitle: "Search",
                symbolName: "magnifyingglass",
                kind: .searchWeb(url: url, query: query)
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
            _ = try await NSWorkspace.shared.openApplication(
                at: url,
                configuration: configuration
            )
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

        case .searchWeb(let url, let query):
            guard NSWorkspace.shared.open(url) else {
                throw MacActionError.couldNotOpen
            }
            return MacActionResult(
                toolMessage: "Opened a web search for: \(query)",
                activityDescription: "Searched the web"
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

    private func resolveApplication(name: String, bundleID: String?) throws -> URL {
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

        let resolvedURL = url.resolvingSymlinksInPath().standardizedFileURL
        let path = resolvedURL.path
        var allowedPrefixes = [
            "/Applications/",
            "/System/Applications/",
            "/System/Library/CoreServices/"
        ]
        if let userHomePath = realUserHomePath() {
            allowedPrefixes.append(userHomePath + "/Applications/")
        }
        guard allowedPrefixes.contains(where: path.hasPrefix), path.hasSuffix(".app") else {
            throw MacActionError.applicationNotAllowed
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

    private func realUserHomePath() -> String? {
        guard let passwordEntry = getpwuid(getuid()),
              let homePointer = passwordEntry.pointee.pw_dir
        else {
            return nil
        }
        return String(cString: homePointer)
    }
}

enum MacActionError: LocalizedError, Sendable {
    case invalidArguments
    case unexpectedArguments
    case missingArgument(String)
    case invalidURL
    case unsupportedTool(String)
    case applicationNotFound(String)
    case applicationNotAllowed
    case couldNotOpen
    case couldNotCopy

    var errorDescription: String? {
        switch self {
        case .invalidArguments:
            "The action arguments were not valid JSON."
        case .unexpectedArguments:
            "The action included arguments Orchard does not allow."
        case .missingArgument(let name):
            "The action is missing the required \(name) value."
        case .invalidURL:
            "Orchard only opens complete HTTPS web addresses."
        case .unsupportedTool(let name):
            "Orchard does not allow the \(name) action."
        case .applicationNotFound(let name):
            "The application \(name) is not installed."
        case .applicationNotAllowed:
            "Orchard only opens installed applications from standard Applications folders."
        case .couldNotOpen:
            "macOS could not open that item."
        case .couldNotCopy:
            "macOS could not write to the clipboard."
        }
    }
}
