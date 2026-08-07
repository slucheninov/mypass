import Foundation
import Network
import ExtensionBridgeKit

/// TCP listener on 127.0.0.1, random OS-assigned port, guarding every request
/// with a per-launch token persisted to Keychain (Task 3). Owns no UI state —
/// delegates request handling entirely to the injected `handler` closure
/// (`ExtensionBridgeService.handle`, wired in Task 7), dispatched onto the
/// main thread since it touches `VaultSession`.
final class LoopbackServer {
    enum LoopbackServerError: Error {
        case listenerFailed
        case timedOut
    }

    private let tokenStore: ExtensionBridgeTokenStoring
    private let handler: (ExtensionBridgeRequest) -> ExtensionBridgeResponse
    /// All Network.framework I/O (listener + connection callbacks) runs on this
    /// private serial queue, never on `.main`. `start()` blocks its *calling*
    /// thread on a semaphore waiting for the listener's `.ready` state; if that
    /// state callback were scheduled on `.main` and `start()` is itself called
    /// from the main thread (as it will be, from `MyPassApp.init()` in Task 7,
    /// and from this file's own tests), the wait would deadlock forever — the
    /// callback can never run on a thread that's synchronously blocked waiting
    /// for it. Only the `handler` invocation (which touches `VaultSession`,
    /// main-thread-only) is explicitly hopped onto `.main` in `handleFrame`.
    private let queue = DispatchQueue(label: "com.mypass.extensionbridge.loopback")
    private let maxConcurrentConnections: Int
    private var listener: NWListener?
    private var activeConnections: [NWConnection] = []
    private var token: String = ""

    private(set) var port: UInt16?

    init(
        tokenStore: ExtensionBridgeTokenStoring,
        handler: @escaping (ExtensionBridgeRequest) -> ExtensionBridgeResponse,
        maxConcurrentConnections: Int = 16
    ) {
        self.tokenStore = tokenStore
        self.handler = handler
        self.maxConcurrentConnections = maxConcurrentConnections
    }

    /// Constant-time comparison: an early-exit `==` would let an attacker
    /// probing the loopback port (any local process can connect) infer the
    /// token's prefix length one byte at a time from response-time
    /// differences. XOR-accumulating over every byte before branching once
    /// removes that timing signal.
    static func isValidToken(_ candidate: String, expected: String) -> Bool {
        guard !candidate.isEmpty else { return false }
        let candidateBytes = Array(candidate.utf8)
        let expectedBytes = Array(expected.utf8)
        guard candidateBytes.count == expectedBytes.count else { return false }
        var difference: UInt8 = 0
        for i in 0..<candidateBytes.count {
            difference |= candidateBytes[i] ^ expectedBytes[i]
        }
        return difference == 0
    }

