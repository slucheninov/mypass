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
    private var listener: NWListener?
    private var activeConnections: [NWConnection] = []
    private var token: String = ""

    private(set) var port: UInt16?

    init(tokenStore: ExtensionBridgeTokenStoring, handler: @escaping (ExtensionBridgeRequest) -> ExtensionBridgeResponse) {
        self.tokenStore = tokenStore
        self.handler = handler
    }

    static func isValidToken(_ candidate: String, expected: String) -> Bool {
        !candidate.isEmpty && candidate == expected
    }

    func start() throws {
        let newListener = try NWListener(using: .tcp, on: .any)
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

        listener = newListener
        port = assignedPort.rawValue
        token = generatedToken
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
        activeConnections.append(connection)
        let reader = NativeMessagingFrameReader()
        connection.start(queue: queue)
        receive(on: connection, reader: reader)
    }

    private func receive(on connection: NWConnection, reader: NativeMessagingFrameReader) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                for frame in reader.feed(data) {
                    self.handleFrame(frame, on: connection)
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
        case .getCredentials(let token, _): return token
        case .fillCredential(let token, _, _): return token
        case .proposeSaveLogin(let token, _, _, _): return token
        }
    }

    private func send(_ response: ExtensionBridgeResponse, on connection: NWConnection) {
        guard let payload = try? JSONEncoder().encode(response) else { return }
        connection.send(content: NativeMessagingCodec.encode(payload), completion: .contentProcessed { _ in })
    }
}
