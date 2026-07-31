# Vault Location — Move, Sync, and Open Existing

Follow-up to [2026-07-30-unified-vault-location-design.md](./2026-07-30-unified-vault-location-design.md). Fixes four concrete bugs in the shipped unified vault location work without changing the overall Local / iCloud primary model.

## Problem

Four issues with unified vault location:

1. **Copy instead of move** — Switching Local ↔ iCloud copies the vault file instead of moving it. Settings shows only a location label ("Local File" / "iCloud Drive"), not the resolved path to `vault.kdbx`.
2. **Nested MyPass folder** — Choosing an iCloud folder named e.g. `mypass` creates `mypass/MyPass/vault.kdbx` because the guard uses case-sensitive `== "MyPass"`.
3. **iCloud write churn** — The primary iCloud vault is constantly rewritten. Remote change notifications and the 300s timer push in-memory state without comparing serialized content, causing cross-device churn and "file busy" on other Macs.
4. **Open Existing stub** — "Open Existing .kdbx" passes an empty password and does not import or retarget primary storage. It must prompt for the master password, become the new primary vault, and load vault contents into the session.

## Approach

**Approach 1 (chosen):** Local = Application Support **or** file bookmark (`LocalFileVaultStore`) plus a targeted sync fix. Keep iCloud as folder bookmark + `vault.kdbx`. Do **not** migrate to an always-file-bookmark model (Approach 2) or copy-to-App-Support Open Existing (Approach 3).

## Decisions (locked)

- **Move, not copy** — Local ↔ iCloud deletes the source vault file after a verified successful write to the destination.
- **Path in Settings** — Show the resolved absolute path to `vault.kdbx`.
- **Open Existing** — Selected file becomes the new primary at its path; `vaultLocation = local`. User can Move to iCloud later.
- **Open Existing cleanup** — Delete the old primary only if it was the default Application Support vault (no `localVaultFileBookmark`). Do **not** delete a previous iCloud primary or other bookmarked local file.
- **Multi-device** — Last-write-wins (LWW). Write only when serialized bytes actually change. On remote change: coordinated read; if content differs, replace in-memory DB (do not push). No entry-level merge on the primary store.
- **Nested MyPass** — Case-insensitive name check when deciding whether to create a `MyPass` subdirectory.

## Data model

### `VaultLocationOption`

Unchanged: `.local` | `.iCloudDrive`.

### Local primary (two modes behind `.local`)

| Mode | Store | Persistence |
|------|-------|-------------|
| Default | `VaultFileStore` → `~/Library/Application Support/MyPass/vault.kdbx` | `vaultLocation = local`; no file bookmark |
| Opened file | `LocalFileVaultStore` — security-scoped bookmark on the `.kdbx` file | `vaultLocation = local` + UserDefaults key e.g. `localVaultFileBookmark` |

### iCloud primary

Existing folder bookmark `syncICloudFolderBookmark` (pinned key — do not rename) + `relativePath = vault.kdbx`.

**Folder picker rule:** If the last path component equals `MyPass` case-insensitively **or** `vault.kdbx` already exists at the picked folder root, use that folder as-is. Otherwise create a `MyPass` subdirectory inside the picked folder.

### Settings UI

`VaultLocationSettingsPane` shows the location label plus a caption with the resolved absolute path to `vault.kdbx`. When iCloud falls back to local (stale bookmark), show the local path and the existing fallback warning as today.

### Primary store resolver

- `local` + valid file bookmark → `LocalFileVaultStore`
- `local` without file bookmark → Application Support `VaultFileStore`
- `iCloudDrive` → existing `ICloudDriveVaultStore` with fallback to local when the bookmark is stale

## Move flow (Local ↔ iCloud)

After master password confirmation and probe/strategy selection (existing `VaultLocationChangeSheet` flow):

1. Write the vault to the destination per the chosen strategy (seed / overwrite / merge / adopt).
2. Verify the destination opens with the same master password.
3. Delete the source vault file (Application Support `vault.kdbx`, bookmarked local file, or iCloud `vault.kdbx`).
4. Swap primary store and UserDefaults (`vaultLocation`, bookmarks); clear source bookmark keys as appropriate.
5. UI wording: **Move**, not copy.

**Failure handling:**

- Any failure before step 2 succeeds — leave the source untouched; do not change `vaultLocation` or bookmarks.
- Write and verify succeed but source delete (step 3) fails — still complete step 4 so the destination becomes primary; show a warning that an old copy remains at the source path.

## Open Existing .kdbx

