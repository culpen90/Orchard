// Adapted from SpeakPad at f6d97465a96e707ac3c3e168e0097195ec9ea65c.
// Copyright (c) 2026 culpen90. MIT licensed; see ThirdParty/SpeakPad/LICENSE.

import Foundation

enum SpeechEngineEvent: Sendable {
    case started
    case paused
    case continued
    case finished
    case cancelled
}

typealias SpeechEventHandler = @MainActor (SpeechEngineEvent) -> Void

@MainActor
protocol SpeechEngine: AnyObject {
    @discardableResult
    func startSpeaking(
        _ text: String,
        eventHandler: @escaping SpeechEventHandler
    ) -> Bool

    @discardableResult
    func pauseSpeaking() -> Bool

    @discardableResult
    func continueSpeaking() -> Bool

    @discardableResult
    func stopSpeaking() -> Bool
}

enum PlaybackState: Equatable, Sendable {
    case idle
    case speaking
    case paused

    var statusText: String {
        switch self {
        case .idle:
            "Ready"
        case .speaking:
            "Speaking"
        case .paused:
            "Paused"
        }
    }
}
