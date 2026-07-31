# Unified Vault Location — Design

## Problem

Today "where the vault lives" is split across two unrelated systems:

1. **Primary storage** — `VaultFileStore`, hardcoded to
   `~/Library/Application Support/MyPass/vault.kdbx` in `MyPassApp.init()`.
   Not configurable at all.
2. **Sync backend** (`SyncBackendOption`: Local folder / iCloud Drive folder /
   SFTP) — an optional *mirror* layered on top of #1. Configuring it requires
   the vault to already be unlocked, because migrating/merging into the
   mirror needs the master password (`VaultSession.performMigration`).

This has two problems:

- There's no single, unambiguous "the vault lives here" answer a future
  iPhone/iPad client could rely on — it would be reading a *mirror* that may
  lag behind the Mac's real canonical copy.
- Choosing or changing where the vault lives is only possible after
  unlocking, so a user can't set up their preferred location — or recover
  from a bad one — without first getting into the vault.

## Goals

- The vault's storage location is a single, first-class setting: **Local**
  (this Mac only) or **iCloud Drive** (synced, and the one a future mobile
  client would also open). No separate "primary copy vs. mirror" split for
  these two.
- Custom Folder and SFTP remain available, but strictly as an optional
  **secondary destination** layered on top of whichever primary location is
  active — not as alternatives to it.
- The vault location (and other settings) can be viewed and changed from
  Settings *before* authenticating.
- Changing the active location is gated: the user must successfully
  authenticate (enter the master password) before the change is persisted.

## Non-goals

- No iOS/iPadOS app is built as part of this work — this only ensures the
  chosen storage convention (a folder inside iCloud Drive) is one a future
  mobile client could reach the same way (user-granted folder access, no
  paid-developer container entitlement required).
- No change to the KDBX merge algorithm itself, or to SFTP's push/pull
  mechanics — both are reused as-is.

## Architecture

### `VaultLocation`

Replaces `VaultFileStore`'s hardcoded directory. Two cases only:

- `.local` — today's Application Support folder. Zero-prompt, always
  available. This is what every existing install is already on, and stays
  the "Skip for now" choice for new installs that decline iCloud.
- `.iCloudDrive(bookmark: Data)` — a user-granted folder inside
  `~/Library/Mobile Documents/com~apple~CloudDocs`, using the existing
  `iCloudBackend`/`ICloudDriveLocation` machinery, promoted from "sync
  mirror" to "the" primary store. Reaching it always requires one explicit
  folder-picker grant — the sandbox has no way around that without the paid
  container entitlement (unchanged constraint, confirmed not in scope).

Whichever is active, the primary store (`VaultFileStore` for Local,
`ICloudDriveVaultStore` for iCloud Drive) reads and writes directly there.
There is no second, separate canonical copy and no continuous push/pull
between "local" and "remote" for these two — they *are* the single copy.

### Secondary destination (orthogonal, not a `VaultLocation` case)

A single picker, independent of the primary location, labeled "Also Sync To"
in Settings: **None / Folder / SFTP**. One at a time (not simultaneous). This
keeps today's `LocalFolderBackend`, `SFTPBackend`, `SyncEngine`
push/pull-with-merge machinery exactly as it works now — a secondary
destination is inherently a second copy that needs reconciliation, unlike the
primary location.

