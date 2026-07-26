# MyPass Settings Redesign — Design

Date: 2026-07-26  
Status: approved

## Goal and Context

MyPass settings today live in a single scrolling `Form` (`SettingsView`) opened from the macOS **Settings** scene. Controls for auto-lock, backups, sync, and the Chrome extension are stacked in one pane with helper subtext — adequate for early phases but hard to scan as settings grow.

This spec defines **Problem 1: Settings shell and pane layout** — an Apple System Settings–style sidebar navigation inside the Settings window, with logical grouping and new General/Security controls. It does **not** redesign menu bar contents beyond toggles that control whether the menu bar extra appears.

**Parent documents:**

| Document | Relationship |
|---|---|
| `docs/superpowers/specs/2026-07-21-mypass-design.md` | Product architecture, security model (Touch ID derived key, auto-lock, clipboard auto-clear default 30 s, backup rotation). Settings must expose those knobs without changing underlying semantics. |
| `docs/superpowers/specs/2026-07-26-mypass-ui-shell-design.md` | Wave 1 restyled settings as a single scrolling pane. **This spec supersedes the Settings layout section of the UI shell spec** (sidebar navigation replaces single-pane layout). Helper subtext pattern, English strings, and semantic styling from Wave 1 remain in force. |

**Separate future work:** **Problem 2 — Menu Bar** (Quick Access panel, menu items, shortcuts wiring to menu actions) will be a dedicated spec. Here, General only exposes presence toggles and a placeholder for future click behavior; `MenuBarExtraContent` is not redesigned in this phase.

## Approach

Replace the monolithic `SettingsView` body with a **Settings-scene `NavigationSplitView`**: fixed-width sidebar (~180 pt) listing five panes; detail column shows the selected pane’s controls. Reuse existing `@AppStorage` keys and section implementations where possible — extract subviews per pane rather than rewriting sync/Chrome logic.

Rejected: keeping a single scrolling form (does not scale); adding Appearance, Privacy, Labs, or About panes in this version (explicitly excluded).

## Settings Window Shell

### Structure

```
Settings scene (MyPassApp)
└── NavigationSplitView
    ├── Sidebar (~180 pt, non-collapsible in v1)
    │   └── List(selection:) — 5 rows with SF Symbol + title
    └── Detail
        └── Selected pane content (Form or grouped controls + helper subtext)
```

- **Minimum window size:** detail column `minWidth` ≥ 480 pt; sidebar fixed ~180 pt.
- **Default selection:** General (on first open and when no persisted selection exists).
- **Selection persistence:** optional `@AppStorage("settingsSelectedPane")` — if omitted, default to General each launch; if added, store pane raw value (`general`, `security`, `browser`, `sync`, `backups`).
- **Style:** grouped form controls in detail column; reuse existing `SettingsHelperText` (11 pt secondary, multi-line).

### Sidebar rows

| Pane | SF Symbol | Detail title |
|---|---|---|
| General | `gearshape` | General |
| Security | `lock.fill` | Security |
| Browser | `globe` | Browser |
| Sync | `arrow.triangle.2.circlepath` | Sync |
| Backups | `externaldrive` | Backups |

Row layout: symbol (secondary tint) + label; system selection highlight. No footer items, no search field, no Appearance / Privacy / Labs / About entries.

## Pane Specifications

### General

Controls for app presence, login item, and keyboard shortcuts. **Explicitly excluded** (do not add): Markdown notes default, prefill username on new entry, vault/item defaults copied from 1Password.

#### Menu bar

| Control | Type | Default | Behavior |
|---|---|---|---|
| Keep MyPass in the menu bar | Toggle | ON | When OFF, `MenuBarExtra` is not registered in `MyPassApp` (icon hidden). When ON, current `MenuBarExtra("MyPass", systemImage: "key.fill")` remains. Does not change `MenuBarExtraContent` layout — that is Problem 2. |
| Click the icon to | Picker (single option) | Show a menu | Only choice: **Show a menu**. Display as a picker or static row with trailing value **Show a menu** so a future **Show Quick Access** option can be added without restructuring. Persist key for forward compatibility; value `"menu"` when only option exists. No effect on click behavior until Problem 2 — today’s popover/menu content stays as implemented. |

Helper subtext (menu bar group): explain that the menu bar icon provides quick access while MyPass runs; turning it off hides the icon but keeps the main window available from the Dock.

#### Login item

| Control | Type | Default | Behavior |
|---|---|---|---|
| Start MyPass at login | Toggle | OFF | Uses `SMAppService.mainApp` (Login Items API). ON → `register()`; OFF → `unregister()`. On appear, sync toggle state from `SMAppService.mainApp.status` (.enabled / .requiresApproval / .notRegistered). Surface `.requiresApproval` with helper text directing user to System Settings → General → Login Items if approval pending. |

Helper subtext: MyPass opens in the background at login so the vault and extensions are ready; vault remains locked until unlocked manually.

#### Keyboard shortcuts

