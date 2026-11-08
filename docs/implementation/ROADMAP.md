# Roadmap — unfinished work

**Status file.** This lists only work that is still open. Remove an item once it is
implemented and its tests pass, or, for manual-only items, once the manual check has
actually been walked. History lives in `git log`, not here.

Last updated: 2026-10-27

---

## Remaining localization

- [ ] German for the app (String Catalogs in `MyPass/Resources/` already carry English,
      Ukrainian and Russian) and extension `_locales` for any language: the extension
      copy is still English only.

## Passkey AAGUID registry

MyPass now emits a stable AAGUID in attested credential data instead of all zeros. Showing
the name "MyPass" in Google's passkey UI depends on the community registry.

- [ ] Upstream registry PR submitted and merged (`passkey-authenticator-aaguids`). It needs
      a vector icon: the repository only has raster artwork, so the light and dark SVGs
      drafted for the submission are a hand-drawn re-creation of the key mark.
- [ ] Google shows "MyPass" for newly created passkeys. Manual check; depends on Google
      ingesting the registry.

## Entry history on save

- [ ] Snapshot the stored entry into its history when an editor saves, honouring the vault's
  `HistoryMaxItems` / `HistoryMaxSize`. Today edits made in the app replace the entry without a
  history copy, so a removed attachment or overwritten field cannot be restored after Save.

## Vault backups

- [ ] Per-vault backup folders. All vault stores share one container `backups/` folder, so
  after a location change or "Open Existing" the Backups list shows (and can restore)
  backups of a different vault, and one vault's saves prune the other's backups. Use a folder
  per vault identity (or tag files) and migrate the existing flat backups.
- [ ] Note drafts after a restore. Note drafts are keyed by vault path, so drafts written after
  the restored backup can be offered for recovery once the restored vault is unlocked. Decide
  whether to discard or flag them.
- [ ] Apply background sync merges locally. `VaultSession.persist(_:)` discards the
  `SyncResult.merged` database, so entries another device added reach the remote but only appear
  locally at the next unlock. Apply and publish the merged result without replacing newer local
  edits made while the sync ran.
