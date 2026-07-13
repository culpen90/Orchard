import XCTest
@testable import Orchard

@MainActor
final class MacActionServiceTests: XCTestCase {
    private let service = MacActionService()

    func testPreparesHTTPSURLForConfirmation() throws {
        let proposal = try service.prepare(
            toolCall: call(
                name: "open_url",
                arguments: #"{"url":"https://example.com/path?source=orchard"}"#
            )
        )

        XCTAssertEqual(proposal.title, "Open this website?")
        XCTAssertEqual(proposal.detail, "https://example.com/path?source=orchard")
        XCTAssertEqual(
            proposal.kind,
            .openURL(URL(string: "https://example.com/path?source=orchard")!)
        )
    }

    func testRejectsNonHTTPSURL() {
        XCTAssertThrowsError(
            try service.prepare(
                toolCall: call(name: "open_url", arguments: #"{"url":"file:///etc/passwd"}"#)
            )
        )
    }

    func testRejectsUnexpectedArguments() {
        XCTAssertThrowsError(
            try service.prepare(
                toolCall: call(
                    name: "search_web",
                    arguments: #"{"query":"orchards","shell":"rm -rf"}"#
                )
            )
        )
    }

    func testRejectsUnknownTool() {
        XCTAssertThrowsError(
            try service.prepare(toolCall: call(name: "run_shell", arguments: "{}"))
        )
    }

    private func call(name: String, arguments: String) -> OpenRouterToolCall {
        OpenRouterToolCall(
            id: "call_1",
            type: "function",
            function: OpenRouterFunctionCall(name: name, arguments: arguments)
        )
    }
}
