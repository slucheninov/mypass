# Chrome Extension — Passkeys (Create + Get)

**Date:** 2026-08-01  
**Status:** Approved

Follow-up to [2026-07-25-mypass-phase4-chrome-extension-design.md](./2026-07-25-mypass-phase4-chrome-extension-design.md) and companion to [2026-08-01-chrome-extension-totp-autofill-design.md](./2026-08-01-chrome-extension-totp-autofill-design.md) (piece A) and [2026-08-01-chrome-extension-totp-setup-design.md](./2026-08-01-chrome-extension-totp-setup-design.md) (piece B). Implements **piece C only**: full WebAuthn **register** (`navigator.credentials.create`) and **authenticate** (`navigator.credentials.get`) in Chrome via `chrome.webAuthenticationProxy`, with MyPass as the authenticator and KeePassXC-compatible vault storage. Master design Phase 6 scope: [2026-07-21-mypass-design.md](./2026-07-21-mypass-design.md) (Passkeys — KeePassXC convention).

## Problem

Websites increasingly require passkeys for sign-in and account creation. Phase 4 Chrome extension covers username/password autofill and save proposals; pieces A and B add TOTP consumption and setup. None of that addresses WebAuthn ceremonies initiated by pages (`navigator.credentials.create` / `.get`). Chrome exposes `chrome.webAuthenticationProxy` (Chrome 115+, MV3) so an extension can intercept those calls and complete them via a local authenticator — the same API family remote-desktop tools use to forward WebAuthn to a local security key.

MyPass must participate in that flow without storing private keys in the extension or Chrome profile: keys live in the user's KDBX vault, readable by KeePassXC-compatible clients, while the extension remains a thin ceremony relay with explicit user confirmation on every create and every get.

## Goals

- **Full Chrome WebAuthn cycle (MVP)** — handle `onCreateRequest`, `onGetRequest`, and `onIsUvpaaRequest` via `chrome.webAuthenticationProxy`; complete ceremonies with `completeCreateRequest`, `completeGetRequest`, and `completeIsUvpaaRequest`.
- **MyPass as authenticator** — extension forwards ceremony JSON to the macOS app over the existing native-messaging + loopback bridge; app generates keys, signs assertions, and persists credentials after user confirmation.
- **KeePassXC-compatible storage** — passkey material stored as `KPEX_PASSKEY_*` custom fields on existing **Login** entries (no new `EntryType`; no Secure Enclave).
- **Explicit consent only** — **Create:** always show confirm before vault write; **Get:** always require an **Approve** click (entry picker when >1 match). Never silent auto-sign or auto-save.
- **Opt-in proxy attach (approach 1, approved)** — user enables **Use MyPass for Chrome passkeys** (default **off**). While attached and vault unlocked + paired, MyPass is the exclusive WebAuthn proxy; platform passkey UI is suspended for Chrome. Detach restores normal Chrome WebAuthn.
- **ES256 only (MVP)** — accept create requests whose `pubKeyCredParams` includes ES256 (-7); reject or error other algorithms at the app boundary with a clear user-facing message.

## Non-goals

- **Piece A / B** — TOTP autofill, privacy circle, 2FA setup banners (orthogonal; may share popup shell and `getCredentials` list).
- **Safari** extension or **ASCredentialProvider** (Phase 4b / iOS Phase 5).
- **Secure Enclave** or platform-bound keys — software keys in vault only.
- **Conditional UI** (`mediation: "conditional"`) without proxy attach — not supported in MVP; pages must trigger discoverable/non-discoverable ceremonies while proxy is attached.
- **Non-ES256 algorithms** — EdDSA, RS256 deferred.
- **Always-on attach** — proxy remains opt-in; no silent attach on extension install.
- **New EntryType** — passkeys attach to Login entries via custom fields.
- **Attestation formats beyond MVP needs** — packed self-attestation for create responses; no FIDO U2F / TPM attestation.

## Design

### Scope boundary

