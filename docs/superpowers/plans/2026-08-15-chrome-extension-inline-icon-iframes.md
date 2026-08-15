# Inline Fill Icon Inside Iframes — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the inline key icon, its panel, and filling work inside every frame — cross-origin included — while keeping banners and the popup's candidate query in the top frame and keeping the per-frame payload small.

**Architecture:** Two changes, both narrow. `manifest.json` splits into two content-script entries so the 251 KB QR decoder stays out of subframes while `content.js` gains `all_frames`. `content.js` gains one frame-policy predicate and four call sites that consult it. Nothing about the fill protocol, the trusted-event gate, or the shadow roots changes — those already behave correctly per-frame, which is what keeps this small.

**Tech Stack:** Plain ES5-compatible browser JS, no build step; `node:assert` scripts run directly by `node`; Chrome MV3 content scripts.

**Spec:** [`docs/superpowers/specs/2026-08-15-chrome-extension-inline-icon-iframes-design.md`](../specs/2026-08-15-chrome-extension-inline-icon-iframes-design.md)

## Global Constraints

- **`background.js`, `popup.js`, `popup.html`, `shared/entry-visuals.js` and all Swift are unchanged.** If one appears to need a change, stop — the design was wrong.
- **No change to the fill protocol**, the `isTrusted` gate, the closed shadow roots, the clicked-field-only fill, or the `frameId`/`documentId` delivery scoping.
- **No banner may render in a subframe** — neither the password save banner nor the 2FA one.
- **Exactly one frame answers `queryTotpCandidate`.** Subframes must return without touching `sendResponse`.
- **The frame policy fails closed:** an unknown feature name is treated as not enabled, so a future feature added without a policy entry does not silently start running in ad frames.
- **Everything new is declared ABOVE** the browser-only `if (typeof chrome !== 'undefined' && typeof document !== 'undefined')` guard. A declaration below its first use is a temporal-dead-zone `ReferenceError` invisible to the node suite; it has broken this feature once already.
- **No `innerHTML` anywhere** — sites enforcing `require-trusted-types-for 'script'` throw on it.
- **English everywhere except `RUN.md`**, which stays Ukrainian.

---

### Task 1: Frame policy and its four gates

**Files:**
- Modify: `ChromeExtension/content.js` (new predicate near the other helpers; four call sites inside the browser-only block; export block)
- Test: `ChromeExtension/tests/inlineIcon.test.js`

**Interfaces:**
- Produces:
  - `FRAME_FEATURE_POLICY` — object mapping feature name to `'allFrames' | 'topOnly'`
  - `isFeatureEnabledInFrame(feature, isTopFrame) -> boolean`

- [ ] **Step 1: Write the failing test**

Append a section to `ChromeExtension/tests/inlineIcon.test.js`:

```js
const { isFeatureEnabledInFrame, FRAME_FEATURE_POLICY } = require('../content.js');

// In the top frame everything runs.
for (const feature of Object.keys(FRAME_FEATURE_POLICY)) {
  assert.strictEqual(isFeatureEnabledInFrame(feature, true), true, feature + ' runs in the top frame');
}

// In a subframe only the inline icon does.
assert.strictEqual(isFeatureEnabledInFrame('inlineIcon', false), true, 'the icon is the whole point — it runs in subframes');
assert.strictEqual(isFeatureEnabledInFrame('saveBanner', false), false, 'a password save banner must never render inside a subframe');
assert.strictEqual(isFeatureEnabledInFrame('totpBanner', false), false, 'a 2FA save banner must never render inside a subframe');
assert.strictEqual(isFeatureEnabledInFrame('totpScan', false), false, 'the TOTP candidate scan is top-frame work');
assert.strictEqual(
  isFeatureEnabledInFrame('totpCandidateQuery', false),
  false,
  'only one frame may answer the popup, or responses collide'
);

// Fail closed: a feature nobody gave a policy to must NOT start running in ad frames.
assert.strictEqual(
  isFeatureEnabledInFrame('somethingAddedLater', false),
  false,
  'an unknown feature fails closed in subframes rather than silently running everywhere'
);
assert.strictEqual(isFeatureEnabledInFrame('somethingAddedLater', true), false, 'an unknown feature is not enabled anywhere');
console.log('inlineIcon.test.js: frame policy OK');
```

