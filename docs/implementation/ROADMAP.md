# Implementation Roadmap — Vault Location + Chrome Extension Pieces A / B / C

**Status file.** This is the single place where execution progress across the
outstanding workstreams is tracked. Tick a box only when the item is implemented **and**
its tests pass — see "Definition of done" below.

Last updated: 2026-08-07

---

## Scope

Three written plans are pending implementation, plus one workstream (U) whose design
and plan are written as its own first two items. A fourth (V) turned out to be already
shipped — see the correction in Decisions:

| ID | Plan | Tasks | Lines | Risk |
|----|------|-------|-------|------|
| ~~**V**~~ | [`2026-07-31-vault-location-move-sync-open`](../superpowers/plans/2026-07-31-vault-location-move-sync-open.md) | 9 | 1495 | **Already shipped — see Stage 1** |
| **A** | [`2026-08-01-chrome-extension-totp-autofill`](../superpowers/plans/2026-08-01-chrome-extension-totp-autofill.md) | 7 | 1303 | Low |
| **B** | [`2026-08-01-chrome-extension-totp-setup`](../superpowers/plans/2026-08-01-chrome-extension-totp-setup.md) | 11 | 1780 | Medium (vendored `jsQR`, new navigation branch) |
| **C** | [`2026-08-01-chrome-extension-passkeys`](../superpowers/plans/2026-08-01-chrome-extension-passkeys.md) | 11 | 2314 | High (hand-rolled CBOR/COSE, `webAuthenticationProxy` availability) |
| **U** | Unlock from the popup — no plan yet, written as part of Stage 3 | 9 | — | Medium (relaxes a deliberate security constraint) |

Already shipped and out of scope: `chrome-extension-icon-and-popup-fallback`,
`chrome-extension-popup-list-redesign`.

## Execution order and why

Two tracks run in parallel because they are near-orthogonal — the vault plan touches
`MyPass/Storage/**`, `VaultSession`, and `SyncKit`, while the Chrome plans touch
`MyPass/State/ExtensionBridge/**` and `ChromeExtension/**`. The only shared file is
`MyPass/MyPassApp.swift`, in different regions.

```
Track 1 (Swift/storage):   Stage 1 — V  (already shipped)
Track 2 (Chrome):          Stage 0 — spike + plan C fixes
                           Stage 2 — C core (isolated new files)
                           Stage 3 — U (unlock from popup)
                           Stage 4 — A
                           Stage 5 — B
                           Stage 6 — C rest
```

U goes before A because it is small, self-contained, and edits the same
`background.js` / `popup.js` / `ExtensionBridgeMessages.swift` files that A, B, and C
all rewrite — landing it while those files are still in their current shape is the
cheapest point to do it.

Chrome pieces are **not** ordered hardest-first. All three edit the same set of files
(`ExtensionBridgeMessages.swift`, `ExtensionBridgeService.swift`, `LoopbackServer.swift`,
`background.js`, `popup.js/html`, `content.js`, `scripts/test.sh`), and every plan is
written against the *current* pre-A, pre-B state of those files. Landing C first would
force A's and B's anchors to be re-derived against the files C rewrites most heavily.

The hard part of C that *is* isolated — the CBOR/COSE encoder and the KDBX passkey
fields, both brand-new files with zero conflict surface — is pulled forward into
Stage 2 so the riskiest code is proven early without paying the merge cost.

Note: C task 1 (wire protocol) is **not** part of the isolated core, because it edits
`ExtensionBridgeMessages.swift`, which A and B also edit. It stays in Stage 6.

---

## Definition of done (per item)

An item may be ticked when all of these hold:

1. The plan task's failing test was written first and observed failing.
2. The implementation makes it pass.
3. `./scripts/test.sh` is green (or, for a mid-stage item, the specific suites the
   task touches are green and nothing previously green regressed).
4. No `- [ ]` sub-item under it remains open.

