# Chrome Extension Passkeys (Piece C) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let MyPass act as the WebAuthn authenticator for Chrome via `chrome.webAuthenticationProxy`, so a user can register (`navigator.credentials.create`) and sign in with (`navigator.credentials.get`) passkeys stored in their KDBX vault, with explicit confirmation on every ceremony and zero private-key material ever reaching the extension.

**Architecture:** `background.js` registers `chrome.webAuthenticationProxy` listeners at service-worker load and manages an opt-in attach/detach lifecycle keyed on a `chrome.storage.local` flag plus a live `getPasskeyProxyStatus` check. Each ceremony is a **two-phase synchronous exchange** over the existing native-messaging bridge — this plan's answer to the spec's open "push vs. long-poll" question: **neither**. Phase 1 (`passkeyCreate`/`passkeyGet`) is a fast, synchronous parse-and-match call — the app parses the WebAuthn JSON, validates ES256, matches vault entries by relying-party ID, and replies immediately with routing data (no vault touch, no crypto yet). `background.js` then holds Chrome's `onCreateRequest`/`onGetRequest` callback open in JS memory (a `Map` keyed by `requestId`, with a 120s watchdog) while it opens the popup for user confirmation. Phase 2 (`passkeyCreateConfirm`/`passkeyGetApprove`), triggered by the user's Save/Approve click in the popup, is a second synchronous call that performs the actual ES256 key generation (create) or assertion signing (get), writes `KPEX_PASSKEY_*` fields to the chosen KDBX entry, and returns the finished `responseJson` in the same round trip. `background.js` then calls `completeCreateRequest`/`completeGetRequest` and clears its pending-request bookkeeping. This design needs **no changes to the native-messaging transport** — every bridge message stays a plain one-shot request/response, exactly like `fillCredential` today; only `background.js`'s own JS event loop bridges the real-world wait between phase 1 and phase 2.

**Tech Stack:** Swift + CryptoKit (`P256.Signing.PrivateKey/PublicKey`) for ES256 key generation, PEM export, and ECDSA signing; a small hand-rolled CBOR/COSE encoder (no CBOR library exists anywhere in this repo — confirmed by search); vanilla JavaScript (`chrome.webAuthenticationProxy`, Chrome 115+); XCTest; Node `assert`.

## Global Constraints