| Piece | Description | In this spec |
|-------|-------------|--------------|
| **A** | TOTP autofill + popup privacy circle | No |
| **B** | 2FA setup / QR in extension | No |
| **C** | Passkeys create + get via WebAuthn proxy | **Yes** |

### Architecture & ceremonies

**Trust model** (extends Phase 4 + pairing):

- Browser extension ↔ ChromeHost via native messaging (`allowed_origins` restricted to extension ID).
- ChromeHost ↔ MyPass app via loopback TCP + per-session Keychain token.
- Pairing secret required for passkey bridge messages (same gate as `fillCredential`).
- **Private keys never leave the app** — extension sees only WebAuthn ceremony JSON (`requestDetailsJson` in / `responseJson` or `error` out). PEM material stays in KDBX after explicit save.
- Vault must be **unlocked** for attach and for completing ceremonies; locked → error response to Chrome + detach if attach was active.

**Opt-in attach / detach lifecycle**

| Event | Extension action |
|-------|------------------|
| User enables **Use MyPass for Chrome passkeys** (popup or app Settings) | If unlocked + paired → `chrome.webAuthenticationProxy.attach()`; persist `passkeyProxyEnabled: true` in `chrome.storage.local` |
| User disables setting | `detach()`; clear attach intent; platform WebAuthn resumes |
| Vault locks (app auto-lock or manual) | `detach()`; notify popup if open; pending ceremonies canceled |
| Pairing revoked / missing | `detach()`; block re-attach until paired |
| Extension unload / browser restart | Chrome auto-detaches; on service worker start, re-attach **only if** setting on **and** fresh `getPasskeyProxyStatus` from app confirms unlocked + paired |
| Another extension already attached | `attach()` fails → show **Another passkey provider is active**; keep setting off until user resolves |
| App quit / host unavailable | Treat as locked; `detach()`; ceremonies fail with `NotAllowedError`-class DOMException to page |

**Exclusive attach:** While MyPass holds the proxy, Chrome suspends the built-in platform authenticator for intercepted requests. Users who need iCloud Keychain or a security key for a site must disable MyPass passkeys (detach) first — product copy must state this clearly in Settings.

**Bridge messages** (app ↔ extension via ChromeHost; JSON shapes in `ExtensionBridgeKit`):

| Message | Direction | Payload | Response |
|---------|-----------|---------|----------|
| `getPasskeyProxyStatus` | extension → app | optional `pairing` | `{ type: "passkeyProxyStatus", unlocked: bool, paired: bool, attachAllowed: bool }` |
| `setPasskeyProxyEnabled` | extension → app | `enabled: bool`, optional `pairing` | `{ type: "passkeyProxyEnabled", enabled: bool }` — app persists user preference (`UserDefaults` / settings store) for Settings UI parity |
| `passkeyCreate` | extension → app | `requestId`, `requestDetailsJson`, `originUrl`, optional `pairing` | `{ type: "passkeyCreatePending" }` immediately; later `{ type: "passkeyCreateComplete", requestId, responseJson? \| error? }` via async push or polling — **implementation plan chooses push over existing loopback connection vs. long-poll**; spec requires single in-flight create per `requestId` |
| `passkeyGet` | extension → app | `requestId`, `requestDetailsJson`, `originUrl`, optional `pairing` | Same pending → complete pattern as create |
| `passkeyCancel` | extension → app | `requestId`, optional `pairing` | `{ type: "ok" }` — app aborts pending UI and does not write vault |
| `passkeyCeremonyComplete` | app → extension (internal) | N/A — completion returned on the pending bridge reply channel | Extension calls `completeCreateRequest` / `completeGetRequest` |

ChromeHost forwards opaquely. Ceremony completion is **app-driven** after popup/app user action.

**Extension `background.js` responsibilities**

