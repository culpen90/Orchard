// Adapted from SpeakPad v0.2.0 at 4759c090eac120947fd785d32c60aeb41a6bbcde.
// Copyright (c) 2026 culpen90. MIT licensed; see ThirdParty/SpeakPad/LICENSE.

import Foundation
import Observation

@MainActor
@Observable
final class SpeechController {
    private(set) var playbackState: PlaybackState = .idle
    private(set) var errorMessage: String?

    @ObservationIgnored private let engine: any SpeechEngine
    @ObservationIgnored private var generation: UInt = 0

    init(engine: (any SpeechEngine)? = nil) {
        self.engine = engine ?? SystemSpeechEngine()
    }

    func read(
        _ text: String,
        configuration: SpeechConfiguration = .default
    ) {
        guard text.contains(where: { !$0.isWhitespace }) else {
            return
        }

        generation &+= 1
        let currentGeneration = generation
        engine.stopSpeaking()
        errorMessage = nil
        playbackState = .speaking

        let didStart = engine.startSpeaking(
            text,
            configuration: configuration
        ) { [weak self] event in
            self?.handle(event, generation: currentGeneration)
        }

        guard didStart else {
            playbackState = .idle
            errorMessage = "Your Mac could not start reading this response."
            return
        }
    }

    func pause() {
        guard playbackState == .speaking else {
            return
        }

        if engine.pauseSpeaking() {
            playbackState = .paused
        } else {
            playbackState = .idle
        }
    }

    func resume() {
        guard playbackState == .paused else {
            return
        }

        if engine.continueSpeaking() {
            playbackState = .speaking
        } else {
            playbackState = .idle
        }
    }

    func stop() {
        generation &+= 1
        engine.stopSpeaking()
        playbackState = .idle
    }

    func dismissError() {
        errorMessage = nil
    }

    private func handle(_ event: SpeechEngineEvent, generation: UInt) {
        guard generation == self.generation else {
            return
        }

        switch event {
        case .started, .paused, .continued:
            // Button actions update these states synchronously. Ignoring delayed
            // delegate echoes prevents an older pause from overriding a newer resume.
            break
        case .finished, .cancelled:
            playbackState = .idle
        }
    }
}
