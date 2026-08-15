# Chrome Extension — Inline Fill Icon Inside Iframes

Status: approved 2026-08-15.

Follow-up to [2026-08-14-chrome-extension-inline-fill-icon-design.md](./2026-08-14-chrome-extension-inline-fill-icon-design.md),
which listed iframe support as an explicit non-goal. **This design reverses that**, with the
cost that was named there now measured rather than assumed.

## Problem

`content_scripts` in `manifest.json` does not set `all_frames`, so the content script runs
only in the top frame. Any login form inside an iframe therefore gets no key icon at all —
including the case the inline icon exists to serve: a third-party sign-in widget (SSO,
an embedded provider form), which is by definition cross-origin and by definition in a frame.

The original design deferred this because `all_frames: true` injects the whole content
script into every ad and tracking frame on every page. That reasoning stands; what changed
is that the payload can be split so the expensive part stays out of subframes.

## Goals

- The key icon, its panel, and filling work in every frame, cross-origin included.
- The per-frame payload stays small enough that injecting everywhere is defensible.
- No banner ever renders inside a subframe.
- No credential crosses a frame boundary.

## Non-goals

- **A save-password or save-2FA prompt after a login completed inside an iframe.** See
  "Banners stay in the top frame" — accepted gap, recorded rather than solved.
- **Making the panel fit inside a narrow frame.** See "Known limitations".
- **Any change to the fill protocol, the trusted-event gate, or the shadow roots.** All
  three already behave correctly per-frame; that is what makes this change small.
- **A settings toggle for iframe support.**

## Design

### Payload split

Measured, not estimated:

| File | Size | Needed in subframes? |
|---|---|---|
| `vendor/jsQR.js` | 251.0 KB | no |
| `content.js` | 52.1 KB | yes |
| `shared/entry-visuals.js` | 1.9 KB | yes |

`jsQR` is 82% of the payload and is called from exactly one place, `decodeQrFromImage`,
already guarded by `typeof jsQR === 'function'`. A 2FA setup QR code does not appear inside
an ad frame, so subframes lose nothing by not having the decoder — they simply return `null`
from QR detection, which is the correct answer there anyway.

`manifest.json` therefore declares two content-script entries:

```json
{ "matches": ["<all_urls>"], "js": ["vendor/jsQR.js"], "run_at": "document_idle" },
{ "matches": ["<all_urls>"], "all_frames": true,
  "js": ["shared/entry-visuals.js", "content.js"], "run_at": "document_idle" }
```

Per-frame cost drops from 305 KB to 54 KB. Both entries inject into the top frame, in
manifest order, so `jsQR` is defined before `content.js` runs there.

### Frame gating

`content.js` currently contains no frame awareness at all — every line was written assuming
the top frame. One constant and four gates fix that:

```js
const IS_TOP_FRAME = window.top === window;
```

Comparing `window.top` by reference is allowed cross-origin; only reading its properties is
not. Nothing here reads them.

| Behaviour | Frames |
|---|---|
| icon attachment, panel, fill | all |
| `showSaveBanner` (password) | top only |
| `showTotpSaveBanner` and `observeTotpCandidates` | top only |
| the initial TOTP candidate scan at load | top only |
| responding to the popup's `queryTotpCandidate` | top only |

The last row is not cosmetic. The popup sends `queryTotpCandidate` with
`chrome.tabs.sendMessage(tabId, …)`, which broadcasts to every frame carrying a listener.
Without the gate, each frame would try to `sendResponse` and only the first would be
delivered, with the rest producing errors. Subframes must return without touching
`sendResponse` at all; the top frame always answers, so the popup always gets a reply.

### Banners stay in the top frame

A banner is `position: fixed`, so inside a subframe it anchors to that frame's corner. In a
300×250 ad slot the result is clipped or invisible; in a login widget it would cover the form
it is asking about.

The accepted consequence: **a login completed entirely inside an iframe will not offer to
save the password.** Routing the offer out to the top frame is possible — the subframe would
detect the submit and ask the top frame to render — but it means moving a password across a
frame boundary through the background worker, which is a new secret-bearing path and deserves
its own design rather than being smuggled in here. Deferred deliberately.

### Security

Three properties already hold per-frame, which is what makes this change small rather than
dangerous:

