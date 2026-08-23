# Roadmap open items — implementation plan (2026-08-23)

**Spec:** `docs/implementation/2026-08-23-roadmap-audit-and-feature-proposals.md`, section 1.1 ("Open items the 71/71 total hides") and section 6 ("Housekeeping"). That document is the authority; this plan is its argument.

**Branch:** `roadmap-open-items` (from `e8f1958`). Merge into `master` when the whole-branch review is clean.

## Global constraints

- Project language: English in code, comments, docs, commits. `RUN.md` is Ukrainian and is NOT touched by this plan.
- Every code task is TDD: failing test first, then the implementation, then the suite for the affected package. Commit per task with a conventional message.
- No behaviour change outside the task's stated scope. In particular, the trust model of the Chrome extension (no page-script reachability of fills, `event.isTrusted` on user actions, fail-closed frame policy) must not be weakened.
- Verification commands: `(cd Packages/MyPassKit && swift test)`, `(cd Packages/SyncKit && swift test --filter CitadelDependencySmokeTests)`, `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/ExtensionEntryMatcherTests` (run `./scripts/generate.sh` first if `MyPass.xcodeproj` is missing), `node ChromeExtension/tests/<file>.test.js`. Never judge `./scripts/test.sh | tail` by the pipeline exit code.
- The Gate 6 manual walk (passkeys) cannot be executed by an agent. This plan only corrects how ROADMAP reports it.

## Task 1 — Gate the Citadel smoke test on its fixture

**Files:** `Packages/SyncKit/Tests/SyncKitTests/CitadelDependencySmokeTests.swift`

**Problem:** the suite reads `/tmp/citadel_smoke_key` unconditionally; macOS clears `/tmp`, and because `scripts/test.sh` runs under `set -e` the resulting failure aborts the whole script before `ExtensionBridgeKit` and the JS tests run (ROADMAP "Known trap when running the suite").

**Change:** in `setUpWithError()` (add it if absent) call
```swift
try XCTSkipUnless(
    FileManager.default.fileExists(atPath: Self.privateKeyPath),
    "Citadel smoke fixture missing. Regenerate with: ssh-keygen -t ed25519 -N \"correct-horse-battery-staple\" -f /tmp/citadel_smoke_key -C \"smoketest@mypass\""
)
```
where `privateKeyPath` is the existing path constant (introduce a `static let` if the path is currently inline). Keep every existing test unchanged otherwise.

**Verification:** (1) temporarily move the key away → `swift test --filter CitadelDependencySmokeTests` reports the tests as skipped, exit code 0; (2) restore the key (run the ssh-keygen command above) → tests pass. Record both outputs in the report.

## Task 2 — Public Suffix List in `MyPassKit` and PSL-correct entry matching

**Files:**
- new `Packages/MyPassKit/Sources/MyPassKit/Resources/public_suffix_list.dat` (already placed; the full list from publicsuffix.org, both ICANN and PRIVATE sections, MPL-2.0 — keep its header comment intact)
- `Packages/MyPassKit/Package.swift` — add `resources: [.copy("Resources/public_suffix_list.dat")]` to the `MyPassKit` target
- new `Packages/MyPassKit/Sources/MyPassKit/PublicSuffixList.swift`
- new `Packages/MyPassKit/Tests/MyPassKitTests/PublicSuffixListTests.swift`
- `MyPass/State/ExtensionBridge/ExtensionEntryMatcher.swift`
- `MyPassTests/ExtensionEntryMatcherTests.swift`

**Problem (security):** `ExtensionEntryMatcher.registrableDomain` takes the last two DNS labels, so `accounts.google.co.uk` and `www.amazon.co.uk` both reduce to `co.uk` and `matchingEntries` offers one site's saved credentials on the other. Same for `.com.ua`, `.com.au`, `.co.jp`, `github.io`, `herokuapp.com`, and every other multi-label public suffix. ROADMAP's Decisions row of 2026-08-15 mis-recorded this as an under-match.