Stage gates (`⛳`) additionally require a full `./scripts/test.sh` run plus the manual
e2e checklist for that stage.

---

## Stage 0 — Spike and plan C corrections

Blocking for Stage 2 and Stage 6 only. Does not block Track 1, A, or B.

Review of plan C found five defects in `background.js` (Task 8) and one deliberate
spec deviation in the ceremony core (Task 3). Fix the plan text **before** executing it.

- [x] **S1** — Spike: confirm `chrome.webAuthenticationProxy` is usable by an
      **unpacked, non-policy-installed** extension. **Answer: yes, no policy gate.**
      Chromium's `_permission_features.json` lists it as `channel: stable`,
      `extension_types: ["extension"]`, `min_manifest_version: 3`,
      `platforms: ["linux", "mac", "win"]` — with no `location: "policy"` and no
      `allowlist`, which is how Chrome marks force-install-only APIs.
      `_api_features.json` adds only `dependencies: ["permission:webAuthenticationProxy"]`
      and `contexts: ["privileged_extension"]`. Stage 6 keeps its shape.
      Side finding for **C8**: `privileged_extension` means service worker and popup
      only — never a content script. Plan C already registers in `background.js`.
      An optional on-machine confirmation probe is in the session scratchpad
      (`s1-proxy-probe/`); it attaches and immediately detaches.
- [x] **S2** — Spike: confirm `chrome.action.openPopup()` behaviour when called from a
      `webAuthenticationProxy` event (no user gesture). **Answer: no user gesture is
      required — but the Chrome window must be OS-level focused, and the effective
      Chrome floor is 127, not 115.**
      `ActionOpenPopupFunction::Run()` performs no `user_gesture()` check at all, so the
      original worry was unfounded. It does enforce two separate preconditions:
      `FindActiveBrowserWindow()` non-null (`kNoActiveWindowFound`) and
      `browser->GetWindow()->IsActive()` (`kOpenPopupInactiveWindow`) — the latter is
      OS-level window focus. In the normal passkey flow the user is interacting with a
      Chrome page, so the window is focused and the call succeeds; plan C's notification
      fallback survives as the edge case (Chrome backgrounded), not the norm.
      Version gate: per the official docs, "Between Chrome 118 and Chrome 126, this is
      only available to policy installed extensions" — so a normally-installed extension
      needs **Chrome 127+**. See the amendment on **C7**.
      Third precondition worth remembering: `kNoActivePopup` fires if the extension has
      no `default_popup` on the active tab. MyPass declares `popup.html`, so this holds.
- [x] **S3** — Spike: capture one real `requestDetailsJson` from a live Chrome create
      and get ceremony, diff against the fixtures in plan C Task 3. **Done — captured on
      a real Chrome against a localhost bench; both parse functions match the real shape.**
      `parseGetRequest` correctly reads `rpId` / `challenge` / `allowCredentials[].id` and
      ignores the `transports` array Chrome injects on its own. `parseCreateRequest`
      matches `rp.id` / `rp.name` / `user` / `pubKeyCredParams`.
      Differences from the MDN-derived fixtures, all recorded here as amendments:
  - [x] **Origin must come from the payload, not the active tab.** `requestInfo` carries
        exactly two keys — `requestDetailsJson` and `requestId` — verified empirically.
        The true origin is inside the payload as
        `extensions.remoteDesktopClientOverride.origin` (present on both create and get).
        Plan C's `chrome.tabs.query({active: true, currentWindow: true})` only guesses the
        initiating tab, which is wrong for a background-tab ceremony and weakens the
        domain-match gate that consumes `originUrl`. Amends **C3**, **C4**, **C8**.
        Use the payload origin as authoritative; fail closed if it is absent.
        Applied to **C8**. **C3/C4 need no signature change** — the wire `originUrl` now
        carries the true origin. Still open as a **C4** hardening item: have the app
        cross-check the received `originUrl` against the payload's own
        `remoteDesktopClientOverride.origin` and reject on mismatch, so a compromised
        extension cannot steer the domain gate by lying about the origin.
  - [x] **`requestId` is negative in practice** (`-56026996`, `-913466539`). Plan C already
        types it `Int`, which is correct — but the tests use `42`. Add a negative-value
        round-trip case. Amends **C1**.
  - [x] Chrome rewrote the page's requested `timeout: 60000` to **`180000`**. Our
        `PASSKEY_WATCHDOG_MS` of 120000 therefore fires before Chrome's own timeout.
        Intentional, but record it rather than rediscover it. Amends **C8**.
  - [x] `challenge` and `user.id` arrive as **unpadded** base64url (43 chars, no `=`).
        `PasskeyBase64URL.decode` must accept missing padding. Amends **C3** —
        **verified, no change needed**: the planned decoder already re-pads with
        `while base64.count % 4 != 0 { base64 += "=" }`.
  - [x] `attestation: "none"` reaches the authenticator verbatim, so the **S8** deviation
        (always returning `fmt: "packed"`) is observable by the RP, not theoretical.
