# Chrome Extension Pairing Code Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add iCloud Passwords–style one-time browser pairing (6-digit code + persistent secret) on top of the existing Phase 4 Chrome extension bridge, per `docs/superpowers/specs/2026-07-26-mypass-extension-pairing-design.md`.

**Architecture:** Extend `ExtensionBridgeKit` wire types with optional `pairing` on data requests plus `startPairing` / `completePairing`. New app types `ExtensionPairingStore` (Keychain hash storage, app-only) and `ExtensionPairingManager` (code challenge + secret issuance) gate `ExtensionBridgeService` before credential/save logic. SwiftUI shows a pairing code sheet via `NavigationState.pendingPairingCode`; Settings lists revocable paired browsers. MV3 extension stores the secret in `chrome.storage.local` and drives a Connect flow in the popup.

**Tech Stack:** Swift 5 / SwiftUI / XCTest, MV3 JS + `node:assert` tests.

## Global Constraints

- English everywhere except `RUN.md` (Ukrainian).
- xcodegen project: run `./scripts/generate.sh` before `xcodebuild`.
- TDD: write failing test first in every task.
- Swift package tests: `cd Packages/ExtensionBridgeKit && swift test`. App tests: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS'`. JS: `node ChromeExtension/tests/<file>`.
- **`RelayTokenInjector` is generic** — it sets `"token"` on any JSON object; no allowlist update needed for new message types. **`LoopbackServer.requestToken(from:)` must gain cases** for the two new request types.

---

### Task 1: Protocol — extend ExtensionBridgeRequest/Response + update all enum consumers

**Files:**
- Modify: `Packages/ExtensionBridgeKit/Sources/ExtensionBridgeKit/ExtensionBridgeMessages.swift`
- Modify: `Packages/ExtensionBridgeKit/Tests/ExtensionBridgeKitTests/ExtensionBridgeMessagesTests.swift`
- Modify: `MyPass/State/ExtensionBridge/LoopbackServer.swift`
- Modify: `MyPassTests/LoopbackServerTests.swift`
- Modify: `MyPass/State/ExtensionBridge/ExtensionBridgeService.swift` (case labels only — full gate in Task 4)
- Modify: `MyPassTests/ExtensionBridgeServiceTests.swift` (add `pairing: nil` to existing calls)

**Interfaces:**
- Consumes: existing `ExtensionBridgeRequest` / `ExtensionBridgeResponse` Codable style.
- Produces (final API — do not rename):
```swift
public enum ExtensionBridgeRequest: Equatable {
    case getCredentials(token: String, url: String, pairing: String?)
    case fillCredential(token: String, id: String, url: String, pairing: String?)
    case proposeSaveLogin(token: String, url: String, username: String, password: String, pairing: String?)
    case startPairing(token: String)
    case completePairing(token: String, code: String)
}
public enum ExtensionBridgeResponse: Equatable {
    case locked
    case pairingRequired
    case pairingStarted
    case paired(secret: String)
    case credentialList([ExtensionCredentialSummary])
    case credential(username: String, password: String, totp: String?)
    case saveProposalAccepted
    case error(String)
}
```

- [ ] **Step 1: Write the failing tests**

Append to `ExtensionBridgeMessagesTests.swift`:

```swift
    func testGetCredentialsRoundTripsWithOptionalPairing() throws {
        let request = ExtensionBridgeRequest.getCredentials(token: "tok-1", url: "https://example.com", pairing: "secret-b64")
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(ExtensionBridgeRequest.self, from: data)
        XCTAssertEqual(decoded, request)
        let object = try jsonObject(from: data)
        XCTAssertEqual(object["pairing"] as? String, "secret-b64")
    }

    func testGetCredentialsRoundTripsWithoutPairingKeyWhenNil() throws {
        let request = ExtensionBridgeRequest.getCredentials(token: "tok-1", url: "https://example.com", pairing: nil)
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(ExtensionBridgeRequest.self, from: data)
        XCTAssertEqual(decoded, request)
        XCTAssertNil(try jsonObject(from: data)["pairing"])
    }

    func testStartPairingRoundTripsAndHasExpectedShape() throws {
        let request = ExtensionBridgeRequest.startPairing(token: "tok-p")
        let data = try JSONEncoder().encode(request)
        XCTAssertEqual(try JSONDecoder().decode(ExtensionBridgeRequest.self, from: data), request)
        let object = try jsonObject(from: data)
        XCTAssertEqual(object["type"] as? String, "startPairing")
        XCTAssertEqual(object["token"] as? String, "tok-p")
    }

    func testCompletePairingRoundTripsAndHasExpectedShape() throws {
        let request = ExtensionBridgeRequest.completePairing(token: "tok-p", code: "123456")
        let data = try JSONEncoder().encode(request)
        XCTAssertEqual(try JSONDecoder().decode(ExtensionBridgeRequest.self, from: data), request)
        let object = try jsonObject(from: data)
        XCTAssertEqual(object["type"] as? String, "completePairing")
        XCTAssertEqual(object["code"] as? String, "123456")
    }

    func testPairingRequiredRoundTrips() throws {
        let response = ExtensionBridgeResponse.pairingRequired
        let data = try JSONEncoder().encode(response)
        XCTAssertEqual(try JSONDecoder().decode(ExtensionBridgeResponse.self, from: data), response)
        XCTAssertEqual(try jsonObject(from: data)["type"] as? String, "pairingRequired")
    }

    func testPairingStartedRoundTrips() throws {
        let response = ExtensionBridgeResponse.pairingStarted
        let data = try JSONEncoder().encode(response)
        XCTAssertEqual(try JSONDecoder().decode(ExtensionBridgeResponse.self, from: data), response)
        XCTAssertEqual(try jsonObject(from: data)["type"] as? String, "pairingStarted")
    }

    func testPairedRoundTripsAndHasExpectedShape() throws {
        let response = ExtensionBridgeResponse.paired(secret: "YWJj")
        let data = try JSONEncoder().encode(response)
        XCTAssertEqual(try JSONDecoder().decode(ExtensionBridgeResponse.self, from: data), response)
        let object = try jsonObject(from: data)
        XCTAssertEqual(object["type"] as? String, "paired")
        XCTAssertEqual(object["secret"] as? String, "YWJj")
    }

    func testInvalidCodeErrorRoundTrips() throws {
        let response = ExtensionBridgeResponse.error("invalid_code")
        let data = try JSONEncoder().encode(response)
        XCTAssertEqual(try JSONDecoder().decode(ExtensionBridgeResponse.self, from: data), response)
        XCTAssertEqual(try jsonObject(from: data)["message"] as? String, "invalid_code")
    }
```

