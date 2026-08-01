# Chrome Extension TOTP Autofill and Privacy Circle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a MyPass Chrome extension user autofill a live TOTP code on user-initiated row click, and reveal or copy that code from a privacy circle in the popup list, without ever sending the Base32 secret to the browser.

**Architecture:** The Swift-side `ExtensionBridgeService` gains a `hasTotp` flag on the `getCredentials` summary, computes a live six-digit code in `fillCredential` when the matched entry has a secret, and adds a new `getTotp` request/response pair for on-demand reveal/copy — all gated by the same pairing + domain-match checks `fillCredential` already uses. On the extension side, `content.js` gains OTP-field detection (`findOtpField`/`scoreOtpLikeness`) so `applyFill` can fill username, password, and/or TOTP independently depending on what fields exist on the page; `background.js` just needs `getTotp` added to its known-message-types allowlist since its generic relay path already handles it; `popup.js` renders a per-row privacy circle for `hasTotp` entries with idle/revealed/copied states, wired to `getTotp` and gated with `stopPropagation()` so it never triggers a row fill.

**Tech Stack:** Swift (Xcode project + Swift Package Manager for `ExtensionBridgeKit`), vanilla JavaScript (Chrome MV3 extension, CommonJS-style exports for Node unit tests, no framework/bundler), XCTest, Node's `assert` module for JS tests.

## Global Constraints

- The Base32 TOTP secret (`entry.totpSecretBase32`) must never appear in any message sent to the extension — not in the `getCredentials` list, not in `fillCredential`'s response, not anywhere. Only live six-digit codes may cross the bridge.
- `fillCredential`'s async response to `popup.js` never includes `username`, `password`, or `totp` — enforced by `stripCredentialSecrets` in `background.js`, which reduces any `"credential"`-typed response to `{ type: "ok" }` before it reaches the popup.
- The popup obtains a TOTP string **only** via the new `getTotp` message — never as a side effect of `fillCredential`.
- A valid pairing secret is required for `getCredentials`, `fillCredential`, and the new `getTotp`.
- Entry domain must match the tab URL via `ExtensionEntryMatcher.matchingEntries` on the Swift side; `content.js` independently re-checks the message URL against `location.href` via `hostnameMatches` before touching the DOM.
- No auto-fill on page load — filling only ever happens after an explicit popup row click relayed through `background.js`.
- TOTP generation is always: `TOTPCode.currentCode(secretBase32:, digits: 6, period: 30, algorithm: .sha1, now: Date())`.
- `getTotp` does **not** call `vaultSession.touchAccess` and does **not** fire `onCredentialFilled` — reveal/copy is lighter-weight than a full fill.
- Popup privacy circle: idle (no digits) by default; left-click reveals via `getTotp`; right-click/`contextmenu` copies via `getTotp` + clipboard; auto-hides ~5 s after reveal or copy, on a second left-click, or on click outside the circle; circle gestures always `stopPropagation()` so they never trigger the row's `fillCredential` + `window.close()` handler.
- Chrome only in this spec — no Safari parity, no extension-icon badge, no animated countdown ring in the popup circle, no auto-fill after page navigation.

## File Structure

| Path | Responsibility |
|------|----------------|
| `Packages/ExtensionBridgeKit/Sources/ExtensionBridgeKit/ExtensionBridgeMessages.swift` | Wire protocol: adds `.getTotp` request case, `.totp(code:)` response case, `hasTotp` field on `ExtensionCredentialSummary` |
| `Packages/ExtensionBridgeKit/Tests/ExtensionBridgeKitTests/ExtensionBridgeMessagesTests.swift` | Encode/decode round-trip coverage for the new wire types |
| `MyPass/State/ExtensionBridge/ExtensionBridgeService.swift` | Business logic: populates `hasTotp`, computes live TOTP on fill, handles `getTotp` |
| `MyPass/State/ExtensionBridge/LoopbackServer.swift` | Token extraction — needs a `.getTotp` arm so its request-token switch stays exhaustive |
| `MyPassTests/ExtensionBridgeServiceTests.swift` | Swift behavior tests for `hasTotp`, live fill TOTP, and `getTotp` (positive + negative cases) |
| `ChromeExtension/content.js` | `scoreOtpLikeness`/`findOtpField` OTP detection; `applyFill` fills username/password/TOTP independently based on what's present |
| `ChromeExtension/background.js` | Adds `"getTotp"` to the known-message-types allowlist so it routes through the existing generic relay |
| `ChromeExtension/popup.js` / `popup.html` | Renders the privacy circle per row, wires reveal/copy/hide gestures, adds circle CSS |
| `ChromeExtension/tests/formDetection.test.js` | OTP scoring/detection unit tests |
| `ChromeExtension/tests/totpCircle.test.js` (new) | Privacy circle state-machine unit tests |
| `ChromeExtension/tests/fixtures/otp.html`, `login-with-otp.html` (new) | Manual e2e fixture pages |
| `RUN.md` | Manual e2e checklist bullets (Ukrainian, do not translate) |
| `scripts/test.sh` | Add the new `totpCircle.test.js` invocation so it actually runs |

---

### Task 1: ExtensionBridgeKit wire protocol — `getTotp` request, `totp` response, `hasTotp` field

**Files:**
- Modify: `Packages/ExtensionBridgeKit/Sources/ExtensionBridgeKit/ExtensionBridgeMessages.swift`
- Test: `Packages/ExtensionBridgeKit/Tests/ExtensionBridgeKitTests/ExtensionBridgeMessagesTests.swift`

**Interfaces:**
- Produces: `ExtensionBridgeRequest.getTotp(token: String, id: String, url: String, pairing: String?)`; `ExtensionBridgeResponse.totp(code: String)`; `ExtensionCredentialSummary.init(id: String, title: String, username: String, hasTotp: Bool)`.

- [ ] **Step 1: Read the test file, then write failing tests**

Open `Packages/ExtensionBridgeKit/Tests/ExtensionBridgeKitTests/ExtensionBridgeMessagesTests.swift` and confirm the exact signature of its private `jsonObject(from:)` helper (used by existing round-trip tests like `testFillCredentialRoundTripsAndHasExpectedShape` and `testCredentialRoundTripsWithTotp`/`WithoutTotp`) — it wraps `JSONSerialization.jsonObject(with:)` into a `[String: Any]` for asserting exact wire-shape keys. Reuse it as-is.

Find every existing call site of `ExtensionCredentialSummary(id:title:username:)` in this file (at minimum inside `testCredentialListRoundTripsAndNeverIncludesAPasswordKey`) and update each to pass a `hasTotp:` argument (`false` unless the test specifically needs a TOTP-bearing summary), since the initializer is about to gain a required parameter.

Then append these three new test methods to the `ExtensionBridgeMessagesTests` class:

