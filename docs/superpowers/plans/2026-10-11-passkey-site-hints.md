# Passkey site hints implementation plan

1. [x] Verify official documentation and bundle a small exact-host support catalog.
2. [x] Gate only the popup's disabled-passkey message by current-site relevance.
3. [x] Preserve all authentication and credential matching boundaries.
4. [x] Cover host boundaries, saved-passkey fallback and asynchronous popup changes.
5. [x] Run targeted extension tests, then the full repository suite with the integrated changes.

## Validation completed on 2026-10-11

- Targeted passkey hints, popup, favorites, script-scope, fallback and browser-settings suites passed.
- Full `./scripts/test.sh` passed: 986 Swift cases total, comprising 963 passed and
  23 skipped, with no failures; all 25 JavaScript suites passed.
- `./scripts/build-all.sh` built both MyPass and ChromeHost successfully.
- `git diff --check` passed. Review found no remaining actionable issues in the
  passkey hint implementation; the catalog is used only by popup presentation.
- Test log: `/tmp/mypass-final-addresses-test.log`.
- Build log: `/tmp/mypass-final-addresses-build.log`.

The final gate included the concurrently implemented address feature. It did not
install, launch or restart the app or native host. Hosted XCTest's existing bridge
isolation guard remained intact and its tests passed. No live passkey ceremony or
external-site account eligibility was asserted by this validation.