- [x] **S4** — Plan C fix: `onIsUvpaaRequest` (`:1913`) returns early without calling
      `completeIsUvpaaRequest` when the toggle is off, so Chrome's request never gets an
      answer. Must complete with `isUvpaa: false`.
- [x] **S5** — Plan C fix: `handlePasskeyRequest` (`:1868`) handles only `response.error`
      and `*Pending`. A `locked` or `pairingRequired` reply falls through every branch —
      no completion, no watchdog armed, ceremony hangs on the page until Chrome's own
      timeout. Add an explicit branch. This is the most likely real-world path.
- [x] **S6** — Plan C fix: `attachPasskeyProxyIfEligible` (`:1832`) wraps an existing
      promise in `new Promise((resolve) => ….then(resolve))` with no reject/catch, so a
      rejection (MyPass not running) never settles and the `await` hangs forever. Drop
      the wrapper.
- [x] **S7** — Plan C rework: move pending-ceremony bookkeeping to `chrome.storage.session`
      as the source of truth. MV3 terminates the service worker after ~30 s idle while the
      user has 120 s to confirm, so the in-memory `pendingPasskeyCeremonies` Map and its
      `setTimeout` watchdog silently evaporate. Consequences today: the "one ceremony at a
      time" guard stops rejecting, and an abandoned ceremony is never completed with an
      error. Completion itself is safe (`completeCreateRequest` needs only `requestId`).
      This is a medium rework of Task 8, not a one-liner.
- [x] **S8** — Plan C decision: `buildAttestationObject` (`:985`) always returns
      `fmt: "packed"` self-attestation even when the RP requested `attestation: "none"`.
      Decide explicitly — honour the requested value, or document why packed is always
      returned. Most RPs accept it; strict ones checking `fmt === "none"` will not.

**⛳ Gate 0 — PASSED (2026-08-07).** S1–S3 answered and recorded in "Decisions" below;
S4–S8 applied to `docs/superpowers/plans/2026-08-01-chrome-extension-passkeys.md`, along
with the S2 version bump and the S3 origin/`requestId`/timeout amendments. Evidence for
S3 is committed alongside this file as `s3-webauthn-capture-2026-08-07.json`.

---

## Stage 1 — Vault location move, sync, and open existing — COMPLETE

**This stage was already implemented and merged before this roadmap was written.** It was
listed as pending by mistake; see the correction in Decisions. Every task maps to a commit
on `master`, and `e77878c` ("fix 8 findings from whole-branch review") shows it also went
through review. Kept here with its commit trail rather than deleted, so the roadmap stays
a faithful record.

The move-delete gate is sound as reviewed: destination bytes are opened with the master
password via `KdbxDatabase.open` before the source is removed.

- [x] **V1** *(shipped: `8ce3c1b`, `f4c2f4e`)* — `LocalFileVaultStore` + `VaultPrimaryStorage` protocol extension
      (`primaryVaultFileURL`, `deleteVaultFileIfPresent`)
