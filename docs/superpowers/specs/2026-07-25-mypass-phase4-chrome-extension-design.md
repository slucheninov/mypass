# MyPass — Phase 4 (Chrome): Design

## Goal and Context

- Phase 4 implements the Chrome browser extension (Manifest V3) with autofill
  for logins and saving new logins via MyPass. The Safari target and shared
  WebExtension layer are deliberately out of scope for this phase (future Phase 4b) —
  Chrome end-to-end is done first.
- References the general design: `docs/superpowers/specs/2026-07-21-mypass-design.md`
  (sections "Architecture and Components", "Security Model") — this spec
  details and refines what was stated there in a single line
  ("Extensions — shared JS, Safari target, Chrome host, IPC").
- The MyPass app is sandboxed (`com.apple.security.app-sandbox = true`), without
  an App Group. This is the key constraint that determined the IPC transport
  choice (see below).

## Components

- `ChromeExtension/` — MV3 extension: `manifest.json`, `background.js`
  (service worker), `content.js` (login form detection + autofill on
  user click), `popup.html`/`popup.js` (domain match list,
  entry selection, new-login save confirmation UI).
- `ChromeHost/` — native helper process (Swift Package executable target),
  not inside the app App Sandbox. Installed/registered by the main
  MyPass app via a native messaging host manifest
  (`~/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.mypass.chromehost.json`,
  with `allowed_origins` restricted to the extension ID). Communication with Chrome — via
  stdio, native messaging framing (4-byte little-endian length prefix + JSON
  UTF-8, max message size per Chrome spec — 1MB for messages from
  host to extension).
- New `ExtensionBridge` module inside `MyPass/` (app):
  `LoopbackServer` (based on Network.framework, listens on TCP at 127.0.0.1 on
  a random free port at app startup), `ExtensionBridgeService`
  (handles incoming requests, talks to VaultSession).

## IPC Transport and Rationale

Since ChromeHost is a process outside the sandboxed app bundle, direct Mach
XPC (`NSXPCListener`) would require a temporary-exception entitlement
(`com.apple.security.temporary-exception.mach-lookup.global-name`), which is fragile
and blocks possible future App Store distribution. Instead, a local loopback TCP socket was chosen:

- At app startup `LoopbackServer` binds to `127.0.0.1:<random
  port>`, a one-time authorization token is generated (cryptographically secure random,
  e.g. 32 bytes base64).
- Port and token are written to the app Keychain (same access group
  `com.mypass.app.keychain` already in use — see `MyPass.entitlements`)
  — the single trust point between processes.
- When ChromeHost receives a message from the extension, it reads port+token from the same
  Keychain access group (ChromeHost must be signed by the same development team/same Team ID to access the access group — an explicit
  requirement for code signing of both targets), opens a TCP connection to
  `127.0.0.1:<port>`, attaches the token to each request.
- `ExtensionBridgeService` rejects requests without a valid token. Port+token
  are regenerated on each app launch (not persistent across
  launches) — ChromeHost must re-read from Keychain on connection error/invalid token (retry once, then report error to
  extension).
- Residual risk: the loopback port is theoretically accessible to any local
  process of the same user (not only ChromeHost); without the token it would not
  pass validation, but an open port on 127.0.0.1 is a compromise for
  simplicity and App Sandbox compatibility. The alternative would be a Unix domain
  socket in an App Group (rejected in this phase as a more complex option, see
  "Rejected Alternatives" below).

## Data Flow: Autofill Existing Login

1. `content.js` finds a login form on the page (heuristics:
   `input[type=password]` + adjacent text/email input, or autocomplete
   attributes) → sends `{type: "getCredentials", url: <current tab URL>}` via `chrome.runtime.sendMessage` to `background.js`.
2. `background.js` keeps a persistent connection via
   `chrome.runtime.connectNative("com.mypass.chromehost")` (or opens
   a new one if needed) → forwards the JSON message over stdio to
   ChromeHost.
3. ChromeHost relays the request to the app over TCP (see transport above),
   adding the token.
4. `ExtensionBridgeService`: if `VaultSession.state == .locked` → responds
   `{status: "locked"}`. If unlocked → computes eTLD+1 domain from URL, finds
   entries with matching domain in the database, returns a list of
   `[{id, title, username}]` WITHOUT passwords at this step.
5. Response travels back the same path (app → ChromeHost →
   `background.js` → `popup.js`), popup shows the list; if locked —
   shows "Open MyPass and unlock".
6. User clicks an entry in popup → `background.js` sends
   `{type: "fillCredential", id: <entryId>, url}` over the same channel.
