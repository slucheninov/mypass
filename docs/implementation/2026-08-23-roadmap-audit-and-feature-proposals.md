# Roadmap audit and feature proposals — 2026-08-23

This document does three things: (1) audits [`ROADMAP.md`](./ROADMAP.md) against the
current code, (2) inventories what MyPass actually does today, and (3) proposes next
features and design work, benchmarked against 1Password, Enpass and Proton Pass, filtered
down to what is realistic given MyPass's architecture — a local-first macOS app over a
KDBX4 vault, no server, no account, with a Chrome extension talking to the app over native
messaging.

---

## 1. ROADMAP audit — verdict

Summary: all 71 checkbox items across Stages 0–8 are ticked, and were spot-checked
against code. Six spot-checks confirmed:

- `KPEX_PASSKEY_CREATED` exists in `MyPass/Models/KdbxEntry+Passkey.swift`.
- `FRAME_FEATURE_POLICY` exists at `ChromeExtension/content.js:32`.
- `isAnswerableWhileLocked` exists in
  `Packages/ExtensionBridgeKit/Sources/ExtensionBridgeKit/ExtensionBridgeMessages.swift:216`.
- `emptyRecycleBin` exists in `MyPass/UI/Sidebar/GroupTreeOperations.swift:209`, backed by
  `KdbxDeletedObject`.
- `ChromeExtension/tests/scriptScopes.test.js` exists and covers the claimed scope.
- `minimum_chrome_version: "127"` is set in `ChromeExtension/manifest.json:14`.

All 18 commits since 2026-08-15 are reflected in Stage 8. No `TODO`/`FIXME` markers exist
anywhere in Swift or JS sources.

### 1.1 Open items the "71/71" total hides

| Item | Where | State |
|------|-------|-------|
| Gate 6 manual walk (passkeys, Piece C) | `ROADMAP.md:424-427` says "Gate 6 stays open until the manual half is walked against a real Chrome 127+"; the progress row at `:557` says "code complete, Gate 6 manual walk open"; `RUN.md:133-148`'s passkey checklist is entirely `[ ]` while the neighbouring Stage 5/7/8 walks are `[x]`; no "close Gate 6" commit exists (compare `998b44a` "close Gate 7") | **Open.** The total row at `:560` counts Stage 6 as done, which contradicts the surrounding text. Recommendation: either walk it and close it, or restate the total as 62/71 + "Gate 6 open" so the summary stops disagreeing with its own table. ROADMAP total row reworded. |
| `.co.uk`-style multi-label suffixes in `ExtensionEntryMatcher.registrableDomain` (`MyPass/State/ExtensionBridge/ExtensionEntryMatcher.swift:5-9, 66`) | The 2026-08-15 Decisions table records this as "under-match, which is the safe direction" | **Mis-classified — this is an OVER-match and a security issue, not a safe under-match.** `labels.suffix(2)` reduces `accounts.google.co.uk` and `www.amazon.co.uk` to the same registrable domain, `co.uk`, so `matchingEntries` will offer one site's saved credentials on the other. The same collapse happens for `.com.ua`, `.com.au`, `.co.jp`, `.github.io`, `.herokuapp.com`, and any other multi-label public suffix. Fix: bundle the Public Suffix List (or a trimmed copy) and compute suffix + 1 label instead of a fixed last-two-labels heuristic. See proposal P1. Fixed on branch `roadmap-open-items` (2026-08-23). |
| Citadel smoke test env gate | `Packages/SyncKit/Tests/SyncKitTests/CitadelDependencySmokeTests.swift` reads `/tmp/citadel_smoke_key` with no environment gate, and is documented as a "known trap" | Fixed on branch `roadmap-open-items` (2026-08-23). |
| Piece B parked follow-ups (Decisions, 2026-08-08) | Per-image QR decode memoization, `isReplacingTotp` recompute on a cleared field, picker panel polish, and `img.onload` rescan — none of these appear in `content.js` or `popup.js`. `event.isTrusted` was added for the inline fill icon (`content.js:405`) but not for the TOTP banner buttons. | Fixed on branch `roadmap-open-items` (2026-08-23). |
| Lowercase manual TOTP keys in `detectManualSetupKey` (`content.js:296`) | Deferred at the time | Still open. |
| `SecuritySettingsPane.swift:251` "TEMPORARY diagnostic detail" | Code comment; the raw Swift error is surfaced to the user in the enable-device-unlock alert | Kept deliberately — see ROADMAP Decisions. |
| Uncommitted `RUN.md` diff in the working tree | Formatting-only pass (114+/116−): strips the `- ` list markers from checkboxes and wraps markdown links in backticks, which turns working links into inert code spans | Recommend reverting rather than committing — it degrades the file without changing its content. |