1. Register `onCreateRequest`, `onGetRequest`, `onIsUvpaaRequest`, `onRequestCanceled` listeners at service worker load (synchronous registration per Chrome docs).
2. On each request: if not attached or app status not ready → complete with `NotAllowedError` (`name: "NotAllowedError"`, message: `"MyPass passkeys unavailable"`).
3. Forward to app via `passkeyCreate` / `passkeyGet`; open popup for user confirm (see Popup UX).
4. On app completion → `completeCreateRequest` / `completeGetRequest` with `responseJson` or `error`.
5. On `onRequestCanceled` or local timeout → forward `passkeyCancel` to app; drop pending state.

**isUvpaa handling**

When proxy is **attached** and unlocked:

- Respond to `onIsUvpaaRequest` with `completeIsUvpaaRequest({ requestId, isUvpaa: true })` so sites offering passkey-first UX detect a platform authenticator.
- When **detached** or setting off: do not register isUvpaa listener behavior (Chrome uses real platform authenticator).

When attached but **locked**: complete isUvpaa with `isUvpaa: false` (or detach immediately — product choice: **return false while locked without claiming attach**; attach only when unlocked).

```mermaid
sequenceDiagram
    participant Page as Website
    participant Chrome as Chrome WebAuthn
    participant BG as background.js
    participant Host as ChromeHost
    participant App as PasskeyCeremony + Vault
    participant Popup as popup.js

    Note over BG,App: Opt-in attach (unlocked + paired)
    Popup->>BG: setPasskeyProxyEnabled { enabled: true }
    BG->>Host: forward
    Host->>App: setPasskeyProxyEnabled
    BG->>Chrome: webAuthenticationProxy.attach()

    Note over Page,Popup: Create (register)
    Page->>Chrome: credentials.create()
    Chrome->>BG: onCreateRequest { requestId, requestDetailsJson }
    BG->>Host: passkeyCreate { requestId, requestDetailsJson, originUrl }
    Host->>App: passkeyCreate
    App->>App: parse options, ES256 check, match entries 0/1/N
    BG->>Popup: openPopup (Save passkey / picker)
    Popup->>Host: user confirms Save
    Host->>App: confirm create + target entryId
    App->>App: generate ES256 keypair, build response, mutate KDBX
    App-->>Host: passkeyCreateComplete { responseJson }
    Host-->>BG: passkeyCreateComplete
    BG->>Chrome: completeCreateRequest { responseJson }
    Chrome-->>Page: PublicKeyCredential

    Note over Page,Popup: Get (authenticate)
    Page->>Chrome: credentials.get()
    Chrome->>BG: onGetRequest { requestId, requestDetailsJson }
    BG->>Host: passkeyGet
    Host->>App: passkeyGet
    App->>App: match by RP + allowCredentials
    BG->>Popup: openPopup (Use passkey / picker)
    Popup->>Host: user Approve
    App->>App: sign assertion
    App-->>Host: passkeyGetComplete { responseJson }
    BG->>Chrome: completeGetRequest { responseJson }

    Note over Page,Chrome: Cancel / timeout
    Page->>Chrome: abort
    Chrome->>BG: onRequestCanceled(requestId)
    BG->>Host: passkeyCancel
    BG->>Chrome: (no complete* call)
```

### KDBX / Login model + matching

Passkeys are stored on **Login** entries using KeePassXC custom attributes (protected where noted). No separate entry type.

| Field | Content | Protected |
|-------|---------|-----------|
| `KPEX_PASSKEY_RELYING_PARTY` | Relying party ID (registrable domain, e.g. `github.com`) | No |
| `KPEX_PASSKEY_CREDENTIAL_ID` | Base64url-encoded credential ID | Yes |
| `KPEX_PASSKEY_PRIVATE_KEY_PEM` | PKCS#8 PEM (`-----BEGIN PRIVATE KEY-----` …) ES256 | Yes |
| `KPEX_PASSKEY_USER_HANDLE` | Base64url-encoded user handle from registration | Yes |
| `KPEX_PASSKEY_USERNAME` | Display username from registration (mirrors entry login when set) | No |
| `KPEX_PASSKEY_FLAG_BE` | Backup eligibility `1` or `0` (optional; default `1` at implementation for KeePassXC interop) | No |
| `KPEX_PASSKEY_FLAG_BS` | Backup state `1` or `0` (optional; default `1`) | No |