7. `ExtensionBridgeService` re-checks that the entry `id` domain
   matches the given `url` (spoofing protection), returns password (and
   TOTP code, if present) ONLY in response to this specific request.
8. `content.js` receives the password via `background.js`, verifies `origin`
   of the active tab against the expected domain again in the content script,
   fills form fields. NO autofill on simple page load —
   only on explicit user click in popup/UI.

## Data Flow: Save New Login

`content.js` listens for login/registration form submit events on the page.
If after a successful submit (heuristic: form submitted, no validation error
on the page, or URL changed) no matching entry was found for the page domain in the previously returned `getCredentials` list —
shows an unobtrusive banner "Save password in MyPass?" on the page.
User clicks "Save" → `content.js` sends
`{type: "proposeSaveLogin", url, username, password}` over the same channel
(`background.js` → ChromeHost → app). The app does NOT save
automatically: it activates the main MyPass window and opens the new-entry form
with prefilled title (domain)/username/password; the user
reviews, edits if needed, and confirms save inside
the app itself (using existing `VaultSession.mutate`). Password
is sent once, only on explicit user click on the banner (not
automatically on every submit); the banner can be dismissed/ignored.

## Security Model (Addition to General Design)

- Loopback server authorization token — one-time per app session,
  stored in Keychain access group accessible only to processes signed with
  the same Team ID.
- `ExtensionBridgeService` never returns a password in response to
  `getCredentials` (only id/title/username) — password only in response to
  explicit `fillCredential` for a specific id.
- Re-check of entry domain vs tab URL match both on the
  app side (step 7 above) and in `content.js` before fill —
  double protection against credential leak to wrong origin.
- ChromeHost and extension do not store passwords persistently — only in transit in
  process memory for the duration of one request.
- Native messaging manifest restricts `allowed_origins` to the specific extension
  ID — third-party extensions cannot reach ChromeHost.
- Locked vault: extension receives "locked" status, unlock
  happens only in the main app (never in the extension popup) —
  an established principle from the general design, preserved here.

## Errors and Edge Cases

- Chrome cannot start/reach ChromeHost (native messaging manifest not installed, or MyPass.app not installed) → popup shows a clear error "MyPass not found. Make sure the app is installed and
  launched once (to register the native messaging host)".
- App not running (LoopbackServer not up) → ChromeHost gets
  connection refused → reports `app_not_running` status to extension → popup:
  "Open the MyPass app".
- Token expired/invalid (e.g. app restarted, port+token
  changed) → `ExtensionBridgeService` responds with a 401-like error →
  ChromeHost re-reads Keychain (retry once) → if still invalid,
  reports error to extension.
- Vault locked during active popup session → next request
  returns "locked", popup updates UI.
- Multiple tabs/parallel requests to LoopbackServer — server must
  handle several simultaneous TCP connections (Network.framework
  `NWListener` supports this out of the box).

## Testing

- Unit tests (XCTest, Swift) for `ExtensionBridgeService`: entry matching
  by domain (eTLD+1, subdomains, exact and similar domains), behavior
  when locked/unlocked, rejection of requests with invalid/missing
  token, that `getCredentials` never returns a password.
- Unit tests for native messaging framing in ChromeHost (encoding/
  decoding 4-byte length prefix + JSON, handling messages at the
  size boundary).
- JS form-detection tests (`content.js`) on saved HTML fixtures
  from real login/registration sites (as in the general spec — a fixture set for
  regression testing heuristics).
- Manual e2e checklist: install unpacked extension in Chrome, launch
  MyPass.app, unlock vault, autofill on test page,
  save new login via banner, behavior with locked
  vault, behavior with app closed.

## Rejected Alternatives

- Unix domain socket in shared App Group container — rejected for this phase:
  requires adding `com.apple.security.application-groups` entitlement to
  both targets and solving socket file permission issues; loopback
  TCP+token provides equivalent security more simply.
- `NSXPCListener` with `temporary-exception.mach-lookup.global-name` entitlement —
  rejected: this entitlement class does not pass App Store review and
  is considered a deprecated Apple pattern; not suitable if the app
  ever goes to the Mac App Store.

## Scope Boundaries for This Phase (Explicitly Out of Scope)

- Safari App Extension and shared WebExtension JS layer — Phase 4b.
- Badge indicator for match count on extension icon — deferred, not
  in MVP.
- Password generator access from extension — deferred, not in MVP.
- TOTP copy-to-clipboard from extension without form fill — not in scope
  (TOTP is filled only as part of `fillCredential`, if a form field for
  it exists).