- [x] **V2** *(shipped: `57ffe9c`)* — Resolver + `localVaultFileBookmark` UserDefaults key
- [x] **V3** *(shipped: `9afecee`)* — Case-insensitive `MyPass` folder guard (`VaultICloudFolderSelection`)
- [x] **V4** *(shipped: `965e3f8`, `3637f50`)* — Migration move: verify destination opens → delete source → swap
  - [x] Delete-failure path still swaps and surfaces a warning
  - [x] Failure before verify leaves the source file untouched
- [x] **V5** *(shipped: `a55c2ea`)* — Settings resolved-path display + Move wording
- [x] **V6** *(shipped: `a233358`, `0bd5bb7`)* — Skip-identical-bytes persist, dirty-flag timer gating
- [x] **V7** *(shipped: `a4fb908`)* — Remote change LWW reload, no push (`readNewestAvailableBytes` in `iCloudBackend`)
  - [x] Wrong password / corrupt remote on reload must not wipe local state
- [x] **V8** *(shipped: `526af53`, `e623a23`, `44cee8a`)* — Open Existing `.kdbx` (password sheet, bookmark, session retarget)
  - [x] App Support file deleted only when leaving the default local mode
- [x] **V9** *(shipped: `ec72b61`)* — Bookmark bookkeeping on local ↔ iCloud location change

**⛳ Gate 1 — PASSED (2026-08-07).** `./scripts/test.sh` re-run on `master` when this
correction was made: `** TEST SUCCEEDED **` for the MyPass scheme, 0 failures across
MyPassKit / SyncKit / ExtensionBridgeKit, all three JS suites OK.

---

## Stage 2 — Passkey core, isolated (Track 2)

Two brand-new files, no shared-file edits, no extension changes. Reviewed and found
correct on canonical CTAP2 CBOR key ordering, authenticator-data flags (`0x5D` create /
`0x1D` get), and DER signatures over `authData + clientDataHash`.

- [ ] **C2** — `KdbxEntry+Passkey.swift`: `KPEX_PASSKEY_*` accessors, `clearPasskey()`,
      widen `setFieldValue`/`fieldValue` to `internal`
- [ ] **C3** — `PasskeyCeremony.swift`: CBOR/COSE encoder, WebAuthn JSON parse/build,
      ES256 key generation and signing
  - [ ] Fixtures reconciled with the real payload captured in **S3**
  - [ ] Attestation format resolved per **S8**

**⛳ Gate 2** — `MyPassTests/PasskeyCeremonyTests` and `KdbxEntryPasskeyTests` green,
including the self-verifying signature assertions.

---

## Stage 3 — Unlock MyPass from the popup

Today the locked popup shows only "MyPass is locked" + Retry. This adds an **Unlock
MyPass** button that brings the app forward with its unlock UI (password + Touch ID).

**This reverses a deliberate constraint.** `chrome-extension-popup-list-redesign`
states *"No unlock-from-extension, password field, or unlock IPC in the popup."* The
reversal is narrow and the security property is preserved by the chosen model:

- The extension **cannot unlock anything**. `requestUnlock` only asks the app to
  *present* its own unlock UI. The master password is typed into the native app and
  never enters the browser process, the popup DOM, or any bridge message.
- Touch ID cannot run in an extension at all — `LocalAuthentication` is native-only —
  so biometric unlock necessarily means "the app shows the prompt". This model is the
  only one that supports it.
- A valid pairing secret is still required. This is possible while locked because
  pairing lives in `KeychainExtensionPairingStore`, independent of the vault.

**Accepted UX consequence:** activating MyPass takes focus, which closes the Chrome
popup. The user unlocks in the app, returns to Chrome, and reopens the popup to see
credentials. Commit `95ea2a9` removed window activation on pairing-code generation for
exactly this reason — so the popup must fire-and-forget here, with no "waiting for
unlock" state that the user will never see.

