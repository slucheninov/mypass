# Chrome Extension — TOTP/2FA Setup from Extension

**Date:** 2026-08-01  
**Status:** Approved

Follow-up to [2026-07-25-mypass-phase4-chrome-extension-design.md](./2026-07-25-mypass-phase4-chrome-extension-design.md) and companion to [2026-08-01-chrome-extension-totp-autofill-design.md](./2026-08-01-chrome-extension-totp-autofill-design.md) (piece A). OTP field UX in the macOS app is defined in [2026-07-26-mypass-entry-sidebar-polish-design.md](./2026-07-26-mypass-entry-sidebar-polish-design.md). Implements **piece B only**: detecting TOTP setup material on a page (QR image, `otpauth://` text, manual secret heuristics) or via popup paste, then opening MyPass for user-confirmed save. Does **not** include piece A (TOTP autofill / privacy circle implementation details beyond dependency on `hasTotp`) or piece C (Passkeys).

## Problem

Users enable two-factor authentication on websites using QR codes or manual setup keys shown during enrollment. MyPass stores TOTP secrets in the vault, but today the user must manually copy the secret or `otpauth://` URL into the macOS app. Phase 4 Chrome extension save flow covers **new logins** (`proposeSaveLogin`) but not attaching or updating 2FA on an existing domain-matched entry. Piece A adds TOTP **consumption** (autofill + reveal); piece B closes the loop for **capture and attach** without the extension ever writing to the KDBX file.

## Goals

- **Attach TOTP to an existing entry** when the page domain matches one or more vault entries; when multiple entries match, show a picker in the popup; when zero match, create a new login entry with OTP pre-filled together.
- **Capture setup material from the page** — decode QR from visible `<img>` / `<canvas>`, find `otpauth://` links and inline text, apply manual-key Base32 heuristics; plus a manual paste field in the popup. **No camera access.**
- **Confirmation in the app** — same trust model as password save: extension sends a proposal → MyPass opens `EntryEditView` → user taps Save in the app. Extension never writes the vault alone.
- **Replace guard** — if the target entry already has TOTP, show an explicit **Replace 2FA?** confirmation in the app; no silent overwrite.
- **Architecture approach 1 (approved)** — page detect → banner or popup picker → `proposeSaveTotp` → app edit/create form.

## Non-goals

- **Piece A** — TOTP autofill, `getTotp`, privacy circle, `findOtpField`, or live code generation in the extension (except depending on `hasTotp` in list metadata when piece A is shipped).
- **Piece C** — Passkeys / WebAuthn registration or autofill from the extension.
- **Camera / webcam QR scan** — page DOM and popup paste only.
- **Auto-write to vault** — no `VaultSession.mutate` triggered solely by extension messages.
- **HOTP** — TOTP (`otpauth://totp/...`) only.
- **Non-default TOTP parameter persistence** — digits, period, and algorithm parsed from `otpauth://` are applied for validation/display in edit but not persisted as separate KDBX fields unless a trivial follow-up lands separately (see App / bridge).
- **Safari** extension parity — Chrome only in this spec.

## Design

### Scope boundary

| Piece | Description | In this spec |
|-------|-------------|--------------|
| **A** | TOTP autofill + popup privacy circle | Dependency only (`hasTotp` on list rows) |
| **B** | 2FA setup / QR capture in extension | **Yes** |
| **C** | Passkeys | No |

### User-visible behavior

