# Passkey discovery and provider diagnostics

Date: 2026-10-11

## Problem

Passkeys already live on vault entries, but neither the app nor the extension has a
Passkeys category. The extension reports the app's enabled setting without reporting
whether Chrome accepted its WebAuthn proxy attachment. A competing extension can
therefore prevent registration and sign-in with no visible explanation. Starting the
worker while the app is locked or unavailable can also leave interception inactive
after the app becomes available.

The GitHub login page offers a "Sign in with a passkey" action. A saved credential
badge and the site's ability to start WebAuthn are different facts. MyPass must explain
how to start that action and report its own readiness rather than promise sign-in from
a password-fill row.

## Behavior

- Add Passkeys to the app sidebar and extension category menu. Include entries with
  both nonempty, decodable credential IDs and nonempty private-key fields, regardless
  of whether a password is also present. Exclude recycle-bin and generator-history
  records using the existing browse boundaries. The count and list share a predicate.
- Keep the existing entry-detail passkey section and popup credential badges. Use the
  same predicate for app categories and bridge summaries. This predicate checks stored
  field presence; actual key parsing and cryptographic validation remain in ceremonies.
- Separate the app's enabled preference from actual proxy attachment and readiness.
  Distinguish disabled, locked, unavailable/unpaired, attached, and attachment failure.
  Surface failure in the popup instead of logging it only to the service-worker console.
- Reconcile attachment after startup and on appropriate refresh/retry events. The app
  remains authoritative. Polling must never unlock the vault or reset its idle timer.
  Preserve synchronous proxy listener registration and serialize attachment updates.
- Show actionable warnings for observable conflicts. Chrome's password-saving setting
  can be inspected separately from enabled extensions that may provide passwords or
  passkeys. Never automatically disable another extension or change browser settings.
- Treat password saving as password saving, not evidence that Chrome's passkey provider
  is disabled. Extension enumeration cannot verify all native or OS-level providers.
  Missing permissions or unsupported APIs must report limited/unknown diagnostics.
- Explain that users start sign-in or registration with the site's passkey action and
  then confirm in MyPass. Do not synthesize page clicks or bypass WebAuthn origin checks.
- Repair confirmation fallback when Chrome cannot open the popup: use permitted,
  guarded notifications and/or an action badge, keeping the pending ceremony accessible.

## Registration exclusions

Parse `excludeCredentials` from Chrome's JSON payload and compare decoded credential
IDs, scoped to the same relying party. Unsupported credential types cannot identify
MyPass public-key records; malformed descriptors must not silently erase exclusions.
Before key generation or vault mutation, recheck the current vault at confirmation and
return `InvalidStateError` if a live credential is excluded. Even an entry with URI
matching disabled remains owned by this authenticator for the exclusion check.

The refusal happens after the user's Save/Replace confirmation. Returning this error
on the page-triggered request would disclose credential presence without consent.
WebAuthn requires that consent before disclosing an exclusion match; see
[authenticatorMakeCredential](https://www.w3.org/TR/webauthn-3/#sctn-op-make-cred).
Existing keys and passwords remain unchanged on refusal, and the pending request is
consumed so it cannot be retried to bypass the exclusion.

## Boundaries

This change does not scrape private keys created by another manager. Registration is
captured through the attached WebAuthn proxy, not inferred from page text. A successful
proxy attachment suspends Chrome's normal WebAuthn handling, but does not prove that
all third-party page injectors or system providers have been disabled. Documentation:
[Chrome WebAuthn proxy](https://developer.chrome.com/docs/extensions/reference/api/webAuthenticationProxy),
[Chrome privacy settings](https://developer.chrome.com/docs/extensions/reference/api/privacy),
[Chrome extension management](https://developer.chrome.com/docs/extensions/reference/api/management).

No credential is created in a real account merely to validate this change. Automated
coverage and fixture checks must be reported separately from authenticated GitHub
registration/sign-in, which requires a correctly loaded extension and an account.

## Verification

Cover category contents/counts, passwordless and mixed entries, malformed/incomplete
fields, nested recycle-bin entries, generator history, authorization/locked browsing,
and consistent bridge badges. Cover exclusion decoding, unknown types, malformed
descriptors, consent timing, same-RP refusal, other-RP acceptance and changes while
confirmation is open. Cover proxy lifecycle, attachment conflict, retries, diagnostics
permission limits, and notification failures in extension tests. Run the full repository
suite before marking roadmap work complete; retain explicit manual browser limitations.
