# MyPass iCloud Sync Migration — Design

Date: 2026-07-27  
Status: approved

## Goal and Context

MyPass syncs a **local working copy** of the vault (`~/Library/Application Support/MyPass/vault.kdbx`, managed by `VaultFileStore`) against a remote mirror chosen in Settings. The user selected **iCloud Drive** as the sync backend and saw:

> iCloud Drive is unavailable — sign in to iCloud and enable iCloud Drive in System Settings.

That message is misleading. The app has **no iCloud ubiquity-container entitlements** (`MyPass/MyPass.entitlements` contains sandbox, network, bookmarks, and keychain only). For a sandboxed app, `FileManager.url(forUbiquityContainerIdentifier:)` always returns `nil`, so `iCloudBackend` throws `.containerUnavailable` regardless of the user's iCloud sign-in state. A real ubiquity container is a **restricted entitlement** requiring a paid Apple Developer Team ID and a registered container identifier; the project has no paid account and no `DEVELOPMENT_TEAM` in `project.yml`, so that path is closed and adding the entitlement would break local ad-hoc signing.

There is also **nothing to "migrate" in the file-relocation sense**: the canonical vault always stays in Application Support. What is genuinely missing is a **first-run connect flow** — seeding the remote mirror from the local vault, and deciding what to do when the remote mirror already holds a different vault.

This spec defines the approved design: reach iCloud through the user's **iCloud Drive folder** (`~/Library/Mobile Documents/com~apple~CloudDocs/`), which the system file provider syncs and which existing entitlements (`com.apple.security.files.user-selected.read-write`, `com.apple.security.files.bookmarks.app-scope`) already permit.

**Parent documents:**

| Document | Relationship |
|---|---|
| `docs/superpowers/specs/2026-07-21-mypass-design.md` | Product architecture, sync cycle, merge semantics, security model (atomic writes, backup rotation). Migration must not change canonical vault location or merge rules. |
| `docs/superpowers/specs/2026-07-26-mypass-settings-redesign-design.md` | Sync pane lives in `SyncSettingsPane`; this spec replaces misleading iCloud status copy and adds a dedicated migration sheet without restructuring the five-pane settings shell. |

**Adjacent gap (out of scope, mention only):** `BackupsSettingsPane` writes `backupCount` to UserDefaults, but `MyPassApp` constructs `VaultFileStore` with the default `backupCount: 10`. Unrelated to iCloud migration.

## Chosen Approach and Rejected Alternatives

### Chosen: iCloud Drive folder via dual-root `iCloudBackend`

The user picks a folder inside iCloud Drive (defaulting the open panel to the CloudDocs root). SyncKit's `iCloudBackend` gains a second root mode that resolves an app-scoped security-scoped bookmark to that folder. All coordinated I/O, download materialisation, and `NSFileVersion` conflict resolution remain shared with the ubiquity-container path. The app stores the bookmark separately from the Local File backend bookmark so both backends can stay configured.

### Rejected (B): Add real ubiquity-container entitlements

| Aspect | Why rejected |
|---|---|
| Entitlement | `com.apple.developer.icloud-container-identifiers` is restricted; requires paid Apple Developer Program membership and portal registration |
| Signing | Project has no `DEVELOPMENT_TEAM`; adding the entitlement breaks local ad-hoc builds |
| User impact | Does not help the current developer setup; remains available as a future convenience initialiser for paid-account builds |

The existing `iCloudBackend` initialiser that calls `url(forUbiquityContainerIdentifier:)` stays as a **convenience delegating to `.ubiquityContainer(identifier: nil)`** so integration tests and future paid-account setup continue to work.

### Rejected (C): Fix the message only; manual copy via Local File backend

| Aspect | Why rejected |
|---|---|
| UX | User must discover folder picking and backend switching without guidance |
| Data loss | No structured probe/merge/adopt/overwrite flow when the target folder already contains `vault.kdbx` |
| Semantics | "Local File" and "iCloud Drive" would share one bookmark key, preventing independent configuration |

## Current State (Verified)

