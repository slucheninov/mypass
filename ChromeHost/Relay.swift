import Foundation
import Network
import ExtensionBridgeKit

enum Relay {
    static func run(tokenStore: ExtensionBridgeTokenStoring = ExtensionBridgeTokenStore()) {
        let stdin = FileHandle.standardInput
        let stdout = FileHandle.standardOutput
        let requestReader = NativeMessagingFrameReader()
        let responseReader = NativeMessagingFrameReader()

        guard let endpoint = (try? tokenStore.load()) ?? nil else {
            writeError("app_not_running", to: stdout)
            return
        }

        guard let nwPort = NWEndpoint.Port(rawValue: endpoint.port) else {
            writeError("app_not_running", to: stdout)
            return
        }
        let connection = NWConnection(host: "127.0.0.1", port: nwPort, using: .tcp)

        // NOTE (deadlock, see LoopbackServer.swift for the precedent this
        // matches): `run()`'s own stdin loop below blocks the calling thread
        // synchronously in `stdin.availableData`, and nothing here ever calls
        // `RunLoop.main.run()`/`dispatchMain()`. If the connection's state
        // callback and receive/send completions were scheduled on `.main`
        // (as the original brief snippet did), they could never actually run
        // while this thread is blocked reading stdin or waiting on
        // `readySemaphore` — a real deadlock, confirmed empirically by a
        // smoke test that hung indefinitely before this fix. Using a private
        // serial queue for the connection means its callbacks run on a
        // dedicated background thread regardless of what the calling thread
        // (blocked on stdin, or waiting on the semaphore) is doing.
        let connectionQueue = DispatchQueue(label: "com.mypass.chromehost.relay.connection")

        let readySemaphore = DispatchSemaphore(value: 0)
        var connectionFailed = false
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                readySemaphore.signal()
            case .failed, .cancelled:
                connectionFailed = true
                readySemaphore.signal()
            case .waiting:
                // A refused loopback connection (MyPass.app not running, or
                // its listener already torn down) lands NWConnection in
                // `.waiting` with the underlying POSIX error attached, NOT
                // `.failed` — Network.framework's default behavior treats a
                // refused connection as transient and would keep retrying
                // indefinitely on its own. That default is wrong for this
                // relay: Chrome is waiting synchronously for a response, so
                // treat `.waiting` the same as `.failed` here rather than
                // silently exhausting the 5s timeout with no error reported
                // (confirmed empirically: without this case, the "app not
                // running" smoke test produced zero output on stdout).
                connectionFailed = true
                readySemaphore.signal()
            default:
                break
            }
        }
        connection.start(queue: connectionQueue)
        _ = readySemaphore.wait(timeout: .now() + 5)

        guard !connectionFailed else {
            writeError("app_not_running", to: stdout)
            return
        }

        func receiveResponses() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    // See NativeMessagingFrameReader.feed's doc comment: it now
                    // throws `frameTooLarge` instead of silently misbehaving.
                    // A malicious/buggy peer on the TCP side shouldn't be able
                    // to take down the relay process, so log to stderr (never
                    // stdout — that's Chrome's native-messaging channel) and
                    // stop trusting this connection's byte stream rather than
                    // crashing, matching main.swift's Task 8 echo-loop
                    // convention.
                    do {
                        for frame in try responseReader.feed(data) {
                            stdout.write(NativeMessagingCodec.encode(frame))
                        }
                    } catch {
                        FileHandle.standardError.write(Data("ChromeHost: response frame read error: \(error)\n".utf8))
                        connection.cancel()
                        return
                    }
                }
                if isComplete || error != nil {
                    return
                }
                receiveResponses()
            }
        }
        receiveResponses()

        while true {
            let chunk = stdin.availableData
            if chunk.isEmpty {
                break
            }
            let frames: [Data]
            do {
                frames = try requestReader.feed(chunk)
            } catch {
                // Same rationale as above: an oversized claimed frame length
                // desyncs the byte stream, so stop trusting stdin rather than
                // crashing the relay process.
                FileHandle.standardError.write(Data("ChromeHost: request frame read error: \(error)\n".utf8))
                break
            }
            for frame in frames {
                guard let framedRequest = try? RelayTokenInjector.injectToken(into: frame, token: endpoint.token) else {
                    writeError("malformed_request", to: stdout)
                    continue
                }
                connection.send(content: NativeMessagingCodec.encode(framedRequest), completion: .contentProcessed { _ in })
            }
        }

        connection.cancel()
    }

    private static func writeError(_ message: String, to handle: FileHandle) {
        let payload = Data("{\"type\":\"error\",\"message\":\"\(message)\"}".utf8)
        handle.write(NativeMessagingCodec.encode(payload))
    }
}
