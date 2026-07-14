import CryptoKit
import Foundation
import Network

final class BrowserBridgeService: BrowserControlling, @unchecked Sendable {
    static let shared = BrowserBridgeService()
    static let defaultPort: UInt16 = 38_476

    let accessToken: String
    let port: UInt16

    private let queue = DispatchQueue(label: "com.culpen90.Orchard.browser-bridge")
    private let lock = NSLock()
    private let pendingCommands = BrowserBridgePendingCommands()
    private var listener: NWListener?
    private var activeConnection: NWConnection?
    private var activeConnectionGeneration: UInt64 = 0
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

    var connectionGeneration: UInt64 {
        lock.withLock { activeConnectionGeneration }
    }

    var isListenerReady: Bool {
        lock.withLock { listenerReady }
    }

    var listenerErrorDescription: String? {
        lock.withLock { listenerFailure }
    }

    func perform(_ command: BrowserCommand) async throws -> BrowserCommandResult {
        try await perform(
            command,
            expectedConnectionGeneration: connectionGeneration
        )
    }

    func perform(
        _ command: BrowserCommand,
        expectedConnectionGeneration: UInt64
    ) async throws -> BrowserCommandResult {
        let command = try command.validatedForSending()
        let status = lock.withLock {
            (
                listenerReady,
                listenerFailure,
                activeConnection,
                activeConnectionGeneration
            )
        }
        if status.1 != nil || !status.0 {
            throw BrowserBridgeError.listenerUnavailable
        }
        guard status.3 == expectedConnectionGeneration else {
            throw BrowserBridgeError.staleConnection
        }
        guard let connection = status.2 else {
            throw BrowserBridgeError.extensionNotConnected
        }

        let request = BrowserBridgeCommandRequest(id: UUID(), command: command)
        let result = try await pendingCommands.perform(
            request: request,
            connectionGeneration: status.3,
            send: { [weak self, weak connection] message in
                guard let self, let connection else {
                    throw BrowserBridgeError.cancelled
                }
                try await self.send(message, over: connection)
            },
            cancel: { [weak self, weak connection] id in
                guard let self, let connection else {
                    return
                }
                try? await self.send(
                    BrowserBridgeCommandCancellation(id: id),
                    over: connection
                )
            }
        )
        return try result.validated(for: command.action)
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
            Task { await pendingCommands.failAll(with: .outcomeUnknown) }
        case .cancelled:
            lock.withLock {
                listenerReady = false
            }
            Task { await pendingCommands.failAll(with: .outcomeUnknown) }
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
            message.version == 2
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

            let requiredCapabilities = Set(BrowserCommandAction.allCases.map(\.rawValue))
            guard let capabilities = message.capabilities,
                  requiredCapabilities.isSubset(of: Set(capabilities))
            else {
                await rejectHandshake(
                    connection,
                    code: "incompatible_extension",
                    message: "This extension does not support Orchard browser control protocol v2. Reload the bundled extension."
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

            let replacement = lock.withLock { () -> (NWConnection?, UInt64?) in
                let oldConnection = activeConnection
                let oldGeneration = oldConnection == nil
                    ? nil
                    : activeConnectionGeneration
                activeConnectionGeneration &+= 1
                activeConnection = connection
                return (oldConnection, oldGeneration)
            }
            if let oldGeneration = replacement.1 {
                await pendingCommands.invalidate(
                    through: oldGeneration,
                    with: .connectionChanged
                )
            }
            if let previous = replacement.0, previous !== connection {
                previous.cancel()
            }
            try? await send(BrowserBridgeHandshakeResponse(ok: true), over: connection)

        case "ping":
            guard isActive(connection) else {
                connection.cancel()
                return
            }
            try? await send(BrowserBridgeControlMessage(type: "pong"), over: connection)

        case "browser.response":
            guard isActive(connection), let id = message.id, let ok = message.ok else {
                connection.cancel()
                return
            }
            if ok, let result = message.result {
                await pendingCommands.complete(id: id, result: result)
            } else if let remoteError = message.error {
                let sanitizedError = Self.sanitizedRemoteError(remoteError)
                await pendingCommands.fail(
                    id: id,
                    with: .remote(
                        code: sanitizedError.code,
                        message: sanitizedError.message
                    )
                )
            } else {
                await pendingCommands.fail(id: id, with: .outcomeUnknown)
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

        Task { await pendingCommands.failAll(with: .outcomeUnknown) }
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
        let payload = "orchard-browser-bridge:v2:\(role):\(clientNonce):\(serverNonce)"
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

private actor BrowserBridgePendingCommands {
    typealias Continuation = CheckedContinuation<BrowserCommandResult, any Error>

    private struct Entry {
        let connectionGeneration: UInt64
        let continuation: Continuation
    }

    private var pending: [UUID: Entry] = [:]
    private var highestInvalidatedGeneration: UInt64?

    func perform(
        request: BrowserBridgeCommandRequest,
        connectionGeneration: UInt64,
        send: @escaping @Sendable (BrowserBridgeCommandRequest) async throws -> Void,
        cancel: @escaping @Sendable (UUID) async -> Void
    ) async throws -> BrowserCommandResult {
        if let highestInvalidatedGeneration,
           connectionGeneration <= highestInvalidatedGeneration {
            throw BrowserBridgeError.connectionChanged
        }
        return try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
            } catch {
                throw BrowserBridgeError.cancelled
            }

            return try await withCheckedThrowingContinuation { continuation in
                pending[request.id] = Entry(
                    connectionGeneration: connectionGeneration,
                    continuation: continuation
                )
                if Task.isCancelled {
                    fail(id: request.id, with: .cancelled)
                    return
                }

                Task {
                    do {
                        try await send(request)
                    } catch {
                        fail(id: request.id, with: .outcomeUnknown)
                    }
                }

                Task {
                    try? await Task.sleep(for: .seconds(45))
                    guard !Task.isCancelled else {
                        return
                    }
                    if fail(id: request.id, with: .outcomeUnknown) {
                        await cancel(request.id)
                    }
                }
            }
        } onCancel: {
            Task {
                if await self.fail(id: request.id, with: .outcomeUnknown) {
                    await cancel(request.id)
                }
            }
        }
    }

    func complete(id: UUID, result: BrowserCommandResult) {
        pending.removeValue(forKey: id)?.continuation.resume(returning: result)
    }

    @discardableResult
    func fail(id: UUID, with error: BrowserBridgeError) -> Bool {
        guard let entry = pending.removeValue(forKey: id) else {
            return false
        }
        entry.continuation.resume(throwing: error)
        return true
    }

    func invalidate(
        through connectionGeneration: UInt64,
        with error: BrowserBridgeError
    ) {
        if let highestInvalidatedGeneration {
            self.highestInvalidatedGeneration = max(
                highestInvalidatedGeneration,
                connectionGeneration
            )
        } else {
            highestInvalidatedGeneration = connectionGeneration
        }

        let invalidatedIDs = pending.compactMap { id, entry in
            entry.connectionGeneration <= connectionGeneration ? id : nil
        }
        for id in invalidatedIDs {
            pending.removeValue(forKey: id)?.continuation.resume(throwing: error)
        }
    }

    func failAll(with error: BrowserBridgeError) {
        let entries = pending.values
        pending.removeAll()
        for entry in entries {
            entry.continuation.resume(throwing: error)
        }
    }
}