---

## 2. What MyPass is today (inventory)

Organized by area. Absences are called out explicitly, since they drive section 3.

### 2.1 Platform and architecture

- macOS 14+ only. `project.yml` declares the `MyPass` app target and the `ChromeHost`
  helper tool. `Packages/MyPassKit/Package.swift` also declares an iOS 17 platform, so the
  core model/format layer is portable in principle, but no iOS target exists yet.
- Own KDBX4 implementation lives in `Packages/MyPassKit/Sources/MyPassKit/Format/`:
  AES-256-CBC, ChaCha20, HMAC block stream, Argon2id and AES-KDF via swift-sodium.
  KeePassKit was evaluated and rejected — see
  `docs/superpowers/spikes/2026-07-21-keepasskit-vs-custom-parser.md`. KDBX3 and the
  legacy `.kdb` format are not supported.
- No server and no account. "Sync" means user-owned storage locations, not a MyPass
  cloud service.
- Extension-to-app bridge: a Chrome native messaging host (`ChromeHost/`) relays to an
  in-app `LoopbackServer` (`MyPass/State/ExtensionBridge/`), using secret-token pairing.
  Chrome only, Manifest V3, `minimum_chrome_version` 127. The extension ships with a fixed
  `key` in its manifest — a self-distributed ID, not a Chrome Web Store listing.
- Packages: `MyPassKit` (format, models, generator, TOTP), `SyncKit` (Local / iCloud
  Drive / SFTP backends, a three-way `MergeEngine`, `SyncEngine`, checkpoints),
  `ExtensionBridgeKit` (wire protocol, token store).

### 2.2 Vault and storage

| Capability | Status | Evidence |
|---|---|---|
| Local file vault | Present | Core vault storage path |
| iCloud Drive sync | Present | `SyncKit` iCloud Drive backend |
| SFTP sync | Present | Citadel-based client, TOFU host key |
| Three-way merge | Present | UUID-keyed merge, including deletion tombstones (`MergeEngine`) |
| Recycle bin | Present | `KdbxDeletedObject`, `emptyRecycleBin` |
| Entry history | Present | `KdbxEntry.history`, `HistoryView` |
| Local backup rotation | Present | Keep last N (1–50), configurable |
| Vault move / open existing `.kdbx` | Present | Vault Location settings, `OpenExistingVaultSheet` |
| Key file in composite key | **Absent** | `KdbxDatabase.compositeKey(fromPassword:)` only takes a password |
| YubiKey / challenge-response | **Absent** | No HID or challenge-response code |
| Multiple vaults | **Absent** | Single active vault only |
| WebDAV / Dropbox / Google Drive sync | **Absent** | Only Local / iCloud Drive / SFTP |
| Attachments UI | **Absent** | Binary pool is parsed at the format level; no UI in `MyPass/UI/` surfaces it |
| Opening KeePassXC-created files with a 32-byte Argon2id salt | **Absent / broken** | Explicit error text in `MyPass/UI/Settings/OpenExistingVaultSheet.swift:69` |

### 2.3 Entries

| Capability | Status | Evidence |
|---|---|---|
| Login / Card / Notes templates | Present | `MyPass/Models/EntryType.swift`; Card uses `MyPass.CardNumber/CardholderName/ExpiryDate/CVV`; Notes uses a Markdown `MyPass.NotesBody` |
| Custom fields | Present | Free-form key/value fields |
| TOTP | Present | `otp` field, countdown ring |
| Passkeys | Present | `KPEX_PASSKEY_*` fields, KeePassXC-compatible |
| Multiple URLs per entry | Present | `KP2A_URL` StringArray, `WebsitesSheet` |
| Favorites | Present | Custom `Favorite` field |
| Group tree with counts | Present | Sidebar group tree |
| Smart categories (All / Favorites / Codes / Cards / Notes / Security / Deleted) | Present | `EntryCategoryFilter.swift` |
| Tags | **Absent** | No `<Tags>` handling found in `KdbxXmlCoder.swift` — also an open question whether tags set in KeePassXC round-trip through a MyPass save without being dropped |
| Entry expiry | **Absent** | No `Expires`/`ExpiryTime` handling |
| Custom icons / favicons | **Absent** | Every new entry is `iconID: 0`; letter avatars only |
| `.security` smart category | **Stub** | `EntryCategoryFilter.swift` currently returns all entries for this category |

