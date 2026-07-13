import XCTest
@testable import Orchard

final class SSEParserTests: XCTestCase {
    func testIgnoresKeepaliveAndEmitsDataAtEventBoundary() {
        var parser = SSEEventParser()

        XCTAssertNil(parser.consume(line: ": OPENROUTER PROCESSING"))
        XCTAssertNil(parser.consume(line: ""))
        XCTAssertNil(parser.consume(line: "data: {\"hello\":true}"))
        XCTAssertEqual(parser.consume(line: ""), "{\"hello\":true}")
    }

    func testJoinsMultipleDataLinesAndAcceptsCRLF() {
        var parser = SSEEventParser()

        XCTAssertNil(parser.consume(line: "data: first\r"))
        XCTAssertNil(parser.consume(line: "data:second\r"))
        XCTAssertEqual(parser.consume(line: "\r"), "first\nsecond")
    }

    func testDecodesTextAndIgnoresRoleAndUsageOnlyChunks() throws {
        let text = try OpenRouterStreamDecoder.decode(payload: """
        {"choices":[{"delta":{"role":"assistant","content":"Hello"},"finish_reason":null}]}
        """)
        let roleOnly = try OpenRouterStreamDecoder.decode(payload: """
        {"choices":[{"delta":{"role":"assistant"},"finish_reason":null}]}
        """)
        let usageOnly = try OpenRouterStreamDecoder.decode(payload: """
        {"choices":[],"usage":{"prompt_tokens":2,"completion_tokens":1,"total_tokens":3}}
        """)

        XCTAssertEqual(text, [.text("Hello")])
        XCTAssertTrue(roleOnly.isEmpty)
        XCTAssertTrue(usageOnly.isEmpty)
        XCTAssertEqual(try OpenRouterStreamDecoder.decode(payload: "[DONE]"), [.completed])
    }

    func testReassemblesFragmentedToolCallArguments() throws {
        let first = try OpenRouterStreamDecoder.decode(payload: """
        {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"search_web","arguments":"{\\\"query\\\":"}}]}}]}
        """)
        let second = try OpenRouterStreamDecoder.decode(payload: """
        {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\\\"orchards\\\"}"}}]}}]}
        """)

        var accumulator = OpenRouterToolCallAccumulator()
        for event in first + second {
            if case .toolCall(let delta) = event {
                accumulator.merge(delta)
            }
        }

        let calls = try accumulator.completedCalls()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].function.name, "search_web")
        XCTAssertEqual(calls[0].function.arguments, "{\"query\":\"orchards\"}")
    }

    func testPreservesReasoningDetailsAndFinishReason() throws {
        let events = try OpenRouterStreamDecoder.decode(payload: """
        {
          "choices": [{
            "delta": {
              "reasoning": "Checking the request.",
              "reasoning_details": [{
                "type": "reasoning.encrypted",
                "data": "opaque-value",
                "id": "reasoning-1",
                "format": "anthropic-claude-v1",
                "index": 0
              }]
            },
            "finish_reason": "tool_calls"
          }]
        }
        """)
        let expectedDetail = try JSONDecoder().decode(
            JSONValue.self,
            from: Data("""
            {
              "type": "reasoning.encrypted",
              "data": "opaque-value",
              "id": "reasoning-1",
              "format": "anthropic-claude-v1",
              "index": 0
            }
            """.utf8)
        )

        XCTAssertEqual(
            events,
            [
                .reasoning("Checking the request."),
                .reasoningDetails([expectedDetail]),
                .finishReason(.toolCalls)
            ]
        )
    }

    func testDecodesNonSuccessFinishReasons() throws {
        let length = try OpenRouterStreamDecoder.decode(payload: """
        {"choices":[{"delta":{},"finish_reason":"length"}]}
        """)
        let filtered = try OpenRouterStreamDecoder.decode(payload: """
        {"choices":[{"delta":{},"finish_reason":"content_filter"}]}
        """)

        XCTAssertEqual(length, [.finishReason(.length)])
        XCTAssertEqual(filtered, [.finishReason(.contentFilter)])
    }

    func testSurfacesTopLevelMidstreamError() {
        XCTAssertThrowsError(
            try OpenRouterStreamDecoder.decode(payload: """
            {"error":{"code":"server_error","message":"Provider disconnected"},"choices":[]}
            """)
        ) { error in
            XCTAssertEqual(
                error as? OpenRouterError,
                .api(code: "server_error", message: "Provider disconnected")
            )
        }
    }

    func testMalformedJSONIsAnError() {
        XCTAssertThrowsError(try OpenRouterStreamDecoder.decode(payload: "not json"))
    }
}