- [ ] **Step 2: Run it to verify it fails**

Run: `node ChromeExtension/tests/inlineIcon.test.js`
Expected: `TypeError: isFeatureEnabledInFrame is not a function`

- [ ] **Step 3: Implement the predicate**

In `content.js`, with the other helpers and ABOVE the browser-only block:

```js
  // Which behaviours may run outside the top frame. Stated once, as data, rather than as
  // `window.top === window` scattered through the file: the policy is then testable without
  // a DOM, and adding a behaviour forces a decision about frames instead of inheriting one.
  // Unknown names are NOT enabled — a banner added later without a policy entry must not
  // quietly start rendering inside every ad frame on the web.
  const FRAME_FEATURE_POLICY = {
    inlineIcon: 'allFrames',
    saveBanner: 'topOnly',
    totpBanner: 'topOnly',
    totpScan: 'topOnly',
    totpCandidateQuery: 'topOnly',
  };

  function isFeatureEnabledInFrame(feature, isTopFrame) {
    const policy = FRAME_FEATURE_POLICY[feature];
    if (!policy) return false;
    return policy === 'allFrames' || isTopFrame === true;
  }
```

Add both to `module.exports`.

- [ ] **Step 4: Run the test — expect PASS**

Run: `node ChromeExtension/tests/inlineIcon.test.js`
Expected: every section prints OK, including `frame policy OK`

- [ ] **Step 5: Add the frame constant and wire the four gates**

Inside the browser-only block, at the top of the `state` setup:

```js
    // Reference comparison only — reading properties of a cross-origin window.top throws,
    // comparing the reference does not.
    const IS_TOP_FRAME = window.top === window;
    const runsHere = (feature) => isFeatureEnabledInFrame(feature, IS_TOP_FRAME);
```

Then gate exactly four things, changing nothing else:

1. `showSaveBanner`'s caller in `attachSubmitListener` — wrap the existing condition so the banner is only offered when `runsHere('saveBanner')`.
2. The initial TOTP detection at bootstrap — only run when `runsHere('totpScan')`.
3. `observeTotpCandidates(state, attachIcons)` — keep calling it (icons still need the mutation observer in every frame), but inside its debounced callback gate the banner half on `runsHere('totpBanner')` while leaving the `attachIcons` half ungated.
4. The `queryTotpCandidate` branch of the `chrome.runtime.onMessage` listener — when `!runsHere('totpCandidateQuery')`, `return` immediately WITHOUT calling `sendResponse`, so only the top frame replies.

Do not gate `attachIcons`, the panel, `applyFill`, or anything on the fill path.

- [ ] **Step 6: Run the whole JS suite**

Run: `for f in ChromeExtension/tests/*.test.js; do node "$f" || exit 1; done`
Expected: all suites pass — nothing previously green regresses.

- [ ] **Step 7: Confirm the file still loads under stubs**

Write a throwaway script that stubs `chrome`, a minimal `document`, and a `window` whose `top` is itself, requires `content.js`, and asserts no exception. Then stub a `window` whose `top` is a *different* object and assert it still loads — that is the subframe path. Delete the script; paste its output into the report.

- [ ] **Step 8: Commit**

```bash
git add ChromeExtension/content.js ChromeExtension/tests/inlineIcon.test.js
git commit -m "feat(chrome): gate banners and the candidate query to the top frame"
```

---

### Task 2: Split the manifest so subframes do not carry the QR decoder

**Files:**
- Modify: `ChromeExtension/manifest.json`
- Test: `ChromeExtension/tests/background.manifest.test.js`

**Interfaces:**
- Consumes: nothing from Task 1 at runtime; the gates simply become reachable in subframes once this lands.

- [ ] **Step 1: Write the failing test**

`background.manifest.test.js` currently pins a single content-script entry with a three-element `js` array. Replace that assertion block with:

