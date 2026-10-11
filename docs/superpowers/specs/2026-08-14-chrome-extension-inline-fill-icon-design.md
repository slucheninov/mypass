# Chrome Extension — Inline Fill Icon in Form Fields

Status: approved 2026-08-14.

Follow-up to [2026-07-25-mypass-phase4-chrome-extension-design.md](./2026-07-25-mypass-phase4-chrome-extension-design.md),
[2026-08-01-chrome-extension-totp-autofill-design.md](./2026-08-01-chrome-extension-totp-autofill-design.md)
and [2026-08-07-chrome-extension-unlock-from-popup-design.md](./2026-08-07-chrome-extension-unlock-from-popup-design.md).

## Problem

Filling a credential today costs four actions: click the toolbar icon, wait for the popup
to resolve `getCredentials`, find the entry, click it. The popup is a separate surface
from the form the user is looking at, and it closes on any focus change.

Every mainstream password manager solves this with an affordance rendered inside the field
itself. MyPass has all the machinery for it already — field detection
(`scoreUsernameLikeness`, `scoreOtpLikeness`), a domain-scoped credential list fetched at
page load (`state.lastCredentialList`), and a hardened fill path (`fillCredential` →
`relayFillToActiveTab` → `applyFill`). What is missing is the entry point.

## Goals

- A key glyph inside recognised login, password and OTP fields, matching the app's menu-bar
  `key.fill` symbol.
- One trusted click opens a panel listing this domain's entries; one more fills only the
  field whose icon was clicked.
- No new channel for secrets: reuse `fillCredential` byte-for-byte as the popup sends it.
- No mutation of the host page's layout.
- Page scripts cannot read the panel, style it, or trigger a fill.

## Non-goals

- **Forms inside iframes.** Requires `all_frames: true`, which injects the content script
  into every ad and tracking frame on every page. That is a separate decision with its own
  cost; see "Rejected alternatives". **Reversed 2026-08-15**: the motivating case — a
  third-party sign-in widget — is cross-origin by definition, so deferring left the actual
  target case broken. See
  [2026-08-15-chrome-extension-inline-icon-iframes-design.md](./2026-08-15-chrome-extension-inline-icon-iframes-design.md)
  for the frame-gating design that lets `all_frames: true` ship without widening the banner
  or QR-detection surface. The reasoning above for deferring was correct at the time; it was
  the coverage gap, not the cost, that shifted.
- **A settings toggle.** Not requested. The icon is inert until clicked, and pairing already
  expresses consent. Revisit if the icon proves intrusive in the manual walk.
- **Changing the padding or geometry of the site's own inputs.** See "Positioning".
- **Filling without an explicit click.** No auto-fill on page load, ever — the constraint
  from the phase-4 design stands unchanged.
- **A new native-messaging request, or any Swift change.** This stage is extension-only.
- **Replacing the popup's fill flow.** Both entry points coexist.

## Design

### Trust model

The inline icon changes *where the user clicks*, not *what crosses the boundary*. The
message the content script sends on entry selection is the same `{type: 'fillCredential',
id, url}` the popup sends today. Consequently:

- The app still resolves the entry and returns the secret to `background.js`.
- `relayFillToActiveTab` still re-checks that the active tab's origin matches the request
  origin before the secret is delivered.
- `content.js`'s `applyFill` handler still re-checks `hostnameMatches` on receipt.
- `stripSecretsFromResponse` still applies to whatever is handed back to the requesting UI.

The credential list the panel renders is the one already in `state.lastCredentialList`:
summaries only (`id`, `title`, `username`, `hasTotp`, `hasPasskey`). **No secret is ever
held by the panel.** The password exists in the page process only inside `applyFill`, for
exactly as long as it takes to assign it to the input — which is already true today.

### What is genuinely new: the page can see and click our UI

The banner surfaces added in Stage 5 are transient and appear only after a user action.
An always-present in-field control is different: it sits in the DOM for the lifetime of the
page, and a hostile page can dispatch a synthetic `click` at it.

Two mitigations, both mandatory:

1. **`event.isTrusted` on every handler.** Opening the panel, selecting an entry, and the
   unlock button all require a user-generated event. A synthetic click is ignored silently.
   This closes the item parked in the roadmap's Decisions table
   ("`event.isTrusted` on banner buttons") for the new surface, and the same guard should be
   applied to the two existing banners while we are here.
2. **Closed shadow DOM.** `attachShadow({mode: 'closed'})` gives no `.shadowRoot` handle to
   page scripts, so the panel's contents — including the entry titles and usernames — are
   not readable by the page, and the page's CSS cannot restyle it.

Note that the host element itself remains detectable, as any injected node is. This is
accepted deliberately: because the icon renders on *every* recognised field regardless of
whether matches exist, its presence tells the page nothing about the user's vault. Making
visibility conditional on having a match would leak "this user has an account here" to the
site and hand it a fingerprinting signal. That trade is the reason for the always-visible
rule, and it must not be "optimised" away later.

### Positioning

The icon must not change how the page lays out. Two rejected shapes and the chosen one:

