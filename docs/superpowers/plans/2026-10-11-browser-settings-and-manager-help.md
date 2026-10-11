# Browser settings and manager help implementation

1. Add bounded diagnostics value types and two authenticated bridge requests.
2. Resolve report ownership from actual pairings and keep transient observable snapshots.
3. Make Settings → Browser the primary control/report surface and add a scrollable help sheet.
4. Connect popup Settings to a captured native settings action, including closed-window activation.
5. Simplify extension popup, retain browser-owned permission gesture, and report diagnostics.
6. Separate passkey confirmation entry/account details and preserve RP/origin visibility.
7. Correct Chromium-required creation response fields and test their CBOR/key consistency.
8. Run focused regression checks, full `./scripts/test.sh`, independent review and extension visual checks.
9. Verify the native settings window visually and complete real GitHub registration/sign-in separately.

The browser permission prompt and other managers' settings remain user-controlled.
Do not disable extensions or delete stored credentials automatically. Final roadmap
completion boxes require the full suite to pass; browser-profile verification is
recorded separately.

## Verified outcome — 2026-10-11

Steps 1–8 are implemented and verified by automated checks and independent review.
The full suite passed: 970 Swift tests reported, 23 skipped, 947 executed; all 21
registered JavaScript suites passed and all 21 passed an independent final rerun.
The popup was visually checked with normal and long text at 360 px without overflow;
the browser-check page was inspected at desktop size using mocked browser responses.
Native-window visual verification and real GitHub account registration/sign-in remain
open under step 9.

Registration completion now includes Chromium-required attestation response fields,
waits for the browser API acknowledgement before clearing the pending request, surfaces
completion failures, and prevents stale failures from overwriting a newer ceremony.
See the roadmap for exact test totals and local verification logs.
