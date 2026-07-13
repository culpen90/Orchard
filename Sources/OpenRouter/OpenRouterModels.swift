import Foundation

enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case integer(Int64)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .integer(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }
}

enum OpenRouterRole: String, Codable, Sendable {
    case system
    case user
    case assistant
    case tool
}

struct OpenRouterMessage: Codable, Equatable, Sendable {
    let role: OpenRouterRole
    let content: String?
    let toolCalls: [OpenRouterToolCall]?
    let toolCallID: String?
    let reasoning: String?
    let reasoningDetails: [JSONValue]?

    enum CodingKeys: String, CodingKey {
        case role
        case content
        case toolCalls = "tool_calls"
        case toolCallID = "tool_call_id"
        case reasoning
        case reasoningDetails = "reasoning_details"
    }

    static func system(_ content: String) -> OpenRouterMessage {
        OpenRouterMessage(
            role: .system,
            content: content,
            toolCalls: nil,
            toolCallID: nil,
            reasoning: nil,
            reasoningDetails: nil
        )
    }

    static func user(_ content: String) -> OpenRouterMessage {
        OpenRouterMessage(
            role: .user,
            content: content,
            toolCalls: nil,
            toolCallID: nil,
            reasoning: nil,
            reasoningDetails: nil
        )
    }

    static func assistant(
        _ content: String?,
        toolCalls: [OpenRouterToolCall]? = nil,
        reasoning: String? = nil,
        reasoningDetails: [JSONValue]? = nil
    ) -> OpenRouterMessage {
        OpenRouterMessage(
            role: .assistant,
            content: content,
            toolCalls: toolCalls,
            toolCallID: nil,
            reasoning: reasoning,
            reasoningDetails: reasoningDetails
        )
    }

    static func tool(callID: String, content: String) -> OpenRouterMessage {
        OpenRouterMessage(
            role: .tool,
            content: content,
            toolCalls: nil,
            toolCallID: callID,
            reasoning: nil,
            reasoningDetails: nil
        )
    }
}

struct OpenRouterToolCall: Codable, Equatable, Sendable {
    let id: String
    let type: String
    let function: OpenRouterFunctionCall
}

struct OpenRouterFunctionCall: Codable, Equatable, Sendable {
    let name: String
    let arguments: String
}

struct OpenRouterToolDefinition: Encodable, Equatable, Sendable {
    let type: String
    let function: OpenRouterFunctionDefinition

    init(function: OpenRouterFunctionDefinition) {
        type = "function"
        self.function = function
    }
}

struct OpenRouterFunctionDefinition: Encodable, Equatable, Sendable {
    let name: String
    let description: String
    let parameters: OpenRouterToolParameters
}

struct OpenRouterToolParameters: Encodable, Equatable, Sendable {
    let type: String
    let properties: [String: OpenRouterToolProperty]
    let required: [String]
    let additionalProperties: Bool

    init(
        properties: [String: OpenRouterToolProperty],
        required: [String]
    ) {
        type = "object"
        self.properties = properties
        self.required = required
        additionalProperties = false
    }

    enum CodingKeys: String, CodingKey {
        case type
        case properties
        case required
        case additionalProperties = "additionalProperties"
    }
}

struct OpenRouterToolProperty: Encodable, Equatable, Sendable {
    let type: String
    let description: String

    static func string(_ description: String) -> OpenRouterToolProperty {
        OpenRouterToolProperty(type: "string", description: description)
    }
}

struct OpenRouterChatConfiguration: Sendable {
    let apiKey: String
    let modelID: String?
    let messages: [OpenRouterMessage]
    let tools: [OpenRouterToolDefinition]
}

enum OpenRouterStreamEvent: Equatable, Sendable {
    case text(String)
    case reasoning(String)
    case reasoningDetails([JSONValue])
    case toolCall(OpenRouterToolCallDelta)
    case finishReason(OpenRouterFinishReason)
    case completed
}

enum OpenRouterFinishReason: Equatable, Sendable {
    case stop
    case toolCalls
    case length
    case contentFilter
    case other(String)

    init(rawValue: String) {
        switch rawValue {
        case "stop":
            self = .stop
        case "tool_calls":
            self = .toolCalls
        case "length":
            self = .length
        case "content_filter":
            self = .contentFilter
        default:
            self = .other(rawValue)
        }
    }
}

struct OpenRouterToolCallDelta: Equatable, Sendable {
    let index: Int
    let id: String?
    let type: String?
    let functionName: String?
    let arguments: String?
}

struct OpenRouterChatRequest: Encodable, Sendable {
    let model: String?
    let messages: [OpenRouterMessage]
    let stream: Bool
    let tools: [OpenRouterToolDefinition]?
    let parallelToolCalls: Bool?

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case stream
        case tools
        case parallelToolCalls = "parallel_tool_calls"
    }
}
