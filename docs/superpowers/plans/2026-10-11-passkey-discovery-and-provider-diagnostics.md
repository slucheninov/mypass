# Passkey discovery and provider diagnostics plan

Date: 2026-10-11

Design: [Passkey discovery and provider diagnostics](../specs/2026-10-11-passkey-discovery-and-provider-diagnostics-design.md)

The working tree already contains extension browsing, generator/history and shared
module changes. Preserve them and add scoped changes on top. No generated Xcode project
edits, signing changes, commits or publication are part of this plan.

## Implementation sequence

1. Add the app `passkeys` smart category, filter and count. Route bridge
   `listEntries(category: "passkeys")` and align summary metadata with `hasPasskey`.
   Harden that predicate for empty IDs/keys; preserve dedicated entry detail UI.
2. Add category regressions for passwordless and mixed entries, malformed fields,
   trash/history, count/list agreement and bridge authorization boundaries.
3. Parse WebAuthn registration exclusions. At explicit confirmation, check live
   same-RP credentials before any vault mutation and return `InvalidStateError` on a
   match. Test consent privacy, byte-normalized IDs, malformed data, preserved keys,
   different relying parties and credentials arriving during the pending prompt.
4. Add extension proxy lifecycle health independent from the app-enabled preference.
   Serialize reconciliation, retry eligible attachment, handle conflict errors and
   preserve fail-closed origin, pairing and lock behavior.
5. Add extension diagnostics for observable browser password-saving settings and
   enabled potential provider extensions. Show precise warnings/settings instructions with
   unknown/unsupported states; never auto-disable or assert global exclusivity.
6. Add extension Passkeys category and site-action guidance. Repair popup/notification
   fallback and test both successful and unavailable API paths.
7. Review the combined diff for private-key leakage, origin/RP checks, trusted UI
   actions, stale attachment state, permission failures and preserved user changes.
8. Run `./scripts/test.sh` after all edits. Record exact results and any environment
   limitations. Update the single status tracker only when implementation and tests
   pass. A GitHub page inspection is not an authenticated registration/sign-in test.

## Checks

- App: `SmartCategoryTests`, `PasskeyCategoryTests`, `ExtensionBridgeServiceTests`,
  `PasskeyCeremonyTests`, plus existing full-suite regressions.
- Extension: category browsing, proxy attach conflict and recovery, app lock/unlock,
  disabled state, service-worker restart, notification API absence/rejection, manager
  diagnostics without permission and unsupported browser APIs.
- Manual: open GitHub login with an unlocked, paired MyPass; confirm readiness then
  start the site's passkey action. Use local WebAuthn fixtures to exercise create/get,
  cancellation and competing-provider diagnostics where browser access permits.
- Required final suite: `./scripts/test.sh`; formatting: `git diff --check`.

Status is tracked only in `docs/implementation/ROADMAP.md`.

## Verification record and remaining manual work

The full repository script passed on 2026-10-11: 964 Swift tests reported, including
23 skips (941 executed), and all 20 standalone JavaScript test files. The temporary
full-run log is `/tmp/mypass-final-20261011-102429.log`.

Review found three additional popup issues: an already-open popup needed live pending
state hydration; Passkeys category rows must open the site without password autofill;
and only the background worker may remove pending ceremony state. After those fixes,
independent review approved the changes and all 20 JavaScript test files passed again
(`/tmp/mypass-final-node-20261011.log`). Swift code did not change after its passing
full-suite run. `git diff --check` also passed.

Authenticated GitHub registration/sign-in and live competing-manager checks remain
manual work. Public page inspection and fixture/mocked tests do not establish success
in the installed browser profile. Conditional mediation/autofill UI remains unsupported
by this change; the explicit site passkey action is the supported entry point. Browser
diagnostics cannot prove that all OS/native providers and unknown managers are disabled.
