import Foundation
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
        XCTAssertEqual(engine.configurations, [.default])
        XCTAssertEqual(controller.playbackState, .speaking)
    }

    func testReadPassesSpeechConfiguration() {
        let engine = FakeSpeechEngine()
        let controller = SpeechController(engine: engine)
        let configuration = SpeechConfiguration(
            voiceIdentifier: "com.apple.voice.compact.en-US.Samantha",
            rate: 0.4,
            pitch: 1.2,
            volume: 0.75
        )

        controller.read("Hello", configuration: configuration)

        XCTAssertEqual(engine.configurations, [configuration])
    }

    func testConfigurationClampsValuesToSafeSpeechRanges() {
        let configuration = SpeechConfiguration(
            voiceIdentifier: "   ",
            rate: .greatestFiniteMagnitude,
            pitch: -1,
            volume: 2
        )

        XCTAssertNil(configuration.voiceIdentifier)
        XCTAssertEqual(configuration.rate, SpeechConfiguration.maximumRate)
        XCTAssertEqual(configuration.pitch, SpeechConfiguration.minimumPitch)
        XCTAssertEqual(configuration.volume, SpeechConfiguration.maximumVolume)
    }

    func testConfigurationUsesDefaultsForNonFiniteValues() {
        let configuration = SpeechConfiguration(
            rate: .nan,
            pitch: .infinity,
            volume: -.infinity
        )

        XCTAssertEqual(configuration.rate, SpeechConfiguration.defaultRate)
        XCTAssertEqual(configuration.pitch, SpeechConfiguration.defaultPitch)
        XCTAssertEqual(configuration.volume, SpeechConfiguration.defaultVolume)
    }

    func testInstalledVoiceCatalogExposesReadableMetadata() throws {
        let voices = SpeechVoiceCatalog.installedVoices(
            locale: Locale(identifier: "en_US")
        )
        let voice = try XCTUnwrap(voices.first)

        XCTAssertEqual(voice.id, voice.identifier)
        XCTAssertFalse(voice.name.isEmpty)
        XCTAssertFalse(voice.languageCode.isEmpty)
        XCTAssertFalse(voice.languageName.isEmpty)
        XCTAssertFalse(voice.qualityName.isEmpty)
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
