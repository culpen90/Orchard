import CryptoKit
import Foundation
import XCTest
@testable import Orchard

final class BrowserBridgeServiceTests: XCTestCase {
    func testAuthenticatedWebSocketRoundTripReturnsBrowserEvidence() async throws {
        let token = "test-pairing-token-that-is-long-enough"
        let port: UInt16 = 48_476
        let service = BrowserBridgeService(accessToken: token, port: port)
        try await service.waitUntilListening()

        let session = URLSession(configuration: .ephemeral)
        let socket = session.webSocketTask(
            with: URL(string: "ws://127.0.0.1:\(port)")!
        )
        socket.resume()
        defer {
            socket.cancel(with: .normalClosure, reason: nil)
            session.invalidateAndCancel()
        }

        let clientNonce = authenticationValue(Data(repeating: 0x41, count: 32))
        try await sendJSON(
            [
                "version": 1,
                "type": "hello",
                "clientNonce": clientNonce
            ],
            over: socket
        )
        let challenge = try await receiveJSON(from: socket)
        let serverNonce = try XCTUnwrap(challenge["serverNonce"] as? String)
        let serverProof = try XCTUnwrap(challenge["proof"] as? String)

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
        XCTAssertFalse(service.isExtensionConnected)

        try await sendJSON(
            [
                "version": 1,
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
        try await sendJSON(
            [
                "version": 1,
                "type": "ping"
            ],
            over: socket
        )

        let acknowledgement = try await receiveJSON(from: socket)
        let pong = try await receiveJSON(from: socket)
        XCTAssertEqual(acknowledgement["type"] as? String, "hello.ack")
        XCTAssertEqual(acknowledgement["ok"] as? Bool, true)
        XCTAssertEqual(pong["type"] as? String, "pong")
        XCTAssertTrue(service.isExtensionConnected)

        async let searchResult = service.search(query: "current orchard facts")
        let request = try await receiveJSON(from: socket)
        let requestID = try XCTUnwrap(request["id"] as? String)

        XCTAssertEqual(request["type"] as? String, "search.request")
        XCTAssertEqual(request["query"] as? String, "current orchard facts")

        try await sendJSON(
            [
                "version": 1,
                "type": "search.response",
                "id": requestID,
                "ok": true,
                "result": [
                    "pageTitle": "current orchard facts - Google Search",
                    "pageURL": "https://www.google.com/search?q=current+orchard+facts",
                    "visibleText": "Fresh browser evidence",
                    "results": [
                        [
                            "title": "Orchard facts",
                            "url": "https://example.com/facts",
                            "snippet": "A current fact from the browser."
                        ]
                    ]
                ]
            ],
            over: socket
        )

        let result = try await searchResult
        XCTAssertEqual(result.results.first?.title, "Orchard facts")
        XCTAssertEqual(result.results.first?.url, "https://example.com/facts")
        XCTAssertEqual(result.visibleText, "Fresh browser evidence")

        let cancelledSearch = Task {
            try await service.search(query: "cancel this browser lookup")
        }
        let cancellableRequest = try await receiveJSON(from: socket)
        let cancelledRequestID = try XCTUnwrap(cancellableRequest["id"] as? String)
        cancelledSearch.cancel()

        let cancellation = try await receiveJSON(from: socket)
        XCTAssertEqual(cancellation["type"] as? String, "search.cancel")
        XCTAssertEqual(cancellation["id"] as? String, cancelledRequestID)
        do {
            _ = try await cancelledSearch.value
            XCTFail("Expected the pending search to be cancelled")
        } catch {
            XCTAssertEqual(error as? BrowserBridgeError, .cancelled)
        }

        // A response already in flight after cancellation is safely ignored.
        try await sendJSON(
            [
                "version": 1,
                "type": "search.response",
                "id": cancelledRequestID,
                "ok": true,
                "result": [
                    "pageTitle": "Late result",
                    "pageURL": "https://www.google.com/search?q=late",
                    "visibleText": "Late evidence",
                    "results": []
                ]
            ],
            over: socket
        )

        async let remoteFailure = service.search(query: "bounded remote error")
        let failingRequest = try await receiveJSON(from: socket)
        let failingRequestID = try XCTUnwrap(failingRequest["id"] as? String)
        try await sendJSON(
            [
                "version": 1,
                "type": "search.response",
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

        let session = URLSession(configuration: .ephemeral)
        let socket = session.webSocketTask(
            with: URL(string: "ws://127.0.0.1:\(port)")!
        )
        socket.resume()
        defer {
            socket.cancel(with: .normalClosure, reason: nil)
            session.invalidateAndCancel()
        }

        try await sendJSON(
            [
                "version": 1,
                "type": "hello",
                "clientNonce": authenticationValue(Data(repeating: 0x42, count: 32))
            ],
            over: socket
        )
        let challenge = try await receiveJSON(from: socket)
        XCTAssertEqual(challenge["type"] as? String, "hello.challenge")

        try await sendJSON(
            [
                "version": 1,
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

    func testLegacyBearerHelloIsRejectedWithoutAValidNonce() async throws {
        let token = "test-pairing-token-that-is-long-enough"
        let port: UInt16 = 48_479
        let service = BrowserBridgeService(accessToken: token, port: port)
        try await service.waitUntilListening()

        let session = URLSession(configuration: .ephemeral)
        let socket = session.webSocketTask(
            with: URL(string: "ws://127.0.0.1:\(port)")!
        )
        socket.resume()
        defer {
            socket.cancel(with: .normalClosure, reason: nil)
            session.invalidateAndCancel()
        }

        try await sendJSON(
            [
                "version": 1,
                "type": "hello",
                "token": token
            ],
            over: socket
        )
        let rejection = try await receiveJSON(from: socket)
        let error = try XCTUnwrap(rejection["error"] as? [String: Any])

        XCTAssertEqual(rejection["type"] as? String, "hello.ack")
        XCTAssertEqual(rejection["ok"] as? Bool, false)
        XCTAssertEqual(error["code"] as? String, "invalid_nonce")
        XCTAssertFalse(service.isExtensionConnected)
    }

    func testSearchFailsClearlyWithoutConnectedExtension() async throws {
        let service = BrowserBridgeService(
            accessToken: "another-test-token-that-is-long-enough",
            port: 48_477
        )
        try await service.waitUntilListening()

        do {
            _ = try await service.search(query: "anything")
            XCTFail("Expected an extension connection error")
        } catch {
            XCTAssertEqual(error as? BrowserBridgeError, .extensionNotConnected)
        }
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
        case .string(let text):
            data = Data(text.utf8)
        case .data(let receivedData):
            data = receivedData
        @unknown default:
            throw BrowserBridgeError.invalidMessage
        }
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }

    private func authenticationProof(
        token: String,
        role: String,
        clientNonce: String,
        serverNonce: String
    ) -> String {
        let payload = "orchard-browser-bridge:v1:\(role):\(clientNonce):\(serverNonce)"
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
