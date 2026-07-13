// Adapted from SpeakPad v0.2.0 at 4759c090eac120947fd785d32c60aeb41a6bbcde.
// Copyright (c) 2026 culpen90. MIT licensed; see ThirdParty/SpeakPad/LICENSE.

import AVFAudio
import Foundation

struct SpeechConfiguration: Equatable, Sendable {
    static let minimumRate = AVSpeechUtteranceMinimumSpeechRate
    static let maximumRate = AVSpeechUtteranceMaximumSpeechRate
    static let defaultRate = AVSpeechUtteranceDefaultSpeechRate
    static let minimumPitch: Float = 0.5
    static let maximumPitch: Float = 2.0
    static let defaultPitch: Float = 1.0
    static let minimumVolume: Float = 0.0
    static let maximumVolume: Float = 1.0
    static let defaultVolume: Float = 1.0

    static let `default` = SpeechConfiguration()

    let voiceIdentifier: String?
    let rate: Float
    let pitch: Float
    let volume: Float

    init(
        voiceIdentifier: String? = nil,
        rate: Float = SpeechConfiguration.defaultRate,
        pitch: Float = SpeechConfiguration.defaultPitch,
        volume: Float = SpeechConfiguration.defaultVolume
    ) {
        self.voiceIdentifier = voiceIdentifier?.trimmedOrNil
        self.rate = Self.sanitized(
            rate,
            minimum: Self.minimumRate,
            maximum: Self.maximumRate,
            fallback: Self.defaultRate
        )
        self.pitch = Self.sanitized(
            pitch,
            minimum: Self.minimumPitch,
            maximum: Self.maximumPitch,
            fallback: Self.defaultPitch
        )
        self.volume = Self.sanitized(
            volume,
            minimum: Self.minimumVolume,
            maximum: Self.maximumVolume,
            fallback: Self.defaultVolume
        )
    }

    private static func sanitized(
        _ value: Float,
        minimum: Float,
        maximum: Float,
        fallback: Float
    ) -> Float {
        guard value.isFinite else {
            return fallback
        }

        return min(max(value, minimum), maximum)
    }
}

struct SpeechVoice: Identifiable, Equatable, Sendable {
    enum Quality: Equatable, Sendable {
        case standard
        case enhanced
        case premium
        case unknown

        var displayName: String {
            switch self {
            case .standard:
                "Standard"
            case .enhanced:
                "Enhanced"
            case .premium:
                "Premium"
            case .unknown:
                "Unknown"
            }
        }
    }

    let identifier: String
    let name: String
    let languageCode: String
    let languageName: String
    let quality: Quality

    var id: String { identifier }
    var qualityName: String { quality.displayName }

    fileprivate init(
        voice: AVSpeechSynthesisVoice,
        locale: Locale
    ) {
        identifier = voice.identifier
        name = voice.name
        languageCode = voice.language
        languageName = locale.localizedString(forIdentifier: voice.language)
            ?? voice.language

        switch voice.quality {
        case .default:
            quality = .standard
        case .enhanced:
            quality = .enhanced
        case .premium:
            quality = .premium
        @unknown default:
            quality = .unknown
        }
    }
}

@MainActor
enum SpeechVoiceCatalog {
    static func installedVoices(locale: Locale = .current) -> [SpeechVoice] {
        let currentIdentifier = locale.identifier
            .split(separator: "@", maxSplits: 1)
            .first?
            .replacingOccurrences(of: "_", with: "-")
            .lowercased() ?? ""
        let currentLanguage = currentIdentifier.split(separator: "-").first

        return AVSpeechSynthesisVoice.speechVoices()
            .map { SpeechVoice(voice: $0, locale: locale) }
            .sorted {
                let leftRank = localeRank(
                    languageCode: $0.languageCode,
                    currentIdentifier: currentIdentifier,
                    currentLanguage: currentLanguage
                )
                let rightRank = localeRank(
                    languageCode: $1.languageCode,
                    currentIdentifier: currentIdentifier,
                    currentLanguage: currentLanguage
                )
                if leftRank != rightRank {
                    return leftRank < rightRank
                }

                let languageOrder = $0.languageName.localizedStandardCompare($1.languageName)
                if languageOrder == .orderedSame {
                    return $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
                return languageOrder == .orderedAscending
            }
    }

    private static func localeRank(
        languageCode: String,
        currentIdentifier: String,
        currentLanguage: Substring?
    ) -> Int {
        let normalizedCode = languageCode
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()

        if normalizedCode == currentIdentifier {
            return 0
        }
        if normalizedCode.split(separator: "-").first == currentLanguage {
            return 1
        }
        return 2
    }
}

private extension String {
    var trimmedOrNil: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

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
        configuration: SpeechConfiguration,
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