1. **Page with TOTP setup UI** — extension detects `otpauth://` URL, decodable QR, or plausible manual secret text → shows banner **Save 2FA to MyPass?** with **Save** / **Not now**. **Not now** dismisses for the current tab session.
2. **Zero domain matches** — **Save** opens MyPass create form with URL (registrable domain title default), OTP field revealed and pre-filled; user completes username/password if desired and Save.
3. **Exactly one domain match** — **Save** opens MyPass edit form for that entry with OTP field revealed and pre-filled; if entry already has TOTP, app shows **Replace 2FA?** before applying the new secret.
4. **Multiple domain matches** — **Save** stores candidate in session storage and opens popup entry picker (with `hasTotp` indicator per row when piece A metadata exists); user selects entry → `proposeSaveTotp` with `entryId` → app edit flow as above.
5. **Popup paste path** — user pastes `otpauth://` or Base32 secret into **Add 2FA** field → same picker / routing rules → **Opened in MyPass** feedback after `saveProposalAccepted`.
6. **Password-save banner unchanged** — TOTP banner is a separate UI element and state flag; both may not show simultaneously on the same page (TOTP banner takes precedence when setup material is detected).

### Architecture & data flow

**Trust model** (unchanged from Phase 4 + piece A):

- Browser extension ↔ ChromeHost via native messaging (`allowed_origins` restricted to extension ID).
- ChromeHost ↔ MyPass app via loopback TCP + per-session Keychain token.
- Pairing secret required for `getCredentials`, `proposeSaveTotp`, and all credential operations.
- Vault must be **unlocked**; locked → banner hidden or Save shows locked state in popup; no proposal sent.
- When `entryId` is supplied, app re-validates that the entry's domain matches the proposal `url` via `ExtensionEntryMatcher` (same gate as `fillCredential`). Domain mismatch → `{ type: "error", message: "entry not found or domain mismatch" }`; no window activation.

**Approach 1 (approved):**

| Step | Actor | Action |
|------|-------|--------|
| 1 | `content.js` | Detect TOTP setup candidate on page |
| 2 | `content.js` / `popup.js` | Resolve 0 / 1 / N domain-matched entries via cached or fresh `getCredentials` |
| 3 | User | Confirms Save or picks entry + confirms |
| 4 | `background.js` | Sends `proposeSaveTotp` |
| 5 | App | Activates window, opens `EntryEditView` (edit or create), user Save |
| 6 | Extension | Receives `saveProposalAccepted`; shows **Opened in MyPass** (popup) or removes banner (page) |

**Messages**

| Message | Direction | Payload | Response |
|---------|-----------|---------|----------|
| `getCredentials` | extension → app | `url`, optional `pairing` | `{ type: "credentialList", credentials: [{ id, title, username, hasTotp? }] }` or locked / pairingRequired / error |
| `proposeSaveTotp` | extension → app | `url`, `otpauthOrSecret`, optional `entryId`, optional `pairing` | `{ type: "saveProposalAccepted" }` or locked / pairingRequired / error |

`otpauthOrSecret` is the raw string captured from the page or popup paste — full `otpauth://totp/...` URL or Base32 secret. The extension never parses or stores the secret in `chrome.storage.local`; session-scoped pending candidate may live in `chrome.storage.session` until consumed or tab close.

**Invariant:** The extension and ChromeHost **never** call `VaultSession.mutate` or write KDBX. Only the user's Save action in `EntryEditView` persists `totpSecretBase32`.

```mermaid
sequenceDiagram
    participant Page as content.js
    participant Popup as popup.js
    participant BG as background.js
    participant Host as ChromeHost
    participant App as ExtensionBridgeService
    participant UI as EntryEditView

    Note over Page,App: Zero domain matches
    Page->>Page: detectTotpCandidate()
    Page->>Page: showTotpSaveBanner()
    Page->>BG: proposeSaveTotp { url, otpauthOrSecret }
    BG->>Host: forward
    Host->>App: proposeSaveTotp
    App->>UI: PendingTotpSaveProposal → create + OTP pre-fill
    App-->>Host: saveProposalAccepted
    Host-->>BG: saveProposalAccepted
    BG-->>Page: ack

    Note over Page,App: One domain match
    Page->>Page: detectTotpCandidate()
    Page->>BG: getCredentials { url } (cached ok)
    BG-->>Page: credentialList [single]
    Page->>BG: proposeSaveTotp { url, otpauthOrSecret, entryId }
    BG->>Host: forward
    Host->>App: proposeSaveTotp
    App->>UI: edit entryId; Replace 2FA? if hasTotp
    App-->>Host: saveProposalAccepted

    Note over Page,App: Multiple domain matches
    Page->>Page: detectTotpCandidate()
    Page->>BG: getCredentials { url }
    BG-->>Page: credentialList [N]
    Page->>Popup: open picker (session pending candidate)
    Popup->>BG: proposeSaveTotp { url, otpauthOrSecret, entryId }
    BG->>Host: forward
    Host->>App: proposeSaveTotp
    App->>UI: edit entryId
    App-->>Host: saveProposalAccepted
    Host-->>Popup: saveProposalAccepted
    Popup->>Popup: show "Opened in MyPass"
```

