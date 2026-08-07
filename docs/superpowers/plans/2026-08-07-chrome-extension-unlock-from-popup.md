# Chrome Extension Unlock From Popup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the locked popup an **Unlock MyPass** button that brings the app forward with its unlock screen and a fresh Touch ID prompt, without the master password ever entering the browser.

**Architecture:** A new `requestUnlock` bridge message is the single addition to the wire protocol. `ExtensionBridgeService` answers it as the one documented exception to its blanket locked gate — expressed as a `isAnswerableWhileLocked` predicate on the request rather than a second special case — validates pairing, debounces, and fires a new `onUnlockRequested` callback. `MyPassApp` wires that callback to `MainWindowActivator.request()` plus a new `.requestDeviceUnlockPrompt` notification that `UnlockView` observes to re-run its Touch ID prompt. No new app UI: `ContentView` already renders `UnlockView` whenever the vault is locked.

**Tech Stack:** Swift (Swift Package Manager for `ExtensionBridgeKit`, Xcode project + SwiftUI for the app), vanilla JavaScript (Chrome MV3, CommonJS exports for Node tests, no bundler), XCTest, Node's `assert` module.

Design spec: [`2026-08-07-chrome-extension-unlock-from-popup-design.md`](../specs/2026-08-07-chrome-extension-unlock-from-popup-design.md).
Roadmap items: `U3`–`U9` in [`docs/implementation/ROADMAP.md`](../../implementation/ROADMAP.md).

## Global Constraints

- English everywhere (code, comments, docs, UI, commits). **Exception:** `RUN.md` is Ukrainian — do not translate it.
- The extension never unlocks the vault. `requestUnlock` only asks the app to *present* its unlock UI. The master password must appear in no bridge message and in no popup DOM node.
- **No password field in the popup.** This plan reverses only the "no unlock-from-extension" and "no unlock IPC" clauses of `2026-08-01-chrome-extension-popup-list-redesign-design.md`; its no-password-field clause stands.
- A valid pairing secret is required for `requestUnlock`. Unpaired → `.pairingRequired`, callback not invoked, no window activation.
- No settings toggle, no `UserDefaults` key. Pairing is the only gate.
- Handler check order is load-bearing and must be exactly: pairing → already-unlocked → debounce → activate.
- Debounce window is **2 seconds**.
- `ExtensionBridgeService` must never touch `VaultSession` in this feature — it only fires a callback.
- Do not change auto-lock, pairing, or credential-fill behavior.

## File Structure

| Path | Action | Responsibility |
|------|--------|----------------|
| `Packages/ExtensionBridgeKit/Sources/ExtensionBridgeKit/ExtensionBridgeMessages.swift` | Modify | `.requestUnlock` request, `.unlockPresented` / `.unlockNotNeeded` responses, `isAnswerableWhileLocked` predicate |
| `Packages/ExtensionBridgeKit/Tests/ExtensionBridgeKitTests/ExtensionBridgeMessagesTests.swift` | Modify | Round-trip coverage + predicate coverage |
| `MyPass/State/ExtensionBridge/ExtensionBridgeService.swift` | Modify | Gate exception, `requestUnlock` handler, debounce clock, `onUnlockRequested` |
| `MyPass/State/ExtensionBridge/LoopbackServer.swift` | Modify | Token-extraction arm for the new case |
| `MyPassTests/ExtensionBridgeServiceTests.swift` | Modify | Handler behaviour incl. ordering and debounce |
| `MyPass/App/MainWindowActivator.swift` | Modify | `.requestDeviceUnlockPrompt` notification name |
| `MyPass/UI/Unlock/UnlockView.swift` | Modify | Observe the notification, re-run `attemptDeviceUnlock()` |
| `MyPass/MyPassApp.swift` | Modify | Wire `onUnlockRequested` |
| `ChromeExtension/background.js` | Modify | `requestUnlock` in `knownTypes` |
| `ChromeExtension/popup.html` | Modify | Unlock button in the locked panel |
| `ChromeExtension/popup.js` | Modify | Button visibility, click wiring, `unlockNotNeeded` re-query |
| `ChromeExtension/tests/unlockButton.test.js` | Create | Pure-function tests for visibility and response handling |
| `scripts/test.sh` | Modify | Run the new JS test |
| `RUN.md` | Modify | Manual checklist (Ukrainian) |

---

### Task 1: `ExtensionBridgeKit` — `requestUnlock` wire protocol

Roadmap item `U3`.

**Files:**
- Modify: `Packages/ExtensionBridgeKit/Sources/ExtensionBridgeKit/ExtensionBridgeMessages.swift`
- Test: `Packages/ExtensionBridgeKit/Tests/ExtensionBridgeKitTests/ExtensionBridgeMessagesTests.swift`

**Interfaces:**
- Produces: `ExtensionBridgeRequest.requestUnlock(token: String, pairing: String?)`; `ExtensionBridgeResponse.unlockPresented`; `ExtensionBridgeResponse.unlockNotNeeded`; `ExtensionBridgeRequest.isAnswerableWhileLocked: Bool`.

