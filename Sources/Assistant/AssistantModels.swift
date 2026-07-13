import Foundation

enum ChatRole: String, Sendable {
    case user
    case assistant
}

enum ChatDeliveryState: Equatable, Sendable {
    case complete
    case streaming
    case interrupted
}

struct ChatMessage: Identifiable, Equatable, Sendable {
    let id: UUID
    let role: ChatRole
    var content: String
    var activities: [String]
    var deliveryState: ChatDeliveryState

    init(
        id: UUID = UUID(),
        role: ChatRole,
        content: String,
        activities: [String] = [],
        deliveryState: ChatDeliveryState = .complete
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.activities = activities
        self.deliveryState = deliveryState
    }
}

enum AssistantStatus: Equatable, Sendable {
    case ready
    case listening
    case thinking(String)
    case awaitingConfirmation
    case speaking
    case paused

    var title: String {
        switch self {
        case .ready:
            "Ready"
        case .listening:
            "Listening"
        case .thinking(let activity):
            activity
        case .awaitingConfirmation:
            "Waiting for you"
        case .speaking:
            "Speaking"
        case .paused:
            "Speech paused"
        }
    }

    var symbolName: String {
        switch self {
        case .ready:
            "sparkles"
        case .listening:
            "waveform"
        case .thinking:
            "ellipsis"
        case .awaitingConfirmation:
            "checkmark.shield"
        case .speaking:
            "speaker.wave.2.fill"
        case .paused:
            "pause.fill"
        }
    }
}
