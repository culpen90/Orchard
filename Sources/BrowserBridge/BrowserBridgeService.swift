import CryptoKit
import Foundation
import Network

final class BrowserBridgeService: BrowserSearching, @unchecked Sendable {
    static let shared = BrowserBridgeService()
    static let defaultPort: UInt16 = 38_476

    let accessToken: String
    let port: UInt16

    private let queue = DispatchQueue(label: "com.culpen90.Orchard.browser-bridge")
    private let lock = NSLock()
    private let pendingSearches = BrowserBridgePendingSearches()
    private var listener: NWListener?
    private var activeConnection: NWConnection?
    private var pendingHandshakes: [ObjectIdentifier: BrowserBridgePendingHandshake] = [:]
    private var listenerReady = false
    private var listenerFailure: String?

    init(
        accessToken: String = BrowserBridgeService.loadOrCreateAccessToken(),
        port: UInt16 = BrowserBridgeService.defaultPort
    ) {
        self.accessToken = accessToken
        self.port = port
        startListener()
    }

    deinit {
        listener?.cancel()
        activeConnection?.cancel()
    }

    var isExtensionConnected: Bool {
        lock.withLock { activeConnection != nil }
    }

    var isListenerReady: Bool {
        lock.withLock { listenerReady }
    }

    var listenerErrorDescription: String? {
        lock.withLock { listenerFailure }
    }

    func search(query: String) async throws -> BrowserSearchResult {
        let cleanedQuery = BrowserSearchResult.cleaned(query, maximumLength: 1_000)
        guard !cleanedQuery.isEmpty else {
            throw BrowserBridgeError.invalidMessage
        }

        let status = lock.withLock { (listenerReady, listenerFailure, activeConnection != nil) }
        if status.1 != nil || !status.0 {
            throw BrowserBridgeError.listenerUnavailable
        }
        guard status.2 else {
            throw BrowserBridgeError.extensionNotConnected
        }

        let request = BrowserBridgeSearchRequest(id: UUID(), query: cleanedQuery)
        let result = try await pendingSearches.perform(
            request: request,
            send: { [weak self] message in
                guard let self else {
                    throw BrowserBridgeError.cancelled
                }
                try await self.send(message)
            },
            cancel: { [weak self] id in
                guard let self else {
                    return
                }
                try? await self.send(BrowserBridgeSearchCancellation(id: id))
            }
        )
        return try result.validated()
    }

    func waitUntilListening(timeout: Duration = .seconds(3)) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            let status = lock.withLock { (listenerReady, listenerFailure) }
            if status.0 {
                return
            }
            if let failure = status.1 {
                throw BrowserBridgeError.connectionFailed(failure)
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw BrowserBridgeError.listenerUnavailable
    }

    private func startListener() {
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            parameters.includePeerToPeer = false
            parameters.requiredLocalEndpoint = .hostPort(
                host: "127.0.0.1",
                port: NWEndpoint.Port(rawValue: port)!
            )

            let webSocketOptions = NWProtocolWebSocket.Options()
            webSocketOptions.autoReplyPing = true
            parameters.defaultProtocolStack.applicationProtocols.insert(
                webSocketOptions,
                at: 0
            )

            let listener = try NWListener(using: parameters)
            listener.stateUpdateHandler = { [weak self] state in
                self?.handle(listenerState: state)
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            self.listener = listener
            listener.start(queue: queue)
        } catch {
            lock.withLock {
                listenerFailure = error.localizedDescription
            }
        }
    }