- [ ] **Step 1: Write the failing tests**

Append these to `ExtensionBridgeMessagesTests.swift`, inside the existing `final class ExtensionBridgeMessagesTests: XCTestCase` body. The file already defines the `jsonObject(from:)` helper used below — do not redefine it.

```swift
    func testRequestUnlockRoundTripsAndHasExpectedShape() throws {
        let request = ExtensionBridgeRequest.requestUnlock(token: "tok-9", pairing: "pair-secret")
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(ExtensionBridgeRequest.self, from: data)
        XCTAssertEqual(decoded, request)

        let object = try jsonObject(from: data)
        XCTAssertEqual(object["type"] as? String, "requestUnlock")
        XCTAssertEqual(object["token"] as? String, "tok-9")
        XCTAssertEqual(object["pairing"] as? String, "pair-secret")
    }

    func testRequestUnlockRoundTripsWithoutPairing() throws {
        let request = ExtensionBridgeRequest.requestUnlock(token: "tok-10", pairing: nil)
        let data = try JSONEncoder().encode(request)
        XCTAssertEqual(try JSONDecoder().decode(ExtensionBridgeRequest.self, from: data), request)

        let object = try jsonObject(from: data)
        XCTAssertNil(object["pairing"])
    }

    func testUnlockResponsesRoundTrip() throws {
        for response in [ExtensionBridgeResponse.unlockPresented, .unlockNotNeeded] {
            let data = try JSONEncoder().encode(response)
            XCTAssertEqual(try JSONDecoder().decode(ExtensionBridgeResponse.self, from: data), response)
        }

        let presented = try jsonObject(from: try JSONEncoder().encode(ExtensionBridgeResponse.unlockPresented))
        XCTAssertEqual(presented["type"] as? String, "unlockPresented")
        let notNeeded = try jsonObject(from: try JSONEncoder().encode(ExtensionBridgeResponse.unlockNotNeeded))
        XCTAssertEqual(notNeeded["type"] as? String, "unlockNotNeeded")
    }

    func testOnlyRequestUnlockIsAnswerableWhileLocked() {
        XCTAssertTrue(ExtensionBridgeRequest.requestUnlock(token: "t", pairing: nil).isAnswerableWhileLocked)

        let gated: [ExtensionBridgeRequest] = [
            .getCredentials(token: "t", url: "https://example.com", pairing: nil),
            .fillCredential(token: "t", id: "e", url: "https://example.com", pairing: nil),
            .proposeSaveLogin(token: "t", url: "https://example.com", username: "u", password: "p", pairing: nil),
            .startPairing(token: "t", browser: nil),
            .completePairing(token: "t", code: "123456"),
        ]
        for request in gated {
            XCTAssertFalse(request.isAnswerableWhileLocked, "\(request) must stay behind the locked gate")
        }
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd Packages/ExtensionBridgeKit && swift test 2>&1 | tail -20`

Expected: FAIL — compile errors, `requestUnlock` / `unlockPresented` / `unlockNotNeeded` / `isAnswerableWhileLocked` do not exist.

- [ ] **Step 3: Add the request case**

In `ExtensionBridgeMessages.swift`, add the case to `ExtensionBridgeRequest` (after `completePairing`):

```swift
    case requestUnlock(token: String, pairing: String?)
```

Add the decode arm inside `init(from:)`'s `switch type`, after the `"completePairing"` case:

```swift
        case "requestUnlock":
            let pairing = try container.decodeIfPresent(String.self, forKey: .pairing)
            self = .requestUnlock(token: token, pairing: pairing)
```

Add the encode arm inside `encode(to:)`'s `switch self`, after the `.completePairing` case:

```swift
        case .requestUnlock(let token, let pairing):
            try container.encode("requestUnlock", forKey: .type)
            try container.encode(token, forKey: .token)
            try container.encodeIfPresent(pairing, forKey: .pairing)
```

No `CodingKeys` change is needed — `type`, `token` and `pairing` already exist.

- [ ] **Step 4: Add the locked-gate predicate**

Add this extension immediately after the closing brace of `extension ExtensionBridgeRequest: Codable { ... }`:

```swift
public extension ExtensionBridgeRequest {
    /// The requests the app answers even while the vault is locked. Everything else is
    /// rejected with `.locked` before it reaches a handler.
    ///
    /// The switch is deliberately exhaustive with no `default`: a new request case must
    /// make an explicit decision here rather than silently inheriting an exemption.
    /// Keep this list as short as the spec allows.
    var isAnswerableWhileLocked: Bool {
        switch self {
        case .requestUnlock:
            return true
        case .getCredentials, .fillCredential, .proposeSaveLogin, .startPairing, .completePairing:
            return false
        }
    }
}
```

- [ ] **Step 5: Add the response cases**

Add to `ExtensionBridgeResponse` (after `saveProposalAccepted`):

```swift
    case unlockPresented
    case unlockNotNeeded
```

Add the decode arms inside `init(from:)`'s `switch type`, after `"saveProposalAccepted"`:

```swift
        case "unlockPresented":
            self = .unlockPresented
        case "unlockNotNeeded":
            self = .unlockNotNeeded
```

Add the encode arms inside `encode(to:)`'s `switch self`, after `.saveProposalAccepted`:

```swift
        case .unlockPresented:
            try container.encode("unlockPresented", forKey: .type)
        case .unlockNotNeeded:
            try container.encode("unlockNotNeeded", forKey: .type)
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `cd Packages/ExtensionBridgeKit && swift test 2>&1 | tail -20`

Expected: PASS, all suites, 0 failures.

- [ ] **Step 7: Commit**

```bash
git add Packages/ExtensionBridgeKit/Sources/ExtensionBridgeKit/ExtensionBridgeMessages.swift \
        Packages/ExtensionBridgeKit/Tests/ExtensionBridgeKitTests/ExtensionBridgeMessagesTests.swift
git commit -m "feat(bridge): add requestUnlock message and locked-gate predicate"
```

---

### Task 2: `ExtensionBridgeService` — handler, gate exception, debounce

Roadmap item `U4`.

**Files:**
- Modify: `MyPass/State/ExtensionBridge/ExtensionBridgeService.swift`
- Modify: `MyPass/State/ExtensionBridge/LoopbackServer.swift:186-191`
- Test: `MyPassTests/ExtensionBridgeServiceTests.swift`

**Interfaces:**
- Consumes: `ExtensionBridgeRequest.requestUnlock`, `.isAnswerableWhileLocked`, `ExtensionBridgeResponse.unlockPresented` / `.unlockNotNeeded` (Task 1).
- Produces: `ExtensionBridgeService.onUnlockRequested: (() -> Void)?`; `ExtensionBridgeService.init(vaultSession:pairingManager:now:)` where `now: @escaping () -> Date = Date.init`; `ExtensionBridgeService.unlockRequestDebounceInterval: TimeInterval` (static, `2`).

- [ ] **Step 1: Write the failing tests**

Append to `ExtensionBridgeServiceTests.swift`, inside the existing class. `setUpWithError` already builds `service`, `session` and `authorizedPairingSecret`; tests that need a controllable clock build their own service, as shown.

```swift
    // MARK: - requestUnlock

    /// Builds a service whose clock the test drives, sharing this case's session and a
    /// pairing manager authorising `authorizedPairingSecret`.
    private func makeServiceWithControlledClock(now: @escaping () -> Date) throws -> ExtensionBridgeService {
        let store = InMemoryExtensionPairingStore()
        let hash = SHA256.hash(data: Data(authorizedPairingSecret.utf8))
            .compactMap { String(format: "%02x", $0) }
            .joined()
        try store.add(PairedBrowser(id: UUID(), label: "Test", createdAt: Date(), secretHash: hash))
        return ExtensionBridgeService(
            vaultSession: session,
            pairingManager: ExtensionPairingManager(store: store),
            now: now
        )
    }

    func testRequestUnlockIsAnsweredWhileLockedAndInvokesCallback() {
        session.lock()
        var callbackCount = 0
        service.onUnlockRequested = { callbackCount += 1 }

        let response = service.handle(.requestUnlock(token: "tok", pairing: authorizedPairingSecret))

        XCTAssertEqual(response, .unlockPresented)
        XCTAssertEqual(callbackCount, 1)
    }

    func testRequestUnlockWithoutPairingReturnsPairingRequiredAndDoesNotInvokeCallback() {
        session.lock()
        var callbackCount = 0
        service.onUnlockRequested = { callbackCount += 1 }

        let response = service.handle(.requestUnlock(token: "tok", pairing: nil))

        XCTAssertEqual(response, .pairingRequired)
        XCTAssertEqual(callbackCount, 0)
    }

    func testRequestUnlockWithWrongPairingSecretReturnsPairingRequired() {
        session.lock()
        var callbackCount = 0
        service.onUnlockRequested = { callbackCount += 1 }

        let response = service.handle(.requestUnlock(token: "tok", pairing: "not-the-secret"))

        XCTAssertEqual(response, .pairingRequired)
        XCTAssertEqual(callbackCount, 0)
    }

    func testRequestUnlockReturnsUnlockNotNeededWhenAlreadyUnlocked() {
        // setUpWithError leaves the session unlocked.
        var callbackCount = 0
        service.onUnlockRequested = { callbackCount += 1 }

        let response = service.handle(.requestUnlock(token: "tok", pairing: authorizedPairingSecret))

        XCTAssertEqual(response, .unlockNotNeeded)
        XCTAssertEqual(callbackCount, 0, "an unlocked vault must not raise the window")
    }

    func testRequestUnlockDebouncesRepeatsWithinTwoSeconds() throws {
        session.lock()
        var clock = Date(timeIntervalSince1970: 1_000)
        let debounced = try makeServiceWithControlledClock(now: { clock })
        var callbackCount = 0
        debounced.onUnlockRequested = { callbackCount += 1 }

        XCTAssertEqual(debounced.handle(.requestUnlock(token: "t", pairing: authorizedPairingSecret)), .unlockPresented)
        clock = clock.addingTimeInterval(1.0)
        XCTAssertEqual(debounced.handle(.requestUnlock(token: "t", pairing: authorizedPairingSecret)), .unlockPresented)

        XCTAssertEqual(callbackCount, 1, "a repeat inside the window must not raise a second prompt")
    }

    func testRequestUnlockAcceptsAgainAfterTheDebounceWindow() throws {
        session.lock()
        var clock = Date(timeIntervalSince1970: 1_000)
        let debounced = try makeServiceWithControlledClock(now: { clock })
        var callbackCount = 0
        debounced.onUnlockRequested = { callbackCount += 1 }

        _ = debounced.handle(.requestUnlock(token: "t", pairing: authorizedPairingSecret))
        clock = clock.addingTimeInterval(2.5)
        _ = debounced.handle(.requestUnlock(token: "t", pairing: authorizedPairingSecret))

        XCTAssertEqual(callbackCount, 2)
    }

    /// The spec's load-bearing ordering: already-unlocked is checked BEFORE the debounce,
    /// so a click arriving right after a successful unlock tells the popup to re-query
    /// instead of being swallowed as a repeat.
    func testUnlockNotNeededWinsOverDebounce() throws {
        session.lock()
        var clock = Date(timeIntervalSince1970: 1_000)
        let debounced = try makeServiceWithControlledClock(now: { clock })

        XCTAssertEqual(debounced.handle(.requestUnlock(token: "t", pairing: authorizedPairingSecret)), .unlockPresented)

        try session.unlock(password: "correct-horse")
        clock = clock.addingTimeInterval(0.5) // still inside the debounce window

        XCTAssertEqual(debounced.handle(.requestUnlock(token: "t", pairing: authorizedPairingSecret)), .unlockNotNeeded)
    }

    func testOtherRequestsStillReturnLockedWhenVaultIsLocked() {
        session.lock()
        XCTAssertEqual(
            service.handle(.getCredentials(token: "tok", url: "https://example.com", pairing: authorizedPairingSecret)),
            .locked
        )
        XCTAssertEqual(service.handle(.startPairing(token: "tok", browser: "Chrome")), .locked)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./scripts/generate.sh && xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/ExtensionBridgeServiceTests 2>&1 | grep -E "error:|Executed [0-9]+ test|TEST FAILED|TEST SUCCEEDED" | head`

Expected: FAIL — no `onUnlockRequested`, no `now:` parameter, no `requestUnlock` handling.

- [ ] **Step 3: Add the callback, clock and debounce state**

In `ExtensionBridgeService.swift`, add next to the existing `onSaveProposal` / `onCredentialFilled` properties:

```swift
    /// Fired for `.requestUnlock`. Wired in `MyPassApp.init()` to bring the window
    /// forward and re-trigger the Touch ID prompt. The service itself never unlocks
    /// anything — presenting the unlock UI is the app layer's job.
    var onUnlockRequested: (() -> Void)?
```

Add the stored clock and debounce bookkeeping alongside `pairingManager`:

```swift
    /// Injectable so the debounce is testable without sleeping.
    private let now: () -> Date
    private var lastAcceptedUnlockRequestAt: Date?

    /// Repeat `requestUnlock` calls inside this window are answered but produce no
    /// second window activation or Touch ID prompt.
    static let unlockRequestDebounceInterval: TimeInterval = 2
```

Replace the initialiser with:

```swift
    init(
        vaultSession: VaultSession,
        pairingManager: ExtensionPairingManager,
        now: @escaping () -> Date = Date.init
    ) {
        self.vaultSession = vaultSession
        self.pairingManager = pairingManager
        self.now = now
    }
```

The new parameter is defaulted, so every existing call site keeps compiling unchanged.

- [ ] **Step 4: Make the locked gate consult the predicate**

Replace the guard at the top of `handle(_:)`:

```swift
// Replace:
        guard vaultSession?.currentDatabase != nil else {
            return .locked
        }

// With:
        guard vaultSession?.currentDatabase != nil || request.isAnswerableWhileLocked else {
            return .locked
        }
```

- [ ] **Step 5: Add the handler**

Add this case to `handle(_:)`'s `switch request`, after the `.proposeSaveLogin` case:

```swift
        case .requestUnlock(_, let pairing):
            // Order is load-bearing — see the design spec's "Order of checks".
            guard pairingManager.isAuthorized(pairing: pairing) else {
                return .pairingRequired
            }
            // Checked before the debounce so a click arriving just after a successful
            // unlock always tells the popup to re-query rather than being swallowed.
            guard vaultSession?.currentDatabase == nil else {
                return .unlockNotNeeded
            }
            let timestamp = now()
            if let last = lastAcceptedUnlockRequestAt,
               timestamp.timeIntervalSince(last) < Self.unlockRequestDebounceInterval {
                return .unlockPresented
            }
            lastAcceptedUnlockRequestAt = timestamp
            onUnlockRequested?()
            return .unlockPresented
```

- [ ] **Step 6: Add the `LoopbackServer` token arm**

In `LoopbackServer.swift`, add to the switch at lines 186-191:

```swift
        case .requestUnlock(let token, _): return token
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `./scripts/generate.sh && xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/ExtensionBridgeServiceTests 2>&1 | grep -E "error:|Executed [0-9]+ test|TEST FAILED|TEST SUCCEEDED" | head`

Expected: PASS, 0 failures.

- [ ] **Step 8: Commit**

```bash
git add MyPass/State/ExtensionBridge/ExtensionBridgeService.swift \
        MyPass/State/ExtensionBridge/LoopbackServer.swift \
        MyPassTests/ExtensionBridgeServiceTests.swift
git commit -m "feat(app): handle requestUnlock with pairing gate and debounce"
```

---

### Task 3: App wiring — notification, `UnlockView`, `MyPassApp`

Roadmap item `U5`.

No new UI is built here. `ContentView.swift:11` already renders `UnlockView()` whenever the vault is locked, and `UnlockView` already owns the password field and the Touch ID button. The only gap is that its auto-prompt lives in `.onAppear` behind the `@State` flag `didAutoPromptDeviceUnlock`, so neither fires when an already-open window is merely refocused.

**Files:**
- Modify: `MyPass/App/MainWindowActivator.swift`
- Modify: `MyPass/UI/Unlock/UnlockView.swift`
- Modify: `MyPass/MyPassApp.swift`

**Interfaces:**
- Consumes: `ExtensionBridgeService.onUnlockRequested` (Task 2).
- Produces: `Notification.Name.requestDeviceUnlockPrompt`.

- [ ] **Step 1: Add the notification name**

In `MainWindowActivator.swift`, add to the existing `extension Notification.Name` block:

```swift
    /// Posted when something outside the unlock screen wants the Touch ID prompt shown
    /// again — currently only the browser extension's `requestUnlock`. `UnlockView`'s
    /// own `.onAppear` auto-prompt does not re-fire when an open window is refocused.
    static let requestDeviceUnlockPrompt = Notification.Name("com.mypass.requestDeviceUnlockPrompt")
```

- [ ] **Step 2: Observe it in `UnlockView`**

In `UnlockView.swift`, find the existing `.onAppear { ... }` modifier (around line 116) and add this modifier immediately after its closing brace:

```swift
        .onReceive(NotificationCenter.default.publisher(for: .requestDeviceUnlockPrompt)) { _ in
            // `silentCancel: true` matches the `.onAppear` auto-prompt: a user who
            // dismisses the system sheet should not be shown an error.
            guard canShowDeviceUnlockButton else { return }
            attemptDeviceUnlock(silentCancel: true)
        }
```

`canShowDeviceUnlockButton` already returns `false` when Touch ID is unenrolled or disallowed, so on such a machine this is a no-op and the password field is simply there — which is the spec's stated behaviour.

- [ ] **Step 3: Wire the callback in `MyPassApp`**

In `MyPassApp.swift`, immediately after the existing `extensionBridgeService.onSaveProposal = { ... }` assignment, add:

```swift
        // Stage 3 (U5): the popup's Unlock button. Activation alone is not enough —
        // if the window was already open on the unlock screen, `UnlockView.onAppear`
        // will not re-fire, so the Touch ID prompt has to be requested explicitly.
        //
        // When the window was closed instead, `MainWindowActivator.request()` opens it
        // asynchronously and `UnlockView.onAppear` runs its own auto-prompt; this
        // notification arrives before any observer exists and is harmlessly dropped, so
        // exactly one prompt is shown in both paths.
        extensionBridgeService.onUnlockRequested = {
            DispatchQueue.main.async {
                MainWindowActivator.request()
                NotificationCenter.default.post(name: .requestDeviceUnlockPrompt, object: nil)
            }
        }
```

- [ ] **Step 4: Build and run the full app suite**

Run: `./scripts/generate.sh && xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' 2>&1 | grep -E "error:|with [1-9][0-9]* failure|TEST FAILED|TEST SUCCEEDED" | head`

Expected: `** TEST SUCCEEDED **`, no failures. There is no automated test for this task: it is three declarations of glue whose behaviour is window activation and a system biometric sheet, neither of which is reachable from XCTest. It is covered by the manual checklist in Task 5.

- [ ] **Step 5: Commit**

```bash
git add MyPass/App/MainWindowActivator.swift MyPass/UI/Unlock/UnlockView.swift MyPass/MyPassApp.swift
git commit -m "feat(app): present unlock screen and Touch ID prompt on extension request"
```

---

### Task 4: Extension — routing and the Unlock button

Roadmap items `U6` and `U7`. They are one task because a one-line `knownTypes` change cannot be reviewed or rejected independently of the button that uses it.

**Files:**
- Modify: `ChromeExtension/background.js:132`
- Modify: `ChromeExtension/popup.html:150-155`
- Modify: `ChromeExtension/popup.js`
- Create: `ChromeExtension/tests/unlockButton.test.js`
- Modify: `scripts/test.sh:29-31`

**Interfaces:**
- Consumes: the `requestUnlock` / `unlockPresented` / `unlockNotNeeded` wire types (Task 1).
- Produces (exported from `popup.js` for tests): `shouldShowUnlockButton(pairingSecret) -> boolean`, `classifyRequestUnlockResponse(response) -> 'presented' | 'notNeeded' | 'unavailable'`, `UNLOCK_BUTTON_LABEL`, `POPUP_PAIRING_STORAGE_KEY`.

- [ ] **Step 1: Write the failing test**

Create `ChromeExtension/tests/unlockButton.test.js`:

```js
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');

const popup = require('../popup.js');

// Visibility is driven purely by whether this browser holds a pairing secret.
assert.strictEqual(popup.shouldShowUnlockButton('some-secret'), true);
assert.strictEqual(popup.shouldShowUnlockButton(''), false);
assert.strictEqual(popup.shouldShowUnlockButton(null), false);
assert.strictEqual(popup.shouldShowUnlockButton(undefined), false);

// Response classification drives what the popup does next.
assert.strictEqual(popup.classifyRequestUnlockResponse({ type: 'unlockPresented' }), 'presented');
assert.strictEqual(popup.classifyRequestUnlockResponse({ type: 'unlockNotNeeded' }), 'notNeeded');
assert.strictEqual(popup.classifyRequestUnlockResponse({ type: 'pairingRequired' }), 'unavailable');
assert.strictEqual(popup.classifyRequestUnlockResponse({ type: 'error' }), 'unavailable');
assert.strictEqual(popup.classifyRequestUnlockResponse(null), 'unavailable');
assert.strictEqual(popup.classifyRequestUnlockResponse(undefined), 'unavailable');

assert.strictEqual(typeof popup.UNLOCK_BUTTON_LABEL, 'string');
assert.ok(popup.UNLOCK_BUTTON_LABEL.length > 0);

// The popup reads the pairing secret straight from storage, so its key must match the
// one background.js writes. These are separate files with no shared module, so assert
// the literal rather than trusting a comment.
const backgroundSource = fs.readFileSync(path.join(__dirname, '..', 'background.js'), 'utf8');
assert.ok(
  backgroundSource.includes(`"${popup.POPUP_PAIRING_STORAGE_KEY}"`) ||
    backgroundSource.includes(`'${popup.POPUP_PAIRING_STORAGE_KEY}'`),
  'popup.js and background.js must agree on the pairing-secret storage key'
);

// requestUnlock must be relayed, not dropped as an unknown type.
assert.ok(backgroundSource.includes('"requestUnlock"'), 'background.js knownTypes must include requestUnlock');

// The button must exist in the markup with the id popup.js wires up.
const popupHtml = fs.readFileSync(path.join(__dirname, '..', 'popup.html'), 'utf8');
assert.ok(popupHtml.includes('id="locked-unlock-btn"'), 'locked panel must contain the unlock button');

console.log('unlockButton.test.js OK');
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `node ChromeExtension/tests/unlockButton.test.js`

Expected: FAIL — `popup.shouldShowUnlockButton is not a function`.

- [ ] **Step 3: Add `requestUnlock` to the background relay**

In `background.js` line 132, extend `knownTypes`:

```js
// Replace:
  const knownTypes = ["getCredentials", "fillCredential", "proposeSaveLogin", "startPairing", "completePairing"];

// With:
  const knownTypes = ["getCredentials", "fillCredential", "proposeSaveLogin", "startPairing", "completePairing", "requestUnlock"];
```

No other background change is needed: the generic relay path already attaches the pairing secret via `attachPairingField`.

- [ ] **Step 4: Add the button to the locked panel**

In `popup.html`, replace the locked panel (lines 150-155):

```html
    <section id="locked-panel" hidden>
      <img class="brand-key" src="icons/icon32.png" width="32" height="32" alt="">
      <h1 class="panel-title" id="locked-title"></h1>
      <p class="panel-helper" id="locked-helper"></p>
      <button id="locked-unlock-btn" type="button" class="btn-primary" hidden>Unlock MyPass</button>
      <button id="locked-retry-btn" type="button" class="btn-secondary">Retry</button>
    </section>
```

Retry moves from `btn-primary` to `btn-secondary` so the new button is the visual primary action. Both classes already exist in `popup.html`'s inline stylesheet (the shared rule at line 43-44 and `.btn-secondary` at line 57), and the app-unavailable panel already pairs them the same way at lines 161-162 — no CSS change is needed.

- [ ] **Step 5: Add the pure functions and wiring to `popup.js`**

Near the other top-level constants (beside `LOCKED_TITLE_TEXT`), add:

```js
const UNLOCK_BUTTON_LABEL = 'Unlock MyPass';
// Must match PAIRING_STORAGE_KEY in background.js — asserted by unlockButton.test.js.
const POPUP_PAIRING_STORAGE_KEY = 'pairingSecret';
```

Next to `classifyGetCredentialsResponse`, add:

```js
function shouldShowUnlockButton(pairingSecret) {
  return typeof pairingSecret === 'string' && pairingSecret.length > 0;
}

function classifyRequestUnlockResponse(response) {
  if (!response) return 'unavailable';
  if (response.type === 'unlockPresented') return 'presented';
  if (response.type === 'unlockNotNeeded') return 'notNeeded';
  return 'unavailable';
}
```

Inside the `if (typeof document !== 'undefined') { ... }` block, add the element lookup beside the existing `lockedRetryBtn` lookup:

```js
  const lockedUnlockBtn = document.getElementById('locked-unlock-btn');
```

Replace the `kind === 'locked'` branch of `handleCredentialsResponse`:

```js
// Replace:
    if (kind === 'locked') {
      showPanel('locked');
      lockedRetryBtn.onclick = () => queryCredentials(url);
      return;
    }

// With:
    if (kind === 'locked') {
      showPanel('locked');
      lockedRetryBtn.onclick = () => queryCredentials(url);
      lockedUnlockBtn.textContent = UNLOCK_BUTTON_LABEL;
      lockedUnlockBtn.onclick = () => requestUnlock(url);
      chrome.storage.local.get(POPUP_PAIRING_STORAGE_KEY, (stored) => {
        lockedUnlockBtn.hidden = !shouldShowUnlockButton(stored[POPUP_PAIRING_STORAGE_KEY]);
      });
      return;
    }
```

Add `requestUnlock` beside `queryCredentials`:

```js
  function requestUnlock(url) {
    chrome.runtime.sendMessage({ type: 'requestUnlock' }, (response) => {
      // 'presented' needs no handling: MyPass is taking focus, which closes this popup.
      if (classifyRequestUnlockResponse(response) === 'notNeeded') {
        queryCredentials(url);
      }
    });
  }
```

Add the four new names to `module.exports`:

```js
    shouldShowUnlockButton,
    classifyRequestUnlockResponse,
    UNLOCK_BUTTON_LABEL,
    POPUP_PAIRING_STORAGE_KEY,
```

- [ ] **Step 6: Wire the test into `scripts/test.sh` — and the two orphaned suites**

`scripts/test.sh` currently runs only three of the five JS test files. `letter-avatar.test.js`
and `popup-fallback.test.js` were added by earlier shipped plans and never wired in, so they
have not run since. Both cover `popup.js`, the file this task modifies, which makes them
exactly the regression net this change needs. Wire all three.

Replace lines 29-31:

```bash
# Replace:
  node ChromeExtension/tests/background.manifest.test.js
  node ChromeExtension/tests/formDetection.test.js
  node ChromeExtension/tests/pairing.test.js

# With:
  node ChromeExtension/tests/background.manifest.test.js
  node ChromeExtension/tests/formDetection.test.js
  node ChromeExtension/tests/pairing.test.js
  node ChromeExtension/tests/letter-avatar.test.js
  node ChromeExtension/tests/popup-fallback.test.js
  node ChromeExtension/tests/unlockButton.test.js
```

If either newly-wired suite fails, stop and report it rather than editing the test to pass:
it means a regression landed while the suite was dark, and that is a separate finding.

- [ ] **Step 7: Run the tests to verify they pass**

Run: `node ChromeExtension/tests/unlockButton.test.js && node ChromeExtension/tests/pairing.test.js && node ChromeExtension/tests/popup-fallback.test.js && node ChromeExtension/tests/letter-avatar.test.js`

Expected: all four print `OK`, no assertion errors. The last three confirm no regression in the popup module they share.

- [ ] **Step 8: Commit**

```bash
git add ChromeExtension/background.js ChromeExtension/popup.html ChromeExtension/popup.js \
        ChromeExtension/tests/unlockButton.test.js scripts/test.sh
git commit -m "feat(chrome): add Unlock MyPass button to the locked popup panel"
```

---

### Task 5: Manual e2e checklist in `RUN.md`

Roadmap item `U8`.

**Files:**
- Modify: `RUN.md`

- [ ] **Step 1: Add the checklist**

`RUN.md` is Ukrainian — do not add an English duplicate. Append these bullets to the existing Chrome extension section:

```markdown
### Розблокування з попапа розширення

- Заблокуйте сховище, відкрийте попап на будь-якому сайті — має з'явитися кнопка **Unlock MyPass** поряд із Retry.
- Натисніть її: MyPass виходить на передній план з екраном розблокування, одразу з'являється запит Touch ID. Попап Chrome при цьому закривається — це очікувано.
- Розблокуйте, поверніться до Chrome, відкрийте попап знову — логіни на місці.
- Вимкніть Touch ID у налаштуваннях і повторіть: вікно так само виходить наперед, але лише з полем пароля, без помилок.
- Натисніть кнопку двічі поспіль швидко — має з'явитися рівно один запит Touch ID, не два.
- Приберіть пару (Settings → Browser → видалити браузер), заблокуйте сховище, відкрийте попап — кнопки **Unlock MyPass** не повинно бути взагалі.
```

- [ ] **Step 2: Verify the file stays Ukrainian-only**

Run: `grep -n "Unlock MyPass" RUN.md`

Expected: matches appear only inside the Ukrainian section above, as UI-string references. No English prose paragraphs were added.

- [ ] **Step 3: Commit**

```bash
git add RUN.md
git commit -m "docs: add Ukrainian manual checklist for unlock from popup"
```

---

### Task 6: Full verification

Roadmap item `U9`.

**Files:** none (verification only).

- [ ] **Step 1: Run the whole suite**

Run: `./scripts/test.sh 2>&1 | tail -40`

Expected: `** TEST SUCCEEDED **` for the MyPass scheme, 0 failures across `MyPassKit` / `SyncKit` / `ExtensionBridgeKit`, and every `ChromeExtension/tests/*.js` printing `OK`.

**Two known traps when reading this result:**

1. Never judge the run by `./scripts/test.sh | tail` alone — a pipeline reports `tail`'s exit code, not the script's. Check the text for `TEST SUCCEEDED` and for `with [1-9] failure`.
2. If `CitadelDependencySmokeTests` fails on a missing `/tmp/citadel_smoke_key`, that is an unrelated environment gap, not this work. `scripts/test.sh` runs under `set -e`, so it aborts there before the JS tests run. Regenerate the fixture and re-run:
   `ssh-keygen -t ed25519 -N "correct-horse-battery-staple" -f /tmp/citadel_smoke_key -C "smoketest@mypass"`

- [ ] **Step 2: Confirm the master password never crosses the bridge**

Run: `grep -rn "password" ChromeExtension/popup.js ChromeExtension/popup.html | grep -vi "pairing"`

Expected: no match introducing a password input, field, or variable for the master password. This is acceptance criterion 7 and the whole point of the design — check it explicitly rather than assuming.

- [ ] **Step 3: Walk the manual checklist**

Work through every bullet added to `RUN.md` in Task 5 against a real build with the extension loaded unpacked. All six must pass.

- [ ] **Step 4: Update the roadmap**

Tick `U3`–`U9` in `docs/implementation/ROADMAP.md`, record the commits, mark Gate 3 passed, and update the progress table.

- [ ] **Step 5: Commit**

```bash
git add docs/implementation/ROADMAP.md
git commit -m "docs: mark Stage 3 complete in roadmap"
```

---

## Self-Review

### Spec coverage checklist

| Spec requirement | Task |
|------------------|------|
| Extension never unlocks; app presents its own UI | Task 2 (callback only), Task 3 (no new UI) |
| No password field in the popup | Task 4; verified in Task 6 Step 2 |
| Pairing required; unpaired → `.pairingRequired`, no callback | Task 2 |
| Unpaired popup shows no button | Task 4 (`shouldShowUnlockButton`) |
| Pairing readable while locked (Keychain-backed) | Task 2 — no code needed, `pairingManager` is already vault-independent |
| `.requestUnlock` request type | Task 1 |
| `.unlockPresented` / `.unlockNotNeeded` responses | Task 1 |
| `.unlockNotNeeded` → popup re-queries | Task 4 (`requestUnlock`) |
| Locked-gate exception as a predicate, not a special case | Task 1 (`isAnswerableWhileLocked`), Task 2 (guard) |
| Fresh Touch ID prompt on request | Task 3 |
| Touch ID unenrolled → no-op, password field only | Task 3 (`canShowDeviceUnlockButton` guard) |
| 2-second debounce | Task 2 |
| Check order: pairing → unlocked → debounce → activate | Task 2 Step 5, asserted by `testUnlockNotNeededWinsOverDebounce` |
| Popup is fire-and-forget, no waiting state | Task 4 (`'presented'` deliberately unhandled) |
| `requestUnlock` in `knownTypes` | Task 4 |
| Manual checklist, Ukrainian | Task 5 |
| Acceptance criteria 1-8 | Tasks 2, 4 (automated); Task 5/6 (manual) |

### Intentional deviations

- **`U6` and `U7` are merged into Task 4.** A one-line `knownTypes` addition has no independently testable deliverable and no reviewer would accept or reject it apart from the button that depends on it.
- **Task 3 ships without an automated test.** Its three changes are a notification name, an `onReceive` modifier, and a closure assignment; the observable behaviour is window activation and a system biometric sheet, neither reachable from XCTest. Covered manually in Task 5 and by the full-suite build in Task 3 Step 4. Fabricating a test that asserts a closure is non-nil would add maintenance cost without evidence.
- **The debounce clock is injected rather than mocked globally.** `init(vaultSession:pairingManager:now:)` takes a defaulted `now` closure so existing call sites are untouched and the debounce tests need no sleeping.
- **Two orphaned JS suites get wired into `scripts/test.sh`** (Task 4 Step 6). Strictly
  outside this feature, but they cover the very file this task edits and were silently
  not running; leaving them dark while relying on them for regression cover in Step 7
  would be self-deception.
- **`popup.js` re-declares the pairing storage key** instead of importing it from `background.js`; the two files share no module system in this extension. The duplication is guarded by an assertion in `unlockButton.test.js` that reads `background.js` source.

---

**Plan complete.** Execute with `superpowers:executing-plans` (inline) or `superpowers:subagent-driven-development` (fresh subagent per task).