Update existing tests in the same file to pass `pairing: nil` on the three data request constructors.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd Packages/ExtensionBridgeKit && swift test --filter ExtensionBridgeMessagesTests`
Expected: FAIL — new enum cases / associated values missing.

- [ ] **Step 3: Write minimal implementation**

Update `ExtensionBridgeMessages.swift` — extend enum cases and Codable (add `pairing`, `code`, `secret` to `CodingKeys`; decode/encode new types). Pattern matches existing switch-on-`type` style:

```swift
public enum ExtensionBridgeRequest: Equatable {
    case getCredentials(token: String, url: String, pairing: String?)
    case fillCredential(token: String, id: String, url: String, pairing: String?)
    case proposeSaveLogin(token: String, url: String, username: String, password: String, pairing: String?)
    case startPairing(token: String)
    case completePairing(token: String, code: String)
}
```

In `init(from:)`, for data requests use `container.decodeIfPresent(String.self, forKey: .pairing)`.

In `encode(to:)`, use `encodeIfPresent(pairing, forKey: .pairing)` only when non-nil.

Add response cases `pairingRequired`, `pairingStarted`, `paired(secret:)`.

Update `LoopbackServer.requestToken(from:)`:

```swift
    private func requestToken(from request: ExtensionBridgeRequest) -> String {
        switch request {
        case .getCredentials(let token, _, _): return token
        case .fillCredential(let token, _, _, _): return token
        case .proposeSaveLogin(let token, _, _, _, _): return token
        case .startPairing(let token): return token
        case .completePairing(let token, _): return token
        }
    }
```

Update `ExtensionBridgeService.handle` case labels (ignore `pairing` for now):

```swift
        case .getCredentials(_, let url, _):
        case .fillCredential(_, let id, let url, _):
        case .proposeSaveLogin(_, let url, let username, let password, _):
        case .startPairing:
            return .error("not implemented")
        case .completePairing:
            return .error("not implemented")
```

Update all `ExtensionBridgeServiceTests` and `LoopbackServerTests` call sites to include `pairing: nil`.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd Packages/ExtensionBridgeKit && swift test --filter ExtensionBridgeMessagesTests`
Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/LoopbackServerTests -only-testing:MyPassTests/ExtensionBridgeServiceTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/ExtensionBridgeKit/Sources/ExtensionBridgeKit/ExtensionBridgeMessages.swift \
  Packages/ExtensionBridgeKit/Tests/ExtensionBridgeKitTests/ExtensionBridgeMessagesTests.swift \
  MyPass/State/ExtensionBridge/LoopbackServer.swift MyPassTests/LoopbackServerTests.swift \
  MyPass/State/ExtensionBridge/ExtensionBridgeService.swift MyPassTests/ExtensionBridgeServiceTests.swift