### Page detect & banner

**Detection sources** (first high-confidence hit wins; re-scan on debounced DOM mutations):

| Priority | Source | Method |
|----------|--------|--------|
| 1 | `otpauth://totp/...` in `<a href>` | Read `href` directly |
| 2 | `otpauth://totp/...` in visible text | Regex scan of `textContent` on `document.body` (bounded depth / exclude script/style) |
| 3 | QR code image | For each visible `<img>` with reasonable size and `<canvas>` on page: draw to offscreen canvas if same-origin; run **jsQR** (or equivalent bundled decoder). Skip **CORS-tainted** images (`img.crossOrigin` insufficient and canvas throws — catch and skip). |
| 4 | Manual setup key | Heuristic: element text or adjacent label matching `/secret|manual|setup key|authenticator/i` plus nearby Base32-like token (`/^[A-Z2-7]{16,}$/` with optional spaces, length 16–128) |

**Candidate normalization:** Prefer full `otpauth://` string when found. For QR/manual-only Base32, pass raw secret string; app-side `EntryEditSaveLogic.applyOTP` and `TOTPCode.parse` perform authoritative parsing.

**Banner UI**

- Copy: **Save 2FA to MyPass?**
- Actions: **Save** (primary), **Not now** (dismiss)
- Placement: fixed bottom-right, distinct styling from password banner (different label color or icon) so the two flows are visually separable
- Session dismiss: `chrome.storage.session` key `totpBannerDismissed:<tabId>` or in-memory `state.totpBannerDismissed` — do not re-show until navigation or new candidate strictly stronger than dismissed one
- **0 / 1 / >1 routing:**
  - **0 matches:** `proposeSaveTotp` without `entryId`
  - **1 match:** `proposeSaveTotp` with that `entryId`
  - **>1 matches:** stash `{ url, otpauthOrSecret }` in `chrome.storage.session` as `pendingTotpCandidate`, programmatically open popup (or focus extension icon) for entry picker
- **Separate from password banner:** independent `state.totpBannerShown` vs `state.bannerShown`; if TOTP candidate detected, do not show password-save banner on same page load cycle
- **MutationObserver:** debounce 300–500 ms on `document.body` subtree; re-run detection when SPA renders QR or setup step

**Vault locked / pairing:** If latest `getCredentials` returned `locked` or `pairingRequired`, suppress TOTP banner (same rationale as password banner — avoid misleading save offers).

### Popup paste + picker

**Add 2FA section** in `popup.html` / `popup.js`:

- Text field (single line) with placeholder e.g. **Paste otpauth:// URL or secret key**
- **Add** button validates lightly client-side:
  - Accept if starts with `otpauth://totp/`
  - Else if trimmed string matches Base32 heuristic (same as page detect)
  - Else inline hint: **Enter a valid authenticator URL or secret key**
- On valid input: fetch `getCredentials` for active tab URL; route 0 / 1 / N same as banner **Save**
- **Pending candidate from session:** on popup open, read `chrome.storage.session.pendingTotpCandidate`; if present, pre-fill paste field and show picker when multiple matches