```swift
func testGetTotpRoundTripsAndHasExpectedShape() throws {
    let request = ExtensionBridgeRequest.getTotp(token: "tok", id: "entry-1", url: "https://example.com", pairing: "pair-secret")
    let data = try JSONEncoder().encode(request)
    let decoded = try JSONDecoder().decode(ExtensionBridgeRequest.self, from: data)
    XCTAssertEqual(decoded, request)

    let json = try jsonObject(from: data)
    XCTAssertEqual(json["type"] as? String, "getTotp")
    XCTAssertEqual(json["token"] as? String, "tok")
    XCTAssertEqual(json["id"] as? String, "entry-1")
    XCTAssertEqual(json["url"] as? String, "https://example.com")
    XCTAssertEqual(json["pairing"] as? String, "pair-secret")
}

func testTotpResponseRoundTripsAndHasExpectedShape() throws {
    let response = ExtensionBridgeResponse.totp(code: "123456")
    let data = try JSONEncoder().encode(response)
    let decoded = try JSONDecoder().decode(ExtensionBridgeResponse.self, from: data)
    XCTAssertEqual(decoded, response)

    let json = try jsonObject(from: data)
    XCTAssertEqual(json["type"] as? String, "totp")
    XCTAssertEqual(json["code"] as? String, "123456")
    XCTAssertNil(json["username"])
    XCTAssertNil(json["password"])
}

func testCredentialListIncludesHasTotpField() throws {
    let summary = ExtensionCredentialSummary(id: "1", title: "Example", username: "alice", hasTotp: true)
    let response = ExtensionBridgeResponse.credentialList([summary])
    let data = try JSONEncoder().encode(response)
    let decoded = try JSONDecoder().decode(ExtensionBridgeResponse.self, from: data)
    XCTAssertEqual(decoded, response)

    let json = try jsonObject(from: data)
    let credentials = try XCTUnwrap(json["credentials"] as? [[String: Any]])
    XCTAssertEqual(credentials.first?["hasTotp"] as? Bool, true)
}
```

- [ ] **Step 2: Run the package tests and confirm they fail to compile**

Run: `cd Packages/ExtensionBridgeKit && swift test`
Expected: build fails — `type 'ExtensionBridgeRequest' has no member 'getTotp'`, `type 'ExtensionBridgeResponse' has no member 'totp'`, and/or `missing argument for parameter 'hasTotp' in call`.

- [ ] **Step 3: Implement the wire protocol changes**

In `Packages/ExtensionBridgeKit/Sources/ExtensionBridgeKit/ExtensionBridgeMessages.swift`, apply these edits in order.

Add the new request case to the enum:

```swift
// Replace:
public enum ExtensionBridgeRequest: Equatable {
    case getCredentials(token: String, url: String, pairing: String?)
    case fillCredential(token: String, id: String, url: String, pairing: String?)
    case proposeSaveLogin(token: String, url: String, username: String, password: String, pairing: String?)
    case startPairing(token: String, browser: String?)
    case completePairing(token: String, code: String)
}

// With:
public enum ExtensionBridgeRequest: Equatable {
    case getCredentials(token: String, url: String, pairing: String?)
    case fillCredential(token: String, id: String, url: String, pairing: String?)
    case getTotp(token: String, id: String, url: String, pairing: String?)
    case proposeSaveLogin(token: String, url: String, username: String, password: String, pairing: String?)
    case startPairing(token: String, browser: String?)
    case completePairing(token: String, code: String)
}
```

Add a `"getTotp"` arm to `init(from decoder:)`, right after the existing `"fillCredential"` arm:

```swift
// Replace:
        case "fillCredential":
            let id = try container.decode(String.self, forKey: .id)
            let url = try container.decode(String.self, forKey: .url)
            let pairing = try container.decodeIfPresent(String.self, forKey: .pairing)
            self = .fillCredential(token: token, id: id, url: url, pairing: pairing)
        case "proposeSaveLogin":

// With:
        case "fillCredential":
            let id = try container.decode(String.self, forKey: .id)
            let url = try container.decode(String.self, forKey: .url)
            let pairing = try container.decodeIfPresent(String.self, forKey: .pairing)
            self = .fillCredential(token: token, id: id, url: url, pairing: pairing)
        case "getTotp":
            let id = try container.decode(String.self, forKey: .id)
            let url = try container.decode(String.self, forKey: .url)
            let pairing = try container.decodeIfPresent(String.self, forKey: .pairing)
            self = .getTotp(token: token, id: id, url: url, pairing: pairing)
        case "proposeSaveLogin":
```

Add the matching `encode(to:)` arm:

```swift
// Replace:
        case .fillCredential(let token, let id, let url, let pairing):
            try container.encode("fillCredential", forKey: .type)
            try container.encode(token, forKey: .token)
            try container.encode(id, forKey: .id)
            try container.encode(url, forKey: .url)
            try container.encodeIfPresent(pairing, forKey: .pairing)
        case .proposeSaveLogin(let token, let url, let username, let password, let pairing):

// With:
        case .fillCredential(let token, let id, let url, let pairing):
            try container.encode("fillCredential", forKey: .type)
            try container.encode(token, forKey: .token)
            try container.encode(id, forKey: .id)
            try container.encode(url, forKey: .url)
            try container.encodeIfPresent(pairing, forKey: .pairing)
        case .getTotp(let token, let id, let url, let pairing):
            try container.encode("getTotp", forKey: .type)
            try container.encode(token, forKey: .token)
            try container.encode(id, forKey: .id)
            try container.encode(url, forKey: .url)
            try container.encodeIfPresent(pairing, forKey: .pairing)
        case .proposeSaveLogin(let token, let url, let username, let password, let pairing):
```

Add `hasTotp` to `ExtensionCredentialSummary`:

```swift
// Replace:
public struct ExtensionCredentialSummary: Codable, Equatable {
    public let id: String
    public let title: String
    public let username: String

    public init(id: String, title: String, username: String) {
        self.id = id
        self.title = title
        self.username = username
    }
}

// With:
public struct ExtensionCredentialSummary: Codable, Equatable {
    public let id: String
    public let title: String
    public let username: String
    public let hasTotp: Bool

    public init(id: String, title: String, username: String, hasTotp: Bool) {
        self.id = id
        self.title = title
        self.username = username
        self.hasTotp = hasTotp
    }
}
```

Add the new response case:

```swift
// Replace:
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

// With:
public enum ExtensionBridgeResponse: Equatable {
    case locked
    case pairingRequired
    case pairingStarted
    case paired(secret: String)
    case credentialList([ExtensionCredentialSummary])
    case credential(username: String, password: String, totp: String?)
    case totp(code: String)
    case saveProposalAccepted
    case error(String)
}
```

Add a `code` key to `ExtensionBridgeResponse`'s `CodingKeys`:

```swift
// Replace:
    private enum CodingKeys: String, CodingKey {
        case type, credentials, username, password, totp, message, secret
    }

// With:
    private enum CodingKeys: String, CodingKey {
        case type, credentials, username, password, totp, message, secret, code
    }
```

Add a `"totp"` arm to `ExtensionBridgeResponse.init(from decoder:)`:

```swift
// Replace:
        case "credential":
            let username = try container.decode(String.self, forKey: .username)
            let password = try container.decode(String.self, forKey: .password)
            let totp = try container.decodeIfPresent(String.self, forKey: .totp)
            self = .credential(username: username, password: password, totp: totp)
        case "saveProposalAccepted":

// With:
        case "credential":
            let username = try container.decode(String.self, forKey: .username)
            let password = try container.decode(String.self, forKey: .password)
            let totp = try container.decodeIfPresent(String.self, forKey: .totp)
            self = .credential(username: username, password: password, totp: totp)
        case "totp":
            let code = try container.decode(String.self, forKey: .code)
            self = .totp(code: code)
        case "saveProposalAccepted":
```