| Component | Location / behaviour |
|---|---|
| Canonical vault | `~/Library/Application Support/MyPass/vault.kdbx` via `VaultFileStore` (`MyPass/Storage/VaultFileStore.swift`); backups at `backups/vault-{timeIntervalSince1970}.kdbx`; rotation in `save`; atomic temp + `replaceItemAt`; serial queue `com.tentens.mypass.VaultFileStore` |
| In-memory model | `KdbxDatabase` in `Packages/MyPassKit`; full parse in memory; no SQLite, WAL, lock files, or long-lived handles |
| Session | `VaultSession` (`MyPass/State/VaultSession.swift`): `.locked` / `.unlocked(KdbxDatabase)`; `fileStore`, optional `syncEngine`, `sessionPassword`, `persistQueue`, debounced `touchAccessPersistWorkItem`; `unlock`, `lock`, `save`, `mutate`, `touchAccess`, `triggerBackgroundSync`, private `syncOnUnlock`, `persist` (writes locally then `syncEngine.sync`) |
| Sync layer | `StorageBackend` protocol in `Packages/SyncKit`; implementations: `LocalFolderBackend`, `iCloudBackend`, `SFTPBackend`, `InMemoryStorageBackend`; `SyncEngine.sync(local:password:cipher:compression:)` download/merge/upload + checkpoint |
| iCloud today | `iCloudBackend` resolves root **only** from `url(forUbiquityContainerIdentifier:)`; remote file at `{containerURL}/Documents/{relativePath}`; `NSFileCoordinator` I/O; `startDownloadingUbiquitousItem` + `ubiquitousItemDownloadingStatusKey` polling; conflicts via `NSFileVersion.unresolvedConflictVersionsOfItem`; `iCloudFilePresenter` + `onRemoteChange` exist but are **not wired** in the app |
| Local folder | `LocalFolderBackend`: security-scoped bookmark, `{folder}/vault.kdbx`, plain uncoordinated I/O |
| Settings | `SyncBackendOption` (`MyPass/UI/Settings/SyncBackendOption.swift`): `local`, `iCloud`, `sftp` with display-string raw values (Phase 7 will move to stable codes — **not in this spec**); `SyncBackendResolver.resolveICloudBackend(relativePath:)`; `SyncSettingsPane.refreshICloudStatus()` shows misleading sign-in message on `.containerUnavailable` |
| App wiring | `MyPassApp.init()` (~lines 26–86): reads `syncBackend`, builds `StorageBackend` once, wraps `SyncEngine` with `UserDefaultsSyncCheckpointStore(key: "com.mypass.sync.checkpoint.{rawValue}")`, injects into `VaultSession` — **once at launch** |
| UserDefaults keys (existing) | `syncBackend`, `syncLocalFolderBookmark`, `syncSFTPHost`, `syncSFTPPort`, `syncSFTPUsername`, `syncSFTPRemotePath`, `syncSFTPPrivateKeyPath`, `syncSFTPCertificatePath`, `com.mypass.sync.checkpoint.{backendRawValue}`, `com.mypass.sync.trustedhostkey.*` |

## Component 1 — SyncKit: Dual-Root `iCloudBackend`

### Root abstraction

Introduce a public root type and initialiser:

```swift
public enum iCloudRoot {
    case ubiquityContainer(identifier: String?)
    case userFolder(bookmark: Data)
}

// New designated initialiser
public init(root: iCloudRoot, relativePath: String) throws

// Existing convenience — unchanged call sites in tests
public init(relativePath: String = "vault.kdbx") throws
// delegates to .ubiquityContainer(identifier: nil)
```

### Path resolution

| Root | Coordinated file URL |
|---|---|
| `.ubiquityContainer(identifier:)` | `{containerURL}/Documents/{relativePath}` — `Documents/` exists only inside a ubiquity container |
| `.userFolder(bookmark:)` | `{resolvedFolder}/{relativePath}` — **no** `Documents/` component |

For `.userFolder`, resolve the app-scoped security-scoped bookmark once at initialisation and hold `startAccessingSecurityScopedResource` for the lifetime of the backend instance, releasing it with `stopAccessingSecurityScopedResource` on deinit — the same lifecycle `LocalFolderBackend` uses. No per-operation acquire/release.

### Why not reuse `LocalFolderBackend`

`LocalFolderBackend` performs **plain uncoordinated** file I/O. For files inside iCloud Drive that is insufficient:

- An evicted or dataless file may read as empty data or a `.icloud` placeholder instead of the vault bytes.
- Concurrent edits from another device would not go through `NSFileVersion` conflict resolution.
- Upload/download materialisation would not be triggered reliably.