(Implementation note: the picker and its backing `SecondaryDestinationOption`
type deliberately avoid "Backup"/"Backups" wording — a naming constraint
adopted during implementation because these are sync mirrors, not backups in
the traditional sense, and using "backup" language risked implying a
restore/versioning guarantee the feature doesn't provide.)

### External-change handling

The existing per-location watchers (`LocalFolderChangeWatcher` for Local,
`iCloudBackend`'s remote-change notification for iCloud Drive) continue to
trigger a reload-and-merge of the single primary file when something external
touches it. This is the mechanism a future mobile client editing the same
iCloud Drive file would depend on for safe interop — already built, just
kept as the standing behavior rather than a side effect of "mirror sync."

## Flows

### First run (no vault exists anywhere yet)

No wizard, no dialogs: MyPass silently creates the vault on `.local`
(Application Support), exactly as every existing install already works. This
mirrors `.local`'s existing dedicated `MyPass` subfolder under Application
Support with no prompt at all.

Choosing iCloud Drive is only available afterward, as an explicit action from
Settings → Vault Location → "Switch to iCloud Drive…" — see "Changing the
primary location later" below. It is never offered or forced on first run.

Whichever location is active, the normal first-unlock flow proceeds unchanged
(`VaultSession.unlock` with `fileStore.load() == nil` creates the new
database and sets the master password). No separate verification step is
needed here — there is nothing yet to verify against.

### Existing installs

Never forced onto a different location. A pre-existing Application Support
`vault.kdbx` means the location is already "configured: Local," full stop.
Nothing changes for them until they explicitly go pick a different location.

### Changing the primary location later (a vault already exists)

Reachable from a new **Vault Location** settings pane, regardless of whether
the app is currently locked or unlocked:

1. User picks Local ↔ iCloud Drive (granting folder access if switching to
   iCloud and not already granted). Whatever folder the grant is made on,
   MyPass creates (or reuses) a "MyPass" subfolder inside it and stores the
   vault there — never loose in the granted folder's root. This is the only
   place in the app a user picks an iCloud folder.
2. This *stages* the change — nothing is persisted yet, no I/O against the
   target happens yet.
3. The pane prompts for the master password inline ("Enter your password to
   confirm this change").
4. That password is checked against the **currently active** location's
   vault. This single check *is* the authorization step — entering it does
   double duty as "prove you own this vault" and as the password the
   migration below uses.
   - On success: reuse `VaultMigrationService`'s existing probe (does the
     target already hold a vault?) and strategy choice (merge / adopt
     remote / overwrite remote / seed remote) exactly as
     `SyncMigrationSheet` does today, just entered from this pane instead of
     requiring a prior separate unlock. Only after the migration succeeds is
     the new location persisted, and the session left unlocked.
   - On failure: show an error, discard the staged change, leave persisted
     settings and session state untouched (still locked if it was locked).

## Error handling

No new failure modes beyond what `SyncMigrationSheet`/`iCloudBackendError`/
`VaultMigrationError` already handle today — those messages are reused
verbatim, just surfaced from the new pane:

- Stale/unresolvable bookmark → cleared, user asked to re-grant.
- iCloud file still downloading → "wait and retry."
- Wrong password on the confirm step → error shown, staged change discarded,
  no partial state (nothing was persisted or touched on disk).
- Migration failures (not a valid vault, password mismatch, write failure)
  → identical existing messages.

## Testing

- Unit tests (pure-logic, following the existing
  `SettingsViewSyncBackendTests` pattern): `VaultLocation` default-resolution
  (fresh install vs. pre-existing Application-Support vault vs. previously
  granted iCloud bookmark), and confirm-password gating (success persists +
  migrates; failure leaves settings and session state untouched).
- Manual verification via the `run` skill: silent local-only first run,
  changing location both pre-auth and post-auth, wrong-password rejection,
  and that an existing pre-redesign install keeps working unchanged on
  Local.

## Implementation notes (resolved)

The open questions this section originally posed are all settled in the
shipped implementation:

- `SyncBackendOption` was fully retired. The new two-picker shape is
  `VaultLocation` (local/iCloudDrive) plus `SecondaryDestinationOption`
  (none/folder/sftp, labeled "Also Sync To" in Settings — deliberately not
  `BackupTarget`/"Backup", see "Secondary destination" above).
- `SettingsPane` gained a dedicated `.vaultLocation` pane, separate from the
  existing sync pane (which now only covers the secondary destination).
- Persistence keys: the pinned `syncICloudFolderBookmark` key is reused
  as-is (never renamed); `syncLocalFolderBookmark`/`syncBackend` are read
  once for legacy migration and superseded by `vaultLocation`/
  `secondaryDestination`/`secondaryFolderBookmark` going forward.
