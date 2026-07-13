import XCTest
@testable import Orchard

@MainActor
final class SpeechControllerTests: XCTestCase {
    func testReadPassesExactTextSnapshot() {
        let engine = FakeSpeechEngine()
        let controller = SpeechController(engine: engine)
        let text = "  Hello, world.\n"

        controller.read(text)

        XCTAssertEqual(engine.spokenTexts, [text])
        XCTAssertEqual(controller.playbackState, .speaking)
    }

    func testWhitespaceOnlyTextDoesNotStart() {
        let engine = FakeSpeechEngine()
        let controller = SpeechController(engine: engine)

        controller.read(" \n\t ")

        XCTAssertTrue(engine.spokenTexts.isEmpty)
        XCTAssertEqual(engine.stopCallCount, 0)
        XCTAssertEqual(controller.playbackState, .idle)
    }

    func testPauseResumeAndStop() {
        let engine = FakeSpeechEngine()
        let controller = SpeechController(engine: engine)
        controller.read("Hello")

        controller.pause()
        XCTAssertEqual(controller.playbackState, .paused)
        XCTAssertEqual(engine.pauseCallCount, 1)

        controller.resume()
        XCTAssertEqual(controller.playbackState, .speaking)
        XCTAssertEqual(engine.continueCallCount, 1)

        controller.stop()
        XCTAssertEqual(controller.playbackState, .idle)
        XCTAssertEqual(engine.stopCallCount, 2)
    }

    func testStaleCompletionCannotStopNewReading() {
        let engine = FakeSpeechEngine()
        let controller = SpeechController(engine: engine)
        controller.read("First")
        controller.stop()
        controller.read("Second")

        engine.emit(.finished, forRequestAt: 0)
        XCTAssertEqual(controller.playbackState, .speaking)

        engine.emit(.finished, forRequestAt: 1)
        XCTAssertEqual(controller.playbackState, .idle)
    }

    func testDelayedPauseEventCannotOverrideNewerResume() {
        let engine = FakeSpeechEngine()
        let controller = SpeechController(engine: engine)
        controller.read("Hello")
        controller.pause()
        controller.resume()

        engine.emit(.paused, forRequestAt: 0)

        XCTAssertEqual(controller.playbackState, .speaking)
    }

    func testStartFailureReturnsToReadyWithError() {
        let engine = FakeSpeechEngine()
        engine.startResult = false
        let controller = SpeechController(engine: engine)

        controller.read("Hello")

        XCTAssertEqual(controller.playbackState, .idle)
        XCTAssertNotNil(controller.errorMessage)
    }
}