All remaining `iCloudBackend` behaviour is **shared** between both roots: `NSFileCoordinator`-mediated read/write, `startDownloadingUbiquitousItem(at:)` plus polling `URLResourceKey.ubiquitousItemDownloadingStatusKey`, and conflict resolution via `NSFileVersion.unresolvedConflictVersionsOfItem(at:)`.

### Errors

Extend `iCloudBackendError`:

| Case | When |
|---|---|
| `.containerUnavailable` | Ubiquity root; `url(forUbiquityContainerIdentifier:)` returned nil |
| `.downloadTimedOut` | Ubiquitous item did not materialise within timeout (existing) |
| `.folderBookmarkUnresolvable` | User-folder bookmark cannot be resolved |
| `.folderUnavailable` | Resolved folder missing or security-scoped access denied |

### iCloud Drive helpers

Add a small helper module next to `iCloudBackend` (same target):

- **`defaultICloudDriveRootURL`** — returns `~/Library/Mobile Documents/com~apple~CloudDocs` (or nil if absent).
- **`isURLInsideICloudDrive(_:)`** — predicate for UI: pre-fill open panel directory and show "this folder is not in iCloud Drive" warning (warn only; do not block folder selection).

## Component 2 — App Wiring

### New UserDefaults key

| Key | Type | Purpose |
|---|---|---|
| `syncICloudFolderBookmark` | Data (app-scoped bookmark) | Folder inside iCloud Drive for iCloud sync backend |

Deliberately **separate** from `syncLocalFolderBookmark` so the user can configure both Local File and iCloud Drive backends and switch the active backend in Settings without re-picking folders.

### Resolver and launch wiring

- **`SyncBackendResolver.resolveICloudBackend(bookmarkData:relativePath:)`** — gains required `bookmarkData:` parameter; returns `nil` when bookmark is absent or unresolvable (caller treats as "not configured").
- **`MyPassApp.init()`** — `.iCloud` case reads `syncICloudFolderBookmark` and passes it to the resolver; when the resolver returns `nil` (no bookmark, or unresolvable), `MyPassApp` attaches **no** `SyncEngine` at all (`syncEngine == nil`), exactly as it already does for an unconfigured Local File bookmark or missing SFTP credentials. `VaultSession` then operates purely locally, which is the correct pre-migration state.

### Restart constraint

The resolved `StorageBackend` and `SyncEngine` are built **once at launch**. Configuring iCloud sync for the first time (or changing the folder) requires an **app restart** to activate syncing. The migration sheet states this explicitly on success. Hot-swapping `VaultSession.syncEngine` is out of scope (`syncEngine` remains `let`).

## Component 3 — `VaultMigrationService`

New file: `MyPass/Storage/VaultMigrationService.swift`.

Backend-agnostic: accepts any `StorageBackend`, so the same logic later serves SFTP and local-folder first-connect flows.

### API sketch

```swift
enum VaultMigrationStrategy {
    case seedRemote
    case merge
    case adoptRemote
    case overwriteRemote
}

struct VaultMigrationTargetProbe {
    let exists: Bool
    let modificationDate: Date?
    let byteCount: Int?
}

struct VaultMigrationOutcome {
    let strategy: VaultMigrationStrategy
    let mergedDatabase: KdbxDatabase?
    let remoteWritten: Bool
    let localReplaced: Bool
}

enum VaultMigrationError: Error {
    case vaultLocked
    case remoteUnreadable(underlying: Error)
    case remoteNotAValidVault
    case remotePasswordMismatch
    case remoteWriteFailed(underlying: Error)
    case localWriteFailed(underlying: Error)
}

final class VaultMigrationService {
    init(fileStore: VaultFileStore)
    func probe(remote: StorageBackend) throws -> VaultMigrationTargetProbe
    func migrate(
        local: KdbxDatabase,
        password: String,
        remote: StorageBackend,
        strategy: VaultMigrationStrategy
    ) throws -> VaultMigrationOutcome
}
```

Adjust type or method names only if they clash with existing symbols during implementation.

### Strategy semantics