### 2.4 Security UX

| Capability | Status | Evidence |
|---|---|---|
| Master password unlock | Present | Core unlock flow |
| Touch ID / Mac password | Present | `BiometricKeyStore`, Keychain ACL, configurable windows |
| Auto-lock idle timeout, lock on sleep | Present | Security settings |
| Clipboard auto-clear | Present | Default 30s |
| Large Type popover | Present | Password display aid |
| Global hotkeys (show / lock) | Present | App-wide shortcuts |
| Password strength meter | **Absent** | No entropy/zxcvbn-style code anywhere |
| Generator beyond length + 4 toggles | **Absent** | `Packages/MyPassKit/.../PasswordGenerator.swift` has no passphrase mode, no exclude-ambiguous, no per-site rules |
| Breach check (HIBP) | **Absent** | No network-based check code |
| Weak / reused / old password detection | **Absent** | No audit logic |
| Screenshot protection | **Absent** | Not implemented |

### 2.5 Search, organization, surfaces

| Capability | Status | Evidence |
|---|---|---|
| Substring search over title/login/url/notes | Present | `EntrySearch.swift` |
| Menu bar extra (recent entries, unlock panel) | Present | Menu bar UI |
| Global hotkey | Present | Raises main window |
| Sorting control | **Absent** | Fixed order |
| Search operators / fuzzy search | **Absent** | Substring only |
| Spotlight integration | **Absent** | Not implemented |
| Quick Access-style floating palette | **Absent** | Hotkey only raises the main window, no dedicated palette |
| List density options | **Absent** | Single fixed layout |
| AppleScript / Shortcuts / App Intents / CLI | **Absent** | No automation surface |
| SSH agent | **Absent** | Not implemented |

### 2.6 Import / export

| Capability | Status | Evidence |
|---|---|---|
| CSV import | Present | Requires title/username/password; url/notes optional; failures are silent per the code comment in `EntryListView.swift` |
| Open existing `.kdbx` as primary vault | Present | `OpenExistingVaultSheet` |
| Export (any format) | **Absent** | No export path exists |
| Import from 1Password / Bitwarden / Enpass / LastPass / browser CSV / KeePassXC merge | **Absent** | Not implemented |

### 2.7 Chrome extension

Present: credential fill from the popup; inline fill icon in fields (closed shadow root,
iframe support, dark theme aware); TOTP fill with a privacy circle; TOTP setup from QR /
`otpauth://` / manual key; passkeys (create, get, replace, picker UI, via
`webAuthenticationProxy`); save-login proposal on form submit; unlock-from-popup; device
pairing; app-not-running fallback; recycle-bin exclusion from matching; IP-literal host
matching.

Absent: popup dark mode (light-only, all CSS inline in `popup.html`); password generator
in the popup or on new-password fields; a distinct "update password" flow (only
`proposeSaveLogin` exists, which always proposes a new/replacement save rather than an
explicit update); user-configurable match rules (exact / host / subdomain); Firefox or
Safari support; localization (`_locales/` does not exist).

### 2.8 Localization and accessibility

- English-only: no `.xcstrings` catalog, no `NSLocalizedString`/`String(localized:)` calls,
  no `_locales/` directory. A design spec exists at
  `docs/superpowers/specs/2026-07-26-mypass-phase7-localization-design.md` (en/uk/de) but
  is unimplemented.
- Accessibility: 12 `accessibilityLabel` usages, 7 `accessibilityHint`, and a single
  `accessibilityIdentifier` (`NotesEditView.swift:97`). Fonts are hard-coded
  `.system(size:)` literals, so Dynamic Type is not supported.

### 2.9 Tests

`scripts/test.sh` runs: xcodebuild for the `MyPass` scheme, `swift test` for the three
packages (`MyPassKit`, `SyncKit`, `ExtensionBridgeKit`), and 14 Node test files under
`ChromeExtension/tests/`. Roughly 134 tests in MyPassKit, 86 in SyncKit, and 49 test files
in MyPassTests.

---

## 3. Feature proposals

