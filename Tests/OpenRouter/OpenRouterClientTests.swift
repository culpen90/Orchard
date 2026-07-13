import Foundation
import XCTest
@testable import Orchard

final class OpenRouterClientTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    func testBuildsAuthenticatedStreamingRequestAndParsesResponse() async throws {
        let capturedRequest = LockedBox<URLRequest?>(nil)
        let capturedBody = LockedBox<Data?>(nil)
        MockURLProtocol.handler = { request in
            capturedRequest.set(request)
            capturedBody.set(try requestBody(request))
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            let body = """
            : OPENROUTER PROCESSING

            data: {"choices":[{"delta":{"content":"Hel"},"finish_reason":null}]}

            data: {"choices":[{"delta":{"content":"lo"},"finish_reason":null}]}

            data: [DONE]

            """
            return (response, Data(body.utf8))
        }

        let client = OpenRouterClient(session: makeSession(), endpoint: URL(string: "https://example.test/chat")!)
        let stream = client.streamChat(
            configuration: OpenRouterChatConfiguration(
                apiKey: "super-secret-key",
                modelID: "test/model",
                messages: [.user("Hi")],
                tools: []
            )
        )

        var events: [OpenRouterStreamEvent] = []
        for try await event in stream {
            events.append(event)
        }

        XCTAssertEqual(events, [.text("Hel"), .text("lo"), .completed])
        let request = try XCTUnwrap(capturedRequest.value)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer super-secret-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try XCTUnwrap(capturedBody.value)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["model"] as? String, "test/model")
        XCTAssertEqual(object["stream"] as? Bool, true)
        XCTAssertFalse(String(decoding: body, as: UTF8.self).contains("super-secret-key"))
    }

    func testHTTPErrorUsesOpenRouterMessage() async {
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 401,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(#"{"error":{"code":401,"message":"bad key"}}"#.utf8))
        }

        let client = OpenRouterClient(session: makeSession(), endpoint: URL(string: "https://example.test/chat")!)
        let stream = client.streamChat(
            configuration: OpenRouterChatConfiguration(
                apiKey: "bad",
                modelID: nil,
                messages: [.user("Hi")],
                tools: []
            )
        )

        do {
            for try await _ in stream {}
            XCTFail("Expected the stream to fail")
        } catch {
            XCTAssertEqual(
                error as? OpenRouterError,
                .http(status: 401, message: "bad key")
            )
        }
    }

    func testEncodesOpaqueReasoningDetailsForToolContinuation() async throws {
        let capturedBody = LockedBox<Data?>(nil)
        MockURLProtocol.handler = { request in
            capturedBody.set(try requestBody(request))
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            return (response, Data("data: [DONE]\n\n".utf8))
        }
        let detail = try JSONDecoder().decode(
            JSONValue.self,
            from: Data(#"{"type":"reasoning.encrypted","data":"opaque","index":0}"#.utf8)
        )
        let toolCall = OpenRouterToolCall(
            id: "call_1",
            type: "function",
            function: OpenRouterFunctionCall(
                name: "copy_to_clipboard",
                arguments: #"{"text":"Hello"}"#
            )
        )
        let client = OpenRouterClient(
            session: makeSession(),
            endpoint: URL(string: "https://example.test/chat")!
        )
        let stream = client.streamChat(
            configuration: OpenRouterChatConfiguration(
                apiKey: "test-key",
                modelID: "test/model",
                messages: [
                    .assistant(
                        nil,
                        toolCalls: [toolCall],
                        reasoningDetails: [detail]
                    ),
                    .tool(callID: "call_1", content: "Copied.")
                ],
                tools: []
            )
        )

        for try await _ in stream {}

        let body = try XCTUnwrap(capturedBody.value)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
        let details = try XCTUnwrap(messages[0]["reasoning_details"] as? [[String: Any]])
        XCTAssertEqual(details[0]["type"] as? String, "reasoning.encrypted")
        XCTAssertEqual(details[0]["data"] as? String, "opaque")
        XCTAssertEqual(details[0]["index"] as? Int, 0)
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private func requestBody(_ request: URLRequest) throws -> Data? {
    if let body = request.httpBody {
        return body
    }
    guard let stream = request.httpBodyStream else {
        return nil
    }

    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count < 0 {
            throw stream.streamError ?? URLError(.cannotDecodeContentData)
        }
        if count == 0 {
            break
        }
        data.append(contentsOf: buffer.prefix(count))
    }
    return data
}

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Value

    init(_ value: Value) {
        storedValue = value
    }

    var value: Value {
        lock.withLock { storedValue }
    }

    func set(_ value: Value) {
        lock.withLock { storedValue = value }
    }
}