Add the matching `encode(to:)` arm:

```swift
// Replace:
        case .credential(let username, let password, let totp):
            try container.encode("credential", forKey: .type)
            try container.encode(username, forKey: .username)
            try container.encode(password, forKey: .password)
            try container.encodeIfPresent(totp, forKey: .totp)
        case .saveProposalAccepted:

// With:
        case .credential(let username, let password, let totp):
            try container.encode("credential", forKey: .type)
            try container.encode(username, forKey: .username)
            try container.encode(password, forKey: .password)
            try container.encodeIfPresent(totp, forKey: .totp)
        case .totp(let code):
            try container.encode("totp", forKey: .type)
            try container.encode(code, forKey: .code)
        case .saveProposalAccepted:
```

- [ ] **Step 4: Run the package tests again and confirm they pass**

Run: `cd Packages/ExtensionBridgeKit && swift test`
Expected: PASS, including the three new tests.

- [ ] **Step 5: Commit**

```bash
git add Packages/ExtensionBridgeKit/Sources/ExtensionBridgeKit/ExtensionBridgeMessages.swift Packages/ExtensionBridgeKit/Tests/ExtensionBridgeKitTests/ExtensionBridgeMessagesTests.swift
git commit -m "feat(bridge): add getTotp request/response and hasTotp field to wire protocol"
```

---

### Task 2: `ExtensionBridgeService` — `hasTotp`, live TOTP on fill, `getTotp` handler

**Files:**
- Modify: `MyPass/State/ExtensionBridge/ExtensionBridgeService.swift`
- Modify: `MyPass/State/ExtensionBridge/LoopbackServer.swift` (its `requestToken(from:)` switch, lines 185-193)
- Test: `MyPassTests/ExtensionBridgeServiceTests.swift`

**Interfaces:**
- Consumes: `ExtensionBridgeRequest.getTotp`, `ExtensionBridgeResponse.totp`, `ExtensionCredentialSummary.init(id:title:username:hasTotp:)` from Task 1; `TOTPCode.currentCode(secretBase32: String, digits: Int, period: TimeInterval, algorithm: TOTPAlgorithm, now: Date) -> String?` (`MyPass/Models/TOTPCode.swift`, already reachable — same `MyPass` module target, no new import); `entry.totpSecretBase32: String?` (`MyPass/Models/KdbxEntry+Convenience.swift`); `ExtensionEntryMatcher.matchingEntries(in:forURL:)` (unchanged, already used by `fillCredential`).
- Produces: `ExtensionBridgeService.handle(_:)` now handles `.getTotp`; `.getCredentials` responses include `hasTotp`; `.fillCredential` responses include a live `totp` when the entry has a secret.

- [ ] **Step 1: Write failing tests**

In `MyPassTests/ExtensionBridgeServiceTests.swift`, **replace** the existing `testFillCredentialNeverReturnsTotpEvenWhenEntryHasOne` (including its doc comment) with a live-code assertion version:

```swift
// Replace:
    /// TOTP-filling isn't implemented anywhere downstream: the base32 seed
    /// must never be echoed back into `.credential`'s totp field, even when
    /// the matched entry has one set — sending a long-lived secret to a web
    /// page's content-script world for a feature that doesn't exist is a
    /// pure liability.
    func testFillCredentialNeverReturnsTotpEvenWhenEntryHasOne() {
        let id = addFixtureEntry(title: "Example", username: "alice", password: "s3cret", url: "https://example.com")
        session.mutate { db in
            if let index = db.rootGroup.entries.firstIndex(where: { $0.uuid == id }) {
                db.rootGroup.entries[index].totpSecretBase32 = "JBSWY3DP"
            }
        }
        let response = service.handle(.fillCredential(token: "t", id: id.uuidString, url: "https://example.com", pairing: authorizedPairingSecret))
        guard case .credential(_, _, let totp) = response else {
            return XCTFail("expected credential response, got \(response)")
        }
        XCTAssertNil(totp)
    }

// With:
    func testFillCredentialReturnsLiveTotpWhenEntryHasSecret() throws {
        let id = addFixtureEntry(title: "Example", username: "alice", password: "s3cret", url: "https://example.com")
        session.mutate { db in
            if let index = db.rootGroup.entries.firstIndex(where: { $0.uuid == id }) {
                db.rootGroup.entries[index].totpSecretBase32 = "JBSWY3DPEHPK3PXP"
            }
        }
        let response = service.handle(.fillCredential(token: "t", id: id.uuidString, url: "https://example.com", pairing: authorizedPairingSecret))
        guard case .credential(_, _, let totp) = response else {
            return XCTFail("expected credential response, got \(response)")
        }
        let code = try XCTUnwrap(totp, "expected a live TOTP code, got nil")
        XCTAssertEqual(code.count, 6)
        XCTAssertTrue(code.allSatisfy(\.isNumber), "TOTP code must be all digits")
        XCTAssertNotEqual(code, "JBSWY3DPEHPK3PXP", "response must never echo the base32 seed")
    }
```

(Assert on shape/non-nil rather than an exact recomputed value — `ExtensionBridgeService` has no injectable clock, so asserting equality against a freshly-computed `TOTPCode.currentCode(...)` in the test would be flaky across a 30s window boundary.)

Then append these new test methods to the same class:

```swift
    func testFillCredentialReturnsNilTotpWhenEntryHasNoSecret() {
        let id = addFixtureEntry(title: "Example", username: "alice", password: "s3cret", url: "https://example.com")
        let response = service.handle(.fillCredential(token: "t", id: id.uuidString, url: "https://example.com", pairing: authorizedPairingSecret))
        guard case .credential(_, _, let totp) = response else {
            return XCTFail("expected credential response, got \(response)")
        }
        XCTAssertNil(totp)
    }

    func testGetCredentialsSetsHasTotpTrueWhenSecretPresent() {
        let id = addFixtureEntry(title: "Example", username: "alice", password: "s3cret", url: "https://example.com")
        session.mutate { db in
            if let index = db.rootGroup.entries.firstIndex(where: { $0.uuid == id }) {
                db.rootGroup.entries[index].totpSecretBase32 = "JBSWY3DPEHPK3PXP"
            }
        }
        let response = service.handle(.getCredentials(token: "t", url: "https://example.com", pairing: authorizedPairingSecret))
        guard case .credentialList(let summaries) = response else {
            return XCTFail("expected credentialList, got \(response)")
        }
        XCTAssertEqual(summaries.first?.hasTotp, true)
    }

    func testGetCredentialsSetsHasTotpFalseWhenSecretAbsent() {
        _ = addFixtureEntry(title: "Example", username: "alice", password: "s3cret", url: "https://example.com")
        let response = service.handle(.getCredentials(token: "t", url: "https://example.com", pairing: authorizedPairingSecret))
        guard case .credentialList(let summaries) = response else {
            return XCTFail("expected credentialList, got \(response)")
        }
        XCTAssertEqual(summaries.first?.hasTotp, false)
    }

    func testGetTotpReturnsLiveCodeForMatchingEntry() {
        let id = addFixtureEntry(title: "Example", username: "alice", password: "s3cret", url: "https://example.com")
        session.mutate { db in
            if let index = db.rootGroup.entries.firstIndex(where: { $0.uuid == id }) {
                db.rootGroup.entries[index].totpSecretBase32 = "JBSWY3DPEHPK3PXP"
            }
        }
        let response = service.handle(.getTotp(token: "t", id: id.uuidString, url: "https://example.com", pairing: authorizedPairingSecret))
        guard case .totp(let code) = response else {
            return XCTFail("expected totp response, got \(response)")
        }
        XCTAssertEqual(code.count, 6)
        XCTAssertTrue(code.allSatisfy(\.isNumber))
    }

    func testGetTotpRejectsDomainMismatch() {
        let id = addFixtureEntry(title: "Example", username: "alice", password: "s3cret", url: "https://example.com")
        session.mutate { db in
            if let index = db.rootGroup.entries.firstIndex(where: { $0.uuid == id }) {
                db.rootGroup.entries[index].totpSecretBase32 = "JBSWY3DPEHPK3PXP"
            }
        }
        let response = service.handle(.getTotp(token: "t", id: id.uuidString, url: "https://not-example.com", pairing: authorizedPairingSecret))
        XCTAssertEqual(response, .error("entry not found or domain mismatch"))
    }

    func testGetTotpReturnsLockedWhenVaultIsLocked() {
        session.lock()
        let response = service.handle(.getTotp(token: "t", id: UUID().uuidString, url: "https://example.com", pairing: authorizedPairingSecret))
        XCTAssertEqual(response, .locked)
    }

    func testGetTotpReturnsPairingRequiredWithoutSecret() {
        let id = addFixtureEntry(title: "Example", username: "alice", password: "s3cret", url: "https://example.com")
        let (service, _, _) = makeServiceWithPairing()
        let response = service.handle(.getTotp(token: "t", id: id.uuidString, url: "https://example.com", pairing: nil))
        XCTAssertEqual(response, .pairingRequired)
    }

    func testGetTotpDoesNotTouchAccess() {
        let id = addFixtureEntry(title: "Example", username: "alice", password: "s3cret", url: "https://example.com")
        session.mutate { db in
            if let index = db.rootGroup.entries.firstIndex(where: { $0.uuid == id }) {
                db.rootGroup.entries[index].totpSecretBase32 = "JBSWY3DPEHPK3PXP"
            }
        }
        var touchedIDs: [UUID] = []
        service.onCredentialFilled = { touchedIDs.append($0) }
        _ = service.handle(.getTotp(token: "t", id: id.uuidString, url: "https://example.com", pairing: authorizedPairingSecret))
        XCTAssertTrue(touchedIDs.isEmpty, "getTotp must not fire onCredentialFilled/touchAccess")
    }
```

- [ ] **Step 2: Run the tests and confirm they fail to compile**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS'`
Expected: build fails — no `.getTotp` case on `ExtensionBridgeRequest` consumer side pending Task 2's production edit, `.totp` unhandled, `hasTotp` missing on `ExtensionCredentialSummary` call site in `ExtensionBridgeService.swift`.

- [ ] **Step 3: Fix the `LoopbackServer` token-extraction switch**

`ExtensionBridgeRequest` is no longer exhaustively handled by `requestToken(from:)` once `.getTotp` exists. In `MyPass/State/ExtensionBridge/LoopbackServer.swift`:

```swift
// Replace:
    private func requestToken(from request: ExtensionBridgeRequest) -> String {
        switch request {
        case .getCredentials(let token, _, _): return token
        case .fillCredential(let token, _, _, _): return token
        case .proposeSaveLogin(let token, _, _, _, _): return token
        case .startPairing(let token, _): return token
        case .completePairing(let token, _): return token
        }
    }

// With:
    private func requestToken(from request: ExtensionBridgeRequest) -> String {
        switch request {
        case .getCredentials(let token, _, _): return token
        case .fillCredential(let token, _, _, _): return token
        case .getTotp(let token, _, _, _): return token
        case .proposeSaveLogin(let token, _, _, _, _): return token
        case .startPairing(let token, _): return token
        case .completePairing(let token, _): return token
        }
    }
```

- [ ] **Step 4: Implement `ExtensionBridgeService` changes**

In `MyPass/State/ExtensionBridge/ExtensionBridgeService.swift`, populate `hasTotp` in `getCredentials`:

```swift
// Replace:
            let matches = ExtensionEntryMatcher.matchingEntries(in: database.rootGroup, forURL: url)
            let summaries = matches.map {
                ExtensionCredentialSummary(id: $0.uuid.uuidString, title: $0.title, username: $0.login)
            }
            return .credentialList(summaries)

        case .fillCredential(_, let id, let url, let pairing):

// With:
            let matches = ExtensionEntryMatcher.matchingEntries(in: database.rootGroup, forURL: url)
            let summaries = matches.map {
                ExtensionCredentialSummary(
                    id: $0.uuid.uuidString,
                    title: $0.title,
                    username: $0.login,
                    hasTotp: $0.totpSecretBase32?.isEmpty == false
                )
            }
            return .credentialList(summaries)

        case .fillCredential(_, let id, let url, let pairing):
```

Compute a live TOTP in `fillCredential` and add the new `getTotp` case right after it:

```swift
// Replace:
            let matches = ExtensionEntryMatcher.matchingEntries(in: database.rootGroup, forURL: url)
            guard let entry = matches.first(where: { $0.uuid.uuidString == id }) else {
                return .error("entry not found or domain mismatch")
            }
            // TOTP filling isn't implemented anywhere downstream (no consumer
            // reads `.credential`'s totp field), so the raw base32 seed is
            // never populated here — sending a long-lived secret into a web
            // page's content-script world for a feature that doesn't exist
            // would be a pure liability. Always `nil` until TOTP-filling is
            // actually built.
            onCredentialFilled?(entry.uuid)
            vaultSession?.touchAccess(entryID: entry.uuid)
            return .credential(username: entry.login, password: entry.password, totp: nil)

        case .proposeSaveLogin(_, let url, let username, let password, let pairing):

// With:
            let matches = ExtensionEntryMatcher.matchingEntries(in: database.rootGroup, forURL: url)
            guard let entry = matches.first(where: { $0.uuid.uuidString == id }) else {
                return .error("entry not found or domain mismatch")
            }
            // Only a live, time-boxed six-digit code crosses the bridge — the
            // Base32 seed itself is never sent to the extension.
            let liveTotp = entry.totpSecretBase32.flatMap {
                TOTPCode.currentCode(secretBase32: $0, digits: 6, period: 30, algorithm: .sha1, now: Date())
            }
            onCredentialFilled?(entry.uuid)
            vaultSession?.touchAccess(entryID: entry.uuid)
            return .credential(username: entry.login, password: entry.password, totp: liveTotp)

        case .getTotp(_, let id, let url, let pairing):
            guard pairingManager.isAuthorized(pairing: pairing) else {
                return .pairingRequired
            }
            guard let database = vaultSession?.currentDatabase else {
                return .locked
            }
            let matches = ExtensionEntryMatcher.matchingEntries(in: database.rootGroup, forURL: url)
            guard let entry = matches.first(where: { $0.uuid.uuidString == id }) else {
                return .error("entry not found or domain mismatch")
            }
            guard let secret = entry.totpSecretBase32,
                  let code = TOTPCode.currentCode(secretBase32: secret, digits: 6, period: 30, algorithm: .sha1, now: Date()) else {
                return .error("entry has no TOTP secret")
            }
            return .totp(code: code)

        case .proposeSaveLogin(_, let url, let username, let password, let pairing):
```