    private func handle(listenerState state: NWListener.State) {
        switch state {
        case .ready:
            lock.withLock {
                listenerReady = true
                listenerFailure = nil
            }
        case .failed(let error):
            lock.withLock {
                listenerReady = false
                listenerFailure = error.localizedDescription
            }
            Task { await pendingSearches.failAll(with: .listenerUnavailable) }
        case .cancelled:
            lock.withLock {
                listenerReady = false
            }
            Task { await pendingSearches.failAll(with: .listenerUnavailable) }
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else {
                return
            }
            switch state {
            case .ready:
                self.receiveNextMessage(from: connection)
                self.expireIfUnauthenticated(connection)
            case .failed(let error):
                self.remove(connection, error: error.localizedDescription)
            case .cancelled:
                self.remove(connection, error: nil)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func receiveNextMessage(from connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] data, _, _, error in
            guard let self, let connection else {
                return
            }

            if let error {
                self.remove(connection, error: error.localizedDescription)
                return
            }

            guard let data, data.count <= 131_072 else {
                connection.cancel()
                return
            }

            Task {
                await self.process(data: data, from: connection)
                if self.shouldContinueReceiving(from: connection) {
                    self.receiveNextMessage(from: connection)
                }
            }
        }
    }

    private func process(data: Data, from connection: NWConnection) async {
        guard
            let message = try? JSONDecoder().decode(BrowserBridgeIncomingMessage.self, from: data),
            message.version == 1
        else {
            connection.cancel()
            return
        }

        switch message.type {
        case "hello":
            guard let clientNonce = message.clientNonce,
                  Self.decodeAuthenticationValue(clientNonce) != nil
            else {
                await rejectHandshake(
                    connection,
                    code: "invalid_nonce",
                    message: "Invalid authentication nonce."
                )
                return
            }

            let serverNonce = Self.makeAuthenticationNonce()
            let challenge = BrowserBridgePendingHandshake(
                clientNonce: clientNonce,
                serverNonce: serverNonce
            )
            lock.withLock {
                pendingHandshakes[ObjectIdentifier(connection)] = challenge
            }

            do {
                try await send(
                    BrowserBridgeHandshakeChallenge(
                        serverNonce: serverNonce,
                        proof: Self.authenticationProof(
                            role: "server",
                            clientNonce: clientNonce,
                            serverNonce: serverNonce,
                            token: accessToken
                        )
                    ),
                    over: connection
                )
            } catch {
                remove(connection, error: error.localizedDescription)
                connection.cancel()
            }

        case "hello.authenticate":
            let connectionID = ObjectIdentifier(connection)
            guard let proof = message.proof,
                  let suppliedProof = Self.decodeAuthenticationValue(proof),
                  let challenge = lock.withLock({ pendingHandshakes.removeValue(forKey: connectionID) })
            else {
                await rejectHandshake(
                    connection,
                    code: "invalid_proof",
                    message: "Invalid pairing proof."
                )
                return
            }

            let expectedProof = Self.authenticationProof(
                role: "client",
                clientNonce: challenge.clientNonce,
                serverNonce: challenge.serverNonce,
                token: accessToken
            )
            guard let expectedProofData = Self.decodeAuthenticationValue(expectedProof),
                  Self.authenticationValuesMatch(suppliedProof, expectedProofData)
            else {
                await rejectHandshake(
                    connection,
                    code: "invalid_proof",
                    message: "Invalid pairing proof."
                )
                return
            }

            let previous = lock.withLock { () -> NWConnection? in
                let oldConnection = activeConnection
                activeConnection = connection
                return oldConnection
            }
            if let previous, previous !== connection {
                previous.cancel()
            }
            try? await send(BrowserBridgeHandshakeResponse(ok: true), over: connection)

        case "ping":
            guard isActive(connection) else {
                connection.cancel()
                return
            }
            try? await send(BrowserBridgeControlMessage(type: "pong"), over: connection)

        case "search.response":
            guard isActive(connection), let id = message.id, let ok = message.ok else {
                connection.cancel()
                return
            }
            if ok, let result = message.result {
                await pendingSearches.complete(id: id, result: result)
            } else if let remoteError = message.error {
                let sanitizedError = Self.sanitizedRemoteError(remoteError)
                await pendingSearches.fail(
                    id: id,
                    with: .remote(
                        code: sanitizedError.code,
                        message: sanitizedError.message
                    )
                )
            } else {
                await pendingSearches.fail(id: id, with: .invalidResponse)
            }

        default:
            connection.cancel()
        }
    }

    private func isActive(_ connection: NWConnection) -> Bool {
        lock.withLock { activeConnection === connection }
    }

    private func shouldContinueReceiving(from connection: NWConnection) -> Bool {
        lock.withLock {
            activeConnection === connection ||
                pendingHandshakes[ObjectIdentifier(connection)] != nil
        }
    }

    private func expireIfUnauthenticated(_ connection: NWConnection) {
        queue.asyncAfter(deadline: .now() + .seconds(5)) { [weak self, weak connection] in
            guard let self, let connection else {
                return
            }
            let shouldCancel = self.lock.withLock { () -> Bool in
                guard self.activeConnection !== connection else {
                    return false
                }
                self.pendingHandshakes.removeValue(forKey: ObjectIdentifier(connection))
                return true
            }
            if shouldCancel {
                connection.cancel()
            }
        }
    }

    private func rejectHandshake(
        _ connection: NWConnection,
        code: String,
        message: String
    ) async {
        lock.withLock {
            _ = pendingHandshakes.removeValue(forKey: ObjectIdentifier(connection))
        }
        try? await send(
            BrowserBridgeHandshakeResponse(
                ok: false,
                error: BrowserBridgeRemoteError(code: code, message: message)
            ),
            over: connection
        )
        connection.cancel()
    }

    private func remove(_ connection: NWConnection, error: String?) {
        let removedActiveConnection = lock.withLock { () -> Bool in
            pendingHandshakes.removeValue(forKey: ObjectIdentifier(connection))
            guard activeConnection === connection else {
                return false
            }
            activeConnection = nil
            return true
        }
        guard removedActiveConnection else {
            return
        }

        let bridgeError: BrowserBridgeError = if let error {
            .connectionFailed(error)
        } else {
            .extensionNotConnected
        }
        Task { await pendingSearches.failAll(with: bridgeError) }
    }

    private func send<Message: Encodable>(_ message: Message) async throws {
        guard let connection = lock.withLock({ activeConnection }) else {
            throw BrowserBridgeError.extensionNotConnected
        }
        try await send(message, over: connection)
    }

    private func send<Message: Encodable>(
        _ message: Message,
        over connection: NWConnection
    ) async throws {
        let data = try JSONEncoder().encode(message)
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(
            identifier: "orchard-browser-bridge-message",
            metadata: [metadata]
        )

        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(
                content: data,
                contentContext: context,
                isComplete: true,
                completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(
                            throwing: BrowserBridgeError.connectionFailed(
                                error.localizedDescription
                            )
                        )
                    } else {
                        continuation.resume()
                    }
                }
            )
        }
    }

    private static func loadOrCreateAccessToken() -> String {
        let defaultsKey = "browserBridge.pairingToken"
        if let existing = UserDefaults.standard.string(forKey: defaultsKey),
           existing.count >= 32
        {
            return existing
        }

        let token = (
            UUID().uuidString + UUID().uuidString
        ).replacingOccurrences(of: "-", with: "")
        UserDefaults.standard.set(token, forKey: defaultsKey)
        return token
    }

    private static func makeAuthenticationNonce() -> String {
        let key = SymmetricKey(size: .bits256)
        let bytes = key.withUnsafeBytes { Data($0) }
        return base64URLEncode(bytes)
    }

    private static func authenticationProof(
        role: String,
        clientNonce: String,
        serverNonce: String,
        token: String
    ) -> String {
        let payload = "orchard-browser-bridge:v1:\(role):\(clientNonce):\(serverNonce)"
        let authenticationCode = HMAC<SHA256>.authenticationCode(
            for: Data(payload.utf8),
            using: SymmetricKey(data: Data(token.utf8))
        )
        return base64URLEncode(Data(authenticationCode))
    }

    private static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func decodeAuthenticationValue(_ value: String) -> Data? {
        guard value.count == 43,
              value.unicodeScalars.allSatisfy({ scalar in
                  (48...57).contains(scalar.value) ||
                      (65...90).contains(scalar.value) ||
                      (97...122).contains(scalar.value) ||
                      scalar.value == 45 || scalar.value == 95
              })
        else {
            return nil
        }

        let base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/") + "="
        guard let data = Data(base64Encoded: base64),
              data.count == 32,
              base64URLEncode(data) == value
        else {
            return nil
        }
        return data
    }

    private static func authenticationValuesMatch(_ supplied: Data, _ expected: Data) -> Bool {
        guard supplied.count == expected.count else {
            return false
        }
        var difference: UInt8 = 0
        for index in supplied.indices {
            difference |= supplied[index] ^ expected[index]
        }
        return difference == 0
    }

    private static func sanitizedRemoteError(
        _ error: BrowserBridgeRemoteError
    ) -> BrowserBridgeRemoteError {
        let codeScalars = error.code.unicodeScalars.filter { scalar in
            (48...57).contains(scalar.value) ||
                (65...90).contains(scalar.value) ||
                (97...122).contains(scalar.value) ||
                scalar.value == 45 || scalar.value == 46 || scalar.value == 95
        }
        let code = String(String.UnicodeScalarView(codeScalars)).prefix(64)

        let messageScalars = error.message.unicodeScalars.map { scalar -> String in
            CharacterSet.controlCharacters.contains(scalar) ? " " : String(scalar)
        }
        let normalizedMessage = messageScalars
            .joined()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")

        return BrowserBridgeRemoteError(
            code: code.isEmpty ? "browser_error" : String(code),
            message: normalizedMessage.isEmpty
                ? "The browser extension reported an error."
                : String(normalizedMessage.prefix(500))
        )
    }
}