Present as a labeled group **Keyboard Shortcuts** with three rows. Use a standard macOS shortcut recorder control (e.g. `KeyboardShortcuts.Recorder`-style or equivalent in-app recorder): click field → capture key combination; **Clear** or empty recording = no shortcut.

| Action | Recorder state | Default | Notes |
|---|---|---|---|
| Show MyPass | Enabled | None (empty) | Brings main window to front / opens app if hidden. Empty = shortcut disabled. |
| Show Quick Access | Disabled | — | Row visible; control greyed out; trailing or helper text: **Coming later** (Problem 2). |
| Lock MyPass | Enabled | ⇧⌘L (Shift+Command+L) | Invokes vault lock when unlocked. Register global hotkey only if combination is available (no conflict with system or other apps); on conflict, show inline warning and do not register until user chooses another combination. Empty = disabled. |

Helper subtext: shortcuts work while MyPass is running; Lock applies only when the vault is unlocked.

**Storage:** new `@AppStorage` string keys encoding modifier+key (implementation plan defines exact encoding, e.g. `"shift+command+L"` or archived `KeyboardShortcut` Data). Keys listed in AppStorage table below.

### Security

Move auto-lock here from the old combined form; add Touch ID enrollment toggle and configurable clipboard clear interval.

#### Auto-lock

| Control | Type | Default | Behavior |
|---|---|---|---|
| Lock automatically after inactivity | Stepper | 15 min | Reuse `@AppStorage("autoLockTimeoutMinutes")` (range 1…120). On change, update `AutoLockController.timeout` as today. |

Helper subtext: lock the vault after inactivity so passwords stay protected when you step away.

#### Touch ID

| Control | Type | Default | Behavior |
|---|---|---|---|
| Unlock with Touch ID | Toggle | OFF if no enrolled key; ON if `BiometricKeyStore` has item for account `"master"` | **ON (enroll):** requires vault **unlocked**. Prompt for master password confirmation, derive/store key via existing `BiometricKeyStore.store(derivedKey:account: "master")` using current vault derived key material (same path as master design — derived key, not master password, with `kSecAccessControlBiometryCurrentSet`). Show error if biometry unavailable or enrollment fails. **OFF (remove):** delete Keychain item (`SecItemDelete` for service `com.mypass.app.biometric`, account `"master"`). Unlock screen Touch ID button reflects enrollment state (existing `UnlockView` behavior). |

Helper subtext: use Touch ID to unlock without typing your master password; after restart, master password is still required per security model.

#### Clipboard

| Control | Type | Default | Behavior |
|---|---|---|---|
| Clear clipboard after | Stepper (seconds) | 30 s | New `@AppStorage("clipboardClearSeconds")`, range 10…120 (step 5 or 10 acceptable). Replace hardcoded `30` in `EntryDetailView.copy(_:)` and `PasswordGeneratorView` copy path — both call `ClipboardAutoClear.schedule(..., after:)` with stored value. Preserve existing rule: clear only if clipboard still contains exactly the copied value. |

Helper subtext: usernames, passwords, and codes copied from MyPass are removed from the clipboard after this interval.

Remove the old clipboard mention from auto-lock helper text in Security (clipboard has its own control now).

### Browser

Relocate the existing **Chrome Extension** section unchanged in behavior:

- Extension ID text field (`@AppStorage("chromeExtensionID")`)
- Native MessagingHosts folder bookmark + Choose Folder… (`chromeNativeMessagingDirectoryBookmark`)
- Install/Update Native Messaging Host button + status message
- Existing helper subtext about native messaging host

Section header in detail pane: **Chrome Extension** (subsection under Browser pane title). Safari extension settings are out of scope (Phase 4b).

### Sync

Relocate existing sync UI **unchanged in behavior**:

- Backend picker (`syncBackend`)
- Local folder / iCloud / SFTP subsections (all existing fields, keychain-backed SFTP secrets, Test Connection, Sync Now)
- Manual sync status message
- iCloud availability check on appear / backend change
- Helper subtext about mirrored vault location

No new backends, no merge-behavior changes.

### Backups

Relocate existing backup control:

| Control | Type | Default | Behavior |
|---|---|---|---|
| Keep last | Stepper | 10 | Reuse `@AppStorage("backupCount")`, range 1…50. |

Helper subtext: rotate local backup copies of the vault file so you can recover from a corrupted save.

## AppStorage and Persistence

### Preserve unchanged (move UI only)

| Key | Used by |
|---|---|
| `autoLockTimeoutMinutes` | Auto-lock stepper |
| `backupCount` | Backups stepper |
| `syncBackend` | Sync picker |
| `syncLocalFolderBookmark` | Local folder sync |
| `syncSFTPHost`, `syncSFTPPort`, `syncSFTPUsername`, `syncSFTPRemotePath`, `syncSFTPPrivateKeyPath`, `syncSFTPCertificatePath` | SFTP UI (secrets remain in Keychain) |
| `chromeExtensionID` | Browser pane |
| `chromeNativeMessagingDirectoryBookmark` | Browser pane |

### New keys (this spec)