- **Delivery is document-scoped.** `sendApplyFillToSender` passes
  `{ frameId, documentId }`, so a fill requested by a subframe is delivered to that document
  and no other. It cannot land in the top frame, and it fails closed when `documentId` is
  absent.
- **Origin validation is per-frame.** `sender.url` is the *frame's* URL, so
  `hostnameMatches(requestUrl, sender.url)` compares against the frame's own origin. A
  cross-origin sign-in iframe receives credentials for its own domain, never the parent's.
- **The trusted-event gate is unchanged.** A synthetic click inside a frame is rejected
  exactly as it is in the top frame.

**Residual risk, accepted.** A hostile top page can size and position an embedded legitimate
login form so that a user clicks our icon somewhere they did not intend. The credential still
goes only to that frame's own origin, so nothing leaks across domains; the exposure is
inducing a user to authenticate to a real site at the wrong moment. This is the same boundary
the browser's own autofill sits on, and no per-frame check distinguishes it from a legitimate
embedded login. Recorded, not mitigated.

## Known limitations

- The panel has `min-width: 220px` and is positioned inside its own frame, so a frame
  narrower than that clips it. Not addressed here.
- Icons in a subframe use that frame's coordinate space. A frame that itself scrolls
  independently behaves like the scrollable-container case already covered in the top frame.

## Files touched

| File | Change |
|---|---|
| `ChromeExtension/manifest.json` | split into two content-script entries; `all_frames` on the second |
| `ChromeExtension/content.js` | `IS_TOP_FRAME` plus four gates |
| `ChromeExtension/tests/inlineIcon.test.js` | gate coverage |
| `ChromeExtension/tests/background.manifest.test.js` | the entry split is pinned there |
| `ChromeExtension/tests/fixtures/` | a cross-origin embed fixture |
| `RUN.md` | manual bullets (Ukrainian) |
| `docs/superpowers/specs/2026-08-14-…-design.md` | its iframe non-goal now points here |

`background.js`, `popup.js`, `shared/entry-visuals.js` and all Swift are unchanged. If any
of them turns out to need a change, stop — the design was wrong.

## Acceptance criteria

1. A login form in a **cross-origin** iframe shows the key icon.
2. Selecting an entry there fills that frame's field and nothing in the parent.
3. The entries offered inside the frame are those matching the **frame's** domain, not the
   parent's.
4. No save-password or save-2FA banner ever appears inside a subframe.
5. The top frame still shows both banners exactly as before.
6. The popup's Add-2FA section still works — exactly one frame answers `queryTotpCandidate`.
7. QR-based 2FA detection still works in the top frame and is simply absent in subframes.
8. A synthetic click inside a subframe fills nothing.
9. `chrome://extensions` shows no errors on a page with several ad iframes.

## Testing

### Automated

- The frame gates as pure predicates: given "is top frame" true/false, which behaviours are
  enabled. Extracted so they are testable without a DOM, the same way panel routing was.
- `background.manifest.test.js`: the two entries, their order, `all_frames` present on the
  second and absent on the first, and `jsQR` listed only in the first.

### Manual (`RUN.md`, Ukrainian)

Frames are not reachable from the node suite, and the last four defects in this feature were
all found only in a browser. A genuine cross-origin fixture is required — different ports are
different origins, so:

```sh
cd ChromeExtension/tests/fixtures && python3 -m http.server 8765
cd ChromeExtension/tests/fixtures && python3 -m http.server 8766
```

with a fixture on `:8765` embedding `http://localhost:8766/login.html`. Bullets cover: the
icon appearing inside the frame; the fill landing in the frame and not the parent; the
entry list matching the frame's origin; no banner inside the frame; the top frame's banners
still working; and a page with several ad-like frames producing no console errors.

## Rejected alternatives

- **`all_frames: true` on the single existing entry.** Simplest, and what the original
  non-goal assumed. Rejected on the measurement: it puts a 251 KB QR decoder into every ad
  frame for no benefit.
- **Same-origin frames only.** Safer-sounding, but misses the entire motivating case — a
  third-party sign-in widget is always cross-origin.
- **Routing the save-password banner from a subframe to the top frame.** Correct, and the
  only way to close the accepted gap, but it creates a new path carrying a password across
  frames. Deserves its own design.