| Strategy | When offered | What it does |
|---|---|---|
| `seedRemote` | Remote absent (`exists == false`) | Serialise local `KdbxDatabase` and `remote.write`; local vault untouched |
| `merge` | Remote present; **default choice** | Run one `SyncEngine.sync(local:password:cipher:.aes256, compression:.gzip)` pass against the new backend with `InMemorySyncCheckpointStore` (already present at `Packages/SyncKit/Sources/SyncKit/SyncCheckpointStore.swift`), never the persisted `UserDefaultsSyncCheckpointStore`, so the one-off migration pass cannot be short-circuited by a stale checkpoint; persist merged result locally via `VaultFileStore.save`; no bespoke merge logic beyond `SyncEngine` |
| `adoptRemote` | Remote present | `remote.read`, open with session password; only after successful parse, write into `VaultFileStore` (whose `save` rotation snapshots the previous local state into `backups/`) |
| `overwriteRemote` | Remote present | Serialise local database and `remote.write`, discarding remote copy |

### Probe behaviour

`probe(remote:)` calls `remote.exists()`, and when true, `modificationDate()` and derives `byteCount` from `remote.read()?.count`. `StorageBackend` exposes no size API, so this means the probe performs a full coordinated read, which is intentional — for an iCloud folder it also forces materialisation of an evicted file, so a later `.downloadTimedOut` surfaces during the probe step rather than mid-migration. The probe never decrypts and never needs the vault password.

### Safety ordering (service-level)

**Governing principle:** never destroy a copy before its replacement has been validated.

- **`seedRemote` / `overwriteRemote`:** serialise to memory first; validate non-empty KDBX header if applicable; only then `remote.write`. Local file not touched until `merge` or `adoptRemote` explicitly writes locally.
- **`adoptRemote`:** parse remote bytes with session password **before** any local write; on parse failure, throw `remoteNotAValidVault` or `remotePasswordMismatch` with **zero writes** on either side.
- **`merge`:** must write to `VaultFileStore` only after `SyncEngine.sync` has returned a database; if the sync pass throws, the local working copy is left exactly as it was and the error propagates unchanged. The implementation must verify this ordering with a test rather than relying on `SyncEngine`'s internal behaviour.

## Component 4 — `VaultSession` Integration

Add to `VaultSession`:

```swift
func probeMigrationTarget(remote: StorageBackend) throws -> VaultMigrationTargetProbe
func performMigration(to remote: StorageBackend, strategy: VaultMigrationStrategy) throws -> VaultMigrationOutcome
```

### Preconditions

Both methods require `.unlocked` state and a stored `sessionPassword`. Otherwise throw `VaultMigrationError.vaultLocked` (or a session-level wrapper).

### Concurrency with autosave

Before executing migration:

1. Cancel any pending debounced `touchAccessPersistWorkItem`.
2. Run migration work on `persistQueue` (same queue as `persist`) so migration cannot race an in-flight autosave or background sync triggered by touch-access debounce.

### State updates after migration

| Strategy | Update published `VaultState` |
|---|---|
| `seedRemote`, `overwriteRemote` | No in-memory change (local database unchanged) |
| `merge`, `adoptRemote` | Replace `.unlocked` payload with resulting `KdbxDatabase` so the UI does not show stale entries |

### Checkpoint cleanup (session or caller)

After successful migration, delete `UserDefaults` entry `com.mypass.sync.checkpoint.{SyncBackendOption.iCloud.rawValue}` so the first sync after restart performs a full merge instead of trusting a stale checkpoint. The migration sheet or `VaultSession` performs this on success before prompting restart.

## Component 5 — UI

### SyncSettingsPane status copy

Replace misleading sign-in message with honest, actionable status:

| State | UI |
|---|---|
| No iCloud folder configured | Explain that MyPass syncs through a **folder in iCloud Drive** (not a ubiquity container); offer **Set up iCloud sync…** button |
| Folder configured | Show chosen folder display name/path and last sync state (existing manual sync status where applicable) |
| Vault locked | **Set up iCloud sync…** disabled with explanation: session password is required to parse a remote vault |
| Stale/unresolvable bookmark | Clear `syncICloudFolderBookmark`, show message asking user to re-pick folder |

Remove production use of the string "sign in to iCloud and enable iCloud Drive in System Settings" as the explanation for missing entitlements. The pane must state that syncing through an iCloud Drive folder needs no developer account, while the ubiquity-container path would require a paid Apple Developer account.