| Key | Type | Default | Pane |
|---|---|---|---|
| `showMenuBarExtra` | Bool | `true` | General |
| `menuBarClickAction` | String | `"menu"` | General (single option for now) |
| `launchAtLogin` | Bool | `false` | General (mirror SMAppService; may sync from service status on launch) |
| `shortcutShowMyPass` | String | `""` (empty = none) | General |
| `shortcutLockMyPass` | String | `"shift+command+L"` | General |
| `clipboardClearSeconds` | Int | `30` | Security |
| `settingsSelectedPane` | String | `"general"` | Shell (optional) |

Do not store master password, derived keys, or SFTP private key PEM in `@AppStorage`.

## Architecture Notes

- **Files:** refactor `MyPass/UI/Settings/` into shell + pane views (e.g. `SettingsShellView`, `GeneralSettingsPane`, `SecuritySettingsPane`, `BrowserSettingsPane`, `SyncSettingsPane`, `BackupsSettingsPane`). `SettingsView` may become the shell entry point or be renamed in the implementation plan.
- **MyPassApp:** conditionally include `MenuBarExtra` from `showMenuBarExtra`; register global shortcuts from General keys at launch and when settings change; read `clipboardClearSeconds` in copy paths via shared accessor or environment.
- **Tests:** extend or add tests for clipboard interval wiring, menu bar toggle (smoke), shortcut encoding, Touch ID toggle state vs Keychain presence (`FakeBiometricKeyStore` in unit tests). Existing `SettingsViewSyncBackendTests` and `ClipboardAutoClearTests` must keep passing with updated call sites.
- **Localization:** English literals in source until Phase 7 (`2026-07-26-mypass-phase7-localization-design.md`).
- **UI shell metrics:** reuse Wave 1 helper text styling; Settings window is separate from main-window `NavigationSplitView`.

## Acceptance Criteria

1. Settings opens as a **`NavigationSplitView`** with a ~180 pt sidebar listing General, Security, Browser, Sync, and Backups (with specified SF Symbols). General is selected by default.
2. **General:** menu bar visibility toggle hides/shows `MenuBarExtra`; login item toggle registers/unregisters via `SMAppService`; keyboard shortcut recorders for Show MyPass and Lock MyPass work (empty disables); Show Quick Access row is visible and disabled with **Coming later**; Click-the-icon control shows **Show a menu** as the only option.
3. **Security:** auto-lock stepper uses `autoLockTimeoutMinutes` and updates `AutoLockController`; Touch ID toggle enrolls/removes biometric key per rules above; clipboard stepper persists `clipboardClearSeconds` and all MyPass copy-to-clipboard paths honor it with unchanged overwrite protection.
4. **Browser, Sync, Backups:** all controls from the current monolithic `SettingsView` appear in the correct pane with **equivalent behavior** (sync backends, SFTP test, Chrome host install, backup count, Sync Now).
5. Each control group includes **Apple-like helper subtext** (11 pt secondary) explaining purpose; no Appearance, Privacy, Labs, or About panes.
6. **No regressions:** existing AppStorage keys for sync and Chrome continue to read/write the same values; vault session, auto-lock, and sync resolver behavior unchanged aside from new settings wiring.
7. **Problem 2 boundary:** menu bar popover content is not redesigned; only presence toggle and placeholder click-action setting are added in General.

## Out of Scope

| Item | Notes |
|---|---|
| Menu bar Quick Access panel and menu contents | Problem 2 — separate spec (`MenuBarExtraContent` redesign, backlog item 7 in UI shell) |
| Show Quick Access shortcut (enabled recorder) | Disabled in General until Problem 2 |
| Appearance (theme, density Comfortable/Compact) | UI shell backlog item 6 |
| Privacy, Labs, About panes | Not in v1 sidebar |
| Markdown notes default, prefill username, vault defaults | Explicitly rejected |
| Safari extension settings | Phase 4b |
| New sync backends or merge logic changes | Master design scope only |
| Auto-lock on sleep / screen lock toggles | Master design mentions optionally; not added here unless already implemented |
| String Catalog / uk / de localization | Phase 7 |
| Main window `NavigationSplitView` changes | UI shell Wave 1 only |

## Implementation Handoff

Proceed via `writing-plans` → `executing-plans`. Plans must reference this spec by path, note supersession of UI shell Settings layout, and split work by pane plus `MyPassApp` integration (menu bar, shortcuts, login item, clipboard interval).

## References

| Resource | Path |
|---|---|
| Master product design | `docs/superpowers/specs/2026-07-21-mypass-design.md` |
| UI shell (superseded Settings layout) | `docs/superpowers/specs/2026-07-26-mypass-ui-shell-design.md` |
| Current settings implementation | `MyPass/UI/Settings/SettingsView.swift` |
| Menu bar extra (unchanged content) | `MyPass/UI/MenuBar/MenuBarExtraContent.swift` |
| Clipboard auto-clear | `MyPass/UI/EntryDetail/ClipboardAutoClear.swift`, `EntryDetailView.swift` |
| Biometric storage | `MyPass/Security/BiometricKeyStore.swift` |
