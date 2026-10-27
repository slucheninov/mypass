# Roadmap — unfinished work

**Status file.** This lists only work that is still open. Remove an item once it is
implemented and its tests pass, or, for manual-only items, once the manual check has
actually been walked. History lives in `git log`, not here.

Last updated: 2026-10-27

---

## Runtime localization

- [ ] Runtime localization for English, Ukrainian and German. The design is approved but
      nothing is implemented: the app has no `.lproj` string tables and the extension has
      no `_locales`, so all UI strings and extension copy are English only.

## Passkey AAGUID registry

MyPass now emits a stable AAGUID in attested credential data instead of all zeros. Showing
the name "MyPass" in Google's passkey UI depends on the community registry.

- [ ] Upstream registry PR submitted and merged (`passkey-authenticator-aaguids`). It needs
      a vector icon: the repository only has raster artwork, so the light and dark SVGs
      drafted for the submission are a hand-drawn re-creation of the key mark.
- [ ] Google shows "MyPass" for newly created passkeys. Manual check; depends on Google
      ingesting the registry.
