import CryptoKit
import ExtensionBridgeKit
import Foundation
import Security

private func sha256Hex(of secret: String) -> String {
    SHA256.hash(data: Data(secret.utf8))
        .compactMap { String(format: "%02x", $0) }
        .joined()
}

final class ExtensionPairingManager {
    private let store: ExtensionPairingStoring
    private let now: () -> Date

    private var activeCode: String?
    private var expiry: Date?
    private var attempts = 0
    private var pendingBrowserLabel = "Chromium browser"

    var onCodeGenerated: ((String) -> Void)?
    var onPairingFinished: (() -> Void)?

    init(store: ExtensionPairingStoring, now: @escaping () -> Date = Date.init) {
        self.store = store
        self.now = now
    }

    func startPairing(browser: String?) -> String {
        pendingBrowserLabel = browser ?? "Chromium browser"
        let code = generateSixDigitCode()
        activeCode = code
        expiry = now().addingTimeInterval(120)
        attempts = 0
        onCodeGenerated?(code)
        return code
    }

    func completePairing(code: String) -> String? {
        guard let activeCode, let expiry, now() <= expiry else {
            return nil
        }

        attempts += 1
        if attempts >= 5 {
            clearChallenge()
            onPairingFinished?()
            return nil
        }

        let normalizedCode = code.filter { !$0.isWhitespace }
        guard normalizedCode == activeCode else {
            return nil
        }

        let secret = ExtensionBridgeTokenStore.generateToken()
        let hash = sha256Hex(of: secret)
        let browser = PairedBrowser(
            id: UUID(),
            label: pendingBrowserLabel,
            createdAt: now(),
            secretHash: hash
        )
        do {
            try store.add(browser)
        } catch {
            clearChallenge()
            onPairingFinished?()
            return nil
        }
        clearChallenge()
        onPairingFinished?()
        return secret
    }

    func cancelPairing() {
        clearChallenge()
        onPairingFinished?()
    }

    func isAuthorized(pairing: String?) -> Bool {
        guard let secret = pairing else { return false }
        return store.containsSecret(matching: secret)
    }

    /// Resolve report ownership from the authenticated secret, never a client-supplied ID.
    func authorizedBrowser(pairing: String?) -> PairedBrowser? {
        guard let secret = pairing, store.containsSecret(matching: secret) else { return nil }
        let hash = sha256Hex(of: secret)
        return store.list().first { $0.secretHash == hash }
    }

    private func clearChallenge() {
        activeCode = nil
        expiry = nil
        attempts = 0
    }

    private func generateSixDigitCode() -> String {
        var random: UInt32 = 0
        let status = SecRandomCopyBytes(kSecRandomDefault, MemoryLayout<UInt32>.size, &random)
        // Fail fast rather than emit a predictable code from an unfilled buffer.
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed with status \(status)")
        let value = random % 1_000_000
        return String(format: "%06d", value)
    }
}
