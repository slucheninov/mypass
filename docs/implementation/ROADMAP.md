# Roadmap — unfinished work

**Status file.** This lists only work that is still open. Remove an item once it is
implemented and its tests pass, or, for manual-only items, once the manual check has
actually been walked. History lives in `git log`, not here.

Last updated: 2026-10-27

---

## Public readiness and distribution

The repository was prepared for a public release (Apache-2.0 licence, third-party notices,
README / CONTRIBUTING, issue and pull request templates, `scripts/dev.sh`, CI workflow,
development packages). Local scripts and GitHub CI tests, packaging and both uploaded
artifacts are verified. The runtime behaviour of unsigned artifacts remains unverified.

- [ ] Record what actually happens when the unsigned, ad-hoc-sealed `dev.sh package`
      artifact is launched on a machine that never built it: whether the entitlement-less
      bundle starts at all, and how the Keychain-backed app-to-host exchange and Touch ID
      behave. Currently expected to be limited and untested. Signed runtime end-to-end
      behaviour is a separate manual check that CI cannot cover.

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

## Manual verification still owed

- [ ] Real native Browser settings window visual verification. Only mocked popup and
      browser-check page visual checks were done; no live native-window check has been
      performed.
- [ ] Installed extension ↔ real-vault address autofill. Covered by tests and by a popup
      with mocked bridge responses against a synthetic profile; never walked against a real
      vault with the installed extension.
- [ ] Single-instance launch behaviour: walk the single-instance checklist in `RUN.md`
      (the section on running one MyPass at a time) against a real profile, including the
      visual saving overlay and the signed-Keychain boundary.

## Deferred follow-ups

- [ ] Remove the "TEMPORARY diagnostic detail" at `MyPass/UI/Settings/SecuritySettingsPane.swift:251`
      (the raw Swift error shown in the enable-device-unlock alert) once the real-device
      Keychain failure it was added for is root-caused.
