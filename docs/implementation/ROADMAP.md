# Implementation Roadmap — Vault Location + Chrome Extension Pieces A / B / C

**Status file.** This is the single place where execution progress across the
outstanding workstreams is tracked. Tick a box only when the item is implemented **and**
its tests pass — see "Definition of done" below.

Last updated: 2026-10-11

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
        carries the true origin. The **C4** hardening item is **closed (2026-09-11)**: the
        app re-parses the payload and refuses any `originUrl` that disagrees with its own
        `remoteDesktopClientOverride.origin`, and on top of that enforces the WebAuthn
        RP ID invariant against the Public Suffix List. See Decisions.
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

- [x] **C2** — `KdbxEntry+Passkey.swift`: `KPEX_PASSKEY_*` accessors, `clearPasskey()`,
      widen `setFieldValue`/`fieldValue` to `internal` *(shipped: `71dc857`)*
  - [x] Adapted from the plan: `fieldValue(forKey:)` returns `String`, not `String?`, so the
        passkey getters read `fields.first(where:)?.value` directly — otherwise an absent
        passkey would read as `""` and `.flatMap` would not compile. Same idiom
        `totpSecretBase32` already uses.
- [x] **C3** — `PasskeyCeremony.swift`: CBOR/COSE encoder, WebAuthn JSON parse/build,
      ES256 key generation and signing *(shipped: `80f2c27`)*
  - [x] Fixtures reconciled with the real payload captured in **S3** — added coverage for
        ES256 offered alongside `-257`, and for the `transports` array Chrome injects
  - [x] Attestation format resolved per **S8** — two tests assert the real CBOR bytes
        (`a3 63 "fmt" 64 "none"` vs `66 "packed"`), which was previously untested

**⛳ Gate 2 — PASSED (2026-08-07).** 16 + 9 tests green, including the signature assertions
verified independently against CryptoKit. Full `./scripts/test.sh` also green, since C2
touched the shared `KdbxEntry+Convenience.swift`. Branch: `feat/passkey-core`.

Two typos in the plan's own test code were corrected while executing: an unbalanced paren
in the get-ceremony fixture (which would have made the challenge undecodable) and doubled
backslash escapes.

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

- [x] **U1** — Design doc in `docs/superpowers/specs/` (use `superpowers:brainstorming`
      first). Must record the reversal above and supersede the redesign plan's constraint.
      *(shipped: `2a42ddc` — `2026-08-07-chrome-extension-unlock-from-popup-design.md`)*
  - [x] Decided during brainstorming: force a fresh Touch ID prompt on request (the
        `.onAppear` auto-prompt does not re-fire on refocus); pairing required, accepting
        the unpaired+locked chicken-and-egg; no settings toggle.
  - [x] Found while writing: no app-side unlock UI is needed — `ContentView.swift:11`
        already shows `UnlockView` when locked, so `U5` reduces to raising the window.
- [x] **U2** — Implementation plan in `docs/superpowers/plans/`
      *(shipped: `ade4dda` — `2026-08-07-chrome-extension-unlock-from-popup.md`, 6 tasks)*
  - [x] Found while planning: `letter-avatar.test.js` and `popup-fallback.test.js` exist but
        were never wired into `scripts/test.sh`, so they have not run since they were added.
        Both cover `popup.js`, which this stage edits — the plan wires them in at Task 4.
- [x] **U3** — `ExtensionBridgeKit`: `requestUnlock` request + `unlockPresented` response
- [x] **U4** — `ExtensionBridgeService`: `requestUnlock` handler
  - [x] Exception to the blanket `guard vaultSession?.currentDatabase != nil` gate at
        `ExtensionBridgeService.swift:24` — the second such exception, alongside plan C's
        `getPasskeyProxyStatus`. Consider factoring the exception list rather than
        bolting on a second special case.
  - [x] Pairing still required; unpaired → `.pairingRequired`, no window activation
  - [x] Already-unlocked → respond without activating the window
  - [x] Rate limit / debounce so repeated requests cannot spam Touch ID prompts
  - [x] The service never unlocks the vault itself — it only fires `onUnlockRequested`
- [x] **U5** — `MyPassApp` wiring: activate the window and present the unlock UI,
      reusing the existing `MenuBarUnlockPanelView` / `UnlockView` path
      (`DeviceUnlockAuthenticator`, `BiometricKeyStore`) rather than a new surface
- [x] **U6** — `background.js`: route `requestUnlock`
- [x] **U7** — `popup.js` / `popup.html`: "Unlock MyPass" button on the locked panel,
      alongside the existing Retry; fire-and-forget, no waiting state
- [x] **U8** — `RUN.md` manual checklist (Ukrainian)
- [x] **U9** — Full verification run *(automated: `./scripts/test.sh` green; manual:
      all 12 `RUN.md` bullets walked and confirmed 2026-08-07)*

**⛳ Gate 3 — PASSED (2026-08-07).**
Blocks 1-3 of the checklist all pass: button visibility, waiting state, self-refresh
without Retry, poll timeout, double-click debounce, no-biometrics path, and the
unpaired path showing no button. Pairing-code visibility, the closed-window
(Cmd+W) path and window non-duplication were confirmed live while debugging.

The last bullet — locking the vault (Cmd+L) *while a pairing code is displayed* — was
confirmed too: the code clears and the window drops off `.floating`. That path was the
fail-open shape the security review flagged, so it was worth verifying separately from
the normal completion path.

**Three defects surfaced only in manual testing**, all fixed (`96854c7`, `2238c09`,
`c968ca0`, `ee96cc0`, `37a49fc`). Two of them invalidated design assumptions:

- The popup does **not** reliably close when MyPass takes focus, so the spec's
  "no waiting state needed" reasoning was wrong. It now polls.
