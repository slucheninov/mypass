# Chrome Extension TOTP Setup (Piece B) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a MyPass Chrome extension user detect 2FA setup material on a web page (otpauth:// link, QR code, or manual Base32 key) or paste it into the popup, then have MyPass open a pre-filled create/edit form so the user confirms the save themselves — the extension never writes to the vault.

**Architecture:** `content.js` detects TOTP setup candidates on the page (link/text/QR/manual-key, in priority order) and shows a "Save 2FA to MyPass?" banner separate from the existing password-save banner; `popup.js` gains an "Add 2FA" paste field plus an entry picker for the multiple-domain-match case. Both paths resolve 0/1/N domain-matched entries via the existing `getCredentials` message, then send a new `proposeSaveTotp` message. On the Swift side, `ExtensionBridgeService.handle` gains a `proposeSaveTotp` case that re-validates domain match when an `entryId` is supplied (mirroring `fillCredential`'s gate) and invokes a new `onTotpSaveProposal` callback; `MyPassApp.init()` wires that callback to activate the window and route into `EntryEditView` via new `NavigationState`/`DetailPresentation` cases, mirroring the existing `PendingSaveProposal`/`createFromProposal` pattern exactly. `EntryEditView` pre-fills the OTP field and, if the target entry already has a secret, gates the Save button behind a new "Replace 2FA?" confirmation before `EntryEditSaveLogic.applyOTP` overwrites it.

**Tech Stack:** Swift (Xcode project + SwiftUI + Swift Package Manager for `ExtensionBridgeKit`), vanilla JavaScript (Chrome MV3, CommonJS exports for Node tests, no bundler), XCTest, Node's `assert` module, a vendored third-party QR decoder (`jsQR`).

## Global Constraints

- The extension and ChromeHost **never** call `VaultSession.mutate` or write KDBX — only the user's own Save tap inside `EntryEditView` persists `totpSecretBase32`.
- Same trust model as the existing password-save flow: pairing secret required, vault must be unlocked (locked → banner hidden / popup shows locked state, no proposal sent).
- When `entryId` is supplied on `proposeSaveTotp`, the app re-validates that entry's domain against the proposal `url` via `ExtensionEntryMatcher` — same gate `fillCredential` already uses. Mismatch → `.error("entry not found or domain mismatch")`, no window activation.
- Zero domain matches → create a new login entry with OTP pre-filled (title defaults to registrable domain, username/password empty). One match → edit that entry, OTP pre-filled. Multiple matches → popup entry picker; row click sends `proposeSaveTotp` with the selected `entryId`.
- If the target entry already has a non-empty `totpSecretBase32`, Save must show a **Replace 2FA?** confirmation before overwriting — no silent overwrite. Cancel leaves the vault unchanged and keeps the form open.
- TOTP banner and password-save banner are independent UI/state — if a TOTP candidate is detected, do not also show the password banner on the same page load cycle. Session-dismiss ("Not now") suppresses only equal-or-weaker-priority candidates until navigation.
- Detection priority (page): 1) `otpauth://totp/...` in an `<a href>`, 2) `otpauth://totp/...` in visible text, 3) same-origin QR image/canvas decode, 4) manual Base32 key near a label like "secret"/"manual"/"setup key"/"authenticator". Cross-origin (CORS-tainted) images must be skipped without throwing.
- No camera access — page DOM and popup paste only. No HOTP — `otpauth://totp/...` only.
- The extension performs format heuristics only; authoritative parsing (`otpauth://` vs raw Base32) happens app-side via `EntryEditSaveLogic.applyOTP` / `TOTPCode.parse`.
- Chrome only in this spec — no Safari parity.
- This plan targets the **current** (pre-piece-A) state of `background.js`/`ExtensionBridgeMessages.swift` — if the companion TOTP-autofill plan (piece A) has already landed when this plan is executed, some anchors below (e.g. `knownTypes`, `ExtensionBridgeRequest`'s case list) will look slightly different; each task's edit steps note this and tell you to adapt the anchor rather than assume piece A is absent.

## File Structure

| Path | Responsibility |
|------|----------------|
| `Packages/ExtensionBridgeKit/Sources/ExtensionBridgeKit/ExtensionBridgeMessages.swift` | Adds `.proposeSaveTotp` request case (reuses existing `.saveProposalAccepted` response) |
| `Packages/ExtensionBridgeKit/Tests/ExtensionBridgeKitTests/ExtensionBridgeMessagesTests.swift` | Encode/decode coverage for `proposeSaveTotp` |
| `MyPass/State/ExtensionBridge/ExtensionBridgeService.swift` | `proposeSaveTotp` handler: pairing gate, optional entry/domain match, `onTotpSaveProposal` callback |
| `MyPass/State/ExtensionBridge/LoopbackServer.swift` | Token extraction — new `.proposeSaveTotp` arm |
| `MyPass/State/NavigationState.swift` | `PendingTotpSaveProposal`, two new `DetailPresentation` cases, presenter methods; also wires `MyPassApp.init()`'s `onTotpSaveProposal` closure |
| `MyPass/ContentView.swift` | Routes the new proposal state to create/edit, builds the draft entry |
| `MyPass/UI/EntryDetail/EntryEditView.swift` | Pre-fills OTP input from a proposal; gates Save behind "Replace 2FA?" |
| `MyPass/UI/EntryDetail/EntryEditSaveLogic.swift` | New pure `requiresReplaceConfirmation` helper |
| `MyPassTests/ExtensionBridgeServiceTests.swift` | `proposeSaveTotp` positive/negative Swift tests |
| `MyPassTests/NavigationStatePendingTotpSaveProposalTests.swift` (new) | `PendingTotpSaveProposal.registrableDomain` tests |
| `MyPassTests/EntryEditSaveLogicTests.swift` | `requiresReplaceConfirmation` tests + an `applyOTP` otpauth-parsing test (existing coverage gap) |
| `ChromeExtension/content.js` | otpauth link/text/manual-key detection, QR decode, TOTP banner, MutationObserver, session dismiss |
| `ChromeExtension/vendor/jsQR.js` (new) | Vendored third-party QR decoder |
| `ChromeExtension/background.js` | `proposeSaveTotp` routing; new `openPopupForTotpPicker` handling; listener extracted into a testable `handleRuntimeMessage` function |
| `ChromeExtension/manifest.json` | Adds `vendor/jsQR.js` to `content_scripts.js`, loaded before `content.js` |
| `ChromeExtension/popup.html` / `popup.js` | "Add 2FA" paste field, multi-match picker, pending-candidate restore from `chrome.storage.session` |
| `ChromeExtension/tests/totpDetection.test.js` (new) | otpauth/Base32/QR detection unit tests |
| `ChromeExtension/tests/totpPicker.test.js` (new) | Paste validation + picker routing unit tests |
| `ChromeExtension/tests/fixtures/otpauth-link.html`, `manual-key.html`, `qr.html`, `totp-qr.png` (new) | Manual e2e fixtures |
| `RUN.md` | Manual e2e checklist bullets (Ukrainian) |
| `scripts/test.sh` | Add the two new JS test files |

---

### Task 1: ExtensionBridgeKit — `proposeSaveTotp` request

**Files:**
- Modify: `Packages/ExtensionBridgeKit/Sources/ExtensionBridgeKit/ExtensionBridgeMessages.swift`
- Test: `Packages/ExtensionBridgeKit/Tests/ExtensionBridgeKitTests/ExtensionBridgeMessagesTests.swift`

**Interfaces:**
- Produces: `ExtensionBridgeRequest.proposeSaveTotp(token: String, url: String, otpauthOrSecret: String, entryId: String?, pairing: String?)`. Reuses the existing `ExtensionBridgeResponse.saveProposalAccepted` case — no new response type.

- [ ] **Step 1: Write failing tests**

Open `Packages/ExtensionBridgeKit/Tests/ExtensionBridgeKitTests/ExtensionBridgeMessagesTests.swift`, confirm its `jsonObject(from:)` helper signature (same one used by `testFillCredentialRoundTripsAndHasExpectedShape` etc. from a prior plan, or by `testProposeSaveLoginRoundTripsAndHasExpectedShape` if that's the existing name — check), then append:

```swift
func testProposeSaveTotpRoundTripsAndHasExpectedShapeWithEntryId() throws {
    let request = ExtensionBridgeRequest.proposeSaveTotp(
        token: "tok", url: "https://example.com", otpauthOrSecret: "otpauth://totp/Example:alice?secret=JBSWY3DP",
        entryId: "entry-1", pairing: "pair-secret"
    )
    let data = try JSONEncoder().encode(request)
    let decoded = try JSONDecoder().decode(ExtensionBridgeRequest.self, from: data)
    XCTAssertEqual(decoded, request)

    let json = try jsonObject(from: data)
    XCTAssertEqual(json["type"] as? String, "proposeSaveTotp")
    XCTAssertEqual(json["url"] as? String, "https://example.com")
    XCTAssertEqual(json["otpauthOrSecret"] as? String, "otpauth://totp/Example:alice?secret=JBSWY3DP")
    XCTAssertEqual(json["entryId"] as? String, "entry-1")
    XCTAssertEqual(json["pairing"] as? String, "pair-secret")
}

func testProposeSaveTotpRoundTripsWithoutEntryIdOrPairing() throws {
    let request = ExtensionBridgeRequest.proposeSaveTotp(
        token: "tok", url: "https://example.com", otpauthOrSecret: "JBSWY3DPEHPK3PXP", entryId: nil, pairing: nil
    )
    let data = try JSONEncoder().encode(request)
    let decoded = try JSONDecoder().decode(ExtensionBridgeRequest.self, from: data)
    XCTAssertEqual(decoded, request)

    let json = try jsonObject(from: data)
    XCTAssertNil(json["entryId"])
    XCTAssertNil(json["pairing"])
}
```

- [ ] **Step 2: Run and confirm failure**

Run: `cd Packages/ExtensionBridgeKit && swift test`
Expected: build fails — `type 'ExtensionBridgeRequest' has no member 'proposeSaveTotp'`.

- [ ] **Step 3: Implement**

In `Packages/ExtensionBridgeKit/Sources/ExtensionBridgeKit/ExtensionBridgeMessages.swift`:

Add the case (insert right after `proposeSaveLogin` in the enum — if piece A already landed and added `getTotp`, insert after `proposeSaveLogin` regardless, its position relative to `getTotp` doesn't matter):

```swift
// Replace:
    case proposeSaveLogin(token: String, url: String, username: String, password: String, pairing: String?)
    case startPairing(token: String, browser: String?)

// With:
    case proposeSaveLogin(token: String, url: String, username: String, password: String, pairing: String?)
    case proposeSaveTotp(token: String, url: String, otpauthOrSecret: String, entryId: String?, pairing: String?)
    case startPairing(token: String, browser: String?)
```

Add the two new `CodingKeys`:

```swift
// Replace:
    private enum CodingKeys: String, CodingKey {
        case type, token, url, id, username, password, pairing, browser, code
    }

// With:
    private enum CodingKeys: String, CodingKey {
        case type, token, url, id, username, password, pairing, browser, code, otpauthOrSecret, entryId
    }
```

Add the decode arm, right after `proposeSaveLogin`'s:

```swift
// Replace:
        case "proposeSaveLogin":
            let url = try container.decode(String.self, forKey: .url)
            let username = try container.decode(String.self, forKey: .username)
            let password = try container.decode(String.self, forKey: .password)
            let pairing = try container.decodeIfPresent(String.self, forKey: .pairing)
            self = .proposeSaveLogin(token: token, url: url, username: username, password: password, pairing: pairing)

// With:
        case "proposeSaveLogin":
            let url = try container.decode(String.self, forKey: .url)
            let username = try container.decode(String.self, forKey: .username)
            let password = try container.decode(String.self, forKey: .password)
            let pairing = try container.decodeIfPresent(String.self, forKey: .pairing)
            self = .proposeSaveLogin(token: token, url: url, username: username, password: password, pairing: pairing)
        case "proposeSaveTotp":
            let url = try container.decode(String.self, forKey: .url)
            let otpauthOrSecret = try container.decode(String.self, forKey: .otpauthOrSecret)
            let entryId = try container.decodeIfPresent(String.self, forKey: .entryId)
            let pairing = try container.decodeIfPresent(String.self, forKey: .pairing)
            self = .proposeSaveTotp(token: token, url: url, otpauthOrSecret: otpauthOrSecret, entryId: entryId, pairing: pairing)
```

Add the encode arm:

```swift
// Replace:
        case .proposeSaveLogin(let token, let url, let username, let password, let pairing):
            try container.encode("proposeSaveLogin", forKey: .type)
            try container.encode(token, forKey: .token)
            try container.encode(url, forKey: .url)
            try container.encode(username, forKey: .username)
            try container.encode(password, forKey: .password)
            try container.encodeIfPresent(pairing, forKey: .pairing)

// With:
        case .proposeSaveLogin(let token, let url, let username, let password, let pairing):
            try container.encode("proposeSaveLogin", forKey: .type)
            try container.encode(token, forKey: .token)
            try container.encode(url, forKey: .url)
            try container.encode(username, forKey: .username)
            try container.encode(password, forKey: .password)
            try container.encodeIfPresent(pairing, forKey: .pairing)
        case .proposeSaveTotp(let token, let url, let otpauthOrSecret, let entryId, let pairing):
            try container.encode("proposeSaveTotp", forKey: .type)
            try container.encode(token, forKey: .token)
            try container.encode(url, forKey: .url)
            try container.encode(otpauthOrSecret, forKey: .otpauthOrSecret)
            try container.encodeIfPresent(entryId, forKey: .entryId)
            try container.encodeIfPresent(pairing, forKey: .pairing)
```

- [ ] **Step 4: Run and confirm pass**

Run: `cd Packages/ExtensionBridgeKit && swift test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/ExtensionBridgeKit/Sources/ExtensionBridgeKit/ExtensionBridgeMessages.swift Packages/ExtensionBridgeKit/Tests/ExtensionBridgeKitTests/ExtensionBridgeMessagesTests.swift
git commit -m "feat(bridge): add proposeSaveTotp request to wire protocol"
```

---

### Task 2: `ExtensionBridgeService` — `proposeSaveTotp` handler

**Files:**
- Modify: `MyPass/State/ExtensionBridge/ExtensionBridgeService.swift`
- Modify: `MyPass/State/ExtensionBridge/LoopbackServer.swift` (`requestToken(from:)` switch)
- Test: `MyPassTests/ExtensionBridgeServiceTests.swift`

**Interfaces:**
- Consumes: `ExtensionBridgeRequest.proposeSaveTotp` from Task 1; `ExtensionEntryMatcher.matchingEntries(in:forURL:)` (unchanged).
- Produces: `var onTotpSaveProposal: ((_ url: String, _ otpauthOrSecret: String, _ entryId: UUID?) -> Void)?` on `ExtensionBridgeService`.

- [ ] **Step 1: Write failing tests**

Append to `MyPassTests/ExtensionBridgeServiceTests.swift`:

```swift
func testProposeSaveTotpWithoutEntryIdInvokesClosureAndReturnsAccepted() {
    var captured: (url: String, otpauthOrSecret: String, entryId: UUID?)?
    service.onTotpSaveProposal = { url, otpauthOrSecret, entryId in
        captured = (url, otpauthOrSecret, entryId)
    }
    let response = service.handle(.proposeSaveTotp(
        token: "t", url: "https://example.com/setup", otpauthOrSecret: "otpauth://totp/Example:alice?secret=JBSWY3DP",
        entryId: nil, pairing: authorizedPairingSecret
    ))
    XCTAssertEqual(response, .saveProposalAccepted)
    XCTAssertEqual(captured?.url, "https://example.com/setup")
    XCTAssertEqual(captured?.otpauthOrSecret, "otpauth://totp/Example:alice?secret=JBSWY3DP")
    XCTAssertNil(captured?.entryId)
}

func testProposeSaveTotpWithMatchingEntryIdInvokesClosureWithResolvedUUID() {
    let id = addFixtureEntry(title: "Example", username: "alice", password: "s3cret", url: "https://example.com")
    var captured: (url: String, otpauthOrSecret: String, entryId: UUID?)?
    service.onTotpSaveProposal = { url, otpauthOrSecret, entryId in
        captured = (url, otpauthOrSecret, entryId)
    }
    let response = service.handle(.proposeSaveTotp(
        token: "t", url: "https://example.com", otpauthOrSecret: "JBSWY3DPEHPK3PXP", entryId: id.uuidString, pairing: authorizedPairingSecret
    ))
    XCTAssertEqual(response, .saveProposalAccepted)
    XCTAssertEqual(captured?.entryId, id)
}

func testProposeSaveTotpReturnsErrorWhenEntryIdDomainMismatch() {
    let id = addFixtureEntry(title: "Example", username: "alice", password: "s3cret", url: "https://example.com")
    var wasInvoked = false
    service.onTotpSaveProposal = { _, _, _ in wasInvoked = true }
    let response = service.handle(.proposeSaveTotp(
        token: "t", url: "https://not-example.com", otpauthOrSecret: "JBSWY3DPEHPK3PXP", entryId: id.uuidString, pairing: authorizedPairingSecret
    ))
    XCTAssertEqual(response, .error("entry not found or domain mismatch"))
    XCTAssertFalse(wasInvoked)
}

func testProposeSaveTotpReturnsPairingRequiredWithoutSecret() {
    let (service, _, _) = makeServiceWithPairing()
    let response = service.handle(.proposeSaveTotp(
        token: "t", url: "https://example.com/setup", otpauthOrSecret: "JBSWY3DPEHPK3PXP", entryId: nil, pairing: nil
    ))
    XCTAssertEqual(response, .pairingRequired)
}

func testProposeSaveTotpReturnsLockedAndDoesNotInvokeClosureWhenVaultIsLocked() {
    session.lock()
    var wasInvoked = false
    service.onTotpSaveProposal = { _, _, _ in wasInvoked = true }
    let response = service.handle(.proposeSaveTotp(
        token: "t", url: "https://example.com/setup", otpauthOrSecret: "JBSWY3DPEHPK3PXP", entryId: nil, pairing: authorizedPairingSecret
    ))
    XCTAssertEqual(response, .locked)
    XCTAssertFalse(wasInvoked)
}
```

- [ ] **Step 2: Run and confirm failure**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS'`
Expected: build fails — no `.proposeSaveTotp` case, no `onTotpSaveProposal` member.

- [ ] **Step 3: Fix `LoopbackServer`'s token-extraction switch**

In `MyPass/State/ExtensionBridge/LoopbackServer.swift`:

```swift
// Replace:
        case .proposeSaveLogin(let token, _, _, _, _): return token

// With:
        case .proposeSaveLogin(let token, _, _, _, _): return token
        case .proposeSaveTotp(let token, _, _, _, _): return token
```

(If piece A already landed, this switch will already have a `.getTotp` arm too — leave it untouched, just add the `.proposeSaveTotp` arm alongside it.)

- [ ] **Step 4: Implement `ExtensionBridgeService`**

Add the callback property, right after `onSaveProposal`:

```swift
// Replace:
    var onSaveProposal: ((_ url: String, _ username: String, _ password: String) -> Void)?
    var onCredentialFilled: ((UUID) -> Void)?

// With:
    var onSaveProposal: ((_ url: String, _ username: String, _ password: String) -> Void)?
    var onTotpSaveProposal: ((_ url: String, _ otpauthOrSecret: String, _ entryId: UUID?) -> Void)?
    var onCredentialFilled: ((UUID) -> Void)?
```

Add the new case, right after `proposeSaveLogin`'s:

```swift
// Replace:
        case .proposeSaveLogin(_, let url, let username, let password, let pairing):
            guard pairingManager.isAuthorized(pairing: pairing) else {
                return .pairingRequired
            }
            onSaveProposal?(url, username, password)
            return .saveProposalAccepted
        }

// With:
        case .proposeSaveLogin(_, let url, let username, let password, let pairing):
            guard pairingManager.isAuthorized(pairing: pairing) else {
                return .pairingRequired
            }
            onSaveProposal?(url, username, password)
            return .saveProposalAccepted

        case .proposeSaveTotp(_, let url, let otpauthOrSecret, let entryId, let pairing):
            guard pairingManager.isAuthorized(pairing: pairing) else {
                return .pairingRequired
            }
            var resolvedEntryID: UUID?
            if let entryId {
                guard let database = vaultSession?.currentDatabase else {
                    return .locked
                }
                let matches = ExtensionEntryMatcher.matchingEntries(in: database.rootGroup, forURL: url)
                guard let entry = matches.first(where: { $0.uuid.uuidString == entryId }) else {
                    return .error("entry not found or domain mismatch")
                }
                resolvedEntryID = entry.uuid
            }
            onTotpSaveProposal?(url, otpauthOrSecret, resolvedEntryID)
            return .saveProposalAccepted
        }
```

(When `entryId` is `nil` — the zero-matches/create path — no database lookup happens at all, matching the spec's "no vault write, no domain check needed" create flow.)

- [ ] **Step 5: Run and confirm pass**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS'`
Expected: PASS. Also run `cd Packages/ExtensionBridgeKit && swift test` to confirm no regression.

- [ ] **Step 6: Commit**

```bash
git add MyPass/State/ExtensionBridge/ExtensionBridgeService.swift MyPass/State/ExtensionBridge/LoopbackServer.swift MyPassTests/ExtensionBridgeServiceTests.swift
git commit -m "feat(bridge): handle proposeSaveTotp with optional entry/domain validation"
```

---

### Task 3: `NavigationState` — `PendingTotpSaveProposal`, routing, and app wiring

**Files:**
- Modify: `MyPass/State/NavigationState.swift`
- Modify: `MyPass/MyPassApp.swift`
- Test: `MyPassTests/NavigationStatePendingTotpSaveProposalTests.swift` (new)

**Interfaces:**
- Consumes: `ExtensionBridgeService.onTotpSaveProposal` from Task 2.
- Produces: `PendingTotpSaveProposal(url:otpauthOrSecret:entryId:)`, `.createFromTotpProposal(PendingTotpSaveProposal)` / `.editFromTotpProposal(entryID:otpauthInput:)` on `DetailPresentation`, `NavigationState.pendingTotpSaveProposal`, `presentCreateFromTotpProposal(_:)`, `presentEditFromTotpProposal(entryID:otpauthInput:)`.

- [ ] **Step 1: Write a failing test**

Create `MyPassTests/NavigationStatePendingTotpSaveProposalTests.swift`:

```swift
import XCTest
@testable import MyPass

final class NavigationStatePendingTotpSaveProposalTests: XCTestCase {
    func testRegistrableDomainParsesHostFromURL() {
        let proposal = PendingTotpSaveProposal(url: "https://accounts.example.com/2fa/setup", otpauthOrSecret: "JBSWY3DP", entryId: nil)
        XCTAssertEqual(proposal.registrableDomain, "example.com")
    }

    func testRegistrableDomainFallsBackToRawURLWhenUnparsable() {
        let proposal = PendingTotpSaveProposal(url: "not-a-url", otpauthOrSecret: "JBSWY3DP", entryId: nil)
        XCTAssertEqual(proposal.registrableDomain, "not-a-url")
    }
}
```

(Check `MyPassTests/NavigationStatePendingSaveProposalTests.swift` first — it tests the same `registrableDomain` pattern on `PendingSaveProposal` — and confirm the expected host-parsing result for `"https://accounts.example.com/2fa/setup"` matches whatever `ExtensionEntryMatcher.registrableDomain` actually returns for a subdomain input; adjust the expected string in the test above if it differs from `"example.com"`.)

- [ ] **Step 2: Run and confirm failure**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS'`
Expected: build fails — no `PendingTotpSaveProposal` type.

- [ ] **Step 3: Implement in `NavigationState.swift`**

Add the new type and `DetailPresentation` cases, right after `PendingSaveProposal`'s `==` extension:

```swift
// Replace:
extension PendingSaveProposal {
    static func == (lhs: PendingSaveProposal, rhs: PendingSaveProposal) -> Bool {
        lhs.url == rhs.url && lhs.username == rhs.username && lhs.password == rhs.password
    }
}

enum DetailPresentation: Equatable, Hashable {
    case browse
    case edit(entryID: UUID)
    case create(defaultGroupID: UUID?, entryType: EntryType = .login)
    case createFromProposal(PendingSaveProposal)
}

// With:
extension PendingSaveProposal {
    static func == (lhs: PendingSaveProposal, rhs: PendingSaveProposal) -> Bool {
        lhs.url == rhs.url && lhs.username == rhs.username && lhs.password == rhs.password
    }
}

/// A 2FA-setup proposal relayed from `ExtensionBridgeService.onTotpSaveProposal`,
/// mirroring `PendingSaveProposal` — waits to be shown as a pre-filled create or
/// edit sheet by `ContentView`. `entryId` selects edit (one/N-picker-resolved
/// domain match) vs. create (zero matches).
struct PendingTotpSaveProposal: Identifiable, Equatable, Hashable {
    let id = UUID()
    let url: String
    let otpauthOrSecret: String
    let entryId: UUID?

    var registrableDomain: String {
        ExtensionEntryMatcher.registrableDomain(from: url) ?? url
    }
}

extension PendingTotpSaveProposal {
    static func == (lhs: PendingTotpSaveProposal, rhs: PendingTotpSaveProposal) -> Bool {
        lhs.url == rhs.url && lhs.otpauthOrSecret == rhs.otpauthOrSecret && lhs.entryId == rhs.entryId
    }
}

enum DetailPresentation: Equatable, Hashable {
    case browse
    case edit(entryID: UUID)
    case create(defaultGroupID: UUID?, entryType: EntryType = .login)
    case createFromProposal(PendingSaveProposal)
    case createFromTotpProposal(PendingTotpSaveProposal)
    case editFromTotpProposal(entryID: UUID, otpauthInput: String)
}
```

Add the `@Published` property and presenter methods:

```swift
// Replace:
    @Published var pendingSaveProposal: PendingSaveProposal?
    @Published var pendingPairingCode: String?

// With:
    @Published var pendingSaveProposal: PendingSaveProposal?
    @Published var pendingTotpSaveProposal: PendingTotpSaveProposal?
    @Published var pendingPairingCode: String?
```

```swift
// Replace:
    func presentCreateFromProposal(_ proposal: PendingSaveProposal) {
        detailPresentation = .createFromProposal(proposal)
    }
}

// With:
    func presentCreateFromProposal(_ proposal: PendingSaveProposal) {
        detailPresentation = .createFromProposal(proposal)
    }

    func presentCreateFromTotpProposal(_ proposal: PendingTotpSaveProposal) {
        detailPresentation = .createFromTotpProposal(proposal)
    }

    func presentEditFromTotpProposal(entryID: UUID, otpauthInput: String) {
        detailPresentation = .editFromTotpProposal(entryID: entryID, otpauthInput: otpauthInput)
    }
}
```

- [ ] **Step 4: Wire `MyPassApp.init()`**

In `MyPass/MyPassApp.swift`, right after the existing `onSaveProposal` block:

```swift
// Replace:
        extensionBridgeService.onSaveProposal = { [weak navigationState] url, username, password in
            DispatchQueue.main.async {
                navigationState?.pendingSaveProposal = PendingSaveProposal(url: url, username: username, password: password)
                MainWindowActivator.request()
            }
        }

// With:
        extensionBridgeService.onSaveProposal = { [weak navigationState] url, username, password in
            DispatchQueue.main.async {
                navigationState?.pendingSaveProposal = PendingSaveProposal(url: url, username: username, password: password)
                MainWindowActivator.request()
            }
        }
        extensionBridgeService.onTotpSaveProposal = { [weak navigationState] url, otpauthOrSecret, entryId in
            DispatchQueue.main.async {
                navigationState?.pendingTotpSaveProposal = PendingTotpSaveProposal(url: url, otpauthOrSecret: otpauthOrSecret, entryId: entryId)
                MainWindowActivator.request()
            }
        }
```

(No dedicated automated test covers `MyPassApp.init()` wiring — none exists for the equivalent `onSaveProposal` block either. Manual verification happens in Task 11's e2e checklist.)

- [ ] **Step 5: Run and confirm pass**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS'`
Expected: PASS, including the two new `NavigationStatePendingTotpSaveProposalTests` cases.

- [ ] **Step 6: Commit**

```bash
git add MyPass/State/NavigationState.swift MyPass/MyPassApp.swift MyPassTests/NavigationStatePendingTotpSaveProposalTests.swift
git commit -m "feat(app): add PendingTotpSaveProposal routing and app wiring"
```

---

### Task 4: `ContentView.swift` — route TOTP proposals to create/edit

**Files:**
- Modify: `MyPass/ContentView.swift`

**Interfaces:**
- Consumes: `NavigationState.pendingTotpSaveProposal`, `.createFromTotpProposal`/`.editFromTotpProposal` from Task 3.
- Produces: `entryEdit(...)` gains two new optional parameters (`totpProposal: PendingTotpSaveProposal? = nil`, `prefilledOtpauthInput: String? = nil`) threaded through to `EntryEditView`'s init (Task 5).

- [ ] **Step 1: Read the file in full**

Read `MyPass/ContentView.swift` completely, specifically the `.onChange(of: navigationState.pendingSaveProposal)` block, the `DetailColumnView.body` switch over `navigationState.detailPresentation`, the `entryEdit(...)` helper's full signature and body, and `resolvedEntry(existingID:proposal:)` / `draftEntry(from:)`. You need their exact current text before applying the edits below, since only fragments are quoted here.

- [ ] **Step 2: Add the `onChange` handler**

Right after the existing `.onChange(of: navigationState.pendingSaveProposal) { _, proposal in ... }` block, add a parallel one:

```swift
.onChange(of: navigationState.pendingTotpSaveProposal) { _, proposal in
    if let proposal {
        if let entryId = proposal.entryId {
            navigationState.presentEditFromTotpProposal(entryID: entryId, otpauthInput: proposal.otpauthOrSecret)
        } else {
            navigationState.presentCreateFromTotpProposal(proposal)
        }
        navigationState.pendingTotpSaveProposal = nil
    }
}
```

- [ ] **Step 3: Add the two new `DetailPresentation` switch cases**

In `DetailColumnView.body`'s switch, right after the existing `case .createFromProposal(let proposal): entryEdit(existingID: nil, proposal: proposal)` case:

```swift
case .createFromTotpProposal(let proposal):
    entryEdit(existingID: nil, totpProposal: proposal)
case .editFromTotpProposal(let entryID, let otpauthInput):
    entryEdit(existingID: entryID, prefilledOtpauthInput: otpauthInput)
```

- [ ] **Step 4: Extend `entryEdit(...)`'s signature and `resolvedEntry`/`draftEntry`**

Add two new parameters to `entryEdit(...)`'s signature — `totpProposal: PendingTotpSaveProposal? = nil` and `prefilledOtpauthInput: String? = nil` — following the existing `proposal: PendingSaveProposal? = nil` parameter's exact style (default `nil`, same position/convention). Thread `prefilledOtpauthInput` through to wherever `entryEdit` constructs `EntryEditView(...)` — Task 5 adds a matching `prefilledOtpauthInput` init parameter there.

Extend `resolvedEntry` to also accept `totpProposal` and build a draft entry from it:

```swift
// Replace:
    private func resolvedEntry(existingID: UUID?, proposal: PendingSaveProposal?) -> KdbxEntry? {
        if let proposal {
            return draftEntry(from: proposal)
        }
        guard let existingID, let database = vaultSession.currentDatabase else { return nil }
        return EntrySearch.allEntries(in: database.rootGroup).first { $0.uuid == existingID }
    }

    private func draftEntry(from proposal: PendingSaveProposal) -> KdbxEntry {
        let now = Date()
        var entry = KdbxEntry(
            uuid: UUID(), iconID: 0, fields: [],
            creationTime: now, lastModificationTime: now, lastAccessTime: now, locationChanged: now,
            history: []
        )
        entry.title = proposal.registrableDomain
        entry.login = proposal.username
        entry.password = proposal.password
        entry.url = proposal.url
        return entry
    }

// With:
    private func resolvedEntry(existingID: UUID?, proposal: PendingSaveProposal?, totpProposal: PendingTotpSaveProposal? = nil) -> KdbxEntry? {
        if let proposal {
            return draftEntry(from: proposal)
        }
        if let totpProposal {
            return draftEntry(from: totpProposal)
        }
        guard let existingID, let database = vaultSession.currentDatabase else { return nil }
        return EntrySearch.allEntries(in: database.rootGroup).first { $0.uuid == existingID }
    }

    private func draftEntry(from proposal: PendingSaveProposal) -> KdbxEntry {
        let now = Date()
        var entry = KdbxEntry(
            uuid: UUID(), iconID: 0, fields: [],
            creationTime: now, lastModificationTime: now, lastAccessTime: now, locationChanged: now,
            history: []
        )
        entry.title = proposal.registrableDomain
        entry.login = proposal.username
        entry.password = proposal.password
        entry.url = proposal.url
        return entry
    }

    private func draftEntry(from totpProposal: PendingTotpSaveProposal) -> KdbxEntry {
        let now = Date()
        var entry = KdbxEntry(
            uuid: UUID(), iconID: 0, fields: [],
            creationTime: now, lastModificationTime: now, lastAccessTime: now, locationChanged: now,
            history: []
        )
        entry.title = totpProposal.registrableDomain
        entry.url = totpProposal.url
        return entry
    }
```

(`draftEntry(from: totpProposal)` deliberately does **not** set `totpSecretBase32` — the OTP value only reaches the draft entry when the user taps Save inside `EntryEditView`, via `EntryEditSaveLogic.applyOTP`, matching acceptance criterion 3's "no vault write until user Save".)

Update every call site of `resolvedEntry(existingID:proposal:)` that builds the entry passed into `EntryEditView`/`CardEditView`/`NotesEditView` to also pass `totpProposal:` through from `entryEdit`'s new parameter.

- [ ] **Step 5: Manual verification**

There's no existing automated test target for `ContentView.swift`. Build the app (`xcodebuild build -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS'`) to confirm it compiles; full behavioral verification happens in Task 11's manual e2e checklist and Task 5's `EntryEditView` changes (which do have unit test coverage for the logic `ContentView` delegates to).

- [ ] **Step 6: Commit**

```bash
git add MyPass/ContentView.swift
git commit -m "feat(app): route TOTP save proposals to create or edit"
```

---

### Task 5: `EntryEditView.swift` — OTP pre-fill and "Replace 2FA?" confirmation

**Files:**
- Modify: `MyPass/UI/EntryDetail/EntryEditView.swift`
- Modify: `MyPass/UI/EntryDetail/EntryEditSaveLogic.swift`
- Test: `MyPassTests/EntryEditSaveLogicTests.swift`

**Interfaces:**
- Consumes: `prefilledOtpauthInput: String?` threaded from Task 4's `entryEdit(...)`.
- Produces: `EntryEditSaveLogic.requiresReplaceConfirmation(existingEntry: KdbxEntry?, isFromTotpProposal: Bool) -> Bool`; `EntryEditView` gains a `prefilledOtpauthInput: String? = nil` init parameter.

- [ ] **Step 1: Write failing tests**

Append to `MyPassTests/EntryEditSaveLogicTests.swift`:

```swift
func testRequiresReplaceConfirmationWhenEntryHasExistingSecretAndFromProposal() {
    var entry = KdbxEntry(
        uuid: UUID(), iconID: 0, fields: [],
        creationTime: Date(), lastModificationTime: Date(), lastAccessTime: Date(), locationChanged: Date(),
        history: []
    )
    entry.totpSecretBase32 = "JBSWY3DP"
    XCTAssertTrue(EntryEditSaveLogic.requiresReplaceConfirmation(existingEntry: entry, isFromTotpProposal: true))
}

func testRequiresReplaceConfirmationFalseWhenNotFromProposal() {
    var entry = KdbxEntry(
        uuid: UUID(), iconID: 0, fields: [],
        creationTime: Date(), lastModificationTime: Date(), lastAccessTime: Date(), locationChanged: Date(),
        history: []
    )
    entry.totpSecretBase32 = "JBSWY3DP"
    XCTAssertFalse(EntryEditSaveLogic.requiresReplaceConfirmation(existingEntry: entry, isFromTotpProposal: false))
}

func testRequiresReplaceConfirmationFalseWhenNoExistingSecret() {
    let entry = KdbxEntry(
        uuid: UUID(), iconID: 0, fields: [],
        creationTime: Date(), lastModificationTime: Date(), lastAccessTime: Date(), locationChanged: Date(),
        history: []
    )
    XCTAssertFalse(EntryEditSaveLogic.requiresReplaceConfirmation(existingEntry: entry, isFromTotpProposal: true))
}

func testRequiresReplaceConfirmationFalseWhenCreatingNewEntry() {
    XCTAssertFalse(EntryEditSaveLogic.requiresReplaceConfirmation(existingEntry: nil, isFromTotpProposal: true))
}

func testApplyOTPParsesOtpauthURL() {
    var entry = KdbxEntry(
        uuid: UUID(), iconID: 0, fields: [],
        creationTime: Date(), lastModificationTime: Date(), lastAccessTime: Date(), locationChanged: Date(),
        history: []
    )
    EntryEditSaveLogic.applyOTP(to: &entry, otpauthInput: "otpauth://totp/Example:alice?secret=JBSWY3DPEHPK3PXP&issuer=Example")
    XCTAssertEqual(entry.totpSecretBase32, "JBSWY3DPEHPK3PXP")
}
```

- [ ] **Step 2: Run and confirm failure**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS'`
Expected: build fails — no `requiresReplaceConfirmation` member. (The `testApplyOTPParsesOtpauthURL` test compiles fine since `applyOTP` already exists — it may already pass; that's fine, it's closing a pre-existing coverage gap, not testing new behavior.)

- [ ] **Step 3: Implement `requiresReplaceConfirmation` in `EntryEditSaveLogic.swift`**

```swift
// Replace:
enum EntryEditSaveLogic {
    static func resolvedTitle(draftTitle: String, url: String) -> String {

// With:
enum EntryEditSaveLogic {
    static func requiresReplaceConfirmation(existingEntry: KdbxEntry?, isFromTotpProposal: Bool) -> Bool {
        isFromTotpProposal && existingEntry?.totpSecretBase32?.isEmpty == false
    }

    static func resolvedTitle(draftTitle: String, url: String) -> String {
```

- [ ] **Step 4: Read `EntryEditView.swift` in full**

Read `MyPass/UI/EntryDetail/EntryEditView.swift` completely — its exact custom `init(...)` signature and body (it already has one, since `_showOTPField = State(initialValue: ...)` appears there), the full `save()` function body, and wherever the Save button's action closure currently calls `save()`, and the view's `body` structure (to find a good place for a new `.alert(...)` modifier — mirror `ContentView.swift`'s `.alert("Save Error", isPresented: ..., actions: {}, message: { ... })` syntax shape as your SwiftUI-alert-syntax reference, since this exact pattern doesn't exist yet in `EntryEditView.swift`).

- [ ] **Step 5: Implement the pre-fill and Replace-2FA gate**

Add a `prefilledOtpauthInput: String? = nil` parameter to `EntryEditView`'s init, and two new `@State` properties:

```swift
@State private var isReplacingTotp: Bool
@State private var showReplaceTotpAlert = false
```

In the init body, alongside the existing `_showOTPField = State(initialValue: existingEntry?.totpSecretBase32?.isEmpty == false)` line:

```swift
// Replace:
        _showOTPField = State(initialValue: existingEntry?.totpSecretBase32?.isEmpty == false)

// With:
        _showOTPField = State(initialValue: existingEntry?.totpSecretBase32?.isEmpty == false || prefilledOtpauthInput != nil)
        _otpauthInput = State(initialValue: prefilledOtpauthInput ?? "")
        _isReplacingTotp = State(initialValue: EntryEditSaveLogic.requiresReplaceConfirmation(
            existingEntry: existingEntry, isFromTotpProposal: prefilledOtpauthInput != nil
        ))
```

Rename the existing `save()` function to `performSave()` (its body is unchanged), and add a new gating `save()`:

```swift
private func save() {
    if isReplacingTotp {
        showReplaceTotpAlert = true
        return
    }
    performSave()
}
```

The Save button's existing action closure keeps calling `save()` unchanged — it now gates through the alert automatically.

Add the alert modifier to the view's `body` (anywhere alongside other modifiers, e.g. near where `showPasswordGenerator`/`showWebsitesSheet` sheets are declared):

```swift
.alert(
    "Replace 2FA?",
    isPresented: $showReplaceTotpAlert,
    actions: {
        Button("Cancel", role: .cancel) {}
        Button("Replace", role: .destructive) {
            isReplacingTotp = false
            performSave()
        }
    },
    message: {
        Text("This entry already has an authenticator set up. Saving will replace it with the new one.")
    }
)
```

(Cancel just dismisses the alert with no side effect — the form stays open with the new OTP value still in `otpauthInput`, matching the spec's "Cancel (stay in edit, clear only the pending overwrite intent — keep form open with new OTP still in field)".)

- [ ] **Step 6: Run and confirm pass**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS'`
Expected: PASS, including all new `EntryEditSaveLogicTests` cases.

- [ ] **Step 7: Commit**

```bash
git add MyPass/UI/EntryDetail/EntryEditView.swift MyPass/UI/EntryDetail/EntryEditSaveLogic.swift MyPassTests/EntryEditSaveLogicTests.swift
git commit -m "feat(app): pre-fill OTP from TOTP proposals and gate replace with confirmation"
```

---

### Task 6: `content.js` — otpauth/manual-key detection and TOTP banner (no QR yet)

**Files:**
- Modify: `ChromeExtension/content.js`
- Test: `ChromeExtension/tests/totpDetection.test.js` (new)
- Modify: `scripts/test.sh`

**Interfaces:**
- Produces: `detectOtpauthLink(root)`, `detectOtpauthText(root)`, `isBase32Secret(candidate)`, `detectManualSetupKey(root)`, `detectTotpCandidateWithPriority(root)`, `shouldShowTotpBanner(detected, state)` — all exported. `showTotpSaveBanner(url, otpauthOrSecret, state)` wired to run detection at content-script load and via a debounced `MutationObserver`.

- [ ] **Step 1: Write failing tests**

Create `ChromeExtension/tests/totpDetection.test.js`:

```js
const assert = require('node:assert');
const {
  detectOtpauthLink, detectOtpauthText, isBase32Secret, detectManualSetupKey,
  detectTotpCandidateWithPriority, shouldShowTotpBanner,
} = require('../content.js');

function fakeAnchor(href) {
  return { getAttribute: (name) => (name === 'href' ? href : null) };
}

function fakeDoc({ links = [], bodyText = '' }) {
  return {
    querySelectorAll: (selector) => (selector === 'a[href]' ? links : []),
    body: { textContent: bodyText },
  };
}

// detectOtpauthLink
const linkDoc = fakeDoc({ links: [fakeAnchor('https://example.com'), fakeAnchor('otpauth://totp/Example:alice?secret=JBSWY3DP')] });
assert.strictEqual(detectOtpauthLink(linkDoc), 'otpauth://totp/Example:alice?secret=JBSWY3DP');
assert.strictEqual(detectOtpauthLink(fakeDoc({ links: [fakeAnchor('https://example.com')] })), null);

// detectOtpauthText
const textDoc = fakeDoc({ bodyText: 'Scan this: otpauth://totp/Example:bob?secret=ABCDEFGH please' });
assert.strictEqual(detectOtpauthText(textDoc), 'otpauth://totp/Example:bob?secret=ABCDEFGH');
assert.strictEqual(detectOtpauthText(fakeDoc({ bodyText: 'no link here' })), null);

// isBase32Secret
assert.strictEqual(isBase32Secret('JBSWY3DPEHPK3PXP'), true);
assert.strictEqual(isBase32Secret('jbswy3dp ehpk3pxp'), true, 'lowercase and spaces normalize');
assert.strictEqual(isBase32Secret('short'), false);
assert.strictEqual(isBase32Secret('has1and9digits'), false);

// detectManualSetupKey
const manualDoc = fakeDoc({ bodyText: 'Your manual setup key is JBSW Y3DP EHPK 3PXP — enter it in your app' });
assert.strictEqual(detectManualSetupKey(manualDoc), 'JBSWY3DPEHPK3PXP');
assert.strictEqual(detectManualSetupKey(fakeDoc({ bodyText: 'JBSWY3DPEHPK3PXP with no label nearby' })), null, 'requires a label keyword present');

// priority ordering
const combinedDoc = fakeDoc({
  links: [fakeAnchor('otpauth://totp/Example:alice?secret=JBSWY3DP')],
  bodyText: 'manual setup key JBSWY3DPEHPK3PXP',
});
assert.strictEqual(detectTotpCandidateWithPriority(combinedDoc).priority, 1, 'otpauth link wins over manual key');

// shouldShowTotpBanner
assert.strictEqual(shouldShowTotpBanner(null, {}), false);
assert.strictEqual(shouldShowTotpBanner({ candidate: 'x', priority: 1 }, { vaultLocked: true }), false);
assert.strictEqual(shouldShowTotpBanner({ candidate: 'x', priority: 1 }, { vaultLocked: false, totpBannerDismissed: null }), true);
assert.strictEqual(shouldShowTotpBanner({ candidate: 'x', priority: 4 }, { vaultLocked: false, totpBannerDismissed: { priority: 1 } }), false, 'weaker candidate stays suppressed');
assert.strictEqual(shouldShowTotpBanner({ candidate: 'x', priority: 1 }, { vaultLocked: false, totpBannerDismissed: { priority: 4 } }), true, 'stronger candidate re-shows');

console.log('totpDetection.test.js: OK');
```

- [ ] **Step 2: Run and confirm failure**

Run: `node ChromeExtension/tests/totpDetection.test.js`
Expected: `TypeError` — none of these functions exist/are exported yet.

- [ ] **Step 3: Implement detection + banner in `content.js`**

Add these near the file's other top-level helpers, before the CommonJS export block:

```js
const OTPAUTH_REGEX = /otpauth:\/\/totp\/[^\s"'<>]+/i;
const BASE32_REGEX = /^[A-Z2-7]{16,128}$/;
const MANUAL_KEY_LABEL_REGEX = /secret|manual|setup key|authenticator/i;

function detectOtpauthLink(root) {
  const scope = root || document;
  const links = Array.from(scope.querySelectorAll('a[href]'));
  for (const link of links) {
    const href = link.getAttribute('href') || '';
    const match = href.match(OTPAUTH_REGEX);
    if (match) return match[0];
  }
  return null;
}

function detectOtpauthText(root) {
  const scope = root || document;
  const body = scope.body || scope;
  if (!body) return null;
  const text = body.textContent || '';
  const match = text.match(OTPAUTH_REGEX);
  return match ? match[0] : null;
}

function normalizeBase32Candidate(raw) {
  return (raw || '').replace(/\s+/g, '').toUpperCase();
}

function isBase32Secret(candidate) {
  return BASE32_REGEX.test(normalizeBase32Candidate(candidate));
}

function detectManualSetupKey(root) {
  const scope = root || document;
  const body = scope.body || scope;
  if (!body) return null;
  const text = (body.textContent || '').replace(/\s+/g, ' ');
  if (!MANUAL_KEY_LABEL_REGEX.test(text)) return null;
  const tokens = text.split(' ').filter(Boolean);
  for (let i = 0; i < tokens.length; i += 1) {
    for (let span = 1; span <= 8 && i + span <= tokens.length; span += 1) {
      const candidate = tokens.slice(i, i + span).join('');
      if (isBase32Secret(candidate)) {
        return normalizeBase32Candidate(candidate);
      }
    }
  }
  return null;
}

function detectTotpCandidateWithPriority(root) {
  const link = detectOtpauthLink(root);
  if (link) return { candidate: link, priority: 1 };
  const text = detectOtpauthText(root);
  if (text) return { candidate: text, priority: 2 };
  const manual = detectManualSetupKey(root);
  if (manual) return { candidate: manual, priority: 4 };
  return null;
}

function shouldShowTotpBanner(detected, state) {
  if (!detected) return false;
  if (state.vaultLocked) return false;
  if (!state.totpBannerDismissed) return true;
  return detected.priority < state.totpBannerDismissed.priority;
}

function showTotpSaveBanner(url, otpauthOrSecret, state) {
  if (state.totpBannerShown) return;
  state.totpBannerShown = true;

  const banner = document.createElement('div');
  banner.style.cssText =
    'position:fixed;bottom:16px;right:16px;z-index:2147483647;background:#134e4a;' +
    'color:#f0fdfa;padding:12px 16px;border-radius:8px;font-family:sans-serif;' +
    'font-size:13px;box-shadow:0 2px 8px rgba(0,0,0,0.3);display:flex;align-items:center;gap:8px;';
  banner.textContent = 'Save 2FA to MyPass?';

  const saveButton = document.createElement('button');
  saveButton.textContent = 'Save';
  saveButton.style.cssText = 'margin-left:8px;cursor:pointer;';
  saveButton.addEventListener('click', () => {
    chrome.runtime.sendMessage({ type: 'getCredentials', url }, (response) => {
      const credentials = (response && response.type === 'credentialList') ? response.credentials : [];
      if (credentials.length === 0) {
        chrome.runtime.sendMessage({ type: 'proposeSaveTotp', url, otpauthOrSecret });
      } else if (credentials.length === 1) {
        chrome.runtime.sendMessage({ type: 'proposeSaveTotp', url, otpauthOrSecret, entryId: credentials[0].id });
      } else {
        chrome.storage.session.set({ pendingTotpCandidate: { url, otpauthOrSecret } }, () => {
          chrome.runtime.sendMessage({ type: 'openPopupForTotpPicker' });
        });
      }
    });
    banner.remove();
    state.totpBannerShown = false;
  });

  const closeButton = document.createElement('button');
  closeButton.textContent = '×';
  closeButton.style.cssText = 'margin-left:8px;cursor:pointer;background:none;border:none;color:inherit;';
  closeButton.addEventListener('click', () => {
    banner.remove();
    state.totpBannerShown = false;
    state.totpBannerDismissed = { priority: 4 };
  });

  banner.appendChild(saveButton);
  banner.appendChild(closeButton);
  document.body.appendChild(banner);
}

function observeTotpCandidates(state) {
  let debounceTimer = null;
  const observer = new MutationObserver(() => {
    if (debounceTimer) clearTimeout(debounceTimer);
    debounceTimer = setTimeout(() => {
      const detected = detectTotpCandidateWithPriority(document);
      if (shouldShowTotpBanner(detected, state)) {
        showTotpSaveBanner(location.href, detected.candidate, state);
      }
    }, 400);
  });
  observer.observe(document.body, { childList: true, subtree: true });
  return observer;
}
```

(`closeButton`'s dismiss stores `{ priority: 4 }` — the weakest priority — so `shouldShowTotpBanner` only re-shows for a candidate strictly stronger than whatever was dismissed, per the spec's "do not re-show until navigation or new candidate strictly stronger than dismissed one".)

Find the `state` object literal declaration (used throughout this file, e.g. passed into `showSaveBanner`/`attachSubmitListener` — currently `{ lastCredentialList: [], bannerShown: false, vaultLocked: false }`) and add two fields:

```js
// Replace:
{ lastCredentialList: [], bannerShown: false, vaultLocked: false }

// With:
{ lastCredentialList: [], bannerShown: false, vaultLocked: false, totpBannerShown: false, totpBannerDismissed: null }
```

Make the password banner and TOTP banner mutually exclusive on the same submit:

```js
// Replace:
      loginForm.form.addEventListener('submit', () => {
        if (!state.vaultLocked && state.lastCredentialList.length === 0) {

// With:
      loginForm.form.addEventListener('submit', () => {
        if (!state.vaultLocked && !state.totpBannerShown && state.lastCredentialList.length === 0) {
```

Inside the file's existing browser-only wiring guard (`if (typeof chrome !== 'undefined' && typeof document !== 'undefined') { ... }`), after the `state` object is constructed, run initial detection and start observing:

```js
const detected = detectTotpCandidateWithPriority(document);
if (shouldShowTotpBanner(detected, state)) {
  showTotpSaveBanner(location.href, detected.candidate, state);
}
observeTotpCandidates(state);
```

Update the export block to add the new functions:

```js
// Replace:
  if (typeof module !== 'undefined') {
    module.exports = { scoreUsernameLikeness, findBestUsernameInput, hostnameMatches };
  }

// With:
  if (typeof module !== 'undefined') {
    module.exports = {
      scoreUsernameLikeness, findBestUsernameInput, hostnameMatches,
      detectOtpauthLink, detectOtpauthText, isBase32Secret, detectManualSetupKey,
      detectTotpCandidateWithPriority, shouldShowTotpBanner,
    };
  }
```

(If a prior piece-A implementation already changed this export block to include `scoreOtpLikeness`/`findOtpField`, merge into that existing object instead of replacing it — keep every existing export, just add the new ones.)

- [ ] **Step 4: Wire the new test into `scripts/test.sh`**

```bash
# Replace:
  node ChromeExtension/tests/pairing.test.js
else

# With:
  node ChromeExtension/tests/pairing.test.js
  node ChromeExtension/tests/totpDetection.test.js
else
```

(If piece A already added a `totpCircle.test.js` line here, just add `totpDetection.test.js` as an additional line alongside it.)

- [ ] **Step 5: Run and confirm pass**

Run: `node ChromeExtension/tests/totpDetection.test.js`
Expected: PASS. Also run `node ChromeExtension/tests/formDetection.test.js` to confirm no regression.

- [ ] **Step 6: Commit**

```bash
git add ChromeExtension/content.js ChromeExtension/tests/totpDetection.test.js scripts/test.sh
git commit -m "feat(chrome): detect otpauth links, text, and manual keys with a TOTP save banner"
```

---

### Task 7: `content.js` — QR code detection (vendored `jsQR`)

**Files:**
- Create: `ChromeExtension/vendor/jsQR.js`
- Modify: `ChromeExtension/content.js`
- Modify: `ChromeExtension/manifest.json`
- Test: `ChromeExtension/tests/totpDetection.test.js` (extend)

**Interfaces:**
- Consumes: global `jsQR(data, width, height)` function from the vendored file, returning `{ data: string, location: {...} } | null`.
- Produces: `decodeQrFromImage(imgEl)`, `detectQrCandidate(root)` — both exported; `detectTotpCandidateWithPriority` (from Task 6) gains QR as priority 3.

- [ ] **Step 1: Vendor the real jsQR library**

This is a real third-party dependency — do not hand-write a QR decoder. Fetch the official single-file UMD build of `jsQR` (npm package `jsqr`, e.g. version `^1.4.0`) and save it verbatim as `ChromeExtension/vendor/jsQR.js`. For example:

```bash
curl -o ChromeExtension/vendor/jsQR.js https://cdn.jsdelivr.net/npm/jsqr@1.4.0/dist/jsQR.js
```

or `npm pack jsqr@1.4.0` and extract `dist/jsQR.js` from the tarball. Confirm the file defines a global `jsQR` function (check the last few lines for something like `window.jsQR = ...` or a UMD `module.exports`/global-attach pattern) and is not empty. If the execution environment has no network access, stop here and ask the user to supply the vendored file manually — do not fabricate a stand-in decoder.

- [ ] **Step 2: Write failing tests**

Append to `ChromeExtension/tests/totpDetection.test.js` (after the existing content, before nothing needs re-requiring — see note below about `global.document`/`global.jsQR` needing to be set up before `decodeQrFromImage`/`detectQrCandidate` are *called*, not before `content.js` is required, since it's already required at the top of this file from Task 6):

```js
// --- QR detection ---

function fakeCanvasContext(imageDataResult) {
  return { drawImage: () => {}, getImageData: () => imageDataResult };
}

function fakeCanvas(imageDataResult, shouldThrow) {
  return {
    width: 0,
    height: 0,
    getContext: () => {
      if (shouldThrow) throw new Error('SecurityError: tainted canvas');
      return fakeCanvasContext(imageDataResult);
    },
  };
}

global.document = global.document || {};
global.document.createElement = (tag) => (tag === 'canvas' ? fakeCanvas({ data: [], width: 1, height: 1 }, global.__fakeCanvasThrows) : {});
global.jsQR = () => global.__fakeQrResult || null;

const { decodeQrFromImage, detectQrCandidate } = require('../content.js');

global.__fakeQrResult = { data: 'otpauth://totp/Example:alice?secret=JBSWY3DP' };
const decodableImg = { complete: true, naturalWidth: 200, naturalHeight: 200 };
assert.strictEqual(decodeQrFromImage(decodableImg), 'otpauth://totp/Example:alice?secret=JBSWY3DP');

global.__fakeQrResult = null;
assert.strictEqual(decodeQrFromImage(decodableImg), null, 'no QR payload decodes to null');

global.__fakeCanvasThrows = true;
assert.strictEqual(decodeQrFromImage(decodableImg), null, 'CORS-tainted canvas is caught and skipped, not thrown');
global.__fakeCanvasThrows = false;

const incompleteImg = { complete: false, naturalWidth: 0, naturalHeight: 0 };
assert.strictEqual(decodeQrFromImage(incompleteImg), null, 'unloaded image is skipped');

global.__fakeQrResult = { data: 'otpauth://totp/Example:carol?secret=ABCDEFGH' };
const qrDoc = { querySelectorAll: (sel) => (sel === 'img' ? [decodableImg] : []) };
assert.strictEqual(detectQrCandidate(qrDoc), 'otpauth://totp/Example:carol?secret=ABCDEFGH');

console.log('totpDetection.test.js: QR detection OK');
```

- [ ] **Step 3: Run and confirm failure**

Run: `node ChromeExtension/tests/totpDetection.test.js`
Expected: `TypeError` — `decodeQrFromImage`/`detectQrCandidate` not exported yet.

- [ ] **Step 4: Implement QR detection in `content.js`**

Add near the other detection functions:

```js
function decodeQrFromImage(imgEl) {
  try {
    if (!imgEl.complete || !imgEl.naturalWidth) return null;
    const canvas = document.createElement('canvas');
    canvas.width = imgEl.naturalWidth;
    canvas.height = imgEl.naturalHeight;
    const ctx = canvas.getContext('2d');
    ctx.drawImage(imgEl, 0, 0);
    const imageData = ctx.getImageData(0, 0, canvas.width, canvas.height);
    const result = typeof jsQR === 'function' ? jsQR(imageData.data, imageData.width, imageData.height) : null;
    return result ? result.data : null;
  } catch (error) {
    // getImageData throws on a CORS-tainted canvas (cross-origin image) —
    // skip rather than treat as a hard failure.
    return null;
  }
}

function detectQrCandidate(root) {
  const scope = root || document;
  const images = Array.from(scope.querySelectorAll('img'));
  for (const img of images) {
    if ((img.naturalWidth || 0) < 40 || (img.naturalHeight || 0) < 40) continue;
    const decoded = decodeQrFromImage(img);
    if (decoded && OTPAUTH_REGEX.test(decoded)) {
      return decoded.match(OTPAUTH_REGEX)[0];
    }
  }
  return null;
}
```

Insert QR as priority 3 in `detectTotpCandidateWithPriority` (from Task 6):

```js
// Replace:
function detectTotpCandidateWithPriority(root) {
  const link = detectOtpauthLink(root);
  if (link) return { candidate: link, priority: 1 };
  const text = detectOtpauthText(root);
  if (text) return { candidate: text, priority: 2 };
  const manual = detectManualSetupKey(root);
  if (manual) return { candidate: manual, priority: 4 };
  return null;
}

// With:
function detectTotpCandidateWithPriority(root) {
  const link = detectOtpauthLink(root);
  if (link) return { candidate: link, priority: 1 };
  const text = detectOtpauthText(root);
  if (text) return { candidate: text, priority: 2 };
  const qr = detectQrCandidate(root);
  if (qr) return { candidate: qr, priority: 3 };
  const manual = detectManualSetupKey(root);
  if (manual) return { candidate: manual, priority: 4 };
  return null;
}
```

Add `decodeQrFromImage, detectQrCandidate` to the export block from Task 6.

- [ ] **Step 5: Add `vendor/jsQR.js` to the manifest's content scripts, before `content.js`**

```json
// Replace:
  "content_scripts": [
    {
      "matches": ["<all_urls>"],
      "js": ["content.js"],
      "run_at": "document_idle"
    }
  ]

// With:
  "content_scripts": [
    {
      "matches": ["<all_urls>"],
      "js": ["vendor/jsQR.js", "content.js"],
      "run_at": "document_idle"
    }
  ]
```

Check `ChromeExtension/tests/background.manifest.test.js` — if it asserts an exact array for `content_scripts[0].js`, update that assertion to include `"vendor/jsQR.js"` as the first element.

- [ ] **Step 6: Run and confirm pass**

Run: `node ChromeExtension/tests/totpDetection.test.js` and `node ChromeExtension/tests/background.manifest.test.js`
Expected: both PASS.

- [ ] **Step 7: Commit**

```bash
git add ChromeExtension/vendor/jsQR.js ChromeExtension/content.js ChromeExtension/manifest.json ChromeExtension/tests/totpDetection.test.js ChromeExtension/tests/background.manifest.test.js
git commit -m "feat(chrome): decode QR codes for TOTP setup via vendored jsQR"
```

---

### Task 8: `background.js` — `proposeSaveTotp` routing and popup-picker trigger

**Files:**
- Modify: `ChromeExtension/background.js`
- Test: `ChromeExtension/tests/pairing.test.js`

**Interfaces:**
- Produces: exported `handleRuntimeMessage(message, sender, sendResponse)` (the existing `onMessage` listener body, extracted so it's directly callable from tests); `knownTypes` includes `"proposeSaveTotp"`; a new `"openPopupForTotpPicker"` message type that calls `chrome.action.openPopup()` without going through native messaging.

- [ ] **Step 1: Write a failing test**

Open `ChromeExtension/tests/pairing.test.js` in full and confirm its `global.chrome` stub shape (in-memory `storage`, `sentNativeMessages`, `chrome.runtime.sendNativeMessage`/`onMessage.addListener` stubs). Append this block near the end of the file (outside the existing async IIFE is fine, since these assertions are synchronous):

```js
{
  const { handleRuntimeMessage } = require('../background.js');

  let openPopupCalled = false;
  global.chrome.action = { openPopup: () => { openPopupCalled = true; return Promise.resolve(); } };
  const pickerResult = handleRuntimeMessage({ type: 'openPopupForTotpPicker' }, {}, () => {});
  assert.strictEqual(pickerResult, false);
  assert.strictEqual(openPopupCalled, true, 'openPopupForTotpPicker triggers chrome.action.openPopup');

  const keepChannelOpen = handleRuntimeMessage(
    { type: 'proposeSaveTotp', url: 'https://example.com', otpauthOrSecret: 'JBSWY3DP' }, {}, () => {}
  );
  assert.strictEqual(keepChannelOpen, true, 'proposeSaveTotp is a known type routed through native messaging');

  console.log('pairing.test.js: proposeSaveTotp + openPopupForTotpPicker routing OK');
}
```

- [ ] **Step 2: Run and confirm failure**

Run: `node ChromeExtension/tests/pairing.test.js`
Expected: `TypeError: Cannot destructure property 'handleRuntimeMessage'` — not exported yet, and `background.js`'s listener is currently an anonymous inline callback, not an extracted named function.

- [ ] **Step 3: Extract the listener into `handleRuntimeMessage` and add the new routing**

In `ChromeExtension/background.js`:

```js
// Replace:
chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  const knownTypes = ["getCredentials", "fillCredential", "proposeSaveLogin", "startPairing", "completePairing"];
  if (!message || !knownTypes.includes(message.type)) {
    return false;
  }

  if (message.type === "startPairing") {
    sendNativeMessage({ type: "startPairing", browser: detectBrowserName() }).then((response) => {
      sendResponse(response);
    });
    return true;
  }

  if (message.type === "completePairing") {
    sendPairingCompletion(message).then((response) => {
      sendResponse(response);
    });
    return true;
  }

  sendNativeMessageWithPairing(message).then((response) => {
    if (message.type === "fillCredential" && response && response.type === "credential") {
      relayFillToActiveTab(response, message.url);
      sendResponse(stripCredentialSecrets(response));
      return;
    }
    sendResponse(response);
  });

  return true; // keep the message channel open for the async sendNativeMessage response
});

// With:
function handleRuntimeMessage(message, sender, sendResponse) {
  if (message && message.type === "openPopupForTotpPicker") {
    if (chrome.action && typeof chrome.action.openPopup === "function") {
      chrome.action.openPopup().catch(() => {});
    }
    return false;
  }

  const knownTypes = ["getCredentials", "fillCredential", "proposeSaveLogin", "proposeSaveTotp", "startPairing", "completePairing"];
  if (!message || !knownTypes.includes(message.type)) {
    return false;
  }

  if (message.type === "startPairing") {
    sendNativeMessage({ type: "startPairing", browser: detectBrowserName() }).then((response) => {
      sendResponse(response);
    });
    return true;
  }

  if (message.type === "completePairing") {
    sendPairingCompletion(message).then((response) => {
      sendResponse(response);
    });
    return true;
  }

  sendNativeMessageWithPairing(message).then((response) => {
    if (message.type === "fillCredential" && response && response.type === "credential") {
      relayFillToActiveTab(response, message.url);
      sendResponse(stripCredentialSecrets(response));
      return;
    }
    sendResponse(response);
  });

  return true; // keep the message channel open for the async sendNativeMessage response
}

chrome.runtime.onMessage.addListener(handleRuntimeMessage);
```

(If piece A already hoisted `knownTypes` to module scope and added `"getTotp"`, adapt this edit to that shape instead — the goal is: `knownTypes` includes `"proposeSaveTotp"`, and the listener body is an exported, directly-callable `handleRuntimeMessage` function with the new `openPopupForTotpPicker` branch at the top.)

Add `handleRuntimeMessage` to the file's `module.exports` block.

- [ ] **Step 4: Run and confirm pass**

Run: `node ChromeExtension/tests/pairing.test.js`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ChromeExtension/background.js ChromeExtension/tests/pairing.test.js
git commit -m "feat(chrome): route proposeSaveTotp and add popup-picker trigger"
```

---

### Task 9: `popup.js` / `popup.html` — "Add 2FA" paste field and entry picker

**Files:**
- Modify: `ChromeExtension/popup.html`
- Modify: `ChromeExtension/popup.js`
- Create: `ChromeExtension/tests/totpPicker.test.js`
- Modify: `scripts/test.sh`

**Interfaces:**
- Produces: `validateTotpPasteInput(raw)`, `isBase32PasteSecret(candidate)`, `renderTotpPicker(credentials, url, otpauthOrSecret)`, `routeTotpCandidate(url, otpauthOrSecret, credentials)`, `restorePendingTotpCandidate()` — added to `popup.js`'s `module.exports`.

- [ ] **Step 1: Read the existing DOM-stub pattern, then write failing tests**

Read `ChromeExtension/tests/popup-fallback.test.js` in full for its exact `global.document`/`global.chrome` stub setup (it already successfully `require('../popup.js')`s without the top-level DOM-wiring code throwing) — copy that same baseline into the new test file below. Also confirm, by reading `popup.js`, the exact name of whatever existing module-level variable/mechanism it already uses to capture the active tab's URL (search for `chrome.tabs.query`) — the "Add 2FA" button reuses it rather than re-querying tabs.

Create `ChromeExtension/tests/totpPicker.test.js`:

```js
const assert = require('node:assert');

// --- copy the exact global.document / global.chrome stub setup from
// popup-fallback.test.js here, before requiring '../popup.js'. ---

const { validateTotpPasteInput, isBase32PasteSecret, routeTotpCandidate } = require('../popup.js');

assert.deepStrictEqual(
  validateTotpPasteInput('otpauth://totp/Example:alice?secret=JBSWY3DP'),
  { valid: true, value: 'otpauth://totp/Example:alice?secret=JBSWY3DP' }
);
assert.deepStrictEqual(validateTotpPasteInput('  JBSW Y3DP EHPK 3PXP  '), { valid: true, value: 'JBSWY3DPEHPK3PXP' });
assert.strictEqual(validateTotpPasteInput('not valid').valid, false);
assert.strictEqual(validateTotpPasteInput('').valid, false);
assert.strictEqual(isBase32PasteSecret('JBSWY3DPEHPK3PXP'), true);
assert.strictEqual(isBase32PasteSecret('short'), false);
console.log('totpPicker.test.js: paste validation OK');

(() => {
  let sentMessage = null;
  global.chrome.runtime.sendMessage = (msg, cb) => { sentMessage = msg; if (cb) cb({ type: 'saveProposalAccepted' }); };

  routeTotpCandidate('https://example.com', 'JBSWY3DP', []);
  assert.strictEqual(sentMessage.type, 'proposeSaveTotp');
  assert.strictEqual(sentMessage.entryId, undefined, 'zero matches sends no entryId');

  routeTotpCandidate('https://example.com', 'JBSWY3DP', [{ id: 'entry-1', title: 'Example', hasTotp: false }]);
  assert.strictEqual(sentMessage.entryId, 'entry-1', 'single match includes entryId');

  console.log('totpPicker.test.js: routeTotpCandidate routing OK');
})();
```

- [ ] **Step 2: Run and confirm failure**

Run: `node ChromeExtension/tests/totpPicker.test.js`
Expected: `TypeError` — none of these functions exist/are exported yet.

- [ ] **Step 3: Implement in `popup.html`**

Add a new "Add 2FA" section, following the existing `#code-entry` panel's markup convention (label `<p>`, `<input>`, `<button class="btn-primary">`, error `<p hidden>`):

```html
<div id="add-totp-section">
  <p id="add-totp-hint">Paste otpauth:// URL or secret key</p>
  <input id="totp-paste-input" type="text" placeholder="Paste otpauth:// URL or secret key" />
  <button id="add-totp-btn" type="button" class="btn-primary">Add</button>
  <p id="add-totp-error" hidden></p>
</div>
```

Add a badge style to the existing `<style>` block:

```css
.totp-badge {
  flex-shrink: 0;
  font-size: 10px;
  font-weight: 600;
  padding: 2px 6px;
  border-radius: 4px;
  background: rgba(80, 160, 255, 0.15);
  color: #3b82f6;
}
```

- [ ] **Step 4: Implement in `popup.js`**

Add near the file's other helpers, before the export block:

```js
function validateTotpPasteInput(raw) {
  const trimmed = (raw || '').trim();
  if (trimmed.toLowerCase().startsWith('otpauth://totp/')) {
    return { valid: true, value: trimmed };
  }
  if (isBase32PasteSecret(trimmed)) {
    return { valid: true, value: trimmed.replace(/\s+/g, '').toUpperCase() };
  }
  return { valid: false, value: null };
}

function isBase32PasteSecret(candidate) {
  const normalized = (candidate || '').replace(/\s+/g, '');
  return /^[A-Z2-7]{16,128}$/i.test(normalized);
}

function renderTotpPicker(credentials, url, otpauthOrSecret) {
  listEl.innerHTML = '';
  credentials.forEach((credential) => {
    const item = document.createElement('li');
    item.className = 'credential-row';
    item.appendChild(buildLetterAvatarElement(credential.title));

    const textCol = document.createElement('div');
    textCol.className = 'credential-text';
    const title = document.createElement('div');
    title.className = 'credential-title';
    title.textContent = credential.title;
    textCol.appendChild(title);
    item.appendChild(textCol);

    if (credential.hasTotp) {
      const badge = document.createElement('span');
      badge.className = 'totp-badge';
      badge.textContent = '2FA';
      item.appendChild(badge);
    }

    item.addEventListener('click', () => {
      chrome.runtime.sendMessage(
        { type: 'proposeSaveTotp', url, otpauthOrSecret, entryId: credential.id },
        () => {
          const errorEl = document.getElementById('add-totp-error');
          errorEl.hidden = false;
          errorEl.textContent = 'Opened in MyPass';
        }
      );
    });
    listEl.appendChild(item);
  });
}

function routeTotpCandidate(url, otpauthOrSecret, credentials) {
  if (credentials.length === 0) {
    chrome.runtime.sendMessage({ type: 'proposeSaveTotp', url, otpauthOrSecret });
  } else if (credentials.length === 1) {
    chrome.runtime.sendMessage({ type: 'proposeSaveTotp', url, otpauthOrSecret, entryId: credentials[0].id });
  } else {
    renderTotpPicker(credentials, url, otpauthOrSecret);
  }
}

function handleAddTotpClick(activeTabUrl) {
  const raw = document.getElementById('totp-paste-input').value;
  const validation = validateTotpPasteInput(raw);
  const errorEl = document.getElementById('add-totp-error');
  if (!validation.valid) {
    errorEl.textContent = 'Enter a valid authenticator URL or secret key';
    errorEl.hidden = false;
    return;
  }
  errorEl.hidden = true;
  chrome.runtime.sendMessage({ type: 'getCredentials', url: activeTabUrl }, (response) => {
    const credentials = (response && response.type === 'credentialList') ? response.credentials : [];
    routeTotpCandidate(activeTabUrl, validation.value, credentials);
  });
}

function restorePendingTotpCandidate(activeTabUrl) {
  const area = getPairingStorageArea();
  if (!area || !area.get) return;
  area.get(['pendingTotpCandidate'], (result) => {
    const pending = result && result.pendingTotpCandidate;
    if (!pending) return;
    document.getElementById('totp-paste-input').value = pending.otpauthOrSecret;
    chrome.runtime.sendMessage({ type: 'getCredentials', url: pending.url }, (response) => {
      const credentials = (response && response.type === 'credentialList') ? response.credentials : [];
      if (credentials.length > 1) {
        renderTotpPicker(credentials, pending.url, pending.otpauthOrSecret);
      }
    });
    area.remove(['pendingTotpCandidate']);
  });
}
```

(`handleAddTotpClick`/`restorePendingTotpCandidate` take the active tab URL as a parameter rather than re-querying — wire the actual call sites to pass whatever variable already holds it from the existing `getCredentials`-on-open flow you found in Step 1.)

Wire `#add-totp-btn`'s click listener to `handleAddTotpClick(...)` and call `restorePendingTotpCandidate(...)` during popup init, alongside the existing credential-list load.

Add the new functions to `module.exports`:

```js
validateTotpPasteInput, isBase32PasteSecret, renderTotpPicker, routeTotpCandidate, restorePendingTotpCandidate
```

- [ ] **Step 5: Wire the new test into `scripts/test.sh`**

```bash
# Replace:
  node ChromeExtension/tests/totpDetection.test.js
else

# With:
  node ChromeExtension/tests/totpDetection.test.js
  node ChromeExtension/tests/totpPicker.test.js
else
```

- [ ] **Step 6: Run and confirm pass**

Run: `node ChromeExtension/tests/totpPicker.test.js`
Expected: PASS. Also run `node ChromeExtension/tests/popup-fallback.test.js` and `node ChromeExtension/tests/letter-avatar.test.js` to confirm no regression in `popup.js`.

- [ ] **Step 7: Commit**

```bash
git add ChromeExtension/popup.html ChromeExtension/popup.js ChromeExtension/tests/totpPicker.test.js scripts/test.sh
git commit -m "feat(chrome): add popup Add 2FA paste field and multi-match picker"
```

---

### Task 10: Manual e2e fixtures and `RUN.md` checklist

**Files:**
- Create: `ChromeExtension/tests/fixtures/otpauth-link.html`
- Create: `ChromeExtension/tests/fixtures/manual-key.html`
- Create: `ChromeExtension/tests/fixtures/qr.html`
- Create: `ChromeExtension/tests/fixtures/totp-qr.png`
- Modify: `RUN.md`

**Interfaces:** none (fixtures + docs only).

- [ ] **Step 1: Create the otpauth-link fixture**

Write `ChromeExtension/tests/fixtures/otpauth-link.html`:

```html
<!DOCTYPE html>
<html>
<head><meta charset="utf-8"><title>MyPass otpauth link fixture</title></head>
<body>
  <h1>Set up two-factor authentication</h1>
  <p>Scan the QR code, or use this link if scanning isn't available:</p>
  <a href="otpauth://totp/Example:alice@example.com?secret=JBSWY3DPEHPK3PXP&issuer=Example">Open in authenticator app</a>
</body>
</html>
```

- [ ] **Step 2: Create the manual-key fixture**

Write `ChromeExtension/tests/fixtures/manual-key.html`:

```html
<!DOCTYPE html>
<html>
<head><meta charset="utf-8"><title>MyPass manual key fixture</title></head>
<body>
  <h1>Can't scan? Enter this manual setup key</h1>
  <p class="secret-key">JBSW Y3DP EHPK 3PXP</p>
</body>
</html>
```

- [ ] **Step 3: Generate the QR fixture image and page**

Generate a QR PNG encoding a known otpauth test string, e.g. via `qrencode` if available:

```bash
qrencode -o ChromeExtension/tests/fixtures/totp-qr.png 'otpauth://totp/Example:carol@example.com?secret=JBSWY3DPEHPK3PXP&issuer=Example'
```

If `qrencode` isn't installed, use any QR generator (`brew install qrencode`, an online generator saved locally, etc.) to produce `totp-qr.png` encoding that same string. This is a real image asset — do not fabricate PNG bytes by hand.

Write `ChromeExtension/tests/fixtures/qr.html`:

```html
<!DOCTYPE html>
<html>
<head><meta charset="utf-8"><title>MyPass QR fixture</title></head>
<body>
  <h1>Scan this QR code</h1>
  <img src="totp-qr.png" alt="TOTP setup QR code" width="200" height="200">
</body>
</html>
```

- [ ] **Step 4: Verify fixtures are served correctly**

Run: `cd ChromeExtension/tests/fixtures && python3 -m http.server 8765 &`
Then: `curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8765/otpauth-link.html`, `.../manual-key.html`, `.../qr.html`, `.../totp-qr.png`
Expected: all print `200`. Stop the server: `kill %1`.

- [ ] **Step 5: Add manual e2e bullets to `RUN.md`**

Find the "Короткий чеклист" list under `### Chrome e2e (ручна перевірка)` in `RUN.md` (if the piece-A plan already added bullets there, append after its last bullet instead of the original four):

```markdown
     - [ ] Сторінка з посиланням otpauth:// показує банер **Save 2FA to MyPass?** (не банер пароля)
     - [ ] **Not now** ховає банер; перезавантаження або новий крок налаштування може показати його знову
     - [ ] QR того самого походження на фікстурній сторінці декодується; Save відкриває MyPass з попередньо заповненим OTP
     - [ ] Сайт без запису у сховищі: Save відкриває форму створення, назва — registrable domain, поле OTP видиме
     - [ ] Сайт з одним записом: Save відкриває редагування цього запису з попередньо заповненим OTP
     - [ ] Сайт з кількома записами: Save відкриває пікер у popup; вибір рядка → редагування в MyPass з OTP
     - [ ] Запис, що вже має 2FA: з'являється **Replace 2FA?**; Cancel залишає старий секрет; Replace + Save оновлює секрет
     - [ ] Вставка **Add 2FA** у popup з otpauth URL → **Opened in MyPass** після відкриття застосунку
     - [ ] Заблокований сейф: банер TOTP не показується (або Save показує заблокований стан у popup)
     - [ ] QR іншого походження (cross-origin) пропускається без падіння; без банера, якщо немає тексту otpauth
```

(`RUN.md` is Ukrainian by project convention — do not translate any of it.)

- [ ] **Step 6: Commit**

```bash
git add ChromeExtension/tests/fixtures/otpauth-link.html ChromeExtension/tests/fixtures/manual-key.html ChromeExtension/tests/fixtures/qr.html ChromeExtension/tests/fixtures/totp-qr.png RUN.md
git commit -m "docs(chrome): add TOTP setup manual e2e fixtures and checklist bullets"
```

---

### Task 11: Full verification run

**Files:** none (verification only).

- [ ] **Step 1: Run the full test suite**

Run: `./scripts/test.sh`
Expected: PASS end-to-end — `xcodebuild test` (including the new `ExtensionBridgeServiceTests`, `NavigationStatePendingTotpSaveProposalTests`, and `EntryEditSaveLogicTests` cases), `swift test` for `ExtensionBridgeKit` (including the new `ExtensionBridgeMessagesTests` cases), and every `node ChromeExtension/tests/*.test.js` line in `scripts/test.sh` (including the two new files).

- [ ] **Step 2: Cross-check acceptance criteria against the spec**

Confirm each of the following, from `docs/superpowers/specs/2026-08-01-chrome-extension-totp-setup-design.md`'s Acceptance Criteria section:

1. **Page detect** — `totpDetection.test.js` covers link/text/manual-key detection and the priority-based dismiss/re-show logic (`shouldShowTotpBanner`).
2. **QR decode** — `totpDetection.test.js`'s QR section covers same-origin decode and the CORS-tainted-canvas skip path.
3. **Zero matches** — `draftEntry(from: PendingTotpSaveProposal)` never sets `totpSecretBase32`; `testProposeSaveTotpWithoutEntryIdInvokesClosureAndReturnsAccepted` confirms no domain check blocks the create path.
4. **One match** — `testProposeSaveTotpWithMatchingEntryIdInvokesClosureWithResolvedUUID` plus `EntryEditView`'s `prefilledOtpauthInput` pre-fill.
5. **Multiple matches** — `renderTotpPicker`/`routeTotpCandidate` in `totpPicker.test.js`, `hasTotp` badge conditional on `credential.hasTotp`.
6. **Replace guard** — `testRequiresReplaceConfirmationWhenEntryHasExistingSecretAndFromProposal` plus the `showReplaceTotpAlert` gate in `EntryEditView.save()`.
7. **Domain mismatch** — `testProposeSaveTotpReturnsErrorWhenEntryIdDomainMismatch`.
8. **Popup paste** — `validateTotpPasteInput` tests in `totpPicker.test.js`.
9. **Security** — no code path calls `VaultSession.mutate` from the extension/ChromeHost side (confirm by reading `ExtensionBridgeService.swift`'s `proposeSaveTotp` case — it only invokes `onTotpSaveProposal?`, never touches `vaultSession.mutate`); `testProposeSaveTotpReturnsLockedAndDoesNotInvokeClosureWhenVaultIsLocked` and `ReturnsPairingRequiredWithoutSecret` confirm the gates; TOTP banner and password banner use separate `state.totpBannerShown`/`state.bannerShown` flags.
10. **Invariant** — grep the diff for `VaultSession.mutate`/`.mutate(` calls introduced in `ChromeExtension/` or `ChromeHost`-adjacent Swift files outside `EntryEditView.save()`'s existing pre-proposal-B call path — there should be none.

If any criterion doesn't hold, stop and fix it before considering the plan complete.
