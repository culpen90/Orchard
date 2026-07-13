// Adapted from SpeakPad at f6d97465a96e707ac3c3e168e0097195ec9ea65c.
// Copyright (c) 2026 culpen90. MIT licensed; see ThirdParty/SpeakPad/LICENSE.

import AVFAudio
import Foundation

@MainActor
final class SystemSpeechEngine: NSObject, SpeechEngine, AVSpeechSynthesizerDelegate {
    private struct Session {
        let utteranceID: ObjectIdentifier
        let eventHandler: SpeechEventHandler
    }

    private let synthesizer = AVSpeechSynthesizer()
    private var session: Session?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    @discardableResult
    func startSpeaking(
        _ text: String,
        eventHandler: @escaping SpeechEventHandler
    ) -> Bool {
        guard text.contains(where: { !$0.isWhitespace }) else {
            return false
        }

        if session != nil {
            stopSpeaking()
        }

        let utterance = AVSpeechUtterance(string: text)
        utterance.prefersAssistiveTechnologySettings = true
        session = Session(
            utteranceID: ObjectIdentifier(utterance),
            eventHandler: eventHandler
        )
        synthesizer.speak(utterance)
        return true
    }

    @discardableResult
    func pauseSpeaking() -> Bool {
        synthesizer.pauseSpeaking(at: .immediate)
    }

    @discardableResult
    func continueSpeaking() -> Bool {
        synthesizer.continueSpeaking()
    }

    @discardableResult
    func stopSpeaking() -> Bool {
        session = nil
        return synthesizer.stopSpeaking(at: .immediate)
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didStart utterance: AVSpeechUtterance
    ) {
        enqueue(.started, for: utterance)
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didPause utterance: AVSpeechUtterance
    ) {
        enqueue(.paused, for: utterance)
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didContinue utterance: AVSpeechUtterance
    ) {
        enqueue(.continued, for: utterance)
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        enqueue(.finished, for: utterance, isTerminal: true)
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        enqueue(.cancelled, for: utterance, isTerminal: true)
    }

    private nonisolated func enqueue(
        _ event: SpeechEngineEvent,
        for utterance: AVSpeechUtterance,
        isTerminal: Bool = false
    ) {
        let utteranceID = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            self?.deliver(event, for: utteranceID, isTerminal: isTerminal)
        }
    }

    private func deliver(
        _ event: SpeechEngineEvent,
        for utteranceID: ObjectIdentifier,
        isTerminal: Bool
    ) {
        guard let session, session.utteranceID == utteranceID else {
            return
        }

        if isTerminal {
            self.session = nil
        }
        session.eventHandler(event)
    }
}
