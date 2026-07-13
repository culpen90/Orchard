import Foundation

protocol OpenRouterStreaming: Sendable {
    func streamChat(
        configuration: OpenRouterChatConfiguration
    ) -> AsyncThrowingStream<OpenRouterStreamEvent, any Error>
}

final class OpenRouterClient: OpenRouterStreaming, @unchecked Sendable {
    static let endpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions")!

    private let session: URLSession
    private let endpoint: URL

    init(
        session: URLSession = .shared,
        endpoint: URL = OpenRouterClient.endpoint
    ) {
        self.session = session
        self.endpoint = endpoint
    }

    func streamChat(
        configuration: OpenRouterChatConfiguration
    ) -> AsyncThrowingStream<OpenRouterStreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await performStream(
                        configuration: configuration,
                        continuation: continuation
                    )
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    private func performStream(
        configuration: OpenRouterChatConfiguration,
        continuation: AsyncThrowingStream<OpenRouterStreamEvent, any Error>.Continuation
    ) async throws {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Orchard", forHTTPHeaderField: "X-OpenRouter-Title")
        request.setValue(
            "https://github.com/culpen90/Orchard",
            forHTTPHeaderField: "HTTP-Referer"
        )

        let body = OpenRouterChatRequest(
            model: configuration.modelID,
            messages: configuration.messages,
            stream: true,
            tools: configuration.tools.isEmpty ? nil : configuration.tools,
            parallelToolCalls: configuration.tools.isEmpty ? nil : false
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (bytes, response) = try await session.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenRouterError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = try await Self.readErrorMessage(from: bytes)
            throw OpenRouterError.http(
                status: httpResponse.statusCode,
                message: message
            )
        }

        var parser = SSEEventParser()
        var receivedCompletion = false
        var lineData = Data()
        lineData.reserveCapacity(2_048)

        for try await byte in bytes {
            try Task.checkCancellation()
            guard byte == 0x0A else {
                lineData.append(byte)
                if lineData.count > 8_388_608 {
                    throw OpenRouterError.malformedStream(
                        "OpenRouter sent an unexpectedly large stream event."
                    )
                }
                continue
            }

            guard let line = String(data: lineData, encoding: .utf8) else {
                throw OpenRouterError.malformedStream(
                    "A stream event was not valid UTF-8."
                )
            }
            lineData.removeAll(keepingCapacity: true)

            if let payload = parser.consume(line: line),
               try process(payload: payload, continuation: continuation)
            {
                receivedCompletion = true
                break
            }
        }

        if !receivedCompletion, !lineData.isEmpty {
            guard let line = String(data: lineData, encoding: .utf8) else {
                throw OpenRouterError.malformedStream(
                    "A stream event was not valid UTF-8."
                )
            }
            if let payload = parser.consume(line: line) {
                receivedCompletion = try process(
                    payload: payload,
                    continuation: continuation
                )
            }
        }

        if !receivedCompletion, let payload = parser.finish() {
            receivedCompletion = try process(
                payload: payload,
                continuation: continuation
            )
        }

        guard receivedCompletion else {
            throw OpenRouterError.truncatedStream
        }
        continuation.finish()
    }

    @discardableResult
    private func process(
        payload: String,
        continuation: AsyncThrowingStream<OpenRouterStreamEvent, any Error>.Continuation
    ) throws -> Bool {
        let events = try OpenRouterStreamDecoder.decode(payload: payload)
        for event in events {
            continuation.yield(event)
            if event == .completed {
                return true
            }
        }
        return false
    }

    private static func readErrorMessage(
        from bytes: URLSession.AsyncBytes
    ) async throws -> String {
        var data = Data()
        data.reserveCapacity(1_024)
        for try await byte in bytes {
            data.append(byte)
            if data.count >= 1_048_576 {
                break
            }
        }

        if let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data) {
            return envelope.error.message
        }
        if let text = String(data: data, encoding: .utf8) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return "OpenRouter rejected the request."
    }
}

private struct ErrorEnvelope: Decodable {
    let error: OpenRouterAPIErrorPayload
}

enum OpenRouterError: LocalizedError, Equatable, Sendable {
    case invalidResponse
    case http(status: Int, message: String)
    case api(code: String?, message: String)
    case malformedStream(String)
    case malformedToolCall
    case truncatedStream

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "OpenRouter returned an invalid response."
        case .http(let status, let message):
            switch status {
            case 401:
                "OpenRouter rejected the API key. Check it in Settings."
            case 402:
                "This OpenRouter account does not have enough credits for the selected model."
            case 429:
                "OpenRouter is rate limiting requests. Wait a moment and try again."
            default:
                "OpenRouter error \(status): \(message)"
            }
        case .api(let code, let message):
            if let code {
                "OpenRouter error \(code): \(message)"
            } else {
                "OpenRouter error: \(message)"
            }
        case .malformedStream(let message):
            message
        case .malformedToolCall:
            "The model returned an incomplete Mac action."
        case .truncatedStream:
            "The OpenRouter response ended before it was complete."
        }
    }
}
