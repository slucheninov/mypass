# MyPass — Chrome Extension Pairing: Design

Design spec for a user-visible pairing layer on top of the existing Phase 4 Chrome
extension bridge. Implementation plan:
`docs/superpowers/plans/2026-07-26-mypass-extension-pairing.md`.

References:

- Phase 4 Chrome design: `docs/superpowers/specs/2026-07-25-mypass-phase4-chrome-extension-design.md`
- General security model: `docs/superpowers/specs/2026-07-21-mypass-design.md`

## Overview

Pairing follows an iCloud Passwords–style trust flow: before the Chrome extension
can read or save credentials through MyPass, the user confirms trust once by typing
a **6-digit code** displayed by the MyPass app into the extension popup. Pairing
persists across app launches until the user revokes it in **Settings → Browser**.

Pairing is **in addition to** the existing loopback token layer (see below). It does
not replace native-messaging origin pinning, ChromeHost relay, or per-launch
loopback authorization.

## Current Trust Model (Background)

The existing stack (unchanged by pairing):

1. **Extension origin** — pinned extension ID `hjijbabodfldconmhdcdphlbgaajkejn`
   (`ChromeExtension/manifest.json` `key` field); native messaging manifest
   `allowed_origins` restricts ChromeHost to that ID only.
2. **Native messaging** — `background.js` → `chrome.runtime.sendNativeMessage`
   → `ChromeHost` over stdio framing.
3. **Loopback token** — `ChromeHost` reads port+token from shared Keychain access
   group `com.mypass.app.keychain` (`ExtensionBridgeTokenStore`), injects `token`
   into every relayed JSON request via `RelayTokenInjector.injectToken(into:token:)`
   (generic — adds/overwrites `"token"` on any JSON object, no type allowlist).
4. **TCP bridge** — `ChromeHost` → `127.0.0.1:<port>` → `LoopbackServer` validates
   token, dispatches to `ExtensionBridgeService.handle(_:)`.

Pairing adds a **persistent, user-visible authorization layer** on top of step 4:
even with a valid loopback token, credential and save-proposal operations require a
valid pairing secret unless the user has completed the one-time code flow.

## Requirements

### When pairing is required

These operations return `.pairingRequired` when the vault is unlocked but the request
carries no valid pairing secret:

- `getCredentials`
- `fillCredential`
- `proposeSaveLogin`

These operations are allowed without a prior pairing secret (vault must be unlocked):

- `startPairing` — begins a new code challenge
- `completePairing` — submits the code from the extension

When the vault is **locked**, **all five** request types return `.locked` before any
pairing logic runs.

### Code challenge

- **Format:** 6 decimal digits, cryptographically random (via `SecRandomCopyBytes`,
  same family as `ExtensionBridgeTokenStore.generateToken()`).
- **Display:** grouped as `123 456` in the app UI (space for readability only; wire
  value is six digits without separator).
- **TTL:** 120 seconds from `startPairing()`; expired codes are rejected.
- **Attempts:** max 4 usable `completePairing` submissions per active challenge (the
  attempt counter increments at the start of every call; the 5th call fails regardless
  of code correctness); on exhaustion the challenge is invalidated (user must tap
  Connect again).
- **Vault state:** pairing may only start or complete while the vault is unlocked
  (enforced by the `.locked` gate in `ExtensionBridgeService`).

### Pairing secret

- **Generation:** 32 random bytes, base64-encoded (same size/encoding as loopback
  tokens from `ExtensionBridgeTokenStore.generateToken()`).
- **Extension storage:** full secret in `chrome.storage.local` under key
  `pairingSecret`.
- **App storage:** SHA-256 hash of the secret only, in Keychain — **app-only**, no
  shared access group (unlike `ExtensionBridgeTokenStore`, which uses
  `com.mypass.app.keychain` for ChromeHost cross-process reads).
- **Validation:** `containsSecret(matching:)` hashes the presented secret and
  compares to stored hashes with **constant-time** comparison (`Data.timingSafeEqual`
  or equivalent).
- **Residual risk:** the extension-side pairing secret lives in
  `chrome.storage.local` in cleartext and is only usable together with the loopback
  relay token (another local attacker with extension storage access could pair or
  replay credential requests until revocation).