**API to add (MyPassKit, public):**
```swift
public enum PublicSuffixList {
    /// Longest matching public suffix for a lowercased DNS host, per the
    /// publicsuffix.org algorithm (exact rules, `*.` wildcards, `!` exceptions,
    /// implicit `*` rule for unknown TLDs). Returns nil for an empty host.
    public static func publicSuffix(of host: String) -> String?
    /// Public suffix plus one label. Returns nil when the host IS a public
    /// suffix (e.g. "co.uk", "github.io") or has a single label.
    public static func registrableDomain(of host: String) -> String?
}
```
Implementation notes: parse the resource once (`static let`, thread-safe by Swift's lazy static init) from `Bundle.module`, skipping blank lines and `//` comments; store exact rules, wildcard rules (without the `*.`), and exception rules (without the `!`) in three `Set<String>`. Algorithm for a host with labels `l1.l2...ln`: for each candidate suffix `li...ln` (all of them), check exception → wildcard (parent `l(i+1)...ln` in the wildcard set) → exact. An exception match wins immediately and its suffix is the exception's parent (drop one label). Otherwise take the longest matching rule; if none matched, the suffix is the last label (implicit `*`). Lowercase the input; strip a single trailing dot. No IDNA conversion — document that Unicode rules match only Unicode-form hosts.

**Matcher change:** in `registrableDomain(from:)`, keep every existing branch (empty, trailing dot, IPv6, single label, IPv4) exactly as is, and replace the final `return labels.suffix(2).joined(separator: ".")` with
```swift
return PublicSuffixList.registrableDomain(of: resolvedHost) ?? resolvedHost
```
— a host that is itself a public suffix is compared whole, consistent with the single-label and IP-literal branches. Rewrite the doc comment at the top of the enum: it no longer describes a naive heuristic; it describes PSL lookup with whole-host comparison for IPs, single labels and bare suffixes.

**Tests — `PublicSuffixListTests`:**
- `example.com` → suffix `com`, registrable `example.com`; `www.example.com` → `example.com`
- `accounts.google.co.uk` → suffix `co.uk`, registrable `google.co.uk`
- `shop.example.com.ua` → `example.com.ua`
- `foo.github.io` → suffix `github.io`, registrable `foo.github.io` (PRIVATE section rule)
- `foo.bar.unknowntld` → `bar.unknowntld` (implicit rule)
- wildcard: `a.b.ck` → suffix `b.ck`, registrable `a.b.ck`; exception: `www.ck` → registrable `www.ck` (`!www.ck` rule)
- `co.uk` → registrable nil; `com` → nil; `""` → nil; `Example.COM.` → `example.com`
- performance guard: 10 000 lookups of `www.example.co.uk` complete in under 1 s (`measure` is fine)

**Tests — `ExtensionEntryMatcherTests` (add, keep existing):**
- `registrableDomain(from: "https://accounts.google.co.uk/signin")` == `google.co.uk`
- entries for `https://www.amazon.co.uk` are NOT returned for `https://accounts.google.co.uk` (the over-match regression test)
- `https://mail.google.co.uk` DOES match an entry for `google.co.uk`
- `foo.github.io` does not match `bar.github.io`
- `co.uk` and `github.io` as bare hosts compare whole (`registrableDomain(from: "https://github.io") == "github.io"`)
- existing IPv4/IPv6/localhost expectations unchanged (run the whole class)

**Verification:** `(cd Packages/MyPassKit && swift test)`; `xcodebuild test ... -only-testing:MyPassTests/ExtensionEntryMatcherTests`. Also run `xcodebuild build -scheme MyPass` once — the SPM resource bundle must link into the app.

## Task 3 — Piece B parked follow-ups in `ChromeExtension/content.js`

**Files:** `ChromeExtension/content.js`, `ChromeExtension/tests/totpDetection.test.js` (or a new `totpBanner.test.js` wired into `scripts/test.sh` — add it to the `JS_TESTS`-style list the script already uses), `ChromeExtension/tests/inlineIcon.test.js` only if its fixtures are reused.

**Background:** ROADMAP Decisions 2026-08-08 "B follow-ups parked" lists five items. This task closes three; the other two are handled by Task 4 and Task 5.

**3a — `event.isTrusted` on banner buttons.** `showTotpSaveBanner` (~line 473) and `showSaveBanner` (~line 583) attach click handlers to their Save and Dismiss buttons. Gate each handler with the existing `isTrustedActivation(event)` (line ~405): an untrusted click does nothing. Tests: with the existing DOM-less harness, drive the button handlers with `{ isTrusted: false }` and `{ isTrusted: true }` events and assert that `sendMessage` (or the dismissal record) fires only for the trusted one. If the banner builders are not exported, export the smallest pure pieces needed (e.g. a `bindBannerButton(button, handler)` helper) rather than the whole DOM builder, in the same style as `routeBannerCredentialsResponse`.

**3b — Per-image QR decode memoization.** `decodeQrFromImage(imgEl)` (~line 324) re-decodes every `<img>` on every mutation sweep. Add a module-level `WeakMap<HTMLImageElement, { key: string, result: string | null }>` where `key = \`${img.currentSrc || img.src}|${img.naturalWidth}x${img.naturalHeight}\``; return the cached result when the key matches, otherwise decode and store. Incomplete images (`!complete || !naturalWidth`) are never cached. Tests: stub `jsQR` as a counting function and a fake image object with stable `src`/`naturalWidth`/`naturalHeight`/`complete` and a canvas stub (follow whatever pattern `totpDetection.test.js` already uses for DOM stand-ins; if `document.createElement` is needed, inject it via the existing test seam or add a minimal one); assert two calls with the same image decode once, and that changing `src` decodes again.

**3c — `img.onload` rescan.** A QR image that finishes loading after the sweep ran is never re-examined. In `observeTotpCandidates(state, onMutation, isTopFrame)` (~line 536), when the QR feature is enabled for this frame, add one capture-phase `load` listener on `document` (`document.addEventListener('load', handler, true)`) that, when `event.target` is an `<img>`, schedules the same debounced sweep the MutationObserver uses. Respect the existing `document.body` guards and the frame policy (`isFeatureEnabledInFrame`). Test: with the harness's observer stub, dispatch a synthetic load event for an img target and assert the sweep callback is invoked; for a non-img target it is not.

**Verification:** `node ChromeExtension/tests/totpDetection.test.js`, `node ChromeExtension/tests/inlineIcon.test.js`, `node ChromeExtension/tests/scriptScopes.test.js` (the last one guards top-level `const` collisions — a new module-level name must not clash with `popup.js`/`entry-visuals.js`). Manually load the unpacked extension is out of scope for the agent; say so in the report.

## Task 4 — `isReplacingTotp` recompute when the OTP field is cleared

**Files:** `MyPass/UI/EntryDetail/EntryEditView.swift` (state `isReplacingTotp`, lines ~26, 57, 139, 236, 252), `MyPass/UI/EntryDetail/EntryEditSaveLogic.swift` (`requiresReplaceConfirmation`), `MyPassTests/EntryEditSaveLogicTests.swift` (create if absent, matching the neighbouring test file style).

**Required behaviour (from ROADMAP Decisions 2026-08-08 and the `applyOTP` empty-input semantics):** the "Replace 2FA?" confirmation on Save must fire iff the entry already has a TOTP secret AND the OTP field's current value is non-empty AND differs from the stored secret. Clearing the field (empty) means "keep the existing secret" and must NOT prompt; re-typing the identical secret must NOT prompt; an explicit Remove goes through `removeExistingTotp` and is unaffected.

**Change:** make `isReplacingTotp` a derived value computed from `(existingSecret, currentOtpInput)` at Save time (or via `onChange` of the OTP binding) instead of a one-shot `State(initialValue:)` that is only reset to `false` at the two sites. Put the decision in `EntryEditSaveLogic.requiresReplaceConfirmation(existing:proposed:)` (extend its signature if needed) so it is unit-testable. Keep the proposal-prefill precedence (a TOTP proposal from the extension pre-fills the field and must still prompt when an existing secret differs).

**Tests:** existing secret + empty input → false; existing + identical → false; existing + different → true; no existing + anything → false; proposal prefill over existing different secret → true.

**Verification:** `xcodebuild test ... -only-testing:MyPassTests/EntryEditSaveLogicTests` plus a full `xcodebuild test` of the MyPass scheme.

## Task 5 — Documentation reconciliation

**Files:** `docs/implementation/ROADMAP.md`, `docs/implementation/2026-08-23-roadmap-audit-and-feature-proposals.md`

**ROADMAP.md edits:**
1. `Last updated:` → `2026-08-23`.
2. Progress table: keep the Stage 6 row text; change the Total row to `| **Total** | **71** | **71 code-complete — Gate 6 manual walk still open** |` so the summary no longer contradicts the Stage 6 row.
3. Decisions table — add rows dated 2026-08-23:
   - `.co.uk` correction: the 2026-08-15 row called the multi-label suffix limitation an under-match; it was an OVER-match (`google.co.uk` and `amazon.co.uk` both reduced to `co.uk`, offering one site's credentials on the other). Fixed by `PublicSuffixList` in MyPassKit (full publicsuffix.org list incl. PRIVATE section); bare suffixes, single labels and IP literals compare whole.
   - Citadel smoke test now skips itself when `/tmp/citadel_smoke_key` is absent, with the regeneration command in the skip message; "Known trap" below is historical.
   - Piece B follow-ups closed: banner buttons require `event.isTrusted`; per-image QR decode memoized; `img` load events re-trigger the sweep; `isReplacingTotp` derived from current input. "Picker panel polish" dropped — no concrete defect was ever recorded for it. Lowercase manual setup keys remain deferred (original ruling stands).
   - `SecuritySettingsPane.swift:251` diagnostic detail kept deliberately until the real-device Keychain failure is root-caused.
4. "Known trap when running the suite": prefix the section with `**Fixed 2026-08-23** — the suite now skips itself when the fixture is missing; the text below is kept for history.` and leave the rest.

**Audit doc edits (section 1.1 table):** update the State column of the `.co.uk`, Citadel, Piece B, and `SecuritySettingsPane` rows to "Fixed on branch `roadmap-open-items` (2026-08-23)" / "Kept deliberately — see ROADMAP Decisions"; Gate 6 row: state unchanged, add "ROADMAP total row reworded". Section 6 bullets: mark done items with `(done 2026-08-23)`.

**Verification:** `grep -n 'Gate 6' docs/implementation/ROADMAP.md` shows the reworded total; markdown tables still render (pipe counts consistent).
