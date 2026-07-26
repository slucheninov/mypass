# MyPass — Password Manager: Design

Date: 2026-07-21
Status: approved

## Goal and Context

Personal password manager for macOS (MVP), then iOS/iPadOS. Autofill via
Chrome and Safari extensions. Database sync via iCloud Drive, a local
folder, or SFTP. App Store publication is not planned — installation via Xcode.

## Key Decisions

| Decision | Choice |
|---|---|
| Stack | Swift + SwiftUI, single codebase for macOS/iOS |
| Database format | KeePass KDBX4 (Argon2id; compatible with KeePassXC/Strongbox) |
| Architecture | Single app as the center; extensions as thin clients (option A) |
| MVP | macOS app + 3 sync backends + Chrome/Safari extensions + TOTP |
| Passkeys | Separate phase after iOS; storage format (KeePassXC convention) laid out from the start |
| Localization | String Catalog (`Localizable.xcstrings`) + Chrome `_locales`; source locale English (Phase 7) |
| SSH authentication | Keys and OpenSSH certificates (`*-cert.pub`) |

## Architecture and Components

```
mypass/
├── Packages/
│   ├── MyPassKit/        # Core: kdbx4, crypto, model, TOTP, password generator
│   └── SyncKit/          # StorageBackend protocol + 3 implementations + merge
├── MyPass/               # macOS app (SwiftUI): window + menu bar
├── SafariExtension/      # Safari Web Extension (bundled in the app)
├── ChromeHost/           # Native Messaging host for Chrome
└── WebExtension/         # Shared JS code for extensions (Chrome and Safari)
```

- **MyPassKit** — the only place with decrypted data. Read/write
  KDBX4, Group/Entry model, TOTP (RFC 6238), password generator. No
  dependencies on UI or network. kdbx library: first candidate — KeePassKit
  (ObjC); if KDBX4 support is unsatisfactory — custom parser
  (CryptoKit + C Argon2 library). Decision is fixed at the start of phase 1.
- **SyncKit** — `StorageBackend` protocol (read / write / modificationDate /
  exists) and implementations: local folder, iCloud Drive, SFTP. Shared merge engine.
- **App** — owns the unlocked database, UI, responds to extensions via IPC.
- **Extensions** — detect forms, request `getCredentials(url)`,
  fill. No database or keys. Safari → native handler; Chrome →
  Native Messaging host → XPC → app.

Autofill flow: content script finds form → request by URL → app
returns domain matches → user selects → fill.

## Security Model

- Master password → Argon2id → database key. Decrypted data only in the
  app process memory.
- **Touch ID:** derived key (not master password) in Keychain with
  `kSecAccessControlBiometryCurrentSet`; invalidated when fingerprints change;
  master password required after reboot.
- **Auto-lock:** inactivity timeout (default 15 min), sleep,
  manual command; optionally — on screen lock. Keys are wiped.
- **Extensions:** receive only entries matching the active tab URL,
  on explicit request. Domain matching is done by the app. XPC accepts
  connections only from processes with the expected code signature. Chrome host
  is bound by manifest to the extension ID. Database locked → "locked" status,
  unlock only in the app.
- **Fill:** only on user action; verify page origin against entry URL;
  no autofill on page load.
- **Database file:** atomic write (temp → rename); before each overwrite —
  backup (rotation, default 10).

## Sync

The app works with a **local working copy** (Application Support);
the backend is the remote source of truth. Full offline for all modes.

Cycle (on open, after save, on timer, manually):
1. Download remote file if changed.
2. Unchanged → upload own copy.
3. Changed → merge at entry level → upload result.
4. Upload is atomic (for SFTP: upload to temp name → rename on server).

**Merge** (KeePassXC Synchronize semantics):
- Match by entry/group UUID.
- Concurrent edits → newer `lastModificationTime` wins,
  losing version saved in entry History.
- Deletions via `DeletedObjects`: deletion vs edit — by event time.
- Moves — by `locationChanged`.
- No version-choice dialogs; conflicts resolved automatically and reversibly.

**Backends:**
- *iCloud Drive:* NSFileCoordinator + NSFilePresenter; conflict versions
  (NSFileVersion) run through merge and are removed.
- *Local folder:* user selects folder, security-scoped bookmark,
  FSEvents for external changes.
- *SFTP:* host, port, path, user, private key (file or ~/.ssh),
  optional OpenSSH certificate. Host key — TOFU via known_hosts.
  Key passphrase — in Keychain. Library candidates: Citadel, mft (libssh).

Network failure mid-sync → working copy untouched, retry in next cycle.

## MVP UI and Functionality

Three-column window (`NavigationSplitView`): groups → entries → details.

- Entries: title, login, password, URL, note, TOTP, custom fields.
  Copy with auto-clear clipboard after 30 sec.
- Groups: tree, drag-and-drop, Recycle Bin with restore.
- TOTP: enter `otpauth://` or secret; live code with timer.
- Search: instant, across all fields, global.
- Password generator: length, character classes; in editor and menu bar.
- Entry history: view and restore versions.
- Menu bar: status, quick search, lock, generator. Closing window does not
  quit the app.
- Import: CSV; open existing .kdbx files.
- Settings: backend, lock timeout, Touch ID, number of backups.

Extensions: match count on icon, list → select → fill; button in
password field; password generation; offer to save new login (confirmation
in the app).

## Testing

- **MyPassKit:** round-trip tests; cross-compatibility with reference
  KeePassXC files (different KDF/ciphers/structures) both ways — main safeguard against
  data corruption.
- **Merge:** table-driven tests for all scenarios (add/edit/delete/
  move from both sides).
- **SyncKit:** SFTP against local sshd in Docker (keys, certificates, mid-write
  disconnect); file backends — temp folders.
- **Extensions:** JS form-detection tests on saved pages from real
  sites; end-to-end scenario — manual checklist.
- **UI:** targeted.

## Phases

1. **Core** — MyPassKit; KeePassKit vs custom parser decision.
2. **App (local)** — full UI, local file, Touch ID,
   auto-lock, menu bar. Already usable.
3. **Sync** — folder → iCloud → SFTP; shared merge.
4. **Extensions** — Chrome (done); **4b** — Safari + shared WebExtension layer.
5. **iOS/iPadOS + AutoFill** — same codebase; inherits localization from Phase 7.
6. **Passkeys** — storage format (KeePassXC convention) laid out from the start.
7. **Localization** — en / uk / de (+ more via catalogs); scheduled **after 4b, before 5**.

## Risks

| Risk | Mitigation |
|---|---|
| KeePassKit weak on KDBX4 | Test on reference files in first days of phase 1; fallback — custom parser |
| SFTP library lacks OpenSSH certificates | Early prototype in phase 3; worst case — libssh C bindings |
| iCloud delays upload | NSFileCoordinator + check before merge; merge survives stale copy |
| Database corruption from write bug | Cross-tests with KeePassXC + backups before each write |
