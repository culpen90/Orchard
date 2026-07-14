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

    func testBrowserControlKeepsToolsAvailableForIterativeActions() async throws {
        let router = ScriptedOpenRouter(
            scripts: [
                StubStreamScript(
                    events: [
                        .toolCall(
                            toolCallDelta(
                                id: "inspect_1",
                                functionName: "browser_inspect",
                                arguments: "{}"
                            )
                        ),
                        .finishReason(.toolCalls),
                        .completed
                    ]
                ),
                StubStreamScript(
                    events: [
                        .toolCall(
                            toolCallDelta(
                                id: "click_1",
                                functionName: "browser_click",
                                arguments: #"{"tab_id":42,"snapshot_id":"page:1","element_id":"e2"}"#
                            )
                        ),
                        .finishReason(.toolCalls),
                        .completed
                    ]
                ),
                StubStreamScript(
                    events: [.text("The browser task is complete."), .finishReason(.stop), .completed]
                )
            ]
        )
        let snapshot = #"{"action":"page.inspect","page":{"snapshotId":"page:1"}}"#
        let actionService = StubActionService(
            toolResultMessage: snapshot,
            activity: "Controlled Chrome"
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

        store.submit("Click Continue in the current Chrome tab")
        await waitUntil { !store.isResponding }

        XCTAssertEqual(router.configurations.count, 3)
        let firstToolMessage = try XCTUnwrap(
            router.configurations[1].messages.first(where: { $0.role == .tool })
        )
        XCTAssertEqual(firstToolMessage.content, snapshot)
        XCTAssertFalse(router.configurations[1].tools.isEmpty)
        XCTAssertFalse(router.configurations[2].tools.isEmpty)
        XCTAssertEqual(actionService.executionCount, 2)
        XCTAssertEqual(store.messages.last?.content, "The browser task is complete.")
        XCTAssertEqual(store.messages.last?.activities, ["Controlled Chrome", "Controlled Chrome"])
    }

    func testUnknownBrowserOutcomeWarnsModelNotToRetryBlindly() async throws {
        let router = ScriptedOpenRouter(
            scripts: [
                StubStreamScript(
                    events: [
                        .toolCall(toolCallDelta(id: "uncertain_action")),
                        .finishReason(.toolCalls),
                        .completed
                    ]
                ),
                StubStreamScript(
                    events: [.text("I will inspect before retrying."), .finishReason(.stop), .completed]
                )
            ]
        )
        let actionService = StubActionService(executionError: BrowserBridgeError.outcomeUnknown)
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

        store.submit("Do the browser action")
        await waitUntil { !store.isResponding }

        let toolMessage = try XCTUnwrap(
            router.configurations[1].messages.first(where: { $0.role == .tool })?.content
        )
        XCTAssertTrue(toolMessage.contains("outcome is unknown"))
        XCTAssertTrue(toolMessage.contains("may have happened"))
        XCTAssertTrue(toolMessage.contains("Do not retry it blindly"))
        XCTAssertTrue(toolMessage.contains("List or inspect"))
        XCTAssertFalse(toolMessage.contains("failed safely"))
        XCTAssertEqual(store.messages.last?.content, "I will inspect before retrying.")
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

    func testBrowserControlCanRunWithoutConfirmationWhenPreferenceIsOffAcrossTurns() async {
        let router = ScriptedOpenRouter(
            scripts: [
                StubStreamScript(
                    events: [
                        .toolCall(
                            toolCallDelta(
                                id: "inspect_1",
                                functionName: "browser_inspect",
                                arguments: "{}"
                            )
                        ),
                        .finishReason(.toolCalls),
                        .completed
                    ]
                ),
                StubStreamScript(
                    events: [.text("I inspected the tab."), .finishReason(.stop), .completed]
                ),
                StubStreamScript(
                    events: [
                        .toolCall(
                            toolCallDelta(
                                id: "click_2",
                                functionName: "browser_click",
                                arguments: #"{"tab_id":42,"snapshot_id":"page:2","element_id":"e4"}"#
                            )
                        ),
                        .finishReason(.toolCalls),
                        .completed
                    ]
                ),
                StubStreamScript(
                    events: [.text("I clicked it."), .finishReason(.stop), .completed]
                )
            ]
        )
        let actionService = StubActionService(toolResultMessage: "Browser state")
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

        store.submit("Inspect the tab")
        await waitUntil { !store.isResponding }
        XCTAssertEqual(actionService.executionCount, 1)

        store.submit("Click the requested control")
        await waitUntil { !store.isResponding }
        XCTAssertNil(store.pendingAction)
        XCTAssertEqual(actionService.executionCount, 2)
        XCTAssertEqual(store.messages.last?.content, "I clicked it.")
    }

    func testDefaultConfirmationPausesAndDeclinePreventsExecution() async {
        let router = ScriptedOpenRouter(
            scripts: [
                StubStreamScript(
                    events: [
                        .toolCall(toolCallDelta(id: "declined_action")),
                        .finishReason(.toolCalls),
                        .completed
                    ]
                ),
                StubStreamScript(
                    events: [.text("Nothing was changed."), .finishReason(.stop), .completed]
                )
            ]
        )
        let actionService = StubActionService()
        let defaults = isolatedDefaults()
        defaults.set(false, forKey: PreferenceKeys.speakResponses)
        defaults.set(true, forKey: PreferenceKeys.confirmActions)
        let store = AssistantStore(
            openRouter: router,
            keychain: StubAPIKeyStore(key: "test-key"),
            actionService: actionService,
            speechController: SpeechController(engine: FakeSpeechEngine()),
            defaults: defaults
        )

        store.submit("Copy this only if I approve")
        await waitUntil { store.pendingAction != nil }
        XCTAssertEqual(actionService.executionCount, 0)

        store.resolvePendingAction(approved: false)
        await waitUntil { !store.isResponding }

        XCTAssertEqual(actionService.executionCount, 0)
        XCTAssertNil(store.pendingAction)
        XCTAssertEqual(store.messages.last?.content, "Nothing was changed.")
    }

    func testEachIterativeActionRequiresFreshApproval() async {
        let router = ScriptedOpenRouter(
            scripts: [
                StubStreamScript(
                    events: [
                        .toolCall(toolCallDelta(id: "action_1")),
                        .finishReason(.toolCalls),
                        .completed
                    ]
                ),
                StubStreamScript(
                    events: [
                        .toolCall(toolCallDelta(id: "action_2")),
                        .finishReason(.toolCalls),
                        .completed
                    ]
                ),
                StubStreamScript(
                    events: [.text("Both actions finished."), .finishReason(.stop), .completed]
                )
            ]
        )
        let actionService = StubActionService()
        let defaults = isolatedDefaults()
        defaults.set(false, forKey: PreferenceKeys.speakResponses)
        defaults.set(true, forKey: PreferenceKeys.confirmActions)
        let store = AssistantStore(
            openRouter: router,
            keychain: StubAPIKeyStore(key: "test-key"),
            actionService: actionService,
            speechController: SpeechController(engine: FakeSpeechEngine()),
            defaults: defaults
        )

        store.submit("Run two sequential actions")
        await waitUntil { store.pendingAction != nil }
        store.resolvePendingAction(approved: true)

        await waitUntil {
            actionService.executionCount == 1 && store.pendingAction != nil
        }
        XCTAssertTrue(store.isResponding)
        store.resolvePendingAction(approved: true)
        await waitUntil { !store.isResponding }

        XCTAssertEqual(actionService.executionCount, 2)
        XCTAssertNil(store.pendingAction)
        XCTAssertEqual(store.messages.last?.content, "Both actions finished.")
    }

    func testMultipleToolCallsInOneRoundRunNoActions() async {
        let router = ScriptedOpenRouter(
            scripts: [
                StubStreamScript(
                    events: [
                        .toolCall(toolCallDelta(index: 0, id: "action_1")),
                        .toolCall(toolCallDelta(index: 1, id: "action_2")),
                        .finishReason(.toolCalls),
                        .completed
                    ]
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

        store.submit("Do not batch actions")
        await waitUntil { !store.isResponding }

        XCTAssertEqual(actionService.executionCount, 0)
        XCTAssertTrue(store.lastError?.contains("multiple actions") == true)
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

    func testActionBudgetReservesFinalToolFreeSynthesisRound() async {
        var scripts = (0..<12).map { index in
            StubStreamScript(
                events: [
                    .toolCall(toolCallDelta(id: "call_\(index)")),
                    .finishReason(.toolCalls),
                    .completed
                ]
            )
        }
        scripts.append(
            StubStreamScript(
                events: [.text("Finished after the action budget."), .finishReason(.stop), .completed]
            )
        )
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

        XCTAssertEqual(router.configurations.count, 13)
        XCTAssertEqual(actionService.executionCount, 12)
        XCTAssertEqual(store.messages.last?.activities.count, 12)
        XCTAssertEqual(store.messages.last?.deliveryState, .complete)
        XCTAssertEqual(store.messages.last?.content, "Finished after the action budget.")
        XCTAssertFalse(router.configurations[11].tools.isEmpty)
        XCTAssertTrue(router.configurations[12].tools.isEmpty)
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
        index: Int = 0,
        id: String,
        functionName: String = "copy_to_clipboard",
        arguments: String = #"{"text":"Test text"}"#
    ) -> OpenRouterToolCallDelta {
        OpenRouterToolCallDelta(
            index: index,
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