**Entry invariants**

- An entry is passkey-capable when `KPEX_PASSKEY_PRIVATE_KEY_PEM` is non-empty and `KPEX_PASSKEY_RELYING_PARTY` matches the ceremony RP ID.
- Multiple passkeys on one Login entry are **not** supported in MVP — one passkey field set per entry; second create on same entry triggers **Replace passkey?** flow.
- `getCredentials` gains optional `hasPasskey: Bool` (true when private key field present) for popup picker badges — same pattern as `hasTotp`.

**Create routing (after user initiates register on page)**

1. Parse `PublicKeyCredentialCreationOptions` from `requestDetailsJson`.
2. Extract `rp.id` (or derive from `rp.name` / origin per WebAuthn rules).
3. Require ES256 in `pubKeyCredParams` (-7); else fail ceremony with `NotSupportedError`.
4. Domain-match Login entries for page origin via `ExtensionEntryMatcher` + existing URL association.
5. Route:
   - **0 matches** — popup **Save passkey** panel: create new Login (title default = registrable domain) or user picks group in app on confirm.
   - **1 match** — popup **Save passkey to &lt;title&gt;?** with entry summary; if entry already has passkey fields → **Replace passkey?** sub-confirm before overwrite.
   - **N matches** — popup picker listing domain-matched entries (`hasPasskey` badge); user selects → same confirm / replace rules.

**Get matching**

1. Parse `PublicKeyCredentialRequestOptions`.
2. Determine RP ID from options or caller origin.
3. Collect vault entries where `KPEX_PASSKEY_RELYING_PARTY` equals RP ID (case-sensitive string match as KeePassXC).
4. Filter by `allowCredentials` when non-empty: credential ID must match `KPEX_PASSKEY_CREDENTIAL_ID` (Base64url compare).
5. When `allowCredentials` empty (discoverable / resident-key style request), offer all matching RP entries.
6. Route:
   - **0 matches** — complete with `NotAllowedError` ("No passkey for this site").
   - **1 match** — popup **Use passkey for &lt;title&gt;?** + **Approve** / **Cancel**.
   - **N matches** — picker then **Approve** on selected row.

Never auto-select when N > 1 even if username hints match.

**App Entry detail — Passkey section**

Read-only summary when entry has passkey fields:

- Relying party, username, credential ID (truncated), created/updated from entry revision metadata.
- Actions: **Remove passkey** (clears all `KPEX_PASSKEY_*` fields after confirm) — edit form only; no extension shortcut in MVP.

**ES256 only**

- Create: generate P-256 key pair in app (`SecureEnclave` excluded — use CryptoKit `P256.Signing.PrivateKey` or equivalent software key).
- Get: sign clientDataHash + authenticatorData with stored PEM.
- Attestation: **packed self-attestation** aligned with KeePassXC reference behavior, finalized against a WebAuthn.io / known-RP fixture in the implementation plan (not a bare attestation TBD).

### Popup confirm UX + setting

**Settings toggle (both surfaces, synced via bridge)**

| Surface | Control |
|---------|---------|
| macOS **Settings → Chrome Extension** | Toggle **Use MyPass for Chrome passkeys** (default off); helper text explains exclusive proxy and detach-on-lock |
| Extension popup | Same toggle in footer or settings section; disabled when locked / unpaired with explanation |

App persists canonical preference; extension reads on startup via `getPasskeyProxyStatus` + `setPasskeyProxyEnabled`. Enabling calls `attach()` only when unlocked + paired.

**Popup panels** (reuse ~280 px shell from popup list redesign)