**Entry picker** (multi-match only):

- Reuse popup credential list row layout from popup list redesign
- Show **`hasTotp` indicator** (e.g. small "2FA" badge or filled dot) when `credential.hasTotp === true` — field comes from piece A's `getCredentials` extension; **default `hasTotp: false` when piece A is not shipped yet** (optional field omitted in JSON decodes as false)
- Row click on picker mode sends `proposeSaveTotp` with selected `entryId`, not `fillCredential`
- After `saveProposalAccepted`: replace picker with brief **Opened in MyPass** message; clear session pending candidate

**Validation split:** Extension performs format heuristics only. Authoritative parse and secret extraction happen in the app via `EntryEditSaveLogic.applyOTP` / `TOTPCode.parse`. Malformed input that passes heuristics but fails parse surfaces as empty or invalid OTP in edit — user can fix before Save.

### App / bridge

**New types**

```swift
struct PendingTotpSaveProposal: Identifiable, Equatable, Hashable {
    let id = UUID()
    let url: String
    let otpauthOrSecret: String
    let entryId: UUID?  // nil → create new login + OTP

    var registrableDomain: String {
        ExtensionEntryMatcher.registrableDomain(from: url) ?? url
    }
}
```

**`ExtensionBridgeRequest`** — add case:

```swift
case proposeSaveTotp(token: String, url: String, otpauthOrSecret: String, entryId: String?, pairing: String?)
```

**`ExtensionBridgeService.handle`**

- Gate: unlocked vault + authorized pairing (same as `proposeSaveLogin`).
- If `entryId` present: resolve entry; verify domain match with `url`; on failure return `.error("entry not found or domain mismatch")`.
- Invoke `onTotpSaveProposal?(PendingTotpSaveProposal(...))` wired in `MyPassApp.init()` to:
  1. Activate main window (reuse existing save-proposal activation path).
  2. If `entryId` set → `presentEdit(entryID:)` with OTP field revealed and `otpauthInput` pre-filled from proposal.
  3. If `entryId` nil → `presentCreate` / create-from-proposal variant with URL, title default = registrable domain, OTP pre-filled; username/password empty.
  4. Clear `pendingTotpSaveProposal` on Save or Cancel.

**Replace 2FA confirmation**

- Before applying pre-filled OTP on **edit** path, if `entry.totpSecretBase32?.isEmpty == false`, present alert:
  - Title: **Replace 2FA?**
  - Message: explains existing authenticator will be replaced after Save
  - Actions: **Cancel** (stay in edit, clear only the pending overwrite intent — keep form open with new OTP still in field) / **Replace** (proceed; on Save, `applyOTP` overwrites)
- Implementation: set a `@State` flag when opening edit from proposal if `hasExistingTotp`; alert on appear or on first Save attempt before mutate — product choice: **alert on Save tap** is preferred so user can review OTP field first.

**OTP apply on Save**

- Reuse `EntryEditSaveLogic.applyOTP(to:otpauthInput:)` — parses `otpauth://` via `TOTPCode.parse`, else stores raw Base32.
- **Known gap (out of scope):** `applyOTP` persists secret only; digits / period / algorithm from `otpauth://` are **not** stored in separate KDBX fields. Autofill (piece A) uses defaults (6 digits, 30 s, SHA-1). Document in follow-ups unless a one-line comment in `applyOTP` suffices.

**Navigation**

- Add `@Published var pendingTotpSaveProposal: PendingTotpSaveProposal?` or extend `DetailPresentation` with `.editFromTotpProposal(entryID: UUID, otpauthInput: String)` and `.createFromTotpProposal(PendingTotpSaveProposal)` — mirror `createFromProposal` pattern from entry sidebar polish spec.
- `EntryEditView`: when opened from TOTP proposal, force OTP section visible (same as "entry already has TOTP or user tapped + Add one-time password" rule in sidebar polish spec).