- **Multiple browsers:** multiple Chromium-family browsers supported from day one;
  each browser instance pairs separately (its own `chrome.storage.local` secret) and
  appears as its own row in **Settings → Paired browsers**, labeled by self-reported
  browser name. Each successful pairing creates a new `PairedBrowser` record
  (separate Keychain item); any valid stored secret authorizes requests.
- **Revocation:** Settings → Browser lists paired browsers; **Revoke** removes that
  Keychain item. The extension's stale secret then fails validation → popup returns
  to the Connect flow.

## Protocol Changes (ExtensionBridgeKit)

Wire JSON keeps the existing `"type"` discriminator style from
`ExtensionBridgeMessages.swift`. Final Swift API:

```swift
public enum ExtensionBridgeRequest: Equatable {
    case getCredentials(token: String, url: String, pairing: String?)
    case fillCredential(token: String, id: String, url: String, pairing: String?)
    case proposeSaveLogin(token: String, url: String, username: String, password: String, pairing: String?)
    case startPairing(token: String, browser: String?)
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

### Request wire shapes

| `type` | Fields |
|--------|--------|
| `getCredentials` | `token`, `url`, optional `pairing` |
| `fillCredential` | `token`, `id`, `url`, optional `pairing` |
| `proposeSaveLogin` | `token`, `url`, `username`, `password`, optional `pairing` |
| `startPairing` | `token`, optional `browser` |
| `completePairing` | `token`, `code` |

The optional `pairing` field is omitted or `null` when the extension has no stored
secret yet. The optional `browser` field on `startPairing` is omitted or `null` when
the extension does not report a name (the app falls back to `"Chromium browser"`).

### Response wire shapes

| `type` | Fields |
|--------|--------|
| `locked` | (none) |
| `pairingRequired` | (none) |
| `pairingStarted` | (none) |
| `paired` | `secret` (base64, 32 random bytes) |
| `credentialList` | `credentials` (unchanged) |
| `credential` | `username`, `password`, optional `totp` (unchanged) |
| `saveProposalAccepted` | (none) |
| `error` | `message` — new value **`invalid_code`** for expired/wrong/exhausted code |

### RelayTokenInjector and LoopbackServer

- **`RelayTokenInjector`** — no change required. It injects `"token"` into any valid
  JSON object regardless of `"type"`; new `startPairing` / `completePairing` messages
  are covered automatically.
- **`LoopbackServer.requestToken(from:)`** — must be updated to extract `token` from
  all five enum cases (today it pattern-matches only the three data requests).

## App Components

### ExtensionPairingStore

```swift
// MyPass/State/ExtensionBridge/ExtensionPairingStore.swift

struct PairedBrowser: Codable, Equatable, Identifiable {
    let id: UUID
    let label: String
    let createdAt: Date
    let secretHash: String
}

protocol ExtensionPairingStoring: AnyObject {
    func list() -> [PairedBrowser]
    func add(_ browser: PairedBrowser) throws
    func remove(id: UUID) throws
    func containsSecret(matching secret: String) -> Bool
}

final class KeychainExtensionPairingStore: ExtensionPairingStoring
// Keychain generic password, service "com.mypass.extension.pairing",
// one item per PairedBrowser (account = id.uuidString),
// value = JSON-encoded PairedBrowser, NO kSecAttrAccessGroup (app-only)

final class InMemoryExtensionPairingStore: ExtensionPairingStoring
// for tests and previews
```

Keychain pattern mirrors `ExtensionBridgeTokenStore` (generic password, JSON payload,
`SecItemDelete` before add, `kSecAttrAccessibleAfterFirstUnlock`) but **without**
`kSecAttrAccessGroup`, since ChromeHost must never read pairing secrets.

### ExtensionPairingManager

```swift
// MyPass/State/ExtensionBridge/ExtensionPairingManager.swift

final class ExtensionPairingManager {
    init(store: ExtensionPairingStoring, now: @escaping () -> Date = Date.init)

    var onCodeGenerated: ((String) -> Void)?
    var onPairingFinished: (() -> Void)?