| Panel | When | Actions |
|-------|------|---------|
| **Save passkey** | Create; 0 or 1 entry target | **Save** (primary), **Cancel** |
| **Replace passkey?** | Create; target entry already has passkey | **Replace**, **Cancel** |
| **Use passkey** | Get; 1 match | **Approve**, **Cancel** |
| **Passkey picker** | Create or Get; N matches | Row list + **Approve** on selection |
| **Locked / unpaired** | Any ceremony when vault unavailable | **Retry** after unlock/pair; **Cancel** pending ceremony |
| **Proxy unattached** | Ceremony arrives but setting off | Inform user to enable passkeys; **Cancel** |

Show RP ID and origin hostname on every confirm panel for phishing resistance.

**openPopup / notification fallback**

- Primary: `chrome.action.openPopup()` when ceremony pending (Chrome 127+ behavior — verify in implementation; fallback documented below).
- Fallback when openPopup fails (no user gesture, popup already open, API error): `chrome.notifications.create` with **MyPass passkey confirmation needed** → clicking notification focuses extension action; user opens popup manually.
- Pending ceremony stored in `chrome.storage.session` (`pendingPasskeyCeremony: { kind, requestId, summary }`) so popup render on open shows the correct panel.

**Cancel / timeout**

- User **Cancel** → app returns error completion; extension calls `completeCreateRequest` / `completeGetRequest` with `DOMExceptionDetails { name: "NotAllowedError", message: "User cancelled" }`.
- Chrome `onRequestCanceled` → app `passkeyCancel`; clear session pending.
- Local watchdog **120 s** (configurable constant) if user never opens popup → same cancel path.
- Second concurrent create/get while one pending → queue or reject second with `AbortError`; MVP choice: **reject second** with NotAllowedError to keep state machine simple.

### Crypto / bridge / risks

**PasskeyCeremony module sketch** (`MyPass/State/ExtensionBridge/` or `Packages/MyPassKit/` if crypto stays kit-pure):

```swift
enum PasskeyCeremonyError: Error {
    case unsupportedAlgorithm
    case noMatchingCredential
    case userCancelled
    case invalidRequestJSON
}

struct PasskeyCeremony {
    /// Parse create options; validate ES256; return RP ID + user entity for UI.
    static func parseCreateRequest(_ json: String) throws -> CreateContext

    /// Generate ES256 keypair, credential ID, user handle; build WebAuthn create response JSON.
    static func performCreate(context: CreateContext, keypair: GeneratedKey) throws -> String

    /// Parse get options; return matching entry IDs from database.
    static func matchGetRequest(_ json: String, entries: [KdbxEntry], rpId: String) throws -> [UUID]

    /// Sign assertion for chosen entry; return get response JSON.
    static func performGet(entry: KdbxEntry, context: GetContext) throws -> String
}
```

Vault write occurs only inside `performCreate` after explicit confirm, writing all `KPEX_PASSKEY_*` fields on the chosen Login entry.

**Product risks — `webAuthenticationProxy`**

| Risk | Mitigation |
|------|------------|
| API designed for remote desktop, not password managers | Document exclusivity; opt-in default off; clear Settings copy |
| Exclusive attach blocks iCloud Keychain / security keys in Chrome while enabled | Detach toggle prominent; detach on lock |
| Only one extension may attach | Detect attach failure; instruct user to disable other proxy extensions |
| Service worker suspension | Pending ceremony in session storage; rehydrate on wake; cancel if app already timed out |
| Chrome version fragmentation | Require Chrome 115+; manifest `minimum_chrome_version` |

**Technical risks**

| Risk | Mitigation |
|------|------------|
| WebAuthn JSON compatibility | Use `PublicKeyCredential` JSON serialization matching Chrome's `parseCreationOptionsFromJSON` / `toJSON` |
| Cross-client KDBX interop | KeePassXC field names and PEM format; cross-test open in KeePassXC |
| Phishing | Show origin + RP ID on every confirm |
| Long-poll / async bridge | Implementation plan defines single pattern; unit tests for cancel mid-flight |

### Out of scope