**ChromeHost / `background.js`**

- Add `"proposeSaveTotp"` to `knownTypes`; forward through native messaging with pairing token.
- Response `saveProposalAccepted` — same shape as login save proposal.

### Out of scope

Explicitly deferred (not piece B):

- Camera / webcam QR scanning.
- Piece A implementation (autofill, `getTotp`, privacy circle) — only `hasTotp` list metadata dependency documented above.
- Piece C Passkeys.
- Extension-initiated vault write or silent OTP attach.
- HOTP (`otpauth://hotp/...`).
- Persisting non-default TOTP digits, period, or algorithm from `otpauth://` (unless trivial follow-up).
- Auto-attaching OTP on page load without user clicking Save / Add.
- Merging TOTP setup with password-save banner into one combined flow.

## Files touched

| Path | Change |
|------|--------|
| `Packages/ExtensionBridgeKit/Sources/ExtensionBridgeKit/ExtensionBridgeMessages.swift` | **Edit** — `proposeSaveTotp` request; reuse `saveProposalAccepted` response |
| `Packages/ExtensionBridgeKit/Tests/ExtensionBridgeKitTests/ExtensionBridgeMessagesTests.swift` | **Edit** — encode/decode `proposeSaveTotp` |
| `MyPass/State/ExtensionBridge/ExtensionBridgeService.swift` | **Edit** — handler + `onTotpSaveProposal` callback |
| `MyPass/State/ExtensionBridge/LoopbackServer.swift` | **Edit** — token extraction for new request type |
| `MyPass/State/NavigationState.swift` | **Edit** — `PendingTotpSaveProposal`, presentation cases |
| `MyPass/MyPassApp.swift` | **Edit** — wire `onTotpSaveProposal` → navigation + activate |
| `MyPass/ContentView.swift` | **Edit** — route TOTP proposal to detail column edit/create |
| `MyPass/UI/EntryDetail/EntryEditView.swift` | **Edit** — pre-fill OTP from proposal; Replace 2FA? alert |
| `MyPassTests/ExtensionBridgeServiceTests.swift` | **Edit** — proposeSaveTotp success + domain mismatch + locked |
| `MyPassTests/NavigationStatePendingTotpSaveProposalTests.swift` | **Add** — registrable domain helper |
| `MyPassTests/EntryEditSaveLogicTests.swift` | **Edit** — optional replace-path coverage if alert affects save |
| `ChromeExtension/content.js` | **Edit** — TOTP detect, banner, MutationObserver, session dismiss |
| `ChromeExtension/background.js` | **Edit** — `proposeSaveTotp` routing |
| `ChromeExtension/popup.html` / `popup.js` | **Edit** — Add 2FA paste, multi-match picker mode, feedback |
| `ChromeExtension/manifest.json` | **Edit** — `storage` permission if session API requires explicit declaration (verify MV3 defaults) |
| `ChromeExtension/vendor/jsQR.js` or npm devDependency | **Add** — bundled QR decoder |
| `ChromeExtension/tests/*.test.js` | **Edit** — detect heuristics, banner routing, Base32/otpauth fixtures |
| `RUN.md` | **Edit** — manual e2e bullets (see Testing) |

**Out of touch:** piece A autofill/content OTP fill, Passkeys, ChromeHost business logic beyond forward, `fillCredential` / `getTotp` handlers except shared `hasTotp` on summaries when piece A lands.

## Acceptance criteria