- *Wrap the input in a positioned container* — reparents a node the site's own scripts may
  hold references to, and changes the box model. Breaks real sites.
- *Add right padding to the input* — what most managers do, and what visually reads best,
  but it is still a mutation of the site's element and fights sites that recompute style.
- **Chosen: an absolutely-positioned host in `document.body`**, placed from the input's
  `getBoundingClientRect()`. The input is never touched.

Sync sources, all coalesced through one `requestAnimationFrame`:

| Source | Why |
|---|---|
| `scroll` (capture, passive) | scroll containers other than the window |
| `resize` | viewport reflow |
| `ResizeObserver` on the input | the field itself changing size |
| `IntersectionObserver` on the input | hide when the field leaves the viewport |
| existing `MutationObserver` | fields added by SPA navigation |

Updated 2026-10-11: the icon keeps a 6px inset from the actual input edge. It reserves
the measured bounds of overlapping buttons and links within the field's wrapper, keeping
show-password and clear controls usable without mutating the input. The target is at most
28px square, shrinks to fit compact fields, and is hidden when fewer than 36px remain for
typing or the target would be smaller than 20px. The toolbar popup remains available.
Controls outside that wrapper and browser-native decorations cannot all be detected.
The full button must fit inside the viewport and every ancestor overflow clip, checked per
axis; scrolling a field outside its container hides the overlay until it fits again.

### Field recognition

`findLoginForm()` today requires `input[type=password]` **and** that it sit inside a
`<form>`. Both are too strict for the sites this feature exists to serve — SPA login
screens frequently have neither, and identifier-first flows show a username field with no
password field on the page at all.

The rework introduces `findFillableFields(root)` returning a list of
`{ input, kind }` where `kind ∈ {username, password, otp}`:

- **password** — every visible `input[type=password]`, `<form>` or not.
- **username** — the best `scoreUsernameLikeness` candidate, scoped to the password field's
  form when there is one and to the document otherwise. Also emitted when no password field
  exists, so identifier-first pages get an icon.
- **otp** — `findOtpField`, unchanged, including its `MIN_OTP_FIELD_SCORE` threshold.

`findLoginForm` stays for `applyFill`'s existing behaviour, reimplemented on top of
`findFillableFields` so the two cannot drift apart.

Fields that are `disabled`, `readonly`, or not rendered (`offsetParent === null`) get no
icon, mirroring `scoreOtpLikeness`'s existing exclusions.

### Panel contents

Panel state is a function of connection state, not of which field was clicked. Routing is
extracted into a pure `chooseInlinePanel(state)` — the same shape as Stage 6's
`choosePasskeyPanel(pending)`, and for the same reason: it makes the decision testable
without a DOM.

| State | Panel |
|---|---|
| unlocked, matches exist | entry rows: title, username, 2FA/passkey badges |
| unlocked, no matches | "No entries for this site" |
| locked | "MyPass is locked" + **Unlock MyPass**, reusing `requestUnlock` from Stage 3 |
| pairing required | pairing hint, no action — mirrors the popup |
| app unavailable / error | "MyPass is not running" |

On a field of kind `otp`, the entry list is filtered to `hasTotp` entries. A `credentialList`
whose every entry lacks TOTP therefore renders the empty state on an OTP field while still
rendering rows on a password field — the same list, filtered per field kind.

The list is refreshed from `state.lastCredentialList` at open time. If the vault was locked
at page load and has since been unlocked, opening the panel re-issues `getCredentials`
rather than showing a stale locked panel.

### Fill

Selecting a row sends `{type: 'fillCredential', id, url: location.href}` — identical to
popup.js:617. `background.js` needs no change: `fillCredential` is already in its known-type
allowlist, and `relayFillToActiveTab` already routes the result to the active tab's content
script as an `applyFill` message, which the existing handler consumes.

`relayFillToActiveTab` resolves the target through `chrome.tabs.query({active: true})`
rather than `sender.tab.id`. That remains correct here: a trusted click is only possible in
a tab the user is looking at, so the active tab *is* the originating tab. The `isTrusted`
gate is what makes this hold, which is a second reason it is mandatory rather than
defensive.

### Icon asset

`web_accessible_resources` is unset in the manifest, so `icons/*.png` cannot be referenced
from a page-injected element. Rather than declare them — which would widen what any page can
probe for — the key glyph is an **inline SVG path** built in the shadow root. It is drawn to
match the extension's upright green MyPass key (`icons/icon128.png`), with its round head,
hole and right-facing teeth. Updated 2026-10-11: the visible mark is up to 24px high in a
28px target, with a transparent idle background, subtle green hover surface, and explicit
keyboard focus ring. Compact fields scale the mark down with the target. High-contrast
mode uses system colors. `inline-icon-layout.html` covers large, compact, tiny, dark and
reveal-button layouts, including hostile page CSS.

## Files touched

| File | Change |
|---|---|
| `ChromeExtension/content.js` | `findFillableFields`, `chooseInlinePanel`, icon + panel rendering, observers, `isTrusted` guards; `findLoginForm` reimplemented on the new finder |
| `ChromeExtension/tests/inlineIcon.test.js` | new suite |
| `scripts/test.sh` | wire the new suite (line 29–39 block) |
| `RUN.md` | manual checklist bullets (Ukrainian) |
| `docs/implementation/ROADMAP.md` | new stage entry |

