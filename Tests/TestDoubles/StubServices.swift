import Foundation
@testable import Orchard

struct StubOpenRouter: OpenRouterStreaming, Sendable {
    let events: [OpenRouterStreamEvent]
    let error: StubError?

    init(events: [OpenRouterStreamEvent], error: StubError? = nil) {
        self.events = events
        self.error = error
    }

    func streamChat(
        configuration: OpenRouterChatConfiguration
    ) -> AsyncThrowingStream<OpenRouterStreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            for event in events {
                continuation.yield(event)
            }
            if let error {
                continuation.finish(throwing: error)
            } else {
                continuation.finish()
            }
        }
    }
}

struct StubStreamScript: Sendable {
    let events: [OpenRouterStreamEvent]
    let error: StubError?

    init(events: [OpenRouterStreamEvent], error: StubError? = nil) {
        self.events = events
        self.error = error
    }
}

final class ScriptedOpenRouter: OpenRouterStreaming, @unchecked Sendable {
    private let lock = NSLock()
    private var scripts: [StubStreamScript]
    private var recordedConfigurations: [OpenRouterChatConfiguration] = []

    init(scripts: [StubStreamScript]) {
        self.scripts = scripts
    }

    var configurations: [OpenRouterChatConfiguration] {
        lock.withLock { recordedConfigurations }
    }

    func streamChat(
        configuration: OpenRouterChatConfiguration
    ) -> AsyncThrowingStream<OpenRouterStreamEvent, any Error> {
        let script = lock.withLock {
            recordedConfigurations.append(configuration)
            if scripts.isEmpty {
                return StubStreamScript(events: [], error: .failed)
            }
            return scripts.removeFirst()
        }

        return AsyncThrowingStream { continuation in
            for event in script.events {
                continuation.yield(event)
            }
            if let error = script.error {
                continuation.finish(throwing: error)
            } else {
                continuation.finish()
            }
        }
    }
}

@MainActor
final class StubActionService: MacActionServicing {
    let toolDefinitions = [
        OpenRouterToolDefinition(
            function: OpenRouterFunctionDefinition(
                name: "copy_to_clipboard",
                description: "Copy text.",
                parameters: OpenRouterToolParameters(
                    properties: ["text": .string("Text")],
                    required: ["text"]
                )
            )
        )
    ]

    private(set) var executionCount = 0

    func prepare(toolCall: OpenRouterToolCall) throws -> ActionProposal {
        ActionProposal(
            toolCallID: toolCall.id,
            title: "Copy?",
            detail: "Test text",
            confirmationTitle: "Copy",
            symbolName: "doc.on.doc",
            kind: .copyToClipboard("Test text")
        )
    }

    func execute(_ proposal: ActionProposal) async throws -> MacActionResult {
        executionCount += 1
        return MacActionResult(
            toolMessage: "Copied test text.",
            activityDescription: "Copied test text"
        )
    }
}

enum StubError: LocalizedError, Sendable {
    case failed

    var errorDescription: String? { "Stub failure" }
}

final class StubAPIKeyStore: APIKeyStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var key: String?

    init(key: String?) {
        self.key = key
    }

    func loadAPIKey() throws -> String? {
        lock.withLock { key }
    }

    func saveAPIKey(_ key: String) throws {
        lock.withLock { self.key = key }
    }

    func deleteAPIKey() throws {
        lock.withLock { key = nil }
    }
}