```js
const contentScripts = manifest.content_scripts;
assert.strictEqual(contentScripts.length, 2, 'two entries: the QR decoder stays top-frame, the rest runs everywhere');

const [qrEntry, mainEntry] = contentScripts;

assert.deepStrictEqual(qrEntry.js, ['vendor/jsQR.js'], 'the 251 KB QR decoder is its own entry');
assert.ok(!qrEntry.all_frames, 'the QR decoder must NOT be injected into subframes — it is 82% of the payload and useless there');

assert.deepStrictEqual(
  mainEntry.js,
  ['shared/entry-visuals.js', 'content.js'],
  'shared visuals load before content.js, which reads them'
);
assert.strictEqual(mainEntry.all_frames, true, 'the icon must reach login forms inside iframes');
assert.ok(!mainEntry.js.includes('vendor/jsQR.js'), 'jsQR must not sneak back into the all-frames entry');
console.log('background.manifest.test.js: content script frame split OK');
```

- [ ] **Step 2: Run it to verify it fails**

Run: `node ChromeExtension/tests/background.manifest.test.js`
Expected: FAIL on the entry count — currently 1, expected 2.

- [ ] **Step 3: Split the manifest**

In `ChromeExtension/manifest.json`, replace the single `content_scripts` entry with:

```json
  "content_scripts": [
    {
      "matches": ["<all_urls>"],
      "js": ["vendor/jsQR.js"],
      "run_at": "document_idle"
    },
    {
      "matches": ["<all_urls>"],
      "all_frames": true,
      "js": ["shared/entry-visuals.js", "content.js"],
      "run_at": "document_idle"
    }
  ],
```

Change nothing else in the manifest — not `permissions`, not `minimum_chrome_version`, not `key`.

- [ ] **Step 4: Run the test — expect PASS**

Run: `node ChromeExtension/tests/background.manifest.test.js`
Expected: `content script frame split OK`

- [ ] **Step 5: Confirm the manifest is still valid JSON**

Run: `python3 -c "import json; json.load(open('ChromeExtension/manifest.json')); print('valid')"`
Expected: `valid`

- [ ] **Step 6: Run the whole JS suite**

Run: `for f in ChromeExtension/tests/*.test.js; do node "$f" || exit 1; done`
Expected: all pass.

- [ ] **Step 7: Commit**

```bash
git add ChromeExtension/manifest.json ChromeExtension/tests/background.manifest.test.js
git commit -m "feat(chrome): run the content script in all frames, keep jsQR top-frame only"
```

---

### Task 3: Cross-origin fixture, manual checklist, and spec cross-reference

**Files:**
- Create: `ChromeExtension/tests/fixtures/inline-icon-iframe-parent.html`
- Modify: `RUN.md`
- Modify: `docs/superpowers/specs/2026-08-14-chrome-extension-inline-fill-icon-design.md`

- [ ] **Step 1: Create the cross-origin parent fixture**

Different ports are different origins, so a second server on `:8766` gives a genuine cross-origin frame rather than an imitation. Create `inline-icon-iframe-parent.html`:

```html
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <title>MyPass fixture — cross-origin login iframe</title>
  <style>
    body { font-family: system-ui, sans-serif; margin: 0; padding: 24px; max-width: 720px; }
    iframe { width: 100%; height: 260px; border: 1px solid #ccc; }
    .narrow { width: 180px; }
    .why { background: #fff8e1; border-left: 4px solid #f0b429; padding: 12px 16px; margin: 20px 0; }
  </style>
</head>
<body>
  <h1>Parent page (:8765)</h1>

  <div class="why">
    Serve this directory on <strong>two</strong> ports — different ports are different
    origins, so the frame below is genuinely cross-origin rather than a same-origin
    imitation:
    <pre>cd ChromeExtension/tests/fixtures &amp;&amp; python3 -m http.server 8765
cd ChromeExtension/tests/fixtures &amp;&amp; python3 -m http.server 8766</pre>
    Open this page on :8765.
  </div>

  <h2>1. Cross-origin login form</h2>
  <p>Expect: the key icon appears inside the frame; the entries it lists are those for
     <code>localhost:8766</code>; filling lands in the frame and leaves this page untouched.</p>
  <iframe src="http://localhost:8766/login.html" title="cross-origin login"></iframe>

  <h2>2. Narrow frame — known limitation</h2>
  <p>Expect: the icon appears, but the panel is clipped by the frame's width. Recorded in
     the design, not a defect to file.</p>
  <iframe class="narrow" src="http://localhost:8766/login.html" title="narrow login"></iframe>

  <h2>3. This page's own field</h2>
  <p>Expect: its own icon, filling with entries for <code>localhost:8765</code>.</p>
  <form>
    <input type="text" name="username" placeholder="Username">
    <input type="password" name="password" placeholder="Password">
  </form>

  <p><strong>Also expect:</strong> no save-password or save-2FA banner ever appears inside
     either frame — banners belong to the top frame only.</p>
</body>
</html>
```