Benchmarked against 1Password, Enpass and Proton Pass. Each proposal states what the
competitor does, what MyPass has today, the shape that's realistic for MyPass's
architecture, and a rough size (S / M / L / XL). Ordered roughly by value-to-effort.
Things that would require a server are deliberately excluded here — see section 5.

### P1 — Public Suffix List in entry matching (security fix) — S

**Benchmark:** every competitor does PSL-correct domain matching; Bitwarden and 1Password
additionally offer per-item match modes.
**Today:** `registrableDomain` in `ExtensionEntryMatcher.swift` takes the last two labels
of the host, which over-matches for any multi-label public suffix (`.co.uk`, `.com.ua`,
`.github.io`, `.herokuapp.com`, …), offering saved credentials from one site on an
unrelated site under the same suffix.
**Proposal:** bundle a trimmed Public Suffix List (ICANN section only) as a resource in
`MyPassKit` or the app; compute the registrable domain as public-suffix-plus-one-label;
keep the existing IP-literal branches unchanged; add unit tests for `.co.uk`, `.com.ua`,
`.github.io`. Follow-up: a per-entry match mode (base domain / host / exact URL) stored as
a `MyPass.MatchMode` custom field.
**Size:** S.
**Notes / risks:** the PSL needs periodic refresh. Fail closed: for an unrecognized
multi-label suffix, treat matching as host-exact rather than falling back to the current
two-label behavior.

### P2 — Security audit ("Watchtower" / Proton Pass Monitor / Enpass Audit) — M

**Benchmark:** weak, reused, old, compromised, missing 2FA, expiring credentials.
**Today:** the `.security` smart category is a stub, and there is no strength-estimation
code at all.
**Proposal:** two stages. Stage 1 (offline, no network): strength estimate (entropy plus a
bundled top-10k common-password list; a full zxcvbn port is optional), reuse detection
across entries, age (from `lastModificationTime`/history), "2FA available but not
enabled" using a bundled 2fa.directory dataset matched by registrable domain, and entry
expiry (see P4). Wire the real `.security` category to surface flagged entries with badges
in `EntryListRow`, plus a per-entry warning row in `DetailFieldsCard`. Stage 2 (opt-in,
network): HIBP range API using k-anonymity (only the first 5 SHA-1 hex characters leave
the device), gated behind an explicit toggle in Security settings, off by default.
**Size:** M.
**Notes / risks:** don't run the audit on the main thread for large vaults; cache results
keyed to the last save.

### P3 — Password generator parity + generator in the browser — M

**Benchmark:** 1Password/Proton Pass offer random, memorable/passphrase, and PIN modes,
separators, capitalization, ambiguous-character exclusion, and live strength; the
generator is also available inline in the extension on sign-up forms.
**Today:** the generator has 4 toggles and length only, and is app-only.
**Proposal:** add a passphrase mode (bundled EFF large wordlist), an exclude-ambiguous
toggle, a PIN mode, and a live strength readout; persist last-used settings. In the
extension, detect `autocomplete="new-password"` and sign-up-shaped forms in `content.js`,
and route a "Suggest password" panel state through the existing `chooseInlinePanel`
mechanism, generating via a new `generatePassword` bridge request so policy stays
single-sourced in the app (the alternative — generating client-side with
`crypto.getRandomValues` — is simpler but duplicates policy logic). On submit, the
existing `proposeSaveLogin` flow captures the generated value as usual.
**Size:** M.

### P4 — Native KDBX features the format already has: tags, expiry, attachments, custom icons — M

**Benchmark:** all three competitors support tags/labels, expiry reminders, and
attachments.
**Today:** absent, even though KDBX4 already carries `<Tags>`, `<Expires>`/`<ExpiryTime>`,
binaries, and `<CustomIcons>` at the format level.
**Proposal:**
(a) Tags — parse and write `<Tags>`, tag chips in the edit view, a tag filter in the
sidebar, and a `tag:` search operator; first verify KeePassXC-set tags round-trip through
a MyPass save without being dropped.
(b) Expiry — a date picker in the edit view, and an "Expiring" smart category feeding P2.
(c) Attachments — a list/add/Quick Look UI in the detail view, with a size-cap warning.
(d) Icons — a KeePass built-in 69-icon picker or custom icon upload; favicon fetching only
as an explicit opt-in, since each fetch reveals the site to whoever serves the favicon
(KeePassXC does direct opt-in fetch, Proton proxies the request instead).
**Size:** M overall; each sub-item is roughly S on its own.

