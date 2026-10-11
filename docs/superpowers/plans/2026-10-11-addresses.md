# Address entries implementation plan

Reference: [Address design](../specs/2026-10-11-addresses-design.md).

- [x] Add the Address type and protected KDBX field mapping, preserving entry identity and unrelated fields.
- [x] Add native category/count/search, create/edit/detail views, country picker, and menu bar display.
- [x] Add the typed fillAddress bridge request/response and paired/unlocked/live-entry/destination checks.
- [x] Add extension category and explicit document-bound address-form selection/filling.
- [x] Cover model persistence, authorization, scoped form discovery, and routing with regression tests.
- [x] Add a manual shipping/billing fixture and run the full test suite.
- [x] Review the final integration and record precise validation boundaries.

Creation and editing are native. The old extension createEntry payload does not support addresses and must reject that type explicitly rather than silently creating an incomplete entry.

## Verification evidence

- Native focused test selection: 127 passed; final incremental address/model/activity selection: 6 passed.
- ExtensionBridgeKit: 76 tests, 2 skipped, zero failures.
- Address browser suites cover detection, relay authorization/document routing, and popup selection.
- Actual helper in a synthetic browser fixture: shipping six fields and billing four fields filled independently; hidden/login/ambiguous fields and fields lacking a saved value remained unchanged.
- Popup preview at 360 × 600 used mocked bridge responses to check form selection, acknowledgement, and layout. This was not an installed-extension/native-vault end-to-end test.
- The installed extension's address flow against a real vault and third-party forms remains unverified. Supported filling is limited to annotated native controls in the top document; users must review partial fills if a website rebuilds its form.

Usage: native **+ / Add → Address**, then browser extension **Addresses → entry → form**. The destination hostname is shown before the final form confirmation. A unique focused group may narrow the form choices. No automatic submission or address capture occurs.

## Final integrated gate

`./scripts/test.sh` passed: 986 Swift test cases (963 passed, 23 skipped, zero failures) and all 25 JavaScript suites. `./scripts/build-all.sh` successfully built both MyPass and ChromeHost. `git diff --check` passed. Logs: `/tmp/mypass-final-addresses-test.log` and `/tmp/mypass-final-addresses-build.log`.

These results complete the implementation and automated verification tasks above. Installed-extension ↔ real-vault end-to-end address filling remains unverified; the browser evidence uses a synthetic profile and mocked popup bridge responses.