`background.js`, `popup.js`, `manifest.json` and all Swift are unchanged. If any of them
turns out to need a change, that is a signal the design was wrong — stop and revisit.

`content.js` is 469 lines today and this adds materially to it. The icon/panel code goes
behind a clear section boundary with its own exports; if it passes roughly 250 lines it
should be split into `ChromeExtension/inline-fill.js` loaded ahead of `content.js` in the
same content-script entry, the way `vendor/jsQR.js` already is.

## Acceptance criteria

1. A key icon appears in recognised username, password and OTP fields on a page with no
   `<form>` element.
2. The icon appears whether or not the domain has matches, and whether or not the vault is
   unlocked.
3. Clicking the icon opens the panel; clicking outside or pressing Escape closes it.
4. Selecting an entry fills only the field whose icon was clicked — the password icon fills
   password only, the username icon fills username only, the OTP icon fills the TOTP code
   only. (Reversed during the manual walk on 2026-08-14: the original criterion filled
   username, password and TOTP together from a single click. Deliberately traded one-click
   sign-in for precision — see "Deliberate reversal" below.)
5. A synthetic `click` dispatched by page script neither opens the panel nor fills anything.
6. Page CSS (`* { display: none !important }`, aggressive `z-index`) does not disturb the
   icon or panel.
7. The panel on an OTP field lists only entries with `hasTotp`.
8. Locked vault shows the unlock panel; unlocking and reopening shows entries without a
   page reload.
9. Scrolling, resizing and SPA navigation keep the icon aligned to its field.
10. The site's own input elements are not mutated: no added padding, no wrapper, no changed
    attributes. Verified by comparing `outerHTML` before and after injection.
11. No secret appears in any message the content script sends — only `fillCredential` with
    an `id`.

### Deliberate reversal (2026-08-14)

Criterion 4 originally read: selecting an entry fills username and password, and the TOTP
field when the entry has one — the popup's group-fill behaviour, reused for the inline icon.
During the manual walk this was reversed on purpose: the inline icon now fills only the field
whose icon was clicked. The trade-off was named and accepted explicitly — precision over
one-click sign-in — so signing in via the inline icon now costs two panel openings (one for
username, one for password) instead of one. The popup's own fill path is untouched by this
change: it has no clicked field and still fills username and password together via
`findLoginForm`.

## Testing

### Automated (`inlineIcon.test.js`)

- `findFillableFields`: password outside a form; identifier-first page with no password
  field; disabled/readonly/hidden exclusion; OTP threshold boundary reused from
  `totpDetection.test.js` fixtures.
- `chooseInlinePanel`: each of the five states, including the OTP filter reducing a
  non-empty list to the empty state.
- `isTrusted` gate: a handler invoked with `{isTrusted: false}` performs no action and sends
  no message.
- `findLoginForm` regression: existing `formDetection.test.js` must stay green unchanged,
  proving the reimplementation preserves behaviour.

### Manual (`RUN.md`, Ukrainian)

Positioning, shadow-DOM isolation and real trusted clicks are not reachable from Node tests.
Stage 3, 5 and 6 each shipped defects that only a manual walk surfaced, so this list is a
gate, not a formality:

- icon alignment on scroll, zoom, and a resized window;
- an SPA login (identifier-first) — icon on the username step, then on the password step;
- a site with its own show-password eye — confirm the site stays usable;
- locked → unlock → panel refresh without reload;
- a page with `<form>`-less password field;
- confirm the site's input is unchanged (DevTools).

## Rejected alternatives

- **Icon opens the existing popup** (`chrome.action.openPopup()`). Smallest attack surface —
  all choice stays in trusted browser UI. Rejected because it is a shortcut to the thing the
  user already has, and it inherits the Chrome 127+ and window-focus preconditions recorded
  in the passkey design's S2 spike.
- **Fill immediately when there is exactly one match.** Fewest clicks in the common case, but
  the same control does different things depending on data the user cannot see, and a
  password lands in the page with no confirmation.
- **Show the icon only when matches exist.** Less visual noise; leaks account existence to
  the site. See "What is genuinely new".
- **`all_frames: true` for iframe support.** Real coverage gap, but it injects into every
  third-party frame on every page. Deserves its own decision.

## Follow-ups

- Split the inline-fill code out of `content.js` into its own `inline-fill.js`, as the
  file-size guidance in this spec suggests. Deliberately **not** done in the final fix wave:
  it needs a `manifest.json` change and a second content-script entry, which is new risk at
  the last gate. The bug that motivated it (module-level consts in their temporal dead zone
  at `attachIcons()` time) was fixed completely by moving the new declarations above the
  browser-only block, matching the idiom every other helper in the file already follows.
- Apply the `isTrusted` guard to the two existing banners (`showSaveBanner`,
  `showTotpSaveBanner`) — currently parked in the roadmap's Decisions table.
- iframe support, if the coverage gap proves real in use.
- A settings toggle, if the icon proves intrusive.