### P5 — Import / export — M

**Benchmark:** 1Password imports 1PUX/CSV/LastPass/Bitwarden and more; Enpass imports 20+
formats; Proton Pass imports 1PUX, Bitwarden JSON, KeePass, and Chrome CSV.
**Today:** CSV import only, and no export path at all.
**Proposal:**
(a) Export — CSV (with an explicit plaintext-data warning) and "Save a copy of the vault
as .kdbx" (trivial, since the writer already produces an encrypted file).
(b) Import — KeePassXC `.kdbx` merged into the current vault through the existing
`MergeEngine` (highest value, since it's the same underlying format), Bitwarden JSON,
1Password 1PUX (zip + JSON, mapping categories onto Login/Card/Notes plus custom fields),
and common Chrome/Safari CSV header variants.
(c) Fix the 32-byte Argon2id salt limitation in `OpenExistingVaultSheet` — a real
interoperability gap against KeePassXC-created files.
(d) Surface CSV import failures with an alert instead of a silent no-op.
**Size:** M.

### P6 — macOS Credential Provider extension (system AutoFill + Safari) — L

**Benchmark:** 1Password, Enpass and Proton Pass all register an
`ASCredentialProviderExtension` on macOS 14, giving AutoFill in Safari and in any app or
browser that uses the system credential picker.
**Today:** absent; Safari support was previously planned as a "Phase 4b" Safari Web
Extension instead.
**Proposal:** add an `ASCredentialProviderExtension` target sharing the vault via an app
group, offering password AutoFill and (macOS 14+) passkey registration/assertion reusing
the existing `PasskeyCeremony` code. This is a cheaper route to Safari support than a
second web-extension port.
**Size:** L.
**Notes / risks:** the extension must unlock the vault independently (Keychain-backed key,
Touch ID), keep its memory footprint small, and must not load the whole app.

### P7 — Quick Access palette — M

**Benchmark:** 1Password's Quick Access (⌘⇧Space), Enpass Assistant.
**Today:** the global hotkey only raises the main window; the menu bar extra shows recent
entries.
**Proposal:** a floating, non-activating `NSPanel` search window that appears on hotkey,
suggests entries matching the frontmost app's window title or frontmost browser URL (via
Accessibility APIs where available, otherwise falling back to recent entries), with
copy-username/password/TOTP actions and an opt-in Return-to-fill-into-frontmost-field via
`CGEvent` typing. Reuses `EntrySearch`, `LetterAvatar`, and `RecentEntriesQuery`.
**Size:** M.

### P8 — More entry templates — S

**Benchmark:** Enpass has 40+ templates, 1Password roughly 20, Proton Pass has
Login/Alias/Card/Note/Identity.
**Today:** 3 templates (Login, Card, Notes).
**Proposal:** all expressible via the existing `MyPass.*` custom-field mechanism on top of
`EntryType`: Identity (name, address, phone, email, date of birth), Wi-Fi (SSID, password,
security type — with a QR code for the password, as in Enpass), SSH Key (private key,
protected; public key; fingerprint — a prerequisite for a later SSH agent), API
credential/Token (key, secret, expiry), Bank account (IBAN, SWIFT), Software licence.
Keep Login as the default template, and map each new template's fields to extension fill
where relevant (Identity to address forms could come later).
**Size:** S–M.

### P9 — Chrome extension follow-ups — S each

- Popup dark mode: the inline panel already supports it; the popup is explicitly
  light-only per the popup-list-redesign spec. Move the inline CSS to `popup.css` and
  share color tokens with the inline panel's constants.
- Update-password flow: detect change-password forms (current + new password fields) and
  propose "Update password for &lt;entry&gt;" instead of always proposing a new entry; the
  app side would update the existing entry and record the old value in history.
- Per-entry "never autofill here" / match mode (ties into P1).
- Entry-type icons (card/notes) in the popup list — currently out of scope per the
  redesign spec.
- Firefox port: WebExtensions APIs and native messaging are near-identical to Chrome;
  passkeys would stay Chrome-only, since `webAuthenticationProxy` has no Firefox
  equivalent. Size M for the Firefox port itself.

### P10 — Localization (spec already written) — M

Implement `docs/superpowers/specs/2026-07-26-mypass-phase7-localization-design.md`: a
String Catalog for en/uk/de in the app, and `_locales/` for the extension. Ship en + uk
first; de only if there's a maintainer for it.