Explicitly deferred (not piece C):

- Safari extension and ASCredentialProvider.
- Secure Enclave / platform-bound keys.
- Conditional UI (`mediation: "conditional"`) without active proxy attach.
- EdDSA, RS256, or other `pubKeyCredParams`.
- Always-on proxy attach on install.
- Piece A TOTP autofill / privacy circle and piece B 2FA setup (separate specs).
- Passkey import/export UI (KeePassXC `.passkey` JSON) — follow-up.
- iOS AutoFill passkeys (Phase 5).
- Silent auto-sign or auto-save without Approve / Save click.

## Files touched

| Path | Change |
|------|--------|
| `ChromeExtension/manifest.json` | **Edit** — `permissions`: `webAuthenticationProxy`; `minimum_chrome_version`: `115` |
| `ChromeExtension/background.js` | **Edit** — proxy listeners, attach/detach lifecycle, ceremony forward, complete* calls |
| `ChromeExtension/popup.html` / `popup.js` | **Edit** — passkey panels, picker, settings toggle, session pending ceremony |
| `ChromeExtension/tests/*.test.js` | **Add** — attach gating, pending ceremony state, cancel/timeout helpers |
| `Packages/ExtensionBridgeKit/Sources/ExtensionBridgeKit/ExtensionBridgeMessages.swift` | **Edit** — passkey message types; `hasPasskey` on summary; status/enable requests |
| `Packages/ExtensionBridgeKit/Tests/ExtensionBridgeKitTests/ExtensionBridgeMessagesTests.swift` | **Edit** — encode/decode new messages |
| `MyPass/State/ExtensionBridge/ExtensionBridgeService.swift` | **Edit** — passkey handlers, pending ceremony state |
| `MyPass/State/ExtensionBridge/PasskeyCeremony.swift` | **Add** — parse, match, sign, create response builders |
| `MyPass/State/ExtensionBridge/LoopbackServer.swift` | **Edit** — route new request types |
| `Packages/MyPassKit/Sources/MyPassKit/KdbxEntry+Passkey.swift` | **Add** — read/write `KPEX_PASSKEY_*` fields |
| `MyPass/UI/Settings/SettingsView.swift` (or extension settings pane) | **Edit** — passkey proxy toggle |
| `MyPass/UI/EntryDetail/EntryDetailView.swift` | **Edit** — Passkey section (read-only + remove) |
| `MyPass/MyPassApp.swift` | **Edit** — wire passkey pending UI if needed |
| `MyPassTests/ExtensionBridgeServiceTests.swift` | **Add** — passkey create/get/cancel/status tests |
| `MyPassTests/PasskeyCeremonyTests.swift` | **Add** — ES256 round-trip with fixture JSON |
| `MyPassTests/KdbxEntryPasskeyTests.swift` | **Add** — field round-trip |
| `RUN.md` | **Edit** — manual e2e bullets |

**Out of touch:** TOTP handlers (`getTotp`, `proposeSaveTotp`), ChromeHost business logic beyond forward, content script autofill.

## Acceptance criteria

1. **Default off** — fresh install: proxy not attached; `isUvpaa` uses platform behavior when detached.
2. **Opt-in attach** — enabling toggle while unlocked + paired calls `attach()`; disabling calls `detach()`; platform WebAuthn resumes after detach.
3. **Detach on lock** — vault lock triggers `detach()`; pending ceremony canceled with NotAllowedError.
4. **Create ES256** — fixture page register flow completes; KDBX entry contains all required `KPEX_PASSKEY_*` fields; Opens in KeePassXC without field warnings.
5. **Create confirm** — no vault write until user clicks **Save**; **Replace passkey?** when entry already has passkey.
6. **Get Approve** — sign-in completes only after **Approve**; no auto-sign when single match.
7. **Get picker** — multiple RP matches show picker; user must select then Approve.
8. **Get allowCredentials** — only matching credential ID offered when RP sends allow list.
9. **Cancel** — popup Cancel and page abort both end without vault mutation on create.
10. **No key in extension** — no PEM or private key material in extension messages or storage; only ceremony JSON.
11. **Algorithm gate** — RS256-only create request fails with clear error before key generation.
12. **isUvpaa** — while attached + unlocked, `isUvpaa: true`; when detached, extension does not spoof UVPAA.
13. **Security** — pairing + unlocked required; wrong pairing rejected; origin logged on confirm panels.
14. **Tests** — Swift PasskeyCeremony + bridge tests pass; JS ceremony state tests pass.