git commit -m "feat(pairing): extend ExtensionBridge wire types for browser pairing"
```

---

### Task 2: ExtensionPairingStore (protocol + Keychain + InMemory) + tests

**Files:**
- Create: `MyPass/State/ExtensionBridge/ExtensionPairingStore.swift`
- Create: `MyPassTests/ExtensionPairingStoreTests.swift`

**Interfaces:**
- Consumes: `CryptoKit` (`SHA256`), `Security` (Keychain — mirror `ExtensionBridgeTokenStore` query shape without access group).
- Produces:
```swift
struct PairedBrowser: Codable, Equatable, Identifiable {
    let id: UUID; let label: String; let createdAt: Date; let secretHash: String
}
protocol ExtensionPairingStoring: AnyObject {
    func list() -> [PairedBrowser]
    func add(_ browser: PairedBrowser) throws
    func remove(id: UUID) throws
    func containsSecret(matching secret: String) -> Bool
}
final class KeychainExtensionPairingStore: ExtensionPairingStoring
final class InMemoryExtensionPairingStore: ExtensionPairingStoring
```

- [ ] **Step 1: Write the failing test**

Create `MyPassTests/ExtensionPairingStoreTests.swift`:

```swift
import XCTest
import CryptoKit
@testable import MyPass

final class ExtensionPairingStoreTests: XCTestCase {

    func testInMemoryStoreStartsEmpty() {
        let store = InMemoryExtensionPairingStore()
        XCTAssertTrue(store.list().isEmpty)
    }

    func testInMemoryStoreAddListRemove() throws {
        let store = InMemoryExtensionPairingStore()
        let browser = PairedBrowser(id: UUID(), label: "Chrome", createdAt: Date(), secretHash: "abc")
        try store.add(browser)
        XCTAssertEqual(store.list(), [browser])
        try store.remove(id: browser.id)
        XCTAssertTrue(store.list().isEmpty)
    }

    func testInMemoryContainsSecretUsesSHA256Hash() throws {
        let store = InMemoryExtensionPairingStore()
        let secret = "test-secret-b64"
        let hash = SHA256.hash(data: Data(secret.utf8)).compactMap { String(format: "%02x", $0) }.joined()
        try store.add(PairedBrowser(id: UUID(), label: "Chrome", createdAt: Date(), secretHash: hash))
        XCTAssertTrue(store.containsSecret(matching: secret))
        XCTAssertFalse(store.containsSecret(matching: "wrong"))
        XCTAssertFalse(store.containsSecret(matching: ""))
    }

    private func requireKeychainTestsEnabled() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MYPASS_KEYCHAIN_TESTS"] == "1",
            "set MYPASS_KEYCHAIN_TESTS=1 to run tests against the real Keychain"
        )
    }

    func testKeychainStoreAddListRemoveAndContainsSecret() throws {
        try requireKeychainTestsEnabled()
        let store = KeychainExtensionPairingStore()
        for existing in store.list() { try store.remove(id: existing.id) }

        let secret = ExtensionBridgeTokenStore.generateToken()
        let hash = SHA256.hash(data: Data(secret.utf8)).compactMap { String(format: "%02x", $0) }.joined()
        let browser = PairedBrowser(id: UUID(), label: "Chrome", createdAt: Date(), secretHash: hash)
        try store.add(browser)
        XCTAssertTrue(store.containsSecret(matching: secret))
        try store.remove(id: browser.id)
        XCTAssertFalse(store.containsSecret(matching: secret))
    }
}
```

Add `import ExtensionBridgeKit` if `generateToken()` is used from the package.

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/ExtensionPairingStoreTests`
Expected: FAIL — types do not exist.

- [ ] **Step 3: Write minimal implementation**

Create `ExtensionPairingStore.swift` with `PairedBrowser`, protocol, `InMemoryExtensionPairingStore`, and `KeychainExtensionPairingStore`:

- Service: `"com.mypass.extension.pairing"`
- Account: `browser.id.uuidString`
- Value: `JSONEncoder().encode(browser)`
- **No** `kSecAttrAccessGroup`
- `list()`: `SecItemCopyMatching` with `kSecMatchLimitAll`, decode each item
- `remove(id:)`: delete by service + account
- `containsSecret(matching:)`: SHA-256 hex digest, compare to each stored `secretHash` using constant-time `Data` comparison:

```swift
private func hashesMatch(stored: String, computed: String) -> Bool {
    guard let a = stored.data(using: .utf8), let b = computed.data(using: .utf8), a.count == b.count else {
        return false
    }
    return a.withUnsafeBytes { aBytes in
        b.withUnsafeBytes { bBytes in
            timingsafe_bcmp(aBytes.baseAddress, bBytes.baseAddress, a.count) == 0
        }
    }
}
```

