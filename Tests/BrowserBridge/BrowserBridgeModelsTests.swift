import XCTest
@testable import Orchard

final class BrowserBridgeModelsTests: XCTestCase {
    func testValidationCapsAndCleansBrowserContent() throws {
        let items = (0..<12).map { index in
            BrowserSearchItem(
                title: " Result \(index) ",
                url: "https://example.com/\(index)",
                snippet: " Snippet \(index) "
            )
        }
        let result = BrowserSearchResult(
            pageTitle: " Search ",
            pageURL: "https://www.google.com/search?q=test",
            visibleText: String(repeating: "x", count: 35_000),
            results: items
        )

        let validated = try result.validated()

        XCTAssertEqual(validated.pageTitle, "Search")
        XCTAssertEqual(validated.results.count, 8)
        XCTAssertEqual(validated.results.first?.title, "Result 0")
        XCTAssertEqual(validated.visibleText.count, 30_000)
    }

    func testValidationRejectsNonWebResultURL() {
        let result = BrowserSearchResult(
            pageTitle: "Search",
            pageURL: "https://www.google.com/search?q=test",
            visibleText: "Result",
            results: [
                BrowserSearchItem(
                    title: "Local file",
                    url: "file:///etc/passwd",
                    snippet: "Unsafe"
                )
            ]
        )

        XCTAssertThrowsError(try result.validated()) { error in
            XCTAssertEqual(error as? BrowserBridgeError, .invalidResponseURL)
        }
    }

    func testToolMessageLabelsEvidenceAsUntrustedAndPreservesSources() throws {
        let result = BrowserSearchResult(
            pageTitle: "Search",
            pageURL: "https://www.google.com/search?q=latest",
            visibleText: "Current information",
            results: [
                BrowserSearchItem(
                    title: "Primary source",
                    url: "https://example.com/source",
                    snippet: "Evidence"
                )
            ]
        )

        let message = try result.toolMessage(for: "latest information")

        XCTAssertTrue(message.contains("untrusted web search evidence"))
        XCTAssertTrue(message.contains(#""query":"latest information""#))
        XCTAssertTrue(message.contains("https://example.com/source"))
    }
}