### SyncMigrationSheet

New file: `MyPass/UI/Settings/SyncMigrationSheet.swift` — keeps `SyncSettingsPane` from growing further (it already handles three backends).

**Sheet flow (steps):**

1. **Choose folder** — `NSOpenPanel` with `canChooseDirectories = true`, `directoryURL` pre-filled to `defaultICloudDriveRootURL`. Store app-scoped bookmark in `syncICloudFolderBookmark`. If `!isURLInsideICloudDrive(chosenURL)`, show warning; do not block.
2. **Probe** — build temporary `iCloudBackend(root: .userFolder(bookmark:), relativePath: "vault.kdbx")`, call `VaultSession.probeMigrationTarget`.
3. **Confirm strategy** — If remote empty: confirm upload (`seedRemote`). If remote occupied: show modification date and byte size; present merge (preselected), adopt remote, overwrite remote with short descriptions per strategy table.
4. **Progress** — indeterminate or stepped progress while `performMigration` runs on unlocked vault.
5. **Result** — success summary; **restart MyPass** to activate syncing; dismiss returns to Sync pane showing configured folder.

Button entry point: **Set up iCloud sync…** in iCloud section of `SyncSettingsPane`. Sheet receives `VaultSession` (or environment object) for probe/migrate calls.

### Error surfacing in UI

| Error | User-facing behaviour |
|---|---|
| `.folderBookmarkUnresolvable` / `.folderUnavailable` | Clear bookmark key; ask to re-pick |
| `.downloadTimedOut` | Explain file may still be downloading from iCloud; offer Retry |
| `.remoteNotAValidVault` | Abort; both sides unchanged |
| `.remotePasswordMismatch` | Abort; explain remote vault uses a different password; both sides unchanged |
| `.remoteWriteFailed` | Local untouched; show error |
| `.localWriteFailed` | Remote may already be updated — message must state explicitly that **cloud copy is ahead** of local |
| Migration while locked | Disabled button / alert if invoked |

## Error Handling and Safety (Cross-Cutting)

All branches honour: **validate before destroy**.

| Scenario | Behaviour |
|---|---|
| Stale bookmark | Clear `syncICloudFolderBookmark`, prompt re-pick; no sync until configured |
| Folder deleted / unreachable | `.folderUnavailable`; no writes |
| Download timeout | Surface `.downloadTimedOut` with retry; no partial merge |
| Remote not valid KDBX | Abort; zero writes either side |
| Remote wrong password | Abort; byte-identical before/after on both sides |
| Remote write failure | Local untouched |
| Local write failure after remote success | User informed cloud is ahead; manual recovery via adopt/merge on next attempt |
| Migration while locked | Rejected at session layer |
| Pending autosave | Cancel debounced work item; serialise through `persistQueue` |

## Testing

Run all tests via `./scripts/test.sh`. Build via `./scripts/build-all.sh`, `./scripts/generate.sh` (XcodeGen), `./scripts/run.sh`.

### SyncKit — `Packages/SyncKit/Tests/SyncKitTests/`

**Ungated (no real iCloud account required):**

- User-folder root of `iCloudBackend` against a temporary directory reached through a **real app-scoped bookmark**: `read`, `write`, `exists`, `modificationDate`, conflict resolution (simulate two versions via `NSFileVersion` or test hooks).
- Ubiquity convenience initialiser still throws `.containerUnavailable` without entitlements (existing test pattern).

**Gated integration** (`MYPASS_ICLOUD_INTEGRATION_TESTS=1`):

- User-folder root against a real subfolder of `com~apple~CloudDocs` (existing gate pattern from `iCloudBackendTests.swift`).

### App — `MyPassTests/`

**New `VaultMigrationServiceTests.swift`** (using `InMemoryStorageBackend`):

1. Seed empty remote.
2. Merge when both sides have distinct entries (assert merged entry set).
3. `adoptRemote` replaces local; prior local state appears in `backups/` rotation.
4. `overwriteRemote` discards remote content.
5. Wrong-password remote abort — **both sides byte-identical** to pre-migration.

**`VaultSessionTests.swift` additions:**

- Migration rejected when locked.
- Pending debounced persist cancelled before migration runs.

**`SettingsViewSyncBackendTests.swift` additions:**