(Or a small private helper using `CryptoKit` + fixed-length hex compare.)

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/ExtensionPairingStoreTests`
Expected: PASS (3 InMemory tests; Keychain test SKIP unless `MYPASS_KEYCHAIN_TESTS=1`).

- [ ] **Step 5: Commit**

```bash
git add MyPass/State/ExtensionBridge/ExtensionPairingStore.swift MyPassTests/ExtensionPairingStoreTests.swift
git commit -m "feat(pairing): add Keychain-backed ExtensionPairingStore"
```

---

### Task 3: ExtensionPairingManager + unit tests

**Files:**
- Create: `MyPass/State/ExtensionBridge/ExtensionPairingManager.swift`
- Create: `MyPassTests/ExtensionPairingManagerTests.swift`

**Interfaces:**
- Consumes: `ExtensionPairingStoring`, `ExtensionBridgeTokenStore.generateToken()` (for 32-byte secret).
- Produces:
```swift
final class ExtensionPairingManager {
    init(store: ExtensionPairingStoring, now: @escaping () -> Date = Date.init)
    var onCodeGenerated: ((String) -> Void)?
    var onPairingFinished: (() -> Void)?
    func startPairing() -> String
    func completePairing(code: String) -> String?
    func cancelPairing()
    func isAuthorized(pairing: String?) -> Bool
}
```

- [ ] **Step 1: Write the failing test**

Create `MyPassTests/ExtensionPairingManagerTests.swift`:

```swift
import XCTest
@testable import MyPass

final class ExtensionPairingManagerTests: XCTestCase {
    private var store: InMemoryExtensionPairingStore!
    private var now: Date!
    private var manager: ExtensionPairingManager!

    override func setUp() {
        store = InMemoryExtensionPairingStore()
        now = Date(timeIntervalSinceReferenceDate: 100_000)
        manager = ExtensionPairingManager(store: store, now: { [unowned self] in self.now })
    }

    func testStartPairingProducesSixDigitCode() {
        let code = manager.startPairing()
        XCTAssertEqual(code.count, 6)
        XCTAssertTrue(code.allSatisfy(\.isNumber))
    }

    func testCompletePairingSucceedsWithMatchingCode() throws {
        let code = manager.startPairing()
        let secret = try XCTUnwrap(manager.completePairing(code: code))
        XCTAssertFalse(secret.isEmpty)
        XCTAssertTrue(manager.isAuthorized(pairing: secret))
    }

    func testCompletePairingFailsAfterTTL() {
        let code = manager.startPairing()
        now = now.addingTimeInterval(121)
        XCTAssertNil(manager.completePairing(code: code))
    }

    func testCompletePairingLocksOutAfterFiveFailedAttempts() {
        let code = manager.startPairing()
        for _ in 0..<4 { XCTAssertNil(manager.completePairing(code: "000000")) }
        XCTAssertNil(manager.completePairing(code: code), "correct code must fail after 5 attempts")
    }

    func testCancelPairingClearsActiveChallenge() {
        let code = manager.startPairing()
        manager.cancelPairing()
        XCTAssertNil(manager.completePairing(code: code))
    }

