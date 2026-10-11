# Browser settings and manager help

## Problem

The extension repeats generic passkey readiness and unchecked-manager messages in a
small popup. Configuration belongs in MyPass Settings, and users need concrete steps
for Google Password Manager, iCloud Passwords and 1Password. A registration confirmation
also needs readable entry/account/site details rather than one long wrapped sentence.

## Behavior

Settings → Browser owns the existing canonical passkey preference, explains the next
step, shows per-pairing last browser reports, and presents a scrollable manager-help
sheet. Reports explicitly describe a past observation and display app receipt time.
The extension provides a compact status, opens native settings, and retains the
browser-owned permission action named Check this browser. Optional permissions are
requested from a direct browser user gesture; native settings cannot grant them.

Help provides copyable Chrome settings addresses, extension-disable steps, official
sources, and optional macOS AutoFill guidance distinguished from Chrome settings.
Disabling a manager does not delete credentials. Browser password saving off does not
prove every autofill or passkey provider is disabled.

## Protocol and trust

Authenticated `openBrowserSettings` opens the Browser pane, including with the main
window closed. Authenticated `reportBrowserDiagnostics` carries proxy state, permission
state, optional password-saving observation, extension-scan state, and bounded manager
names. The app derives browser identity from the pairing secret and supplies receipt
time. Neither request resets idle auto-lock; both can be served while locked because
neither exposes vault contents. Reports are transient and never store pairing secrets.
Revoked pairings cannot submit reports or open settings.

Unknown permissions/API failures stay distinct from denied permissions and successful
empty results. No report establishes exclusive control over every password manager.
The app preference remains authoritative even when a delayed report differs.

## Registration response correction

Chromium's actual create-response parser requires `publicKeyAlgorithm`,
`authenticatorData`, and, for ES256, DER SPKI `publicKey` in the response. These must
match the attestation CBOR object. Omitting them lets local saving occur before Chrome
rejects completion, leaving the website waiting. The native response includes all
three, tested against the same key and encoded attestation. Local storage alone is
not website registration success. The extension clears pending ceremony state only
after the browser completion API acknowledges success. Completion failures are shown
to the user, and a delayed failure from an older ceremony cannot replace the state of
a newer request.

## Verification boundary

Focused protocol and native tests cover authenticated ownership, locked behavior,
revocation, validation, no idle timer reset, unknown-state presentation, and create
response consistency. The complete repository suite and independent review passed on
2026-10-11: 970 Swift tests reported, 23 skipped, 947 executed, and 21 JavaScript suites
passed. All 21 JavaScript suites also passed an independent final rerun.

Mocked extension visual checks covered normal and long popup content at 360 px with
no overflow, plus the browser-check page at desktop size. The real native settings
window was not visually verified. Real GitHub registration/sign-in remains a separate
browser-profile check; automated fixtures do not establish it.