- Three separate mechanisms that act on the main window were themselves hosted
  *inside* that window (`ContentView`'s observers, `OpenMainWindowOnDemand`), so closing
  the window removed the mechanism. Watch for this shape in future window work.

Method note: four blind fix attempts failed before file-based instrumentation found the
cause in one run — and disproved the leading hypothesis (SwiftUI clobbering the window
level) along the way. Instrument after the first failed fix, not the fourth.

`./scripts/test.sh` genuinely green (`EXIT=0` unpiped, `** TEST SUCCEEDED **`, 370 app
tests, 42 ExtensionBridgeKit tests, all six JS suites). Acceptance criterion 7 verified
mechanically: `grep` finds no `password` reference and no password input anywhere in
`popup.js` / `popup.html`, and `requestUnlock` sends only `{ type: 'requestUnlock' }`.

`U9` stays open until the six-bullet checklist in `RUN.md` is walked against a real build
— Touch ID and window activation are not reachable from any automated test.

---

## Stage 4 — Piece A: TOTP autofill and privacy circle

First plan to touch the shared Chrome/bridge files. Establishes `hasTotp`, which B and C
both build on.

- [x] **A1** — `ExtensionBridgeKit`: `.getTotp` request, `.totp` response, `hasTotp` on summary
- [x] **A2** — `ExtensionBridgeService`: populate `hasTotp`, live TOTP on fill, `getTotp` handler
  - [x] Verify the Base32 secret appears in no outbound message (plan's first global constraint)
- [x] **A3** — `content.js`: `scoreOtpLikeness` / `findOtpField`, OTP-aware `applyFill`
- [x] **A4** — `background.js`: `getTotp` in the known-types allowlist
- [x] **A5** — `popup.js` / `popup.html`: privacy circle, reveal/copy states
- [x] **A6** — Manual e2e fixtures + `RUN.md` checklist (Ukrainian)
- [x] **A7** — Full verification run; `totpCircle.test.js` wired into `scripts/test.sh`

**⛳ Gate 4 — closed 2026-08-08:** full `./scripts/test.sh` green and the manual walk of all seven RUN.md TOTP bullets passed on a real Chrome + MyPass build.

---

## Stage 5 — Piece B: TOTP setup

Builds on A's `hasTotp` for the picker badge. Adapt plan anchors — B is written against
the pre-A state of `background.js` and `ExtensionBridgeMessages.swift`.

- [x] **B1** — `ExtensionBridgeKit`: `proposeSaveTotp` request
- [x] **B2** — `ExtensionBridgeService`: `proposeSaveTotp` handler with domain re-validation
- [x] **B3** — `NavigationState`: `PendingTotpSaveProposal`, routing, `MyPassApp.init()` wiring
- [x] **B4** — `ContentView.swift`: route proposals to create / edit
- [x] **B5** — `EntryEditView.swift`: OTP pre-fill + "Replace 2FA?" confirmation
- [x] **B6** — `content.js`: otpauth link/text/manual-key detection + TOTP banner (no QR yet)
- [x] **B7** — `content.js`: QR detection via vendored `jsQR`
  - [x] Check `jsQR` licence and record it before vendoring
  - [x] Confirm the vendored script loads under the MV3 content-script CSP
- [x] **B8** — `background.js`: `proposeSaveTotp` routing, `openPopupForTotpPicker`,
      listener extracted into a testable `handleRuntimeMessage`
- [x] **B9** — `popup.js` / `popup.html`: "Add 2FA" paste field + multi-match entry picker
- [x] **B10** — Manual e2e fixtures + `RUN.md` checklist (Ukrainian)
- [x] **B11** — Full verification run; new JS tests wired into `scripts/test.sh`

**⛳ Gate 5** — `./scripts/test.sh` green; all five e2e scenarios from the design pass
(0 matches, 1 match, N matches, replace-existing, locked vault).

Gate 5 closed 2026-08-08: full `./scripts/test.sh` green, the whole-branch review's findings fixed, and the manual walk of all fourteen new RUN.md bullets passed on a real Chrome + MyPass build — including six defects the walk itself surfaced (see Decisions).

---

## Stage 6 — Piece C: passkeys, remaining tasks

Requires Gate 0 (especially **S1**) and Gate 2. Apply the S4–S8 plan fixes as written.

- [x] **C1** — `ExtensionBridgeKit`: passkey wire protocol *(shipped: `573f760`)*
  - [x] Adapted: `getPasskeyProxyStatus` joins `requestUnlock` in U3's
        `isAnswerableWhileLocked` exemption list rather than being special-cased ahead of
        the blanket lock guard. That list is now the one place an exception is declared —
        the factoring the C4 note below asked for.
  - [x] `hasPasskey` added alongside A's `hasTotp`, neither replacing the other
- [x] **C4** — `ExtensionBridgeService`: passkey handlers, pending-ceremony maps,
      `hasPasskey` in `getCredentials`, `LoopbackServer` routing *(shipped: `5bc9cc8`,
      `c4ff7db`, `00a195a`)*
  - [x] `getPasskeyProxyStatus` answers even while the vault is locked — the second
        documented exception to the blanket locked gate, declared in the same list as U3's
  - [x] Beyond the plan: recycle-bin entries excluded from passkey matching (Gate 5
        precedent); `passkeyGetApprove` re-resolves `entryId` inside the ceremony's own
        relying party; locking the vault drops every pending ceremony
- [x] **C5** — `BrowserSettingsPane`: "Use MyPass for Chrome passkeys" toggle *(shipped: `30ab273`)*
- [x] **C6** — `EntryDetailView`: read-only Passkey section + destructive "Remove passkey"
      *(shipped: `a1a2afd`)*
- [x] **C7** — `manifest.json`: `webAuthenticationProxy` permission, `minimum_chrome_version`
      *(shipped: `fee7007`)*
  - [x] Per **S2**, raise the declared minimum from `115` to `127`. `webAuthenticationProxy`
        needs 115, but `chrome.action.openPopup()` is policy-installed-only on 118–126,
        so 127 is the real floor for the confirm UX. Alternatively keep 115 and document
        that 115–126 users only ever get the notification fallback.
- [x] **C8** — `background.js`: proxy lifecycle, ceremony relay, watchdog *(shipped: `2a2130e`)*
  - [x] Incorporates **S4** (complete isUvpaa when disabled)
  - [x] Incorporates **S5** (locked / pairingRequired branch — plus an `error` branch the
        plan missed, see Decisions)
  - [x] Incorporates **S6** (promise wrapper removed)
  - [x] Incorporates **S7** (`storage.session` as source of truth, `chrome.alarms` watchdog)
- [x] **C9** — `popup.js` / `popup.html`: confirm / replace / approve / picker panels,
      session-pending rehydration, settings toggle *(shipped: `7a40005`)*
- [x] **C10** — Manual e2e fixtures + `RUN.md` checklist (Ukrainian) *(shipped: `6dcdce3`)*
- [x] **C11** — Full verification run; `passkeyProxy.test.js` and `passkeyPopup.test.js`
      wired into `scripts/test.sh`

**⛳ Gate 6** — `./scripts/test.sh` green; a real register-then-sign-in round trip against
a live WebAuthn test site; vault lock and pairing loss both cancel a pending ceremony.

Automated half done 2026-08-09: `./scripts/test.sh` green unpiped (`EXIT=0`,
`** TEST SUCCEEDED **`) — 439 app tests, 134 MyPassKit, 86 SyncKit, 59 ExtensionBridgeKit,
and all eleven JS suites including the two new ones. Criterion 10 ("no key in the
extension") verified mechanically: `grep -rn "passkeyPrivateKeyPEM\|PRIVATE KEY"
ChromeExtension/` returns nothing, and no `ExtensionBridgeResponse` case carries PEM.
Criterion 13 verified the same way: all seven new handler cases open with
`pairingManager.isAuthorized`.

**⛳ Gate 6 — PASSED (after the 2026-08-24 fixes).** The manual half was walked against a
real Chrome 127+ and a real MyPass build — the thirteen new `RUN.md` bullets. Nothing in
the proxy lifecycle (`attach`/`detach`, `chrome.action.openPopup()`, a real
`requestDetailsJson`) is reachable from an automated test, so this is a manual-only
guarantee, as Stage 3 and Stage 5 both proved the hard way. The first walk on 2026-08-23
surfaced three defects — candidate matching, the app-side toggle not taking effect, and a
follow-up because the first toggle fix only half worked — all three recorded in Decisions
and fixed within a day. The checklist was then re-walked green.

---

## Stage 7 — Inline fill icon

Plan: [`2026-08-14-chrome-extension-inline-fill-icon`](../superpowers/plans/2026-08-14-chrome-extension-inline-fill-icon.md),
7 tasks. Puts a key glyph inside recognised username / password / OTP fields; clicking it
opens a panel listing the domain's entries and fills the form on selection. All work is
inside `ChromeExtension/content.js` plus a new test suite — no change to `background.js`,
`popup.js`, or `manifest.json`.

- [x] **I1** — `findFillableFields` and a safe `findLoginForm` rewrite; characterisation
      tests added first since `findLoginForm` had no prior coverage
- [x] **I2** — `chooseInlinePanel` — pure panel routing
- [x] **I3** — Trusted-event gate and the fill message
- [x] **I4** — The icon host — closed shadow root, inline SVG, no page mutation
- [x] **I5** — The panel — render the routed state and wire the fill
- [x] **I6** — Lifecycle: attach icons, keep them aligned, open and close the panel (no new
      unit tests — this is the DOM wiring the previous five tasks were extracted out of;
      verified by the Task 7 manual walk)
- [x] **I7** — `inlineIcon.test.js` wired into `scripts/test.sh`; `RUN.md` manual checklist;
      this stage recorded

**⛳ Gate 7 — PASSED (2026-08-15).** Automated half green 2026-08-14: `./scripts/test.sh` green unpiped
(`EXIT=0`, `** TEST SUCCEEDED **`) — 448 app tests, 134 MyPassKit, 86 SyncKit,
59 ExtensionBridgeKit, and all twelve JS suites including the new `inlineIcon.test.js`
(8 sections: `isFieldVisible`, `findFillableFields`, `findLoginForm`, `chooseInlinePanel`,
trusted-event gate, icon host, shadow host separation, panel content).

**Gate 7 closed 2026-08-15** — the full `RUN.md` walk passed on a real Chrome build, and
the drift the thirteenth bullet was written for did not materialise: the capture-phase
`scroll` listener catches nested containers too, so a field inside a scrollable
sub-container keeps its icon.

The walk earned its keep. It surfaced **four blocking defects that nine code reviews had
all missed**, every one of them invisible in a diff:

1. The feature threw an uncaught `ReferenceError` and had never run at all — and the same
   throw killed the shipped Stage-5 TOTP save banner on any page with a password field.
   Unreachable from the node suite, which skips the whole browser-only block.
2. Filling targeted the first password field in the document rather than the clicked one,
   so on a page with several groups it always filled the wrong form.
3. Filling did nothing on a fresh tab: `relayFillToActiveTab` read `tab.url`, which the
   `activeTab` permission only exposes after a gesture on the extension itself. A click
   inside the page is not such a gesture. This lived in Chrome's permission model, not in
   any line of the diff.
4. Extracting `letterFromTitle`/`colorForTitle` into a shared classic script killed the
   popup outright: `popup.js` redeclared those names with a top-level `const`, a
   `SyntaxError` at instantiation. Node cannot see it — there `popup.js` is a CJS module —
   and `vm.runInContext` does not reproduce the semantics either, which is how a probe
   wrongly cleared it. Only real headless Chrome showed the throw.

The defects forced three deliberate reversals, all recorded in Decisions: `background.js`
stopped being off-limits, the relay now targets the sending document instead of the active
tab, and a fill lands only in the clicked field.

Fix summary and the shape to remember: nothing here was findable by reading a diff. Stages
3, 5 and 6 each shipped defects the walk caught; Stage 7 makes four in a row, and two of
them were regressions in already-shipped surfaces.

---

## Stage 8 — Inline icon follow-ups: recognition, dark theme, iframes

Three strands landed together, all reached through `feat/inline-icon-polish` and
`feat/inline-icon-iframes` plus an independent security fix. Spec:
[`2026-08-15-chrome-extension-inline-icon-iframes-design`](../superpowers/specs/2026-08-15-chrome-extension-inline-icon-iframes-design.md),
plan: [`2026-08-15-chrome-extension-inline-icon-iframes`](../superpowers/plans/2026-08-15-chrome-extension-inline-icon-iframes.md).
The polish strand and the IP fix had no plan of their own — both were small and are recorded
here as their own items.

- [x] **F1** — `placeholder` / `aria-label` / associated `<label>` join `name` and `id` as
      username hints, as ONE group contributing `+2` at most and only when neither `name` nor
      `id` matched. `name` and `id` keep their original independent `+2` each — a first
      attempt merged them, compressing the range that `findBestUsernameInput` ranks by
- [x] **F2** — `prefers-color-scheme: dark` block in the panel's shadow stylesheet
- [x] **F3** — Frame policy (`FRAME_FEATURE_POLICY`, `isFeatureEnabledInFrame`) and its four
      gates: both banners, the initial TOTP scan, and the `queryTotpCandidate` responder stay
      in the top frame. Fails closed — a feature added later without a policy entry does not
      silently start rendering inside every ad frame
  - [x] `buildMutationSweep` extracted so the sweep's two halves are independently testable.
        The observer serves `attachIcons` (all frames) and the TOTP banner (top only); a
        review swapped them and all 14 suites stayed green, which is why it is now pinned
- [x] **F4** — `manifest.json` split into two content-script entries: `all_frames: true` for
      `content.js`, and `vendor/jsQR.js` top-frame only. 314,849 → 57,872 bytes per subframe
- [x] **F5** — Cross-origin fixture (`inline-icon-iframe-parent.html`) plus `RUN.md` walk
  - [x] Retargeted from `localhost:8766` to `127.0.0.1:8766` — `hostnameMatches` compares
        hostname only, so the original fixture could not falsify its own acceptance criterion
  - [x] The walk is ordered, not a list: the "no banner in a frame" check must run BEFORE an
        entry exists for that host, because the banner only fires when the domain has none
- [x] **F6** *(security)* — The popup's `applyFill` is scoped with `{ frameId: 0 }`. Under
      `all_frames` the old unscoped three-argument call became a tab-wide broadcast of a
      decrypted password: any same-hostname subframe passed the origin check, had no pending
      target, and fell through to `findLoginForm()`
- [x] **F7** — `document.body` guards in `observeTotpCandidates` and `attachIconTo`. SVG and
      XML documents are ordinary iframe targets and have no body
- [x] **F8** — `isExtensionContextAlive` guards all seven `chrome.runtime.sendMessage` sites
      and tears down our own injected UI when the context dies. Reloading an unpacked
      extension orphans content scripts in open tabs; every stale icon threw
      "Extension context invalidated" on click
- [x] **F9** *(security)* — `ExtensionEntryMatcher` compares IP literals whole. It reduced
      every host to its last two labels, so `127.0.0.1`, `192.168.0.1` and `10.0.0.1` all
      became `"0.1"` — a router admin password was offered on a page served from localhost

**⛳ Gate 8 — PASSED (2026-08-15).** `./scripts/test.sh` green unpiped on the merged result
(`EXIT=0`, `** TEST SUCCEEDED **`, 0 failures), and the full `RUN.md` walk confirmed on a real
Chrome build across both strands.

The walk earned its keep again. **F6 and F9 were both found in the browser, not by review** —
F6 by the final whole-branch review only after it was told to read the untouched
`background.js`, and F9 by the user noticing an unexpected entry in a panel and calling it "a
small nuance". Three separate checks in this stage turned out to be **incapable of failing**
before they were fixed: the same-hostname fixture, the prerequisite that silenced the banner
check it was meant to enable, and IPv6 tests using dotless addresses that never reached the
branch they claimed to cover.

---

## Progress

| Stage | Items | Done |
|-------|-------|------|
| 0 — Spike + plan C fixes | 8 | **8 — complete** |
| 1 — Vault (V1–V9) | 9 | **9 — already shipped** |
| 2 — Passkey core (C2–C3) | 2 | **2 — complete** |
| 3 — Unlock from popup (U1–U9) | 9 | **9 — complete** |
| 4 — Piece A (A1–A7) | 7 | **7 — complete** |
| 5 — Piece B (B1–B11) | 11 | **11 — complete** |
| 6 — Piece C rest (C1, C4–C11) | 9 | **9 — complete** |
| 7 — Inline fill icon (I1–I7) | 7 | **7 — complete** |
| 8 — Inline icon follow-ups (F1–F9) | 9 | **9 — complete** |
| **Total** | **71** | **71 — complete** |

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
| 2026-08-07 | A scoring semantics | Plan A's illustrative scoring code contradicts its own test values (additive scoring gives 11 where tests demand 10; findOtpField would return a score-1 field where tests demand null). Ruling: the test assertions govern. autocomplete=one-time-code is a decisive signal (early-return 10, not stacked) and findOtpField requires MIN_OTP_FIELD_SCORE = 4. Both documented in content.js comments plus boundary tests. |
| 2026-08-07 | A copied-flash dismissal | Plan A's popup snippet contradicts its own Global Constraints (copied flash must dismiss on second left-click / outside click; outside-click hide must survive sibling circles' stopPropagation). Ruling: constraints prose governs. Fixed via an active revealed-or-copied flag, capture-phase document listener with isConnected self-cleanup (commit d78a6d3). |
| 2026-08-08 | B dismissal priority | Plan B's banner snippet hardcoded {priority: 4} on dismiss, contradicting its Global Constraints (a dismissed priority-1 banner would instantly re-show). Ruling: constraints govern — dismiss records the actual dismissed candidate's priority. |
| 2026-08-08 | B manual-key detector | Plan B's detectManualSetupKey snippet fails its own test (greedy token concat matches "YOURMANUALSETUPKEY" before the real key). Ruling: the plan's tests govern; search window restricted to contiguous all-caps-as-written tokens. Lowercase page keys deferred. |
| 2026-08-08 | B locked-state gating | Plan B's popup and banner snippets sent proposeSaveTotp even on locked/pairingRequired getCredentials responses, contradicting "locked → no proposal sent". Ruling: constraints govern — both paths now classify the response and only a real credentialList proceeds (popup: d89b793; banner: 61e473c, which also records dismissal on Save to stop a re-show loop). |
| 2026-08-08 | B follow-ups parked | Final review deferrals (none touch the trust model): per-image QR decode memoization, event.isTrusted on banner buttons, isReplacingTotp recompute on cleared field, picker panel polish, img.onload rescan. |
| 2026-08-08 | Gate 5 walk findings | The manual walk surfaced four fixes: create-path TOTP proposals dropped the secret (plan B Task 4 defect, `fa50b0d`); recycle-bin entries were matched by all four bridge requests — now filtered at one choke point, plus the `.codes` smart category (`7fb3823`); no way to empty the bin or delete permanently — added with KdbxDeletedObject tombstones consumed by MergeEngine (`4155d84`); no way to remove 2FA in the editor — explicit Remove button, `applyOTP` empty-input semantics untouched (`1b1a313`); `isInRecycleBin` made subtree-recursive to keep the bridge boundary aligned with `emptyRecycleBin` (`c984a41`). |
| 2026-08-08 | Editor and popup UX | Two further walk findings: the editor showed an empty OTP field for entries that already had 2FA, so the stored secret could be neither seen nor edited — now pre-filled, with proposal prefill still taking precedence so the Replace-2FA alert keeps its meaning (`0b54899`); the popup's Add-2FA section was always visible — now hidden unless the page reports a 2FA candidate (new `queryTotpCandidate` content-script message) or the picker flow opens it (`e36f26d`). |
| 2026-08-09 | Passkey card UX | The read-only Passkey section showed rpId, passkey username and a truncated credential ID inline — diagnostics presented as everyday reading. Reduced to one row (`Passkey` · `Added <date>`) with a **Show** popover behind it, and removal moved out of the card into the editor, next to every other destructive edit. |
| 2026-08-09 | `KPEX_PASSKEY_CREATED` | KeePassXC's passkey field set has no creation date, so MyPass adds one as a plain ISO8601 custom field, stamped at ceremony time. It is deliberately not derived from the entry's own timestamps: a passkey added to a years-old entry must date from today, and `lastModificationTime` changes on every unrelated edit. A passkey imported from KeePassXC has no date and renders as a plain "Added". |
| 2026-09-12 | KDBX4 Argon2 interop | Vendored phc-winner-argon2 (ref variant) as a SwiftPM C target, replacing swift-sodium for Argon2id/Argon2d key derivation. Lifted the 16-byte salt and P=1 constraints; added Argon2d support; save() now writes a 32-byte salt and P=2. Fixed a real blake2b symbol collision between the vendored library and libsodium via compile-time renaming. See docs/superpowers/plans/2026-09-12-kdbx4-argon2-interop.md for the full plan and measured derivation-time results. |
| 2026-08-09 | Passkey fields are standard fields | Found while reworking the card: `additionalFields` treated `KPEX_PASSKEY_*` as generic custom fields, so **the editor rendered the private-key PEM as an editable text row**, and — because all three editors rebuild `fields` as "standard keys plus the rows on screen" — hiding those rows would have silently destroyed a working passkey on the first unrelated edit. Both are fixed at the root by adding the passkey keys to `standardFieldKeys`, whose meaning is exactly "has a dedicated UI, never a generic row". Removal is now the one deliberate exception, applied after the rebuild. |
| 2026-08-09 | C locked-gate exemption | Plan C's "special-case `getPasskeyProxyStatus` before the blanket guard" was superseded by U3's `isAnswerableWhileLocked`, which landed after plan C was written. Both exemptions are now declared in one exhaustive switch with no `default`, so a new request case must state its position rather than inherit one. |
| 2026-08-09 | C native-messaging error envelope | Plan C's `background.js` wrapped `sendNativeMessageWithPairing` in try/catch for the "MyPass not running" path, but this codebase's `sendNativeMessage` **resolves** `{type:"error"}` rather than rejecting — the catch could never fire, and an unreachable app would have fallen through to the "unexpected response" branch. `error` is now an explicit branch everywhere a ceremony reply is classified. |
| 2026-08-09 | C subgroup write bug | Plan C's confirm handler located the target entry with `db.rootGroup.entries.firstIndex`, which finds nothing for an entry in a subgroup: the ceremony returned a success `responseJson` while writing no passkey, leaving the site holding a credential the vault has no key for. Now resolved through `GroupTreeOperations.entryLocation`, with a failed write reported as an error. Regression test added. |
| 2026-08-09 | C attach gate | Plan C mirrors `passkeyProxyEnabled` in `UserDefaults` and `chrome.storage.local`, but `attachAllowed` reported lock state only — so turning the feature **off in the app** left an already-attached Chrome attached, with MyPass still the exclusive passkey provider. `attachAllowed` now folds in the app's own value, and `isUvpaa` answers from `attachAllowed` rather than `unlocked`. The extension's local flag stays a cache; the app is authoritative. |
| 2026-08-09 | C popup toggle state | Plan C's snippet set the popup checkbox from `status.attachAllowed`, which is false whenever the vault is locked — the feature would have read as off on every locked-vault popup open. `checked` now comes from the extension's stored flag; `attachAllowed`/`unlocked` only drive whether the control is enabled. |
| 2026-08-09 | C ceremony owns the popup | A pending ceremony is checked before anything else at popup open and, when found, suppresses the ordinary `getCredentials` flow entirely rather than racing it — the same sequencing failure `restorePendingTotpCandidate` was fixed for in Stage 5. Panel routing was extracted into a pure `choosePasskeyPanel(pending)` so it is testable without a DOM. |
| 2026-08-08 | Closed-window proposals | Both proposal flows (password and TOTP) were lost whenever the main window was closed at proposal time: `NavigationState.pending*SaveProposal` was set before the fresh `ContentView` subscribed, and SwiftUI's `onChange` does not fire for an initial value, so the window opened on the plain list. Routing moved into `NavigationState.consumePendingProposals()`, called from both `onChange` handlers and from `onAppear` on the unlocked branch — which also covers a proposal that arrives while the vault is locked (`aec5528`). |
| 2026-08-14 | Inline fill icon: two constraints not to "optimise" away | (1) The icon renders on every recognised field unconditionally, regardless of match count or lock state — conditional visibility would leak account existence to the site and hand it a fingerprinting signal. (2) Every handler requires `event.isTrusted` — without it, `background.js`'s `relayFillToActiveTab`, which resolves its target via `chrome.tabs.query({active:true})` rather than `sender.tab.id`, becomes reachable by page script (a synthetic click could trigger a fill on whatever tab happens to be active). |
| 2026-08-15 | Fill targeting | A fill lands ONLY in the field whose icon was clicked. Originally the whole group was filled; the manual walk showed that reads as surprising when the user deliberately picks one field. Cost accepted by the user: signing in takes one panel opening per field. Side benefit — the group-scoping machinery (`findFillGroupScope`) became unnecessary and was deleted, removing a whole class of "which field is the partner" ambiguity. |
| 2026-08-15 | `background.js` no longer off-limits | The Stage 7 spec declared `background.js` unchangeable, assuming the existing fill path would just work. It did not: `relayFillToActiveTab` read `tab.url`, which the `activeTab` permission only exposes after a gesture **on the extension** — a click inside the page is not one — so inline fills silently aborted on every fresh tab. The constraint was wrong and was lifted. |
| 2026-08-15 | Relay targets the sender, not the active tab | Content-script fills now resolve `sender.tab.id` and validate against `sender.url`, with delivery scoped by `frameId`/`documentId`; the popup keeps the active-tab path, which its own opening gesture makes valid. This needs no host permissions and is strictly stronger than before: the secret goes to the exact document that asked, and a navigation mid-round-trip makes delivery fail instead of landing in the new origin's renderer. Fails closed when `documentId` is absent. |
| 2026-08-15 | Shared entry visuals | `letterFromTitle`/`colorForTitle` (and the palette they hash into) live in `ChromeExtension/shared/entry-visuals.js`, loaded by both the popup and the content script. Duplicating them would let one entry show different colours in the two surfaces — visible to a user, invisible to every test. The extraction initially broke the popup outright (top-level `const` redeclaring a name an earlier classic script had already declared: `SyntaxError` at instantiation, invisible to node and not reproduced by `vm.runInContext`); `scriptScopes.test.js` now guards that class statically. |
| 2026-08-15 | Frame policy fails closed | Which behaviours may run outside the top frame is stated once as data (`FRAME_FEATURE_POLICY`), not as `window.top === window` scattered through the file. An unknown feature name is enabled NOWHERE — adding a behaviour forces a decision about frames instead of inheriting one, so a banner added later cannot quietly start rendering inside every ad frame on the web. |
| 2026-08-15 | Popup fill scoped to frame 0 | Turning on `all_frames` gave every frame an `applyFill` listener, which turned the popup's unscoped `chrome.tabs.sendMessage` into a tab-wide broadcast of a decrypted password — any same-hostname subframe passed the origin check and fell through to `findLoginForm()`. Now `{ frameId: 0 }`. Consequence accepted: a login form living only inside an iframe is no longer fillable from the popup; the in-frame icon is that path. Not a regression — before `all_frames` no subframe had a listener at all. |
| 2026-08-15 | IP literals compared whole | `registrableDomain` took the last two dot-separated labels, collapsing `127.0.0.1`, `192.168.0.1` and `10.0.0.1` to `"0.1"`. A router admin password was therefore offered to any local server on an address ending `.0.1`. IPv4 (all labels numeric) and IPv6 (contains `:`) are now returned whole. Found by the user during the Stage 8 walk; the bug dated from Phase 4 and had survived every prior review and walk. Left deliberately: the `.co.uk` limitation, non-canonical IPv4 spellings (`192.168.1`, `0x7f.1`), and a second trailing dot — all under-match, which is the safe direction. |
| 2026-08-23 | `.co.uk` correction | The 2026-08-15 row called the multi-label suffix limitation an under-match; it was an OVER-match (`google.co.uk` and `amazon.co.uk` both reduced to `co.uk`, offering one site's credentials on the other). Fixed by `PublicSuffixList` in MyPassKit (full publicsuffix.org list incl. PRIVATE section); bare suffixes, single labels and IP literals compare whole. Unicode-form PSL rules (IDN suffixes such as `公司.hk`) are not matched against punycode hosts — no IDNA conversion; unchanged from the previous behaviour and tracked as a follow-up. |
| 2026-08-23 | Citadel smoke test self-skips | The suite now skips itself when `/tmp/citadel_smoke_key` is absent, with the regeneration command in the skip message; "Known trap" below is historical. |
| 2026-08-23 | Piece B follow-ups closed | Banner buttons require `event.isTrusted`; per-image QR decode memoized; `img` load events re-trigger the sweep; `isReplacingTotp` derived from current input. "Picker panel polish" dropped — no concrete defect was ever recorded for it. Lowercase manual setup keys remain deferred (original ruling stands). |
| 2026-08-23 | `SecuritySettingsPane.swift:251` | Diagnostic detail kept deliberately until the real-device Keychain failure is root-caused. |
| 2026-08-15 | Orphaned content scripts | Reloading an unpacked extension destroys the context of content scripts already injected into open tabs while leaving their DOM in place, so every stale icon threw "Extension context invalidated" on click. All seven `chrome.runtime.sendMessage` sites are now guarded by `chrome.runtime.id`, and a dead context tears our own UI out of the page. Deliberately NOT a blanket try/catch — genuine failures from a live context still surface. |
| 2026-08-15 | Three checks that could not fail | Recorded because the pattern recurred: a fixture whose two "different" origins were both `localhost`; a prerequisite that saved an entry and thereby silenced the very banner the next bullet checked for; and IPv6 tests using dotless addresses, which the pre-existing single-label passthrough answered without ever reaching the branch under test. Each looked like coverage and provided none. When a check asserts the ABSENCE of something, it needs a control showing that something can appear at all. |
| 2026-08-23 | Gate 6 walk finding — passkey create candidates | `passkeyCreate` listed only entries that already had a passkey for the rpId, so with existing Login entries for the host the popup showed a generic "Save passkey" for `<rpId — origin>` and confirm created a new, unrelated entry. Candidates are now the union of PSL-domain-matched Login entries and rpId passkey entries (spec step 4); the save/replace panels name the target entry and username, 0 matches says "New entry". |
| 2026-08-23 | Gate 6 walk finding — app-side passkey toggle | Toggling **Use MyPass for Chrome passkeys** in the app took effect only after a service-worker restart: `attachPasskeyProxyIfEligible` gated on the extension's own local cache (written only by the popup toggle), and nothing ever called `detach()` when the app's status said disabled — an app-side "off" left Chrome attached indefinitely. `passkeyProxyStatus` now carries `enabled` (the app's opt-in, reported separately from `attachAllowed` so it survives a locked vault); every status fetch resyncs the local cache and attaches/detaches accordingly (`syncPasskeyProxyFromStatus`), and the popup now sends a fire-and-forget `refreshPasskeyProxy` on every open, so a much more frequent event than a restart re-checks the app's authoritative state. App unreachable (no status) leaves both the cache and the current attachment untouched. |
| 2026-08-23 | Gate 6 walk finding — toggle still didn't take effect | The claim above ("the popup now sends a fire-and-forget `refreshPasskeyProxy` on every open") was false: that send lived inside `initPasskeySettingsToggle()`, which only ran when `rehydratePendingPasskeyCeremony` reported `tookOver === false` — i.e. it was skipped in exactly the scenario that matters, an active passkey ceremony. Real passkey use almost never resynced/detached the proxy. Separately, `.passkeyCreate`/`.passkeyGet` in `ExtensionBridgeService.swift` never checked `passkeyProxyEnabled` at all, so even a stale-attached Chrome would have the app process the ceremony anyway. Fixed on both sides: `popup.js` now sends `refreshPasskeyProxy` unconditionally (extracted into its own `refreshPasskeyProxy()` function, called before the `tookOver` branch), and `.passkeyCreate`/`.passkeyGet` now refuse outright with a `NotAllowedError` (`"MyPass passkeys are turned off in Settings"`) whenever `passkeyProxyEnabled` is off, regardless of Chrome's attach state. A known consistency hole remains, accepted rather than gated: if the user toggles the feature off while a `.passkeyCreate` Save panel is already showing (i.e. after `.passkeyCreate` returned pending), the popup's now-unconditional `refreshPasskeyProxy` detaches the proxy immediately, yet Save still writes the passkey into the vault while the page's in-flight ceremony fails against a detached proxy — passkey saved, error surfaced on the page. This is accepted under the existing "in-flight ceremony finishes" rule; `passkeyCreateConfirm`/`passkeyGetApprove` remain authorization-safe transitively (they can't be reached without the initial request having passed the new gate) but are not consistency-safe against a mid-ceremony toggle-off. |
| 2026-08-24 | Auto-lock idle timer vs extension activity | The idle timer was reset only by key and mouse events in the MyPass window, so a user working entirely in Chrome had the vault re-lock under them mid-session. `ExtensionBridgeRequest.resetsAutoLockTimer` now marks the gesture-gated requests and `ExtensionBridgeService` reports them through the new `AutoLockActivityRecording` protocol. The first cut was wrong and was corrected the same day: `getCredentials`, `passkeyCreate` and `passkeyGet` are page-controllable rather than user actions, so a hostile or merely noisy background tab could have defeated idle auto-lock entirely. The reset set is now exactly `fillCredential`, `getTotp`, `proposeSaveLogin`, `proposeSaveTotp`, `passkeyCreateConfirm`, `passkeyGetApprove` and `requestUnlock`. Activity is also recorded only after the response is computed, and only when `requestWasServed(_:)` says the request was actually served — a refusal (`locked`, `pairingRequired`, `error`, or a `*Complete` carrying an error) never counts as activity. |
| 2026-08-24 | One device-unlock prompt per locked session | Three independent auto-prompt paths — opening the window, an extension unlock request, and opening the menu bar panel — each tracked their own per-view `@State` flag, so each could fire its own Touch ID sheet. `MenuBarExtra`'s content closure is recreated on every menu open, which makes a per-view flag useless as a cross-open guard. `DeviceUnlockPromptCoordinator` now owns the decision: at most one `.automatic` prompt per locked session, an explicit click always allowed unless a prompt is literally in flight, and `vaultDidLock()` restoring the allowance. Failure feedback is surfaced only for `.explicit` triggers; an automatic prompt that fails stays silent. A prompt left in flight longer than `staleInFlightThreshold` (60s) is treated as finished so a dropped callback cannot wedge the gate for the rest of the session — and the root cause of those drops, an `LAContext` released before `evaluatePolicy` called back, is fixed by capturing it in the completion closure. |
| 2026-08-24 | Post-gate housekeeping | `scripts/run.sh` now stops a running MyPass before `open`, because `open` was activating the stale process and making fixes look like no-ops; it escalates TERM to KILL after five seconds and fails loudly rather than launching over a survivor. The passkey get flow in the popup was brought to parity with create — it names the target entry and shows the passkey badge in both the picker and the ordinary credential list. Two regression tests were repaired at the same time: the popup resync tests hand-rolled the init composition instead of exercising `initPasskeyPopupUI`, and `testSetPasskeyProxyEnabledPersistsAndReturnsEnabled` had been de-fanged by a `true` default in `setUpWithError`. |
| 2026-09-11 | C4 origin gate closed | The app now validates the origin of a passkey ceremony instead of trusting what the extension sent. `PasskeyCeremony.validateOrigin(_:requestDetailsJson:rpId:)` runs two independent checks, called from both `.passkeyCreate` and `.passkeyGet` immediately after the payload parses and before any candidate matching. First, the wire `originUrl` must equal the payload's own `extensions.remoteDesktopClientOverride.origin`, and an absent override is a refusal — the same fail-closed rule `background.js` already applies on its own side. On its own this check is weak, because a fully compromised extension controls both fields and would simply rewrite them together; its real value is that it removes the cheap lie and stops the two copies of the origin from drifting apart unnoticed. Second, and this is the actual gate, `rpId` must be the origin's host or a parent of it no higher than the registrable domain, which is the WebAuthn RP ID invariant. Without it the app would sign an assertion binding an attacker-chosen origin to an attacker-chosen relying party, and the Public Suffix List is what stops `rpId` climbing to something like `co.uk`. Both refusals surface as `SecurityError` through the existing `*Complete(error:)` channel. Worth recording: the pre-existing test fixtures carried no `remoteDesktopClientOverride` block at all, so the first check failed closed on every passkey test until the fixture builders were taught to emit one — the check was not relaxed to accommodate them. |

## Stage 9 — Site-aware password rules and per-entry URI match modes

Two related, fully offline capabilities: MyPass generates passwords that a site's own
Password Rules will actually accept, in both the app's generator and the browser
extension; and a vault entry can declare how its URL is matched against a page, via one
of five explicit `URIMatchMode` values, replacing the single hardcoded
registrable-domain rule. Spec:
[`2026-09-12-site-password-rules-and-uri-matching-design`](../superpowers/specs/2026-09-12-site-password-rules-and-uri-matching-design.md),
plan: [`2026-09-12-site-password-rules-and-uri-matching`](../superpowers/plans/2026-09-12-site-password-rules-and-uri-matching.md).

- [x] **Task 1** — Vendor Apple's `password-rules.json` snapshot into `Packages/MyPassKit`, with its provenance file and `scripts/update-password-rules.sh`
- [x] **Task 2** — `PasswordRulesParser` for the Password Rules grammar, with fixtures derived from Apple's own reference parser tests
- [x] **Task 3** — `PasswordRulesCatalog`, a host-keyed rule lookup that walks up to (but never above) the registrable domain
- [x] **Task 4** — `PasswordGenerator.generate(options:rules:)` honours required/allowed character classes, length clamping, `max-consecutive` repair, and a typed `.unsatisfiableRules` failure
- [x] **Task 5** — Property test against every rule in the vendored snapshot: every generated password satisfies its own rule
- [x] **Task 6** — `PasswordGeneratorDefaults` persists the user's generator toggles, shared by the app's own Generate button and the bridge handler
- [x] **Task 7** — `PasswordGeneratorView` surfaces the active rule in plain English, with a control to override it
- [x] **Task 8** — `URIMatchMode` and its hidden `MyPass.URIMatchMode` field on `KdbxEntry`, defaulting to `.registrableDomain` with no migration needed
- [x] **Task 9** — `ExtensionEntryMatcher` matches per-entry against all five `URIMatchMode` values, with `never` excluded before any credential list is assembled
- [x] **Task 10** — A match-mode picker beside the URL field in the entry edit form, with per-mode help text
- [x] **Task 11** — The 16th bridge request/response pair, `generatePassword`/`generatedPassword`, wired through every exhaustive switch in `ExtensionBridgeKit`, `ExtensionBridgeService`, and `LoopbackServer`
- [x] **Task 12** — `content.js` classifies password fields as `isNewPassword` via `autocomplete=new-password` or the confirm-password shape
- [x] **Task 13** — "Generate password" actions in the inline panel and the popup, gated on `event.isTrusted` and on the page actually having a new-password field

**⛳ Gate 9 — PASSED.** `./scripts/test.sh` green unpiped (`EXIT=0`,
`** TEST SUCCEEDED **`, 0 Swift-package failures, all 17 node scripts OK).

## Known trap when running the suite

**Fixed 2026-08-23** — the suite now skips itself when the fixture is missing; the text below is kept for history.

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

**Fixed 2026-08-09 — was flaky:** `LoopbackServerTests` intermittently timed out under
full-suite load while passing every time in isolation. Cause: the *client* connections in
those tests ran their callbacks on `.main`, and each test then blocks the main thread in
`wait(for:)` — so under a full run they competed with every other test's main-dispatched
work and missed the 5 s expectation. The server always had its own queue; the client now
does too (`clientQueue`), so the tests measure the server rather than main-queue load.
Confirmed with three consecutive green full runs. If anything in this class starts timing
out again, look for newly added main-queue work in the suite before suspecting the server.

Also: never judge a run by `./scripts/test.sh | tail`. The pipeline reports `tail`'s exit
code, not the script's, which is how a 4-failure run first read as a pass here.

## Passkey discovery and provider diagnostics — 2026-10-11

Design: [spec](../superpowers/specs/2026-10-11-passkey-discovery-and-provider-diagnostics-design.md).
Implementation: [plan](../superpowers/plans/2026-10-11-passkey-discovery-and-provider-diagnostics.md).

- [x] Passkeys categories in app and extension, consistent badge metadata and live-entry counts.
- [x] Registration exclusion checks after consent, preserving existing credentials on refusal.
- [x] Visible proxy attachment health, conflict diagnostics and retry/reconciliation with automated coverage.
- [x] Browser password-saving/provider warnings with explicit diagnostic limitations.
- [x] Site passkey-action guidance and confirmation popup fallback with automated coverage.
- [x] Combined source review and automated verification recorded below.
- [x] Authenticated GitHub passkey registration and sign-in with the installed MyPass extension. Confirmed 2026-10-15.
- [x] Manual checks of native/system passkey providers and other managers in the user's browser profile. Confirmed 2026-10-15.

Verification on 2026-10-11: `./scripts/test.sh` passed. Reported Swift totals: app 590
(1 skipped), MyPassKit 211 XCTest plus 6 Swift Testing tests, SyncKit 86 (20 skipped),
ExtensionBridgeKit 71 (2 skipped). Combined: 964 tests reported, 23 skipped, 941
executed, no failures. All 20 standalone JavaScript test files passed. Local run log:
`/tmp/mypass-final-20261011-102429.log` (temporary verification artifact, not committed).

Final popup review then fixed live checking/ready/cancel transitions, made Passkeys
category rows open sites without password autofill, and removed popup-owned pending
state deletion. Independent review approved these changes; all 20 JavaScript test files
passed again on the final code, recorded in `/tmp/mypass-final-node-20261011.log`.
The Swift implementation was unchanged after the full-suite run. `git diff --check`
passed. The post-review JavaScript rerun was not another full Swift-suite run.

GitHub's public login-page inspection on 2026-10-11 confirmed a passkey action only.
On 2026-10-15 a live registration and sign-in with the installed extension succeeded.
Tests use fixtures/mocks and cannot prove that walk. Conditional mediation/autofill UI
is not implemented by this change; users initiate the site's explicit passkey action.
Diagnostics cover observable Chrome password-saving settings and known/permission-
identified extensions only. They cannot establish that every OS provider or unknown
manager is disabled. That check was done manually in the user's browser profile on 2026-10-15.

## Browser settings and manager help — 2026-10-11

Design: [spec](../superpowers/specs/2026-10-11-browser-settings-and-manager-help-design.md).
Implementation: [plan](../superpowers/plans/2026-10-11-browser-settings-and-manager-help.md).

- [x] Native Browser settings with per-pairing reports, authenticated navigation and manager help; automated checks passed.
- [x] Compact extension status and browser-owned permission flow.
- [x] Chromium-compatible passkey create response and completion-error handling.
- [x] Full automated suite and independent review.
- [x] Mocked extension popup and browser-check page visual checks.
- [ ] Real native settings window visual verification.
- [x] Real GitHub passkey registration and sign-in confirmed by the website. Confirmed 2026-10-15.

Final verification on 2026-10-11: `./scripts/test.sh` passed. Swift totals: app 593
(1 skipped), MyPassKit 211 XCTest plus 6 Swift Testing tests, SyncKit 86 (20 skipped),
ExtensionBridgeKit 74 (2 skipped). Combined: 970 reported, 23 skipped, 947 executed,
zero failures. All 21 registered JavaScript suites passed, followed by an independent
final rerun of all 21. Logs: `/tmp/mypass-settings-final-20261011-111140.log` and
`/tmp/mypass-settings-final-node.log` (local temporary artifacts, not committed).

Chromium rejects create responses missing `publicKeyAlgorithm`, `authenticatorData`
and ES256 DER SPKI `publicKey`, even after the app stores a key. These fields now
match the emitted CBOR attestation. The extension waits for browser API acknowledgement
before clearing pending state, reports rejected completion, and guards a newer
ceremony from stale failure state. Regression tests exercise these boundaries.

Independent review passed. Mocked visual checks found no overflow in normal or long
popup content at 360 px and covered the browser-check page at desktop size. Native
help links were verified against official documentation. No live native-window visual
check or manager-configuration change was performed by the 2026-10-11 verification.
GitHub registration and sign-in were confirmed separately on 2026-10-15.

## Verification commands

```bash
./scripts/test.sh                 # everything: xcodebuild + 3 SPM packages + JS tests
(cd Packages/ExtensionBridgeKit && swift test)
xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS'
node ChromeExtension/tests/<file>.test.js
```

## Address entries and browser autofill (2026-10-11)

- [x] Native Home / Work / Other address entries, encrypted KDBX fields, and Addresses category.
- [x] Explicit browser address selection and form-scoped autofill, with document-bound delivery.
- [x] Regression coverage and the full integrated automated test gate.

Design: [Addresses](../superpowers/specs/2026-10-11-addresses-design.md).
Plan: [Implementation](../superpowers/plans/2026-10-11-addresses.md).

Verification: `./scripts/test.sh` passed 986 Swift cases (963 passed, 23 skipped) and all 25 JavaScript suites; `./scripts/build-all.sh` built MyPass and ChromeHost. Installed-extension ↔ real-vault address autofill remains unverified. Browser checks used the actual helper with a synthetic profile and a popup with mocked bridge responses.

## Contextual passkey hints (2026-10-11)

- [x] Show disabled-passkey guidance only in This site on HTTPS pages whose exact host appears in a bundled five-provider catalog or for which the app reports a matching saved passkey. Hide the hint on unsupported/unknown sites without a saved match and in global/category/search views.

The catalog is local UI guidance and does not change credential matching or WebAuthn authorization. Regression coverage passed in the same 25-suite JavaScript gate.

Design: [Passkey site hints](../superpowers/specs/2026-10-11-passkey-site-hints-design.md).
Plan: [Implementation](../superpowers/plans/2026-10-11-passkey-site-hints.md).