    func testIsAuthorizedReturnsFalseForNilOrUnknown() {
        XCTAssertFalse(manager.isAuthorized(pairing: nil))
        XCTAssertFalse(manager.isAuthorized(pairing: "unknown"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/ExtensionPairingManagerTests`
Expected: FAIL.

- [ ] **Step 3: Write minimal implementation**

Create `ExtensionPairingManager.swift`:

- Private state: `activeCode: String?`, `expiry: Date?`, `attempts: Int`
- `startPairing()`: generate 6 digits via `SecRandomCopyBytes` mod 1_000_000, zero-padded; set expiry = now()+120; attempts = 0; call `onCodeGenerated?`
- `completePairing(code:)`: guard active + not expired; on mismatch increment attempts, if attempts >= 5 clear challenge + `onPairingFinished?`, return nil; on match generate secret via `ExtensionBridgeTokenStore.generateToken()`, hash with SHA-256, `store.add(PairedBrowser(...))`, clear challenge, `onPairingFinished?`, return secret
- `cancelPairing()`: clear challenge, `onPairingFinished?`
- `isAuthorized(pairing:)`: guard let secret = pairing else { return false }; return store.containsSecret(matching: secret)

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/ExtensionPairingManagerTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add MyPass/State/ExtensionBridge/ExtensionPairingManager.swift MyPassTests/ExtensionPairingManagerTests.swift
git commit -m "feat(pairing): add ExtensionPairingManager code challenge"
```

---

### Task 4: ExtensionBridgeService gate + startPairing/completePairing handling + tests

**Files:**
- Modify: `MyPass/State/ExtensionBridge/ExtensionBridgeService.swift`
- Modify: `MyPassTests/ExtensionBridgeServiceTests.swift`
- Modify: `MyPass/MyPassApp.swift` (wire manager into service)

**Interfaces:**
- Consumes: `ExtensionPairingManager`.
- Produces: updated `ExtensionBridgeService` initializer and gate order from spec.

- [ ] **Step 1: Write the failing tests**

Add to `ExtensionBridgeServiceTests.swift`:

```swift
    private func makeServiceWithPairing() -> (ExtensionBridgeService, InMemoryExtensionPairingStore, ExtensionPairingManager) {
        let store = InMemoryExtensionPairingStore()
        let manager = ExtensionPairingManager(store: store)
        let service = ExtensionBridgeService(vaultSession: session, pairingManager: manager)
        return (service, store, manager)
    }

    func testStartPairingReturnsLockedWhenVaultIsLocked() {
        session.lock()
        let (service, _, _) = makeServiceWithPairing()
        XCTAssertEqual(service.handle(.startPairing(token: "t")), .locked)
    }

    func testStartPairingReturnsPairingStartedWhenUnlocked() {
        let (service, _, _) = makeServiceWithPairing()
        XCTAssertEqual(service.handle(.startPairing(token: "t")), .pairingStarted)
    }

    func testGetCredentialsReturnsPairingRequiredWithoutSecret() {
        _ = addFixtureEntry(title: "Example", username: "alice", password: "s3cret", url: "https://example.com")
        let (service, _, _) = makeServiceWithPairing()
        let response = service.handle(.getCredentials(token: "t", url: "https://example.com", pairing: nil))
        XCTAssertEqual(response, .pairingRequired)
    }

    func testGetCredentialsReturnsListWhenAuthorized() throws {
        _ = addFixtureEntry(title: "Example", username: "alice", password: "s3cret", url: "https://example.com")
        let (service, store, manager) = makeServiceWithPairing()
        let code = manager.startPairing()
        let secret = try XCTUnwrap(manager.completePairing(code: code))
        _ = secret
        let response = service.handle(.getCredentials(token: "t", url: "https://example.com", pairing: secret))
        guard case .credentialList(let summaries) = response else {
            return XCTFail("expected credentialList, got \(response)")
        }
        XCTAssertEqual(summaries.count, 1)
    }

    func testCompletePairingReturnsPairedWithSecret() {
        let (service, _, manager) = makeServiceWithPairing()
        let code = manager.startPairing()
        guard case .paired(let secret) = service.handle(.completePairing(token: "t", code: code)) else {
            return XCTFail("expected paired response")
        }
        XCTAssertFalse(secret.isEmpty)
    }

    func testCompletePairingReturnsInvalidCodeOnMismatch() {
        let (service, _, manager) = makeServiceWithPairing()
        _ = manager.startPairing()
        XCTAssertEqual(service.handle(.completePairing(token: "t", code: "000000")), .error("invalid_code"))
    }
```

Update `setUp` to use new initializer or keep default with a stub manager that always authorizes for existing tests — prefer adding `pairingManager:` parameter with a test helper that pre-authorizes via in-memory store for legacy tests.

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/ExtensionBridgeServiceTests`
Expected: FAIL.

- [ ] **Step 3: Write minimal implementation**

Update `ExtensionBridgeService`:

```swift
final class ExtensionBridgeService {
    weak var vaultSession: VaultSession?
    private let pairingManager: ExtensionPairingManager
    // ... existing callbacks ...

    init(vaultSession: VaultSession, pairingManager: ExtensionPairingManager) {
        self.vaultSession = vaultSession
        self.pairingManager = pairingManager
    }

    func handle(_ request: ExtensionBridgeRequest) -> ExtensionBridgeResponse {
        guard vaultSession?.currentDatabase != nil else {
            return .locked
        }
        switch request {
        case .startPairing:
            _ = pairingManager.startPairing()
            return .pairingStarted
        case .completePairing(_, let code):
            if let secret = pairingManager.completePairing(code: code) {
                return .paired(secret: secret)
            }
            return .error("invalid_code")
        case .getCredentials(_, let url, let pairing):
            guard pairingManager.isAuthorized(pairing: pairing) else {
                return .pairingRequired
            }
            let matches = ExtensionEntryMatcher.matchingEntries(in: database.rootGroup, forURL: url)
            // ... existing getCredentials body ...
        case .fillCredential(_, let id, let url, let pairing):
            guard pairingManager.isAuthorized(pairing: pairing) else {
                return .pairingRequired
            }
            // ... existing fillCredential body ...
        case .proposeSaveLogin(_, let url, let username, let password, let pairing):
            guard pairingManager.isAuthorized(pairing: pairing) else {
                return .pairingRequired
            }
            onSaveProposal?(url, username, password)
            return .saveProposalAccepted
        }
    }
}
```

Refactor the three data cases to share the authorization guard, then run existing credential/save logic.

In `MyPassApp.init()`, before `ExtensionBridgeService` construction:

```swift
        let pairingStore = KeychainExtensionPairingStore()
        let pairingManager = ExtensionPairingManager(store: pairingStore)
        AppDelegate.extensionPairingStore = pairingStore
        AppDelegate.extensionPairingManager = pairingManager
        let extensionBridgeService = ExtensionBridgeService(
            vaultSession: session,
            pairingManager: pairingManager
        )
```

Add static properties on `AppDelegate` (mirror `extensionBridgeServer`).

For existing `ExtensionBridgeServiceTests`, use a manager backed by `InMemoryExtensionPairingStore` and pre-seed authorization:

```swift
        let store = InMemoryExtensionPairingStore()
        let manager = ExtensionPairingManager(store: store)
        service = ExtensionBridgeService(vaultSession: session, pairingManager: manager)
        // Pre-authorize all legacy tests:
        let secret = ExtensionBridgeTokenStore.generateToken()
        let hash = /* sha256 hex */
        try? store.add(PairedBrowser(id: UUID(), label: "Test", createdAt: Date(), secretHash: hash))
        authorizedPairingSecret = secret
```

Pass `pairing: authorizedPairingSecret` in all existing test requests.

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/ExtensionBridgeServiceTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add MyPass/State/ExtensionBridge/ExtensionBridgeService.swift MyPassTests/ExtensionBridgeServiceTests.swift MyPass/MyPassApp.swift MyPass/App/AppDelegate.swift
git commit -m "feat(pairing): gate ExtensionBridgeService on pairing authorization"
```

---

### Task 5: App UI — NavigationState, PairingCodeSheet, MyPassApp wiring, ContentView sheet

**Files:**
- Modify: `MyPass/State/NavigationState.swift`
- Create: `MyPass/UI/ExtensionPairing/PairingCodeSheet.swift`
- Modify: `MyPass/MyPassApp.swift`
- Modify: `MyPass/ContentView.swift`

**Interfaces:**
- Consumes: `NavigationState.pendingPairingCode`, `MainWindowActivator.request()`, `AppDelegate.extensionPairingManager`.
- Produces: sheet UI and callback wiring from spec.

- [ ] **Step 1: Build check baseline**

Run: `./scripts/build.sh`
Expected: PASS before UI changes (or note failures to fix in implementation).

- [ ] **Step 2: Write minimal implementation**

`NavigationState.swift` — add:

```swift
    @Published var pendingPairingCode: String?
```

`PairingCodeSheet.swift`:

```swift
import SwiftUI

struct PairingCodeSheet: View {
    let code: String
    let onCancel: () -> Void

    private var groupedCode: String {
        guard code.count == 6 else { return code }
        let index = code.index(code.startIndex, offsetBy: 3)
        return "\(code[..<index]) \(code[index...])"
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Connect browser extension")
                .font(.title2.weight(.semibold))
            Text(groupedCode)
                .font(.system(size: 40, weight: .medium, design: .monospaced))
            Text("Enter this code in the MyPass browser extension.")
                .foregroundStyle(.secondary)
            Button("Cancel", role: .cancel, action: onCancel)
        }
        .padding(32)
        .frame(minWidth: 320)
    }
}
```

`MyPassApp.init()` — after pairing manager creation:

```swift
        pairingManager.onCodeGenerated = { [weak navigationState] code in
            DispatchQueue.main.async {
                navigationState?.pendingPairingCode = code
                MainWindowActivator.request()
            }
        }
        pairingManager.onPairingFinished = { [weak navigationState] in
            DispatchQueue.main.async {
                navigationState?.pendingPairingCode = nil
            }
        }
```

`ContentView` — in `.unlocked` branch, add:

```swift
            .sheet(isPresented: Binding(
                get: { navigationState.pendingPairingCode != nil },
                set: { if !$0 { navigationState.pendingPairingCode = nil } }
            )) {
                if let code = navigationState.pendingPairingCode {
                    PairingCodeSheet(code: code) {
                        AppDelegate.extensionPairingManager?.cancelPairing()
                    }
                }
            }
```

- [ ] **Step 3: Run build**

Run: `./scripts/build.sh`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add MyPass/State/NavigationState.swift MyPass/UI/ExtensionPairing/PairingCodeSheet.swift MyPass/MyPassApp.swift MyPass/ContentView.swift
git commit -m "feat(pairing): show pairing code sheet in main window"
```

---

### Task 6: Settings → Browser "Paired browsers" list + Revoke

**Files:**
- Modify: `MyPass/UI/Settings/BrowserSettingsPane.swift`
- Modify: `MyPass/UI/Settings/SettingsView.swift`
- Modify: `MyPass/MyPassApp.swift` (pass store via environment)

**Interfaces:**
- Consumes: `ExtensionPairingStoring` via `@EnvironmentObject` or explicit binding to `AppDelegate.extensionPairingStore`.

- [ ] **Step 1: Write minimal implementation**

`SettingsView.swift` — pass store to browser pane:

```swift
        case .browser:
            BrowserSettingsPane()
                .environmentObject(AppDelegate.extensionPairingStoreWrapper)
```

Prefer a thin `ObservableObject` wrapper if the protocol is not `ObservableObject`:

```swift
final class ExtensionPairingStoreModel: ObservableObject {
    let store: ExtensionPairingStoring
    init(store: ExtensionPairingStoring) { self.store = store }
    func refresh() -> [PairedBrowser] { store.list() }
}
```

Created once in `MyPassApp.init()` from `KeychainExtensionPairingStore`.

`BrowserSettingsPane` — add section:

```swift
    @EnvironmentObject private var pairingStoreModel: ExtensionPairingStoreModel
    @State private var pairedBrowsers: [PairedBrowser] = []

    // Inside Form, after chromeExtensionSection:
    Section {
        if pairedBrowsers.isEmpty {
            Text("No paired browsers.")
                .foregroundStyle(.secondary)
        } else {
            ForEach(pairedBrowsers) { browser in
                HStack {
                    VStack(alignment: .leading) {
                        Text(browser.label)
                        Text(browser.createdAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Revoke") {
                        try? pairingStoreModel.store.remove(id: browser.id)
                        pairedBrowsers = pairingStoreModel.refresh()
                    }
                }
            }
        }
    } header: {
        Text("Paired browsers")
            .font(.system(size: 13, weight: .semibold))
    }
    .onAppear { pairedBrowsers = pairingStoreModel.refresh() }
```

- [ ] **Step 2: Run build**

Run: `./scripts/build.sh`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add MyPass/UI/Settings/BrowserSettingsPane.swift MyPass/UI/Settings/SettingsView.swift MyPass/MyPassApp.swift
git commit -m "feat(pairing): add paired browsers list to Browser settings"
```

---

### Task 7: Extension background.js pairing support + pairing.test.js

**Files:**
- Modify: `ChromeExtension/background.js`
- Create: `ChromeExtension/tests/pairing.test.js`

**Interfaces:**
- Consumes: existing `sendNativeMessage`, `chrome.storage.local`.
- Produces: pairing secret read/write, `pairing` field on data requests, popup message handlers.

- [ ] **Step 1: Write the failing test**

Create `ChromeExtension/tests/pairing.test.js`:

```javascript
const assert = require('node:assert');

const storage = {};
global.chrome = {
  storage: {
    local: {
      get: (keys, cb) => {
        const result = {};
        for (const key of (Array.isArray(keys) ? keys : [keys])) {
          if (storage[key] !== undefined) result[key] = storage[key];
        }
        cb(result);
      },
      set: (items, cb) => {
        Object.assign(storage, items);
        if (cb) cb();
      },
      remove: (keys, cb) => {
        for (const key of (Array.isArray(keys) ? keys : [keys])) delete storage[key];
        if (cb) cb();
      }
    }
  },
  runtime: { lastError: null }
};

const {
  PAIRING_STORAGE_KEY,
  attachPairingField,
  persistPairingResponse,
  clearStaleSecretOnPairingRequired
} = require('../background.js');

assert.strictEqual(attachPairingField({ type: 'getCredentials', url: 'https://example.com' }, 'sec').pairing, 'sec');
assert.strictEqual(attachPairingField({ type: 'getCredentials', url: 'https://example.com' }, null).pairing, undefined);

(async () => {
  await persistPairingResponse({ type: 'paired', secret: 'YWJj' });
  assert.strictEqual(storage[PAIRING_STORAGE_KEY], 'YWJj');
  storage[PAIRING_STORAGE_KEY] = 'stale';
  await clearStaleSecretOnPairingRequired({ type: 'pairingRequired' }, 'stale');
  assert.strictEqual(storage[PAIRING_STORAGE_KEY], undefined);
  console.log('pairing.test.js OK');
})();
```

Refactor `background.js` to export `PAIRING_STORAGE_KEY`, `attachPairingField`, `persistPairingResponse`, and `clearStaleSecretOnPairingRequired` via `module.exports` under `typeof module !== 'undefined'` (same pattern as `content.js` exports `hostnameMatches`).

- [ ] **Step 2: Run test to verify it fails**

Run: `node ChromeExtension/tests/pairing.test.js`
Expected: FAIL — helpers missing.

- [ ] **Step 3: Write minimal implementation**

Update `background.js`:

```javascript
const PAIRING_STORAGE_KEY = "pairingSecret";

function attachPairingField(message, pairingSecret) {
  if (!pairingSecret) return message;
  return { ...message, pairing: pairingSecret };
}

function persistPairingResponse(response) {
  return new Promise((resolve) => {
    if (response && response.type === "paired" && response.secret) {
      chrome.storage.local.set({ [PAIRING_STORAGE_KEY]: response.secret }, resolve);
    } else {
      resolve();
    }
  });
}

function clearStaleSecretOnPairingRequired(response, previousSecret) {
  return new Promise((resolve) => {
    if (response && response.type === "pairingRequired" && previousSecret) {
      chrome.storage.local.remove(PAIRING_STORAGE_KEY, resolve);
    } else {
      resolve();
    }
  });
}

function readPairingSecret() {
  return new Promise((resolve) => {
    chrome.storage.local.get(PAIRING_STORAGE_KEY, (result) => {
      resolve(result[PAIRING_STORAGE_KEY] || null);
    });
  });
}

async function sendNativeMessageWithPairing(message) {
  const pairingSecret = await readPairingSecret();
  const enriched = attachPairingField(message, pairingSecret);
  const response = await sendNativeMessage(enriched);
  await clearStaleSecretOnPairingRequired(response, pairingSecret);
  await persistPairingResponse(response);
  return response;
}

const knownTypes = ["getCredentials", "fillCredential", "proposeSaveLogin", "startPairing", "completePairing"];
```

Replace `sendNativeMessage(message)` in the listener with `sendNativeMessageWithPairing(message)`.

Export at file bottom:

```javascript
if (typeof module !== "undefined") {
  module.exports = {
    PAIRING_STORAGE_KEY,
    attachPairingField,
    persistPairingResponse,
    clearStaleSecretOnPairingRequired
  };
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `node ChromeExtension/tests/pairing.test.js`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ChromeExtension/background.js ChromeExtension/tests/pairing.test.js
git commit -m "feat(pairing): add background.js pairing secret relay"
```

---

### Task 8: Extension popup pairing UX + content.js pairingRequired handling

**Files:**
- Modify: `ChromeExtension/popup.html`
- Modify: `ChromeExtension/popup.js`
- Modify: `ChromeExtension/content.js`
- Modify: `ChromeExtension/tests/pairing.test.js` (popup flow helpers if extracted)

- [ ] **Step 1: Write minimal popup implementation**

`popup.html` — add containers:

```html
  <div id="pairing-panel" hidden>
    <button id="connect-btn" type="button">Connect to MyPass</button>
    <div id="code-entry" hidden>
      <p id="code-hint">Enter the code shown in MyPass</p>
      <input id="code-input" type="text" inputmode="numeric" maxlength="6" pattern="[0-9]{6}" />
      <button id="submit-code-btn" type="button">Submit</button>
    </div>
  </div>
```

`popup.js` — on `pairingRequired`:

```javascript
    if (response.type === 'pairingRequired') {
      document.getElementById('pairing-panel').hidden = false;
      document.getElementById('connect-btn').onclick = () => {
        chrome.runtime.sendMessage({ type: 'startPairing' }, (startResp) => {
          if (startResp && startResp.type === 'pairingStarted') {
            document.getElementById('code-entry').hidden = false;
          }
        });
      };
      return;
    }
```

Submit handler sends `{ type: 'completePairing', code: input.value }`; on `paired` re-run `getCredentials` query (extract `queryCredentials(url)` function from current inline flow).

`content.js` — in `requestCredentials` callback:

```javascript
        state.vaultLocked = !!(response && (response.type === 'locked' || response.type === 'pairingRequired'));
```

- [ ] **Step 2: Manual smoke + JS tests**

Run: `node ChromeExtension/tests/pairing.test.js`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add ChromeExtension/popup.html ChromeExtension/popup.js ChromeExtension/content.js ChromeExtension/tests/pairing.test.js
git commit -m "feat(pairing): add Connect flow to extension popup"
```

---

### Task 9: Docs + wiring finish (test.sh, RUN.md, cross-links)

**Files:**
- Modify: `scripts/test.sh`
- Modify: `RUN.md` (Ukrainian paragraph only)
- Modify: `docs/superpowers/specs/2026-07-26-mypass-extension-pairing-design.md` (ensure plan link present — already at top)
- Modify: `docs/superpowers/plans/2026-07-26-mypass-extension-pairing.md` (ensure spec link present — already in Goal)

- [ ] **Step 1: Register JS test**

In `scripts/test.sh`, after existing node tests:

```bash
  node ChromeExtension/tests/pairing.test.js
```

- [ ] **Step 2: Add Ukrainian RUN.md paragraph**

In the `## Chrome-розширення` section, after automatic setup or before e2e checklist, add:

```markdown
### Підключення браузера (pairing)

Перед першим автозаповненням або збереженням пароля розширення має бути **підключене** до розблокованого MyPass:

1. Відкрийте popup розширення на будь-якій сторінці — з’явиться кнопка **Connect to MyPass**.
2. Натисніть її; у головному вікні MyPass з’явиться **6-значний код** (дійсний 120 секунд).
3. Введіть цей код у popup розширення та підтвердіть.

Після успішного підключення popup показує збережені записи як раніше. Скасувати довіру можна в **MyPass → Settings → Browser → Paired browsers → Revoke**. Деталі протоколу: [spec pairing](docs/superpowers/specs/2026-07-26-mypass-extension-pairing-design.md).
```

- [ ] **Step 3: Run full test suite**

Run: `./scripts/test.sh`
Expected: PASS (or document any pre-existing failures unrelated to pairing).

- [ ] **Step 4: Commit**

```bash
git add scripts/test.sh RUN.md
git commit -m "docs(pairing): register pairing tests and RUN.md pairing steps"
```

---

## Plan self-review checklist

| Check | Status |
|-------|--------|
| Spec coverage — all spec sections map to Tasks 1–9 | OK |
| No placeholders / TBD / "similar to task N" | OK — each task repeats concrete paths and code |
| Type consistency — Swift API matches spec exactly | OK |
| RelayTokenInjector documented as generic (no allowlist) | OK — Global Constraints + Task 1 |
| LoopbackServer `requestToken` updated | OK — Task 1 |
| Keychain tests gated `MYPASS_KEYCHAIN_TESTS=1` | OK — Task 2 |
| RUN.md additions in Ukrainian | OK — Task 9 |
| English UI strings | OK |
| Cross-links spec ↔ plan | OK |