private struct BrowserBridgePendingHandshake: Equatable {
    let clientNonce: String
    let serverNonce: String
}

private actor BrowserBridgePendingSearches {
    typealias Continuation = CheckedContinuation<BrowserSearchResult, any Error>

    private var pending: [UUID: Continuation] = [:]

    func perform(
        request: BrowserBridgeSearchRequest,
        send: @escaping @Sendable (BrowserBridgeSearchRequest) async throws -> Void,
        cancel: @escaping @Sendable (UUID) async -> Void
    ) async throws -> BrowserSearchResult {
        try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
            } catch {
                throw BrowserBridgeError.cancelled
            }

            return try await withCheckedThrowingContinuation { continuation in
                pending[request.id] = continuation
                if Task.isCancelled {
                    fail(id: request.id, with: .cancelled)
                    return
                }

                Task {
                    do {
                        try await send(request)
                    } catch let error as BrowserBridgeError {
                        fail(id: request.id, with: error)
                    } catch {
                        fail(
                            id: request.id,
                            with: .connectionFailed(error.localizedDescription)
                        )
                    }
                }

                Task {
                    try? await Task.sleep(for: .seconds(45))
                    guard !Task.isCancelled else {
                        return
                    }
                    if fail(id: request.id, with: .timedOut) {
                        await cancel(request.id)
                    }
                }
            }
        } onCancel: {
            Task {
                if await self.fail(id: request.id, with: .cancelled) {
                    await cancel(request.id)
                }
            }
        }
    }

    func complete(id: UUID, result: BrowserSearchResult) {
        pending.removeValue(forKey: id)?.resume(returning: result)
    }

    @discardableResult
    func fail(id: UUID, with error: BrowserBridgeError) -> Bool {
        guard let continuation = pending.removeValue(forKey: id) else {
            return false
        }
        continuation.resume(throwing: error)
        return true
    }

    func failAll(with error: BrowserBridgeError) {
        let continuations = pending.values
        pending.removeAll()
        for continuation in continuations {
            continuation.resume(throwing: error)
        }
    }
}