Note the `getTotp` case deliberately does **not** call `onCredentialFilled?` or `vaultSession?.touchAccess` — that's what `testGetTotpDoesNotTouchAccess` verifies.

- [ ] **Step 5: Run the tests again and confirm they pass**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS'`
Expected: PASS, including all new/replaced tests in `ExtensionBridgeServiceTests.swift`.

Also run: `cd Packages/ExtensionBridgeKit && swift test` to confirm Task 1's changes still pass now that `ExtensionBridgeService.swift` consumes them.

- [ ] **Step 6: Commit**

```bash
git add MyPass/State/ExtensionBridge/ExtensionBridgeService.swift MyPass/State/ExtensionBridge/LoopbackServer.swift MyPassTests/ExtensionBridgeServiceTests.swift
git commit -m "feat(bridge): compute live TOTP on fill and add getTotp handler"
```

---

### Task 3: `content.js` — OTP field detection and OTP-aware `applyFill`

**Files:**
- Modify: `ChromeExtension/content.js`
- Test: `ChromeExtension/tests/formDetection.test.js`

**Interfaces:**
- Produces: `scoreOtpLikeness(input)` — returns an integer score (0 excludes the candidate); `findOtpField(root)` — returns the highest-scoring visible `<input>`/`<textarea>` in `root` (defaults to `document`), or `null`; both added to `content.js`'s `module.exports`. `applyFill`'s message handler now fills username/password/TOTP independently based on what's present on the page and in the message.

- [ ] **Step 1: Read the test file, then write failing tests**

Open `ChromeExtension/tests/formDetection.test.js` and confirm the exact signature of its existing `fakeInput(attrs)` factory (it stubs `getAttribute`) and how it `require`s `content.js`'s CommonJS exports. Reuse that same style.

Append the following to the file, before its final `console.log(...)` line:

```js
// --- OTP field scoring ---

const otpAutocomplete = fakeInput({ type: 'text', autocomplete: 'one-time-code' });
assert.strictEqual(scoreOtpLikeness(otpAutocomplete), 10, 'autocomplete=one-time-code scores 10');

const otpByName = fakeInput({ type: 'text', name: 'otp-code' });
assert.strictEqual(scoreOtpLikeness(otpByName), 7, 'name matching otp pattern scores 6, plus 1 for type=text');

const otpByNumericMode = fakeInput({ type: 'text', inputmode: 'numeric', maxlength: '6' });
assert.strictEqual(scoreOtpLikeness(otpByNumericMode), 5, 'numeric inputmode + maxlength 6 scores 4, plus 1 for type=text');

const genericText = fakeInput({ type: 'text' });
assert.strictEqual(scoreOtpLikeness(genericText), 1, 'plain text input scores 1 (fallback signal)');

const passwordField = fakeInput({ type: 'password', autocomplete: 'one-time-code' });
assert.strictEqual(scoreOtpLikeness(passwordField), 0, 'password inputs are excluded even with matching autocomplete');

const hiddenField = fakeInput({ type: 'hidden', name: 'otp' });
assert.strictEqual(scoreOtpLikeness(hiddenField), 0, 'hidden inputs are excluded');

const disabledField = fakeInput({ type: 'text', disabled: 'true', name: 'otp' });
assert.strictEqual(scoreOtpLikeness(disabledField), 0, 'disabled inputs are excluded');

const readonlyField = fakeInput({ type: 'text', readonly: 'true', name: 'otp' });
assert.strictEqual(scoreOtpLikeness(readonlyField), 0, 'readonly inputs are excluded');

console.log('formDetection.test.js: OTP scoring OK');

// --- findOtpField ---

const fakeOtpDoc = {
  querySelectorAll: () => [
    fakeInput({ type: 'text' }),
    fakeInput({ type: 'text', autocomplete: 'one-time-code', id: 'best-match' }),
    fakeInput({ type: 'password' }),
  ],
};
const found = findOtpField(fakeOtpDoc);
assert.strictEqual(found.getAttribute('id'), 'best-match', 'findOtpField picks the highest-scoring candidate');

const fakeLoginOnlyDoc = {
  querySelectorAll: () => [
    fakeInput({ type: 'text', name: 'username' }),
    fakeInput({ type: 'password', name: 'password' }),
  ],
};
assert.strictEqual(findOtpField(fakeLoginOnlyDoc), null, 'no OTP-like field on a login-only page');

const fakeOtpOnlyDoc = {
  querySelectorAll: () => [
    fakeInput({ type: 'text', autocomplete: 'one-time-code' }),
  ],
};
assert.notStrictEqual(findOtpField(fakeOtpOnlyDoc), null, 'OTP-only page (no password field) still finds the OTP input');

console.log('formDetection.test.js: findOtpField OK');
```

Update the file's `require(...)` destructuring line to also pull in `scoreOtpLikeness` and `findOtpField` alongside the existing imports (e.g. `findBestUsernameInput`, `scoreUsernameLikeness`), matching however that line is currently written.

- [ ] **Step 2: Run the test and confirm it fails**

Run: `node ChromeExtension/tests/formDetection.test.js`
Expected: `TypeError: scoreOtpLikeness is not a function` (or `undefined`) — the exports don't exist yet.

- [ ] **Step 3: Implement `scoreOtpLikeness`, `findOtpField`, and OTP-aware `applyFill` in `content.js`**

Add these two functions somewhere among `content.js`'s other top-level helper functions (near the existing username-scoring helpers), before the CommonJS export block:

```js
function scoreOtpLikeness(input) {
  if (!input) return 0;
  const type = (input.getAttribute('type') || 'text').toLowerCase();
  const isDisabled = input.getAttribute('disabled') !== null || input.disabled === true;
  const isReadOnly = input.getAttribute('readonly') !== null || input.readOnly === true;
  if (type === 'password' || type === 'hidden' || isDisabled || isReadOnly) {
    return 0;
  }

  let score = 0;
  const autocomplete = (input.getAttribute('autocomplete') || '').toLowerCase();
  if (autocomplete === 'one-time-code') score += 10;

  const nameOrId = `${input.getAttribute('name') || ''} ${input.getAttribute('id') || ''}`.toLowerCase();
  if (/otp|totp|2fa|two.?factor|verification.?code|auth.?code|security.?code/.test(nameOrId)) {
    score += 6;
  }

  const inputMode = (input.getAttribute('inputmode') || '').toLowerCase();
  const maxLength = parseInt(input.getAttribute('maxlength') || '', 10);
  if (inputMode === 'numeric' && [6, 7, 8].includes(maxLength)) {
    score += 4;
  }

  if (type === 'tel' || type === 'text') {
    score += 1;
  }

  return score;
}

function findOtpField(root) {
  const scope = root || document;
  const candidates = Array.from(scope.querySelectorAll('input, textarea'));
  let best = null;
  let bestScore = 0;
  for (const candidate of candidates) {
    if (candidate.offsetParent === null) continue;
    const score = scoreOtpLikeness(candidate);
    if (score > bestScore) {
      bestScore = score;
      best = candidate;
    }
  }
  return best;
}
```

