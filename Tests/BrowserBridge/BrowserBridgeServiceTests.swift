import CryptoKit
import Foundation
import XCTest
@testable import Orchard

final class BrowserBridgeServiceTests: XCTestCase {
    func testAuthenticatedProtocolV2RoundTripControlsBrowserAndSupportsCancellation() async throws {
        let token = "test-pairing-token-that-is-long-enough"
        let port: UInt16 = 48_476
        let service = BrowserBridgeService(accessToken: token, port: port)
        try await service.waitUntilListening()

        let (session, socket) = makeSocket(port: port)
        defer {
            socket.cancel(with: .normalClosure, reason: nil)
            session.invalidateAndCancel()
        }
        try await authenticate(socket: socket, service: service, token: token)
        XCTAssertEqual(service.connectionGeneration, 1)

        let command = BrowserCommand(
            action: .inspect,
            tabID: 42,
            expectedURL: "https://example.com/form"
        )
        async let commandResult = service.perform(command)
        let request = try await receiveJSON(from: socket)
        let requestID = try XCTUnwrap(request["id"] as? String)
        let commandPayload = try XCTUnwrap(request["command"] as? [String: Any])

        XCTAssertEqual(request["version"] as? Int, 2)
        XCTAssertEqual(request["type"] as? String, "browser.command")
        XCTAssertEqual(commandPayload["action"] as? String, "page.inspect")
        XCTAssertEqual(commandPayload["tabId"] as? Int, 42)
        XCTAssertEqual(commandPayload["expectedUrl"] as? String, "https://example.com/form")

        try await sendJSON(
            [
                "version": 2,
                "type": "browser.response",
                "id": requestID,
                "ok": true,
                "result": browserResult(action: "page.inspect", snapshotID: "page:1")
            ],
            over: socket
        )

        let result = try await commandResult
        XCTAssertEqual(result.action, .inspect)
        XCTAssertEqual(result.outcome, "Inspected the Chrome tab.")
        XCTAssertEqual(result.page?.tabID, 42)
        XCTAssertEqual(result.page?.snapshotID, "page:1")
        XCTAssertEqual(result.page?.elements.first?.id, "e1")

        let cancelledCommand = Task {
            try await service.perform(
                BrowserCommand(action: .navigate, url: "https://example.com", newTab: true)
            )
        }
        let cancellableRequest = try await receiveJSON(from: socket)
        let cancelledRequestID = try XCTUnwrap(cancellableRequest["id"] as? String)
        cancelledCommand.cancel()

        let cancellation = try await receiveJSON(from: socket)
        XCTAssertEqual(cancellation["type"] as? String, "browser.cancel")
        XCTAssertEqual(cancellation["id"] as? String, cancelledRequestID)
        do {
            _ = try await cancelledCommand.value
            XCTFail("Expected the browser command to be cancelled")
        } catch {
            XCTAssertEqual(error as? BrowserBridgeError, .outcomeUnknown)
        }

        // A response already in flight after cancellation is ignored.
        try await sendJSON(
            [
                "version": 2,
                "type": "browser.response",
                "id": cancelledRequestID,
                "ok": true,
                "result": browserResult(action: "page.navigate", snapshotID: "late:1")
            ],
            over: socket
        )

        async let remoteFailure = service.perform(
            BrowserCommand(
                action: .scroll,
                tabID: 42,
                expectedURL: "https://example.com/form",
                direction: "down",
                amount: 700
            )
        )
        let failingRequest = try await receiveJSON(from: socket)
        let failingRequestID = try XCTUnwrap(failingRequest["id"] as? String)
        try await sendJSON(
            [
                "version": 2,
                "type": "browser.response",
                "id": failingRequestID,
                "ok": false,
                "error": [
                    "code": String(repeating: "x", count: 80) + "!\n",
                    "message": "  Unsafe\u{0000}\n" + String(repeating: "m", count: 600)
                ]
            ],
            over: socket
        )

        do {
            _ = try await remoteFailure
            XCTFail("Expected the extension error")
        } catch BrowserBridgeError.remote(let code, let message) {
            XCTAssertEqual(code, String(repeating: "x", count: 64))
            XCTAssertLessThanOrEqual(message.count, 500)
            XCTAssertFalse(message.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testInvalidClientProofNeverAuthenticatesConnection() async throws {
        let token = "test-pairing-token-that-is-long-enough"
        let port: UInt16 = 48_478
        let service = BrowserBridgeService(accessToken: token, port: port)
        try await service.waitUntilListening()
        let (session, socket) = makeSocket(port: port)
        defer {
            socket.cancel(with: .normalClosure, reason: nil)
            session.invalidateAndCancel()
        }

        try await sendJSON(
            [
                "version": 2,
                "type": "hello",
                "clientNonce": authenticationValue(Data(repeating: 0x42, count: 32)),
                "capabilities": BrowserCommandAction.allCases.map(\.rawValue)
            ],
            over: socket
        )
        let challenge = try await receiveJSON(from: socket)
        XCTAssertEqual(challenge["type"] as? String, "hello.challenge")

        try await sendJSON(
            [
                "version": 2,
                "type": "hello.authenticate",
                "proof": String(repeating: "A", count: 43)
            ],
            over: socket
        )
        let rejection = try await receiveJSON(from: socket)
        let error = try XCTUnwrap(rejection["error"] as? [String: Any])

        XCTAssertEqual(rejection["type"] as? String, "hello.ack")
        XCTAssertEqual(rejection["ok"] as? Bool, false)
        XCTAssertEqual(error["code"] as? String, "invalid_proof")
        XCTAssertFalse(service.isExtensionConnected)
    }

    func testAuthenticatedReplacementChangesGenerationAndRejectsOldIntent() async throws {
        let token = "replacement-test-token-that-is-long-enough"
        let service = BrowserBridgeService(accessToken: token, port: 48_480)
        try await service.waitUntilListening()
        XCTAssertEqual(service.connectionGeneration, 0)

        let (firstSession, firstSocket) = makeSocket(port: 48_480)
        defer {
            firstSocket.cancel(with: .normalClosure, reason: nil)
            firstSession.invalidateAndCancel()
        }
        try await authenticate(socket: firstSocket, service: service, token: token)
        let firstGeneration = service.connectionGeneration
        let command = BrowserCommand(
            action: .inspect,
            tabID: 42,
            expectedURL: "https://example.com/form"
        )
        let oldCommand = Task {
            try await service.perform(
                command,
                expectedConnectionGeneration: firstGeneration
            )
        }
        let oldRequest = try await receiveJSON(from: firstSocket)
        XCTAssertEqual(oldRequest["type"] as? String, "browser.command")

        let (secondSession, secondSocket) = makeSocket(port: 48_480)
        defer {
            secondSocket.cancel(with: .normalClosure, reason: nil)
            secondSession.invalidateAndCancel()
        }
        let replacementStarted = ContinuousClock.now
        try await authenticate(socket: secondSocket, service: service, token: token)

        XCTAssertEqual(firstGeneration, 1)
        XCTAssertEqual(service.connectionGeneration, 2)
        do {
            _ = try await oldCommand.value
            XCTFail("Expected the in-flight old-generation command to fail")
        } catch {
            XCTAssertEqual(error as? BrowserBridgeError, .connectionChanged)
        }
        XCTAssertLessThan(
            replacementStarted.duration(to: ContinuousClock.now),
            .seconds(2),
            "Replacing a connection should not leave its commands waiting for timeout"
        )

        do {
            _ = try await service.perform(
                command,
                expectedConnectionGeneration: firstGeneration
            )
            XCTFail("Expected a stale, not-yet-sent intent to be rejected")
        } catch {
            XCTAssertEqual(error as? BrowserBridgeError, .staleConnection)
        }

        async let currentResult = service.perform(
            command,
            expectedConnectionGeneration: service.connectionGeneration
        )
        let currentRequest = try await receiveJSON(from: secondSocket)
        let currentRequestID = try XCTUnwrap(currentRequest["id"] as? String)
        try await sendJSON(
            [
                "version": 2,
                "type": "browser.response",
                "id": currentRequestID,
                "ok": true,
                "result": browserResult(action: "page.inspect", snapshotID: "replacement:1")
            ],
            over: secondSocket
        )
        let replacementResult = try await currentResult
        XCTAssertEqual(replacementResult.page?.snapshotID, "replacement:1")
    }

    func testExtensionWithoutBrowserControlCapabilityIsRejected() async throws {
        let port: UInt16 = 48_479
        let service = BrowserBridgeService(
            accessToken: "test-pairing-token-that-is-long-enough",
            port: port
        )
        try await service.waitUntilListening()
        let (session, socket) = makeSocket(port: port)
        defer {
            socket.cancel(with: .normalClosure, reason: nil)
            session.invalidateAndCancel()
        }

        try await sendJSON(
            [
                "version": 2,
                "type": "hello",
                "clientNonce": authenticationValue(Data(repeating: 0x43, count: 32)),
                "capabilities": BrowserCommandAction.allCases
                    .filter { $0 != .click }
                    .map(\.rawValue)
            ],
            over: socket
        )
        let rejection = try await receiveJSON(from: socket)
        let error = try XCTUnwrap(rejection["error"] as? [String: Any])

        XCTAssertEqual(rejection["type"] as? String, "hello.ack")
        XCTAssertEqual(rejection["ok"] as? Bool, false)
        XCTAssertEqual(error["code"] as? String, "incompatible_extension")
        XCTAssertFalse(service.isExtensionConnected)
    }

    func testCommandFailsClearlyWithoutConnectedExtension() async throws {
        let service = BrowserBridgeService(
            accessToken: "another-test-token-that-is-long-enough",
            port: 48_477
        )
        try await service.waitUntilListening()

        do {
            _ = try await service.perform(
                BrowserCommand(
                    action: .inspect,
                    tabID: 42,
                    expectedURL: "https://example.com/form"
                )
            )
            XCTFail("Expected an extension connection error")
        } catch {
            XCTAssertEqual(error as? BrowserBridgeError, .extensionNotConnected)
        }
    }

    private func authenticate(
        socket: URLSessionWebSocketTask,
        service: BrowserBridgeService,
        token: String
    ) async throws {
        let clientNonce = authenticationValue(Data(repeating: 0x41, count: 32))
        try await sendJSON(
            [
                "version": 2,
                "type": "hello",
                "clientNonce": clientNonce,
                "capabilities": BrowserCommandAction.allCases.map(\.rawValue)
            ],
            over: socket
        )
        let challenge = try await receiveJSON(from: socket)
        let serverNonce = try XCTUnwrap(challenge["serverNonce"] as? String)
        let serverProof = try XCTUnwrap(challenge["proof"] as? String)
        XCTAssertEqual(challenge["version"] as? Int, 2)
        XCTAssertEqual(challenge["type"] as? String, "hello.challenge")
        XCTAssertEqual(
            serverProof,
            authenticationProof(
                token: token,
                role: "server",
                clientNonce: clientNonce,
                serverNonce: serverNonce
            )
        )

        try await sendJSON(
            [
                "version": 2,
                "type": "hello.authenticate",
                "proof": authenticationProof(
                    token: token,
                    role: "client",
                    clientNonce: clientNonce,
                    serverNonce: serverNonce
                )
            ],
            over: socket
        )
        try await sendJSON(["version": 2, "type": "ping"], over: socket)

        let acknowledgement = try await receiveJSON(from: socket)
        let pong = try await receiveJSON(from: socket)
        XCTAssertEqual(acknowledgement["type"] as? String, "hello.ack")
        XCTAssertEqual(acknowledgement["ok"] as? Bool, true)
        XCTAssertEqual(pong["type"] as? String, "pong")
        XCTAssertTrue(service.isExtensionConnected)
    }

    private func browserResult(action: String, snapshotID: String) -> [String: Any] {
        [
            "action": action,
            "outcome": action == "page.inspect"
                ? "Inspected the Chrome tab."
                : "Completed the browser action.",
            "page": [
                "tabId": 42,
                "snapshotId": snapshotID,
                "title": "Example",
                "url": "https://example.com/page",
                "loading": false,
                "visibleText": "Visible page content",
                "scrollX": 0,
                "scrollY": 0,
                "viewportWidth": 1280,
                "viewportHeight": 720,
                "elements": [
                    [
                        "id": "e1",
                        "role": "button",
                        "name": "Continue",
                        "tag": "button",
                        "disabled": false,
                        "editable": false,
                        "inViewport": true
                    ]
                ]
            ]
        ]
    }

    private func makeSocket(port: UInt16) -> (URLSession, URLSessionWebSocketTask) {
        let session = URLSession(configuration: .ephemeral)
        let socket = session.webSocketTask(
            with: URL(string: "ws://127.0.0.1:\(port)")!
        )
        socket.resume()
        return (session, socket)
    }

    private func sendJSON(
        _ object: [String: Any],
        over socket: URLSessionWebSocketTask
    ) async throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        try await socket.send(.string(text))
    }

    private func receiveJSON(
        from socket: URLSessionWebSocketTask
    ) async throws -> [String: Any] {
        let message = try await socket.receive()
        let data: Data
        switch message {
        case .string(let text): data = Data(text.utf8)
        case .data(let receivedData): data = receivedData
        @unknown default: throw BrowserBridgeError.invalidMessage
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func authenticationProof(
        token: String,
        role: String,
        clientNonce: String,
        serverNonce: String
    ) -> String {
        let payload = "orchard-browser-bridge:v2:\(role):\(clientNonce):\(serverNonce)"
        let code = HMAC<SHA256>.authenticationCode(
            for: Data(payload.utf8),
            using: SymmetricKey(data: Data(token.utf8))
        )
        return authenticationValue(Data(code))
    }

    private func authenticationValue(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
