import Foundation
import XCTest
@testable import Orchard

@MainActor
final class AssistantStoreTests: XCTestCase {
    func testBlankPromptIsIgnored() {
        let (store, _) = makeStore(events: [.completed])

        store.submit("   \n")

        XCTAssertTrue(store.messages.isEmpty)
        XCTAssertFalse(store.isResponding)
    }

    func testStreamingUpdatesOneAssistantMessageAndSpeaksOnce() async {
        let (store, engine) = makeStore(
            events: [.text("Hel"), .text("lo"), .completed],
            speakResponses: true
        )

        store.submit("Say hello")
        await waitUntil { !store.isResponding }

        XCTAssertEqual(store.messages.map(\.role), [.user, .assistant])
        XCTAssertEqual(store.messages.last?.content, "Hello")
        XCTAssertEqual(engine.spokenTexts, ["Hello"])
    }

    func testStreamFailureRemovesEmptyPlaceholderAndShowsError() async {
        let (store, _) = makeStore(events: [], error: .failed)

        store.submit("Fail")
        await waitUntil { !store.isResponding }

        XCTAssertEqual(store.messages.map(\.role), [.user])
        XCTAssertEqual(store.lastError, "Stub failure")
    }

    func testMissingAPIKeyDoesNotAddMessages() {
        let defaults = isolatedDefaults()
        let store = AssistantStore(
            openRouter: StubOpenRouter(events: [.completed]),
            keychain: StubAPIKeyStore(key: nil),
            speechController: SpeechController(engine: FakeSpeechEngine()),
            defaults: defaults
        )

        store.submit("Hello")

        XCTAssertTrue(store.messages.isEmpty)
        XCTAssertNotNil(store.lastError)
    }