## Testing

### Automated

**JavaScript** (`ChromeExtension/tests/`)

- Attach only when setting enabled and mock status `{ unlocked: true, paired: true }`.
- Pending ceremony session rehydration on popup load.
- Cancel clears pending and sends `passkeyCancel`.
- Timeout watchdog fires NotAllowedError completion.
- Second concurrent request rejected.

**Swift** (`MyPassTests/`, `ExtensionBridgeKitTests`)

- `KPEX_PASSKEY_*` field read/write on Login entry.
- `PasskeyCeremony.parseCreateRequest` / `matchGetRequest` with frozen JSON fixtures (WebAuthn.io-compatible samples).
- ES256 create produces verifiable `responseJson` structure (smoke parse).
- Get assertion signs with stored PEM (fixture clientDataHash / authenticatorData vectors).
- `ExtensionBridgeService`: create/get happy path, cancel, locked, pairingRequired, unsupported algorithm.
- Replace path does not mutate until confirm.

Run via `./scripts/test.sh`.

### Manual e2e notes (add to `RUN.md` Chrome section)

Add bullets under **Chrome e2e (ручна перевірка)**:

- [ ] **Use MyPass for Chrome passkeys** default off; enabling while unlocked attaches; disabling detaches.
- [ ] Lock vault → proxy detaches; passkey sign-in on fixture site fails gracefully.
- [ ] Register on WebAuthn.io (or fixture): **Save passkey** confirm → entry in MyPass with KPEX fields; sign-in with **Approve** succeeds.
- [ ] Site with existing Login entry: create offers save to that entry; second create shows **Replace passkey?**
- [ ] Multiple entries same domain: picker shown for create and get.
- [ ] Cancel on popup → site shows cancellation; no vault write on aborted create.
- [ ] With MyPass attached, iCloud Keychain passkey not offered until detach (expected exclusivity).
- [ ] Export KDBX → open in KeePassXC → passkey fields visible on Login entry.

Use fixture HTTP server on port 8765; prefer [webauthn.io](https://webauthn.io) or bundled static WebAuthn fixture pages.

## Follow-ups

- **EdDSA / RS256** — broaden `pubKeyCredParams` acceptance.
- **Passkey import/export** — KeePassXC `.passkey` JSON and report UI.
- **Safari / ASCredentialProvider** — platform authenticator integration (Phase 4b / 5).
- **Conditional UI** — discoverable passkey autofill when proxy attached.
- **Secure Enclave option** — optional non-exportable keys for users who opt out of sync interop.
- **touchAccess on passkey get** — align last-accessed metadata with password fill.
- **Concurrent ceremony queue** — if product needs parallel pending requests.

## Risks

| Risk | Mitigation |
|------|------------|
| Exclusive proxy frustrates users who mix MyPass and iCloud passkeys | Default off; explicit Settings copy; one-click detach |
| WebAuthn JSON edge cases (JSON serialization quirks) | Fixture-driven tests; align with Chrome `requestDetailsJson` format |
| KeePassXC interop drift | Exact field names; verify in KeePassXC 2.7.x after save |
| attach() fails due to competing extension | Detect error; surface actionable message |
| Popup fails to open on ceremony | Notification fallback + session pending state |
| Software keys weaker than hardware | Accepted MVP tradeoff; document in Settings |
| Attestation mismatch with strict RPs | Packed self-attestation validated against fixture in implementation plan |
