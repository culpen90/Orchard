import Foundation

enum PreferenceKeys {
    static let modelID = "assistant.modelID"
    static let systemPrompt = "assistant.systemPrompt"
    static let speakResponses = "assistant.speakResponses"
    static let autoSubmitVoice = "assistant.autoSubmitVoice"
    static let confirmActions = "assistant.confirmActions"
    static let enableActions = "assistant.enableActions"
    static let onDeviceRecognition = "assistant.onDeviceRecognition"
}

struct AssistantPreferences: Equatable, Sendable {
    static let defaultModelID = "~openai/gpt-latest"
    static let defaultSystemPrompt = """
    You are Orchard, a capable, warm, and concise macOS voice assistant. Answer naturally for spoken playback. Prefer short, direct answers unless the user asks for detail. Use the provided Mac tools only when they clearly help fulfill the request. Never claim an action succeeded until its tool result confirms it.
    """

    var modelID: String
    var systemPrompt: String
    var speakResponses: Bool
    var autoSubmitVoice: Bool
    var confirmActions: Bool
    var enableActions: Bool
    var onDeviceRecognition: Bool

    static func load(from defaults: UserDefaults = .standard) -> AssistantPreferences {
        AssistantPreferences(
            modelID: modelString(defaults: defaults),
            systemPrompt: string(
                forKey: PreferenceKeys.systemPrompt,
                default: defaultSystemPrompt,
                defaults: defaults
            ),
            speakResponses: bool(
                forKey: PreferenceKeys.speakResponses,
                default: true,
                defaults: defaults
            ),
            autoSubmitVoice: bool(
                forKey: PreferenceKeys.autoSubmitVoice,
                default: true,
                defaults: defaults
            ),
            confirmActions: bool(
                forKey: PreferenceKeys.confirmActions,
                default: true,
                defaults: defaults
            ),
            enableActions: bool(
                forKey: PreferenceKeys.enableActions,
                default: true,
                defaults: defaults
            ),
            onDeviceRecognition: bool(
                forKey: PreferenceKeys.onDeviceRecognition,
                default: false,
                defaults: defaults
            )
        )
    }

    private static func string(
        forKey key: String,
        default fallback: String,
        defaults: UserDefaults
    ) -> String {
        guard let value = defaults.string(forKey: key) else {
            return fallback
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    private static func modelString(defaults: UserDefaults) -> String {
        guard let value = defaults.string(forKey: PreferenceKeys.modelID) else {
            return defaultModelID
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func bool(
        forKey key: String,
        default fallback: Bool,
        defaults: UserDefaults
    ) -> Bool {
        guard defaults.object(forKey: key) != nil else {
            return fallback
        }
        return defaults.bool(forKey: key)
    }
}