- Private keys **never** leave the app. The extension only ever sees WebAuthn ceremony JSON (`requestDetailsJson` in / `responseJson` or `error` out) and routing metadata (RP ID, entry summaries). PEM material is written to KDBX only inside the phase-2 confirm handler, after explicit user action.
- Passkeys attach to existing **Login** entries via `KPEX_PASSKEY_*` custom fields — no new `EntryType`, no Secure Enclave, ES256 (`alg: -7`) only. A create request whose `pubKeyCredParams` doesn't include ES256 fails with a `NotSupportedError`-class error before any key is generated.
- **Consent gates:** Create always shows a confirm panel before any vault write; a second create on an entry that already has passkey fields shows **Replace passkey?** before overwrite. Get always requires an explicit **Approve** click — never silent auto-sign, even with exactly one match.
- The proxy is **opt-in, default off** (`passkeyProxyEnabled`, mirrored in both `chrome.storage.local` on the extension side and `UserDefaults` on the app side via the existing `@AppStorage` convention). `attach()` only when unlocked + paired; vault lock or pairing loss triggers `detach()` and cancels any pending ceremony with a `NotAllowedError`-class completion.
- `getPasskeyProxyStatus` is the one bridge message that must answer **even while the vault is locked** (it exists specifically to report lock state) — it is the single exception to `ExtensionBridgeService.handle`'s blanket "locked → `.locked`" gate.
- `onIsUvpaaRequest` replies `isUvpaa: true` only while attached **and** unlocked; while attached-but-locked, reply `isUvpaa: false` without claiming attach; while detached, don't intercept it at all (Chrome uses the real platform authenticator).
- A second concurrent create/get while one is already pending is rejected immediately with `AbortError` — no queueing in MVP.
- Show RP ID and origin hostname on every popup confirm panel (phishing resistance) — this is a hard requirement, not a nice-to-have.
- `KPEX_PASSKEY_*` field names and PEM (PKCS#8) format must match KeePassXC's own convention exactly, since that's the entire point of storing them this way — verify cross-compatibility by confirming the field-name spelling in this plan matches the spec's table verbatim (it does, copy them exactly, do not abbreviate or rename).
- This plan is independent of the piece A (TOTP autofill) and piece B (2FA setup) plans — some anchors below (e.g. `ExtensionCredentialSummary`'s exact field list, `background.js`'s `knownTypes`/listener shape) may look different if those plans already landed. Each task notes this and tells you to adapt the anchor to whatever the current shape is, preserving every existing field/case rather than replacing it.

## File Structure

| Path | Responsibility |
|------|----------------|
| `Packages/ExtensionBridgeKit/Sources/ExtensionBridgeKit/ExtensionBridgeMessages.swift` | New passkey request/response cases, `PasskeyErrorDetails`, `hasPasskey` on summary |
| `Packages/ExtensionBridgeKit/Tests/ExtensionBridgeKitTests/ExtensionBridgeMessagesTests.swift` | Encode/decode coverage |
| `MyPass/Models/KdbxEntry+Convenience.swift` | Widen `setFieldValue`/`fieldValue` from `private` to `internal` so a sibling file can reuse them |
| `MyPass/Models/KdbxEntry+Passkey.swift` (new) | `KPEX_PASSKEY_*` field accessors + `clearPasskey()` |
| `MyPassTests/KdbxEntryPasskeyTests.swift` (new) | Field round-trip tests |
| `MyPass/State/ExtensionBridge/PasskeyCeremony.swift` (new) | CBOR/COSE encoder, WebAuthn JSON parse/build, ES256 key generation and signing |
| `MyPassTests/PasskeyCeremonyTests.swift` (new) | Fixture-driven parse + self-verifying signature tests |
| `MyPass/State/ExtensionBridge/ExtensionBridgeService.swift` | Passkey message handlers, in-memory pending-ceremony maps, `hasPasskey` in `getCredentials` |
| `MyPass/State/ExtensionBridge/LoopbackServer.swift` | Token extraction for new request cases |
| `MyPassTests/ExtensionBridgeServiceTests.swift` | Passkey handler tests (happy path, cancel, locked, pairingRequired, unsupported algorithm, replace guard) |
| `MyPass/UI/Settings/BrowserSettingsPane.swift` | "Use MyPass for Chrome passkeys" toggle |
| `MyPass/UI/EntryDetail/EntryDetailView.swift` | Read-only Passkey section + "Remove passkey" destructive confirm |
| `ChromeExtension/manifest.json` | `webAuthenticationProxy` permission, `minimum_chrome_version: 115` |
| `ChromeExtension/background.js` | Proxy event listeners, attach/detach lifecycle, pending-ceremony `Map`, watchdog, `completeCreateRequest`/`completeGetRequest`/`completeIsUvpaaRequest` |
| `ChromeExtension/popup.html` / `popup.js` | Passkey confirm/picker/locked/unattached panels, settings toggle, session-pending rehydration |
| `ChromeExtension/tests/passkeyProxy.test.js` (new) | Attach gating, pending-state, cancel/timeout, second-request-rejected tests |
| `ChromeExtension/tests/fixtures/webauthn-create.html`, `webauthn-get.html` (new) | Manual e2e fixtures |
| `RUN.md` | Manual e2e checklist bullets (Ukrainian) |
| `scripts/test.sh` | Add the new JS test file |

---

### Task 1: ExtensionBridgeKit — passkey wire protocol

**Files:**
- Modify: `Packages/ExtensionBridgeKit/Sources/ExtensionBridgeKit/ExtensionBridgeMessages.swift`
- Test: `Packages/ExtensionBridgeKit/Tests/ExtensionBridgeKitTests/ExtensionBridgeMessagesTests.swift`

**Interfaces:**
- Produces (requests): `.getPasskeyProxyStatus(token:pairing:)`, `.setPasskeyProxyEnabled(token:enabled:pairing:)`, `.passkeyCreate(token:requestId:requestDetailsJson:originUrl:pairing:)`, `.passkeyCreateConfirm(token:requestId:entryId:replace:pairing:)`, `.passkeyGet(token:requestId:requestDetailsJson:originUrl:pairing:)`, `.passkeyGetApprove(token:requestId:entryId:pairing:)`, `.passkeyCancel(token:requestId:pairing:)`.
- Produces (responses): `.passkeyProxyStatus(unlocked:paired:attachAllowed:)`, `.passkeyProxyEnabled(enabled:)`, `.passkeyCreatePending(requestId:rpId:rpName:matches:)`, `.passkeyCreateComplete(requestId:responseJson:error:)`, `.passkeyGetPending(requestId:rpId:matches:)`, `.passkeyGetComplete(requestId:responseJson:error:)`, `.passkeyCancelled(requestId:)`.
- Produces (types): `public struct PasskeyErrorDetails: Codable, Equatable { public let name: String; public let message: String }` — mirrors Chrome's `DOMExceptionDetails` shape exactly (`name`/`message`) so `background.js` can pass it straight through to `completeCreateRequest`/`completeGetRequest`'s `error` field with no remapping. `ExtensionCredentialSummary` gains `hasPasskey: Bool`.
- `requestId` is `Int` throughout — Chrome's `chrome.webAuthenticationProxy` API defines it as a `number` (confirmed against `https://developer.chrome.com/docs/extensions/reference/api/webAuthenticationProxy`), so it must round-trip as a JSON number, not a string, end to end.

- [ ] **Step 1: Write failing tests**

Open `Packages/ExtensionBridgeKit/Tests/ExtensionBridgeKitTests/ExtensionBridgeMessagesTests.swift`, confirm its `jsonObject(from:)` helper signature, then append:

```swift
func testGetPasskeyProxyStatusRoundTrips() throws {
    let request = ExtensionBridgeRequest.getPasskeyProxyStatus(token: "tok", pairing: "pair-secret")
    let data = try JSONEncoder().encode(request)
    XCTAssertEqual(try JSONDecoder().decode(ExtensionBridgeRequest.self, from: data), request)
    let json = try jsonObject(from: data)
    XCTAssertEqual(json["type"] as? String, "getPasskeyProxyStatus")
}

func testPasskeyProxyStatusResponseRoundTrips() throws {
    let response = ExtensionBridgeResponse.passkeyProxyStatus(unlocked: true, paired: true, attachAllowed: true)
    let data = try JSONEncoder().encode(response)
    XCTAssertEqual(try JSONDecoder().decode(ExtensionBridgeResponse.self, from: data), response)
    let json = try jsonObject(from: data)
    XCTAssertEqual(json["type"] as? String, "passkeyProxyStatus")
    XCTAssertEqual(json["unlocked"] as? Bool, true)
    XCTAssertEqual(json["paired"] as? Bool, true)
    XCTAssertEqual(json["attachAllowed"] as? Bool, true)
}

func testSetPasskeyProxyEnabledRoundTrips() throws {
    let request = ExtensionBridgeRequest.setPasskeyProxyEnabled(token: "tok", enabled: true, pairing: "pair-secret")
    let data = try JSONEncoder().encode(request)
    XCTAssertEqual(try JSONDecoder().decode(ExtensionBridgeRequest.self, from: data), request)
    let response = ExtensionBridgeResponse.passkeyProxyEnabled(enabled: true)
    let responseData = try JSONEncoder().encode(response)
    XCTAssertEqual(try JSONDecoder().decode(ExtensionBridgeResponse.self, from: responseData), response)
}

func testPasskeyCreateRoundTripsWithRequestIdAsNumber() throws {
    let request = ExtensionBridgeRequest.passkeyCreate(
        token: "tok", requestId: 42, requestDetailsJson: "{\"challenge\":\"AA\"}", originUrl: "https://example.com", pairing: "pair-secret"
    )
    let data = try JSONEncoder().encode(request)
    XCTAssertEqual(try JSONDecoder().decode(ExtensionBridgeRequest.self, from: data), request)
    let json = try jsonObject(from: data)
    XCTAssertEqual(json["requestId"] as? Int, 42, "requestId must serialize as a JSON number, not a string")
    XCTAssertEqual(json["originUrl"] as? String, "https://example.com")
}

func testPasskeyCreateConfirmRoundTripsWithAndWithoutEntryId() throws {
    let withEntry = ExtensionBridgeRequest.passkeyCreateConfirm(token: "tok", requestId: 1, entryId: "entry-1", replace: true, pairing: "p")
    let dataWithEntry = try JSONEncoder().encode(withEntry)
    XCTAssertEqual(try JSONDecoder().decode(ExtensionBridgeRequest.self, from: dataWithEntry), withEntry)

    let withoutEntry = ExtensionBridgeRequest.passkeyCreateConfirm(token: "tok", requestId: 1, entryId: nil, replace: false, pairing: "p")
    let dataWithoutEntry = try JSONEncoder().encode(withoutEntry)
    XCTAssertEqual(try JSONDecoder().decode(ExtensionBridgeRequest.self, from: dataWithoutEntry), withoutEntry)
}

func testPasskeyGetAndGetApproveRoundTrip() throws {
    let get = ExtensionBridgeRequest.passkeyGet(token: "tok", requestId: 7, requestDetailsJson: "{}", originUrl: "https://example.com", pairing: "p")
    XCTAssertEqual(try JSONDecoder().decode(ExtensionBridgeRequest.self, from: try JSONEncoder().encode(get)), get)

    let approve = ExtensionBridgeRequest.passkeyGetApprove(token: "tok", requestId: 7, entryId: "entry-1", pairing: "p")
    XCTAssertEqual(try JSONDecoder().decode(ExtensionBridgeRequest.self, from: try JSONEncoder().encode(approve)), approve)
}

func testPasskeyCancelRoundTripsAndCancelledResponseRoundTrips() throws {
    let request = ExtensionBridgeRequest.passkeyCancel(token: "tok", requestId: 3, pairing: "p")
    XCTAssertEqual(try JSONDecoder().decode(ExtensionBridgeRequest.self, from: try JSONEncoder().encode(request)), request)

    let response = ExtensionBridgeResponse.passkeyCancelled(requestId: 3)
    let data = try JSONEncoder().encode(response)
    XCTAssertEqual(try JSONDecoder().decode(ExtensionBridgeResponse.self, from: data), response)
    let json = try jsonObject(from: data)
    XCTAssertEqual(json["type"] as? String, "passkeyCancelled")
    XCTAssertEqual(json["requestId"] as? Int, 3)
}

func testPasskeyCreatePendingIncludesMatchesWithHasPasskey() throws {
    let summary = ExtensionCredentialSummary(id: "1", title: "Example", username: "alice", hasPasskey: true)
    let response = ExtensionBridgeResponse.passkeyCreatePending(requestId: 1, rpId: "example.com", rpName: "Example", matches: [summary])
    let data = try JSONEncoder().encode(response)
    XCTAssertEqual(try JSONDecoder().decode(ExtensionBridgeResponse.self, from: data), response)
    let json = try jsonObject(from: data)
    let matches = try XCTUnwrap(json["matches"] as? [[String: Any]])
    XCTAssertEqual(matches.first?["hasPasskey"] as? Bool, true)
}

func testPasskeyCreateCompleteRoundTripsWithResponseJsonOrError() throws {
    let success = ExtensionBridgeResponse.passkeyCreateComplete(requestId: 1, responseJson: "{\"id\":\"abc\"}", error: nil)
    XCTAssertEqual(try JSONDecoder().decode(ExtensionBridgeResponse.self, from: try JSONEncoder().encode(success)), success)

    let failure = ExtensionBridgeResponse.passkeyCreateComplete(
        requestId: 1, responseJson: nil, error: PasskeyErrorDetails(name: "NotSupportedError", message: "MyPass passkeys require ES256")
    )
    let failureData = try JSONEncoder().encode(failure)
    XCTAssertEqual(try JSONDecoder().decode(ExtensionBridgeResponse.self, from: failureData), failure)
    let json = try jsonObject(from: failureData)
    let error = try XCTUnwrap(json["error"] as? [String: Any])
    XCTAssertEqual(error["name"] as? String, "NotSupportedError")
}

func testPasskeyGetPendingAndCompleteRoundTrip() throws {
    let pending = ExtensionBridgeResponse.passkeyGetPending(requestId: 2, rpId: "example.com", matches: [])
    XCTAssertEqual(try JSONDecoder().decode(ExtensionBridgeResponse.self, from: try JSONEncoder().encode(pending)), pending)

    let complete = ExtensionBridgeResponse.passkeyGetComplete(requestId: 2, responseJson: "{\"id\":\"abc\"}", error: nil)
    XCTAssertEqual(try JSONDecoder().decode(ExtensionBridgeResponse.self, from: try JSONEncoder().encode(complete)), complete)
}
```

Also find every existing `ExtensionCredentialSummary(id:title:username:...)` call site in this test file and add `hasPasskey:` to each (`false` unless the test needs a passkey-bearing summary) — the initializer is gaining a required parameter. If a prior piece-A run already added `hasTotp:` to this initializer, add `hasPasskey:` alongside it, keep both.

- [ ] **Step 2: Run and confirm failure**

Run: `cd Packages/ExtensionBridgeKit && swift test`
Expected: build fails — none of the new cases/types exist yet.

- [ ] **Step 3: Implement**

In `Packages/ExtensionBridgeKit/Sources/ExtensionBridgeKit/ExtensionBridgeMessages.swift`:

Add the new request cases to `ExtensionBridgeRequest` (append after the existing cases, order doesn't matter functionally):

```swift
    case getPasskeyProxyStatus(token: String, pairing: String?)
    case setPasskeyProxyEnabled(token: String, enabled: Bool, pairing: String?)
    case passkeyCreate(token: String, requestId: Int, requestDetailsJson: String, originUrl: String, pairing: String?)
    case passkeyCreateConfirm(token: String, requestId: Int, entryId: String?, replace: Bool, pairing: String?)
    case passkeyGet(token: String, requestId: Int, requestDetailsJson: String, originUrl: String, pairing: String?)
    case passkeyGetApprove(token: String, requestId: Int, entryId: String, pairing: String?)
    case passkeyCancel(token: String, requestId: Int, pairing: String?)
```

Add the new `CodingKeys` cases needed (`enabled`, `requestId`, `requestDetailsJson`, `originUrl`, `entryId`, `replace`, `unlocked`, `paired`, `attachAllowed`, `rpId`, `rpName`, `matches`, `responseJson`, `error`, `name` — note `entryId` may already exist if piece B's `proposeSaveTotp` landed first; don't duplicate it):

```swift
    private enum CodingKeys: String, CodingKey {
        case type, token, url, id, username, password, pairing, browser, code
        case enabled, requestId, requestDetailsJson, originUrl, entryId, replace
        case unlocked, paired, attachAllowed, rpId, rpName, matches, responseJson, error, name, message
    }
```

(If `entryId` and/or `message` already exist in this enum from a prior plan, don't add them twice — just make sure every key listed above is present exactly once.)

Add decode arms (anywhere inside the `switch type` in `ExtensionBridgeRequest.init(from:)`):

```swift
        case "getPasskeyProxyStatus":
            let pairing = try container.decodeIfPresent(String.self, forKey: .pairing)
            self = .getPasskeyProxyStatus(token: token, pairing: pairing)
        case "setPasskeyProxyEnabled":
            let enabled = try container.decode(Bool.self, forKey: .enabled)
            let pairing = try container.decodeIfPresent(String.self, forKey: .pairing)
            self = .setPasskeyProxyEnabled(token: token, enabled: enabled, pairing: pairing)
        case "passkeyCreate":
            let requestId = try container.decode(Int.self, forKey: .requestId)
            let requestDetailsJson = try container.decode(String.self, forKey: .requestDetailsJson)
            let originUrl = try container.decode(String.self, forKey: .originUrl)
            let pairing = try container.decodeIfPresent(String.self, forKey: .pairing)
            self = .passkeyCreate(token: token, requestId: requestId, requestDetailsJson: requestDetailsJson, originUrl: originUrl, pairing: pairing)
        case "passkeyCreateConfirm":
            let requestId = try container.decode(Int.self, forKey: .requestId)
            let entryId = try container.decodeIfPresent(String.self, forKey: .entryId)
            let replace = try container.decodeIfPresent(Bool.self, forKey: .replace) ?? false
            let pairing = try container.decodeIfPresent(String.self, forKey: .pairing)
            self = .passkeyCreateConfirm(token: token, requestId: requestId, entryId: entryId, replace: replace, pairing: pairing)
        case "passkeyGet":
            let requestId = try container.decode(Int.self, forKey: .requestId)
            let requestDetailsJson = try container.decode(String.self, forKey: .requestDetailsJson)
            let originUrl = try container.decode(String.self, forKey: .originUrl)
            let pairing = try container.decodeIfPresent(String.self, forKey: .pairing)
            self = .passkeyGet(token: token, requestId: requestId, requestDetailsJson: requestDetailsJson, originUrl: originUrl, pairing: pairing)
        case "passkeyGetApprove":
            let requestId = try container.decode(Int.self, forKey: .requestId)
            let entryId = try container.decode(String.self, forKey: .entryId)
            let pairing = try container.decodeIfPresent(String.self, forKey: .pairing)
            self = .passkeyGetApprove(token: token, requestId: requestId, entryId: entryId, pairing: pairing)
        case "passkeyCancel":
            let requestId = try container.decode(Int.self, forKey: .requestId)
            let pairing = try container.decodeIfPresent(String.self, forKey: .pairing)
            self = .passkeyCancel(token: token, requestId: requestId, pairing: pairing)
```

Add matching encode arms inside `ExtensionBridgeRequest.encode(to:)`:

```swift
        case .getPasskeyProxyStatus(let token, let pairing):
            try container.encode("getPasskeyProxyStatus", forKey: .type)
            try container.encode(token, forKey: .token)
            try container.encodeIfPresent(pairing, forKey: .pairing)
        case .setPasskeyProxyEnabled(let token, let enabled, let pairing):
            try container.encode("setPasskeyProxyEnabled", forKey: .type)
            try container.encode(token, forKey: .token)
            try container.encode(enabled, forKey: .enabled)
            try container.encodeIfPresent(pairing, forKey: .pairing)
        case .passkeyCreate(let token, let requestId, let requestDetailsJson, let originUrl, let pairing):
            try container.encode("passkeyCreate", forKey: .type)
            try container.encode(token, forKey: .token)
            try container.encode(requestId, forKey: .requestId)
            try container.encode(requestDetailsJson, forKey: .requestDetailsJson)
            try container.encode(originUrl, forKey: .originUrl)
            try container.encodeIfPresent(pairing, forKey: .pairing)
        case .passkeyCreateConfirm(let token, let requestId, let entryId, let replace, let pairing):
            try container.encode("passkeyCreateConfirm", forKey: .type)
            try container.encode(token, forKey: .token)
            try container.encode(requestId, forKey: .requestId)
            try container.encodeIfPresent(entryId, forKey: .entryId)
            try container.encode(replace, forKey: .replace)
            try container.encodeIfPresent(pairing, forKey: .pairing)
        case .passkeyGet(let token, let requestId, let requestDetailsJson, let originUrl, let pairing):
            try container.encode("passkeyGet", forKey: .type)
            try container.encode(token, forKey: .token)
            try container.encode(requestId, forKey: .requestId)
            try container.encode(requestDetailsJson, forKey: .requestDetailsJson)
            try container.encode(originUrl, forKey: .originUrl)
            try container.encodeIfPresent(pairing, forKey: .pairing)
        case .passkeyGetApprove(let token, let requestId, let entryId, let pairing):
            try container.encode("passkeyGetApprove", forKey: .type)
            try container.encode(token, forKey: .token)
            try container.encode(requestId, forKey: .requestId)
            try container.encode(entryId, forKey: .entryId)
            try container.encodeIfPresent(pairing, forKey: .pairing)
        case .passkeyCancel(let token, let requestId, let pairing):
            try container.encode("passkeyCancel", forKey: .type)
            try container.encode(token, forKey: .token)
            try container.encode(requestId, forKey: .requestId)
            try container.encodeIfPresent(pairing, forKey: .pairing)
```

Add `hasPasskey: Bool` to `ExtensionCredentialSummary` (mirror however `hasTotp` was added if piece A already landed — otherwise the struct currently has just `id`, `title`, `username`):

```swift
public struct ExtensionCredentialSummary: Codable, Equatable {
    public let id: String
    public let title: String
    public let username: String
    public let hasPasskey: Bool
    // keep any existing `hasTotp: Bool` here too if piece A already added it

    public init(id: String, title: String, username: String, hasPasskey: Bool) {
        // keep any existing hasTotp parameter/assignment here too if present
        self.id = id
        self.title = title
        self.username = username
        self.hasPasskey = hasPasskey
    }
}
```

Add `PasskeyErrorDetails` near `ExtensionCredentialSummary`:

```swift
public struct PasskeyErrorDetails: Codable, Equatable {
    public let name: String
    public let message: String

    public init(name: String, message: String) {
        self.name = name
        self.message = message
    }
}
```

Add the new response cases to `ExtensionBridgeResponse`:

```swift
    case passkeyProxyStatus(unlocked: Bool, paired: Bool, attachAllowed: Bool)
    case passkeyProxyEnabled(enabled: Bool)
    case passkeyCreatePending(requestId: Int, rpId: String, rpName: String, matches: [ExtensionCredentialSummary])
    case passkeyCreateComplete(requestId: Int, responseJson: String?, error: PasskeyErrorDetails?)
    case passkeyGetPending(requestId: Int, rpId: String, matches: [ExtensionCredentialSummary])
    case passkeyGetComplete(requestId: Int, responseJson: String?, error: PasskeyErrorDetails?)
    case passkeyCancelled(requestId: Int)
```

Add decode arms inside `ExtensionBridgeResponse.init(from:)`:

```swift
        case "passkeyProxyStatus":
            let unlocked = try container.decode(Bool.self, forKey: .unlocked)
            let paired = try container.decode(Bool.self, forKey: .paired)
            let attachAllowed = try container.decode(Bool.self, forKey: .attachAllowed)
            self = .passkeyProxyStatus(unlocked: unlocked, paired: paired, attachAllowed: attachAllowed)
        case "passkeyProxyEnabled":
            let enabled = try container.decode(Bool.self, forKey: .enabled)
            self = .passkeyProxyEnabled(enabled: enabled)
        case "passkeyCreatePending":
            let requestId = try container.decode(Int.self, forKey: .requestId)
            let rpId = try container.decode(String.self, forKey: .rpId)
            let rpName = try container.decode(String.self, forKey: .rpName)
            let matches = try container.decode([ExtensionCredentialSummary].self, forKey: .matches)
            self = .passkeyCreatePending(requestId: requestId, rpId: rpId, rpName: rpName, matches: matches)
        case "passkeyCreateComplete":
            let requestId = try container.decode(Int.self, forKey: .requestId)
            let responseJson = try container.decodeIfPresent(String.self, forKey: .responseJson)
            let error = try container.decodeIfPresent(PasskeyErrorDetails.self, forKey: .error)
            self = .passkeyCreateComplete(requestId: requestId, responseJson: responseJson, error: error)
        case "passkeyGetPending":
            let requestId = try container.decode(Int.self, forKey: .requestId)
            let rpId = try container.decode(String.self, forKey: .rpId)
            let matches = try container.decode([ExtensionCredentialSummary].self, forKey: .matches)
            self = .passkeyGetPending(requestId: requestId, rpId: rpId, matches: matches)
        case "passkeyGetComplete":
            let requestId = try container.decode(Int.self, forKey: .requestId)
            let responseJson = try container.decodeIfPresent(String.self, forKey: .responseJson)
            let error = try container.decodeIfPresent(PasskeyErrorDetails.self, forKey: .error)
            self = .passkeyGetComplete(requestId: requestId, responseJson: responseJson, error: error)
        case "passkeyCancelled":
            let requestId = try container.decode(Int.self, forKey: .requestId)
            self = .passkeyCancelled(requestId: requestId)
```

Add matching encode arms inside `ExtensionBridgeResponse.encode(to:)`:

```swift
        case .passkeyProxyStatus(let unlocked, let paired, let attachAllowed):
            try container.encode("passkeyProxyStatus", forKey: .type)
            try container.encode(unlocked, forKey: .unlocked)
            try container.encode(paired, forKey: .paired)
            try container.encode(attachAllowed, forKey: .attachAllowed)
        case .passkeyProxyEnabled(let enabled):
            try container.encode("passkeyProxyEnabled", forKey: .type)
            try container.encode(enabled, forKey: .enabled)
        case .passkeyCreatePending(let requestId, let rpId, let rpName, let matches):
            try container.encode("passkeyCreatePending", forKey: .type)
            try container.encode(requestId, forKey: .requestId)
            try container.encode(rpId, forKey: .rpId)
            try container.encode(rpName, forKey: .rpName)
            try container.encode(matches, forKey: .matches)
        case .passkeyCreateComplete(let requestId, let responseJson, let error):
            try container.encode("passkeyCreateComplete", forKey: .type)
            try container.encode(requestId, forKey: .requestId)
            try container.encodeIfPresent(responseJson, forKey: .responseJson)
            try container.encodeIfPresent(error, forKey: .error)
        case .passkeyGetPending(let requestId, let rpId, let matches):
            try container.encode("passkeyGetPending", forKey: .type)
            try container.encode(requestId, forKey: .requestId)
            try container.encode(rpId, forKey: .rpId)
            try container.encode(matches, forKey: .matches)
        case .passkeyGetComplete(let requestId, let responseJson, let error):
            try container.encode("passkeyGetComplete", forKey: .type)
            try container.encode(requestId, forKey: .requestId)
            try container.encodeIfPresent(responseJson, forKey: .responseJson)
            try container.encodeIfPresent(error, forKey: .error)
        case .passkeyCancelled(let requestId):
            try container.encode("passkeyCancelled", forKey: .type)
            try container.encode(requestId, forKey: .requestId)
```

- [ ] **Step 4: Run and confirm pass**

Run: `cd Packages/ExtensionBridgeKit && swift test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/ExtensionBridgeKit/Sources/ExtensionBridgeKit/ExtensionBridgeMessages.swift Packages/ExtensionBridgeKit/Tests/ExtensionBridgeKitTests/ExtensionBridgeMessagesTests.swift
git commit -m "feat(bridge): add passkey ceremony wire protocol"
```

---

### Task 2: `KdbxEntry+Passkey.swift` — `KPEX_PASSKEY_*` field storage

**Files:**
- Modify: `MyPass/Models/KdbxEntry+Convenience.swift`
- Create: `MyPass/Models/KdbxEntry+Passkey.swift`
- Test: `MyPassTests/KdbxEntryPasskeyTests.swift` (new)

**Interfaces:**
- Produces: `entry.passkeyRelyingParty: String?`, `entry.passkeyCredentialId: Data?`, `entry.passkeyPrivateKeyPEM: String?`, `entry.passkeyUserHandle: Data?`, `entry.passkeyUsername: String?`, `entry.clearPasskey()`.

- [ ] **Step 1: Read `KdbxEntry+Convenience.swift` in full**

Read `MyPass/Models/KdbxEntry+Convenience.swift` completely and find its `setFieldValue(_:forKey:isProtected:)` and `fieldValue(forKey:)` helper declarations (used by `totpSecretBase32` among others) — note their exact current signatures and `private` modifier.

- [ ] **Step 2: Write failing tests**

Create `MyPassTests/KdbxEntryPasskeyTests.swift`:

```swift
import XCTest
import MyPassKit
@testable import MyPass

final class KdbxEntryPasskeyTests: XCTestCase {
    private func makeEntry() -> KdbxEntry {
        let now = Date()
        return KdbxEntry(
            uuid: UUID(), iconID: 0, fields: [],
            creationTime: now, lastModificationTime: now, lastAccessTime: now, locationChanged: now,
            history: []
        )
    }

    func testPasskeyFieldsRoundTrip() {
        var entry = makeEntry()
        entry.passkeyRelyingParty = "example.com"
        entry.passkeyCredentialId = Data([1, 2, 3, 4])
        entry.passkeyPrivateKeyPEM = "-----BEGIN PRIVATE KEY-----\nabc\n-----END PRIVATE KEY-----"
        entry.passkeyUserHandle = Data([9, 9, 9])
        entry.passkeyUsername = "alice"

        XCTAssertEqual(entry.passkeyRelyingParty, "example.com")
        XCTAssertEqual(entry.passkeyCredentialId, Data([1, 2, 3, 4]))
        XCTAssertEqual(entry.passkeyPrivateKeyPEM, "-----BEGIN PRIVATE KEY-----\nabc\n-----END PRIVATE KEY-----")
        XCTAssertEqual(entry.passkeyUserHandle, Data([9, 9, 9]))
        XCTAssertEqual(entry.passkeyUsername, "alice")
    }

    func testPasskeyFieldsAreNilWhenAbsent() {
        let entry = makeEntry()
        XCTAssertNil(entry.passkeyRelyingParty)
        XCTAssertNil(entry.passkeyCredentialId)
        XCTAssertNil(entry.passkeyPrivateKeyPEM)
        XCTAssertNil(entry.passkeyUserHandle)
        XCTAssertNil(entry.passkeyUsername)
    }

    func testPasskeyFieldsUseKeePassXCFieldNames() {
        var entry = makeEntry()
        entry.passkeyRelyingParty = "example.com"
        entry.passkeyCredentialId = Data([1])
        entry.passkeyPrivateKeyPEM = "pem"
        entry.passkeyUserHandle = Data([2])
        entry.passkeyUsername = "alice"

        let keys = Set(entry.fields.map(\.key))
        XCTAssertTrue(keys.contains("KPEX_PASSKEY_RELYING_PARTY"))
        XCTAssertTrue(keys.contains("KPEX_PASSKEY_CREDENTIAL_ID"))
        XCTAssertTrue(keys.contains("KPEX_PASSKEY_PRIVATE_KEY_PEM"))
        XCTAssertTrue(keys.contains("KPEX_PASSKEY_USER_HANDLE"))
        XCTAssertTrue(keys.contains("KPEX_PASSKEY_USERNAME"))
    }

    func testClearPasskeyRemovesAllFields() {
        var entry = makeEntry()
        entry.passkeyRelyingParty = "example.com"
        entry.passkeyCredentialId = Data([1])
        entry.passkeyPrivateKeyPEM = "pem"
        entry.passkeyUserHandle = Data([2])
        entry.passkeyUsername = "alice"

        entry.clearPasskey()

        XCTAssertNil(entry.passkeyRelyingParty)
        XCTAssertNil(entry.passkeyCredentialId)
        XCTAssertNil(entry.passkeyPrivateKeyPEM)
        XCTAssertNil(entry.passkeyUserHandle)
        XCTAssertNil(entry.passkeyUsername)
        XCTAssertTrue(entry.fields.filter { $0.key.hasPrefix("KPEX_PASSKEY_") }.isEmpty)
    }
}
```

- [ ] **Step 3: Run and confirm failure**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS'`
Expected: build fails — no `KdbxEntry+Passkey.swift`, no passkey members.

- [ ] **Step 4: Widen the shared field helpers**

In `MyPass/Models/KdbxEntry+Convenience.swift`, change `setFieldValue`/`fieldValue` from `private func` to plain `func` (internal — the default), so a sibling file in the same `MyPass` module can call them:

```swift
// Replace (using whatever the exact current signatures are, found in Step 1):
    private func setFieldValue(...) { ... }
    private func fieldValue(...) { ... }

// With (same bodies, just drop `private`):
    func setFieldValue(...) { ... }
    func fieldValue(...) { ... }
```

- [ ] **Step 5: Implement `KdbxEntry+Passkey.swift`**

Create `MyPass/Models/KdbxEntry+Passkey.swift`:

```swift
import Foundation
import MyPassKit

extension KdbxEntry {
    private static let passkeyFieldKeys = [
        "KPEX_PASSKEY_RELYING_PARTY",
        "KPEX_PASSKEY_CREDENTIAL_ID",
        "KPEX_PASSKEY_PRIVATE_KEY_PEM",
        "KPEX_PASSKEY_USER_HANDLE",
        "KPEX_PASSKEY_USERNAME",
        "KPEX_PASSKEY_FLAG_BE",
        "KPEX_PASSKEY_FLAG_BS",
    ]

    var passkeyRelyingParty: String? {
        get { fieldValue(forKey: "KPEX_PASSKEY_RELYING_PARTY") }
        set {
            guard let newValue else {
                fields.removeAll(where: { $0.key == "KPEX_PASSKEY_RELYING_PARTY" })
                return
            }
            setFieldValue(newValue, forKey: "KPEX_PASSKEY_RELYING_PARTY", isProtected: false)
        }
    }

    var passkeyCredentialId: Data? {
        get { fieldValue(forKey: "KPEX_PASSKEY_CREDENTIAL_ID").flatMap { PasskeyBase64URL.decode($0) } }
        set {
            guard let newValue else {
                fields.removeAll(where: { $0.key == "KPEX_PASSKEY_CREDENTIAL_ID" })
                return
            }
            setFieldValue(PasskeyBase64URL.encode(newValue), forKey: "KPEX_PASSKEY_CREDENTIAL_ID", isProtected: true)
        }
    }

    var passkeyPrivateKeyPEM: String? {
        get { fieldValue(forKey: "KPEX_PASSKEY_PRIVATE_KEY_PEM") }
        set {
            guard let newValue else {
                fields.removeAll(where: { $0.key == "KPEX_PASSKEY_PRIVATE_KEY_PEM" })
                return
            }
            setFieldValue(newValue, forKey: "KPEX_PASSKEY_PRIVATE_KEY_PEM", isProtected: true)
        }
    }

    var passkeyUserHandle: Data? {
        get { fieldValue(forKey: "KPEX_PASSKEY_USER_HANDLE").flatMap { PasskeyBase64URL.decode($0) } }
        set {
            guard let newValue else {
                fields.removeAll(where: { $0.key == "KPEX_PASSKEY_USER_HANDLE" })
                return
            }
            setFieldValue(PasskeyBase64URL.encode(newValue), forKey: "KPEX_PASSKEY_USER_HANDLE", isProtected: true)
        }
    }

    var passkeyUsername: String? {
        get { fieldValue(forKey: "KPEX_PASSKEY_USERNAME") }
        set {
            guard let newValue else {
                fields.removeAll(where: { $0.key == "KPEX_PASSKEY_USERNAME" })
                return
            }
            setFieldValue(newValue, forKey: "KPEX_PASSKEY_USERNAME", isProtected: false)
        }
    }

    mutating func clearPasskey() {
        for key in Self.passkeyFieldKeys {
            fields.removeAll(where: { $0.key == key })
        }
    }

    /// Sets the KeePassXC backup-eligible/backup-state flags — both default `1`
    /// at write time for interop with KeePassXC's own passkey convention.
    mutating func setPasskeyBackupFlags(eligible: Bool = true, state: Bool = true) {
        setFieldValue(eligible ? "1" : "0", forKey: "KPEX_PASSKEY_FLAG_BE", isProtected: false)
        setFieldValue(state ? "1" : "0", forKey: "KPEX_PASSKEY_FLAG_BS", isProtected: false)
    }
}

/// Base64url (RFC 4648 §5) without padding — used for every binary WebAuthn
/// value (credential IDs, user handles, challenges) per the spec's wire format.
/// Shared between `KdbxEntry+Passkey.swift` and `PasskeyCeremony.swift` (Task 3
/// re-exports/reuses this rather than duplicating it).
enum PasskeyBase64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ string: String) -> Data? {
        var base64 = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        return Data(base64Encoded: base64)
    }
}
```

- [ ] **Step 6: Run and confirm pass**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS'`
Expected: PASS, including all `KdbxEntryPasskeyTests` cases.

- [ ] **Step 7: Commit**

```bash
git add MyPass/Models/KdbxEntry+Convenience.swift MyPass/Models/KdbxEntry+Passkey.swift MyPassTests/KdbxEntryPasskeyTests.swift
git commit -m "feat(app): store KPEX_PASSKEY_* fields on Login entries"
```

---

### Task 3: `PasskeyCeremony.swift` — CBOR/COSE core, parse, create, sign

**Files:**
- Create: `MyPass/State/ExtensionBridge/PasskeyCeremony.swift`
- Test: `MyPassTests/PasskeyCeremonyTests.swift` (new)

**Interfaces:**
- Consumes: `PasskeyBase64URL` from Task 2.
- Produces: `PasskeyCeremonyError`, `PasskeyCreateContext`, `PasskeyGetContext`, `PasskeyCreateResult`, `PasskeyGetResult`, `PasskeyCeremony.parseCreateRequest(_:) throws -> PasskeyCreateContext`, `PasskeyCeremony.parseGetRequest(_:) throws -> PasskeyGetContext`, `PasskeyCeremony.performCreate(context:originUrl:) throws -> PasskeyCreateResult`, `PasskeyCeremony.performGet(context:originUrl:privateKeyPEM:credentialId:userHandle:) throws -> PasskeyGetResult`.

**IMPORTANT — verify against a live Chrome fixture before trusting this task done:** the exact `requestDetailsJson` shape from `chrome.webAuthenticationProxy.onCreateRequest`/`onGetRequest` is not independently confirmed against a running Chrome instance in this plan — it's built from MDN's documented `PublicKeyCredentialCreationOptionsJSON`/`toJSON()` shapes (verified via `https://developer.mozilla.org/en-US/docs/Web/API/PublicKeyCredential/parseCreationOptionsFromJSON_static` and `.../PublicKeyCredential/toJSON`), which is the best available authority but is one hop removed from Chrome's actual proxy payload. Task 8 (background.js) includes a step to capture one real `requestDetailsJson` value from a live Chrome ceremony and diff it against the fixtures below — treat that as a required checkpoint, not optional polish.

- [ ] **Step 1: Write failing tests**

Create `MyPassTests/PasskeyCeremonyTests.swift`:

```swift
import XCTest
import CryptoKit
@testable import MyPass

final class PasskeyCeremonyTests: XCTestCase {
    private func createFixtureJSON(challenge: Data, userId: Data, algs: [Int] = [-7]) -> String {
        let params = algs.map { "{ \"type\": \"public-key\", \"alg\": \($0) }" }.joined(separator: ", ")
        return """
        {
          "challenge": "\(PasskeyBase64URL.encode(challenge))",
          "rp": { "id": "example.com", "name": "Example" },
          "user": { "id": "\(PasskeyBase64URL.encode(userId))", "name": "alice", "displayName": "Alice" },
          "pubKeyCredParams": [\(params)],
          "attestation": "none"
        }
        """
    }

    func testParseCreateRequestExtractsRpAndUser() throws {
        let challenge = Data((0..<16).map { UInt8($0) })
        let userId = Data([1, 2, 3, 4])
        let context = try PasskeyCeremony.parseCreateRequest(createFixtureJSON(challenge: challenge, userId: userId))
        XCTAssertEqual(context.rpId, "example.com")
        XCTAssertEqual(context.rpName, "Example")
        XCTAssertEqual(context.userName, "alice")
        XCTAssertEqual(context.userDisplayName, "Alice")
        XCTAssertEqual(context.challenge, challenge)
        XCTAssertEqual(context.userId, userId)
    }

    func testParseCreateRequestThrowsUnsupportedAlgorithmWhenES256Missing() {
        let json = createFixtureJSON(challenge: Data([1, 2, 3]), userId: Data([9, 9, 9]), algs: [-257])
        XCTAssertThrowsError(try PasskeyCeremony.parseCreateRequest(json)) { error in
            XCTAssertEqual(error as? PasskeyCeremonyError, .unsupportedAlgorithm)
        }
    }

    func testParseCreateRequestThrowsInvalidRequestJSONOnGarbage() {
        XCTAssertThrowsError(try PasskeyCeremony.parseCreateRequest("not json")) { error in
            XCTAssertEqual(error as? PasskeyCeremonyError, .invalidRequestJSON)
        }
    }

    func testPerformCreateProducesValidSelfAttestationSignature() throws {
        let challenge = Data((0..<16).map { UInt8($0) })
        let userId = Data([1, 2, 3, 4])
        let context = try PasskeyCeremony.parseCreateRequest(createFixtureJSON(challenge: challenge, userId: userId))

        let result = try PasskeyCeremony.performCreate(context: context, originUrl: "https://example.com")

        let privateKey = try P256.Signing.PrivateKey(pemRepresentation: result.privateKeyPEM)
        let publicKey = privateKey.publicKey

        let responseData = try XCTUnwrap(result.responseJson.data(using: .utf8))
        let response = try XCTUnwrap(try JSONSerialization.jsonObject(with: responseData) as? [String: Any])
        XCTAssertEqual(response["type"] as? String, "public-key")
        let responseInner = try XCTUnwrap(response["response"] as? [String: Any])
        let clientDataJSONB64 = try XCTUnwrap(responseInner["clientDataJSON"] as? String)
        let clientDataJSON = try XCTUnwrap(PasskeyBase64URL.decode(clientDataJSONB64))
        let clientDataHash = Data(SHA256.hash(data: clientDataJSON))

        // Independently verify the embedded self-attestation signature — proves
        // real ES256 correctness, not just that JSON round-trips.
        let signature = try P256.Signing.ECDSASignature(derRepresentation: result.signature)
        XCTAssertTrue(publicKey.isValidSignature(signature, for: result.authData + clientDataHash))
        XCTAssertGreaterThan(result.credentialId.count, 0)

        let clientData = try XCTUnwrap(try JSONSerialization.jsonObject(with: clientDataJSON) as? [String: Any])
        XCTAssertEqual(clientData["type"] as? String, "webauthn.create")
        XCTAssertEqual(clientData["origin"] as? String, "https://example.com")
        XCTAssertEqual(clientData["challenge"] as? String, PasskeyBase64URL.encode(challenge))
    }

    func testPerformCreateAuthDataHasAttestedCredentialDataFlagSet() throws {
        let context = try PasskeyCeremony.parseCreateRequest(createFixtureJSON(challenge: Data([1]), userId: Data([2])))
        let result = try PasskeyCeremony.performCreate(context: context, originUrl: "https://example.com")
        let flags = result.authData[32] // byte 32: rpIdHash is 32 bytes, flags is the next byte
        XCTAssertNotEqual(flags & 0x40, 0, "AT (attested credential data present) flag must be set on create")
    }

    func testParseGetRequestExtractsRpIdAndAllowCredentials() throws {
        let credentialId = Data([5, 6, 7])
        let json = """
        {
          "challenge": "\(PasskeyBase64URL.encode(Data([1, 2, 3])))",
          "rpId": "example.com",
          "allowCredentials": [{ "type": "public-key", "id": "\(PasskeyBase64URL.encode(credentialId))" }]
        }
        """
        let context = try PasskeyCeremony.parseGetRequest(json)
        XCTAssertEqual(context.rpId, "example.com")
        XCTAssertEqual(context.allowCredentialIds, [credentialId])
    }

    func testPerformGetProducesValidAssertionSignature() throws {
        // Reuse performCreate to get a real ES256 keypair/PEM, then sign a get ceremony with it.
        let createContext = try PasskeyCeremony.parseCreateRequest(createFixtureJSON(challenge: Data([1]), userId: Data([2, 2])))
        let createResult = try PasskeyCeremony.performCreate(context: createContext, originUrl: "https://example.com")

        let getJson = """
        { "challenge": "\(PasskeyBase64URL.encode(Data([9, 9, 9, 9]))))", "rpId": "example.com", "allowCredentials": [] }
        """
        let getContext = try PasskeyCeremony.parseGetRequest(getJson)
        let getResult = try PasskeyCeremony.performGet(
            context: getContext, originUrl: "https://example.com",
            privateKeyPEM: createResult.privateKeyPEM, credentialId: createResult.credentialId, userHandle: Data([2, 2])
        )

        let privateKey = try P256.Signing.PrivateKey(pemRepresentation: createResult.privateKeyPEM)
        let responseData = try XCTUnwrap(getResult.responseJson.data(using: .utf8))
        let response = try XCTUnwrap(try JSONSerialization.jsonObject(with: responseData) as? [String: Any])
        let responseInner = try XCTUnwrap(response["response"] as? [String: Any])
        let clientDataJSONB64 = try XCTUnwrap(responseInner["clientDataJSON"] as? String)
        let clientDataJSON = try XCTUnwrap(PasskeyBase64URL.decode(clientDataJSONB64))
        let clientDataHash = Data(SHA256.hash(data: clientDataJSON))

        let signature = try P256.Signing.ECDSASignature(derRepresentation: getResult.signature)
        XCTAssertTrue(privateKey.publicKey.isValidSignature(signature, for: getResult.authData + clientDataHash))

        let clientData = try XCTUnwrap(try JSONSerialization.jsonObject(with: clientDataJSON) as? [String: Any])
        XCTAssertEqual(clientData["type"] as? String, "webauthn.get")
    }

    func testPerformGetAuthDataDoesNotHaveAttestedCredentialDataFlag() throws {
        let createContext = try PasskeyCeremony.parseCreateRequest(createFixtureJSON(challenge: Data([1]), userId: Data([2])))
        let createResult = try PasskeyCeremony.performCreate(context: createContext, originUrl: "https://example.com")
        let getContext = try PasskeyCeremony.parseGetRequest(
            "{ \\"challenge\\": \\"\(PasskeyBase64URL.encode(Data([3])))\\", \\"rpId\\": \\"example.com\\", \\"allowCredentials\\": [] }"
        )
        let getResult = try PasskeyCeremony.performGet(
            context: getContext, originUrl: "https://example.com",
            privateKeyPEM: createResult.privateKeyPEM, credentialId: createResult.credentialId, userHandle: nil
        )
        let flags = getResult.authData[32]
        XCTAssertEqual(flags & 0x40, 0, "AT flag must NOT be set on a get/assertion authData")
    }
}
```

- [ ] **Step 2: Run and confirm failure**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS'`
Expected: build fails — `PasskeyCeremony` doesn't exist yet.

- [ ] **Step 3: Implement `PasskeyCeremony.swift`**

Create `MyPass/State/ExtensionBridge/PasskeyCeremony.swift`:

```swift
import Foundation
import CryptoKit

enum PasskeyCeremonyError: Error, Equatable {
    case unsupportedAlgorithm
    case noMatchingCredential
    case userCancelled
    case invalidRequestJSON
}

struct PasskeyCreateContext {
    let rpId: String
    let rpName: String
    let challenge: Data
    let userId: Data
    let userName: String
    let userDisplayName: String
}

struct PasskeyGetContext {
    let rpId: String
    let challenge: Data
    let allowCredentialIds: [Data]
}

struct PasskeyCreateResult {
    let responseJson: String
    let credentialId: Data
    let privateKeyPEM: String
    /// Exposed so tests can independently re-verify the embedded self-attestation
    /// signature without re-parsing CBOR — see PasskeyCeremonyTests.
    let authData: Data
    let signature: Data
}

struct PasskeyGetResult {
    let responseJson: String
    let authData: Data
    let signature: Data
}

// MARK: - Minimal CBOR encoder (RFC 8949) — only the major types this ceremony
// needs: unsigned int (0), negative int (1), byte string (2), text string (3),
// map (5). No indefinite-length items, tags, or floats — not a general-purpose
// CBOR library, just enough for a fixed-shape packed attestation object.
enum CBOR {
    private static func encodeHeader(majorType: UInt8, length: UInt64) -> Data {
        let typeBits = majorType << 5
        if length < 24 {
            return Data([typeBits | UInt8(length)])
        } else if length <= 0xFF {
            return Data([typeBits | 24, UInt8(length)])
        } else if length <= 0xFFFF {
            return Data([typeBits | 25, UInt8((length >> 8) & 0xFF), UInt8(length & 0xFF)])
        } else {
            return Data([
                typeBits | 26,
                UInt8((length >> 24) & 0xFF), UInt8((length >> 16) & 0xFF),
                UInt8((length >> 8) & 0xFF), UInt8(length & 0xFF),
            ])
        }
    }

    static func encodeUnsignedInt(_ value: UInt64) -> Data { encodeHeader(majorType: 0, length: value) }

    static func encodeNegativeInt(_ value: Int) -> Data {
        precondition(value < 0)
        return encodeHeader(majorType: 1, length: UInt64(-1 - value))
    }

    static func encodeByteString(_ bytes: Data) -> Data {
        encodeHeader(majorType: 2, length: UInt64(bytes.count)) + bytes
    }

    static func encodeTextString(_ string: String) -> Data {
        let bytes = Data(string.utf8)
        return encodeHeader(majorType: 3, length: UInt64(bytes.count)) + bytes
    }

    static func encodeMapHeader(pairCount: Int) -> Data { encodeHeader(majorType: 5, length: UInt64(pairCount)) }
}

enum PasskeyCeremony {
    // MARK: Parsing

    static func parseCreateRequest(_ requestDetailsJson: String) throws -> PasskeyCreateContext {
        guard let data = requestDetailsJson.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PasskeyCeremonyError.invalidRequestJSON
        }
        guard let challengeB64 = json["challenge"] as? String,
              let challenge = PasskeyBase64URL.decode(challengeB64),
              let rp = json["rp"] as? [String: Any],
              let rpId = rp["id"] as? String,
              let user = json["user"] as? [String: Any],
              let userIdB64 = user["id"] as? String,
              let userId = PasskeyBase64URL.decode(userIdB64) else {
            throw PasskeyCeremonyError.invalidRequestJSON
        }
        let pubKeyCredParams = json["pubKeyCredParams"] as? [[String: Any]] ?? []
        guard pubKeyCredParams.contains(where: { ($0["alg"] as? Int) == -7 }) else {
            throw PasskeyCeremonyError.unsupportedAlgorithm
        }
        let rpName = (rp["name"] as? String) ?? rpId
        let userName = (user["name"] as? String) ?? ""
        let userDisplayName = (user["displayName"] as? String) ?? userName
        return PasskeyCreateContext(
            rpId: rpId, rpName: rpName, challenge: challenge,
            userId: userId, userName: userName, userDisplayName: userDisplayName
        )
    }

    static func parseGetRequest(_ requestDetailsJson: String) throws -> PasskeyGetContext {
        guard let data = requestDetailsJson.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let challengeB64 = json["challenge"] as? String,
              let challenge = PasskeyBase64URL.decode(challengeB64),
              let rpId = json["rpId"] as? String else {
            throw PasskeyCeremonyError.invalidRequestJSON
        }
        let allowCredentials = json["allowCredentials"] as? [[String: Any]] ?? []
        let allowCredentialIds = allowCredentials.compactMap { ($0["id"] as? String).flatMap(PasskeyBase64URL.decode) }
        return PasskeyGetContext(rpId: rpId, challenge: challenge, allowCredentialIds: allowCredentialIds)
    }

    // MARK: Building blocks shared by create + get

    private static func buildClientDataJSON(type: String, challenge: Data, origin: String) -> Data {
        let object: [String: Any] = [
            "type": type, "challenge": PasskeyBase64URL.encode(challenge), "origin": origin, "crossOrigin": false,
        ]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }

    private static func coseEC2PublicKey(x: Data, y: Data) -> Data {
        var out = CBOR.encodeMapHeader(pairCount: 5)
        out += CBOR.encodeUnsignedInt(1) + CBOR.encodeUnsignedInt(2)   // kty: EC2
        out += CBOR.encodeUnsignedInt(3) + CBOR.encodeNegativeInt(-7)  // alg: ES256
        out += CBOR.encodeNegativeInt(-1) + CBOR.encodeUnsignedInt(1)  // crv: P-256
        out += CBOR.encodeNegativeInt(-2) + CBOR.encodeByteString(x)
        out += CBOR.encodeNegativeInt(-3) + CBOR.encodeByteString(y)
        return out
    }

    private static func buildAuthenticatorData(rpId: String, flags: UInt8, signCount: UInt32, attestedCredentialData: Data?) -> Data {
        var out = Data(SHA256.hash(data: Data(rpId.utf8)))
        out.append(flags)
        withUnsafeBytes(of: signCount.bigEndian) { out.append(contentsOf: $0) }
        if let attestedCredentialData { out.append(attestedCredentialData) }
        return out
    }

    private static func buildAttestedCredentialData(credentialId: Data, cosePublicKey: Data) -> Data {
        var out = Data(repeating: 0, count: 16) // AAGUID: all-zero, no FIDO MDS registration for a software authenticator
        let length = UInt16(credentialId.count)
        out.append(UInt8(length >> 8))
        out.append(UInt8(length & 0xFF))
        out.append(credentialId)
        out.append(cosePublicKey)
        return out
    }

    private static func buildAttestationObject(authData: Data, signature: Data) -> Data {
        var out = CBOR.encodeMapHeader(pairCount: 3)
        out += CBOR.encodeTextString("fmt") + CBOR.encodeTextString("packed")
        var attStmt = CBOR.encodeMapHeader(pairCount: 2)
        attStmt += CBOR.encodeTextString("alg") + CBOR.encodeNegativeInt(-7)
        attStmt += CBOR.encodeTextString("sig") + CBOR.encodeByteString(signature)
        out += CBOR.encodeTextString("attStmt") + attStmt
        out += CBOR.encodeTextString("authData") + CBOR.encodeByteString(authData)
        return out
    }

    // MARK: Create

    static func performCreate(context: PasskeyCreateContext, originUrl: String) throws -> PasskeyCreateResult {
        let privateKey = P256.Signing.PrivateKey()
        let publicKey = privateKey.publicKey
        let rawKey = publicKey.rawRepresentation // expect 64 bytes: X(32) || Y(32), no format-byte prefix
        guard rawKey.count == 64 else { throw PasskeyCeremonyError.invalidRequestJSON }
        let x = rawKey.prefix(32)
        let y = rawKey.suffix(32)

        var credentialIdBytes = Data(count: 32)
        _ = credentialIdBytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }

        let cosePublicKey = coseEC2PublicKey(x: Data(x), y: Data(y))
        let attestedCredentialData = buildAttestedCredentialData(credentialId: credentialIdBytes, cosePublicKey: cosePublicKey)
        // Flags: UP(0x01) | UV(0x04) | BE(0x08) | BS(0x10) | AT(0x40) — MyPass's own
        // unlock+confirm stands in for user verification for a software authenticator.
        let authData = buildAuthenticatorData(rpId: context.rpId, flags: 0x5D, signCount: 0, attestedCredentialData: attestedCredentialData)

        let clientDataJSON = buildClientDataJSON(type: "webauthn.create", challenge: context.challenge, origin: originUrl)
        let clientDataHash = Data(SHA256.hash(data: clientDataJSON))
        let signature = try privateKey.signature(for: authData + clientDataHash).derRepresentation

        let attestationObject = buildAttestationObject(authData: authData, signature: signature)

        let response: [String: Any] = [
            "id": PasskeyBase64URL.encode(credentialIdBytes),
            "rawId": PasskeyBase64URL.encode(credentialIdBytes),
            "type": "public-key",
            "response": [
                "clientDataJSON": PasskeyBase64URL.encode(clientDataJSON),
                "attestationObject": PasskeyBase64URL.encode(attestationObject),
                "transports": ["internal"],
            ],
            "clientExtensionResults": [String: Any](),
        ]
        let responseData = try JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])
        let responseJson = String(data: responseData, encoding: .utf8) ?? "{}"

        return PasskeyCreateResult(
            responseJson: responseJson, credentialId: credentialIdBytes,
            privateKeyPEM: privateKey.pemRepresentation, authData: authData, signature: signature
        )
    }

    // MARK: Get

    static func performGet(
        context: PasskeyGetContext, originUrl: String, privateKeyPEM: String, credentialId: Data, userHandle: Data?
    ) throws -> PasskeyGetResult {
        let privateKey = try P256.Signing.PrivateKey(pemRepresentation: privateKeyPEM)

        // Flags: UP(0x01) | UV(0x04) | BE(0x08) | BS(0x10) — no AT, no attested
        // credential data on an assertion.
        let authData = buildAuthenticatorData(rpId: context.rpId, flags: 0x1D, signCount: 0, attestedCredentialData: nil)

        let clientDataJSON = buildClientDataJSON(type: "webauthn.get", challenge: context.challenge, origin: originUrl)
        let clientDataHash = Data(SHA256.hash(data: clientDataJSON))
        let signature = try privateKey.signature(for: authData + clientDataHash).derRepresentation

        var responseInner: [String: Any] = [
            "clientDataJSON": PasskeyBase64URL.encode(clientDataJSON),
            "authenticatorData": PasskeyBase64URL.encode(authData),
            "signature": PasskeyBase64URL.encode(signature),
        ]
        if let userHandle {
            responseInner["userHandle"] = PasskeyBase64URL.encode(userHandle)
        }
        let response: [String: Any] = [
            "id": PasskeyBase64URL.encode(credentialId),
            "rawId": PasskeyBase64URL.encode(credentialId),
            "type": "public-key",
            "response": responseInner,
            "clientExtensionResults": [String: Any](),
        ]
        let responseData = try JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])
        let responseJson = String(data: responseData, encoding: .utf8) ?? "{}"

        return PasskeyGetResult(responseJson: responseJson, authData: authData, signature: signature)
    }
}
```

- [ ] **Step 4: Run and confirm pass**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS'`
Expected: PASS, including the signature-verification tests. If `P256.Signing.PublicKey.rawRepresentation` turns out not to be exactly 64 bytes on this Swift/CryptoKit version, the `guard rawKey.count == 64` will throw immediately in the test — adjust the X/Y slicing (e.g. if it's actually `x963Representation` with a leading `0x04` byte, drop first byte then split 32/32) and re-run until green. Do not proceed to Task 4 with this test red.

- [ ] **Step 5: Commit**

```bash
git add MyPass/State/ExtensionBridge/PasskeyCeremony.swift MyPassTests/PasskeyCeremonyTests.swift
git commit -m "feat(app): add PasskeyCeremony ES256 create/get crypto core"
```

---

### Task 4: `ExtensionBridgeService` — passkey handlers + `LoopbackServer` routing

**Files:**
- Modify: `MyPass/State/ExtensionBridge/ExtensionBridgeService.swift`
- Modify: `MyPass/State/ExtensionBridge/LoopbackServer.swift`
- Test: `MyPassTests/ExtensionBridgeServiceTests.swift`

**Interfaces:**
- Consumes: everything from Tasks 1-3.
- Produces: `ExtensionBridgeService.handle(_:)` handles all seven new request cases; `getCredentials` includes `hasPasskey`.

- [ ] **Step 1: Write failing tests**

Append to `MyPassTests/ExtensionBridgeServiceTests.swift` (reuse `addFixtureEntry`/`makeServiceWithPairing`/`authorizedPairingSecret` exactly as existing tests do):

```swift
private func createFixtureRequestJSON(rpId: String = "example.com") -> String {
    """
    {
      "challenge": "\\(PasskeyBase64URL.encode(Data([1, 2, 3, 4])))",
      "rp": { "id": "\\(rpId)", "name": "Example" },
      "user": { "id": "\\(PasskeyBase64URL.encode(Data([9, 9])))", "name": "alice", "displayName": "Alice" },
      "pubKeyCredParams": [{ "type": "public-key", "alg": -7 }]
    }
    """
}

func testGetPasskeyProxyStatusReportsUnlockedEvenWhileVaultCheckWouldOtherwiseGateLocked() {
    let response = service.handle(.getPasskeyProxyStatus(token: "t", pairing: authorizedPairingSecret))
    XCTAssertEqual(response, .passkeyProxyStatus(unlocked: true, paired: true, attachAllowed: true))
}

func testGetPasskeyProxyStatusReportsLockedWithoutReturningGenericLockedResponse() {
    session.lock()
    let response = service.handle(.getPasskeyProxyStatus(token: "t", pairing: authorizedPairingSecret))
    XCTAssertEqual(response, .passkeyProxyStatus(unlocked: false, paired: true, attachAllowed: false))
}

func testGetPasskeyProxyStatusReturnsPairingRequiredWithoutSecret() {
    let (service, _, _) = makeServiceWithPairing()
    XCTAssertEqual(service.handle(.getPasskeyProxyStatus(token: "t", pairing: nil)), .pairingRequired)
}

func testSetPasskeyProxyEnabledPersistsAndReturnsEnabled() {
    let response = service.handle(.setPasskeyProxyEnabled(token: "t", enabled: true, pairing: authorizedPairingSecret))
    XCTAssertEqual(response, .passkeyProxyEnabled(enabled: true))
    XCTAssertTrue(UserDefaults.standard.bool(forKey: "passkeyProxyEnabled"))
}

func testGetCredentialsSetsHasPasskeyTrueWhenPrivateKeyPresent() {
    let id = addFixtureEntry(title: "Example", username: "alice", password: "s3cret", url: "https://example.com")
    session.mutate { db in
        if let index = db.rootGroup.entries.firstIndex(where: { $0.uuid == id }) {
            db.rootGroup.entries[index].passkeyRelyingParty = "example.com"
            db.rootGroup.entries[index].passkeyPrivateKeyPEM = "pem"
        }
    }
    let response = service.handle(.getCredentials(token: "t", url: "https://example.com", pairing: authorizedPairingSecret))
    guard case .credentialList(let summaries) = response else { return XCTFail("expected credentialList") }
    XCTAssertEqual(summaries.first?.hasPasskey, true)
}

func testPasskeyCreateReturnsPendingWithZeroMatches() {
    let response = service.handle(.passkeyCreate(
        token: "t", requestId: 1, requestDetailsJson: createFixtureRequestJSON(), originUrl: "https://example.com", pairing: authorizedPairingSecret
    ))
    guard case .passkeyCreatePending(let requestId, let rpId, _, let matches) = response else {
        return XCTFail("expected passkeyCreatePending, got \(response)")
    }
    XCTAssertEqual(requestId, 1)
    XCTAssertEqual(rpId, "example.com")
    XCTAssertTrue(matches.isEmpty)
}

func testPasskeyCreateReturnsUnsupportedAlgorithmError() {
    let json = """
    { "challenge": "AAEC", "rp": { "id": "example.com" }, "user": { "id": "AAEC", "name": "a" }, "pubKeyCredParams": [{ "type": "public-key", "alg": -257 }] }
    """
    let response = service.handle(.passkeyCreate(
        token: "t", requestId: 2, requestDetailsJson: json, originUrl: "https://example.com", pairing: authorizedPairingSecret
    ))
    guard case .passkeyCreateComplete(_, let responseJson, let error) = response else {
        return XCTFail("expected passkeyCreateComplete with error, got \(response)")
    }
    XCTAssertNil(responseJson)
    XCTAssertEqual(error?.name, "NotSupportedError")
}

func testPasskeyCreateThenConfirmWritesEntryAndReturnsResponseJson() {
    let prepareResponse = service.handle(.passkeyCreate(
        token: "t", requestId: 3, requestDetailsJson: createFixtureRequestJSON(), originUrl: "https://example.com", pairing: authorizedPairingSecret
    ))
    guard case .passkeyCreatePending = prepareResponse else { return XCTFail("expected pending") }

    let confirmResponse = service.handle(.passkeyCreateConfirm(token: "t", requestId: 3, entryId: nil, replace: false, pairing: authorizedPairingSecret))
    guard case .passkeyCreateComplete(let requestId, let responseJson, let error) = confirmResponse else {
        return XCTFail("expected passkeyCreateComplete, got \(confirmResponse)")
    }
    XCTAssertEqual(requestId, 3)
    XCTAssertNil(error)
    XCTAssertNotNil(responseJson)

    let entries = EntrySearch.allEntries(in: session.currentDatabase!.rootGroup)
    XCTAssertTrue(entries.contains { $0.passkeyRelyingParty == "example.com" && $0.passkeyPrivateKeyPEM?.isEmpty == false })
}

func testPasskeyCreateConfirmRequiresReplaceFlagWhenEntryAlreadyHasPasskey() {
    let id = addFixtureEntry(title: "Example", username: "alice", password: "s3cret", url: "https://example.com")
    session.mutate { db in
        if let index = db.rootGroup.entries.firstIndex(where: { $0.uuid == id }) {
            db.rootGroup.entries[index].passkeyRelyingParty = "example.com"
            db.rootGroup.entries[index].passkeyPrivateKeyPEM = "existing-pem"
        }
    }
    _ = service.handle(.passkeyCreate(
        token: "t", requestId: 4, requestDetailsJson: createFixtureRequestJSON(), originUrl: "https://example.com", pairing: authorizedPairingSecret
    ))
    let response = service.handle(.passkeyCreateConfirm(token: "t", requestId: 4, entryId: id.uuidString, replace: false, pairing: authorizedPairingSecret))
    guard case .passkeyCreateComplete(_, let responseJson, let error) = response else { return XCTFail("expected complete") }
    XCTAssertNil(responseJson)
    XCTAssertEqual(error?.name, "InvalidStateError")

    let entries = EntrySearch.allEntries(in: session.currentDatabase!.rootGroup)
    XCTAssertEqual(entries.first { $0.uuid == id }?.passkeyPrivateKeyPEM, "existing-pem", "must not overwrite without replace: true")
}

func testPasskeyCreateReturnsLockedAndDoesNotWriteWhenVaultIsLocked() {
    session.lock()
    let response = service.handle(.passkeyCreate(
        token: "t", requestId: 5, requestDetailsJson: createFixtureRequestJSON(), originUrl: "https://example.com", pairing: authorizedPairingSecret
    ))
    XCTAssertEqual(response, .locked)
}

func testPasskeyGetReturnsPendingForMatchingRp() {
    let id = addFixtureEntry(title: "Example", username: "alice", password: "s3cret", url: "https://example.com")
    session.mutate { db in
        if let index = db.rootGroup.entries.firstIndex(where: { $0.uuid == id }) {
            db.rootGroup.entries[index].passkeyRelyingParty = "example.com"
            db.rootGroup.entries[index].passkeyPrivateKeyPEM = "pem"
            db.rootGroup.entries[index].passkeyCredentialId = Data([1, 2, 3])
        }
    }
    let json = """
    { "challenge": "\\(PasskeyBase64URL.encode(Data([1, 2, 3])))", "rpId": "example.com", "allowCredentials": [] }
    """
    let response = service.handle(.passkeyGet(token: "t", requestId: 6, requestDetailsJson: json, originUrl: "https://example.com", pairing: authorizedPairingSecret))
    guard case .passkeyGetPending(_, let rpId, let matches) = response else { return XCTFail("expected pending, got \(response)") }
    XCTAssertEqual(rpId, "example.com")
    XCTAssertEqual(matches.count, 1)
}

func testPasskeyGetReturnsNotAllowedErrorWhenNoMatch() {
    let json = """
    { "challenge": "\\(PasskeyBase64URL.encode(Data([1])))", "rpId": "no-such-site.com", "allowCredentials": [] }
    """
    let response = service.handle(.passkeyGet(token: "t", requestId: 7, requestDetailsJson: json, originUrl: "https://no-such-site.com", pairing: authorizedPairingSecret))
    guard case .passkeyGetComplete(_, let responseJson, let error) = response else { return XCTFail("expected complete, got \(response)") }
    XCTAssertNil(responseJson)
    XCTAssertEqual(error?.name, "NotAllowedError")
}

func testPasskeyGetThenApproveSignsAssertion() {
    let id = addFixtureEntry(title: "Example", username: "alice", password: "s3cret", url: "https://example.com")
    session.mutate { db in
        if let index = db.rootGroup.entries.firstIndex(where: { $0.uuid == id }) {
            db.rootGroup.entries[index].passkeyRelyingParty = "example.com"
        }
    }
    let createPrepare = service.handle(.passkeyCreate(
        token: "t", requestId: 8, requestDetailsJson: createFixtureRequestJSON(), originUrl: "https://example.com", pairing: authorizedPairingSecret
    ))
    guard case .passkeyCreatePending = createPrepare else { return XCTFail("expected pending") }
    _ = service.handle(.passkeyCreateConfirm(token: "t", requestId: 8, entryId: id.uuidString, replace: false, pairing: authorizedPairingSecret))

    let getJson = """
    { "challenge": "\\(PasskeyBase64URL.encode(Data([4, 4, 4])))", "rpId": "example.com", "allowCredentials": [] }
    """
    let getPrepare = service.handle(.passkeyGet(token: "t", requestId: 9, requestDetailsJson: getJson, originUrl: "https://example.com", pairing: authorizedPairingSecret))
    guard case .passkeyGetPending = getPrepare else { return XCTFail("expected pending, got \(getPrepare)") }

    let approveResponse = service.handle(.passkeyGetApprove(token: "t", requestId: 9, entryId: id.uuidString, pairing: authorizedPairingSecret))
    guard case .passkeyGetComplete(_, let responseJson, let error) = approveResponse else { return XCTFail("expected complete, got \(approveResponse)") }
    XCTAssertNil(error)
    XCTAssertNotNil(responseJson)
}

func testPasskeyCancelClearsPendingStateForBothCreateAndGet() {
    _ = service.handle(.passkeyCreate(
        token: "t", requestId: 10, requestDetailsJson: createFixtureRequestJSON(), originUrl: "https://example.com", pairing: authorizedPairingSecret
    ))
    let cancelResponse = service.handle(.passkeyCancel(token: "t", requestId: 10, pairing: authorizedPairingSecret))
    XCTAssertEqual(cancelResponse, .passkeyCancelled(requestId: 10))

    let confirmAfterCancel = service.handle(.passkeyCreateConfirm(token: "t", requestId: 10, entryId: nil, replace: false, pairing: authorizedPairingSecret))
    guard case .passkeyCreateComplete(_, let responseJson, let error) = confirmAfterCancel else { return XCTFail("expected complete") }
    XCTAssertNil(responseJson)
    XCTAssertEqual(error?.name, "NotAllowedError", "confirming a cancelled request must fail, not silently succeed")
}
```

- [ ] **Step 2: Run and confirm failure**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS'`
Expected: build fails — no passkey cases handled yet, `EntrySearch` import already present per existing file conventions.

- [ ] **Step 3: Fix `LoopbackServer`'s token-extraction switch**

In `MyPass/State/ExtensionBridge/LoopbackServer.swift`'s `requestToken(from:)`, add one arm per new request case (adapt to whatever arms already exist from prior plans):

```swift
        case .getPasskeyProxyStatus(let token, _): return token
        case .setPasskeyProxyEnabled(let token, _, _): return token
        case .passkeyCreate(let token, _, _, _, _): return token
        case .passkeyCreateConfirm(let token, _, _, _, _): return token
        case .passkeyGet(let token, _, _, _, _): return token
        case .passkeyGetApprove(let token, _, _, _): return token
        case .passkeyCancel(let token, _, _): return token
```

- [ ] **Step 4: Implement `ExtensionBridgeService`**

Add two pending-ceremony dictionaries as stored properties, near `pairingManager`:

```swift
    private var pendingPasskeyCreates: [Int: (context: PasskeyCreateContext, originUrl: String)] = [:]
    private var pendingPasskeyGets: [Int: (context: PasskeyGetContext, originUrl: String)] = [:]
```

Special-case `getPasskeyProxyStatus` **before** the existing blanket-lock guard, since it's the one message that must answer while locked:

```swift
// Replace:
    func handle(_ request: ExtensionBridgeRequest) -> ExtensionBridgeResponse {
        guard vaultSession?.currentDatabase != nil else {
            return .locked
        }
        switch request {

// With:
    func handle(_ request: ExtensionBridgeRequest) -> ExtensionBridgeResponse {
        if case .getPasskeyProxyStatus(_, let pairing) = request {
            guard pairingManager.isAuthorized(pairing: pairing) else {
                return .pairingRequired
            }
            let unlocked = vaultSession?.currentDatabase != nil
            return .passkeyProxyStatus(unlocked: unlocked, paired: true, attachAllowed: unlocked)
        }
        guard vaultSession?.currentDatabase != nil else {
            return .locked
        }
        switch request {
```

Add `hasPasskey` to the `getCredentials` summary mapping (find whatever the current `ExtensionCredentialSummary(...)` call site looks like — it may already include `hasTotp` from a prior plan — add `hasPasskey` alongside without removing anything):

```swift
                ExtensionCredentialSummary(
                    id: $0.uuid.uuidString, title: $0.title, username: $0.login,
                    hasPasskey: $0.passkeyPrivateKeyPEM?.isEmpty == false
                    // keep any existing hasTotp: ... argument here too
                )
```

Add the new cases to the `switch request` (anywhere after `getCredentials`, e.g. right before `proposeSaveLogin`):

```swift
        case .setPasskeyProxyEnabled(_, let enabled, let pairing):
            guard pairingManager.isAuthorized(pairing: pairing) else {
                return .pairingRequired
            }
            UserDefaults.standard.set(enabled, forKey: "passkeyProxyEnabled")
            return .passkeyProxyEnabled(enabled: enabled)

        case .passkeyCreate(_, let requestId, let requestDetailsJson, let originUrl, let pairing):
            guard pairingManager.isAuthorized(pairing: pairing) else {
                return .pairingRequired
            }
            guard let database = vaultSession?.currentDatabase else {
                return .locked
            }
            let context: PasskeyCreateContext
            do {
                context = try PasskeyCeremony.parseCreateRequest(requestDetailsJson)
            } catch PasskeyCeremonyError.unsupportedAlgorithm {
                return .passkeyCreateComplete(
                    requestId: requestId, responseJson: nil,
                    error: PasskeyErrorDetails(name: "NotSupportedError", message: "MyPass passkeys require ES256")
                )
            } catch {
                return .passkeyCreateComplete(
                    requestId: requestId, responseJson: nil,
                    error: PasskeyErrorDetails(name: "NotAllowedError", message: "Invalid passkey request")
                )
            }
            let matches = EntrySearch.allEntries(in: database.rootGroup).filter { $0.passkeyRelyingParty == context.rpId }
            let summaries = matches.map {
                ExtensionCredentialSummary(id: $0.uuid.uuidString, title: $0.title, username: $0.login, hasPasskey: true)
            }
            pendingPasskeyCreates[requestId] = (context: context, originUrl: originUrl)
            return .passkeyCreatePending(requestId: requestId, rpId: context.rpId, rpName: context.rpName, matches: summaries)

        case .passkeyCreateConfirm(_, let requestId, let entryId, let replace, let pairing):
            guard pairingManager.isAuthorized(pairing: pairing) else {
                return .pairingRequired
            }
            guard let database = vaultSession?.currentDatabase else {
                return .locked
            }
            guard let pending = pendingPasskeyCreates[requestId] else {
                return .passkeyCreateComplete(
                    requestId: requestId, responseJson: nil,
                    error: PasskeyErrorDetails(name: "NotAllowedError", message: "No pending request")
                )
            }
            let targetEntry = entryId.flatMap { id in
                EntrySearch.allEntries(in: database.rootGroup).first(where: { $0.uuid.uuidString == id })
            }
            if let targetEntry, targetEntry.passkeyPrivateKeyPEM?.isEmpty == false, !replace {
                return .passkeyCreateComplete(
                    requestId: requestId, responseJson: nil,
                    error: PasskeyErrorDetails(name: "InvalidStateError", message: "Entry already has a passkey")
                )
            }
            do {
                let result = try PasskeyCeremony.performCreate(context: pending.context, originUrl: pending.originUrl)
                var entry = targetEntry ?? {
                    let now = Date()
                    var newEntry = KdbxEntry(
                        uuid: UUID(), iconID: 0, fields: [],
                        creationTime: now, lastModificationTime: now, lastAccessTime: now, locationChanged: now, history: []
                    )
                    newEntry.title = pending.context.rpId
                    newEntry.login = pending.context.userName
                    return newEntry
                }()
                entry.passkeyRelyingParty = pending.context.rpId
                entry.passkeyCredentialId = result.credentialId
                entry.passkeyPrivateKeyPEM = result.privateKeyPEM
                entry.passkeyUserHandle = pending.context.userId
                entry.passkeyUsername = pending.context.userName
                entry.setPasskeyBackupFlags()
                entry.lastModificationTime = Date()
                let isUpdate = targetEntry != nil
                vaultSession?.mutate { db in
                    if isUpdate, let index = db.rootGroup.entries.firstIndex(where: { $0.uuid == entry.uuid }) {
                        db.rootGroup.entries[index] = entry
                    } else if !isUpdate {
                        db.rootGroup.entries.append(entry)
                    }
                }
                onCredentialFilled?(entry.uuid)
                pendingPasskeyCreates.removeValue(forKey: requestId)
                return .passkeyCreateComplete(requestId: requestId, responseJson: result.responseJson, error: nil)
            } catch {
                pendingPasskeyCreates.removeValue(forKey: requestId)
                return .passkeyCreateComplete(
                    requestId: requestId, responseJson: nil,
                    error: PasskeyErrorDetails(name: "NotAllowedError", message: "Failed to create passkey")
                )
            }

        case .passkeyGet(_, let requestId, let requestDetailsJson, let originUrl, let pairing):
            guard pairingManager.isAuthorized(pairing: pairing) else {
                return .pairingRequired
            }
            guard let database = vaultSession?.currentDatabase else {
                return .locked
            }
            let context: PasskeyGetContext
            do {
                context = try PasskeyCeremony.parseGetRequest(requestDetailsJson)
            } catch {
                return .passkeyGetComplete(
                    requestId: requestId, responseJson: nil,
                    error: PasskeyErrorDetails(name: "NotAllowedError", message: "Invalid passkey request")
                )
            }
            let candidates = EntrySearch.allEntries(in: database.rootGroup).filter { $0.passkeyRelyingParty == context.rpId }
            let matched = context.allowCredentialIds.isEmpty
                ? candidates
                : candidates.filter { entry in context.allowCredentialIds.contains(where: { $0 == entry.passkeyCredentialId }) }
            guard !matched.isEmpty else {
                return .passkeyGetComplete(
                    requestId: requestId, responseJson: nil,
                    error: PasskeyErrorDetails(name: "NotAllowedError", message: "No passkey for this site")
                )
            }
            let summaries = matched.map {
                ExtensionCredentialSummary(id: $0.uuid.uuidString, title: $0.title, username: $0.login, hasPasskey: true)
            }
            pendingPasskeyGets[requestId] = (context: context, originUrl: originUrl)
            return .passkeyGetPending(requestId: requestId, rpId: context.rpId, matches: summaries)

        case .passkeyGetApprove(_, let requestId, let entryId, let pairing):
            guard pairingManager.isAuthorized(pairing: pairing) else {
                return .pairingRequired
            }
            guard let database = vaultSession?.currentDatabase else {
                return .locked
            }
            guard let pending = pendingPasskeyGets[requestId] else {
                return .passkeyGetComplete(
                    requestId: requestId, responseJson: nil,
                    error: PasskeyErrorDetails(name: "NotAllowedError", message: "No pending request")
                )
            }
            guard let entry = EntrySearch.allEntries(in: database.rootGroup).first(where: { $0.uuid.uuidString == entryId }),
                  let pem = entry.passkeyPrivateKeyPEM, let credentialId = entry.passkeyCredentialId else {
                pendingPasskeyGets.removeValue(forKey: requestId)
                return .passkeyGetComplete(
                    requestId: requestId, responseJson: nil,
                    error: PasskeyErrorDetails(name: "NotAllowedError", message: "Passkey entry not found")
                )
            }
            do {
                let result = try PasskeyCeremony.performGet(
                    context: pending.context, originUrl: pending.originUrl,
                    privateKeyPEM: pem, credentialId: credentialId, userHandle: entry.passkeyUserHandle
                )
                pendingPasskeyGets.removeValue(forKey: requestId)
                return .passkeyGetComplete(requestId: requestId, responseJson: result.responseJson, error: nil)
            } catch {
                pendingPasskeyGets.removeValue(forKey: requestId)
                return .passkeyGetComplete(
                    requestId: requestId, responseJson: nil,
                    error: PasskeyErrorDetails(name: "NotAllowedError", message: "Failed to sign assertion")
                )
            }

        case .passkeyCancel(_, let requestId, let pairing):
            guard pairingManager.isAuthorized(pairing: pairing) else {
                return .pairingRequired
            }
            pendingPasskeyCreates.removeValue(forKey: requestId)
            pendingPasskeyGets.removeValue(forKey: requestId)
            return .passkeyCancelled(requestId: requestId)
```

(These new cases don't call `vaultSession?.touchAccess` — only `onCredentialFilled?` on a successful create, mirroring `fillCredential`'s bookkeeping since a create genuinely does touch/modify the entry; get/approve intentionally skips both, matching `getTotp`'s "lighter than a full fill" precedent from piece A if it landed, or simply because the spec doesn't ask for it here.)

- [ ] **Step 5: Run and confirm pass**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS'`
Expected: PASS, including every new `ExtensionBridgeServiceTests` case. Also run `cd Packages/ExtensionBridgeKit && swift test` to confirm no regression.

- [ ] **Step 6: Commit**

```bash
git add MyPass/State/ExtensionBridge/ExtensionBridgeService.swift MyPass/State/ExtensionBridge/LoopbackServer.swift MyPassTests/ExtensionBridgeServiceTests.swift
git commit -m "feat(bridge): handle passkey create/get/cancel ceremonies"
```

---

### Task 5: Settings toggle — "Use MyPass for Chrome passkeys"

**Files:**
- Modify: `MyPass/UI/Settings/BrowserSettingsPane.swift`

**Interfaces:** Reads/writes the same `UserDefaults` key (`"passkeyProxyEnabled"`) that `ExtensionBridgeService.setPasskeyProxyEnabled` writes (Task 4), via the existing `@AppStorage` convention.

- [ ] **Step 1: Read the file and confirm the existing toggle convention**

Read `MyPass/UI/Settings/BrowserSettingsPane.swift` in full, and `MyPass/UI/Settings/GeneralSettingsPane.swift` or `SecuritySettingsPane.swift` for the exact `@AppStorage` + `Toggle` + `SettingsHelperText` pattern to mirror (e.g. `@AppStorage("lockOnDeviceSleepEnabled") private var lockOnDeviceSleepEnabled = true` → `Toggle("Lock when device locks or sleeps", isOn: $lockOnDeviceSleepEnabled)`).

- [ ] **Step 2: Add the toggle**

Add, following the exact same convention:

```swift
@AppStorage("passkeyProxyEnabled") private var passkeyProxyEnabled = false
```

and inside the pane's `Form`/`Section`, add:

```swift
Toggle("Use MyPass for Chrome passkeys", isOn: $passkeyProxyEnabled)
SettingsHelperText(text: "While enabled, MyPass becomes the exclusive passkey provider for Chrome — iCloud Keychain and security keys won't be offered for passkey sign-in until you turn this off. Changes take effect the next time Chrome's extension checks in (on browser restart or when you reopen the popup).")
```

There is no automated test for this pane (none of the existing `*SettingsPane.swift` files have one). This is a plain `@AppStorage` read/write — the same value `ExtensionBridgeService.setPasskeyProxyEnabled`/`getPasskeyProxyStatus` (Task 4) already read/write directly via `UserDefaults.standard`, so no bridge wiring is needed here; the two surfaces converge on the same key. Note explicitly in a code comment that a change made here takes effect in the extension only the next time it calls `getPasskeyProxyStatus` (service worker wake or popup reopen) — there's no live push channel from app to extension, which matches the spec's own "re-attach only if setting on AND fresh getPasskeyProxyStatus confirms" lifecycle design, not a gap to fix.

- [ ] **Step 3: Build and verify**

Run: `xcodebuild build -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS'`
Expected: builds cleanly.

- [ ] **Step 4: Commit**

```bash
git add MyPass/UI/Settings/BrowserSettingsPane.swift
git commit -m "feat(app): add Use MyPass for Chrome passkeys settings toggle"
```

---

### Task 6: `EntryDetailView.swift` — read-only Passkey section + Remove

**Files:**
- Modify: `MyPass/UI/EntryDetail/EntryDetailView.swift`

**Interfaces:** Consumes `entry.passkeyRelyingParty`/`passkeyUsername`/`passkeyCredentialId`/`clearPasskey()` from Task 2.

- [ ] **Step 1: Read the file in full**

Read `MyPass/UI/EntryDetail/EntryDetailView.swift` completely — specifically the `totpRow(secret:)` function and its `if let secret = entry.totpSecretBase32 { DetailFieldDivider(); totpRow(secret: secret) }` call site (the pattern to mirror for a new `passkeyRow(...)`), and `HistoryView.swift`'s destructive-confirm pattern (`@State private var showClearConfirm = false`, `Button(..., role: .destructive)`, `.alert(...)`) as your template — `EntryDetailView.swift` itself has no existing alert/confirm pattern, so this is net-new here.

- [ ] **Step 2: Add the Passkey section**

Following the `totpRow` conditional-section pattern, add a new conditional section (adjust exact placement/styling to match the surrounding `DetailFieldsCard` conventions found in Step 1):

```swift
if let rpId = entry.passkeyRelyingParty, entry.passkeyPrivateKeyPEM?.isEmpty == false {
    DetailFieldDivider()
    passkeyRow(rpId: rpId, username: entry.passkeyUsername, credentialId: entry.passkeyCredentialId)
}
```

Add the row builder and a truncated-credential-ID helper:

```swift
@ViewBuilder
private func passkeyRow(rpId: String, username: String?, credentialId: Data?) -> some View {
    VStack(alignment: .leading, spacing: 4) {
        Text("Passkey")
            .font(.caption)
            .foregroundStyle(.secondary)
        Text(rpId)
        if let username, !username.isEmpty {
            Text(username)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if let credentialId {
            Text("Credential ID: \(truncatedCredentialId(credentialId))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        Button("Remove passkey", role: .destructive) {
            showRemovePasskeyConfirm = true
        }
        .padding(.top, 4)
    }
}

private func truncatedCredentialId(_ data: Data) -> String {
    let encoded = PasskeyBase64URL.encode(data)
    guard encoded.count > 12 else { return encoded }
    return "\(encoded.prefix(6))…\(encoded.suffix(6))"
}
```

Add the confirm state and alert modifier, mirroring `HistoryView.swift`'s exact `Button(role: .destructive)` + `.alert(...)` shape:

```swift
@State private var showRemovePasskeyConfirm = false
```

```swift
.alert(
    "Remove Passkey?",
    isPresented: $showRemovePasskeyConfirm,
    actions: {
        Button("Cancel", role: .cancel) {}
        Button("Remove", role: .destructive) {
            vaultSession.mutate { db in
                if let index = db.rootGroup.entries.firstIndex(where: { $0.uuid == entry.uuid }) {
                    db.rootGroup.entries[index].clearPasskey()
                }
            }
        }
    },
    message: {
        Text("This removes the passkey from this entry. The site will no longer accept it for sign-in.")
    }
)
```

(Adapt `vaultSession.mutate { ... }` to however `EntryDetailView.swift` actually accesses `vaultSession`/the current entry mutation pattern per Step 1's read — e.g. it may already hold a `@State private var entry: KdbxEntry` bound to a live document, or take the entry via a binding; use whatever the file's existing "Restore" action at lines ~207-219 does as the exact template for correctly mutating the vault and refreshing this view.)

- [ ] **Step 3: Build and verify**

Run: `xcodebuild build -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS'`
Expected: builds cleanly. There's no unit test for this view (SwiftUI view logic isn't unit-tested elsewhere in this codebase either) — manual verification happens in Task 10's e2e checklist.

- [ ] **Step 4: Commit**

```bash
git add MyPass/UI/EntryDetail/EntryDetailView.swift
git commit -m "feat(app): show read-only Passkey section with Remove passkey confirm"
```

---

### Task 7: `manifest.json` — WebAuthn proxy permission

**Files:**
- Modify: `ChromeExtension/manifest.json`

- [ ] **Step 1: Add the permission and minimum Chrome version**

```json
// Replace:
  "permissions": ["nativeMessaging", "activeTab", "storage"],

// With:
  "permissions": ["nativeMessaging", "activeTab", "storage", "webAuthenticationProxy"],
  "minimum_chrome_version": "115",
```

(If pieces A/B already added other permissions like `"clipboardRead"`, keep them — just make sure `"webAuthenticationProxy"` is present alongside whatever's already there.)

- [ ] **Step 2: Update `background.manifest.test.js` if it locks down the permissions array**

Open `ChromeExtension/tests/background.manifest.test.js` — if it asserts an exact permissions array or explicitly asserts `"webAuthenticationProxy"` is absent, update that assertion to expect it present. Also add an assertion that `manifest.minimum_chrome_version === "115"` if the file's style favors asserting every manifest field explicitly (match whatever level of strictness the existing assertions already use).

- [ ] **Step 3: Run and confirm pass**

Run: `node ChromeExtension/tests/background.manifest.test.js`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add ChromeExtension/manifest.json ChromeExtension/tests/background.manifest.test.js
git commit -m "feat(chrome): add webAuthenticationProxy permission and minimum Chrome version"
```

---

### Task 8: `background.js` — WebAuthn proxy lifecycle and ceremony relay

**Files:**
- Modify: `ChromeExtension/background.js`
- Test: `ChromeExtension/tests/passkeyProxy.test.js` (new)
- Modify: `scripts/test.sh`

**Interfaces:**
- Produces: `attachPasskeyProxyIfEligible()`, `handlePasskeyRequest(kind, requestId, requestDetailsJson, originUrl)`, `completePasskeyRequest(kind, details)`, `passkeyNotAllowedError(message)` — exported for testing. Registers `chrome.webAuthenticationProxy.onCreateRequest`/`onGetRequest`/`onIsUvpaaRequest`/`onRequestCanceled` listeners synchronously at service-worker load (MV3 requirement — listeners must be added in the first turn of the event loop, not inside a callback).

**Required checkpoint before this task is done:** capture one real `requestDetailsJson` payload from an actual Chrome ceremony (e.g. temporarily `console.log(JSON.stringify(requestInfo))` inside `onCreateRequest`'s listener, load the unpacked extension, attach the proxy, and trigger a real `navigator.credentials.create()` on a test page or webauthn.io) and diff it against the fixture JSON used in Task 3's `PasskeyCeremonyTests.swift` and Task 10's fixture pages. If the real shape differs (e.g. wrapped under a `"publicKey"` key, or different casing), fix `PasskeyCeremony.parseCreateRequest`/`parseGetRequest` in Task 3 before continuing — do not ship this task with an unverified assumption about the wire shape.

- [ ] **Step 1: Write failing tests**

Read `ChromeExtension/tests/pairing.test.js` in full for its `global.chrome` stub shape (in-memory `storage`, `sentNativeMessages`, etc.) — reuse the same baseline. Create `ChromeExtension/tests/passkeyProxy.test.js`:

```js
const assert = require('node:assert');

global.chrome = global.chrome || {};
global.chrome.storage = global.chrome.storage || { local: {}, session: {} };
global.chrome.storage.local.get = (keys, cb) => cb({ passkeyProxyEnabled: true });
global.chrome.storage.local.set = (obj, cb) => { if (cb) cb(); };
global.chrome.storage.session = global.chrome.storage.session || {};
global.chrome.storage.session.set = (obj, cb) => { if (cb) cb(); };
global.chrome.runtime = global.chrome.runtime || {};
global.chrome.runtime.sendNativeMessage = (msg, cb) => { cb({ type: 'passkeyProxyStatus', unlocked: true, paired: true, attachAllowed: true }); };
global.chrome.runtime.onMessage = { addListener: () => {} };
global.chrome.webAuthenticationProxy = {
  attach: () => Promise.resolve(),
  detach: () => Promise.resolve(),
  onCreateRequest: { addListener: () => {} },
  onGetRequest: { addListener: () => {} },
  onIsUvpaaRequest: { addListener: () => {} },
  onRequestCanceled: { addListener: () => {} },
  completeCreateRequest: () => {},
  completeGetRequest: () => {},
  completeIsUvpaaRequest: () => {},
};
global.chrome.tabs = { query: (opts, cb) => cb([{ url: 'https://example.com' }]) };
global.chrome.action = { openPopup: () => Promise.resolve() };
global.chrome.notifications = { create: () => {} };

const {
  attachPasskeyProxyIfEligible, handlePasskeyRequest, completePasskeyRequest, passkeyNotAllowedError,
} = require('../background.js');

assert.deepStrictEqual(passkeyNotAllowedError('x'), { name: 'NotAllowedError', message: 'x' });
console.log('passkeyProxy.test.js: passkeyNotAllowedError OK');

(async () => {
  let attachCalled = false;
  global.chrome.webAuthenticationProxy.attach = () => { attachCalled = true; return Promise.resolve(); };
  await attachPasskeyProxyIfEligible();
  assert.strictEqual(attachCalled, true, 'attach() called when setting enabled and status allows it');
  console.log('passkeyProxy.test.js: attachPasskeyProxyIfEligible attaches when eligible OK');

  attachCalled = false;
  global.chrome.storage.local.get = (keys, cb) => cb({ passkeyProxyEnabled: false });
  await attachPasskeyProxyIfEligible();
  assert.strictEqual(attachCalled, false, 'attach() not called when setting disabled');
  console.log('passkeyProxy.test.js: attachPasskeyProxyIfEligible skips when disabled OK');

  attachCalled = false;
  global.chrome.storage.local.get = (keys, cb) => cb({ passkeyProxyEnabled: true });
  global.chrome.runtime.sendNativeMessage = (msg, cb) => cb({ type: 'passkeyProxyStatus', unlocked: false, paired: true, attachAllowed: false });
  await attachPasskeyProxyIfEligible();
  assert.strictEqual(attachCalled, false, 'attach() not called when status.attachAllowed is false (locked)');
  console.log('passkeyProxy.test.js: attachPasskeyProxyIfEligible skips when locked OK');

  let completedWith = null;
  global.chrome.webAuthenticationProxy.completeCreateRequest = (details) => { completedWith = details; };
  global.chrome.runtime.sendNativeMessage = (msg, cb) => {
    if (msg.type === 'passkeyCreate') {
      cb({ type: 'passkeyCreatePending', requestId: 1, rpId: 'example.com', rpName: 'Example', matches: [] });
    }
  };
  handlePasskeyRequest('create', 1, '{}', 'https://example.com');
  await new Promise((resolve) => setTimeout(resolve, 10));
  assert.strictEqual(completedWith, null, 'pending response must not auto-complete the ceremony');
  console.log('passkeyProxy.test.js: handlePasskeyRequest pending does not auto-complete OK');

  completePasskeyRequest('create', { requestId: 1, responseJson: '{}' });
  assert.deepStrictEqual(completedWith, { requestId: 1, responseJson: '{}' });
  console.log('passkeyProxy.test.js: completePasskeyRequest calls completeCreateRequest OK');
})();
```

- [ ] **Step 2: Run and confirm failure**

Run: `node ChromeExtension/tests/passkeyProxy.test.js`
Expected: `TypeError` — none of these functions exist/are exported yet.

- [ ] **Step 3: Implement in `background.js`**

Add near the top of the file, alongside other module-level state (must be at the top level, not inside a callback, per MV3's synchronous-listener-registration requirement):

```js
const PASSKEY_WATCHDOG_MS = 120000;
const pendingPasskeyCeremonies = new Map(); // requestId -> { kind, timer, originUrl, rpId, matches }

function passkeyNotAllowedError(message) {
  return { name: 'NotAllowedError', message };
}

async function attachPasskeyProxyIfEligible() {
  const stored = await new Promise((resolve) => chrome.storage.local.get(['passkeyProxyEnabled'], resolve));
  if (!stored.passkeyProxyEnabled) return;
  const status = await new Promise((resolve) => sendNativeMessageWithPairing({ type: 'getPasskeyProxyStatus' }).then(resolve));
  if (status && status.type === 'passkeyProxyStatus' && status.attachAllowed) {
    try {
      await chrome.webAuthenticationProxy.attach();
    } catch (error) {
      console.warn('MyPass: passkey proxy attach failed', error);
    }
  }
}

function openPasskeyPopup() {
  if (chrome.action && typeof chrome.action.openPopup === 'function') {
    chrome.action.openPopup().catch(() => {
      chrome.notifications.create({
        type: 'basic', iconUrl: 'icons/icon48.png', title: 'MyPass', message: 'MyPass passkey confirmation needed',
      });
    });
  }
}

function completePasskeyRequest(kind, details) {
  const pending = pendingPasskeyCeremonies.get(details.requestId);
  if (pending) {
    clearTimeout(pending.timer);
    pendingPasskeyCeremonies.delete(details.requestId);
  }
  if (kind === 'create') {
    chrome.webAuthenticationProxy.completeCreateRequest(details);
  } else {
    chrome.webAuthenticationProxy.completeGetRequest(details);
  }
}

function handlePasskeyRequest(kind, requestId, requestDetailsJson, originUrl) {
  if (pendingPasskeyCeremonies.size > 0) {
    completePasskeyRequest(kind, { requestId, error: { name: 'AbortError', message: 'Another passkey ceremony is already pending' } });
    return;
  }
  const messageType = kind === 'create' ? 'passkeyCreate' : 'passkeyGet';
  sendNativeMessageWithPairing({ type: messageType, requestId, requestDetailsJson, originUrl }).then((response) => {
    if (response && response.error) {
      completePasskeyRequest(kind, { requestId, error: response.error });
      return;
    }
    if (response && (response.type === 'passkeyCreatePending' || response.type === 'passkeyGetPending')) {
      const timer = setTimeout(() => {
        completePasskeyRequest(kind, { requestId, error: passkeyNotAllowedError('Timed out waiting for confirmation') });
      }, PASSKEY_WATCHDOG_MS);
      pendingPasskeyCeremonies.set(requestId, { kind, timer, originUrl, rpId: response.rpId, matches: response.matches });
      chrome.storage.session.set({
        pendingPasskeyCeremony: { kind, requestId, rpId: response.rpId, matches: response.matches, originUrl },
      });
      openPasskeyPopup();
    }
  });
}
```

Register the four proxy listeners synchronously at top level (near the file's other top-level `chrome.*.addListener` registrations):

```js
if (typeof chrome !== 'undefined' && chrome.webAuthenticationProxy) {
  chrome.webAuthenticationProxy.onCreateRequest.addListener((requestInfo) => {
    chrome.tabs.query({ active: true, currentWindow: true }, (tabs) => {
      handlePasskeyRequest('create', requestInfo.requestId, requestInfo.requestDetailsJson, tabs[0] ? tabs[0].url : '');
    });
  });

  chrome.webAuthenticationProxy.onGetRequest.addListener((requestInfo) => {
    chrome.tabs.query({ active: true, currentWindow: true }, (tabs) => {
      handlePasskeyRequest('get', requestInfo.requestId, requestInfo.requestDetailsJson, tabs[0] ? tabs[0].url : '');
    });
  });

  chrome.webAuthenticationProxy.onIsUvpaaRequest.addListener((requestInfo) => {
    chrome.storage.local.get(['passkeyProxyEnabled'], (stored) => {
      if (!stored.passkeyProxyEnabled) return;
      sendNativeMessageWithPairing({ type: 'getPasskeyProxyStatus' }).then((status) => {
        const isUvpaa = !!(status && status.type === 'passkeyProxyStatus' && status.unlocked);
        chrome.webAuthenticationProxy.completeIsUvpaaRequest({ requestId: requestInfo.requestId, isUvpaa });
      });
    });
  });

  chrome.webAuthenticationProxy.onRequestCanceled.addListener((requestId) => {
    const pending = pendingPasskeyCeremonies.get(requestId);
    if (pending) {
      clearTimeout(pending.timer);
      pendingPasskeyCeremonies.delete(requestId);
    }
    sendNativeMessageWithPairing({ type: 'passkeyCancel', requestId });
  });

  attachPasskeyProxyIfEligible();
}
```

Add two branches to the message listener (inside `handleRuntimeMessage` if piece B already extracted it, otherwise inside the raw `chrome.runtime.onMessage.addListener` callback — add near the existing `startPairing`/`completePairing` special cases) for the popup's confirm/approve and cancel actions:

```js
  if (message.type === 'passkeyCreateConfirm' || message.type === 'passkeyGetApprove') {
    const kind = message.type === 'passkeyCreateConfirm' ? 'create' : 'get';
    sendNativeMessageWithPairing(message).then((response) => {
      if (response && (response.type === 'passkeyCreateComplete' || response.type === 'passkeyGetComplete')) {
        completePasskeyRequest(kind, { requestId: message.requestId, responseJson: response.responseJson, error: response.error });
      }
      sendResponse(response);
    });
    return true;
  }

  if (message.type === 'passkeyCancelUI') {
    const pending = pendingPasskeyCeremonies.get(message.requestId);
    const kind = pending ? pending.kind : 'create';
    sendNativeMessageWithPairing({ type: 'passkeyCancel', requestId: message.requestId }).then(() => {
      completePasskeyRequest(kind, { requestId: message.requestId, error: passkeyNotAllowedError('User cancelled') });
      sendResponse({ type: 'ok' });
    });
    return true;
  }
```

Add `"setPasskeyProxyEnabled"` to `knownTypes` (wherever it currently lives) so the popup's settings toggle can route through the generic relay, and, when the popup enables the setting, also persist it locally and attempt attach:

```js
  if (message.type === 'setPasskeyProxyEnabled') {
    chrome.storage.local.set({ passkeyProxyEnabled: message.enabled }, () => {
      sendNativeMessageWithPairing(message).then((response) => {
        if (message.enabled) {
          attachPasskeyProxyIfEligible();
        } else {
          chrome.webAuthenticationProxy.detach().catch(() => {});
        }
        sendResponse(response);
      });
    });
    return true;
  }
```

Add all four new functions (`attachPasskeyProxyIfEligible`, `handlePasskeyRequest`, `completePasskeyRequest`, `passkeyNotAllowedError`) to `module.exports`.

- [ ] **Step 4: Wire the new test into `scripts/test.sh`**

Add `node ChromeExtension/tests/passkeyProxy.test.js` alongside the other `node ChromeExtension/tests/*.test.js` lines (append after whatever the last one currently is).

- [ ] **Step 5: Run and confirm pass**

Run: `node ChromeExtension/tests/passkeyProxy.test.js`
Expected: PASS. Also run `node ChromeExtension/tests/pairing.test.js` to confirm no regression.

- [ ] **Step 6: Commit**

```bash
git add ChromeExtension/background.js ChromeExtension/tests/passkeyProxy.test.js scripts/test.sh
git commit -m "feat(chrome): implement webAuthenticationProxy attach lifecycle and ceremony relay"
```

---

### Task 9: `popup.js` / `popup.html` — passkey confirm panels

**Files:**
- Modify: `ChromeExtension/popup.html`
- Modify: `ChromeExtension/popup.js`

**Interfaces:** Consumes `chrome.storage.session.pendingPasskeyCeremony` from Task 8; sends `passkeyCreateConfirm`/`passkeyGetApprove`/`passkeyCancelUI`/`setPasskeyProxyEnabled` messages.

- [ ] **Step 1: Read `popup.html` and `popup.js` in full**

Confirm the exact `PANEL_SECTIONS` array and `showPanel(name)` switch (Task's Global Constraints note some earlier plans may have added panels already — adapt), and the exact `activeTab.url` capture site to reuse.

- [ ] **Step 2: Add panel markup to `popup.html`**

Inside `#panel-shell`, add new sections following the exact `hidden`-attribute convention as the existing panels:

```html
<section id="passkey-save-panel" hidden>
  <p class="panel-title">Save passkey</p>
  <p id="passkey-save-summary"></p>
  <button id="passkey-save-btn" type="button" class="btn-primary">Save</button>
  <button id="passkey-cancel-btn" type="button" class="btn-secondary">Cancel</button>
</section>
<section id="passkey-replace-panel" hidden>
  <p class="panel-title">Replace passkey?</p>
  <p id="passkey-replace-summary"></p>
  <button id="passkey-replace-btn" type="button" class="btn-primary">Replace</button>
  <button id="passkey-replace-cancel-btn" type="button" class="btn-secondary">Cancel</button>
</section>
<section id="passkey-use-panel" hidden>
  <p class="panel-title">Use passkey</p>
  <p id="passkey-use-summary"></p>
  <button id="passkey-approve-btn" type="button" class="btn-primary">Approve</button>
  <button id="passkey-use-cancel-btn" type="button" class="btn-secondary">Cancel</button>
</section>
<section id="passkey-picker-panel" hidden>
  <p class="panel-title">Choose an entry</p>
  <ul id="passkey-picker-list" class="credential-list"></ul>
</section>
<section id="passkey-unattached-panel" hidden>
  <p class="panel-title">Passkeys not enabled</p>
  <p>Enable "Use MyPass for Chrome passkeys" to continue.</p>
  <button id="passkey-unattached-cancel-btn" type="button" class="btn-secondary">Cancel</button>
</section>
```

Add a settings toggle in the footer, following the `#code-entry` input pattern's markup style:

```html
<div id="passkey-settings-footer">
  <label><input type="checkbox" id="passkey-proxy-toggle"> Use MyPass for Chrome passkeys</label>
</div>
```

Every confirm panel's summary paragraph (`#passkey-save-summary` etc.) must render both the RP ID and the origin hostname — this is the phishing-resistance requirement from the spec's Global Constraints, not optional copy.

- [ ] **Step 3: Implement in `popup.js`**

Add the new panel elements to `PANEL_SECTIONS` and add cases to `showPanel(name)` for `'passkey-save'`, `'passkey-replace'`, `'passkey-use'`, `'passkey-picker'`, `'passkey-unattached'`, following the exact existing dispatcher pattern.

Add rehydration logic, called during popup init alongside the existing `getCredentials`-on-open flow:

```js
function rehydratePendingPasskeyCeremony() {
  const area = getPairingStorageArea();
  if (!area || !area.get) return;
  area.get(['pendingPasskeyCeremony'], (result) => {
    const pending = result && result.pendingPasskeyCeremony;
    if (!pending) return;
    renderPasskeyCeremonyPanel(pending);
  });
}

function renderPasskeyCeremonyPanel(pending) {
  const summaryText = `${pending.rpId} — ${pending.originUrl}`;
  if (pending.matches.length > 1) {
    renderPasskeyPicker(pending);
    showPanel('passkey-picker');
    return;
  }
  const entryId = pending.matches.length === 1 ? pending.matches[0].id : undefined;
  const alreadyHasPasskey = pending.matches.length === 1 && pending.matches[0].hasPasskey;
  if (pending.kind === 'create') {
    document.getElementById(alreadyHasPasskey ? 'passkey-replace-summary' : 'passkey-save-summary').textContent = summaryText;
    showPanel(alreadyHasPasskey ? 'passkey-replace' : 'passkey-save');
    wirePasskeyCreateButtons(pending.requestId, entryId, alreadyHasPasskey);
  } else {
    document.getElementById('passkey-use-summary').textContent = summaryText;
    showPanel('passkey-use');
    wirePasskeyGetButtons(pending.requestId, entryId);
  }
}

function renderPasskeyPicker(pending) {
  const listEl = document.getElementById('passkey-picker-list');
  listEl.innerHTML = '';
  pending.matches.forEach((credential) => {
    const item = document.createElement('li');
    item.className = 'credential-row';
    item.appendChild(buildLetterAvatarElement(credential.title));
    const title = document.createElement('div');
    title.className = 'credential-title';
    title.textContent = credential.title;
    item.appendChild(title);
    item.addEventListener('click', () => {
      if (pending.kind === 'create') {
        sendPasskeyCreateConfirm(pending.requestId, credential.id, credential.hasPasskey);
      } else {
        sendPasskeyGetApprove(pending.requestId, credential.id);
      }
    });
    listEl.appendChild(item);
  });
}

function sendPasskeyCreateConfirm(requestId, entryId, replace) {
  chrome.runtime.sendMessage({ type: 'passkeyCreateConfirm', requestId, entryId, replace: !!replace }, () => {
    chrome.storage.session.remove(['pendingPasskeyCeremony']);
    window.close();
  });
}

function sendPasskeyGetApprove(requestId, entryId) {
  chrome.runtime.sendMessage({ type: 'passkeyGetApprove', requestId, entryId }, () => {
    chrome.storage.session.remove(['pendingPasskeyCeremony']);
    window.close();
  });
}

function sendPasskeyCancel(requestId) {
  chrome.runtime.sendMessage({ type: 'passkeyCancelUI', requestId }, () => {
    chrome.storage.session.remove(['pendingPasskeyCeremony']);
    window.close();
  });
}

function wirePasskeyCreateButtons(requestId, entryId, isReplace) {
  const saveBtn = document.getElementById(isReplace ? 'passkey-replace-btn' : 'passkey-save-btn');
  const cancelBtn = document.getElementById(isReplace ? 'passkey-replace-cancel-btn' : 'passkey-cancel-btn');
  saveBtn.onclick = () => sendPasskeyCreateConfirm(requestId, entryId, isReplace);
  cancelBtn.onclick = () => sendPasskeyCancel(requestId);
}

function wirePasskeyGetButtons(requestId, entryId) {
  document.getElementById('passkey-approve-btn').onclick = () => sendPasskeyGetApprove(requestId, entryId);
  document.getElementById('passkey-use-cancel-btn').onclick = () => sendPasskeyCancel(requestId);
}
```

Wire the settings toggle, reading current state via `getPasskeyProxyStatus` on popup open and sending `setPasskeyProxyEnabled` on change:

```js
function initPasskeySettingsToggle(url) {
  const toggle = document.getElementById('passkey-proxy-toggle');
  chrome.runtime.sendMessage({ type: 'getPasskeyProxyStatus', url }, (status) => {
    toggle.checked = !!(status && status.attachAllowed);
    toggle.disabled = !(status && status.unlocked && status.paired);
  });
  toggle.addEventListener('change', () => {
    chrome.runtime.sendMessage({ type: 'setPasskeyProxyEnabled', enabled: toggle.checked });
  });
}
```

Call `rehydratePendingPasskeyCeremony()` and `initPasskeySettingsToggle(activeTab.url)` during the existing popup-open init flow, alongside the existing `queryCredentials(activeTab.url)` call.

Add every new function intended for direct testing (`renderPasskeyCeremonyPanel`, `renderPasskeyPicker`, `sendPasskeyCreateConfirm`, `sendPasskeyGetApprove`, `sendPasskeyCancel`) to `module.exports`.

- [ ] **Step 4: Manual verification**

Run: `xcodebuild build ...` is not applicable here (JS-only); run `node -c ChromeExtension/popup.js` to catch syntax errors, and `node ChromeExtension/tests/popup-fallback.test.js` to confirm the existing popup tests still pass (this file requires `../popup.js` and would throw on a syntax error or a broken top-level DOM-wiring block).

- [ ] **Step 5: Commit**

```bash
git add ChromeExtension/popup.html ChromeExtension/popup.js
git commit -m "feat(chrome): add passkey confirm, replace, approve, and picker panels"
```

---

### Task 10: Manual e2e fixtures and `RUN.md` checklist

**Files:**
- Create: `ChromeExtension/tests/fixtures/webauthn-create.html`
- Create: `ChromeExtension/tests/fixtures/webauthn-get.html`
- Modify: `RUN.md`

- [ ] **Step 1: Create the create-ceremony fixture**

Write `ChromeExtension/tests/fixtures/webauthn-create.html`:

```html
<!DOCTYPE html>
<html>
<head><meta charset="utf-8"><title>MyPass WebAuthn create fixture</title></head>
<body>
  <h1>Register a passkey</h1>
  <button id="register-btn">Create passkey</button>
  <pre id="result"></pre>
  <script>
    function randomBytes(n) {
      const arr = new Uint8Array(n);
      crypto.getRandomValues(arr);
      return arr;
    }
    document.getElementById('register-btn').addEventListener('click', async () => {
      try {
        const credential = await navigator.credentials.create({
          publicKey: {
            challenge: randomBytes(32),
            rp: { id: location.hostname, name: 'MyPass Fixture' },
            user: { id: randomBytes(16), name: 'fixture-user', displayName: 'Fixture User' },
            pubKeyCredParams: [{ type: 'public-key', alg: -7 }],
            attestation: 'none',
          },
        });
        document.getElementById('result').textContent = JSON.stringify(credential.toJSON(), null, 2);
      } catch (error) {
        document.getElementById('result').textContent = 'Error: ' + error.name + ' — ' + error.message;
      }
    });
  </script>
</body>
</html>
```

- [ ] **Step 2: Create the get-ceremony fixture**

Write `ChromeExtension/tests/fixtures/webauthn-get.html`:

```html
<!DOCTYPE html>
<html>
<head><meta charset="utf-8"><title>MyPass WebAuthn get fixture</title></head>
<body>
  <h1>Sign in with a passkey</h1>
  <button id="signin-btn">Sign in with passkey</button>
  <pre id="result"></pre>
  <script>
    function randomBytes(n) {
      const arr = new Uint8Array(n);
      crypto.getRandomValues(arr);
      return arr;
    }
    document.getElementById('signin-btn').addEventListener('click', async () => {
      try {
        const credential = await navigator.credentials.get({
          publicKey: { challenge: randomBytes(32), rpId: location.hostname, allowCredentials: [] },
        });
        document.getElementById('result').textContent = JSON.stringify(credential.toJSON(), null, 2);
      } catch (error) {
        document.getElementById('result').textContent = 'Error: ' + error.name + ' — ' + error.message;
      }
    });
  </script>
</body>
</html>
```

- [ ] **Step 3: Verify fixtures are served correctly**

Run: `cd ChromeExtension/tests/fixtures && python3 -m http.server 8765 &`
Then: `curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8765/webauthn-create.html` and `.../webauthn-get.html`
Expected: both print `200`. Stop the server: `kill %1`.

Note: `navigator.credentials.create()`/`.get()` require a secure context — `http://localhost:8765` qualifies (localhost is treated as secure by Chrome), so this fixture works over plain HTTP on localhost without needing TLS setup.

- [ ] **Step 4: Add manual e2e bullets to `RUN.md`**

Find the "Короткий чеклист" list under `### Chrome e2e (ручна перевірка)` in `RUN.md` and append after its last existing bullet:

```markdown
     - [ ] **Use MyPass for Chrome passkeys** вимкнено за замовчуванням; увімкнення при розблокованому сховищі підключає proxy; вимкнення відключає
     - [ ] Блокування сховища → proxy відключається; вхід через passkey на фікстурному сайті завершується помилкою без падіння
     - [ ] Реєстрація на webauthn.io (або фікстурі): **Save passkey** підтвердження → запис у MyPass з полями KPEX; вхід через **Approve** успішний
     - [ ] Сайт з існуючим Login-записом: створення пропонує зберегти в цей запис; повторне створення показує **Replace passkey?**
     - [ ] Кілька записів на одному домені: пікер показується і для створення, і для входу
     - [ ] Cancel у popup → сайт показує скасування; без запису у сховище при перерваному створенні
     - [ ] При підключеному MyPass passkey з iCloud Keychain не пропонується до відключення (очікувана ексклюзивність)
     - [ ] Експорт KDBX → відкрити в KeePassXC → поля passkey видимі на Login-записі
```

(`RUN.md` is Ukrainian by project convention — do not translate any of it.)

- [ ] **Step 5: Commit**

```bash
git add ChromeExtension/tests/fixtures/webauthn-create.html ChromeExtension/tests/fixtures/webauthn-get.html RUN.md
git commit -m "docs(chrome): add passkey manual e2e fixtures and checklist bullets"
```

---

### Task 11: Full verification run

**Files:** none (verification only).

- [ ] **Step 1: Run the full test suite**

Run: `./scripts/test.sh`
Expected: PASS end-to-end — `xcodebuild test` (including all new `ExtensionBridgeServiceTests`, `PasskeyCeremonyTests`, `KdbxEntryPasskeyTests` cases), `swift test` for `ExtensionBridgeKit` (new `ExtensionBridgeMessagesTests` cases), and every `node ChromeExtension/tests/*.test.js` line including `passkeyProxy.test.js`.

- [ ] **Step 2: Cross-check acceptance criteria against the spec**

Confirm each of the following, from `docs/superpowers/specs/2026-08-01-chrome-extension-passkeys-design.md`'s Acceptance Criteria section:

1. **Default off** — `passkeyProxyEnabled` defaults `false` in both `@AppStorage` (Task 5) and `chrome.storage.local` (Task 8's `attachPasskeyProxyIfEligible` no-ops when unset/false).
2. **Opt-in attach** — `testGetPasskeyProxyStatusReportsUnlockedEvenWhileVaultCheckWouldOtherwiseGateLocked`-adjacent tests plus `passkeyProxy.test.js`'s `attachPasskeyProxyIfEligible` tests.
3. **Detach on lock** — verify manually per Task 10's checklist (no automated lock-triggers-detach test exists since that requires live Chrome extension lifecycle — flag this as a manual-only guarantee if true).
4. **Create ES256** — `testPerformCreateProducesValidSelfAttestationSignature`, `testPasskeyCreateThenConfirmWritesEntryAndReturnsResponseJson`.
5. **Create confirm** — `pendingPasskeyCreates` only mutates the vault in `passkeyCreateConfirm`, never in `passkeyCreate`; `testPasskeyCreateConfirmRequiresReplaceFlagWhenEntryAlreadyHasPasskey`.
6. **Get Approve** — `testPasskeyGetThenApproveSignsAssertion` — no signing happens in `passkeyGet`, only in `passkeyGetApprove`.
7. **Get picker** — `renderPasskeyPicker`/`renderPasskeyCeremonyPanel`'s `matches.length > 1` branch (Task 9).
8. **Get allowCredentials** — `testParseGetRequestExtractsRpIdAndAllowCredentials`, and `passkeyGet`'s `context.allowCredentialIds.contains` filter.
9. **Cancel** — `testPasskeyCancelClearsPendingStateForBothCreateAndGet`.
10. **No key in extension** — grep the diff for anywhere `passkeyPrivateKeyPEM`/PEM strings might cross into a `ChromeExtension/*.js` file or a bridge response type other than what stays server-side — there should be none; `PasskeyCreateResult`/`PasskeyGetResult`'s `privateKeyPEM` field (Task 3) is consumed only inside `ExtensionBridgeService.swift`, never placed on any `ExtensionBridgeResponse` case.
11. **Algorithm gate** — `testPasskeyCreateReturnsUnsupportedAlgorithmError`.
12. **isUvpaa** — Task 8's `onIsUvpaaRequest` listener only replies `true` when `status.unlocked`, and the listener is only registered/reachable when the proxy machinery exists at all (still gated by the outer `attach()`ed state via Chrome's own routing — Chrome doesn't deliver these events to a detached extension).
13. **Security** — every new case in `ExtensionBridgeService.handle` gates on `pairingManager.isAuthorized(pairing:)` first; origin is shown on every popup confirm panel per Task 9's `summaryText`.
14. **Tests** — confirmed by Step 1's green `./scripts/test.sh`.

If any criterion doesn't hold, or if Task 8's required live-Chrome checkpoint was skipped, stop and fix/verify before considering the plan complete.