- [ ] **U1** — Design doc in `docs/superpowers/specs/` (use `superpowers:brainstorming`
      first). Must record the reversal above and supersede the redesign plan's constraint.
- [ ] **U2** — Implementation plan in `docs/superpowers/plans/`
- [ ] **U3** — `ExtensionBridgeKit`: `requestUnlock` request + `unlockPresented` response
- [ ] **U4** — `ExtensionBridgeService`: `requestUnlock` handler
  - [ ] Exception to the blanket `guard vaultSession?.currentDatabase != nil` gate at
        `ExtensionBridgeService.swift:24` — the second such exception, alongside plan C's
        `getPasskeyProxyStatus`. Consider factoring the exception list rather than
        bolting on a second special case.
  - [ ] Pairing still required; unpaired → `.pairingRequired`, no window activation
  - [ ] Already-unlocked → respond without activating the window
  - [ ] Rate limit / debounce so repeated requests cannot spam Touch ID prompts
  - [ ] The service never unlocks the vault itself — it only fires `onUnlockRequested`
- [ ] **U5** — `MyPassApp` wiring: activate the window and present the unlock UI,
      reusing the existing `MenuBarUnlockPanelView` / `UnlockView` path
      (`DeviceUnlockAuthenticator`, `BiometricKeyStore`) rather than a new surface
- [ ] **U6** — `background.js`: route `requestUnlock`
- [ ] **U7** — `popup.js` / `popup.html`: "Unlock MyPass" button on the locked panel,
      alongside the existing Retry; fire-and-forget, no waiting state
- [ ] **U8** — `RUN.md` manual checklist (Ukrainian)
- [ ] **U9** — Full verification run

**⛳ Gate 3** — `./scripts/test.sh` green; manual: locked + paired → button unlocks via
password and via Touch ID; locked + unpaired → no window activation; repeated clicks
raise no prompt storm.

---

## Stage 4 — Piece A: TOTP autofill and privacy circle

First plan to touch the shared Chrome/bridge files. Establishes `hasTotp`, which B and C
both build on.