- `resolveICloudBackend(bookmarkData:)` returns `nil` for nil, empty, and garbage bookmark data, and never throws or traps.

## Documentation Impact

**`RUN.md`** (Ukrainian — must remain Ukrainian):

- Add a short section on setting up iCloud sync through an iCloud Drive folder (pick folder, run connect flow, restart app).
- Rewrite the existing "iCloud entitlements" limitation bullet to state plainly: the ubiquity-container path requires a paid Apple Developer account; the folder-based path does not.

No other doc files are required by this spec.

## Architecture Notes

| Area | Notes |
|---|---|
| Files (new) | `MyPass/Storage/VaultMigrationService.swift`, `MyPass/UI/Settings/SyncMigrationSheet.swift` |
| Files (modified) | `Packages/SyncKit/.../iCloudBackend.swift`, helpers; `MyPass/State/SyncBackendResolver.swift`, `VaultSession.swift`; `MyPass/MyPassApp.swift`; `MyPass/UI/Settings/SyncSettingsPane.swift` |
| Dependencies | `VaultMigrationService` depends on `VaultFileStore`, `SyncEngine`, `KdbxDatabase`, `StorageBackend` — no UI |
| Phase 7 dependency | `SyncBackendOption` raw values remain display strings until Phase 7 stable codes (`local` / `icloud` / `sftp`); checkpoint key uses current raw value — document only, do not migrate in this work |
| Entitlements | No change to `MyPass.entitlements`; no `DEVELOPMENT_TEAM` added |

## Success Criteria

1. Settings **never** shows the old "sign in to iCloud and enable iCloud Drive" message as the explanation for missing ubiquity entitlements.
2. A user with a local-only vault can run **Set up iCloud sync…**, pick an iCloud Drive folder, seed remotely, restart, and see `vault.kdbx` appear in that folder.
3. When the target folder already holds a vault, the user is offered **merge** (default), **adopt remote**, and **overwrite remote**; no data loss in any branch under test.
4. Wrong-password remote aborts with **both sides unchanged** (byte-identical).
5. `./scripts/test.sh` passes including new unit tests; gated iCloud integration test passes when env var set.

## Out of Scope

| Item | Notes |
|---|---|
| Hot-swapping `SyncEngine` without restart | `VaultSession.syncEngine` stays `let`; user restarts after connect |
| Ubiquity-container entitlements or `DEVELOPMENT_TEAM` | Paid account path deferred |
| Wiring `iCloudBackend.onRemoteChange` / `NSFilePresenter` | Exists in SyncKit; app integration deferred |
| Phase 7 `SyncBackendOption` raw-value migration | Separate spec |
| iOS support | macOS only |
| `backupCount` wiring from Settings to `VaultFileStore` | Unrelated gap |
| SFTP / Local File connect sheets | Same `VaultMigrationService` API enables later; not in this phase UI |
| Real-time remote change notifications | Manual sync + timer/on-save cycle unchanged |

## Implementation Handoff

Proceed via `writing-plans` → `executing-plans`. Implementation plan must reference this spec by path, implement SyncKit dual-root first (tests), then `VaultMigrationService`, then `VaultSession` + resolver wiring, then UI sheet, then `RUN.md` update. Order migration UI after service tests pass.

## References

| Resource | Path |
|---|---|
| Master product design | `docs/superpowers/specs/2026-07-21-mypass-design.md` |
| Settings shell | `docs/superpowers/specs/2026-07-26-mypass-settings-redesign-design.md` |
| Vault file I/O | `MyPass/Storage/VaultFileStore.swift` |
| Vault session | `MyPass/State/VaultSession.swift` |
| iCloud backend | `Packages/SyncKit/Sources/SyncKit/iCloudBackend.swift` |
| Local folder backend (bookmark pattern) | `Packages/SyncKit/Sources/SyncKit/LocalFolderBackend.swift` |
| Sync resolver | `MyPass/State/SyncBackendResolver.swift` |
| App launch wiring | `MyPass/MyPassApp.swift` |
| Sync settings UI | `MyPass/UI/Settings/SyncSettingsPane.swift` |
| Entitlements | `MyPass/MyPass.entitlements` |
| Test runner | `./scripts/test.sh` |
| Ukrainian run guide | `RUN.md` |