### P11 — Key file and hardware keys — S / L

**Benchmark:** not a 1Password/Proton Pass feature, but table stakes in the KeePass
ecosystem (KeePassXC, Strongbox).
**Proposal:** key file support in the composite key is S — SHA-256 of the file's bytes (or
a KeePass XML key file v2), concatenated before the Argon2 derivation, with UI in both the
unlock screen and Security settings. YubiKey challenge-response (KeePassXC's
`KeeChallenge`-compatible scheme) is L — needs HID access and a hardened flow; list as a
stretch goal.

### P12 — Sorting, density, search operators — S

Sort by title / last modified / created; Comfortable/Compact density (this was already in
the earlier Wave-1 backlog); `user:`, `url:`, `tag:` operators added to `EntrySearch`.

### P13 — SSH agent — L (stretch)

**Benchmark:** 1Password's SSH agent.
Requires the P8 SSH Key template. Would implement the SSH agent protocol on a Unix socket,
with per-use Touch ID approval. `SyncKit` already links swift-nio-ssh, but only as an SFTP
client — the agent protocol itself is small, but key parsing and signing (ed25519/RSA)
need care. Stretch goal.

### P14 — iOS app (Phase 5) — XL

`MyPassKit` already targets iOS 17. The app shell, an AutoFill extension, and iCloud Drive
sync would all reuse `SyncKit`. Listed here for completeness only — this is a separate
programme, not a single feature.

### Priority table

| Proposal | Value | Size | Depends on |
|---|---|---|---|
| P1 — PSL matching fix | High (security) | S | — |
| P2 stage 1 — offline audit | High | M | — |
| P3 — generator parity | High | M | — |
| P5 (a, c, d) — export, salt fix, import error surfacing | High | M | — |
| P4 — tags, expiry | Medium-High | M | — |
| P9 — popup dark mode, update-password flow | Medium | S | — |
| P7 — Quick Access palette | Medium | M | — |
| P6 — Credential Provider extension | Medium-High | L | — |
| P8 — more templates | Medium | S–M | — |
| P2 stage 2 — HIBP | Medium | S (adds to P2) | P2 stage 1 |
| P10 — localization | Medium | M | — |
| P11 — key file / YubiKey | Low-Medium | S / L | — |
| P12 — sort/density/operators | Low-Medium | S | — |
| P13 — SSH agent | Low (niche) | L | P8 |
| P14 — iOS app | Strategic, not incremental | XL | — |

