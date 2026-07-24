import Foundation
import Crypto
import NIO
import NIOFoundationCompat
import NIOSSH
import Citadel
import MyPassKit

public enum SFTPBackendError: Error {
    case invalidPrivateKey
    case remoteWriteVerificationFailed
}

public struct SFTPBackendConfiguration {
    public var host: String
    public var port: Int
    public var username: String
    public var remotePath: String
    public var privateKeyPEM: String
    public var privateKeyPassphrase: String?

    public init(
        host: String,
        port: Int = 22,
        username: String,
        remotePath: String,
        privateKeyPEM: String,
        privateKeyPassphrase: String? = nil
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.remotePath = remotePath
        self.privateKeyPEM = privateKeyPEM
        self.privateKeyPassphrase = privateKeyPassphrase
    }

    /// The key `TrustedHostKeyStore` uses to remember this host's SSH host
    /// key across connections — distinct hosts (or the same host on a
    /// distinct port) must be tracked independently.
    public var hostKeyIdentifier: String { "\(host):\(port)" }
}

/// `StorageBackend` over SFTP, via Citadel.
///
/// Citadel's SFTP client (`SSHClient`, `SFTPClient`, `SFTPFile`) is entirely
/// `async`/`await`-based, while `StorageBackend` (Task 1) is a synchronous
/// protocol. `runSSHSync(_:)` is the bridge: it runs the given async closure
/// on a detached `Task`, blocking the CALLING thread on a `DispatchSemaphore`
/// until that `Task` completes, then re-throws whatever error (if any) the
/// async closure produced. This is safe here because every call into
/// `SFTPBackend` arrives via `SyncEngine.sync(...)` (Task 6), which is only
/// ever invoked from `VaultSession`'s (Task 7) already-synchronous,
/// already-off-the-main-thread contexts (`unlock(password:)`'s call to
/// `syncOnUnlock`, and `persist(_:)`'s dedicated serial `persistQueue`) —
/// never from the main thread's run loop — so blocking on the semaphore here
/// cannot deadlock the UI.
public final class SFTPBackend: StorageBackend {
    private let configuration: SFTPBackendConfiguration
    private let trustedHostKeyStore: TrustedHostKeyStore
    private let group: MultiThreadedEventLoopGroup

    public init(
        configuration: SFTPBackendConfiguration,
        trustedHostKeyStore: TrustedHostKeyStore,
        group: MultiThreadedEventLoopGroup = .singleton
    ) {
        self.configuration = configuration
        self.trustedHostKeyStore = trustedHostKeyStore
        self.group = group
    }

    public func exists() throws -> Bool {
        try runSSHSync { sftp in
            // SFTP's SSH_FXP_STAT fails (Citadel surfaces this as a thrown
            // error) when the path does not exist, so a successful
            // getAttributes(at:) is itself the existence check.
            do {
                _ = try await sftp.getAttributes(at: self.configuration.remotePath)
                return true
            } catch {
                return false
            }
        }
    }

    public func modificationDate() throws -> Date? {
        try runSSHSync { sftp in
            let attributes = try await sftp.getAttributes(at: self.configuration.remotePath)
            return attributes.accessModificationTime?.modificationTime
        }
    }

    public func read() throws -> Data? {
        try runSSHSync { sftp in
            do {
                return try await sftp.withFile(filePath: self.configuration.remotePath, flags: .read) { file in
                    let buffer = try await file.readAll()
                    return Data(buffer: buffer)
                }
            } catch {
                return nil
            }
        }
    }

    public func write(_ data: Data) throws {
        try runSSHSync { sftp in
            let remotePath = self.configuration.remotePath
            let temporaryRemotePath = remotePath + ".tmp-\(UUID().uuidString)"
            let buffer = ByteBuffer(data: data)

            try await sftp.withFile(filePath: temporaryRemotePath, flags: [.write, .create, .truncate]) { file in
                try await file.write(buffer, at: 0)
            }

            // Verify what was actually written before it replaces the real
            // file — an interrupted or corrupted upload must never clobber
            // a good remote copy with a bad one.
            let verifiedData: Data = try await sftp.withFile(filePath: temporaryRemotePath, flags: .read) { file in
                let readBuffer = try await file.readAll()
                return Data(buffer: readBuffer)
            }
            guard verifiedData == data else {
                _ = try? await sftp.remove(at: temporaryRemotePath)
                throw SFTPBackendError.remoteWriteVerificationFailed
            }

            do {
                _ = try await sftp.getAttributes(at: remotePath)
                try await sftp.remove(at: remotePath)
            } catch {
                // No pre-existing remote file at `remotePath` — nothing to
                // remove before the rename.
            }
            try await sftp.rename(at: temporaryRemotePath, to: remotePath)
        }
    }

    private func runSSHSync<T>(_ body: @escaping @Sendable (SFTPClient) async throws -> T) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let box = SFTPBackendResultBox<T>()
        let configuration = self.configuration
        let trustedHostKeyStore = self.trustedHostKeyStore
        let group = self.group

        Task {
            do {
                let privateKey = try SFTPBackend.loadPrivateKey(
                    pem: configuration.privateKeyPEM,
                    passphrase: configuration.privateKeyPassphrase
                )
                let hostKeyValidator = SSHHostKeyValidator.custom(
                    TrustOnFirstUseHostKeyValidator(host: configuration.hostKeyIdentifier, store: trustedHostKeyStore)
                )
                let client = try await SSHClient.connect(
                    host: configuration.host,
                    port: configuration.port,
                    authenticationMethod: .ed25519(username: configuration.username, privateKey: privateKey),
                    hostKeyValidator: hostKeyValidator,
                    reconnect: .never,
                    group: group
                )
                do {
                    let value = try await client.withSFTP { sftp in
                        try await body(sftp)
                    }
                    try? await client.close()
                    box.result = .success(value)
                } catch {
                    try? await client.close()
                    box.result = .failure(error)
                }
            } catch {
                box.result = .failure(error)
            }
            semaphore.signal()
        }

        semaphore.wait()
        switch box.result! {
        case .success(let value):
            return value
        case .failure(let error):
            throw error
        }
    }

    private static func loadPrivateKey(pem: String, passphrase: String?) throws -> Curve25519.Signing.PrivateKey {
        guard let pemData = pem.data(using: .utf8) else {
            throw SFTPBackendError.invalidPrivateKey
        }
        let passphraseData = passphrase.flatMap { $0.data(using: .utf8) }
        return try Curve25519.Signing.PrivateKey(sshEd25519: pemData, decryptionKey: passphraseData)
    }
}

/// A tiny reference-type box so `runSSHSync(_:)`'s detached `Task` can hand a
/// `Result` back across the semaphore hand-off without needing `T` (or
/// `Result<T, Error>`) to itself be `Sendable`. The semaphore already
/// guarantees the calling thread only reads `result` after the `Task` has
/// finished writing it (`semaphore.wait()` only returns after
/// `semaphore.signal()`), so there is no actual data race here — only a
/// shape the compiler's strict-concurrency checking cannot see through
/// unaided, hence the explicit `@unchecked Sendable`.
private final class SFTPBackendResultBox<T>: @unchecked Sendable {
    var result: Result<T, Error>?
}