1. **Page detect** — fixture page with `otpauth://` link shows TOTP banner; **Not now** dismisses for session; debounced re-detect after DOM injection shows banner again on new navigation.
2. **QR decode** — fixture page with same-origin QR `<img>` encoding valid `otpauth://totp/...` produces candidate; cross-origin tainted image is skipped without throw.
3. **Zero matches** — Save opens MyPass create form with OTP field visible and pre-filled; title defaults to registrable domain; no vault write until user Save.
4. **One match** — Save opens edit for matched entry; OTP pre-filled; Save persists secret via `applyOTP`.
5. **Multiple matches** — Save opens popup picker; selecting row sends `proposeSaveTotp` with correct `entryId`; `hasTotp` badge visible when piece A metadata present.
6. **Replace guard** — edit entry with existing TOTP shows **Replace 2FA?** before overwrite; Cancel leaves vault unchanged.
7. **Domain mismatch** — `proposeSaveTotp` with wrong `entryId` for `url` returns error; app window does not open edit.
8. **Popup paste** — valid otpauth and Base32 paste routes correctly; invalid shows inline hint; success shows **Opened in MyPass**.
9. **Security** — no KDBX write from extension; pairing + unlocked required; password banner and TOTP banner use separate state (no duplicate conflation when vault locked).
10. **Invariant** — no code path in extension/ChromeHost calls vault mutate.

## Testing

### Automated

**JavaScript** (`ChromeExtension/tests/`)

- `detectOtpauthLink` / `detectOtpauthText` on HTML fixture strings.
- Base32 heuristic: valid secrets, spaced secrets, reject too-short / invalid alphabet.
- QR path: mock canvas + jsQR return value; tainted canvas throws → skip.
- Banner routing: 0 / 1 / N credential list fixtures → correct message payload shape.
- Popup paste validation: otpauth prefix, Base32, invalid input.
- Session dismiss flag prevents re-show until navigation.

**Swift** (`MyPassTests/`, `ExtensionBridgeKitTests`)

- `proposeSaveTotp` encode/decode round-trip.
- `ExtensionBridgeService`: accepted proposal fires callback; locked / pairingRequired / domain mismatch.
- `PendingTotpSaveProposal.registrableDomain` parsing.
- `EntryEditSaveLogic.applyOTP` with proposal-shaped otpauth and raw Base32 (existing tests cover core parse).
- Replace alert path: save with existing secret requires confirm (UI test or unit test on save gate if extracted).

Run via `./scripts/test.sh`.

### Manual e2e notes (add to `RUN.md` Chrome section)

Add bullets under **Chrome e2e (ручна перевірка)**:

- [ ] TOTP setup page with `otpauth://` link shows **Save 2FA to MyPass?** banner (not password banner).
- [ ] **Not now** hides banner; reload or new setup step can show again.
- [ ] Same-origin QR on fixture page decodes and Save opens MyPass with OTP pre-filled.
- [ ] Site with no vault entry: Save opens create form, registrable domain title, OTP visible.
- [ ] Site with one entry: Save opens edit for that entry with OTP pre-filled.
- [ ] Site with multiple entries: Save opens popup picker; pick row → MyPass edit with OTP.
- [ ] Entry that already has 2FA: **Replace 2FA?** appears; Cancel keeps old secret; Replace + Save updates secret.
- [ ] Popup **Add 2FA** paste with otpauth URL → **Opened in MyPass** after app opens.
- [ ] Locked vault: no TOTP banner (or Save shows locked in popup).
- [ ] Cross-origin QR image skipped (no crash; no banner unless otpauth text present).

Use fixture HTTP server on port 8765; add TOTP setup fixture pages (otpauth link, QR PNG, manual key text).

## Follow-ups

- **Piece A** — ship `hasTotp` on `getCredentials` if not already present when piece B lands; popup picker badge then reflects live data.
- **Persist TOTP parameters** — store digits / period / algorithm from `otpauth://` when KDBX custom fields support it; align autofill defaults.
- **Combined enrollment UX** — optional single flow when login + TOTP setup detected on same page (password proposal + TOTP proposal sequencing).
- **Safari** extension parity for TOTP setup.
- **Stronger manual-key detection** — site-specific selectors if common patterns emerge (Google, Microsoft enrollment pages).
