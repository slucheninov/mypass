import Foundation
import NIO
import NIOSSH

public protocol TrustedHostKeyStore {
    func trustedKey(forHost host: String) -> String?
    func trust(_ openSSHPublicKey: String, forHost host: String)
}

public final class UserDefaultsTrustedHostKeyStore: TrustedHostKeyStore {
    private let defaults: UserDefaults
    private let keyPrefix: String

    public init(defaults: UserDefaults = .standard, keyPrefix: String = "com.mypass.sync.trustedhostkey.") {
        self.defaults = defaults
        self.keyPrefix = keyPrefix
    }

    public func trustedKey(forHost host: String) -> String? {
        defaults.string(forKey: keyPrefix + host)
    }

    public func trust(_ openSSHPublicKey: String, forHost host: String) {
        defaults.set(openSSHPublicKey, forKey: keyPrefix + host)
    }
}

public final class InMemoryTrustedHostKeyStore: TrustedHostKeyStore {
    private var storage: [String: String] = [:]

    public init() {}

    public func trustedKey(forHost host: String) -> String? {
        storage[host]
    }

    public func trust(_ openSSHPublicKey: String, forHost host: String) {
        storage[host] = openSSHPublicKey
    }
}

/// A host key that was trusted for one host but presented for a different
/// host (or a host whose previously-trusted key changed) — the SFTP
/// equivalent of SSH's "REMOTE HOST IDENTIFICATION HAS CHANGED" warning.
public struct TrustOnFirstUseError: Error, Equatable {
    public let host: String
}

/// A `NIOSSHClientServerAuthenticationDelegate` implementing
/// trust-on-first-use (TOFU) host key verification: the first time a host is
/// seen, whatever key it presents is trusted and remembered in `store`; on
/// every subsequent connection to that same host, the presented key must
/// match the remembered one, or validation fails.
public final class TrustOnFirstUseHostKeyValidator: NIOSSHClientServerAuthenticationDelegate {
    private let host: String
    private let store: TrustedHostKeyStore

    public init(host: String, store: TrustedHostKeyStore) {
        self.host = host
        self.store = store
    }

    public func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let presentedKey = String(openSSHPublicKey: hostKey)
        guard let trustedKey = store.trustedKey(forHost: host) else {
            store.trust(presentedKey, forHost: host)
            validationCompletePromise.succeed(())
            return
        }
        if trustedKey == presentedKey {
            validationCompletePromise.succeed(())
        } else {
            validationCompletePromise.fail(TrustOnFirstUseError(host: host))
        }
    }
}