- [ ] **A1** — `ExtensionBridgeKit`: `.getTotp` request, `.totp` response, `hasTotp` on summary
- [ ] **A2** — `ExtensionBridgeService`: populate `hasTotp`, live TOTP on fill, `getTotp` handler
  - [ ] Verify the Base32 secret appears in no outbound message (plan's first global constraint)
- [ ] **A3** — `content.js`: `scoreOtpLikeness` / `findOtpField`, OTP-aware `applyFill`
- [ ] **A4** — `background.js`: `getTotp` in the known-types allowlist
- [ ] **A5** — `popup.js` / `popup.html`: privacy circle, reveal/copy states
- [ ] **A6** — Manual e2e fixtures + `RUN.md` checklist (Ukrainian)
- [ ] **A7** — Full verification run; `totpCircle.test.js` wired into `scripts/test.sh`

**⛳ Gate 4** — `./scripts/test.sh` green; manual e2e from `RUN.md` passes.

---

## Stage 5 — Piece B: TOTP setup

Builds on A's `hasTotp` for the picker badge. Adapt plan anchors — B is written against
the pre-A state of `background.js` and `ExtensionBridgeMessages.swift`.

- [ ] **B1** — `ExtensionBridgeKit`: `proposeSaveTotp` request
- [ ] **B2** — `ExtensionBridgeService`: `proposeSaveTotp` handler with domain re-validation
- [ ] **B3** — `NavigationState`: `PendingTotpSaveProposal`, routing, `MyPassApp.init()` wiring
- [ ] **B4** — `ContentView.swift`: route proposals to create / edit
- [ ] **B5** — `EntryEditView.swift`: OTP pre-fill + "Replace 2FA?" confirmation
- [ ] **B6** — `content.js`: otpauth link/text/manual-key detection + TOTP banner (no QR yet)
- [ ] **B7** — `content.js`: QR detection via vendored `jsQR`
  - [ ] Check `jsQR` licence and record it before vendoring
  - [ ] Confirm the vendored script loads under the MV3 content-script CSP
- [ ] **B8** — `background.js`: `proposeSaveTotp` routing, `openPopupForTotpPicker`,
      listener extracted into a testable `handleRuntimeMessage`
- [ ] **B9** — `popup.js` / `popup.html`: "Add 2FA" paste field + multi-match entry picker
- [ ] **B10** — Manual e2e fixtures + `RUN.md` checklist (Ukrainian)
- [ ] **B11** — Full verification run; new JS tests wired into `scripts/test.sh`

**⛳ Gate 5** — `./scripts/test.sh` green; all five e2e scenarios from the design pass
(0 matches, 1 match, N matches, replace-existing, locked vault).

---

## Stage 6 — Piece C: passkeys, remaining tasks

Requires Gate 0 (especially **S1**) and Gate 2. Apply the S4–S8 plan fixes as written.

- [ ] **C1** — `ExtensionBridgeKit`: passkey wire protocol (adapt to A's and B's cases —
      add, never replace; `entryId` may already exist from B)
- [ ] **C4** — `ExtensionBridgeService`: passkey handlers, pending-ceremony maps,
      `hasPasskey` in `getCredentials`, `LoopbackServer` routing
  - [ ] `getPasskeyProxyStatus` answers even while the vault is locked — the single
        documented exception to the blanket locked gate
- [ ] **C5** — `BrowserSettingsPane`: "Use MyPass for Chrome passkeys" toggle (opt-in, default off)
- [ ] **C6** — `EntryDetailView`: read-only Passkey section + destructive "Remove passkey"
- [ ] **C7** — `manifest.json`: `webAuthenticationProxy` permission, `minimum_chrome_version`
  - [x] Per **S2**, raise the declared minimum from `115` to `127`. `webAuthenticationProxy`
        needs 115, but `chrome.action.openPopup()` is policy-installed-only on 118–126,
        so 127 is the real floor for the confirm UX. Alternatively keep 115 and document
        that 115–126 users only ever get the notification fallback.
- [ ] **C8** — `background.js`: proxy lifecycle, ceremony relay, watchdog
  - [ ] Incorporates **S4** (complete isUvpaa when disabled)
  - [ ] Incorporates **S5** (locked / pairingRequired branch)
  - [ ] Incorporates **S6** (promise wrapper removed)
  - [ ] Incorporates **S7** (`storage.session` as source of truth)
- [ ] **C9** — `popup.js` / `popup.html`: confirm / picker / locked / unattached panels,
      session-pending rehydration
- [ ] **C10** — Manual e2e fixtures + `RUN.md` checklist (Ukrainian)
- [ ] **C11** — Full verification run; `passkeyProxy.test.js` wired into `scripts/test.sh`

**⛳ Gate 6** — `./scripts/test.sh` green; a real register-then-sign-in round trip against
a live WebAuthn test site; vault lock and pairing loss both cancel a pending ceremony.

---

## Progress

| Stage | Items | Done |
|-------|-------|------|
| 0 — Spike + plan C fixes | 8 | **8 — complete** |
| 1 — Vault (V1–V9) | 9 | **9 — already shipped** |
| 2 — Passkey core (C2–C3) | 2 | 0 |
| 3 — Unlock from popup (U1–U9) | 9 | 0 |
| 4 — Piece A (A1–A7) | 7 | 0 |
| 5 — Piece B (B1–B11) | 11 | 0 |
| 6 — Piece C rest (C1, C4–C11) | 9 | 0 |
| **Total** | **55** | **17** |

## Decisions

Record spike outcomes and any deviation from the plans here, with a date.

| Date | Item | Decision |
|------|------|----------|
| 2026-08-07 | Ordering | Chrome pieces run A → B → C rather than hardest-first; C's isolated core pulled forward to Stage 2. |
| 2026-08-07 | C task 1 | Excluded from the isolated core — it edits `ExtensionBridgeMessages.swift`, shared with A and B. |
| 2026-08-07 | Unlock from popup | Approved, reversing the redesign plan's "no unlock-from-extension" constraint. Model: popup asks, app presents its own unlock UI. Master password never enters the browser; Touch ID is native-only so no alternative exists. |
| 2026-08-07 | Popup focus loss | Accepted: activating MyPass closes the Chrome popup. No waiting state in the popup — user reopens it after unlocking. |
| 2026-08-07 | S1 | `webAuthenticationProxy` is available to unpacked extensions — no enterprise policy required. Verified against Chromium `_permission_features.json` and `_api_features.json` (no `location: "policy"`, no allowlist, `channel: stable`, `mac` supported). Stage 6 unblocked. |
| 2026-08-07 | S2 | `chrome.action.openPopup()` needs **no** user gesture (no such check in `ActionOpenPopupFunction::Run()`), but requires the Chrome window to be OS-level focused (`IsActive()`, else `kOpenPopupInactiveWindow`). Normal passkey flow satisfies this. Effective Chrome floor is **127** (policy-only on 118–126), so `minimum_chrome_version` in C7 must move from 115 to 127. |
| 2026-08-07 | S3 | Real create + get payloads captured from live Chrome. Both plan-C parsers match. Four amendments recorded on the S3 item: payload-supplied origin replaces `chrome.tabs.query` (C3/C4/C8), negative `requestId` test (C1), Chrome's 180 s timeout vs our 120 s watchdog (C8), unpadded base64url (C3). |
| 2026-08-07 | Stage 1 correction | The vault plan was listed as pending **in error** — it was already implemented and merged (V1-V9 all map to commits, plus whole-branch review fix `e77878c`). Cause: the check run while drafting this roadmap was `grep -rl LocalFileVaultStore --include=*.swift .`, which zsh rejected with "no matches found: --include=*.swift"; the command never ran and its shell error was misread as "no results". A re-check of A, B, C and U with a working command confirms those four are genuinely unimplemented. |
| 2026-08-07 | S8 | Honour the RP's requested attestation conveyance: `"none"` (the WebAuthn default, and what Chrome actually sends) now emits `fmt: "none"` with an empty `attStmt`; packed self-attestation is kept for `direct`/`indirect`/`enterprise`. Canonical CTAP2 key ordering preserved in both branches. |

## Known trap when running the suite

`Packages/SyncKit/Tests/SyncKitTests/CitadelDependencySmokeTests.swift` reads a hand-made
ed25519 key from `/tmp/citadel_smoke_key`. macOS clears `/tmp`, and unlike its neighbours
(`MYPASS_SFTP_INTEGRATION_TESTS`, `MYPASS_ICLOUD_INTEGRATION_TESTS`) this suite has **no
env gate**, so it fails hard once the file is gone. Because `scripts/test.sh` runs under
`set -e`, that failure aborts the script before `ExtensionBridgeKit` and the JS tests ever
run — precisely the suites Stages 2-6 depend on.

Regenerate the fixture with the command documented in the test's own header:

```bash
ssh-keygen -t ed25519 -N "correct-horse-battery-staple" -f /tmp/citadel_smoke_key -C "smoketest@mypass"
```

Worth fixing properly at some point — either gate it like its neighbours, or generate the
key into the test's own temp directory in `setUp`. Not part of any current plan.

Also: never judge a run by `./scripts/test.sh | tail`. The pipeline reports `tail`'s exit
code, not the script's, which is how a 4-failure run first read as a pass here.

## Verification commands

```bash
./scripts/test.sh                 # everything: xcodebuild + 3 SPM packages + JS tests
(cd Packages/ExtensionBridgeKit && swift test)
xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS'
node ChromeExtension/tests/<file>.test.js
```