Entry point: existing "Open Existing .kdbx" control (e.g. `EntryListView`); minimum scope is replacing the current stub. Prefer availability from the lock screen as well when practical.

1. `NSOpenPanel` filtered to `.kdbx`.
2. Master password prompt.
3. `KdbxDatabase.open` — on failure, show an alert (not a beep only).
4. Create a security-scoped bookmark on the chosen file.
5. If the current primary is default Application Support (no `localVaultFileBookmark`): delete `Application Support/MyPass/vault.kdbx` after successful open.
6. If the current primary is a bookmarked local file or iCloud: do **not** delete the old file; only retarget primary storage.
7. Set `vaultLocation = local`, save `localVaultFileBookmark`, `updatePrimaryStore(LocalFileVaultStore)`, load the opened database into the session (entries/groups immediately available).

App-level settings remain in UserDefaults/Keychain. "Settings in the file" means vault database contents (groups and entries), not app preferences.

## Multi-device LWW sync (primary iCloud)

**Current bug:** `onRemoteChange` and the 300s timer call `triggerBackgroundSync` → `persist`, pushing in-memory state without reading remote content or comparing bytes — a write loop across Macs.

**Target behavior:**

| Event | Action |
|-------|--------|
| Local mutation | Persist as today, but **skip write** if serialized bytes equal the last successfully written bytes (or matching content hash) |
| `presentedItemDidChange` / remote change | Do **not** push. Coordinated read; if bytes/hash match last-known — no-op; else open with current password → replace in-memory DB (remote wins, LWW) → update last-known hash/mtime |
| 300s timer | Run only if there are dirty local changes since the last successful write; otherwise no-op |
| `touchAccess` | Keep debounce; write only if serialized bytes actually changed |

**Conflict versions:** On primary remote reload, if `NSFileVersion` conflicts exist — take the newest version (LWW), not entry merge. Entry merge remains for the **secondary** `SyncEngine` only when a secondary destination is enabled.

**Local stores (App Support / file bookmark):** No `NSFilePresenter` loop, but skip-identical-bytes still applies to avoid unnecessary KDF writes.

**Guarantee:** Two Macs can work with the same iCloud vault; edits from another device appear after sync. Simultaneous edits on both devices — last remote write wins; the losing Mac may lose in-flight edits (accepted LWW trade-off).

## Error handling

Reuse existing error types and messages where possible (`VaultMigrationError`, `ICloudBackendError`, sync migration sheet copy). Additional rules:

- **Move — failure before verified write:** Do not touch source; show the error; do not change `vaultLocation` or bookmarks.
- **Move — write OK, delete source fails:** Still swap to destination as primary; warn that an old copy remains at the source path.
- **Open Existing — wrong password or invalid format:** Alert; session and bookmarks unchanged.
- **Open Existing — bookmark creation fails:** Do not delete the Application Support vault.
- **iCloud remote reload — wrong password or corrupt file:** Do not wipe in-memory DB; show a non-blocking error; do not write back to iCloud.
- **Path display — stale bookmark:** Show "Path unavailable" plus the existing iCloud fallback warning.

## Testing

Minimum automated and manual coverage:

- **`chooseFolder`:** Picked folder named `mypass`, `MYPASS`, or `MyPass` — no second nested `MyPass` level; `vault.kdbx` at picked root is used as-is.
- **Migration move:** After seed/overwrite, source file absent and destination file present.
- **Open Existing:** File bookmark saved; `vaultLocation = local`; Application Support vault deleted only in the default-local case (not when retargeting from iCloud or bookmarked local).
- **Persist skip:** Identical serialized bytes → underlying `write` not invoked.
- **Remote change:** Newer remote bytes → session DB replaced; identical remote bytes → no write.
- **Resolver:** `local` + valid file bookmark → `LocalFileVaultStore`; `local` without bookmark → Application Support.

Manual: Move Local ↔ iCloud shows path in Settings; multi-Mac iCloud edit without constant file churn; Open Existing loads entries after password prompt.

## Out of scope

- KeePassXC 32-byte salt compatibility work.
- True entry-level merge on the primary store.
- Changing secondary `SyncEngine` rewrite semantics beyond fixing primary churn.

## Key files (for implementers)

- `VaultLocationChangeSheet`
- `VaultLocationSettingsPane`
- `VaultMigrationService`
- `VaultSession`
- `VaultPrimaryStoreResolver`
- `ICloudDriveVaultStore`
- `EntryListView` (Open Existing)
- New `LocalFileVaultStore`
- SyncKit `iCloudBackend` (as needed for remote reload / skip-write)
- Unit tests following existing patterns (e.g. `SettingsViewSyncBackendTests`)