(`candidate.offsetParent === null` is the visibility check — real hidden/detached DOM elements have `offsetParent === null`; fake test objects that don't set it pass through, since `undefined === null` is `false`.)

Update the `applyFill` message listener so it no longer requires a login form to exist, and fills username/password/TOTP independently:

```js
// Replace:
  chrome.runtime.onMessage.addListener((message) => {
    if (message.type === 'applyFill') {
      if (!hostnameMatches(message.url, location.href)) {
        console.warn('MyPass: applyFill rejected — message URL does not match the current page hostname');
        return;
      }
      const loginForm = findLoginForm();
      if (!loginForm) return;
      if (loginForm.usernameInput && message.username) {
        setNativeValue(loginForm.usernameInput, message.username);
      }
      setNativeValue(loginForm.passwordInput, message.password);
    }
  });

// With:
  chrome.runtime.onMessage.addListener((message) => {
    if (message.type === 'applyFill') {
      if (!hostnameMatches(message.url, location.href)) {
        console.warn('MyPass: applyFill rejected — message URL does not match the current page hostname');
        return;
      }
      const loginForm = findLoginForm();
      if (loginForm) {
        if (loginForm.usernameInput && message.username) {
          setNativeValue(loginForm.usernameInput, message.username);
        }
        if (loginForm.passwordInput && message.password) {
          setNativeValue(loginForm.passwordInput, message.password);
        }
      }
      if (message.totp) {
        const otpField = findOtpField();
        if (otpField) {
          setNativeValue(otpField, message.totp);
        }
      }
    }
  });
```

Update the CommonJS export block to include the two new functions:

```js
// Replace:
  if (typeof module !== 'undefined') {
    module.exports = { scoreUsernameLikeness, findBestUsernameInput, hostnameMatches };
  }

// With:
  if (typeof module !== 'undefined') {
    module.exports = { scoreUsernameLikeness, findBestUsernameInput, hostnameMatches, scoreOtpLikeness, findOtpField };
  }
```

- [ ] **Step 4: Run the test again and confirm it passes**

Run: `node ChromeExtension/tests/formDetection.test.js`
Expected: PASS, all assertions including the new OTP ones.

- [ ] **Step 5: Commit**

```bash
git add ChromeExtension/content.js ChromeExtension/tests/formDetection.test.js
git commit -m "feat(chrome): detect OTP fields and fill them independently of the login form"
```

---

### Task 4: `background.js` — route `getTotp`

**Files:**
- Modify: `ChromeExtension/background.js`
- Test: `ChromeExtension/tests/pairing.test.js`

**Interfaces:**
- Produces: module-level `knownTypes` array (now exported) includes `"getTotp"`; `getTotp` messages flow through the existing generic `sendNativeMessageWithPairing(message).then((response) => sendResponse(response))` path unchanged (the `stripCredentialSecrets`/`relayFillToActiveTab` special-casing in that `.then()` only fires for `message.type === "fillCredential"`, so a `"totp"`-typed response passes through to the popup untouched).

- [ ] **Step 1: Write a failing test**

Open `ChromeExtension/tests/pairing.test.js` and find its async IIFE (`(async () => { ... })();`) that exercises `background.js`'s exports. Add this assertion inside it, before the IIFE's closing line:

```js
{
  const { knownTypes } = require('../background.js');
  assert.ok(knownTypes.includes('getTotp'), 'getTotp must be a known routed message type');
  console.log('pairing.test.js: getTotp knownTypes OK');
}
```

- [ ] **Step 2: Run the test and confirm it fails**

Run: `node ChromeExtension/tests/pairing.test.js`
Expected: `TypeError: Cannot destructure property 'knownTypes'` (or `knownTypes` is `undefined`) — it isn't exported yet, and today it's declared inside the `onMessage` listener, not at module scope.

- [ ] **Step 3: Move `knownTypes` to module scope, add `getTotp`, and export it**

In `ChromeExtension/background.js`, find:

```js
  chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
    const knownTypes = ["getCredentials", "fillCredential", "proposeSaveLogin", "startPairing", "completePairing"];
    if (!message || !knownTypes.includes(message.type)) {
      return false;
    }
```

Replace it with:

```js
  chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
    if (!message || !knownTypes.includes(message.type)) {
      return false;
    }
```

And near the top of the file, alongside its other module-level declarations, add the hoisted constant:

```js
const knownTypes = ["getCredentials", "fillCredential", "getTotp", "proposeSaveLogin", "startPairing", "completePairing"];
```

Find the file's `if (typeof module !== 'undefined') { module.exports = { ... }; }` block near the end and add `knownTypes` to the exported object (alongside whatever pairing-related helpers it already exports).

- [ ] **Step 4: Run the test again and confirm it passes**

Run: `node ChromeExtension/tests/pairing.test.js`
Expected: PASS.

Also run: `node ChromeExtension/tests/background.manifest.test.js` and `node ChromeExtension/tests/formDetection.test.js` to confirm no regressions.

- [ ] **Step 5: Commit**

```bash
git add ChromeExtension/background.js ChromeExtension/tests/pairing.test.js
git commit -m "feat(chrome): route getTotp through the existing native-message relay"
```

---

### Task 5: `popup.js` / `popup.html` — privacy circle UI

**Files:**
- Modify: `ChromeExtension/popup.js`
- Modify: `ChromeExtension/popup.html`
- Create: `ChromeExtension/tests/totpCircle.test.js`
- Modify: `scripts/test.sh`

**Interfaces:**
- Consumes: `credential.hasTotp: Bool` on each item in the `getCredentials` response (Tasks 1-2); `getTotp` message type routed by Task 4.
- Produces: `shouldShowTotpCircle(hasTotp)`, `createTotpCircleController(circleEl, requestTotp)`, `buildTotpCircleElement(credential, url)` — all added to `popup.js`'s `module.exports`.

- [ ] **Step 1: Read the existing DOM-stub test pattern, then write a failing test**

Open `ChromeExtension/tests/popup-fallback.test.js` in full and note its exact `global.document` / `global.chrome` stubbing setup — it already successfully `require('../popup.js')`s without the module's top-level DOM-wiring code throwing. Reuse that same stub baseline (copy it) as the foundation for the new file below, rather than inventing a new one — `popup.js`'s DOM-wiring block runs at `require`-time and needs the same stubs to not throw.

Create `ChromeExtension/tests/totpCircle.test.js`:

```js
const assert = require('node:assert');

// --- copy the exact global.document / global.chrome stub setup from
// popup-fallback.test.js here, before the require('../popup.js') call below,
// so popup.js's top-level DOM-wiring code doesn't throw on require. ---

function makeFakeCircleElement() {
  const classes = new Set();
  const listeners = {};
  return {
    classList: {
      add(...names) { names.forEach((n) => classes.add(n)); },
      remove(...names) { names.forEach((n) => classes.delete(n)); },
      contains(name) { return classes.has(name); },
    },
    textContent: '',
    addEventListener(type, handler) {
      listeners[type] = listeners[type] || [];
      listeners[type].push(handler);
    },
    dispatch(type, event) {
      (listeners[type] || []).forEach((handler) => handler(event));
    },
    contains() { return false; },
  };
}

const { shouldShowTotpCircle, createTotpCircleController } = require('../popup.js');

assert.strictEqual(shouldShowTotpCircle(true), true);
assert.strictEqual(shouldShowTotpCircle(false), false);
assert.strictEqual(shouldShowTotpCircle(undefined), false);
console.log('totpCircle.test.js: shouldShowTotpCircle OK');

(async () => {
  const circle = makeFakeCircleElement();
  let requestCount = 0;
  const requestTotp = () => {
    requestCount += 1;
    return Promise.resolve('123456');
  };
  createTotpCircleController(circle, requestTotp);

  let stopped = false;
  circle.dispatch('click', { stopPropagation: () => { stopped = true; } });
  await Promise.resolve();
  await Promise.resolve();

  assert.strictEqual(stopped, true, 'circle click must stopPropagation so it never bubbles to the row click handler');
  assert.strictEqual(circle.textContent, '123456', 'left-click reveals the code');
  assert.strictEqual(requestCount, 1);

  circle.dispatch('click', { stopPropagation: () => {} });
  assert.strictEqual(circle.textContent, '', 'second left-click hides the code');

  console.log('totpCircle.test.js: createTotpCircleController reveal/hide OK');
})();
```

- [ ] **Step 2: Run the test and confirm it fails**

Run: `node ChromeExtension/tests/totpCircle.test.js`
Expected: fails at the `require('../popup.js')` destructure — `shouldShowTotpCircle`/`createTotpCircleController` are `undefined` (not yet implemented/exported).

- [ ] **Step 3: Implement the privacy circle in `popup.js`**

Add these near `popup.js`'s other top-level helpers (near `buildLetterAvatarElement`), before the CommonJS export block:

```js
const TOTP_AUTO_HIDE_MS = 5000;

function shouldShowTotpCircle(hasTotp) {
  return hasTotp === true;
}

function createTotpCircleController(circleEl, requestTotp) {
  let hideTimer = null;
  let revealed = false;

  function clearHideTimer() {
    if (hideTimer) {
      clearTimeout(hideTimer);
      hideTimer = null;
    }
  }

  function showIdle() {
    clearHideTimer();
    revealed = false;
    circleEl.textContent = '';
    circleEl.classList.remove('revealed', 'copied');
  }

  function showDigits(code) {
    revealed = true;
    circleEl.textContent = code;
    circleEl.classList.add('revealed');
    circleEl.classList.remove('copied');
    clearHideTimer();
    hideTimer = setTimeout(showIdle, TOTP_AUTO_HIDE_MS);
  }

  function showCopiedFlash() {
    circleEl.textContent = 'Copied';
    circleEl.classList.add('copied');
    circleEl.classList.remove('revealed');
    clearHideTimer();
    hideTimer = setTimeout(showIdle, TOTP_AUTO_HIDE_MS);
  }

  function handleLeftClick(event) {
    event.stopPropagation();
    if (revealed) {
      showIdle();
      return;
    }
    requestTotp().then((code) => {
      if (code) showDigits(code);
    }).catch(() => {});
  }

  function handleContextMenu(event) {
    event.preventDefault();
    event.stopPropagation();
    requestTotp().then((code) => {
      if (!code) return;
      navigator.clipboard.writeText(code).then(showCopiedFlash).catch(() => {});
    }).catch(() => {});
  }

  function handleMouseDown(event) {
    event.stopPropagation();
  }

  function handleOutsideClick(event) {
    if (revealed && !circleEl.contains(event.target)) {
      showIdle();
    }
  }

  circleEl.addEventListener('mousedown', handleMouseDown);
  circleEl.addEventListener('click', handleLeftClick);
  circleEl.addEventListener('contextmenu', handleContextMenu);
  document.addEventListener('click', handleOutsideClick);

  return { showIdle, showDigits, showCopiedFlash };
}

function buildTotpCircleElement(credential, url) {
  const circle = document.createElement('div');
  circle.className = 'totp-circle';
  circle.setAttribute('role', 'button');
  circle.setAttribute('aria-label', 'Reveal or copy verification code');

  const requestTotp = () => new Promise((resolve, reject) => {
    chrome.runtime.sendMessage({ type: 'getTotp', id: credential.id, url }, (response) => {
      if (response && response.type === 'totp' && response.code) {
        resolve(response.code);
      } else {
        reject(new Error('getTotp failed'));
      }
    });
  });

  createTotpCircleController(circle, requestTotp);
  return circle;
}
```

Wire the circle into `renderCredentials`:

```js
// Replace:
    item.appendChild(textCol);
    item.addEventListener('click', () => {
      chrome.runtime.sendMessage(
        { type: 'fillCredential', id: credential.id, url },
        () => {
          window.close();
        }
      );
    });
    listEl.appendChild(item);

// With:
    item.appendChild(textCol);

    if (shouldShowTotpCircle(credential.hasTotp)) {
      item.appendChild(buildTotpCircleElement(credential, url));
    }

    item.addEventListener('click', () => {
      chrome.runtime.sendMessage(
        { type: 'fillCredential', id: credential.id, url },
        () => {
          window.close();
        }
      );
    });
    listEl.appendChild(item);
```

Update the CommonJS export block to add the three new functions to whatever it already exports (alongside `letterFromTitle`, `colorForTitle`, etc.):

```js
shouldShowTotpCircle, createTotpCircleController, buildTotpCircleElement
```

In `ChromeExtension/popup.html`, add circle styling inside the existing `<style>` block, near the `.credential-row`/`.credential-text` rules:

```css
.totp-circle {
  flex-shrink: 0;
  width: 32px;
  height: 32px;
  border-radius: 50%;
  border: 1px solid rgba(127, 127, 127, 0.35);
  display: flex;
  align-items: center;
  justify-content: center;
  font-family: ui-monospace, SFMono-Regular, monospace;
  font-size: 11px;
  cursor: pointer;
  user-select: none;
}

.totp-circle.revealed {
  border-color: rgba(80, 160, 255, 0.6);
}

.totp-circle.copied {
  font-size: 9px;
  border-color: rgba(60, 200, 120, 0.6);
}
```

(No markup changes needed in `popup.html` beyond this CSS — the circle element is created dynamically per-row in `renderCredentials`, same as `buildLetterAvatarElement`; `.credential-row`'s existing `display:flex` plus `.credential-text`'s `flex:1` already reserve the circle's space at the trailing edge.)

- [ ] **Step 4: Wire the new test into `scripts/test.sh`**

```bash
# Replace:
if command -v node >/dev/null 2>&1; then
  node ChromeExtension/tests/background.manifest.test.js
  node ChromeExtension/tests/formDetection.test.js
  node ChromeExtension/tests/pairing.test.js
else
  echo "Warning: node not found — skipping ChromeExtension JS tests." >&2
fi

# With:
if command -v node >/dev/null 2>&1; then
  node ChromeExtension/tests/background.manifest.test.js
  node ChromeExtension/tests/formDetection.test.js
  node ChromeExtension/tests/pairing.test.js
  node ChromeExtension/tests/totpCircle.test.js
else
  echo "Warning: node not found — skipping ChromeExtension JS tests." >&2
fi
```

- [ ] **Step 5: Run the test again and confirm it passes**

Run: `node ChromeExtension/tests/totpCircle.test.js`
Expected: PASS.

Also run `node ChromeExtension/tests/popup-fallback.test.js` and `node ChromeExtension/tests/letter-avatar.test.js` to confirm the `renderCredentials` change didn't break existing popup behavior (these aren't in `scripts/test.sh` today, but both exercise `popup.js` and should still be checked manually here since this task edits that file directly).

- [ ] **Step 6: Commit**

```bash
git add ChromeExtension/popup.js ChromeExtension/popup.html ChromeExtension/tests/totpCircle.test.js scripts/test.sh
git commit -m "feat(chrome): add popup privacy circle for TOTP reveal and copy"
```

---

### Task 6: Manual e2e fixtures and `RUN.md` checklist

**Files:**
- Create: `ChromeExtension/tests/fixtures/otp.html`
- Create: `ChromeExtension/tests/fixtures/login-with-otp.html`
- Modify: `RUN.md`

**Interfaces:** none (fixtures + docs only, no code consumed/produced).

- [ ] **Step 1: Create the OTP-only fixture page**

Write `ChromeExtension/tests/fixtures/otp.html`:

```html
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <title>MyPass OTP fixture</title>
</head>
<body>
  <h1>Verify your identity</h1>
  <form>
    <label for="otp">Verification code</label>
    <input id="otp" name="otp" type="text" inputmode="numeric" maxlength="6" autocomplete="one-time-code">
    <button type="submit">Verify</button>
  </form>
</body>
</html>
```

- [ ] **Step 2: Create the combined login + OTP fixture page**

Write `ChromeExtension/tests/fixtures/login-with-otp.html`:

```html
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <title>MyPass login + OTP fixture</title>
</head>
<body>
  <h1>Sign in</h1>
  <form>
    <label for="username">Username</label>
    <input id="username" name="username" type="text" autocomplete="username">
    <label for="password">Password</label>
    <input id="password" name="password" type="password" autocomplete="current-password">
    <label for="otp">Verification code</label>
    <input id="otp" name="otp" type="text" inputmode="numeric" maxlength="6" autocomplete="one-time-code">
    <button type="submit">Sign in</button>
  </form>
</body>
</html>
```

- [ ] **Step 3: Verify both fixtures are served correctly**

Run: `cd ChromeExtension/tests/fixtures && python3 -m http.server 8765 &`
Then: `curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8765/otp.html` and `curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8765/login-with-otp.html`
Expected: both print `200`. Then stop the server: `kill %1`.

- [ ] **Step 4: Add manual e2e bullets to `RUN.md`**

In `RUN.md`, find the "Короткий чеклист" list under the `### Chrome e2e (ручна перевірка)` heading:

```markdown
// Replace:
  2. Короткий чеклист:
     - [ ] Popup показує збіги для домену фікстури
     - [ ] Autofill заповнює логін/пароль за явною дією користувача
     - [ ] Після входу пропонується зберегти новий запис
     - [ ] Збережений запис з'являється в MyPass

// With:
  2. Короткий чеклист:
     - [ ] Popup показує збіги для домену фікстури
     - [ ] Autofill заповнює логін/пароль за явною дією користувача
     - [ ] Після входу пропонується зберегти новий запис
     - [ ] Збережений запис з'являється в MyPass
     - [ ] Запис з TOTP показує кружечок конфіденційності в списку popup (`hasTotp`); кружечок не показує цифри до кліку
     - [ ] Клік на рядок логін-сторінки заповнює логін+пароль; TOTP не вставляється, якщо на сторінці немає поля OTP
     - [ ] Сторінка з полем OTP: клік на рядок заповнює код, якщо у запису є TOTP-секрет
     - [ ] Фікстура лише з OTP: клік на рядок заповнює код підтвердження без полів логіна/пароля
     - [ ] Лівий клік на кружечок показує код; ховається через ~5 с або при кліку поза кружечком
     - [ ] Правий клік на кружечок копіює код у буфер обміну (перевірка через вставку)
     - [ ] Клік на кружечок не закриває popup і не запускає autofill; клік на рядок як і раніше заповнює та закриває popup
```

(`RUN.md` is Ukrainian by project convention — do not translate any of it, existing or new.)

- [ ] **Step 5: Commit**

```bash
git add ChromeExtension/tests/fixtures/otp.html ChromeExtension/tests/fixtures/login-with-otp.html RUN.md
git commit -m "docs(chrome): add TOTP manual e2e fixtures and checklist bullets"
```

---

### Task 7: Full verification run

**Files:** none (verification only).

- [ ] **Step 1: Run the full test suite**

Run: `./scripts/test.sh`
Expected: PASS end-to-end — `xcodebuild test` (including the new/replaced `ExtensionBridgeServiceTests` cases), `swift test` for `MyPassKit`, `SyncKit`, and `ExtensionBridgeKit` (including the new `ExtensionBridgeMessagesTests` cases), and all four `node ChromeExtension/tests/*.test.js` invocations (including the new `totpCircle.test.js`).

- [ ] **Step 2: Cross-check acceptance criteria against the spec**

Confirm each of the following, from `docs/superpowers/specs/2026-08-01-chrome-extension-totp-autofill-design.md`'s Acceptance Criteria section:

1. `getCredentials` returns `hasTotp: true`/`false` correctly, no secret or code in the list payload — verified by `testGetCredentialsSetsHasTotpTrueWhenSecretPresent`/`False`.
2. Row click on a page with login + OTP inputs fills all three when the entry has a secret; popup receives `{ type: "ok" }` only — verified by `testFillCredentialReturnsLiveTotpWhenEntryHasSecret` (Swift side) plus `applyFill`'s independent-fill logic (JS side); `stripCredentialSecrets` behavior is unchanged.
3. Fill without an OTP field: username/password fill, `totp` not written to the DOM, no error — verified by `applyFill`'s `if (message.totp) { const otpField = findOtpField(); if (otpField) {...} }` guard (silently no-ops when `findOtpField()` returns `null`).
4. OTP-only page: row click fills TOTP only, no console errors for the missing password field — verified by `applyFill`'s `if (loginForm) {...}` guard no longer being required for the OTP branch, plus the `findOtpField` OTP-only-document test.
5. Privacy circle idle by default — verified by `createTotpCircleController`'s initial state (no `showDigits` call until a click).
6. Reveal via left-click, auto-hide ~5 s — verified by `testtotpCircle.test.js`'s reveal/hide assertions and `TOTP_AUTO_HIDE_MS`.
7. Copy via right-click/contextmenu, copied flash, no row fill — verified by `handleContextMenu`'s `preventDefault()` + `stopPropagation()` + clipboard write.
8. Circle clicks never send `fillCredential`; row click still fills and closes — verified by `stopPropagation()` on the circle's `mousedown`/`click`/`contextmenu` listeners.
9. No Base32 anywhere in extension messages; domain mismatch blocks both fill and `getTotp`; `stripCredentialSecrets` still applies — verified by `testFillCredentialReturnsLiveTotpWhenEntryHasSecret`'s `XCTAssertNotEqual(code, "JBSWY3DPEHPK3PXP", ...)`, `testGetTotpRejectsDomainMismatch`, and `background.js`'s unchanged `stripCredentialSecrets` (only special-cased for `fillCredential`, so it's untouched by this plan).
10. JS OTP scoring tests pass, Swift `hasTotp`/live-fill/`getTotp` tests pass, obsolete forbid-totp test removed — verified by `./scripts/test.sh`'s full green run in Step 1, and `testFillCredentialNeverReturnsTotpEvenWhenEntryHasOne` no longer existing (replaced in Task 2).

If any criterion doesn't hold, stop and fix it before considering the plan complete — do not proceed to a PR/branch-finishing step with a known gap.