    func start() throws {
        // `.tcp` alone binds the wildcard address (all interfaces) — not
        // loopback-only. Restricting to `.loopback` confines the listener to
        // 127.0.0.1/::1 so it's unreachable from other devices on the LAN,
        // even though the port is randomly OS-assigned.
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        let newListener = try NWListener(using: parameters, on: .any)
        let semaphore = DispatchSemaphore(value: 0)
        var startError: Error?

        newListener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                semaphore.signal()
            case .failed:
                startError = LoopbackServerError.listenerFailed
                semaphore.signal()
            default:
                break
            }
        }
        newListener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        newListener.start(queue: queue)

        guard semaphore.wait(timeout: .now() + 5) == .success,
              startError == nil,
              let assignedPort = newListener.port else {
            newListener.cancel()
            throw startError ?? LoopbackServerError.timedOut
        }

        let generatedToken = ExtensionBridgeTokenStore.generateToken()
        try tokenStore.save(ExtensionBridgeEndpoint(port: assignedPort.rawValue, token: generatedToken))

        // `listener`/`port`/`token` are read from `queue` (via `accept`,
        // `handleFrame`, etc.), so writing them must also happen on `queue`
        // to avoid a data race with the calling thread (typically `.main`).
        // Safe to `sync` here: the listener is already `.ready` and `queue`
        // isn't blocked on anything at this point.
        queue.sync {
            listener = newListener
            port = assignedPort.rawValue
            token = generatedToken
        }
    }

    func stop() {
        // `accept`/`receive` mutate `listener`/`activeConnections` on `queue`;
        // synchronize here (may be called from any thread, e.g. main) so
        // teardown doesn't race an in-flight accept/receive callback.
        queue.sync {
            listener?.cancel()
            listener = nil
            activeConnections.forEach { $0.cancel() }
            activeConnections.removeAll()
        }
    }

    private func accept(_ connection: NWConnection) {
        // Cap concurrent connections against the now-reachable (if
        // loopback-only) socket — an unbounded accept loop is itself a
        // resource-exhaustion surface even with the frame-size guard below.
        // Connections beyond the cap are cancelled before `start()`, so the
        // accept never completes at the application layer.
        guard activeConnections.count < maxConcurrentConnections else {
            connection.cancel()
            return
        }
        activeConnections.append(connection)
        let reader = NativeMessagingFrameReader()
        connection.start(queue: queue)
        receive(on: connection, reader: reader)
    }

    private func receive(on connection: NWConnection, reader: NativeMessagingFrameReader) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                do {
                    for frame in try reader.feed(data) {
                        self.handleFrame(frame, on: connection)
                    }
                } catch {
                    // Claimed frame length exceeded the cap: the byte stream
                    // can no longer be trusted to be frame-aligned, so the
                    // connection is not salvageable — report and close it
                    // rather than continuing to read. `cancel()` is deferred
                    // to the send's completion handler: calling it right
                    // after issuing an async `send` can tear the connection
                    // down before the queued bytes are actually flushed to
                    // the socket, silently dropping the error response.
                    self.sendAndClose(.error("frame too large"), on: connection)
                    return
                }
            }
            if isComplete || error != nil {
                connection.cancel()
                self.activeConnections.removeAll { $0 === connection }
                return
            }
            self.receive(on: connection, reader: reader)
        }
    }

    private func handleFrame(_ frame: Data, on connection: NWConnection) {
        guard let request = try? JSONDecoder().decode(ExtensionBridgeRequest.self, from: frame) else {
            send(.error("malformed request"), on: connection)
            return
        }
        guard LoopbackServer.isValidToken(requestToken(from: request), expected: token) else {
            send(.error("invalid token"), on: connection)
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let response = self.handler(request)
            self.send(response, on: connection)
        }
    }

    private func requestToken(from request: ExtensionBridgeRequest) -> String {
        switch request {
        case .getCredentials(let token, _, _): return token
        case .fillCredential(let token, _, _, _): return token
        case .proposeSaveLogin(let token, _, _, _, _): return token
        case .startPairing(let token, _): return token
        case .completePairing(let token, _): return token
        case .requestUnlock(let token, _): return token
        }
    }

    private func send(_ response: ExtensionBridgeResponse, on connection: NWConnection) {
        guard let payload = try? JSONEncoder().encode(response) else { return }
        connection.send(content: NativeMessagingCodec.encode(payload), completion: .contentProcessed { _ in })
    }

    /// Sends `response` and only cancels/deregisters the connection once the
    /// send has actually completed, so a fatal-error response (e.g. an
    /// oversized claimed frame length) isn't dropped by a `cancel()` racing
    /// ahead of its own outbound bytes.
    private func sendAndClose(_ response: ExtensionBridgeResponse, on connection: NWConnection) {
        guard let payload = try? JSONEncoder().encode(response) else {
            connection.cancel()
            activeConnections.removeAll { $0 === connection }
            return
        }
        connection.send(content: NativeMessagingCodec.encode(payload), completion: .contentProcessed { [weak self] _ in
            connection.cancel()
            self?.activeConnections.removeAll { $0 === connection }
        })
    }
}