    func startPairing(browser: String?) -> String
    func completePairing(code: String) -> String?
    func cancelPairing()
    func isAuthorized(pairing: String?) -> Bool
}
```

Behavior:

- `startPairing(browser:)` — stores `pendingBrowserLabel = browser ?? "Chromium browser"`;
  generates new 6-digit code, sets expiry = `now() + 120s`, resets attempts to 0,
  fires `onCodeGenerated(code)`, returns the code.
- `completePairing(code:)` — returns `nil` → service responds `.error("invalid_code")`
  when: no active challenge, expired, code mismatch, or attempts ≥ 5 after this
  failure. On success: generates 32-byte base64 secret, stores
  `PairedBrowser(label: pendingBrowserLabel, createdAt: now(), secretHash: sha256(secret))`,
  clears active challenge, fires `onPairingFinished()`, returns the secret.
- `cancelPairing()` — clears active challenge, fires `onPairingFinished()`.
- `isAuthorized(pairing:)` — `nil` or unknown secret → `false`; else delegates to
  `store.containsSecret(matching:)`.

### Gate in ExtensionBridgeService.handle

`ExtensionBridgeService` gains an `extensionPairingManager: ExtensionPairingManager`
dependency. Order of checks in `handle(_:)`:

1. **Vault locked** (`vaultSession?.currentDatabase == nil`) → `.locked` for **all
   five** request types.
2. **`startPairing`** → `manager.startPairing(browser: browser)` (side effect: UI
   callback), return `.pairingStarted`.
3. **`completePairing`** → if let secret = `manager.completePairing(code:)` return
   `.paired(secret: secret)`; else `.error("invalid_code")`.
4. **Data requests** (`getCredentials`, `fillCredential`, `proposeSaveLogin`) → if
   `!manager.isAuthorized(pairing:)` return `.pairingRequired`; else existing logic
   unchanged (domain matching, `onSaveProposal`, etc.).

Existing `onSaveProposal` wiring in `MyPassApp.init()` remains; pairing gate runs
before save-proposal logic.

## App UI

### NavigationState

Add:

```swift
@Published var pendingPairingCode: String?
```

### MyPassApp wiring

Mirror the `onSaveProposal` pattern in `MyPassApp.init()`:

```swift
extensionPairingManager.onCodeGenerated = { [weak navigationState] code in
    DispatchQueue.main.async {
        navigationState?.pendingPairingCode = code
        MainWindowActivator.request()
    }
}
extensionPairingManager.onPairingFinished = { [weak navigationState] in
    DispatchQueue.main.async {
        navigationState?.pendingPairingCode = nil
    }
}
```

Shared instances (`KeychainExtensionPairingStore`, `ExtensionPairingManager`) are
created in `MyPassApp.init()` alongside `ExtensionBridgeService` / `LoopbackServer`,
stored on `AppDelegate` for Settings access (same pattern as
`AppDelegate.extensionBridgeServer`).

### PairingCodeSheet

New view: `MyPass/UI/ExtensionPairing/PairingCodeSheet.swift`

- Title: **Connect browser extension**
- Code: large monospaced, grouped (`123 456`)
- Subtitle: **Enter this code in the MyPass browser extension.**
- **Cancel** → `extensionPairingManager.cancelPairing()` (clears
  `pendingPairingCode` via `onPairingFinished`)

`ContentView` presents the sheet when `navigationState.pendingPairingCode != nil`
(`.sheet(isPresented:)` or equivalent), only in the unlocked branch (pairing requires
an unlocked vault).

### Settings → Browser

`BrowserSettingsPane` gains a **Paired browsers** section:

- Lists `store.list()` rows: label + formatted creation date
- **Revoke** button per row → `store.remove(id:)`, refresh list

The pairing store is injected via `@EnvironmentObject` from `SettingsView` (same
pattern as `SecuritySettingsPane` receiving `vaultSession`).

## Extension UX

### background.js

- On startup / before data requests: read `pairingSecret` from
  `chrome.storage.local`.
- Add optional `"pairing"` field to `getCredentials`, `fillCredential`,
  `proposeSaveLogin` when a secret exists.
- Extend `knownTypes` to include `startPairing`, `completePairing`.
- Export `detectBrowserName()` — reads `navigator.userAgentData.brands`, picks the
  first non-`Chromium` brand that is not a `Not.A.Brand` placeholder, otherwise
  returns `"Chromium browser"`. The label is **self-reported** (informational for
  Settings display, not a security boundary).
- Handle popup messages `{type: "startPairing", browser: detectBrowserName()}` and
  `{type: "completePairing", code: "123456"}` by forwarding via `sendNativeMessage`.
- On response `type === "paired"`: save `response.secret` to
  `chrome.storage.local` as `pairingSecret` before resolving to caller.
- On data-request response `type === "pairingRequired"` when a stored secret existed:
  remove stale `pairingSecret` from storage, then return response to caller.

### popup.js / popup.html

- On `getCredentials` response `type === "pairingRequired"`: hide credential list,
  show **Connect to MyPass** button.
- Connect click → send `{type: "startPairing"}` via `chrome.runtime.sendMessage`
  (background.js adds `browser: detectBrowserName()` before native relay), show
  6-digit numeric input with hint **Enter the code shown in MyPass**.
- Submit code → `{type: "completePairing", code}`; on `paired` → re-run credential
  query for the active tab URL.
- Existing `locked` and `error` / `app_not_running` UX unchanged.

### content.js

Treat `pairingRequired` like `locked` for save-banner purposes: set
`state.vaultLocked = true` (or equivalent flag) so the "Save password to MyPass?"
banner does not appear when pairing is missing.

## Multi-browser installation

`scripts/setup-chrome-extension.sh` installs the native messaging manifest
(`com.mypass.chromehost.json`) into **every installed Chromium-family browser** under
`~/Library/Application Support`, not only Google Chrome. It iterates a fixed list of
base directories (Chrome stable/beta/canary/dev, Chromium, Edge variants, Brave
variants, Vivaldi, Opera, Opera GX, Arc) and writes
`<base>/NativeMessagingHosts/com.mypass.chromehost.json` for each base directory that
exists. Non-installed browsers are skipped, except **Google/Chrome** — that directory
is always created if missing. The script prints each installed location. The same
unpacked extension (pinned ID) loads in each browser; each browser pairs separately
via its own `chrome.storage.local` secret and appears under **Settings → Paired
browsers** with its self-reported name.

## Error Handling

| Scenario | Response | UX |
|----------|----------|-----|
| Vault locked | `.locked` | Existing "Open MyPass and unlock" popup copy |
| No valid pairing secret | `.pairingRequired` | Connect flow in popup; no save banner in content script |
| Wrong/expired code / 5 failures | `.error("invalid_code")` | Extension restarts Connect flow |
| App relaunch mid-pairing | `.error("invalid_code")` | In-memory challenge lost; user restarts Connect |
| Revoked pairing | `.pairingRequired` | Stale secret cleared; Connect flow |
| Invalid loopback token | `.error("invalid token")` | Unchanged Phase 4 behavior |

## Testing

### Swift

- **ExtensionBridgeMessagesTests** — round-trip all new request/response types; verify
  JSON shapes (`pairing`, `browser`, `code`, `secret`, `pairingRequired`,
  `invalid_code`).
- **ExtensionPairingManagerTests** — injected `now()` clock: code format, TTL expiry,
  5-attempt lockout, cancel, secret issuance, store write on success; browser label
  from `startPairing(browser:)` parameter and `"Chromium browser"` fallback when nil.
- **ExtensionBridgeServiceTests** — gate ordering with `InMemoryExtensionPairingStore`:
  locked blocks all types; unauthorized data requests → `pairingRequired`; authorized
  → existing behavior; start/complete pairing flows.
- **KeychainExtensionPairingStoreTests** — gated by `MYPASS_KEYCHAIN_TESTS=1` (same
  convention as `ExtensionBridgeTokenStoreTests`).

Run commands:

```sh
cd Packages/ExtensionBridgeKit && swift test
xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS'
MYPASS_KEYCHAIN_TESTS=1 swift test --filter KeychainExtensionPairingStoreTests  # optional
```

### JavaScript

- **`ChromeExtension/tests/pairing.test.js`** — mock `chrome.storage.local` and
  `chrome.runtime.sendNativeMessage`; exercise background pairing message forwarding,
  secret persistence on `paired`, stale-secret clearing on `pairingRequired`, and
  `detectBrowserName()` (e.g. brands `[{brand:"Google Chrome"},{brand:"Chromium"},
  {brand:"Not.A/Brand"}]` → `"Google Chrome"`; missing `userAgentData` →
  `"Chromium browser"`).
- Registered in `scripts/test.sh` alongside existing extension tests.

## Out of Scope

- PAKE or encrypted pairing payloads
- Firefox and Safari (different native messaging manifest formats / extension APIs)
- Chrome Web Store distribution concerns
- UI localization (English strings in source until Phase 7)
