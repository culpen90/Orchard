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
                    name: "browser_navigate",
                    arguments: #"{"url":"https://example.com","javascript":"alert(1)"}"#
                )
            )
        )
    }

    func testRejectsUnknownTool() {
        XCTAssertThrowsError(
            try service.prepare(toolCall: call(name: "run_shell", arguments: "{}"))
        )
    }

    func testPreparesSafariForConfirmation() throws {
        let proposal = try service.prepare(
            toolCall: call(
                name: "open_application",
                arguments: #"{"name":"Safari","bundle_id":"com.apple.Safari"}"#
            )
        )

        guard case .openApplication(let url, let name) = proposal.kind else {
            return XCTFail("Expected an open-application proposal")
        }
        XCTAssertEqual(proposal.title, "Open Safari?")
        XCTAssertEqual(name, "Safari")
        XCTAssertEqual(url.lastPathComponent, "Safari.app")
    }

    func testAllowsApplicationOutsideStandardApplicationsDirectories() throws {
        let url = URL(
            fileURLWithPath: "/Users/example/Projects/Build/Portable.app"
        )

        XCTAssertEqual(try service.validatedApplicationURL(url), url)
    }

    func testRejectsNonApplicationItems() {
        let url = URL(fileURLWithPath: "/Users/example/Downloads/readme.txt")

        XCTAssertThrowsError(try service.validatedApplicationURL(url)) { error in
            guard let actionError = error as? MacActionError else {
                return XCTFail("Expected a MacActionError")
            }
            guard case .invalidApplication = actionError else {
                return XCTFail("Expected invalidApplication")
            }
        }
    }

    func testRejectsApplicationNameContainingAPath() {
        XCTAssertThrowsError(
            try service.prepare(
                toolCall: call(
                    name: "open_application",
                    arguments: #"{"name":"../../tmp/Untrusted"}"#
                )
            )
        ) { error in
            guard let actionError = error as? MacActionError else {
                return XCTFail("Expected a MacActionError")
            }
            guard case .invalidApplicationName = actionError else {
                return XCTFail("Expected invalidApplicationName")
            }
        }
    }

    func testPreparesSnapshotScopedBrowserClickWithObservedContext() async throws {
        let page = browserPage(
            snapshotID: "page:7",
            elements: [
                BrowserPageElement(
                    id: "e3",
                    role: "button",
                    name: "Continue",
                    tag: "button",
                    type: nil,
                    value: nil,
                    href: nil,
                    disabled: false,
                    editable: false,
                    inViewport: true,
                    options: nil
                )
            ]
        )
        let browserControl = StubBrowserControl(
            results: [
                listedTabsResult(),
                BrowserCommandResult(
                    action: .inspect,
                    outcome: "Inspected the Chrome tab.",
                    page: page,
                    tabs: nil
                )
            ]
        )
        let service = MacActionService(browserControl: browserControl)
        let list = try service.prepare(
            toolCall: call(name: "browser_tabs", arguments: #"{"action":"list"}"#)
        )
        _ = try await service.execute(list)
        let inspect = try service.prepare(
            toolCall: call(name: "browser_inspect", arguments: #"{"tab_id":42}"#)
        )
        _ = try await service.execute(inspect)

        let proposal = try service.prepare(
            toolCall: call(
                name: "browser_click",
                arguments: #"{"tab_id":42,"snapshot_id":"page:7","element_id":"e3"}"#
            )
        )

        XCTAssertEqual(
            proposal.kind,
            .controlBrowser(
                BrowserCommand(
                    action: .click,
                    tabID: 42,
                    expectedURL: "https://example.com/form",
                    snapshotID: "page:7",
                    elementID: "e3"
                )
            )
        )
        XCTAssertEqual(proposal.confirmationTitle, "Click")
        XCTAssertEqual(proposal.title, "Click “Continue” in Chrome?")
        XCTAssertTrue(proposal.detail.contains("Website: example.com"))
        XCTAssertTrue(proposal.detail.contains("Observed URL: https://example.com/form"))
        XCTAssertTrue(proposal.detail.contains("Observed control: button: Continue"))
        XCTAssertThrowsError(
            try service.prepare(
                toolCall: call(
                    name: "browser_click",
                    arguments: #"{"tab_id":42,"snapshot_id":"page:8","element_id":"e3"}"#
                )
            )
        )
    }

    func testRejectsUnsafeBrowserNavigationAndInvalidFlags() {
        XCTAssertThrowsError(
            try service.prepare(
                toolCall: call(
                    name: "browser_navigate",
                    arguments: #"{"url":"javascript:alert(1)"}"#
                )
            )
        )
        XCTAssertThrowsError(
            try service.prepare(
                toolCall: call(
                    name: "browser_navigate",
                    arguments: #"{"url":"https://example.com","new_tab":"yes"}"#
                )
            )
        )
        XCTAssertThrowsError(
            try service.prepare(
                toolCall: call(
                    name: "browser_navigate",
                    arguments: #"{"url":"https://example.com","new_tab":true,"tab_id":42}"#
                )
            )
        )
    }

    func testExistingTabMutationsRequireAnExplicitObservedTab() {
        XCTAssertThrowsError(
            try service.prepare(
                toolCall: call(name: "browser_inspect", arguments: "{}")
            )
        ) { error in
            guard case MacActionError.missingArgument("tab_id") = error else {
                return XCTFail("Expected a missing tab_id error, got \(error)")
            }
        }
        XCTAssertThrowsError(
            try service.prepare(
                toolCall: call(
                    name: "browser_navigate",
                    arguments: #"{"url":"https://example.com"}"#
                )
            )
        ) { error in
            guard case MacActionError.missingArgument("tab_id") = error else {
                return XCTFail("Expected a missing tab_id error, got \(error)")
            }
        }
        XCTAssertThrowsError(
            try service.prepare(
                toolCall: call(
                    name: "browser_scroll",
                    arguments: #"{"direction":"down"}"#
                )
            )
        ) { error in
            guard case MacActionError.missingArgument("tab_id") = error else {
                return XCTFail("Expected a missing tab_id error, got \(error)")
            }
        }
        XCTAssertThrowsError(
            try service.prepare(
                toolCall: call(
                    name: "browser_history",
                    arguments: #"{"action":"reload"}"#
                )
            )
        ) { error in
            guard case MacActionError.missingArgument("tab_id") = error else {
                return XCTFail("Expected a missing tab_id error, got \(error)")
            }
        }

        XCTAssertThrowsError(
            try service.prepare(
                toolCall: call(
                    name: "browser_inspect",
                    arguments: #"{"tab_id":42}"#
                )
            )
        ) { error in
            guard case MacActionError.browserTabUnavailable = error else {
                return XCTFail("Expected an unobserved-tab error, got \(error)")
            }
        }

        XCTAssertNoThrow(
            try service.prepare(
                toolCall: call(
                    name: "browser_navigate",
                    arguments: #"{"url":"https://example.com","new_tab":true}"#
                )
            )
        )
    }

    func testListedTabMetadataMakesTabConfirmationsMeaningful() async throws {
        let browserControl = StubBrowserControl(
            result: BrowserCommandResult(
                action: .listTabs,
                outcome: "Listed the available normal Chrome tabs.",
                page: nil,
                tabs: [
                    BrowserTabSummary(
                        id: 42,
                        windowID: 3,
                        active: true,
                        title: "Checkout – Example",
                        url: "https://shop.example.com/cart",
                        controllable: true
                    )
                ]
            )
        )
        let service = MacActionService(browserControl: browserControl)
        let list = try service.prepare(
            toolCall: call(name: "browser_tabs", arguments: #"{"action":"list"}"#)
        )
        _ = try await service.execute(list)

        let activate = try service.prepare(
            toolCall: call(
                name: "browser_tabs",
                arguments: #"{"action":"activate","tab_id":42}"#
            )
        )
        XCTAssertEqual(activate.title, "Activate “Checkout – Example” in Chrome?")
        XCTAssertTrue(activate.detail.contains("Website: shop.example.com"))
        XCTAssertTrue(activate.detail.contains("Chrome tab: 42"))
        XCTAssertEqual(
            activate.kind,
            .controlBrowser(
                BrowserCommand(
                    action: .activateTab,
                    tabID: 42,
                    expectedURL: "https://shop.example.com/cart"
                )
            )
        )

        let close = try service.prepare(
            toolCall: call(
                name: "browser_tabs",
                arguments: #"{"action":"close","tab_id":42}"#
            )
        )
        XCTAssertEqual(close.title, "Close “Checkout – Example” in Chrome?")
        XCTAssertTrue(close.detail.contains("Website: shop.example.com"))
        XCTAssertTrue(close.detail.contains("Observed URL: https://shop.example.com/cart"))

        let navigate = try service.prepare(
            toolCall: call(
                name: "browser_navigate",
                arguments: #"{"url":"https://example.com/done","tab_id":42}"#
            )
        )
        XCTAssertEqual(navigate.title, "Navigate “Checkout – Example” in Chrome?")
        XCTAssertTrue(navigate.detail.contains("Destination: https://example.com/done"))
        XCTAssertEqual(
            navigate.kind,
            .controlBrowser(
                BrowserCommand(
                    action: .navigate,
                    tabID: 42,
                    expectedURL: "https://shop.example.com/cart",
                    url: "https://example.com/done",
                    newTab: false
                )
            )
        )

        let scroll = try service.prepare(
            toolCall: call(
                name: "browser_scroll",
                arguments: #"{"tab_id":42,"direction":"down","amount":900}"#
            )
        )
        XCTAssertEqual(scroll.title, "Scroll “Checkout – Example” down?")
        XCTAssertTrue(scroll.detail.contains("Distance: 900 pixels"))
        XCTAssertEqual(
            scroll.kind,
            .controlBrowser(
                BrowserCommand(
                    action: .scroll,
                    tabID: 42,
                    expectedURL: "https://shop.example.com/cart",
                    direction: "down",
                    amount: 900
                )
            )
        )

        let history = try service.prepare(
            toolCall: call(
                name: "browser_history",
                arguments: #"{"action":"back","tab_id":42}"#
            )
        )
        XCTAssertEqual(history.title, "Back in “Checkout – Example”?")
        XCTAssertEqual(
            history.kind,
            .controlBrowser(
                BrowserCommand(
                    action: .back,
                    tabID: 42,
                    expectedURL: "https://shop.example.com/cart"
                )
            )
        )

        XCTAssertThrowsError(
            try service.prepare(
                toolCall: call(
                    name: "browser_tabs",
                    arguments: #"{"action":"close","tab_id":99}"#
                )
            )
        ) { error in
            guard case MacActionError.browserTabListUnavailable = error else {
                return XCTFail("Expected an unlisted-tab error, got \(error)")
            }
        }
    }

    func testInspectedPageIsFreshestForPageMutationsWhileTabCloseUsesList() async throws {
        let browserControl = StubBrowserControl(
            results: [
                listedTabsResult(
                    title: "Listed title",
                    url: "https://listed.example.com"
                ),
                BrowserCommandResult(
                    action: .inspect,
                    outcome: "Inspected the Chrome tab.",
                    page: browserPage(snapshotID: "page:10", elements: []),
                    tabs: nil
                )
            ]
        )
        let service = MacActionService(browserControl: browserControl)
        let list = try service.prepare(
            toolCall: call(name: "browser_tabs", arguments: #"{"action":"list"}"#)
        )
        _ = try await service.execute(list)
        let inspect = try service.prepare(
            toolCall: call(name: "browser_inspect", arguments: #"{"tab_id":42}"#)
        )
        _ = try await service.execute(inspect)

        let reload = try service.prepare(
            toolCall: call(
                name: "browser_history",
                arguments: #"{"action":"reload","tab_id":42}"#
            )
        )
        XCTAssertEqual(reload.title, "Reload in “Example”?")
        XCTAssertTrue(reload.detail.contains("Website: example.com"))
        XCTAssertEqual(
            reload.kind,
            .controlBrowser(
                BrowserCommand(
                    action: .reload,
                    tabID: 42,
                    expectedURL: "https://example.com/form"
                )
            )
        )

        let close = try service.prepare(
            toolCall: call(
                name: "browser_tabs",
                arguments: #"{"action":"close","tab_id":42}"#
            )
        )
        XCTAssertEqual(close.title, "Close “Listed title” in Chrome?")
        XCTAssertTrue(close.detail.contains("Website: listed.example.com"))
    }

    func testNewTabListReplacesStaleTabMetadata() async throws {
        let browserControl = StubBrowserControl(
            results: [
                BrowserCommandResult(
                    action: .listTabs,
                    outcome: "Listed tabs.",
                    page: nil,
                    tabs: [
                        BrowserTabSummary(
                            id: 42,
                            windowID: 3,
                            active: true,
                            title: "Old tab",
                            url: "https://old.example.com",
                            controllable: true
                        )
                    ]
                ),
                BrowserCommandResult(
                    action: .listTabs,
                    outcome: "Listed tabs.",
                    page: nil,
                    tabs: [
                        BrowserTabSummary(
                            id: 7,
                            windowID: 3,
                            active: true,
                            title: "New tab",
                            url: "https://new.example.com",
                            controllable: true
                        )
                    ]
                )
            ]
        )
        let service = MacActionService(browserControl: browserControl)
        let list = try service.prepare(
            toolCall: call(name: "browser_tabs", arguments: #"{"action":"list"}"#)
        )
        _ = try await service.execute(list)
        _ = try await service.execute(list)

        XCTAssertThrowsError(
            try service.prepare(
                toolCall: call(
                    name: "browser_tabs",
                    arguments: #"{"action":"activate","tab_id":42}"#
                )
            )
        ) { error in
            guard case MacActionError.browserTabListUnavailable = error else {
                return XCTFail("Expected stale tab metadata to be rejected, got \(error)")
            }
        }

        let activate = try service.prepare(
            toolCall: call(
                name: "browser_tabs",
                arguments: #"{"action":"activate","tab_id":7}"#
            )
        )
        XCTAssertEqual(activate.title, "Activate “New tab” in Chrome?")
    }

    func testNewTabListInvalidatesInspectedPageWhenURLChanges() async throws {
        let inspectedPage = browserPage(
            snapshotID: "page:old",
            elements: [
                BrowserPageElement(
                    id: "e3",
                    role: "button",
                    name: "Old action",
                    tag: "button",
                    type: nil,
                    value: nil,
                    href: nil,
                    disabled: false,
                    editable: false,
                    inViewport: true,
                    options: nil
                )
            ]
        )
        let browserControl = StubBrowserControl(
            results: [
                listedTabsResult(),
                BrowserCommandResult(
                    action: .inspect,
                    outcome: "Inspected the Chrome tab.",
                    page: inspectedPage,
                    tabs: nil
                ),
                listedTabsResult(
                    title: "New destination",
                    url: "https://new.example.com/checkout"
                )
            ]
        )
        let service = MacActionService(browserControl: browserControl)
        let list = try service.prepare(
            toolCall: call(name: "browser_tabs", arguments: #"{"action":"list"}"#)
        )
        _ = try await service.execute(list)
        let inspect = try service.prepare(
            toolCall: call(name: "browser_inspect", arguments: #"{"tab_id":42}"#)
        )
        _ = try await service.execute(inspect)
        _ = try await service.execute(list)

        XCTAssertThrowsError(
            try service.prepare(
                toolCall: call(
                    name: "browser_click",
                    arguments: #"{"tab_id":42,"snapshot_id":"page:old","element_id":"e3"}"#
                )
            )
        ) { error in
            guard case MacActionError.browserSnapshotUnavailable = error else {
                return XCTFail("Expected the old page snapshot to be invalidated, got \(error)")
            }
        }

        let reload = try service.prepare(
            toolCall: call(
                name: "browser_history",
                arguments: #"{"action":"reload","tab_id":42}"#
            )
        )
        XCTAssertEqual(reload.title, "Reload in “New destination”?")
        XCTAssertTrue(reload.detail.contains("Website: new.example.com"))
    }

    func testNewTabListInvalidatesInspectedPageWhenTitleChanges() async throws {
        let browserControl = StubBrowserControl(
            results: [
                listedTabsResult(),
                BrowserCommandResult(
                    action: .inspect,
                    outcome: "Inspected the Chrome tab.",
                    page: browserPage(snapshotID: "page:old", elements: []),
                    tabs: nil
                ),
                listedTabsResult(title: "Updated title")
            ]
        )
        let service = MacActionService(browserControl: browserControl)
        let list = try service.prepare(
            toolCall: call(name: "browser_tabs", arguments: #"{"action":"list"}"#)
        )
        _ = try await service.execute(list)
        let inspect = try service.prepare(
            toolCall: call(name: "browser_inspect", arguments: #"{"tab_id":42}"#)
        )
        _ = try await service.execute(inspect)
        _ = try await service.execute(list)

        let reload = try service.prepare(
            toolCall: call(
                name: "browser_history",
                arguments: #"{"action":"reload","tab_id":42}"#
            )
        )
        XCTAssertEqual(reload.title, "Reload in “Updated title”?")
    }

    func testObservationWarningInvalidatesPageAndTabMetadata() async throws {
        let inspectedPage = browserPage(
            snapshotID: "page:old",
            elements: [
                BrowserPageElement(
                    id: "e3",
                    role: "button",
                    name: "Old action",
                    tag: "button",
                    type: nil,
                    value: nil,
                    href: nil,
                    disabled: false,
                    editable: false,
                    inViewport: true,
                    options: nil
                )
            ]
        )
        let browserControl = StubBrowserControl(
            results: [
                listedTabsResult(
                    title: "Last listed tab",
                    url: "https://listed.example.com/start"
                ),
                BrowserCommandResult(
                    action: .inspect,
                    outcome: "Inspected the Chrome tab.",
                    page: inspectedPage,
                    tabs: nil
                ),
                BrowserCommandResult(
                    action: .navigate,
                    outcome: "Navigated the Chrome tab.",
                    page: nil,
                    tabs: nil,
                    observationWarning: "The destination could not be inspected."
                )
            ]
        )
        let service = MacActionService(browserControl: browserControl)
        let list = try service.prepare(
            toolCall: call(name: "browser_tabs", arguments: #"{"action":"list"}"#)
        )
        _ = try await service.execute(list)
        let inspect = try service.prepare(
            toolCall: call(name: "browser_inspect", arguments: #"{"tab_id":42}"#)
        )
        _ = try await service.execute(inspect)
        let navigate = try service.prepare(
            toolCall: call(
                name: "browser_navigate",
                arguments: #"{"url":"https://destination.example.com","tab_id":42}"#
            )
        )
        _ = try await service.execute(navigate)

        XCTAssertThrowsError(
            try service.prepare(
                toolCall: call(
                    name: "browser_click",
                    arguments: #"{"tab_id":42,"snapshot_id":"page:old","element_id":"e3"}"#
                )
            )
        ) { error in
            guard case MacActionError.browserSnapshotUnavailable = error else {
                return XCTFail("Expected the unobserved page snapshot to be invalidated, got \(error)")
            }
        }

        XCTAssertThrowsError(
            try service.prepare(
                toolCall: call(
                    name: "browser_history",
                    arguments: #"{"action":"reload","tab_id":42}"#
                )
            )
        ) { error in
            guard case MacActionError.browserTabUnavailable = error else {
                return XCTFail("Expected a fresh tab list to be required, got \(error)")
            }
        }
        XCTAssertThrowsError(
            try service.prepare(
                toolCall: call(
                    name: "browser_tabs",
                    arguments: #"{"action":"activate","tab_id":42}"#
                )
            )
        ) { error in
            guard case MacActionError.browserTabListUnavailable = error else {
                return XCTFail("Expected stale tab metadata to be rejected, got \(error)")
            }
        }
    }

    func testBrowserControlReturnsFreshPageStateForNextModelRound() async throws {
        let inspectedPage = browserPage(
            snapshotID: "page:7",
            elements: [
                BrowserPageElement(
                    id: "e2",
                    role: "textbox",
                    name: "Message",
                    tag: "textarea",
                    type: nil,
                    value: "",
                    href: nil,
                    disabled: false,
                    editable: true,
                    inViewport: true,
                    options: nil
                )
            ]
        )
        let page = BrowserPageSnapshot(
            tabID: 42,
            snapshotID: "page:8",
            title: "Example",
            url: "https://example.com/form",
            loading: false,
            visibleText: "Saved successfully",
            scrollX: 0,
            scrollY: 0,
            viewportWidth: 1_280,
            viewportHeight: 720,
            elements: []
        )
        let browserControl = StubBrowserControl(
            results: [
                listedTabsResult(),
                BrowserCommandResult(
                    action: .inspect,
                    outcome: "Inspected the Chrome tab.",
                    page: inspectedPage,
                    tabs: nil
                ),
                BrowserCommandResult(
                    action: .type,
                    outcome: "Entered text and submitted the form.",
                    page: page,
                    tabs: nil
                )
            ]
        )
        let service = MacActionService(browserControl: browserControl)
        let list = try service.prepare(
            toolCall: call(name: "browser_tabs", arguments: #"{"action":"list"}"#)
        )
        _ = try await service.execute(list)
        let inspect = try service.prepare(
            toolCall: call(name: "browser_inspect", arguments: #"{"tab_id":42}"#)
        )
        _ = try await service.execute(inspect)
        let proposal = try service.prepare(
            toolCall: call(
                name: "browser_type",
                arguments: #"{"tab_id":42,"snapshot_id":"page:7","element_id":"e2","text":"Hello","clear":true,"submit":true}"#
            )
        )

        let actionResult = try await service.execute(proposal)
        let commands = await browserControl.commands()

        XCTAssertEqual(
            commands,
            [
                BrowserCommand(action: .listTabs),
                BrowserCommand(
                    action: .inspect,
                    tabID: 42,
                    expectedURL: "https://example.com/form"
                ),
                BrowserCommand(
                    action: .type,
                    tabID: 42,
                    expectedURL: "https://example.com/form",
                    snapshotID: "page:7",
                    elementID: "e2",
                    text: "Hello",
                    clear: true,
                    submit: true
                )
            ]
        )
        XCTAssertEqual(actionResult.activityDescription, "Typed and submitted in Chrome")
        XCTAssertTrue(actionResult.toolMessage.contains("untrusted website data"))
        XCTAssertTrue(actionResult.toolMessage.contains("Saved successfully"))
        XCTAssertTrue(actionResult.toolMessage.contains(#""snapshotId":"page:8""#))
    }

    func testSelectAllowsAnObservedEmptyOptionValue() async throws {
        let page = browserPage(
            snapshotID: "page:9",
            elements: [
                BrowserPageElement(
                    id: "e5",
                    role: "combobox",
                    name: "Country",
                    tag: "select",
                    type: nil,
                    value: "ca",
                    href: nil,
                    disabled: false,
                    editable: true,
                    inViewport: true,
                    options: [
                        BrowserPageOption(
                            value: "",
                            label: "Choose a country",
                            selected: false,
                            disabled: false
                        )
                    ]
                )
            ]
        )
        let browserControl = StubBrowserControl(
            results: [
                listedTabsResult(),
                BrowserCommandResult(
                    action: .inspect,
                    outcome: "Inspected the Chrome tab.",
                    page: page,
                    tabs: nil
                )
            ]
        )
        let service = MacActionService(browserControl: browserControl)
        let list = try service.prepare(
            toolCall: call(name: "browser_tabs", arguments: #"{"action":"list"}"#)
        )
        _ = try await service.execute(list)
        let inspect = try service.prepare(
            toolCall: call(name: "browser_inspect", arguments: #"{"tab_id":42}"#)
        )
        _ = try await service.execute(inspect)

        let proposal = try service.prepare(
            toolCall: call(
                name: "browser_select",
                arguments: #"{"tab_id":42,"snapshot_id":"page:9","element_id":"e5","value":""}"#
            )
        )

        XCTAssertEqual(proposal.title, "Choose “Choose a country” in “Country”?")
        XCTAssertEqual(
            proposal.kind,
            .controlBrowser(
                BrowserCommand(
                    action: .select,
                    tabID: 42,
                    expectedURL: "https://example.com/form",
                    snapshotID: "page:9",
                    elementID: "e5",
                    value: ""
                )
            )
        )
    }

    func testStaleTabResponseEvictsCachedPageAndTabMetadata() async throws {
        let browserControl = StaleTabBrowserControl(result: listedTabsResult())
        let service = MacActionService(browserControl: browserControl)
        let list = try service.prepare(
            toolCall: call(name: "browser_tabs", arguments: #"{"action":"list"}"#)
        )
        _ = try await service.execute(list)
        let inspect = try service.prepare(
            toolCall: call(name: "browser_inspect", arguments: #"{"tab_id":42}"#)
        )

        do {
            _ = try await service.execute(inspect)
            XCTFail("Expected the changed tab to be rejected")
        } catch BrowserBridgeError.remote(let code, _) {
            XCTAssertEqual(code, "stale_tab")
        }

        XCTAssertThrowsError(
            try service.prepare(
                toolCall: call(name: "browser_inspect", arguments: #"{"tab_id":42}"#)
            )
        ) { error in
            guard case MacActionError.browserTabUnavailable = error else {
                return XCTFail("Expected stale tab metadata to be evicted, got \(error)")
            }
        }
        XCTAssertThrowsError(
            try service.prepare(
                toolCall: call(
                    name: "browser_tabs",
                    arguments: #"{"action":"close","tab_id":42}"#
                )
            )
        ) { error in
            guard case MacActionError.browserTabListUnavailable = error else {
                return XCTFail("Expected stale tab-list metadata to be evicted, got \(error)")
            }
        }
    }

    func testTabWithUnavailableURLCannotBePreparedForMutation() async throws {
        let browserControl = StubBrowserControl(
            result: listedTabsResult(url: "")
        )
        let service = MacActionService(browserControl: browserControl)
        let list = try service.prepare(
            toolCall: call(name: "browser_tabs", arguments: #"{"action":"list"}"#)
        )
        _ = try await service.execute(list)

        XCTAssertThrowsError(
            try service.prepare(
                toolCall: call(
                    name: "browser_tabs",
                    arguments: #"{"action":"activate","tab_id":42}"#
                )
            )
        ) { error in
            guard case MacActionError.browserTabListUnavailable = error else {
                return XCTFail("Expected an unavailable tab URL error, got \(error)")
            }
        }
    }

    func testReconnectInvalidatesCachedTabAndPageObservationsBeforePreparation() async throws {
        let browserControl = GenerationBrowserControl(
            generation: 7,
            results: [listedTabsResult()]
        )
        let service = MacActionService(browserControl: browserControl)
        let list = try service.prepare(
            toolCall: call(name: "browser_tabs", arguments: #"{"action":"list"}"#)
        )
        _ = try await service.execute(list)
        XCTAssertNoThrow(
            try service.prepare(
                toolCall: call(
                    name: "browser_tabs",
                    arguments: #"{"action":"activate","tab_id":42}"#
                )
            )
        )

        browserControl.setGeneration(8)

        XCTAssertThrowsError(
            try service.prepare(
                toolCall: call(
                    name: "browser_tabs",
                    arguments: #"{"action":"activate","tab_id":42}"#
                )
            )
        ) { error in
            guard case MacActionError.browserTabListUnavailable = error else {
                return XCTFail("Expected reconnect to invalidate the tab list, got \(error)")
            }
        }
        XCTAssertThrowsError(
            try service.prepare(
                toolCall: call(name: "browser_inspect", arguments: #"{"tab_id":42}"#)
            )
        ) { error in
            guard case MacActionError.browserTabUnavailable = error else {
                return XCTFail("Expected reconnect to invalidate page context, got \(error)")
            }
        }
    }

    func testReconnectBetweenApprovalAndExecutionRejectsOldBrowserIntent() async throws {
        let browserControl = GenerationBrowserControl(
            generation: 11,
            results: [listedTabsResult()]
        )
        let service = MacActionService(browserControl: browserControl)
        let list = try service.prepare(
            toolCall: call(name: "browser_tabs", arguments: #"{"action":"list"}"#)
        )
        _ = try await service.execute(list)
        let close = try service.prepare(
            toolCall: call(
                name: "browser_tabs",
                arguments: #"{"action":"close","tab_id":42}"#
            )
        )
        XCTAssertEqual(close.browserConnectionGeneration, 11)

        browserControl.setGeneration(12)

        do {
            _ = try await service.execute(close)
            XCTFail("Expected the old browser intent to be rejected")
        } catch {
            XCTAssertEqual(error as? BrowserBridgeError, .staleConnection)
        }
        XCTAssertEqual(browserControl.commands().map(\.action), [.listTabs])
        XCTAssertThrowsError(
            try service.prepare(
                toolCall: call(
                    name: "browser_tabs",
                    arguments: #"{"action":"close","tab_id":42}"#
                )
            )
        )
    }

    func testUnknownBrowserOutcomeInvalidatesCachedObservations() async throws {
        let browserControl = UnknownOutcomeBrowserControl(result: listedTabsResult())
        let service = MacActionService(browserControl: browserControl)
        let list = try service.prepare(
            toolCall: call(name: "browser_tabs", arguments: #"{"action":"list"}"#)
        )
        _ = try await service.execute(list)
        let close = try service.prepare(
            toolCall: call(
                name: "browser_tabs",
                arguments: #"{"action":"close","tab_id":42}"#
            )
        )

        do {
            _ = try await service.execute(close)
            XCTFail("Expected an unknown browser outcome")
        } catch {
            XCTAssertEqual(error as? BrowserBridgeError, .outcomeUnknown)
            XCTAssertTrue(error.localizedDescription.contains("may have happened"))
        }

        XCTAssertThrowsError(
            try service.prepare(
                toolCall: call(
                    name: "browser_tabs",
                    arguments: #"{"action":"activate","tab_id":42}"#
                )
            )
        ) { error in
            guard case MacActionError.browserTabListUnavailable = error else {
                return XCTFail("Expected unknown outcome to clear cached tabs, got \(error)")
            }
        }
    }

    func testToolDefinitionsRemoveSearchAndExposeBrowserControlActions() {
        let names = service.toolDefinitions.map(\.function.name)

        XCTAssertFalse(names.contains("search_web"))
        XCTAssertTrue(names.contains("browser_inspect"))
        XCTAssertTrue(names.contains("browser_navigate"))
        XCTAssertTrue(names.contains("browser_click"))
        XCTAssertTrue(names.contains("browser_type"))
        XCTAssertTrue(names.contains("browser_select"))
        XCTAssertTrue(names.contains("browser_scroll"))
        XCTAssertTrue(names.contains("browser_history"))
        XCTAssertTrue(names.contains("browser_tabs"))
    }

    private func call(name: String, arguments: String) -> OpenRouterToolCall {
        OpenRouterToolCall(
            id: "call_1",
            type: "function",
            function: OpenRouterFunctionCall(name: name, arguments: arguments)
        )
    }

    private func browserPage(
        snapshotID: String,
        elements: [BrowserPageElement]
    ) -> BrowserPageSnapshot {
        BrowserPageSnapshot(
            tabID: 42,
            snapshotID: snapshotID,
            title: "Example",
            url: "https://example.com/form",
            loading: false,
            visibleText: "Visible page text",
            scrollX: 0,
            scrollY: 0,
            viewportWidth: 1_280,
            viewportHeight: 720,
            elements: elements
        )
    }

    private func listedTabsResult(
        title: String = "Example",
        url: String = "https://example.com/form"
    ) -> BrowserCommandResult {
        BrowserCommandResult(
            action: .listTabs,
            outcome: "Listed the available normal Chrome tabs.",
            page: nil,
            tabs: [
                BrowserTabSummary(
                    id: 42,
                    windowID: 3,
                    active: true,
                    title: title,
                    url: url,
                    controllable: true
                )
            ]
        )
    }
}

private actor StaleTabBrowserControl: BrowserControlling {
    private let result: BrowserCommandResult
    private var callCount = 0

    init(result: BrowserCommandResult) {
        self.result = result
    }

    func perform(_ command: BrowserCommand) async throws -> BrowserCommandResult {
        callCount += 1
        if callCount == 1 {
            return result
        }
        throw BrowserBridgeError.remote(
            code: "stale_tab",
            message: "The Chrome tab changed after Orchard observed it."
        )
    }
}

private actor UnknownOutcomeBrowserControl: BrowserControlling {
    private let result: BrowserCommandResult
    private var callCount = 0

    init(result: BrowserCommandResult) {
        self.result = result
    }

    func perform(_ command: BrowserCommand) async throws -> BrowserCommandResult {
        callCount += 1
        if callCount == 1 {
            return result
        }
        throw BrowserBridgeError.outcomeUnknown
    }
}

private final class GenerationBrowserControl: BrowserControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64
    private var results: [BrowserCommandResult]
    private var recordedCommands: [BrowserCommand] = []

    init(generation: UInt64, results: [BrowserCommandResult]) {
        self.generation = generation
        self.results = results
    }

    var connectionGeneration: UInt64 {
        lock.withLock { generation }
    }

    func setGeneration(_ generation: UInt64) {
        lock.withLock { self.generation = generation }
    }

    func perform(_ command: BrowserCommand) async throws -> BrowserCommandResult {
        try lock.withLock {
            recordedCommands.append(command)
            guard !results.isEmpty else {
                throw BrowserBridgeError.invalidResponse
            }
            return results.removeFirst()
        }
    }

    func commands() -> [BrowserCommand] {
        lock.withLock { recordedCommands }
    }
}
