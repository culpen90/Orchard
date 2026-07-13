@testable import Orchard

@MainActor
final class FakeSpeechEngine: SpeechEngine {
    var startResult = true
    var pauseResult = true
    var continueResult = true
    var stopResult = true

    private(set) var spokenTexts: [String] = []
    private(set) var configurations: [SpeechConfiguration] = []
    private(set) var eventHandlers: [SpeechEventHandler] = []
    private(set) var pauseCallCount = 0
    private(set) var continueCallCount = 0
    private(set) var stopCallCount = 0

    func startSpeaking(
        _ text: String,
        configuration: SpeechConfiguration,
        eventHandler: @escaping SpeechEventHandler
    ) -> Bool {
        guard startResult else {
            return false
        }
        spokenTexts.append(text)
        configurations.append(configuration)
        eventHandlers.append(eventHandler)
        return true
    }

    func pauseSpeaking() -> Bool {
        pauseCallCount += 1
        return pauseResult
    }

    func continueSpeaking() -> Bool {
        continueCallCount += 1
        return continueResult
    }

    func stopSpeaking() -> Bool {
        stopCallCount += 1
        return stopResult
    }

    func emit(_ event: SpeechEngineEvent, forRequestAt index: Int) {
        eventHandlers[index](event)
    }
}