- [ ] **Step 2: Add the manual checklist to `RUN.md` (Ukrainian, do not translate the file)**

Append near the other inline-icon bullets:

```markdown
   - [ ] `inline-icon-iframe-parent.html` на :8765 (потрібен другий сервер на :8766): у чужодоменному фреймі з'являється іконка-ключ
   - [ ] Список у панелі всередині фрейма — це записи для `localhost:8766`, а не для батьківської сторінки
   - [ ] Вибір запису заповнює поле **всередині фрейма**; поля батьківської сторінки не змінюються
   - [ ] У жодному з фреймів не з'являється банер збереження пароля чи 2FA
   - [ ] На батьківській сторінці банери працюють як раніше
   - [ ] Секція **Add 2FA** в попапі працює на сторінці з фреймами — відповідає рівно один фрейм, без помилок у консолі
   - [ ] QR-виявлення 2FA і далі працює у верхньому фреймі (`qr.html`), у вкладених його просто немає
   - [ ] Сторінка з кількома рекламними фреймами не дає помилок на `chrome://extensions`
   - [ ] У вузькому фреймі панель обрізається — це відоме обмеження, а не дефект
```

- [ ] **Step 3: Update the earlier spec's non-goal**

In `docs/superpowers/specs/2026-08-14-chrome-extension-inline-fill-icon-design.md`, the Non-goals section states iframes are out of scope "with its own cost". Amend that bullet to record that the decision was reversed on 2026-08-15 and link to `2026-08-15-chrome-extension-inline-icon-iframes-design.md`. Do not delete the original reasoning — it explains why the deferral was right at the time.

- [ ] **Step 4: Run the full suite**

Run:
```bash
test -f /tmp/citadel_smoke_key || ssh-keygen -t ed25519 -N "correct-horse-battery-staple" -f /tmp/citadel_smoke_key -C "smoketest@mypass"
./scripts/test.sh > /tmp/iframes.log 2>&1; echo "EXIT=$?"
grep -c '\*\* TEST SUCCEEDED \*\*' /tmp/iframes.log
```
Expected: `EXIT=0` and a count of 1. Never judge this by `| tail` — a pipeline reports tail's exit code, which is how a failing run once read as a pass in this repository. The run takes several minutes; wait for it.

- [ ] **Step 5: Commit**

```bash
git add ChromeExtension/tests/fixtures/inline-icon-iframe-parent.html RUN.md docs/superpowers/specs/2026-08-14-chrome-extension-inline-fill-icon-design.md
git commit -m "test(chrome): add a genuine cross-origin iframe fixture and its manual walk"
```

---

## Self-Review

**Spec coverage.** Payload split → Task 2. Frame gating → Task 1. Banners staying top-frame → Task 1 gates 1–3. The `queryTotpCandidate` collision → Task 1 gate 4. Security properties → unchanged by design, asserted by the constraint that the fill path is not touched. Acceptance criteria 1–3 and 5–9 are covered by Task 3's manual bullets; criterion 4 has both a unit assertion (the policy) and a manual bullet.

**Type consistency.** `isFeatureEnabledInFrame(feature, isTopFrame)` keeps its argument order between Task 1's tests and its call sites. `FRAME_FEATURE_POLICY`'s five keys are exactly the five names used at the gates.

**Deliberate gap.** Nothing here tests actual frame behaviour — frames are unreachable from node. Task 1's stub-load check covers only that the file parses and runs in both frame shapes. The real gate is Task 3's manual walk, which is why its bullets name specific expectations rather than "verify iframes work".

**Known risk to watch during execution.** `observeTotpCandidates` serves two consumers now — the banner (top only) and `attachIcons` (all frames). Task 1 step 5 gates only the banner half. Getting that backwards would silently stop icons appearing in subframes on SPA navigation, and no automated test would catch it.
