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

    func testBrowserSearchReturnsEvidenceForTheNextModelRound() async throws {
        let browserSearch = StubBrowserSearch(
            result: BrowserSearchResult(
                pageTitle: "orchard trees - Google Search",
                pageURL: "https://www.google.com/search?q=orchard+trees",
                visibleText: "Orchards are planted collections of trees.",
                results: [
                    BrowserSearchItem(
                        title: "Orchard",
                        url: "https://example.com/orchard",
                        snippet: "A planted area of fruit trees."
                    )
                ]
            )
        )
        let service = MacActionService(browserSearch: browserSearch)
        let proposal = try service.prepare(
            toolCall: call(
                name: "search_web",
                arguments: #"{"query":"what is an orchard"}"#
            )
        )

        XCTAssertEqual(proposal.kind, .searchWeb(query: "what is an orchard"))

        let actionResult = try await service.execute(proposal)
        let queries = await browserSearch.queries()

        XCTAssertEqual(queries, ["what is an orchard"])
        XCTAssertEqual(actionResult.activityDescription, "Researched the web in Chrome")
        XCTAssertTrue(actionResult.toolMessage.contains("untrusted web search evidence"))
        XCTAssertTrue(actionResult.toolMessage.contains("https://example.com/orchard"))
        XCTAssertTrue(actionResult.toolMessage.contains("A planted area of fruit trees."))
    }

    private func call(name: String, arguments: String) -> OpenRouterToolCall {
        OpenRouterToolCall(
            id: "call_1",
            type: "function",
            function: OpenRouterFunctionCall(name: name, arguments: arguments)
        )
    }
}
