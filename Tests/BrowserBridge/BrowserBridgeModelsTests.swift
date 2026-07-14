import XCTest
@testable import Orchard

final class BrowserBridgeModelsTests: XCTestCase {
    func testValidationBoundsAndCleansBrowserSnapshot() throws {
        let elements = (0..<70).map { index in
            BrowserPageElement(
                id: "e\(index)",
                role: " button ",
                name: " Control \(index) ",
                tag: "button",
                type: nil,
                value: String(repeating: "v", count: 700),
                href: "https://example.com/action/\(index)",
                disabled: false,
                editable: false,
                inViewport: true,
                options: nil
            )
        }
        let result = BrowserCommandResult(
            action: .inspect,
            outcome: " Inspected ",
            page: snapshot(
                visibleText: String(repeating: "x", count: 30_000),
                elements: elements
            ),
            tabs: nil
        )

        let validated = try result.validated(for: .inspect)

        XCTAssertEqual(validated.outcome, "Inspected")
        XCTAssertEqual(validated.page?.visibleText.count, 24_000)
        XCTAssertEqual(validated.page?.elements.count, 60)
        XCTAssertEqual(validated.page?.elements.first?.role, "button")
        XCTAssertEqual(validated.page?.elements.first?.value?.count, 500)
    }

    func testValidationRejectsUnsafePageURLAndInvalidIdentifiers() {
        let unsafeResult = BrowserCommandResult(
            action: .inspect,
            outcome: "Inspected",
            page: snapshot(url: "file:///etc/passwd"),
            tabs: nil
        )

        XCTAssertThrowsError(try unsafeResult.validated(for: .inspect)) { error in
            XCTAssertEqual(error as? BrowserBridgeError, .invalidResponseURL)
        }

        let invalidIdentifierResult = BrowserCommandResult(
            action: .inspect,
            outcome: "Inspected",
            page: snapshot(snapshotID: "bad id with spaces"),
            tabs: nil
        )
        XCTAssertThrowsError(try invalidIdentifierResult.validated(for: .inspect))
    }

    func testValidationRejectsMismatchedAction() {
        let result = BrowserCommandResult(
            action: .click,
            outcome: "Clicked",
            page: snapshot(),
            tabs: nil
        )

        XCTAssertThrowsError(try result.validated(for: .inspect)) { error in
            XCTAssertEqual(error as? BrowserBridgeError, .invalidResponse)
        }
    }

    func testPostMutationObservationWarningAllowsMissingPageAndIsBounded() throws {
        let warning = "  " + String(repeating: "w", count: 1_200) + "  "
        let result = BrowserCommandResult(
            action: .navigate,
            outcome: "Navigated Chrome.",
            page: nil,
            tabs: nil,
            observationWarning: warning
        )

        let validated = try result.validated(for: .navigate)

        XCTAssertNil(validated.page)
        XCTAssertEqual(validated.observationWarning?.count, 1_000)
        XCTAssertTrue(try validated.toolMessage().contains("observationWarning"))
    }

    func testPostMutationResultRejectsMissingPageWithoutObservationWarning() {
        let actions: [BrowserCommandAction] = [
            .navigate, .click, .type, .select, .scroll, .back, .forward, .reload,
            .activateTab,
        ]

        for action in actions {
            let result = BrowserCommandResult(
                action: action,
                outcome: "Completed the browser action.",
                page: nil,
                tabs: nil
            )

            XCTAssertThrowsError(try result.validated(for: action)) { error in
                XCTAssertEqual(error as? BrowserBridgeError, .invalidResponse)
            }
        }
    }

    func testToolMessageLabelsWebsiteDataAsUntrustedAndPreservesElementIDs() throws {
        let element = BrowserPageElement(
            id: "e7",
            role: "link",
            name: "Continue",
            tag: "a",
            type: nil,
            value: nil,
            href: "https://example.com/continue",
            disabled: false,
            editable: false,
            inViewport: true,
            options: nil
        )
        let result = BrowserCommandResult(
            action: .inspect,
            outcome: "Inspected the Chrome tab.",
            page: snapshot(elements: [element]),
            tabs: nil
        )

        let message = try result.toolMessage()

        XCTAssertTrue(message.contains("untrusted website data"))
        XCTAssertTrue(message.contains(#""snapshotId":"snapshot:1""#))
        XCTAssertTrue(message.contains(#""id":"e7""#))
        XCTAssertTrue(message.contains("https://example.com/continue"))
    }

    func testCommandEnvelopeUsesProtocolV2AndCamelCaseWireFields() throws {
        let request = BrowserBridgeCommandRequest(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            command: BrowserCommand(
                action: .type,
                tabID: 42,
                expectedURL: "https://example.com/form",
                snapshotID: "snapshot:1",
                elementID: "e3",
                text: "Hello",
                clear: true,
                submit: false
            )
        )

        let data = try JSONEncoder().encode(request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let command = try XCTUnwrap(object["command"] as? [String: Any])

        XCTAssertEqual(object["version"] as? Int, 2)
        XCTAssertEqual(object["type"] as? String, "browser.command")
        XCTAssertEqual(command["action"] as? String, "page.type")
        XCTAssertEqual(command["tabId"] as? Int, 42)
        XCTAssertEqual(command["expectedUrl"] as? String, "https://example.com/form")
        XCTAssertEqual(command["snapshotId"] as? String, "snapshot:1")
        XCTAssertEqual(command["elementId"] as? String, "e3")
    }

    func testExistingTabCommandsRequireAValidExpectedURLBinding() throws {
        XCTAssertThrowsError(
            try BrowserCommand(action: .inspect, tabID: 42).validatedForSending()
        ) { error in
            XCTAssertEqual(error as? BrowserBridgeError, .invalidCommand)
        }
        XCTAssertThrowsError(
            try BrowserCommand(
                action: .inspect,
                tabID: 42,
                expectedURL: "not a URL"
            ).validatedForSending()
        ) { error in
            XCTAssertEqual(error as? BrowserBridgeError, .invalidCommand)
        }
        XCTAssertNoThrow(
            try BrowserCommand(
                action: .closeTab,
                tabID: 42,
                expectedURL: "chrome://settings/"
            ).validatedForSending()
        )
        XCTAssertThrowsError(
            try BrowserCommand(
                action: .navigate,
                tabID: 42,
                expectedURL: "https://example.com/",
                url: "https://example.org/",
                newTab: true
            ).validatedForSending()
        ) { error in
            XCTAssertEqual(error as? BrowserBridgeError, .invalidCommand)
        }
    }

    private func snapshot(
        snapshotID: String = "snapshot:1",
        url: String = "https://example.com/page",
        visibleText: String = "Visible page text",
        elements: [BrowserPageElement] = []
    ) -> BrowserPageSnapshot {
        BrowserPageSnapshot(
            tabID: 42,
            snapshotID: snapshotID,
            title: "Example",
            url: url,
            loading: false,
            visibleText: visibleText,
            scrollX: 0,
            scrollY: 100,
            viewportWidth: 1_280,
            viewportHeight: 720,
            elements: elements
        )
    }
}
