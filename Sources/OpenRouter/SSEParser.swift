import Foundation

struct SSEEventParser: Sendable {
    private var dataLines: [String] = []

    mutating func consume(line rawLine: String) -> String? {
        let line = rawLine.last == "\r" ? String(rawLine.dropLast()) : rawLine

        if line.isEmpty {
            return flush()
        }

        if line.hasPrefix(":") {
            return nil
        }

        let separator = line.firstIndex(of: ":")
        let field: Substring
        var value: Substring
        if let separator {
            field = line[..<separator]
            value = line[line.index(after: separator)...]
            if value.first == " " {
                value = value.dropFirst()
            }
        } else {
            field = Substring(line)
            value = ""
        }

        if field == "data" {
            dataLines.append(String(value))
        }
        return nil
    }

    mutating func finish() -> String? {
        flush()
    }

    private mutating func flush() -> String? {
        guard !dataLines.isEmpty else {
            return nil
        }
        let payload = dataLines.joined(separator: "\n")
        dataLines.removeAll(keepingCapacity: true)
        return payload
    }
}

enum OpenRouterStreamDecoder {
    static func decode(payload: String) throws -> [OpenRouterStreamEvent] {
        if payload.trimmingCharacters(in: .whitespacesAndNewlines) == "[DONE]" {
            return [.completed]
        }

        guard let data = payload.data(using: .utf8) else {
            throw OpenRouterError.malformedStream("A stream event was not valid UTF-8.")
        }

        let chunk: StreamChunk
        do {
            chunk = try JSONDecoder().decode(StreamChunk.self, from: data)
        } catch {
            throw OpenRouterError.malformedStream(
                "OpenRouter sent a stream event Orchard could not decode."
            )
        }

        if let error = chunk.error {
            throw OpenRouterError.api(
                code: error.code?.description,
                message: error.message
            )
        }

        var events: [OpenRouterStreamEvent] = []
        for choice in chunk.choices ?? [] {
            if let error = choice.error {
                throw OpenRouterError.api(
                    code: error.code?.description,
                    message: error.message
                )
            }
            if let reasoning = choice.delta?.reasoning, !reasoning.isEmpty {
                events.append(.reasoning(reasoning))
            }
            if let reasoningDetails = choice.delta?.reasoningDetails,
               !reasoningDetails.isEmpty
            {
                events.append(.reasoningDetails(reasoningDetails))
            }
            if let content = choice.delta?.content, !content.isEmpty {
                events.append(.text(content))
            }
            for toolCall in choice.delta?.toolCalls ?? [] {
                events.append(
                    .toolCall(
                        OpenRouterToolCallDelta(
                            index: toolCall.index,
                            id: toolCall.id,
                            type: toolCall.type,
                            functionName: toolCall.function?.name,
                            arguments: toolCall.function?.arguments
                        )
                    )
                )
            }
            if choice.finishReason == "error" {
                throw OpenRouterError.api(
                    code: nil,
                    message: "The model provider ended the response with an error."
                )
            }
            if let finishReason = choice.finishReason {
                events.append(
                    .finishReason(OpenRouterFinishReason(rawValue: finishReason))
                )
            }
        }
        return events
    }
}

private struct StreamChunk: Decodable {
    let choices: [StreamChoice]?
    let error: OpenRouterAPIErrorPayload?
}

private struct StreamChoice: Decodable {
    let delta: StreamDelta?
    let finishReason: String?
    let error: OpenRouterAPIErrorPayload?

    enum CodingKeys: String, CodingKey {
        case delta
        case finishReason = "finish_reason"
        case error
    }
}

private struct StreamDelta: Decodable {
    let content: String?
    let reasoning: String?
    let reasoningDetails: [JSONValue]?
    let toolCalls: [StreamToolCallDelta]?

    enum CodingKeys: String, CodingKey {
        case content
        case reasoning
        case reasoningDetails = "reasoning_details"
        case toolCalls = "tool_calls"
    }
}

private struct StreamToolCallDelta: Decodable {
    let index: Int
    let id: String?
    let type: String?
    let function: StreamFunctionDelta?
}

private struct StreamFunctionDelta: Decodable {
    let name: String?
    let arguments: String?
}

struct OpenRouterAPIErrorPayload: Decodable, Sendable {
    let code: LossyString?
    let message: String
}

enum LossyString: Decodable, Sendable, CustomStringConvertible {
    case string(String)
    case integer(Int)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            self = .integer(try container.decode(Int.self))
        }
    }

    var description: String {
        switch self {
        case .string(let value):
            value
        case .integer(let value):
            String(value)
        }
    }
}

struct OpenRouterToolCallAccumulator: Sendable {
    private struct PartialCall: Sendable {
        var id = ""
        var type = ""
        var functionName = ""
        var arguments = ""
    }

    private var partialCalls: [Int: PartialCall] = [:]

    var isEmpty: Bool {
        partialCalls.isEmpty
    }

    mutating func merge(_ delta: OpenRouterToolCallDelta) {
        var partial = partialCalls[delta.index] ?? PartialCall()
        if let id = delta.id, !id.isEmpty {
            partial.id = id
        }
        if let type = delta.type, !type.isEmpty {
            partial.type = type
        }
        if let functionName = delta.functionName {
            partial.functionName += functionName
        }
        if let arguments = delta.arguments {
            partial.arguments += arguments
        }
        partialCalls[delta.index] = partial
    }

    func completedCalls() throws -> [OpenRouterToolCall] {
        try partialCalls.keys.sorted().map { index in
            guard let partial = partialCalls[index] else {
                throw OpenRouterError.malformedToolCall
            }
            guard !partial.id.isEmpty, !partial.functionName.isEmpty else {
                throw OpenRouterError.malformedToolCall
            }
            return OpenRouterToolCall(
                id: partial.id,
                type: partial.type.isEmpty ? "function" : partial.type,
                function: OpenRouterFunctionCall(
                    name: partial.functionName,
                    arguments: partial.arguments.isEmpty ? "{}" : partial.arguments
                )
            )
        }
    }
}