    func testReasoningDetailsArePreservedAcrossToolRound() async throws {
        let reasoningDetail = try JSONDecoder().decode(
            JSONValue.self,
            from: Data(#"{"type":"reasoning.encrypted","data":"opaque","index":0}"#.utf8)
        )
        let router = ScriptedOpenRouter(
            scripts: [
                StubStreamScript(
                    events: [
                        .reasoning("Plain reasoning fallback"),
                        .reasoningDetails([reasoningDetail]),
                        .toolCall(toolCallDelta(id: "call_1")),
                        .finishReason(.toolCalls),
                        .completed
                    ]
                ),
                StubStreamScript(
                    events: [.text("Done"), .finishReason(.stop), .completed]
                )
            ]
        )
        let actionService = StubActionService()
        let defaults = isolatedDefaults()
        defaults.set(false, forKey: PreferenceKeys.speakResponses)
        defaults.set(false, forKey: PreferenceKeys.confirmActions)
        let store = AssistantStore(
            openRouter: router,
            keychain: StubAPIKeyStore(key: "test-key"),
            actionService: actionService,
            speechController: SpeechController(engine: FakeSpeechEngine()),
            defaults: defaults
        )

        store.submit("Copy this")
        await waitUntil { !store.isResponding }

        XCTAssertEqual(router.configurations.count, 2)
        let continuationMessage = try XCTUnwrap(
            router.configurations[1].messages.first(where: { $0.toolCalls != nil })
        )
        XCTAssertEqual(continuationMessage.reasoningDetails, [reasoningDetail])
        XCTAssertNil(continuationMessage.reasoning)
        XCTAssertEqual(actionService.executionCount, 1)
        XCTAssertEqual(store.messages.last?.content, "Done")
        XCTAssertEqual(store.messages.last?.activities, ["Copied test text"])
        XCTAssertEqual(store.messages.last?.deliveryState, .complete)
    }

    func testBrowserEvidenceIsSentBackToModelForAnswerSynthesis() async throws {
        let router = ScriptedOpenRouter(
            scripts: [
                StubStreamScript(
                    events: [
                        .toolCall(
                            toolCallDelta(
                                id: "search_1",
                                functionName: "search_web",
                                arguments: #"{"query":"current answer"}"#
                            )
                        ),
                        .finishReason(.toolCalls),
                        .completed
                    ]
                ),
                StubStreamScript(
                    events: [.text("The current answer."), .finishReason(.stop), .completed]
                )
            ]
        )
        let evidence = #"{"query":"current answer","results":[{"title":"Source","url":"https://example.com/current","snippet":"Current evidence"}]}"#
        let actionService = StubActionService(
            toolResultMessage: evidence,
            activity: "Researched the web in Chrome"
        )
        let defaults = isolatedDefaults()
        defaults.set(false, forKey: PreferenceKeys.speakResponses)
        defaults.set(false, forKey: PreferenceKeys.confirmActions)
        let store = AssistantStore(
            openRouter: router,
            keychain: StubAPIKeyStore(key: "test-key"),
            actionService: actionService,
            speechController: SpeechController(engine: FakeSpeechEngine()),
            defaults: defaults
        )

        store.submit("Look up the current answer")
        await waitUntil { !store.isResponding }

        XCTAssertEqual(router.configurations.count, 2)
        let toolMessage = try XCTUnwrap(
            router.configurations[1].messages.first(where: { $0.role == .tool })
        )
        XCTAssertEqual(toolMessage.content, evidence)
        XCTAssertTrue(router.configurations[1].tools.isEmpty)
        XCTAssertEqual(store.messages.last?.content, "The current answer.")
        XCTAssertEqual(store.messages.last?.activities, ["Researched the web in Chrome"])
    }

    func testToolCallIsRejectedWhenActionsWereNotOffered() async {
        let router = ScriptedOpenRouter(
            scripts: [
                StubStreamScript(
                    events: [
                        .toolCall(toolCallDelta(id: "unexpected_action")),
                        .finishReason(.toolCalls),
                        .completed
                    ]
                )
            ]
        )
        let actionService = StubActionService()
        let defaults = isolatedDefaults()
        defaults.set(false, forKey: PreferenceKeys.speakResponses)
        defaults.set(false, forKey: PreferenceKeys.enableActions)
        let store = AssistantStore(
            openRouter: router,
            keychain: StubAPIKeyStore(key: "test-key"),
            actionService: actionService,
            speechController: SpeechController(engine: FakeSpeechEngine()),
            defaults: defaults
        )

        store.submit("Do not run an action")
        await waitUntil { !store.isResponding }

        XCTAssertEqual(actionService.executionCount, 0)
        XCTAssertTrue(store.lastError?.contains("actions were unavailable") == true)
    }

    func testBrowserEvidenceCannotTriggerAnActionDuringSynthesis() async {
        let router = ScriptedOpenRouter(
            scripts: [
                StubStreamScript(
                    events: [
                        .toolCall(
                            toolCallDelta(
                                id: "search_1",
                                functionName: "search_web",
                                arguments: #"{"query":"current answer"}"#
                            )
                        ),
                        .finishReason(.toolCalls),
                        .completed
                    ]
                ),
                StubStreamScript(
                    events: [
                        .toolCall(toolCallDelta(id: "injected_action")),
                        .finishReason(.toolCalls),
                        .completed
                    ]
                )
            ]
        )
        let actionService = StubActionService(toolResultMessage: "Untrusted browser evidence")
        let defaults = isolatedDefaults()
        defaults.set(false, forKey: PreferenceKeys.speakResponses)
        defaults.set(false, forKey: PreferenceKeys.confirmActions)
        let store = AssistantStore(
            openRouter: router,
            keychain: StubAPIKeyStore(key: "test-key"),
            actionService: actionService,
            speechController: SpeechController(engine: FakeSpeechEngine()),
            defaults: defaults
        )

        store.submit("Research this")
        await waitUntil { !store.isResponding }

        XCTAssertEqual(actionService.executionCount, 1)
        XCTAssertTrue(router.configurations[1].tools.isEmpty)
        XCTAssertTrue(store.lastError?.contains("actions were unavailable") == true)
    }

    func testLaterActionsRequireConfirmationAfterBrowserResearch() async {
        let router = ScriptedOpenRouter(
            scripts: [
                StubStreamScript(
                    events: [
                        .toolCall(
                            toolCallDelta(
                                id: "search_1",
                                functionName: "search_web",
                                arguments: #"{"query":"current answer"}"#
                            )
                        ),
                        .finishReason(.toolCalls),
                        .completed
                    ]
                ),
                StubStreamScript(
                    events: [.text("First answer"), .finishReason(.stop), .completed]
                ),
                StubStreamScript(
                    events: [
                        .toolCall(toolCallDelta(id: "later_action")),
                        .finishReason(.toolCalls),
                        .completed
                    ]
                ),
                StubStreamScript(
                    events: [.text("No action taken"), .finishReason(.stop), .completed]
                )
            ]
        )
        let actionService = StubActionService(toolResultMessage: "Browser evidence")
        let defaults = isolatedDefaults()
        defaults.set(false, forKey: PreferenceKeys.speakResponses)
        defaults.set(false, forKey: PreferenceKeys.confirmActions)
        let store = AssistantStore(
            openRouter: router,
            keychain: StubAPIKeyStore(key: "test-key"),
            actionService: actionService,
            speechController: SpeechController(engine: FakeSpeechEngine()),
            defaults: defaults
        )

        store.submit("Research this")
        await waitUntil { !store.isResponding }
        XCTAssertEqual(actionService.executionCount, 1)

        store.submit("Continue")
        await waitUntil { store.pendingAction != nil }
        XCTAssertEqual(actionService.executionCount, 1)

        store.resolvePendingAction(approved: false)
        await waitUntil { !store.isResponding }
        XCTAssertEqual(actionService.executionCount, 1)
        XCTAssertEqual(store.messages.last?.content, "No action taken")
    }

    func testPartialFailureIsMarkedInterruptedAndExcludedFromHistory() async {
        let router = ScriptedOpenRouter(
            scripts: [
                StubStreamScript(events: [.text("Partial")], error: .failed),
                StubStreamScript(
                    events: [.text("Recovered"), .finishReason(.stop), .completed]
                )
            ]
        )
        let defaults = isolatedDefaults()
        defaults.set(false, forKey: PreferenceKeys.speakResponses)
        defaults.set(false, forKey: PreferenceKeys.enableActions)
        let store = AssistantStore(
            openRouter: router,
            keychain: StubAPIKeyStore(key: "test-key"),
            speechController: SpeechController(engine: FakeSpeechEngine()),
            defaults: defaults
        )

        store.submit("First")
        await waitUntil { !store.isResponding }
        XCTAssertEqual(store.messages.last?.content, "Partial")
        XCTAssertEqual(store.messages.last?.deliveryState, .interrupted)

        store.submit("Second")
        await waitUntil { !store.isResponding }

        XCTAssertEqual(router.configurations.count, 2)
        XCTAssertFalse(
            router.configurations[1].messages.contains(where: { $0.content == "Partial" })
        )
        XCTAssertEqual(store.messages.last?.content, "Recovered")
        XCTAssertEqual(store.messages.last?.deliveryState, .complete)
    }

    func testLengthFinishReasonDoesNotSpeakPartialResponse() async {
        let (store, engine) = makeStore(
            events: [.text("Cut off"), .finishReason(.length), .completed],
            speakResponses: true
        )

        store.submit("Long answer")
        await waitUntil { !store.isResponding }

        XCTAssertEqual(store.messages.last?.deliveryState, .interrupted)
        XCTAssertTrue(store.lastError?.contains("output limit") == true)
        XCTAssertTrue(engine.spokenTexts.isEmpty)
    }

    func testLastToolRoundIsNotExecutedWithoutSynthesisRound() async {
        let scripts = (0..<4).map { index in
            StubStreamScript(
                events: [
                    .toolCall(toolCallDelta(id: "call_\(index)")),
                    .finishReason(.toolCalls),
                    .completed
                ]
            )
        }
        let router = ScriptedOpenRouter(scripts: scripts)
        let actionService = StubActionService()
        let defaults = isolatedDefaults()
        defaults.set(false, forKey: PreferenceKeys.speakResponses)
        defaults.set(false, forKey: PreferenceKeys.confirmActions)
        let store = AssistantStore(
            openRouter: router,
            keychain: StubAPIKeyStore(key: "test-key"),
            actionService: actionService,
            speechController: SpeechController(engine: FakeSpeechEngine()),
            defaults: defaults
        )

        store.submit("Keep copying")
        await waitUntil { !store.isResponding }

        XCTAssertEqual(router.configurations.count, 4)
        XCTAssertEqual(actionService.executionCount, 3)
        XCTAssertEqual(store.messages.last?.activities.count, 3)
        XCTAssertEqual(store.messages.last?.deliveryState, .interrupted)
        XCTAssertTrue(store.lastError?.contains("too many action rounds") == true)
    }

    private func makeStore(
        events: [OpenRouterStreamEvent],
        error: StubError? = nil,
        speakResponses: Bool = false
    ) -> (AssistantStore, FakeSpeechEngine) {
        let defaults = isolatedDefaults()
        defaults.set(speakResponses, forKey: PreferenceKeys.speakResponses)
        defaults.set(false, forKey: PreferenceKeys.enableActions)
        let engine = FakeSpeechEngine()
        let store = AssistantStore(
            openRouter: StubOpenRouter(events: events, error: error),
            keychain: StubAPIKeyStore(key: "test-key"),
            speechController: SpeechController(engine: engine),
            defaults: defaults
        )
        return (store, engine)
    }

    private func isolatedDefaults() -> UserDefaults {
        let suite = "AssistantStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func toolCallDelta(
        id: String,
        functionName: String = "copy_to_clipboard",
        arguments: String = #"{"text":"Test text"}"#
    ) -> OpenRouterToolCallDelta {
        OpenRouterToolCallDelta(
            index: 0,
            id: id,
            type: "function",
            functionName: functionName,
            arguments: arguments
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @escaping @MainActor () -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition(), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition(), "Condition did not become true before timeout")
    }
}