Recommended order: P1 (fix now, it's a security bug) → P2 stage 1 → P3 → P5 (a, c, d) →
P4 (tags, expiry) → P9 (dark mode, update flow) → P7 → P6 → the rest as capacity allows.

---

## 4. Design proposals

Benchmarks: Apple Passwords (the current visual target per the UI-shell spec), 1Password 8
(dense list, item icons, Watchtower banners, Quick Access), Proton Pass (card-style item
pages, vault color/icon, clean empty states), Enpass (category sidebar, audit dashboard).

**D1 — First-run onboarding.** Today: first run is an inline flag in `UnlockView`
(`isFirstRun`), with "Open Existing .kdbx…" as a link; the iCloud location is only
reachable from Settings after a vault already exists. Proposal: a 3-step sheet (Create new
/ Open existing / Use a vault from iCloud Drive → choose location → master password with
live strength and confirmation), ending with a "Pair Chrome" step that reuses
`PairingCodeSheet`. Affected: `MyPass/UI/Unlock/UnlockView.swift`,
`VaultLocationChangeSheet.swift`.

**D2 — Security in the list and detail.** Today: no badges anywhere. Proposal (paired with
P2): small colored badges on `EntryListRow` for weak/reused/breached/expiring, a warning
banner at the top of `DetailFieldsCard` with a one-click "Generate new password" action,
and the `.security` category becoming a dashboard header (issue counts) above a filtered
list, following the Enpass Audit / Watchtower pattern. Affected: `EntryListView.swift`,
`EntryDetailView.swift`, `SmartCategory.swift`.

**D3 — Entry identity: icons and tags.** Today: letter avatars only, no tags. Proposal: an
icon picker (KeePass built-in set plus custom upload; favicon fetching opt-in only) in the
edit-view hero; tag chips under the title in the detail view and in the list subtitle
(`title · username · #tag`); a tag section in the sidebar. Keep `LetterAvatar` as the
fallback, and keep the Swift and JS color-hash logic in sync
(`ChromeExtension/shared/entry-visuals.js`).

**D4 — List controls.** Today: no sort, fixed density, no grouping. Proposal: a toolbar
sort menu, a density toggle (Comfortable/Compact, from the Wave-1 backlog), an optional
"Recently modified" grouping, and keyboard-first shortcuts (⌘F focuses search, ⌘C copies
the selected row's password, ⌘⇧C copies username, ⌘⌥C copies TOTP — following 1Password's
conventions).

**D5 — Quick Access palette (P7's UI).** A floating roughly 560×360 panel with a single
search field, rows matching `EntryListRow`, and right-aligned action hints (⏎ fill, ⌘C
copy password, …). Appears centered on the active display; dismisses on blur.

**D6 — Settings navigation.** Today: an icon-sidebar `NavigationSplitView`
(`SettingsView.swift`), which diverges from the Wave-1 spec's "single scrolling pane."
Proposal: keep the sidebar — six panes is already past the point where a single pane is
practical — but record that decision explicitly in the spec; add a "Language" pane once
P10 lands, and move Backups under Vault Location.

**D7 — Error surfaces.** Today: CSV import failure is silent, opening an existing vault
that fails just beeps (`NSSound.beep()` in `EntryListView.swift` and `UnlockView.swift`),
and the device-unlock error alert shows the raw Swift error
(`SecuritySettingsPane.swift:251`). Proposal: one consistent alert style with a plain
sentence and a "Show details" disclosure; treat this as a polish pass across the app.

**D8 — Chrome popup.** Today: light-only, all CSS inline, no entry-type icons; the inline
panel is already dark-aware. Proposal: a `popup.css` with shared tokens (`--bg`, `--fg`,
`--hairline #d2d2d7`, `--hover #f5f5f7`, `--accent #007aff`) and the dark variants already
used in `content.js` (`#1e1e20`, `#3a3a3c`, `#2c2c2e`); card/notes tiles matching
`templateIconTile`; a generator panel (P3); an "Update password?" proposal panel (P9).
Known limitation to design around: the inline panel is clipped in narrow iframes
(`RUN.md:186`) — consider flipping the panel, or rendering it from the top frame via a
postMessage hop.

**D9 — Accessibility and type.** Add `accessibilityIdentifier`s for UI tests (currently
just one); replace `.system(size:)` literals with `Font` text styles so Dynamic Type
works; add VoiceOver labels to the TOTP ring ("Verification code, 23 seconds remaining").

**D10 — Browse/edit inline merge (Apple Passwords style).** The password-detail-form spec
already left this as a "future consideration." Recommendation: do NOT do this yet — the
separate edit mode is what keeps destructive actions (Remove 2FA, Remove passkey, Delete)
consolidated in one place. Revisit after P4 lands.

---

## 5. Deliberately not proposed

Each of these needs a server/account MyPass does not have, or contradicts the local-first
model:

- Item/vault sharing and family/team vaults.
- Emergency access / account recovery.
- Proton Pass-style email aliases (hide-my-email).
- Travel Mode.
- Secret Key / SRP-style account authentication.
- Cloud-hosted sync run by MyPass itself.
- Cross-device passkey sync other than through the vault file itself.
- "Autofill and submit" automatically without a user gesture — the inline icon design
  requires `event.isTrusted` for a reason; keep it that way.

---

## 6. Housekeeping before new features

- Close or explicitly re-state Gate 6 (passkey manual walk) in `ROADMAP.md`. (done 2026-08-23)
- Fix `.co.uk`-style domain matching (P1) — bump it to the front of the queue; it's a
  security bug, not a feature gap. (done 2026-08-23)
- Gate the Citadel smoke test on an environment variable, or make it self-provision its
  key file. (done 2026-08-23)
- Revert the formatting-only `RUN.md` diff currently in the working tree.
- Clear the `SecuritySettingsPane.swift:251` "TEMPORARY diagnostic detail" comment and its
  raw-error alert.
- Decide the parked Piece-B follow-ups (QR memoization, `isReplacingTotp` recompute,
  picker panel polish, `img.onload` rescan) — either do them or drop them with a Decisions
  row explaining why. (done 2026-08-23)

---

## How to use this document

Everything in section 3 and 4 is an input for `superpowers:brainstorming`, to be turned
into a spec and then a plan per the project's existing workflow. Nothing in this document
is scheduled.
