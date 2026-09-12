# Site-Aware Password Rules and Per-Entry URI Match Modes — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Two related, fully offline capabilities. First, MyPass generates passwords that a target site will actually accept, by honouring Apple's per-site Password Rules data (`quirks/password-rules.json` from `apple/password-manager-resources`) in the app's own generator and, eventually, through the browser extension. Second, a vault entry can declare *how* its URL is matched against a page, replacing the single registrable-domain rule `ExtensionEntryMatcher` uses today with a per-entry choice of five explicit modes (`URIMatchMode`). Neither capability adds runtime network access: the password-rules data is vendored into the app bundle exactly as the Public Suffix List already is, and match-mode selection is pure local logic over data already in the vault.

**Architecture:** `Packages/MyPassKit` gains a `PasswordRules/` module — a hand-written grammar parser (`PasswordRulesParser`) producing a `PasswordRules` value type, and a `PasswordRulesCatalog` that loads the vendored JSON once, indexes it by domain, and walks upward from a full host to (never past) its registrable domain via the existing `PublicSuffixList`. `PasswordGenerator.generate` gains an optional `rules: PasswordRules?` parameter that constrains the character pool, clamps length, and verifies/repairs candidates against the rule. The app target gains persisted generator defaults (`PasswordGeneratorDefaults`, plain `UserDefaults`-backed) and a `PasswordGeneratorView` that surfaces the active rule in plain English. A later phase of this same plan (Tasks 8–14, in the companion continuation of this document) adds `URIMatchMode` to `MyPassKit`, a hidden `MyPass.URIMatchMode` custom field on `KdbxEntry`, a 16th `ExtensionBridgeMessages` request/response case for site-aware generation from the extension, and matching changes to `content.js`/`popup.js`/`background.js`. This document's first half (Tasks 1–7) covers only the generator/rules capability; the match-mode and bridge-protocol capability is out of scope here.

**Tech Stack:** Swift 5.10, SwiftUI, XCTest — all within the existing `Packages/MyPassKit` SwiftPM package and the `MyPass` app target. No new dependencies: the parser and catalog are hand-written Swift with no third-party JSON-schema or grammar library, matching this codebase's existing preference for vendoring and hand-rolling over pulling in a package for a well-bounded grammar (the same reasoning `docs/superpowers/spikes/2026-07-21-keepasskit-vs-custom-parser.md` already applied to the KDBX format itself). The vendored data is JSON fetched once at vendoring time and refreshed only by a manual, developer-run `bash` script (`curl`/`git`/`python3`, matching the existing `scripts/` shape).

**Spec:** `docs/superpowers/specs/2026-09-12-site-password-rules-and-uri-matching-design.md`

## Global Constraints

- English everywhere: code, comments, commit messages, UI strings, docs. Root `RUN.md` is Ukrainian and is never translated.
- No linter and no formatter are configured. Match the style of surrounding code by hand.
- Conventional Commits with a scope, lowercase imperative subject, no trailing period. Scopes in use: `app`, `extension`, `chrome`, `scripts`, `entry-edit`.
- macOS 14.0+, Swift and SwiftUI.
- No CI. `./scripts/test.sh` must be run locally before the work is called done. It runs `xcodebuild test -scheme MyPass`, then `swift test` in each of the three `Packages/*` directories, then the standalone node scripts in `ChromeExtension/tests/`.
- `MyPass.xcodeproj`, `MyPass/Info.plist` and `MyPassTests/Info.plist` are generated and gitignored. Regenerate with `./scripts/generate.sh`, never hand-edit, never commit.
- Long explanatory comments recording WHY a constraint exists are a feature of this codebase. Preserve and add them; do not strip them as noise.
- No runtime network access is added by this work. The only network access anywhere is the manual, developer-run refresh script.
- All randomness stays on `SecRandomCopyBytes` with rejection sampling. No `Int.random`, no `SystemRandomNumberGenerator`, anywhere in generation or shuffling.

## Why this task order

Task 1 vendors the data before anything parses it, because Task 2's parser fixtures and Task 5's conformance test both need real rule strings to test against — building the parser first against invented strings risks a parser that only agrees with itself, not with any real site's actual rule, which is exactly the gap Task 5 exists to close. Task 2 is a pure function with no I/O; it comes before Task 3 because `PasswordRulesCatalog` is a thin lookup-and-cache layer built *on top of* the parser (load JSON once, walk hosts, hand each candidate's raw string to `PasswordRulesParser.parse`), not the other way around — the catalog cannot be tested meaningfully until the grammar it delegates to is already settled and tested.

Task 4 changes `PasswordGenerator.generate`, an existing, already-shipped, already-tested function, later than Tasks 1–3 on purpose: doing the rules/catalog/parser work first means Task 4's own tests are the first and only place in this plan where that surface has to change, and the existing `PasswordGeneratorTests.swift` suite (six tests, all currently passing, all exercising the no-`rules` path) stays untouched throughout — the new `rules: PasswordRules? = nil` parameter is additive, and Task 4 explicitly keeps the `rules == nil` path byte-for-byte identical to the function's current body rather than routing it through new shared helpers that could subtly change its behaviour.

Task 5 is deliberately its own task, not a step folded into Task 4, because it is the one thing in this plan that actually proves Tasks 1 through 4 agree with each other *and* with real-world data, rather than agreeing only with each other's assumptions about what a rule string looks like — the same distinction the spec's own Testing section draws in calling it "the headline test." Placing it immediately after Task 4, before either persistence (Task 6) or UI work (Task 7) begins, means any disagreement between parser and generator is caught while the diff is still small enough — four tasks, all pure Swift, no UI, no `UserDefaults`, no bridge protocol — to bisect by hand.

Tasks 6 and 7 come last, and in that relative order, because they are consumers of a now-proven engine rather than part of it. Task 6 (persisted generator defaults) has no dependency on Password Rules at all — it is app-target `UserDefaults` plumbing for state the generator view already computes over, with an existing precedent for its exact shape (`ClipboardClearInterval`'s injectable-`UserDefaults` pattern in `MyPass/UI/…/ClipboardClearInterval.swift`, proven by `ClipboardClearIntervalTests.swift`) — so it can be built and tested in complete isolation from Tasks 1–5. Task 7 depends on Task 6 (it reads and writes through `PasswordGeneratorDefaults`), on Task 3 (it looks up `PasswordRulesCatalog.rules(forHost:)`), and on Task 4 (it calls `PasswordGenerator.generate(options:rules:)`); it is last because it is the one task in this half of the plan where a bug shows up as a SwiftUI compile error or a visual defect rather than a red XCTest, and those are more expensive to bisect against a moving foundation than against one already proven by Task 5's conformance gate.

The companion continuation of this document (Tasks 8–14) covers `URIMatchMode` and the bridge/extension surfaces — Decisions 6 through 9 of the spec, touching `ExtensionBridgeMessages.swift`'s 15-case (soon 16-case) enum, `KdbxEntry`'s hidden-field convention, and both `content.js` and `popup.js`. It is sequenced after this half not because of a code dependency (the two capabilities share only the spec they came from) but because the same principle governs the whole plan: prove the smaller, lower-risk, easier-to-bisect half first, and inherit that confidence before opening the second, riskier front — Decision 8's rejected-regex discussion and Decision 6's six-exhaustive-switch surface are exactly the kind of "many things touched at once" risk this ordering exists to contain.

## Task 1 — Vendor the Apple password rules data

**Interfaces:**
- Produces: `Packages/MyPassKit/Sources/MyPassKit/Resources/password-rules.json` (bundled resource, loaded via `Bundle.module`), `Packages/MyPassKit/Sources/MyPassKit/Resources/PASSWORD_RULES_PROVENANCE.md` (documentation, excluded from the build), an updated `Packages/MyPassKit/Package.swift` (new `resources:`/`exclude:` entries on the `MyPassKit` target), `scripts/update-password-rules.sh`.
- Consumes: nothing in this codebase yet. Network access exists only inside the manual update script, never in app or test code.

Verified directly while writing this plan (`git clone --depth 1 https://github.com/apple/password-manager-resources.git` into a scratch directory): at commit `6073487115b722596d3e1826d1b71b524b73bac5`, `quirks/password-rules.json` is a single pretty-printed JSON object, `{ "<domain>": { "password-rules": "<rule string>" }, ... }`, 436 top-level keys, 63,935 bytes, zero entries currently setting `exact-domain-match-only`. Upstream's `LICENSE.md` is short-form MIT: `Copyright 2020 - 2026 Apple Inc.` followed by the standard MIT permission/warranty paragraphs — no separate NOTICE file, no dual-licence text (unlike `CArgon2`'s CC0/Apache choice; this vendored file has exactly one licence to reproduce).

- [ ] **Step 1: Write the failing test**

Create `Packages/MyPassKit/Tests/MyPassKitTests/PasswordRulesResourceTests.swift`:

```swift
import XCTest
@testable import MyPassKit

final class PasswordRulesResourceTests: XCTestCase {
    /// Sanity check that the vendored resource is actually bundled and
    /// readable, before anything in Task 2 or Task 3 depends on it.
    func testBundledPasswordRulesResourceLoadsAndParses() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "password-rules", withExtension: "json"))
        let data = try Data(contentsOf: url)
        let parsed = try JSONSerialization.jsonObject(with: data)
        let object = try XCTUnwrap(parsed as? [String: Any])

        // Deliberately NOT hardcoded to 436: `scripts/update-password-rules.sh`
        // (this task, Step 7) is expected to change this count on every
        // refresh as upstream adds or removes quirks. 100 is a floor that
        // only ever fails if the vendored file were replaced with
        // something close to empty by mistake -- the real count at
        // vendoring time (2026-09-12, commit 6073487115b7) is 436.
        XCTAssertGreaterThan(object.count, 100)
    }
}
```

- [ ] **Step 2: Run and confirm failure**

Run: `cd Packages/MyPassKit && swift test --filter PasswordRulesResourceTests`
Expected: FAIL — `XCTUnwrap` throws on the `Bundle.module.url(...)` call because the resource does not exist yet.

- [ ] **Step 3: Fetch the pinned upstream snapshot**

```bash
cd /tmp
rm -rf password-manager-resources
git clone --depth 1 https://github.com/apple/password-manager-resources.git
cd password-manager-resources
git rev-parse HEAD   # confirm: 6073487115b722596d3e1826d1b71b524b73bac5
wc -c quirks/password-rules.json   # confirm: 63935
python3 -c "import json; print(len(json.load(open('quirks/password-rules.json'))))"   # confirm: 436
```

- [ ] **Step 4: Copy the data file and write the provenance note**

```bash
cd /Users/lucheninov/Works/slava/mypass
cp /tmp/password-manager-resources/quirks/password-rules.json \
   Packages/MyPassKit/Sources/MyPassKit/Resources/password-rules.json
```

The vendored JSON is committed exactly as fetched, with no reformatting — Apple's own file is already pretty-printed with a stable 4-space indent and alphabetically-ish ordered keys, so re-serializing it through any JSON writer here would only add diff noise the next time `scripts/update-password-rules.sh` (Step 7) runs and a `git diff` needs to stay readable against what upstream actually changed.

```bash
cat > Packages/MyPassKit/Sources/MyPassKit/Resources/PASSWORD_RULES_PROVENANCE.md <<'EOF'
# Vendored: Apple password-manager-resources (quirks/password-rules.json)

- Upstream: https://github.com/apple/password-manager-resources
- Vendored file: quirks/password-rules.json
- Commit: 6073487115b722596d3e1826d1b71b524b73bac5
- Retrieved on: 2026-09-12
- Entry count at that commit: 436

The vendored JSON is committed as-is, with no reformatting, so a future
`git diff` against upstream stays readable. Regenerate with
`scripts/update-password-rules.sh` -- this file and `password-rules.json`
are always rewritten together, in the same run, so they can never
independently drift out of sync (see that script for why: it is exactly
the same commit/date/count triple recorded here, plus a fresh copy of
upstream's own LICENSE.md, generated fresh on every run).

## Licence

Copied verbatim from upstream's `LICENSE.md` at the commit above:

Copyright 2020 - 2026 Apple Inc.

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
EOF
```

- [ ] **Step 5: Wire the resource into `Package.swift`**

In `Packages/MyPassKit/Package.swift`, the `MyPassKit` target currently reads:

```swift
        .target(
            name: "MyPassKit",
            dependencies: [
                "CArgon2",
                .product(name: "Sodium", package: "swift-sodium"),
                .product(name: "Clibsodium", package: "swift-sodium")
            ],
            resources: [.copy("Resources/public_suffix_list.dat")]
        ),
```

Change it to:

```swift
        .target(
            name: "MyPassKit",
            dependencies: [
                "CArgon2",
                .product(name: "Sodium", package: "swift-sodium"),
                .product(name: "Clibsodium", package: "swift-sodium")
            ],
            resources: [
                .copy("Resources/public_suffix_list.dat"),
                .copy("Resources/password-rules.json")
            ],
            exclude: ["Resources/PASSWORD_RULES_PROVENANCE.md"]
        ),
```

`exclude:` for the provenance file matches `CArgon2`'s own target, which excludes its `VENDORING.md` for the identical reason: it is documentation, not a resource the app loads at runtime, and SwiftPM otherwise complains about an unhandled file sitting inside a target's source directory.

- [ ] **Step 6: Run and confirm pass**

Run: `cd Packages/MyPassKit && swift test --filter PasswordRulesResourceTests`
Expected: PASS.

- [ ] **Step 7: Write the refresh script**

Create `scripts/update-password-rules.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

UPSTREAM_URL="https://github.com/apple/password-manager-resources.git"
UPSTREAM_DATA_FILE="quirks/password-rules.json"
UPSTREAM_LICENSE_FILE="LICENSE.md"

DATA_TARGET="$REPO_ROOT/Packages/MyPassKit/Sources/MyPassKit/Resources/password-rules.json"
PROVENANCE_TARGET="$REPO_ROOT/Packages/MyPassKit/Sources/MyPassKit/Resources/PASSWORD_RULES_PROVENANCE.md"

require_command() {
  local cmd="$1"
  local hint="${2:-}"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: required command '$cmd' not found." >&2
    [[ -n "$hint" ]] && echo "$hint" >&2
    exit 1
  fi
}

require_command git
# python3, not jq: this repo already relies on python3 for JSON handling
# elsewhere (scripts/setup-chrome-extension.sh writes the native messaging
# manifest via `python3 -c "import json; ..."`), so reusing it here avoids
# introducing a second JSON tool as a preflight dependency.
require_command python3

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

echo "Cloning $UPSTREAM_URL (shallow)..."
git clone --depth 1 "$UPSTREAM_URL" "$WORK_DIR/repo" >/dev/null

COMMIT_SHA="$(git -C "$WORK_DIR/repo" rev-parse HEAD)"
RETRIEVAL_DATE="$(date -u +%Y-%m-%d)"

if [[ ! -f "$WORK_DIR/repo/$UPSTREAM_DATA_FILE" ]]; then
  echo "Error: $UPSTREAM_DATA_FILE not found at $UPSTREAM_URL@$COMMIT_SHA -- upstream layout may have changed." >&2
  exit 1
fi

ENTRY_COUNT="$(python3 -c "
import json, sys
with open(sys.argv[1], encoding='utf-8') as f:
    data = json.load(f)
print(len(data))
" "$WORK_DIR/repo/$UPSTREAM_DATA_FILE")"

if [[ "$ENTRY_COUNT" -lt 1 ]]; then
  echo "Error: fetched password-rules.json has zero entries -- refusing to vendor an empty snapshot." >&2
  exit 1
fi

# Committed as-is, no reformatting -- see PASSWORD_RULES_PROVENANCE.md for
# why: it keeps a future `git diff` against upstream readable.
cp "$WORK_DIR/repo/$UPSTREAM_DATA_FILE" "$DATA_TARGET"

cat > "$PROVENANCE_TARGET" <<EOF
# Vendored: Apple password-manager-resources (quirks/password-rules.json)

- Upstream: https://github.com/apple/password-manager-resources
- Vendored file: quirks/password-rules.json
- Commit: $COMMIT_SHA
- Retrieved on: $RETRIEVAL_DATE
- Entry count at that commit: $ENTRY_COUNT

The vendored JSON is committed as-is, with no reformatting, so a future
\`git diff\` against upstream stays readable. Regenerate with
\`scripts/update-password-rules.sh\` -- this file and \`password-rules.json\`
are always rewritten together, in the same run, so they can never
independently drift out of sync.

## Licence

Copied verbatim from upstream's \`LICENSE.md\` at the commit above:

EOF

cat "$WORK_DIR/repo/$UPSTREAM_LICENSE_FILE" >> "$PROVENANCE_TARGET"

echo "Updated $DATA_TARGET ($ENTRY_COUNT entries) and $PROVENANCE_TARGET at commit $COMMIT_SHA."
```

- [ ] **Step 8: Make the script executable**

```bash
chmod +x scripts/update-password-rules.sh
```

- [ ] **Step 9: Commit**

```bash
git add Packages/MyPassKit/Package.swift \
        Packages/MyPassKit/Sources/MyPassKit/Resources/password-rules.json \
        Packages/MyPassKit/Sources/MyPassKit/Resources/PASSWORD_RULES_PROVENANCE.md \
        Packages/MyPassKit/Tests/MyPassKitTests/PasswordRulesResourceTests.swift \
        scripts/update-password-rules.sh
git commit -m "feat(app): vendor Apple's password-rules.json quirks data"
```

---

## Task 2 — PasswordRules model and grammar parser

**Interfaces:**
- Produces: `Packages/MyPassKit/Sources/MyPassKit/PasswordRules/PasswordRules.swift` (the `PasswordRules` struct, `PasswordRules.CharacterClass`, `PasswordRulesParseError`), `Packages/MyPassKit/Sources/MyPassKit/PasswordRules/PasswordRulesParser.swift` (`PasswordRulesParser.parse(_:)`).
- Consumes: nothing new — this is a pure function with no I/O, no `Bundle`, no `PublicSuffixList` dependency. It only borrows real rule strings from Task 1's vendored data as test fixtures.

**A parsing trap, discovered and fixed while writing this plan — read before Step 3.** The obvious first design for a `;`-separated grammar is `raw.split(separator: ";")`, parsing each piece independently. That design is wrong for this grammar, and wrong in a way that would silently corrupt 61 of the 436 real vendored rules if shipped. Verified directly against the vendored data (`python3 -c "..."` against `quirks/password-rules.json`, counting rules with `;` inside a `[...]` custom class): 61 real domains — including `admiral.com`, `autify.com`, `axa.de`, `bankofamerica.com`, `bitly.com` — have a literal `;` character *inside* a bracketed custom character class, because `;` is itself an ASCII-printable character and Apple's grammar allows any ASCII-printable character as a literal class member. A naive top-level `split(separator: ";")` would cut `admiral.com`'s real rule —

```
minlength: 8; required: digit; required: [- !"#$&'()*+,.:;<=>?@[^_`{|}~]]; allowed: lower, upper;
```

— into a fragment ending mid-character-class (`required: [- !"#$&'()*+,.:` as one piece, `<=>?@[^_\`{|}~]]` as another with no property name at all), producing either a crash, a spurious `unknownProperty` error, or a silently wrong character set. The fix, mirroring Apple's own reference implementation (`tools/PasswordRulesParser/PasswordRulesParser.js` in `apple/password-manager-resources`) rather than reinventing the grammar from the developer.apple.com prose alone: parse the *whole* rule string as a single left-to-right character scan that only treats `;` as a property separator when it appears **outside** an open `[...]` class. The bracket-scanning function below is itself bracket-terminator-aware in a second, non-obvious way covered in its own doc comment (a `]]` sequence encodes one literal `]` plus the real closing bracket) — `admiral.com`'s rule above exercises exactly that too (it ends `~]]`), and `costco.com`'s real rule exercises a *second* non-obvious rule at the same time: a literal `[` is just an ordinary member character when it appears after the opening `[`, never itself nested.

- [ ] **Step 1: Write the failing tests**

Create `Packages/MyPassKit/Tests/MyPassKitTests/PasswordRulesParserTests.swift`:

```swift
import XCTest
@testable import MyPassKit

final class PasswordRulesParserTests: XCTestCase {
    // MARK: AND across clauses, OR within a clause, numeric fields
    //
    // Real rule from the vendored 2026-09-12 snapshot, account.samsung.com.

    func testAndAcrossRequiredClausesOrWithinAClause() throws {
        let raw = "minlength: 8; maxlength: 15; max-consecutive: 3; required: digit; required: special; required: upper,lower;"
        guard case .success(let rules) = PasswordRulesParser.parse(raw) else {
            return XCTFail("expected a successful parse")
        }
        XCTAssertEqual(rules.minLength, 8)
        XCTAssertEqual(rules.maxLength, 15)
        XCTAssertEqual(rules.maxConsecutive, 3)
        // Three `required:` clauses -- ANDed -- the third itself ORs upper
        // with lower.
        XCTAssertEqual(rules.requiredClauses, [[.digit], [.special], [.upper, .lower]])
        // Every required class is folded into allowedClasses even though
        // this rule has no explicit `allowed:` property.
        XCTAssertEqual(Set(rules.allowedClasses), [.asciiPrintable, .digit, .special, .upper, .lower])
    }

    // MARK: Custom bracketed classes, including embedded '[' as a literal
    // member and an OR clause mixing named classes with a custom class.
    //
    // Real rule from the vendored 2026-09-12 snapshot, aeon.co.jp.

    func testCustomBracketedClassMixedWithNamedClassesInOneClause() throws {
        let raw = "minlength: 8; maxlength: 8; max-consecutive: 3; required: digit; required: upper,lower,[#$+./:=?@[^_|~];"
        guard case .success(let rules) = PasswordRulesParser.parse(raw) else {
            return XCTFail("expected a successful parse")
        }
        let customMembers: Set<Character> = ["#", "$", "+", ".", "/", ":", "=", "?", "@", "[", "^", "_", "|", "~"]
        XCTAssertEqual(rules.requiredClauses, [[.digit], [.upper, .lower, .custom(customMembers)]])
        XCTAssertTrue(rules.allowedClasses.contains(.custom(customMembers)))
    }

    // MARK: The doubled-']' rule -- ']]' means "one literal ']', then the
    // real closing bracket" -- plus a literal '[' as an ordinary member and
    // a literal ';' inside the class not ending the statement early.
    //
    // Real rule from the vendored 2026-09-12 snapshot, admiral.com. This is
    // the exact fixture the parsing-trap note above is about.

    func testDoubledClosingBracketEncodesALiteralBracketMember() throws {
        let raw = #"minlength: 8; required: digit; required: [- !"#$&'()*+,.:;<=>?@[^_`{|}~]]; allowed: lower, upper;"#
        guard case .success(let rules) = PasswordRulesParser.parse(raw) else {
            return XCTFail("expected a successful parse")
        }
        XCTAssertEqual(rules.minLength, 8)
        XCTAssertEqual(rules.requiredClauses.count, 2)
        guard case .custom(let members)? = rules.requiredClauses.last?.first else {
            return XCTFail("expected the second required clause to be a single custom class")
        }
        // The class contains both a literal '[' (an ordinary member, not a
        // nested class) and a literal ']' (from the doubled "]]" ending),
        // plus the leading '-' (literal only because it is first) and the
        // ';' in the middle (an ordinary ASCII-printable member, not a
        // premature end of the required: statement).
        XCTAssertTrue(members.contains("["))
        XCTAssertTrue(members.contains("]"))
        XCTAssertTrue(members.contains("-"))
        XCTAssertTrue(members.contains(";"))
        // allowed: lower, upper -- parsed AFTER the bracket closed, proving
        // the scanner correctly resumed top-level parsing past the class
        // rather than getting lost inside it.
        XCTAssertTrue(rules.allowedClasses.contains(.lower))
        XCTAssertTrue(rules.allowedClasses.contains(.upper))
    }

    // MARK: Cumulative `allowed:` across multiple clauses.
    //
    // Fixture from Apple's own tools/PasswordRulesParser/PasswordRulesParserTest.js
    // (the "duplicate allowed values are kept" case).

    func testAllowedIsCumulativeAcrossMultipleClauses() throws {
        let raw = "required: upper; allowed: upper; allowed: lower; minlength: 12; maxlength: 73;"
        guard case .success(let rules) = PasswordRulesParser.parse(raw) else {
            return XCTFail("expected a successful parse")
        }
        XCTAssertEqual(rules.requiredClauses, [[.upper]])
        XCTAssertEqual(rules.allowedClasses, [.upper, .lower])
        XCTAssertEqual(rules.minLength, 12)
        XCTAssertEqual(rules.maxLength, 73)
    }

    // MARK: A required class not named by any `allowed:` property is still
    // folded into the effective allowed set.
    //
    // Real rule from the vendored 2026-09-12 snapshot, benjerry.com -- note
    // the rule repeats `required: upper` twice; each occurrence is its own
    // AND'd clause, duplicates and all.

    func testRequiredClassFoldedIntoAllowedEvenWithoutAnAllowedProperty() throws {
        let raw = "required: upper; required: upper; required: digit; required: digit; required: special; required: special; allowed: lower;"
        guard case .success(let rules) = PasswordRulesParser.parse(raw) else {
            return XCTFail("expected a successful parse")
        }
        XCTAssertEqual(rules.requiredClauses.count, 6)
        // Only "lower" was named by an explicit allowed:, but upper/digit/
        // special are folded in because they are required.
        XCTAssertEqual(Set(rules.allowedClasses), [.lower, .upper, .digit, .special])
    }

    // MARK: Conflicting numeric properties -- minimum wins for
    // max-consecutive and maxlength, maximum wins for minlength.
    //
    // Fixtures from Apple's own PasswordRulesParserTest.js
    // ("duplicate max-consecutive keeps the minimum", "minlength keeps the
    // maximum", "maxlength keeps the minimum").

    func testConflictingMaxConsecutiveResolvesToMinimum() throws {
        guard case .success(let rules) = PasswordRulesParser.parse("max-consecutive: 5; max-consecutive: 3;") else {
            return XCTFail("expected a successful parse")
        }
        XCTAssertEqual(rules.maxConsecutive, 3)
    }

    func testConflictingMinLengthResolvesToMaximum() throws {
        guard case .success(let rules) = PasswordRulesParser.parse("minlength: 12; minlength: 7; minlength: 23;") else {
            return XCTFail("expected a successful parse")
        }
        XCTAssertEqual(rules.minLength, 23)
    }

    func testConflictingMaxLengthResolvesToMinimum() throws {
        guard case .success(let rules) = PasswordRulesParser.parse("maxlength: 10; maxlength: 7; maxlength: 12;") else {
            return XCTFail("expected a successful parse")
        }
        XCTAssertEqual(rules.maxLength, 7)
    }

    // MARK: Default to ascii-printable when nothing is allowed explicitly.
    //
    // Real rule from the vendored 2026-09-12 snapshot, 163.com -- no
    // required: and no allowed: at all.

    func testDefaultsToAsciiPrintableWhenNothingIsAllowedExplicitly() throws {
        guard case .success(let rules) = PasswordRulesParser.parse("minlength: 6; maxlength: 16;") else {
            return XCTFail("expected a successful parse")
        }
        XCTAssertEqual(rules.allowedClasses, [.asciiPrintable])
        XCTAssertTrue(rules.requiredClauses.isEmpty)
    }

    // MARK: max-repeating and max-sequential are parsed and stored, but
    // (per Decision 2 of the spec) never enforced by PasswordGenerator --
    // see that decision's rationale, restated in PasswordGenerator.swift's
    // own doc comment (Task 4). This proves parsing alone.
    //
    // Fixture from Apple's own PasswordRulesParserTest.js.

    func testMaxRepeatingAndMaxSequentialAreParsedAndStored() throws {
        guard case .success(let rules) = PasswordRulesParser.parse("max-consecutive: 2; max-repeating: 3; max-sequential: 4;") else {
            return XCTFail("expected a successful parse")
        }
        XCTAssertEqual(rules.maxConsecutive, 2)
        XCTAssertEqual(rules.maxRepeating, 3)
        XCTAssertEqual(rules.maxSequential, 4)
    }

    // MARK: Malformed input -- typed errors, never a crash.

    func testEmptyInputIsRejected() {
        XCTAssertEqual(PasswordRulesParser.parse(""), .failure(.emptyInput))
        XCTAssertEqual(PasswordRulesParser.parse("   "), .failure(.emptyInput))
    }

    func testUnknownPropertyNameIsRejected() {
        XCTAssertEqual(PasswordRulesParser.parse("foo: bar;"), .failure(.unknownProperty("foo")))
    }

    func testMalformedNumericValueIsRejected() {
        guard case .failure(.malformedValue(let property, let value)) = PasswordRulesParser.parse("minlength: abc;") else {
            return XCTFail("expected malformedValue")
        }
        XCTAssertEqual(property, "minlength")
        XCTAssertEqual(value, "abc")
    }

    func testUnterminatedCustomClassIsRejected() {
        XCTAssertEqual(PasswordRulesParser.parse("required: [abc"), .failure(.unterminatedCustomClass))
    }
}
```

- [ ] **Step 2: Run and confirm failure**

Run: `cd Packages/MyPassKit && swift test --filter PasswordRulesParserTests`
Expected: build fails — `PasswordRules`, `PasswordRulesParser`, and `PasswordRulesParseError` do not exist yet.

- [ ] **Step 3: Write `PasswordRules.swift`**

Create `Packages/MyPassKit/Sources/MyPassKit/PasswordRules/PasswordRules.swift`:

```swift
import Foundation

/// Apple's Password Rules grammar (https://developer.apple.com/password-rules/),
/// parsed into a structured value. See `PasswordRulesParser.parse(_:)` for
/// the parser and `PasswordRulesCatalog.rules(forHost:)` for domain lookup.
public struct PasswordRules: Equatable {
    public enum CharacterClass: Equatable, Hashable {
        case upper
        case lower
        case digit
        case special
        case asciiPrintable
        case unicode
        case custom(Set<Character>)
    }

    /// Each inner array is one `required:` clause -- its members are ORed.
    /// The outer array is the AND of every `required:` clause present.
    public var requiredClauses: [[CharacterClass]]
    /// The cumulative `allowed:` set, with every class named by any
    /// `requiredClauses` member already folded in.
    public var allowedClasses: [CharacterClass]
    public var minLength: Int?
    public var maxLength: Int?
    public var maxConsecutive: Int?
    /// Parsed and stored, never enforced by `PasswordGenerator` -- see
    /// that type's doc comment on why (Task 4 of
    /// docs/superpowers/plans/2026-09-12-site-password-rules-and-uri-matching.md).
    public var maxRepeating: Int?
    /// Parsed and stored, never enforced by `PasswordGenerator` -- see
    /// that type's doc comment on why.
    public var maxSequential: Int?

    init(
        requiredClauses: [[CharacterClass]] = [],
        allowedClasses: [CharacterClass] = [],
        minLength: Int? = nil,
        maxLength: Int? = nil,
        maxConsecutive: Int? = nil,
        maxRepeating: Int? = nil,
        maxSequential: Int? = nil
    ) {
        self.requiredClauses = requiredClauses
        self.allowedClasses = allowedClasses
        self.minLength = minLength
        self.maxLength = maxLength
        self.maxConsecutive = maxConsecutive
        self.maxRepeating = maxRepeating
        self.maxSequential = maxSequential
    }
}

public enum PasswordRulesParseError: Error, Equatable {
    case emptyInput
    case unknownProperty(String)
    case malformedValue(property: String, value: String)
    case unterminatedCustomClass
}
```

The initializer is intentionally not `public` — the only production call site is `PasswordRulesParser.parse` inside this same module; `@testable import MyPassKit` gives every test target above access to it too, so `PasswordRulesParserTests`, `PasswordGeneratorRulesTests` (Task 4), and `PasswordRulesConformanceTests` (Task 5) can all construct fixtures directly without MyPass's public API surface growing a constructor nothing outside the package needs.

- [ ] **Step 4: Write `PasswordRulesParser.swift`**

Create `Packages/MyPassKit/Sources/MyPassKit/PasswordRules/PasswordRulesParser.swift`:

```swift
import Foundation

/// Parses Apple's Password Rules grammar
/// (https://developer.apple.com/password-rules/), the same grammar used by
/// the vendored `password-rules.json` (see
/// `Resources/PASSWORD_RULES_PROVENANCE.md`).
///
/// This parser deliberately does NOT match the leniency of Apple's own
/// reference implementation (`tools/PasswordRulesParser/PasswordRulesParser.js`
/// in `apple/password-manager-resources`), which logs a console warning and
/// silently degrades a malformed rule to "allow ascii-printable" rather than
/// failing outright. That leniency is the right default for a browser
/// autofill heuristic running against untrusted page content; it is the
/// wrong default for a password manager's own generator, where a malformed
/// rule silently producing a password the target site's real policy would
/// reject is a worse outcome than a typed, caller-visible parse error.
/// `PasswordRulesCatalog.rules(forHost:)` (Task 3) is what actually applies
/// leniency at the right boundary instead: a parse failure for one catalog
/// entry is treated as "this domain has no rule" (falls back to plain
/// generator toggles), not as a crash and not as a silently-wrong password.
public enum PasswordRulesParser {
    private static let namedClasses: [String: PasswordRules.CharacterClass] = [
        "upper": .upper,
        "lower": .lower,
        "digit": .digit,
        "special": .special,
        "ascii-printable": .asciiPrintable,
        "unicode": .unicode,
    ]

    public static func parse(_ raw: String) -> Result<PasswordRules, PasswordRulesParseError> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.emptyInput) }

        let chars = Array(trimmed)
        var index = 0

        var requiredClauses: [[PasswordRules.CharacterClass]] = []
        var explicitAllowed: [PasswordRules.CharacterClass] = []
        var sawAllowedProperty = false
        var minLengths: [Int] = []
        var maxLengths: [Int] = []
        var maxConsecutives: [Int] = []
        var maxRepeatings: [Int] = []
        var maxSequentials: [Int] = []

        func skipWhitespace() {
            while index < chars.count, chars[index].isWhitespace {
                index += 1
            }
        }

        skipWhitespace()
        while index < chars.count {
            // Tolerate stray/repeated ';' between properties (real data
            // never has this, but Apple's own reference parser does not
            // error on it either -- see `_parsePasswordRulesInternal`).
            if chars[index] == ";" {
                index += 1
                skipWhitespace()
                continue
            }

            // Property names never contain ':', so the next ':' from here
            // is always THIS property's value-start sentinel -- safe to
            // search for directly rather than tokenizing character classes
            // (identifier characters only), because we are always
            // positioned at the start of a name when this runs.
            guard let colonIndex = chars[index...].firstIndex(of: ":") else {
                let remainder = String(chars[index...]).trimmingCharacters(in: .whitespacesAndNewlines)
                return .failure(.unknownProperty(remainder))
            }
            let name = String(chars[index..<colonIndex])
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            index = colonIndex + 1
            skipWhitespace()

            switch name {
            case "required":
                switch parseClassListValue(chars, index: &index, property: name) {
                case .success(let classes): requiredClauses.append(classes)
                case .failure(let error): return .failure(error)
                }
            case "allowed":
                sawAllowedProperty = true
                switch parseClassListValue(chars, index: &index, property: name) {
                case .success(let classes):
                    for characterClass in classes where !explicitAllowed.contains(characterClass) {
                        explicitAllowed.append(characterClass)
                    }
                case .failure(let error): return .failure(error)
                }
            case "minlength":
                switch parseNonNegativeIntValue(chars, index: &index, property: name) {
                case .success(let n): minLengths.append(n)
                case .failure(let error): return .failure(error)
                }
            case "maxlength":
                switch parseNonNegativeIntValue(chars, index: &index, property: name) {
                case .success(let n): maxLengths.append(n)
                case .failure(let error): return .failure(error)
                }
            case "max-consecutive":
                switch parseNonNegativeIntValue(chars, index: &index, property: name) {
                case .success(let n): maxConsecutives.append(n)
                case .failure(let error): return .failure(error)
                }
            case "max-repeating":
                switch parseNonNegativeIntValue(chars, index: &index, property: name) {
                case .success(let n): maxRepeatings.append(n)
                case .failure(let error): return .failure(error)
                }
            case "max-sequential":
                switch parseNonNegativeIntValue(chars, index: &index, property: name) {
                case .success(let n): maxSequentials.append(n)
                case .failure(let error): return .failure(error)
                }
            default:
                return .failure(.unknownProperty(name))
            }

            skipWhitespace()
            if index < chars.count {
                guard chars[index] == ";" else {
                    return .failure(.malformedValue(property: name, value: String(chars[index...])))
                }
                index += 1
                skipWhitespace()
            }
        }

        // Every class named anywhere in requiredClauses is, definitionally,
        // also allowed -- folded in regardless of whether an explicit
        // `allowed:` property named it too. If no `allowed:` property was
        // ever seen, the base set defaults to ascii-printable.
        var allowedClasses = sawAllowedProperty ? explicitAllowed : [.asciiPrintable]
        for clause in requiredClauses {
            for characterClass in clause where !allowedClasses.contains(characterClass) {
                allowedClasses.append(characterClass)
            }
        }

        return .success(PasswordRules(
            requiredClauses: requiredClauses,
            allowedClasses: allowedClasses,
            minLength: minLengths.max(),
            maxLength: maxLengths.min(),
            maxConsecutive: maxConsecutives.min(),
            maxRepeating: maxRepeatings.min(),
            maxSequential: maxSequentials.min()
        ))
    }

    /// Parses one `required:`/`allowed:` value: comma-separated tokens,
    /// each a named identifier or a bracketed custom class, stopping at the
    /// first top-level ';' (never inside a bracket) or end of input.
    /// Matches Apple's reference `_parsePasswordRequiredOrAllowedPropertyValue`.
    private static func parseClassListValue(
        _ chars: [Character],
        index: inout Int,
        property: String
    ) -> Result<[PasswordRules.CharacterClass], PasswordRulesParseError> {
        var classes: [PasswordRules.CharacterClass] = []

        func skipHorizontalWhitespace() {
            while index < chars.count, chars[index] == " " || chars[index] == "\t" {
                index += 1
            }
        }

        skipHorizontalWhitespace()
        while index < chars.count, chars[index] != ";" {
            if chars[index] == "[" {
                switch parseCustomCharacterClass(chars, from: &index) {
                case .success(let members):
                    // An empty custom class ("[]") contributes nothing,
                    // matching the reference parser's "[], [b]" -> ["[b]"].
                    if !members.isEmpty {
                        classes.append(.custom(Set(members)))
                    }
                case .failure(let error):
                    return .failure(error)
                }
            } else {
                var token = ""
                while index < chars.count, chars[index] != ",", chars[index] != ";" {
                    token.append(chars[index])
                    index += 1
                }
                let identifier = token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard let characterClass = namedClasses[identifier] else {
                    return .failure(.malformedValue(property: property, value: identifier))
                }
                classes.append(characterClass)
            }

            skipHorizontalWhitespace()
            guard index < chars.count else { break }
            if chars[index] == "," {
                index += 1
                skipHorizontalWhitespace()
            } else if chars[index] == ";" {
                break
            } else {
                return .failure(.malformedValue(property: property, value: String(chars[index...])))
            }
        }

        guard !classes.isEmpty else {
            return .failure(.malformedValue(property: property, value: ""))
        }
        return .success(classes)
    }

    /// Scans one bracketed custom class starting at `chars[index] == "["`,
    /// advancing `index` past its closing bracket. Matches Apple's
    /// reference `_parseCustomCharacterClass` exactly, including its two
    /// least-obvious rules:
    ///
    /// 1. A `]` is tentatively treated as the closing delimiter, but if the
    ///    very next character is ALSO `]`, the first one was a literal
    ///    member instead and the second one closes the class -- this is
    ///    how `costco.com`'s real rule, ending
    ///    `required: [-!#$%&'()*+/:;=?@[^_\`{|}~]];`, encodes a class that
    ///    contains both a literal `[` and a literal `]`.
    /// 2. A `-` is a literal member only when it is the very first
    ///    character after `[`; anywhere else it is silently dropped
    ///    (non-fatal, matching the reference parser's own "a '-' may only
    ///    appear as the first character" behavior).
    ///
    /// Any other ASCII-printable character (0x20...0x7E), `;` and `,`
    /// included, is an ordinary literal member; non-ASCII-printable
    /// characters are silently skipped.
    private static func parseCustomCharacterClass(
        _ chars: [Character],
        from index: inout Int
    ) -> Result<[Character], PasswordRulesParseError> {
        precondition(chars[index] == "[")
        index += 1
        let start = index
        var members: [Character] = []

        while index < chars.count {
            let c = chars[index]
            guard let ascii = c.asciiValue, ascii >= 0x20, ascii <= 0x7E else {
                index += 1
                continue
            }
            if c == "-", index > start {
                index += 1
                continue
            }
            members.append(c)
            index += 1
            if c == "]" {
                break
            }
        }

        guard let last = members.last, last == "]" else {
            return .failure(.unterminatedCustomClass)
        }

        if index < chars.count, chars[index] == "]" {
            // Doubled "]]": the first was a literal member (already
            // appended above), the second is the real closing delimiter.
            index += 1
            return .success(members)
        }

        // The single "]" we appended was the delimiter, not a member.
        members.removeLast()
        return .success(members)
    }

    private static func parseNonNegativeIntValue(
        _ chars: [Character],
        index: inout Int,
        property: String
    ) -> Result<Int, PasswordRulesParseError> {
        var digits = ""
        while index < chars.count, chars[index] != ";" {
            digits.append(chars[index])
            index += 1
        }
        let trimmed = digits.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let n = Int(trimmed), n >= 0 else {
            return .failure(.malformedValue(property: property, value: trimmed))
        }
        return .success(n)
    }
}
```

- [ ] **Step 5: Run and confirm pass**

Run: `cd Packages/MyPassKit && swift test --filter PasswordRulesParserTests`
Expected: PASS, all 14 tests.

- [ ] **Step 6: Commit**

```bash
git add Packages/MyPassKit/Sources/MyPassKit/PasswordRules/PasswordRules.swift \
        Packages/MyPassKit/Sources/MyPassKit/PasswordRules/PasswordRulesParser.swift \
        Packages/MyPassKit/Tests/MyPassKitTests/PasswordRulesParserTests.swift
git commit -m "feat(app): parse Apple's Password Rules grammar"
```

---

## Task 3 — PasswordRulesCatalog

**Interfaces:**
- Produces: `Packages/MyPassKit/Sources/MyPassKit/PasswordRules/PasswordRulesCatalog.swift`, containing the public `PasswordRulesCatalog.rules(forHost:)` and an internal `PasswordRulesIndex` type the tests construct directly.
- Consumes: `PasswordRulesParser.parse` (Task 2), `PublicSuffixList.registrableDomain(of:)` (existing), the bundled `password-rules.json` resource (Task 1).

`PasswordRulesIndex` is a small, dependency-free `internal` type separated out from `PasswordRulesCatalog` specifically so `PasswordRulesCatalogTests` can construct one directly, via `@testable import`, with a tiny synthetic fixture — the public contract is only `PasswordRulesCatalog.rules(forHost:) -> PasswordRules?`, with no injection point, so testing the registrable-domain-walk boundary precisely (a case that essentially never arises in the real 436-entry snapshot, since no real key sits above any real registrable domain) needs a fixture built by hand rather than a lucky find in real data.

- [ ] **Step 1: Write the failing tests**

Create `Packages/MyPassKit/Tests/MyPassKitTests/PasswordRulesCatalogTests.swift`:

```swift
import XCTest
@testable import MyPassKit

final class PasswordRulesCatalogTests: XCTestCase {
    func testSubdomainWalkFindsParentRule() {
        let index = PasswordRulesIndex(entries: [
            "example.com": PasswordRulesIndex.Entry(passwordRules: "minlength: 10; required: digit;")
        ])
        let rules = index.rules(forHost: "login.accounts.example.com")
        XCTAssertEqual(rules?.minLength, 10)
        XCTAssertEqual(rules?.requiredClauses, [[.digit]])
    }

    func testLookupStopsAtTheRegistrableDomain() {
        // "co.uk" is itself a public suffix per the bundled Public Suffix
        // List; a rule keyed there must never leak onto an unrelated site
        // that merely shares that suffix, even though the walk would
        // otherwise pass right by it.
        let index = PasswordRulesIndex(entries: [
            "co.uk": PasswordRulesIndex.Entry(passwordRules: "minlength: 20;")
        ])
        XCTAssertNil(index.rules(forHost: "attacker.example.co.uk"))
    }

    func testUnknownHostReturnsNil() {
        let index = PasswordRulesIndex(entries: [
            "example.com": PasswordRulesIndex.Entry(passwordRules: "minlength: 10;")
        ])
        XCTAssertNil(index.rules(forHost: "totally-unrelated.org"))
    }

    func testExactDomainMatchOnlyEntryDoesNotMatchSubdomain() {
        let index = PasswordRulesIndex(entries: [
            "accounts.example.com": PasswordRulesIndex.Entry(passwordRules: "minlength: 12;", exactDomainMatchOnly: true)
        ])
        XCTAssertEqual(index.rules(forHost: "accounts.example.com")?.minLength, 12)
        XCTAssertNil(index.rules(forHost: "login.accounts.example.com"))
    }

    func testMalformedRuleYieldsNilRatherThanThrowing() {
        let index = PasswordRulesIndex(entries: [
            "example.com": PasswordRulesIndex.Entry(passwordRules: "this-is-not-a-recognized-property: 1;")
        ])
        XCTAssertNil(index.rules(forHost: "example.com"))
    }

    func testCatalogReadsTheRealBundledResource() {
        // Sanity check that PasswordRulesCatalog's public API actually
        // reads the bundled password-rules.json, not just that
        // PasswordRulesIndex works in isolation -- "163.com" is a real key
        // in the 2026-09-12 snapshot.
        XCTAssertNotNil(PasswordRulesCatalog.rules(forHost: "163.com"))
    }
}
```

- [ ] **Step 2: Run and confirm failure**

Run: `cd Packages/MyPassKit && swift test --filter PasswordRulesCatalogTests`
Expected: build fails — `PasswordRulesIndex` and `PasswordRulesCatalog` do not exist yet.

- [ ] **Step 3: Write `PasswordRulesCatalog.swift`**

Create `Packages/MyPassKit/Sources/MyPassKit/PasswordRules/PasswordRulesCatalog.swift`:

```swift
import Foundation

/// Dependency-free index over the Password Rules catalog's raw shape,
/// separated out from `PasswordRulesCatalog` purely so
/// `PasswordRulesCatalogTests` can construct one directly with a small
/// synthetic fixture (via `@testable import`) to test the
/// registrable-domain-walk and `exact-domain-match-only` boundary
/// conditions precisely, without needing the real 436-entry vendored
/// catalog to happen to contain a fixture shaped the right way.
final class PasswordRulesIndex {
    struct Entry {
        let passwordRules: String
        let exactDomainMatchOnly: Bool

        init(passwordRules: String, exactDomainMatchOnly: Bool = false) {
            self.passwordRules = passwordRules
            self.exactDomainMatchOnly = exactDomainMatchOnly
        }
    }

    private let entries: [String: Entry] // key: lowercased domain
    private let lock = NSLock()
    private var parseCache: [String: PasswordRules?] = [:]

    init(entries: [String: Entry]) {
        var lowercased: [String: Entry] = [:]
        lowercased.reserveCapacity(entries.count)
        for (domain, entry) in entries {
            lowercased[domain.lowercased()] = entry
        }
        self.entries = lowercased
    }

    /// Nil when no rule applies. Walks upward from `host` -- the full host,
    /// then each parent label, down to (and including) its registrable
    /// domain computed via `PublicSuffixList.registrableDomain(of:)`, the
    /// same type `ExtensionEntryMatcher` already depends on for domain
    /// reduction -- and never above it, so a rule can never apply to an
    /// unrelated site that happens to share a public suffix. A rule keyed
    /// at any level matches every subdomain underneath it down to (and
    /// including) the exact host, UNLESS that entry's
    /// `exactDomainMatchOnly` is set, in which case it matches only the
    /// exact host it was looked up with, never a longer subdomain
    /// discovered by walking upward past it.
    func rules(forHost host: String) -> PasswordRules? {
        let normalizedHost = host.lowercased()
        guard !normalizedHost.isEmpty else { return nil }

        let ceiling = PublicSuffixList.registrableDomain(of: normalizedHost) ?? normalizedHost
        var candidate = normalizedHost

        while true {
            let isExactHost = (candidate == normalizedHost)
            if let entry = entries[candidate], isExactHost || !entry.exactDomainMatchOnly {
                if let parsed = parsedRules(forDomain: candidate, raw: entry.passwordRules) {
                    return parsed
                }
            }

            if candidate == ceiling {
                return nil
            }
            guard let dotIndex = candidate.firstIndex(of: ".") else {
                return nil
            }
            candidate = String(candidate[candidate.index(after: dotIndex)...])
        }
    }

    /// A rule string that fails to parse behaves as "this domain has no
    /// rule" (Decision 2/3 of the spec) -- cached the same as a successful
    /// parse, so a bad row in the catalog only ever costs one parse
    /// attempt per domain, not one per lookup.
    private func parsedRules(forDomain domain: String, raw: String) -> PasswordRules? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = parseCache[domain] {
            return cached
        }
        let parsed: PasswordRules?
        switch PasswordRulesParser.parse(raw) {
        case .success(let rules): parsed = rules
        case .failure: parsed = nil
        }
        parseCache[domain] = .some(parsed)
        return parsed
    }
}

/// Rule lookup keyed by host, over the vendored `password-rules.json`
/// (Task 1). See `PasswordRulesIndex.rules(forHost:)` for the actual
/// registrable-domain walk; this type only owns loading and decoding the
/// bundled resource, lazily, once, on first use.
public enum PasswordRulesCatalog {
    private struct RawJSONEntry: Decodable {
        let passwordRules: String
        let exactDomainMatchOnly: Bool

        enum CodingKeys: String, CodingKey {
            case passwordRules = "password-rules"
            case exactDomainMatchOnly = "exact-domain-match-only"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            passwordRules = try container.decode(String.self, forKey: .passwordRules)
            exactDomainMatchOnly = try container.decodeIfPresent(Bool.self, forKey: .exactDomainMatchOnly) ?? false
        }
    }

    private static let index: PasswordRulesIndex = loadIndex()

    private static func loadIndex() -> PasswordRulesIndex {
        // Fail closed rather than falling back to an empty catalog,
        // matching PublicSuffixList.swift's own justification for
        // fatalError over a silent empty fallback: an empty catalog
        // wouldn't crash anything downstream (PasswordGenerator already
        // treats `rules: nil` as "use plain toggles"), but it would
        // silently and permanently disable this entire feature for every
        // site, indistinguishable from "this site simply has no known
        // rule" -- exactly the failure mode a missing/corrupt bundled
        // resource should never be allowed to hide as normal behavior.
        guard let url = Bundle.module.url(forResource: "password-rules", withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            fatalError("PasswordRulesCatalog: missing or unreadable password-rules.json resource")
        }
        guard let decoded = try? JSONDecoder().decode([String: RawJSONEntry].self, from: data) else {
            fatalError("PasswordRulesCatalog: password-rules.json failed to decode as [String: RawJSONEntry]")
        }
        let entries = decoded.mapValues {
            PasswordRulesIndex.Entry(passwordRules: $0.passwordRules, exactDomainMatchOnly: $0.exactDomainMatchOnly)
        }
        return PasswordRulesIndex(entries: entries)
    }

    /// Nil when no rule applies -- the caller falls back to plain generator
    /// options.
    public static func rules(forHost host: String) -> PasswordRules? {
        index.rules(forHost: host)
    }
}
```

- [ ] **Step 4: Run and confirm pass**

Run: `cd Packages/MyPassKit && swift test --filter PasswordRulesCatalogTests`
Expected: PASS, all 6 tests.

- [ ] **Step 5: Commit**

```bash
git add Packages/MyPassKit/Sources/MyPassKit/PasswordRules/PasswordRulesCatalog.swift \
        Packages/MyPassKit/Tests/MyPassKitTests/PasswordRulesCatalogTests.swift
git commit -m "feat(app): look up password rules by host with a registrable-domain ceiling"
```

---

## Task 4 — The generator honours rules

**Interfaces:**
- Produces: `PasswordGenerator.generate(options:rules:)` (the `rules` parameter is new, default `nil`); `PasswordGeneratorError.unsatisfiableRules` (new case).
- Consumes: `PasswordRules` and `PasswordRules.CharacterClass` (Task 2).
- Must NOT change observable behavior of `PasswordGenerator.generate(options:)` called without `rules` — the existing `PasswordGeneratorTests.swift` suite (6 tests) must keep passing completely unmodified, because that call path is moved verbatim into a private helper rather than rebuilt on shared code.

- [ ] **Step 1: Confirm the baseline**

Run: `cd Packages/MyPassKit && swift test --filter PasswordGeneratorTests`
Expected: PASS (6 tests), with the current single-path implementation still in place.

- [ ] **Step 2: Write the failing tests**

Create `Packages/MyPassKit/Tests/MyPassKitTests/PasswordGeneratorRulesTests.swift`:

```swift
import XCTest
@testable import MyPassKit

final class PasswordGeneratorRulesTests: XCTestCase {
    func testLengthIsClampedIntoTheRuleRange() throws {
        let rules = PasswordRules(minLength: 10, maxLength: 12)
        let options = PasswordGeneratorOptions(length: 20, includeLowercase: true, includeUppercase: true, includeDigits: true, includeSymbols: true)
        let password = try PasswordGenerator.generate(options: options, rules: rules)
        XCTAssertEqual(password.count, 12)
    }

    func testRequiredClassOverridesADisabledToggle() throws {
        let rules = PasswordRules(requiredClauses: [[.digit]], allowedClasses: [.digit, .lower])
        let options = PasswordGeneratorOptions(length: 16, includeLowercase: true, includeUppercase: false, includeDigits: false, includeSymbols: false)
        let password = try PasswordGenerator.generate(options: options, rules: rules)
        XCTAssertTrue(password.contains { $0.isNumber }, "a rule-required digit must appear even though includeDigits is off")
    }

    func testCustomRequiredClassAppearsInOutput() throws {
        let customMembers: Set<Character> = ["!", "@", "#"]
        let rules = PasswordRules(requiredClauses: [[.custom(customMembers)]], allowedClasses: [.custom(customMembers), .lower])
        let options = PasswordGeneratorOptions(length: 12, includeLowercase: true, includeUppercase: false, includeDigits: false, includeSymbols: false)
        let password = try PasswordGenerator.generate(options: options, rules: rules)
        XCTAssertTrue(password.contains { customMembers.contains($0) })
    }

    func testMaxConsecutiveIsNeverViolatedAcrossManyGenerations() throws {
        // Statistical proof that the generator honours max-consecutive
        // regardless of which internal path resolves a given attempt --
        // plain rejection sampling, or the deterministic-construction
        // fallback with repair. A two-character pool makes long runs
        // common enough by chance that 200 generations is a meaningful
        // check, not just a lucky pass.
        let rules = PasswordRules(allowedClasses: [.custom(["a", "b"])], maxConsecutive: 2)
        let options = PasswordGeneratorOptions(length: 24, includeLowercase: false, includeUppercase: false, includeDigits: false, includeSymbols: false)
        for _ in 0..<200 {
            let password = try PasswordGenerator.generate(options: options, rules: rules)
            let characters = Array(password)
            var run = 1
            for i in 1..<characters.count {
                run = characters[i] == characters[i - 1] ? run + 1 : 1
                XCTAssertLessThanOrEqual(run, 2)
            }
        }
    }

    func testUnsatisfiableRulesThrowsForAnImpossibleCombination() {
        // maxlength: 1 with two distinct required clauses can never be
        // satisfied -- there is only one character to place, and it can
        // satisfy at most one clause.
        let rules = PasswordRules(requiredClauses: [[.digit], [.upper]], allowedClasses: [.digit, .upper], maxLength: 1)
        let options = PasswordGeneratorOptions(length: 1, includeLowercase: false, includeUppercase: true, includeDigits: true, includeSymbols: false)
        XCTAssertThrowsError(try PasswordGenerator.generate(options: options, rules: rules)) { error in
            guard case PasswordGeneratorError.unsatisfiableRules = error else {
                return XCTFail("expected unsatisfiableRules, got \(error)")
            }
        }
    }
}
```

- [ ] **Step 3: Run and confirm failure**

Run: `cd Packages/MyPassKit && swift test --filter PasswordGeneratorRulesTests`
Expected: build fails — `generate(options:rules:)` does not exist yet (only `generate(options:)`), and `PasswordGeneratorError.unsatisfiableRules` does not exist.

- [ ] **Step 4: Implement the rules-aware path**

Replace the whole contents of `Packages/MyPassKit/Sources/MyPassKit/PasswordGenerator/PasswordGenerator.swift`:

```swift
import Foundation
import Security

public struct PasswordGeneratorOptions {
    public var length: Int
    public var includeLowercase: Bool
    public var includeUppercase: Bool
    public var includeDigits: Bool
    public var includeSymbols: Bool

    public init(length: Int, includeLowercase: Bool, includeUppercase: Bool, includeDigits: Bool, includeSymbols: Bool) {
        self.length = length
        self.includeLowercase = includeLowercase
        self.includeUppercase = includeUppercase
        self.includeDigits = includeDigits
        self.includeSymbols = includeSymbols
    }
}

public enum PasswordGeneratorError: Error, Equatable {
    case noCharacterClassSelected
    case secureRandomUnavailable
    /// A rule's constraints cannot be satisfied by any combination this
    /// generator can produce -- e.g. `maxlength` smaller than the number of
    /// distinct required clauses, or required classes whose combined
    /// character sets have no room left after length clamping.
    case unsatisfiableRules
}

public enum PasswordGenerator {
    private static let lowercase = Array("abcdefghijklmnopqrstuvwxyz")
    private static let uppercase = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
    private static let digits = Array("0123456789")
    private static let symbols = Array("!@#$%^&*()-_=+[]{};:,.<>?")

    /// `rules` is optional and defaults to `nil` so every existing call
    /// site (the standalone generator UI, before Task 7 wires it up to a
    /// site) is unaffected. When `rules` is nil, this dispatches to
    /// `generateWithoutRules`, whose body is byte-for-byte the function's
    /// pre-Task-4 implementation -- not rebuilt on top of the new shared
    /// helpers below -- specifically so the pre-existing
    /// `PasswordGeneratorTests.swift` suite keeps proving zero behavior
    /// change for that path.
    public static func generate(options: PasswordGeneratorOptions, rules: PasswordRules? = nil) throws -> String {
        guard let rules else {
            return try generateWithoutRules(options: options)
        }
        return try generateHonoringRules(options: options, rules: rules)
    }

    private static func generateWithoutRules(options: PasswordGeneratorOptions) throws -> String {
        var pool: [Character] = []
        if options.includeLowercase { pool.append(contentsOf: lowercase) }
        if options.includeUppercase { pool.append(contentsOf: uppercase) }
        if options.includeDigits { pool.append(contentsOf: digits) }
        if options.includeSymbols { pool.append(contentsOf: symbols) }
        guard !pool.isEmpty else { throw PasswordGeneratorError.noCharacterClassSelected }
        guard options.length > 0 else { return "" }

        // Reject bytes that would introduce modulo bias for a non-power-of-two
        // pool size: only accept bytes below the largest multiple of
        // pool.count that fits in a UInt8 range.
        let limit = UInt8(256 - (256 % pool.count))

        var result = ""
        result.reserveCapacity(options.length)
        for _ in 0..<options.length {
            let byte = try secureRandomByte(below: limit)
            result.append(pool[Int(byte) % pool.count])
        }
        return result
    }

    // MARK: - Rules-aware generation (Decision 4 of the spec)

    /// Which literal characters satisfy each `PasswordRules.CharacterClass`,
    /// built once per `generateHonoringRules` call from the rule and the
    /// user's own toggles.
    private struct EffectivePool {
        let characters: [Character]
        private let membership: [PasswordRules.CharacterClass: Set<Character>]

        init(characters: [Character], membership: [PasswordRules.CharacterClass: Set<Character>]) {
            self.characters = characters
            self.membership = membership
        }

        func characters(for characterClass: PasswordRules.CharacterClass) -> [Character] {
            Array(membership[characterClass] ?? [])
        }

        func contains(_ character: Character, in characterClass: PasswordRules.CharacterClass) -> Bool {
            membership[characterClass]?.contains(character) ?? false
        }
    }

    private static func generateHonoringRules(options: PasswordGeneratorOptions, rules: PasswordRules) throws -> String {
        let minLength = rules.minLength ?? options.length
        let maxLength = rules.maxLength ?? options.length
        // Defensive only -- no rule in the vendored 2026-09-12 snapshot has
        // minlength > maxlength (verified while writing this plan), but a
        // future refresh (scripts/update-password-rules.sh) could vendor
        // one, and an inverted range must never silently produce a
        // negative-length request below.
        guard minLength <= maxLength else {
            throw PasswordGeneratorError.unsatisfiableRules
        }
        let length = Swift.min(Swift.max(options.length, minLength), maxLength)

        let pool = try effectivePool(options: options, rules: rules)
        guard !pool.characters.isEmpty else {
            throw PasswordGeneratorError.noCharacterClassSelected
        }
        guard length >= rules.requiredClauses.count else {
            throw PasswordGeneratorError.unsatisfiableRules
        }

        // Each required clause needs at least one character from its own
        // OR'd set of contributing characters; a clause none of whose
        // members contributed any character to the pool can never be
        // satisfied no matter how many attempts are made.
        let clauseCharacterSets = try rules.requiredClauses.map { clause -> [Character] in
            let members = clause.flatMap { pool.characters(for: $0) }
            guard !members.isEmpty else {
                throw PasswordGeneratorError.unsatisfiableRules
            }
            return members
        }

        for _ in 0..<100 {
            let candidate = try randomString(length: length, from: pool.characters)
            if satisfies(candidate, requiredClauses: rules.requiredClauses, pool: pool, maxConsecutive: rules.maxConsecutive) {
                return candidate
            }
        }

        // Rejection sampling didn't converge in 100 tries -- realistic only
        // for a pathologically tight rule. Fall back to deterministic
        // construction: place one guaranteed-satisfying character per
        // required clause, fill the rest from the pool, shuffle with an
        // unbiased Fisher-Yates so the anchors aren't predictably in the
        // first N positions, then repair any remaining max-consecutive
        // violation. Re-verify before returning either way.
        for _ in 0..<10 {
            var characters: [Character] = try clauseCharacterSets.map { members in
                try randomElement(of: members)
            }
            while characters.count < length {
                characters.append(try randomElement(of: pool.characters))
            }
            try fisherYatesShuffle(&characters)
            if let maxConsecutive = rules.maxConsecutive {
                try repairMaxConsecutive(&characters, maxConsecutive: maxConsecutive, pool: pool.characters)
            }
            let candidate = String(characters)
            if satisfies(candidate, requiredClauses: rules.requiredClauses, pool: pool, maxConsecutive: rules.maxConsecutive) {
                return candidate
            }
        }

        throw PasswordGeneratorError.unsatisfiableRules
    }

    private static func isCustomClass(_ characterClass: PasswordRules.CharacterClass) -> Bool {
        if case .custom = characterClass { return true }
        return false
    }

    private static func effectivePool(options: PasswordGeneratorOptions, rules: PasswordRules) throws -> EffectivePool {
        var membership: [PasswordRules.CharacterClass: Set<Character>] = [:]
        var allCharacters: Set<Character> = []

        let requiredClassesFlat = Set(rules.requiredClauses.flatMap { $0 })
        let asciiPrintableInPlay = rules.allowedClasses.contains(.asciiPrintable)

        // Four toggle-backed classes: included when the rule allows the
        // class (directly, or via `.asciiPrintable` standing in for "any of
        // these four is fine") AND the user's own toggle is on -- except a
        // class the rule REQUIRES is forced in regardless of the toggle
        // (Decision 4: "a site that mandates a digit gets one even if the
        // user turned digits off").
        let toggleBacked: [(PasswordRules.CharacterClass, Bool, [Character])] = [
            (.lower, options.includeLowercase, lowercase),
            (.upper, options.includeUppercase, uppercase),
            (.digit, options.includeDigits, digits),
            (.special, options.includeSymbols, symbols),
        ]
        for (characterClass, toggleOn, baseline) in toggleBacked {
            let ruleAllows = rules.allowedClasses.contains(characterClass) || asciiPrintableInPlay
            let ruleRequires = requiredClassesFlat.contains(characterClass)
            guard ruleRequires || (ruleAllows && toggleOn) else { continue }
            membership[characterClass, default: []].formUnion(baseline)
            allCharacters.formUnion(baseline)
        }

        // Custom classes contribute their literal characters directly,
        // independent of MyPass's own four baseline pools (Decision 4) --
        // Apple's `special` class and this app's `symbols` pool are not the
        // same set, and a site's bespoke required symbol may fall outside
        // it. Applies whether the custom class came from `allowed:` or
        // `required:`.
        for characterClass in rules.allowedClasses where isCustomClass(characterClass) {
            if case .custom(let members) = characterClass {
                membership[characterClass, default: []].formUnion(members)
                allCharacters.formUnion(members)
            }
        }
        for characterClass in requiredClassesFlat where isCustomClass(characterClass) {
            if case .custom(let members) = characterClass {
                membership[characterClass, default: []].formUnion(members)
                allCharacters.formUnion(members)
            }
        }

        // `.unicode` is deliberately unsupported: none of MyPass's baseline
        // character pools contain non-ASCII characters. In the vendored
        // 2026-09-12 snapshot exactly one domain (verizonwireless.com)
        // names `unicode` at all, and only in an `allowed:` clause, never
        // `required:` -- so this limitation never has to reject a real
        // rule outright, it just means MyPass never emits non-ASCII
        // characters even where a site would tolerate them. A hypothetical
        // future rule that REQUIRES `.unicode` with no other satisfiable
        // clause member would surface as `.unsatisfiableRules` below,
        // rather than this function inventing a Unicode character pool
        // that doesn't exist anywhere else in this codebase.

        return EffectivePool(characters: Array(allCharacters), membership: membership)
    }

    private static func satisfies(
        _ candidate: String,
        requiredClauses: [[PasswordRules.CharacterClass]],
        pool: EffectivePool,
        maxConsecutive: Int?
    ) -> Bool {
        let characters = Array(candidate)
        for clause in requiredClauses {
            let clauseSatisfied = characters.contains { character in
                clause.contains { pool.contains(character, in: $0) }
            }
            guard clauseSatisfied else { return false }
        }
        if let maxConsecutive, characters.count > 1 {
            var run = 1
            for i in 1..<characters.count {
                run = characters[i] == characters[i - 1] ? run + 1 : 1
                if run > maxConsecutive { return false }
            }
        }
        return true
    }

    private static func randomString(length: Int, from pool: [Character]) throws -> String {
        guard !pool.isEmpty else { throw PasswordGeneratorError.noCharacterClassSelected }
        var result = ""
        result.reserveCapacity(length)
        for _ in 0..<length {
            result.append(try randomElement(of: pool))
        }
        return result
    }

    private static func randomElement(of pool: [Character]) throws -> Character {
        guard !pool.isEmpty else { throw PasswordGeneratorError.unsatisfiableRules }
        let limit = UInt8(256 - (256 % pool.count))
        let byte = try secureRandomByte(below: limit)
        return pool[Int(byte) % pool.count]
    }

    /// Unbiased Fisher-Yates shuffle, driven by the same rejection-sampled
    /// `SecRandomCopyBytes` source as every other random draw in this type
    /// -- Decision 4 of the spec requires the shuffle to carry the
    /// identical no-modulo-bias guarantee as character selection, not a
    /// separately-reasoned-about source of randomness.
    private static func fisherYatesShuffle(_ characters: inout [Character]) throws {
        guard characters.count > 1 else { return }
        var index = characters.count - 1
        while index > 0 {
            let upperBoundExclusive = index + 1 // choose j in 0...index
            let limit = UInt8(256 - (256 % upperBoundExclusive))
            let byte = try secureRandomByte(below: limit)
            let j = Int(byte) % upperBoundExclusive
            characters.swapAt(index, j)
            index -= 1
        }
    }

    /// Resamples individual characters inside any run longer than
    /// `maxConsecutive`, rather than restarting the whole construction --
    /// Decision 4's "repair just the offending run's characters." Each
    /// resample redraws from the full pool and is accepted only if it does
    /// not extend the run further; this can very rarely fail to fully
    /// repair a pathological pool (e.g. a pool with only one usable
    /// character), which is why the caller re-verifies with `satisfies`
    /// afterward rather than trusting this function unconditionally.
    private static func repairMaxConsecutive(_ characters: inout [Character], maxConsecutive: Int, pool: [Character]) throws {
        guard maxConsecutive > 0, characters.count > 1, !pool.isEmpty else { return }
        var runStart = 0
        var index = 1
        while index <= characters.count {
            if index < characters.count, characters[index] == characters[runStart] {
                index += 1
                continue
            }
            let runLength = index - runStart
            if runLength > maxConsecutive {
                for position in (runStart + maxConsecutive)..<index {
                    var attempt = characters[position]
                    var guardCount = 0
                    while attempt == characters[position - 1], guardCount < 20 {
                        attempt = try randomElement(of: pool)
                        guardCount += 1
                    }
                    characters[position] = attempt
                }
            }
            runStart = index
            index += 1
        }
    }

    /// Returns a cryptographically secure random byte in `0..<limit`,
    /// rejecting biased values by re-drawing.
    private static func secureRandomByte(below limit: UInt8) throws -> UInt8 {
        while true {
            var byte: UInt8 = 0
            let status = SecRandomCopyBytes(kSecRandomDefault, 1, &byte)
            guard status == errSecSuccess else {
                throw PasswordGeneratorError.secureRandomUnavailable
            }
            if byte < limit {
                return byte
            }
        }
    }
}
```

- [ ] **Step 5: Run and confirm the existing suite is unaffected**

Run: `cd Packages/MyPassKit && swift test --filter PasswordGeneratorTests`
Expected: PASS (6 tests), unchanged.

- [ ] **Step 6: Run and confirm the new suite passes**

Run: `cd Packages/MyPassKit && swift test --filter PasswordGeneratorRulesTests`
Expected: PASS (5 tests).

- [ ] **Step 7: Commit**

```bash
git add Packages/MyPassKit/Sources/MyPassKit/PasswordGenerator/PasswordGenerator.swift \
        Packages/MyPassKit/Tests/MyPassKitTests/PasswordGeneratorRulesTests.swift
git commit -m "feat(app): honour site password rules in the generator"
```

---

## Task 5 — Conformance property test over the whole dataset

**Interfaces:**
- Produces: `Packages/MyPassKit/Tests/MyPassKitTests/PasswordRulesConformanceTests.swift`.
- Consumes: `PasswordRulesParser` (Task 2), `PasswordGenerator.generate(options:rules:)` (Task 4), the bundled `password-rules.json` resource (Task 1).

This is the one test in this plan that proves the parser and the generator agree with each other **and** with real-world data, rather than only with each other's assumptions about what a rule string looks like — it reads the raw JSON directly (not through `PasswordRulesCatalog`, which would hide a parse failure as "no rule" — exactly the leniency this test must NOT have, since a parse failure here means Task 2's parser has a real gap against real data) and drives `PasswordGenerator` for every one of the 436 vendored domains.

- [ ] **Step 1: Write the test**

There is no "failing test first" step here in the usual TDD sense — this test exercises Tasks 1 through 4 together, all of which already have their own passing unit tests; its purpose is to catch an integration gap those unit tests individually cannot see (a real rule shape none of the hand-picked fixtures in Tasks 2 or 4 happened to cover). Create `Packages/MyPassKit/Tests/MyPassKitTests/PasswordRulesConformanceTests.swift`:

```swift
import XCTest
@testable import MyPassKit

final class PasswordRulesConformanceTests: XCTestCase {
    /// All four baseline toggles on, so the effective pool is never
    /// artificially starved by a toggle the rule didn't ask about -- this
    /// test exists to prove the PARSER and GENERATOR agree with each other
    /// and with real-world data, not to exercise toggle interaction (Task
    /// 4's `PasswordGeneratorRulesTests` already covers that).
    private static let allTogglesOn = PasswordGeneratorOptions(
        length: 20, includeLowercase: true, includeUppercase: true, includeDigits: true, includeSymbols: true
    )

    func testEveryVendoredRuleGeneratesConformingPasswords() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "password-rules", withExtension: "json"))
        let data = try Data(contentsOf: url)
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: [String: String]])

        // 3 attempts per domain, not 1: a single lucky draw could pass by
        // chance even if the generator only satisfies a rule most of the
        // time rather than always. 3 x 436 domains = ~1,308 generations,
        // each a handful of in-memory character draws with no I/O and no
        // expensive key-derivation work (unlike, say, an Argon2
        // known-answer test) -- comfortably under a few seconds locally.
        let attemptsPerDomain = 3

        for (domain, entry) in raw {
            guard let ruleString = entry["password-rules"] else {
                XCTFail("\(domain): vendored entry missing password-rules key")
                continue
            }
            guard case .success(let rules) = PasswordRulesParser.parse(ruleString) else {
                XCTFail("\(domain): failed to parse vendored rule \(ruleString)")
                continue
            }

            for attempt in 0..<attemptsPerDomain {
                let password: String
                do {
                    password = try PasswordGenerator.generate(options: Self.allTogglesOn, rules: rules)
                } catch {
                    XCTFail("\(domain) attempt \(attempt): generate(options:rules:) threw \(error) for rule \(ruleString)")
                    continue
                }
                assertConforms(password, to: rules, domain: domain, ruleString: ruleString)
            }
        }
    }

    private func assertConforms(_ password: String, to rules: PasswordRules, domain: String, ruleString: String) {
        let characters = Array(password)
        let context = "\(domain): \(ruleString) -> \(password)"

        if let minLength = rules.minLength {
            XCTAssertGreaterThanOrEqual(characters.count, minLength, context)
        }
        if let maxLength = rules.maxLength {
            XCTAssertLessThanOrEqual(characters.count, maxLength, context)
        }
        if let maxConsecutive = rules.maxConsecutive, characters.count > 1 {
            var run = 1
            for i in 1..<characters.count {
                run = characters[i] == characters[i - 1] ? run + 1 : 1
                XCTAssertLessThanOrEqual(run, maxConsecutive, context)
            }
        }
        for clause in rules.requiredClauses {
            let satisfied = characters.contains { character in
                clause.contains { matches(character, $0) }
            }
            XCTAssertTrue(satisfied, "\(context) -- required clause \(clause) not satisfied")
        }
    }

    /// A SECOND, independent characterization of each `CharacterClass`,
    /// deliberately not calling into `PasswordGenerator`'s own private
    /// `EffectivePool` -- if this test reused the generator's own
    /// membership logic, a bug shared by both would be invisible to it.
    private func matches(_ character: Character, _ characterClass: PasswordRules.CharacterClass) -> Bool {
        switch characterClass {
        case .upper: return character.isUppercase
        case .lower: return character.isLowercase
        case .digit: return character.isNumber
        case .special: return !character.isLetter && !character.isNumber
        case .asciiPrintable:
            guard let ascii = character.asciiValue else { return false }
            return ascii >= 0x20 && ascii <= 0x7E
        case .unicode: return true
        case .custom(let members): return members.contains(character)
        }
    }
}
```

- [ ] **Step 2: Run**

Run: `cd Packages/MyPassKit && swift test --filter PasswordRulesConformanceTests`
Expected: PASS, iterating all 436 vendored domains. If this fails for a specific domain, the failure message names the domain, its exact rule string, and the offending generated password — treat it as a real gap in Task 2's parser or Task 4's generator, per `systematic-debugging`, not as a reason to weaken this test (e.g. by lowering `attemptsPerDomain` or excluding the domain). If it fails specifically because the deterministic-construction fallback's bounded 10-retry / 20-resample-per-position limits (Task 4) can't converge on an unusually tight real rule, the fix is to raise those bounds in `PasswordGenerator.swift`, not to change what this test asserts.

- [ ] **Step 3: Commit**

```bash
git add Packages/MyPassKit/Tests/MyPassKitTests/PasswordRulesConformanceTests.swift
git commit -m "test(app): prove generated passwords conform to every vendored rule"
```

---

## Task 6 — Persisted generator defaults

**Interfaces:**
- Produces: `MyPass/UI/PasswordGenerator/PasswordGeneratorDefaults.swift` (app target).
- Consumes: `PasswordGeneratorOptions` (`MyPassKit`, existing).

Matches the exact `UserDefaults(suiteName:)`-throwaway-suite test pattern already established by `MyPassTests/ClipboardClearIntervalTests.swift` for the same kind of injectable-`UserDefaults` settings type.

- [ ] **Step 1: Write the failing tests**

Create `MyPassTests/PasswordGeneratorDefaultsTests.swift`:

```swift
import XCTest
import MyPassKit
@testable import MyPass

final class PasswordGeneratorDefaultsTests: XCTestCase {
    private func makeThrowawaySuite(_ name: String) -> UserDefaults {
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func testAbsentValuesYieldTheDocumentedDefaults() {
        let defaults = makeThrowawaySuite("PasswordGeneratorDefaultsTests-absent")
        let options = PasswordGeneratorDefaults.load(from: defaults)
        XCTAssertEqual(options.length, 20)
        XCTAssertTrue(options.includeLowercase)
        XCTAssertTrue(options.includeUppercase)
        XCTAssertTrue(options.includeDigits)
        XCTAssertTrue(options.includeSymbols)
    }

    func testRoundTripsSavedValues() {
        let defaults = makeThrowawaySuite("PasswordGeneratorDefaultsTests-roundtrip")
        let saved = PasswordGeneratorOptions(
            length: 32, includeLowercase: false, includeUppercase: true, includeDigits: false, includeSymbols: true
        )
        PasswordGeneratorDefaults.save(saved, to: defaults)
        let loaded = PasswordGeneratorDefaults.load(from: defaults)
        XCTAssertEqual(loaded.length, 32)
        XCTAssertFalse(loaded.includeLowercase)
        XCTAssertTrue(loaded.includeUppercase)
        XCTAssertFalse(loaded.includeDigits)
        XCTAssertTrue(loaded.includeSymbols)
    }
}
```

- [ ] **Step 2: Run and confirm failure**

Run: `xcodebuild test -scheme MyPass -only-testing:MyPassTests/PasswordGeneratorDefaultsTests`
Expected: build fails — `PasswordGeneratorDefaults` does not exist yet.

- [ ] **Step 3: Implement `PasswordGeneratorDefaults`**

Create `MyPass/UI/PasswordGenerator/PasswordGeneratorDefaults.swift`:

```swift
import Foundation
import MyPassKit

/// Persisted defaults for the password generator, in the `MyPass.`-prefixed
/// key namespace this codebase already uses for its custom vault fields
/// (`MyPass.CVV`, `MyPass.NotesBody`, etc. in `KdbxEntry+Convenience.swift`)
/// -- these keys live in `UserDefaults`, not the vault, but the naming
/// convention is shared deliberately so every MyPass-owned persisted key in
/// this codebase is recognizable at a glance.
///
/// `UserDefaults` is injectable specifically so tests use a throwaway suite
/// (see `PasswordGeneratorDefaultsTests.swift`) rather than polluting the
/// developer's real defaults -- the same pattern already established by
/// `ClipboardClearInterval.seconds(defaults:)`.
enum PasswordGeneratorDefaults {
    static let lengthKey = "MyPass.PasswordGenerator.length"
    static let includeLowercaseKey = "MyPass.PasswordGenerator.includeLowercase"
    static let includeUppercaseKey = "MyPass.PasswordGenerator.includeUppercase"
    static let includeDigitsKey = "MyPass.PasswordGenerator.includeDigits"
    static let includeSymbolsKey = "MyPass.PasswordGenerator.includeSymbols"

    // Matches PasswordGeneratorView's own pre-persistence hard-coded
    // defaults (length 16 was the OLD default before this task; the spec's
    // Decision 6 sets the new documented default to 20, so both the
    // fallback here and the view's initial state after Task 7 must read
    // 20, not 16).
    private static let defaultLength = 20
    private static let defaultIncludeClass = true

    static func load(from defaults: UserDefaults = .standard) -> PasswordGeneratorOptions {
        // `.integer(forKey:)`/`.bool(forKey:)` return 0/false when the key
        // is absent, which is indistinguishable from "the user explicitly
        // chose 0 characters" or "explicitly turned this class off" --
        // `.object(forKey:) as? T` correctly returns nil when absent, so
        // the `??` fallback below only fires on a genuinely-unset default.
        let length = defaults.object(forKey: lengthKey) as? Int ?? defaultLength
        let includeLowercase = defaults.object(forKey: includeLowercaseKey) as? Bool ?? defaultIncludeClass
        let includeUppercase = defaults.object(forKey: includeUppercaseKey) as? Bool ?? defaultIncludeClass
        let includeDigits = defaults.object(forKey: includeDigitsKey) as? Bool ?? defaultIncludeClass
        let includeSymbols = defaults.object(forKey: includeSymbolsKey) as? Bool ?? defaultIncludeClass
        return PasswordGeneratorOptions(
            length: length,
            includeLowercase: includeLowercase,
            includeUppercase: includeUppercase,
            includeDigits: includeDigits,
            includeSymbols: includeSymbols
        )
    }

    static func save(_ options: PasswordGeneratorOptions, to defaults: UserDefaults = .standard) {
        defaults.set(options.length, forKey: lengthKey)
        defaults.set(options.includeLowercase, forKey: includeLowercaseKey)
        defaults.set(options.includeUppercase, forKey: includeUppercaseKey)
        defaults.set(options.includeDigits, forKey: includeDigitsKey)
        defaults.set(options.includeSymbols, forKey: includeSymbolsKey)
    }
}
```

- [ ] **Step 4: Run and confirm pass**

Run: `xcodebuild test -scheme MyPass -only-testing:MyPassTests/PasswordGeneratorDefaultsTests`
Expected: PASS, both tests.

- [ ] **Step 5: Commit**

```bash
git add MyPass/UI/PasswordGenerator/PasswordGeneratorDefaults.swift \
        MyPassTests/PasswordGeneratorDefaultsTests.swift
git commit -m "feat(app): persist password generator defaults across launches"
```

---

## Task 7 — Generator UI surfaces the active rule

**Interfaces:**
- Produces: `MyPass/UI/PasswordGenerator/PasswordRulesSummary.swift` (`PasswordRulesSummary.describe(_:domain:) -> String`); a modified `MyPass/UI/PasswordGenerator/PasswordGeneratorView.swift` (reads/writes `PasswordGeneratorDefaults`, looks up `PasswordRulesCatalog.rules(forHost:)`, calls `PasswordGenerator.generate(options:rules:)`); a modified call site in `MyPass/UI/EntryDetail/EntryEditView.swift`.
- Consumes: `PasswordGeneratorDefaults` (Task 6), `PasswordRulesCatalog` (Task 3), `PasswordGenerator.generate(options:rules:)` (Task 4), `ExtensionEntryMatcher.registrableDomain(from:)` (existing, `MyPass/State/ExtensionBridge/ExtensionEntryMatcher.swift`).

`PasswordRulesSummary` is the one piece of this task XCTest can verify directly; the rest is SwiftUI wiring verified by building the app target (there is no SwiftUI view-inspection framework in this codebase's dependency graph, and none is introduced here).

- [ ] **Step 1: Write the failing tests for the summary**

Create `MyPassTests/PasswordRulesSummaryTests.swift`:

```swift
import XCTest
import MyPassKit
@testable import MyPass

final class PasswordRulesSummaryTests: XCTestCase {
    func testDescribesRequiredClassesLengthAndMaxConsecutive() throws {
        // Real rule from the vendored 2026-09-12 snapshot, account.samsung.com.
        let ruleString = "minlength: 8; maxlength: 15; max-consecutive: 3; required: digit; required: special; required: upper,lower;"
        guard case .success(let rules) = PasswordRulesParser.parse(ruleString) else {
            return XCTFail("expected a valid parse")
        }
        let summary = PasswordRulesSummary.describe(rules, domain: "account.samsung.com")
        XCTAssertEqual(
            summary,
            "account.samsung.com needs a digit, a symbol, an uppercase letter or a lowercase letter, 8 to 15 characters, at most 3 repeated characters in a row."
        )
    }

    func testDescribesALengthOnlyRule() throws {
        // Real rule from the vendored 2026-09-12 snapshot, 163.com.
        let ruleString = "minlength: 6; maxlength: 16;"
        guard case .success(let rules) = PasswordRulesParser.parse(ruleString) else {
            return XCTFail("expected a valid parse")
        }
        let summary = PasswordRulesSummary.describe(rules, domain: "163.com")
        XCTAssertEqual(summary, "163.com needs 6 to 16 characters.")
    }
}
```

- [ ] **Step 2: Run and confirm failure**

Run: `xcodebuild test -scheme MyPass -only-testing:MyPassTests/PasswordRulesSummaryTests`
Expected: build fails — `PasswordRulesSummary` does not exist yet.

- [ ] **Step 3: Implement `PasswordRulesSummary`**

Create `MyPass/UI/PasswordGenerator/PasswordRulesSummary.swift`:

```swift
import MyPassKit

/// Turns a parsed `PasswordRules` into a short, plain-English sentence for
/// the generator popover (Decision 5 of the spec) -- never the raw grammar
/// string ("minlength: 8; required: digit;"), which is meant for machines,
/// not for a person deciding whether to trust the password MyPass just
/// generated for them.
enum PasswordRulesSummary {
    static func describe(_ rules: PasswordRules, domain: String) -> String {
        var fragments: [String] = []

        for orClause in rules.requiredClauses {
            fragments.append(orClause.map(name(for:)).joined(separator: " or "))
        }

        if let minLength = rules.minLength, let maxLength = rules.maxLength {
            fragments.append(
                minLength == maxLength
                    ? "exactly \(minLength) characters"
                    : "\(minLength) to \(maxLength) characters"
            )
        } else if let minLength = rules.minLength {
            fragments.append("at least \(minLength) characters")
        } else if let maxLength = rules.maxLength {
            fragments.append("at most \(maxLength) characters")
        }

        if let maxConsecutive = rules.maxConsecutive {
            fragments.append("at most \(maxConsecutive) repeated characters in a row")
        }

        guard !fragments.isEmpty else {
            return "\(domain) has no specific password requirements."
        }
        return "\(domain) needs " + fragments.joined(separator: ", ") + "."
    }

    private static func name(for characterClass: PasswordRules.CharacterClass) -> String {
        switch characterClass {
        case .upper: return "an uppercase letter"
        case .lower: return "a lowercase letter"
        case .digit: return "a digit"
        case .special: return "a symbol"
        case .asciiPrintable: return "a printable character"
        case .unicode: return "a unicode character"
        case .custom: return "a required symbol"
        }
    }
}
```

- [ ] **Step 4: Run and confirm pass**

Run: `xcodebuild test -scheme MyPass -only-testing:MyPassTests/PasswordRulesSummaryTests`
Expected: PASS, both tests.

- [ ] **Step 5: Commit the summary and its test**

```bash
git add MyPass/UI/PasswordGenerator/PasswordRulesSummary.swift \
        MyPassTests/PasswordRulesSummaryTests.swift
git commit -m "feat(app): render password rules as a plain-English summary"
```

- [ ] **Step 6: Wire the summary, defaults, and rule lookup into the view**

`PasswordGeneratorView.swift` currently declares `length`/`includeLowercase`/`includeUppercase`/`includeDigits`/`includeSymbols` as plain `@State` properties defaulting to `16`/`true`×4 with no persistence, and calls `PasswordGenerator.generate(options:)` with no `rules` argument. Replace the whole file:

```swift
import SwiftUI
import AppKit
import MyPassKit

struct PasswordGeneratorView: View {
    /// The domain to look up a Password Rules entry for. Passed by the
    /// caller when the generator is opened from an entry's edit screen,
    /// already reduced to a registrable domain via
    /// `ExtensionEntryMatcher.registrableDomain(from:)` -- see
    /// `EntryEditView.swift`'s call site (Step 7 below). Left empty when
    /// opened standalone, in which case the view's own free-text site
    /// field is the only source of a domain.
    var initialSiteDomain: String = ""
    var onGenerate: (String) -> Void = { _ in }

    @State private var length: Double
    @State private var includeLowercase: Bool
    @State private var includeUppercase: Bool
    @State private var includeDigits: Bool
    @State private var includeSymbols: Bool
    @State private var generatedPassword = ""
    @State private var errorMessage: String?
    @State private var siteDomain: String
    @State private var ignoreActiveRule = false
    @State private var showRuleExplanation = false

    private let pasteboard = NSPasteboardClearing()
    private let clock = RealAutoLockClock()

    init(initialSiteDomain: String = "", onGenerate: @escaping (String) -> Void = { _ in }) {
        self.initialSiteDomain = initialSiteDomain
        self.onGenerate = onGenerate
        let stored = PasswordGeneratorDefaults.load()
        _length = State(initialValue: Double(stored.length))
        _includeLowercase = State(initialValue: stored.includeLowercase)
        _includeUppercase = State(initialValue: stored.includeUppercase)
        _includeDigits = State(initialValue: stored.includeDigits)
        _includeSymbols = State(initialValue: stored.includeSymbols)
        _siteDomain = State(initialValue: initialSiteDomain)
    }

    /// Nil when there is no domain yet, the user chose to ignore it, or no
    /// vendored rule applies -- all three fall back to plain toggle-driven
    /// generation, matching `PasswordGenerator.generate(options:rules:)`'s
    /// own `rules: nil` default.
    private var activeRule: PasswordRules? {
        guard !ignoreActiveRule, !siteDomain.isEmpty else { return nil }
        return PasswordRulesCatalog.rules(forHost: siteDomain)
    }

    private var lengthRange: ClosedRange<Double> {
        let ruleMin = Double(activeRule?.minLength ?? 8)
        let ruleMax = Double(activeRule?.maxLength ?? 64)
        let lowerBound = max(8, ruleMin)
        let upperBound = min(64, ruleMax)
        // A rule whose own min/max already conflicts with MyPass's fixed
        // 8...64 slider bounds would otherwise build an invalid
        // ClosedRange and crash the view; collapsing to a single point is
        // the safe degenerate case. Task 5's conformance test would
        // already be failing before this could happen with any vendored
        // rule.
        return lowerBound <= upperBound ? lowerBound...upperBound : lowerBound...lowerBound
    }

    private var requiredClasses: Set<PasswordRules.CharacterClass> {
        Set(activeRule?.requiredClauses.flatMap { $0 } ?? [])
    }

    private var disallowedClasses: Set<PasswordRules.CharacterClass> {
        guard let activeRule else { return [] }
        let allowed = Set(activeRule.allowedClasses)
        let asciiPrintableAllowed = allowed.contains(.asciiPrintable)
        var disallowed: Set<PasswordRules.CharacterClass> = []
        for characterClass in [PasswordRules.CharacterClass.lower, .upper, .digit, .special] {
            if !allowed.contains(characterClass) && !asciiPrintableAllowed {
                disallowed.insert(characterClass)
            }
        }
        return disallowed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if initialSiteDomain.isEmpty {
                TextField("Site (optional)", text: $siteDomain)
                    .onChange(of: siteDomain) { _, _ in applyActiveRuleToToggles() }
            }

            if let activeRule {
                HStack {
                    Button {
                        showRuleExplanation = true
                    } label: {
                        Label("\(siteDomain) has password requirements", systemImage: "info.circle")
                    }
                    .popover(isPresented: $showRuleExplanation) {
                        Text(PasswordRulesSummary.describe(activeRule, domain: siteDomain))
                            .padding()
                            .frame(width: 260)
                    }
                    Spacer()
                    Toggle("Ignore", isOn: $ignoreActiveRule)
                        .toggleStyle(.checkbox)
                }
                .font(.caption)
            }

            Text("Length: \(Int(length))")
            Slider(value: $length, in: lengthRange, step: 1)

            Toggle("Lowercase", isOn: $includeLowercase)
                .disabled(requiredClasses.contains(.lower) || disallowedClasses.contains(.lower))
            Toggle("Uppercase", isOn: $includeUppercase)
                .disabled(requiredClasses.contains(.upper) || disallowedClasses.contains(.upper))
            Toggle("Digits", isOn: $includeDigits)
                .disabled(requiredClasses.contains(.digit) || disallowedClasses.contains(.digit))
            Toggle("Symbols", isOn: $includeSymbols)
                .disabled(requiredClasses.contains(.special) || disallowedClasses.contains(.special))

            Button("Generate", action: generate)
                .buttonStyle(.borderedProminent)

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.caption)
            }

            if !generatedPassword.isEmpty {
                HStack {
                    Text(generatedPassword)
                        .font(.system(.body, design: .monospaced))
                    Button("Copy", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(generatedPassword, forType: .string)
                        ClipboardAutoClear.schedule(value: generatedPassword, after: ClipboardClearInterval.seconds(), pasteboard: pasteboard, clock: clock)
                    }
                    Button("Use") {
                        onGenerate(generatedPassword)
                    }
                }
            }
        }
        .padding()
        .frame(width: 320)
        .onAppear(perform: applyActiveRuleToToggles)
    }

    /// Forces required classes on and disallowed classes off whenever the
    /// active rule could have changed (site edited, ignore toggled, or on
    /// first appearance), and clamps the length slider into the rule's
    /// range -- matching Decision 5's "toggles for classes the rule
    /// requires are shown locked on, and toggles for classes the rule's
    /// effective allowed set excludes are shown locked off." An OPTIONAL
    /// class's toggle stays under the user's control; only required/
    /// disallowed classes are pinned.
    private func applyActiveRuleToToggles() {
        guard activeRule != nil else { return }
        if requiredClasses.contains(.lower) { includeLowercase = true }
        if requiredClasses.contains(.upper) { includeUppercase = true }
        if requiredClasses.contains(.digit) { includeDigits = true }
        if requiredClasses.contains(.special) { includeSymbols = true }
        if disallowedClasses.contains(.lower) { includeLowercase = false }
        if disallowedClasses.contains(.upper) { includeUppercase = false }
        if disallowedClasses.contains(.digit) { includeDigits = false }
        if disallowedClasses.contains(.special) { includeSymbols = false }
        length = min(max(length, lengthRange.lowerBound), lengthRange.upperBound)
    }

    private func generate() {
        let options = PasswordGeneratorOptions(
            length: Int(length),
            includeLowercase: includeLowercase,
            includeUppercase: includeUppercase,
            includeDigits: includeDigits,
            includeSymbols: includeSymbols
        )
        PasswordGeneratorDefaults.save(options)
        do {
            generatedPassword = try PasswordGenerator.generate(options: options, rules: activeRule)
            errorMessage = nil
        } catch PasswordGeneratorError.noCharacterClassSelected {
            errorMessage = "Select at least one character class."
        } catch PasswordGeneratorError.unsatisfiableRules {
            errorMessage = "This site's requirements conflict with your current options."
        } catch {
            errorMessage = "Failed to generate password."
        }
    }
}
```

- [ ] **Step 7: Pass the entry's domain in from `EntryEditView`**

In `MyPass/UI/EntryDetail/EntryEditView.swift`, the sheet presentation currently reads:

```swift
        .sheet(isPresented: $showPasswordGenerator) {
            PasswordGeneratorView { generated in
                password = generated
                showPasswordGenerator = false
            }
        }
```

Change it to pass the entry's own `url` field, reduced to a registrable domain via the exact same machinery every other domain-comparison surface in this app already uses, so "which rule applies" is computed identically everywhere:

```swift
        .sheet(isPresented: $showPasswordGenerator) {
            PasswordGeneratorView(initialSiteDomain: ExtensionEntryMatcher.registrableDomain(from: url) ?? "") { generated in
                password = generated
                showPasswordGenerator = false
            }
        }
```

- [ ] **Step 8: Build and confirm the app target compiles**

Run: `xcodebuild build -scheme MyPass`
Expected: build succeeds with no errors. (There is no SwiftUI view-inspection test framework in this codebase, so this build is the verification step for the UI wiring itself; `PasswordRulesSummaryTests.swift`, already passing from Step 4, is what actually exercises the testable half of this task's logic.)

- [ ] **Step 9: Run the full existing MyPassTests suite once more**

Run: `xcodebuild test -scheme MyPass -only-testing:MyPassTests/PasswordGeneratorDefaultsTests -only-testing:MyPassTests/PasswordRulesSummaryTests -only-testing:MyPassTests/ExtensionEntryMatcherTests`
Expected: PASS — the last of these three (pre-existing, untouched) confirms `ExtensionEntryMatcher.registrableDomain(from:)`'s own behavior is unaffected by this task calling it from a new call site.

- [ ] **Step 10: Commit**

```bash
git add MyPass/UI/PasswordGenerator/PasswordGeneratorView.swift \
        MyPass/UI/EntryDetail/EntryEditView.swift
git commit -m "feat(entry-edit): surface the active site password rule in the generator"
```

---

## Task 8 — URIMatchMode and its storage on the entry

**Interfaces:**
- Produces: `Packages/MyPassKit/Sources/MyPassKit/URIMatchMode.swift` (`public enum URIMatchMode: String, CaseIterable, Hashable`); `MyPass/Models/KdbxEntry+URIMatch.swift` (`KdbxEntry.uriMatchModeFieldKey`, `KdbxEntry.uriMatchMode`).
- Consumes: `KdbxEntry.fieldValue(forKey:)` / `setFieldValue(_:forKey:isProtected:)` (internal helpers already in `MyPass/Models/KdbxEntry+Convenience.swift`, reused exactly the way `KdbxEntry+Passkey.swift` already reuses them).
- Modifies: `KdbxEntry.standardFieldKeys` in `MyPass/Models/KdbxEntry+Convenience.swift`.

- [ ] **Step 1: Write the failing enum test**

Create `Packages/MyPassKit/Tests/MyPassKitTests/URIMatchModeTests.swift`:

```swift
import XCTest
import MyPassKit

final class URIMatchModeTests: XCTestCase {
    func testRawValuesAreKebabCase() {
        XCTAssertEqual(URIMatchMode.registrableDomain.rawValue, "registrable-domain")
        XCTAssertEqual(URIMatchMode.host.rawValue, "host")
        XCTAssertEqual(URIMatchMode.startsWith.rawValue, "starts-with")
        XCTAssertEqual(URIMatchMode.exact.rawValue, "exact")
        XCTAssertEqual(URIMatchMode.never.rawValue, "never")
    }

    func testAllCasesCoversEveryModeExactlyOnce() {
        XCTAssertEqual(URIMatchMode.allCases.count, 5)
        XCTAssertEqual(Set(URIMatchMode.allCases).count, 5)
    }
}
```

- [ ] **Step 2: Run and confirm failure**

Run: `swift test --package-path Packages/MyPassKit --filter URIMatchModeTests`
Expected: build fails — `cannot find type 'URIMatchMode' in scope`.

- [ ] **Step 3: Implement `URIMatchMode`**

Create `Packages/MyPassKit/Sources/MyPassKit/URIMatchMode.swift`:

```swift
import Foundation

/// How a vault entry's saved URL is matched against the page the browser
/// extension is currently looking at. `.registrableDomain` is the default —
/// unchanged behaviour from `ExtensionEntryMatcher.registrableDomain(from:)`
/// before this type existed. Raw values are kebab-case, matching the
/// lowercase-hyphenated style the Password Rules grammar already uses for its
/// own multi-word tokens (`max-consecutive`, `ascii-printable`).
///
/// `CaseIterable` is what lets the entry edit form's picker enumerate every
/// mode without a second, hand-maintained list that could drift out of sync
/// with this enum.
public enum URIMatchMode: String, CaseIterable, Hashable {
    case registrableDomain = "registrable-domain"
    case host = "host"
    case startsWith = "starts-with"
    case exact = "exact"
    case never = "never"
}
```

- [ ] **Step 4: Run and confirm pass**

Run: `swift test --package-path Packages/MyPassKit --filter URIMatchModeTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Regenerate the Xcode project before the app-side test**

`MyPassTests/KdbxEntryURIMatchTests.swift` (written next) is a new file inside the
`MyPassTests` target, and `MyPass.xcodeproj` is generated by XcodeGen — a new file must
exist on disk before regeneration picks it up. Doing the regenerate now, before writing
the file, would find nothing new; doing it after writing the file (Step 7, before running
the test) is what actually matters. Nothing to run yet — noted here so Step 8 isn't a
surprise.

- [ ] **Step 6: Write the failing app-side tests**

Create `MyPassTests/KdbxEntryURIMatchTests.swift`:

```swift
import XCTest
import MyPassKit
@testable import MyPass

final class KdbxEntryURIMatchTests: XCTestCase {
    private func makeEntry() -> KdbxEntry {
        let now = Date()
        return KdbxEntry(
            uuid: UUID(), iconID: 0, fields: [],
            creationTime: now, lastModificationTime: now, lastAccessTime: now,
            locationChanged: now, history: []
        )
    }

    func testAbsentFieldReadsAsRegistrableDomain() {
        let entry = makeEntry()
        XCTAssertEqual(entry.uriMatchMode, .registrableDomain)
    }

    func testUnrecognisedRawValueReadsAsRegistrableDomainRatherThanThrowing() {
        var entry = makeEntry()
        entry.fields.append(
            KdbxField(key: KdbxEntry.uriMatchModeFieldKey, value: "some-future-mode-this-version-does-not-know", isProtected: false)
        )
        XCTAssertEqual(entry.uriMatchMode, .registrableDomain)
    }

    func testSetThenReadRoundTrips() {
        var entry = makeEntry()
        entry.uriMatchMode = .exact
        XCTAssertEqual(entry.uriMatchMode, .exact)
        entry.uriMatchMode = .never
        XCTAssertEqual(entry.uriMatchMode, .never)
    }

    func testSettingBackToRegistrableDomainRemovesTheField() {
        var entry = makeEntry()
        entry.uriMatchMode = .host
        entry.uriMatchMode = .registrableDomain
        XCTAssertFalse(entry.fields.contains { $0.key == KdbxEntry.uriMatchModeFieldKey })
    }

    func testUriMatchModeFieldKeyIsAStandardFieldNotACustomField() {
        var entry = makeEntry()
        entry.uriMatchMode = .startsWith
        XCTAssertTrue(KdbxEntry.standardFieldKeys.contains(KdbxEntry.uriMatchModeFieldKey))
        XCTAssertTrue(entry.additionalFields.isEmpty, "MyPass.URIMatchMode must never render as a generic custom-field row")
    }

    func testUriMatchModeSurvivesAKdbxSaveAndReloadCycle() throws {
        var entry = makeEntry()
        entry.title = "Example"
        entry.url = "https://example.com"
        entry.uriMatchMode = .exact
        let group = KdbxGroup(
            uuid: UUID(), name: "MyPass", iconID: 0,
            creationTime: Date(), lastModificationTime: Date(), locationChanged: Date(),
            entries: [entry], subgroups: []
        )
        let database = KdbxDatabase(rootGroup: group, deletedObjects: [])
        let data = try database.save(password: "correct-horse", cipher: .aes256, compression: .gzip)

        let reopened = try KdbxDatabase.open(data: data, password: "correct-horse")
        let reloadedEntry = try XCTUnwrap(reopened.rootGroup.entries.first { $0.uuid == entry.uuid })
        XCTAssertEqual(reloadedEntry.uriMatchMode, .exact)
    }

    func testEntryWithNoUriMatchModeFieldReloadsAsRegistrableDomain() throws {
        var entry = makeEntry()
        entry.title = "Example"
        entry.url = "https://example.com"
        // uriMatchMode deliberately left untouched — this is the "old file" shape every
        // pre-existing MyPass and KeePassXC vault already has.
        let group = KdbxGroup(
            uuid: UUID(), name: "MyPass", iconID: 0,
            creationTime: Date(), lastModificationTime: Date(), locationChanged: Date(),
            entries: [entry], subgroups: []
        )
        let database = KdbxDatabase(rootGroup: group, deletedObjects: [])
        let data = try database.save(password: "correct-horse", cipher: .aes256, compression: .gzip)

        let reopened = try KdbxDatabase.open(data: data, password: "correct-horse")
        let reloadedEntry = try XCTUnwrap(reopened.rootGroup.entries.first { $0.uuid == entry.uuid })
        XCTAssertEqual(reloadedEntry.uriMatchMode, .registrableDomain)
    }
}
```

- [ ] **Step 7: Regenerate the project, then run and confirm failure**

Run: `./scripts/generate.sh`
Expected: `MyPass.xcodeproj` regenerated with no errors.

Run: `xcodebuild test -scheme MyPass -only-testing:MyPassTests/KdbxEntryURIMatchTests`
Expected: build fails — `value of type 'KdbxEntry' has no member 'uriMatchMode'`.

- [ ] **Step 8: Implement `KdbxEntry.uriMatchMode` and update `standardFieldKeys`**

Create `MyPass/Models/KdbxEntry+URIMatch.swift`:

```swift
import Foundation
import MyPassKit

extension KdbxEntry {
    static let uriMatchModeFieldKey = "MyPass.URIMatchMode"

    /// Absent or unrecognised reads as `.registrableDomain` — the same matching
    /// behaviour every existing MyPass and KeePassXC vault already has, with no
    /// migration step required. Setting `.registrableDomain` removes the field
    /// again (mirroring `entryType`'s own default-removes-the-field convention
    /// in `KdbxEntry+Convenience.swift`), so a vault untouched by this feature
    /// stays byte-for-byte free of this key.
    var uriMatchMode: URIMatchMode {
        get {
            URIMatchMode(rawValue: fieldValue(forKey: Self.uriMatchModeFieldKey)) ?? .registrableDomain
        }
        set {
            if newValue == .registrableDomain {
                fields.removeAll { $0.key == Self.uriMatchModeFieldKey }
            } else {
                setFieldValue(newValue.rawValue, forKey: Self.uriMatchModeFieldKey, isProtected: false)
            }
        }
    }
}
```

In `MyPass/Models/KdbxEntry+Convenience.swift`, add the new key to the literal array feeding `standardFieldKeys` (joins the same way the passkey keys join, just via the array literal rather than a second `.union` call, since there is exactly one new key rather than a whole list):

```swift
// Replace:
    static let standardFieldKeys: Set<String> = Set([
        "Title", "UserName", "Password", "URL", "Notes", "otp", "Favorite",
        "MyPass.EntryType", "MyPass.CardNumber", "MyPass.CardholderName", "MyPass.ExpiryDate", "MyPass.CVV", "MyPass.NotesBody"
    ]).union(KdbxEntry.passkeyFieldKeys)

// With:
    static let standardFieldKeys: Set<String> = Set([
        "Title", "UserName", "Password", "URL", "Notes", "otp", "Favorite",
        "MyPass.EntryType", "MyPass.CardNumber", "MyPass.CardholderName", "MyPass.ExpiryDate", "MyPass.CVV", "MyPass.NotesBody",
        KdbxEntry.uriMatchModeFieldKey
    ]).union(KdbxEntry.passkeyFieldKeys)
```

- [ ] **Step 9: Run and confirm pass**

Run: `xcodebuild test -scheme MyPass -only-testing:MyPassTests/KdbxEntryURIMatchTests`
Expected: PASS (6 tests).

- [ ] **Step 10: Commit**

```bash
git add Packages/MyPassKit/Sources/MyPassKit/URIMatchMode.swift \
        Packages/MyPassKit/Tests/MyPassKitTests/URIMatchModeTests.swift \
        MyPass/Models/KdbxEntry+URIMatch.swift \
        MyPass/Models/KdbxEntry+Convenience.swift \
        MyPassTests/KdbxEntryURIMatchTests.swift
git commit -m "feat(app): add URIMatchMode and its hidden per-entry field"
```

---

## Task 9 — Mode-aware matching

**Interfaces:**
- Consumes: `URIMatchMode` (Task 8), `KdbxEntry.uriMatchMode` (Task 8).
- Produces: `ExtensionEntryMatcher.matchingEntries(in:forURL:)` — signature unchanged, now mode-aware internally. New private helpers `hostAndPort(from:)` and `normalizedURL(from:)`. `registrableDomain(from:)` stays public and unchanged (it is still called directly elsewhere, e.g. by the future generator UI's domain reduction per the spec's Decision 5).

- [ ] **Step 1: Write the failing tests**

Append to `MyPassTests/ExtensionEntryMatcherTests.swift` (reuses the file's existing `makeEntry`/`makeGroup` helpers):

```swift
    // MARK: - URIMatchMode: host

    func testHostModeMatchesExactHostAndPortCaseInsensitively() {
        var entry = makeEntry(url: "https://Example.com:8443/login")
        entry.uriMatchMode = .host
        let group = makeGroup(entries: [entry])
        XCTAssertEqual(
            ExtensionEntryMatcher.matchingEntries(in: group, forURL: "https://example.com:8443/anything").map(\.uuid),
            [entry.uuid]
        )
    }

    func testHostModeDoesNotMatchASubdomain() {
        var entry = makeEntry(url: "https://example.com")
        entry.uriMatchMode = .host
        let group = makeGroup(entries: [entry])
        XCTAssertTrue(ExtensionEntryMatcher.matchingEntries(in: group, forURL: "https://login.example.com").isEmpty)
    }

    func testHostModeDoesNotMatchADifferentPort() {
        var entry = makeEntry(url: "https://example.com:8443")
        entry.uriMatchMode = .host
        let group = makeGroup(entries: [entry])
        XCTAssertTrue(ExtensionEntryMatcher.matchingEntries(in: group, forURL: "https://example.com:9443").isEmpty)
    }

    func testHostModeComparesIPLiteralsWhole() {
        var entry = makeEntry(url: "http://192.168.0.1/admin")
        entry.uriMatchMode = .host
        let group = makeGroup(entries: [entry])
        XCTAssertEqual(
            ExtensionEntryMatcher.matchingEntries(in: group, forURL: "http://192.168.0.1/login").map(\.uuid),
            [entry.uuid]
        )
        XCTAssertTrue(ExtensionEntryMatcher.matchingEntries(in: group, forURL: "http://127.0.0.1/login").isEmpty)
    }

    // MARK: - URIMatchMode: exact

    func testExactModeMatchesOnlyTheIdenticalNormalizedURL() {
        var entry = makeEntry(url: "https://Example.com:443/Login?x=1")
        entry.uriMatchMode = .exact
        let group = makeGroup(entries: [entry])
        XCTAssertEqual(
            ExtensionEntryMatcher.matchingEntries(in: group, forURL: "https://example.com/Login?x=1").map(\.uuid),
            [entry.uuid],
            "default port 443 must drop out of both sides so they normalise identically"
        )
    }

    func testExactModeIsCaseSensitiveOnThePath() {
        var entry = makeEntry(url: "https://example.com/API/v2/Login")
        entry.uriMatchMode = .exact
        let group = makeGroup(entries: [entry])
        XCTAssertTrue(
            ExtensionEntryMatcher.matchingEntries(in: group, forURL: "https://example.com/api/v2/login").isEmpty,
            "a case-sensitive API path must not fold to lowercase"
        )
    }

    func testExactModeDoesNotMatchADifferentPath() {
        var entry = makeEntry(url: "https://example.com/app")
        entry.uriMatchMode = .exact
        let group = makeGroup(entries: [entry])
        XCTAssertTrue(ExtensionEntryMatcher.matchingEntries(in: group, forURL: "https://example.com/app/extra").isEmpty)
    }

    // MARK: - URIMatchMode: starts-with

    func testStartsWithModeMatchesAnyPageUnderThePrefix() {
        var entry = makeEntry(url: "https://example.com/app")
        entry.uriMatchMode = .startsWith
        let group = makeGroup(entries: [entry])
        XCTAssertEqual(
            ExtensionEntryMatcher.matchingEntries(in: group, forURL: "https://example.com/app/settings").map(\.uuid),
            [entry.uuid]
        )
    }

    func testStartsWithModeAcceptsTheDocumentedPrefixOverMatch() {
        // The accepted trade-off from Decision 9: a plain string prefix, not a
        // path-boundary-aware one, so "…/app" also matches "…/app-legacy".
        var entry = makeEntry(url: "https://example.com/app")
        entry.uriMatchMode = .startsWith
        let group = makeGroup(entries: [entry])
        XCTAssertEqual(
            ExtensionEntryMatcher.matchingEntries(in: group, forURL: "https://example.com/app-legacy").map(\.uuid),
            [entry.uuid]
        )
    }

    func testStartsWithModeDoesNotMatchAShorterURL() {
        var entry = makeEntry(url: "https://example.com/app/settings")
        entry.uriMatchMode = .startsWith
        let group = makeGroup(entries: [entry])
        XCTAssertTrue(ExtensionEntryMatcher.matchingEntries(in: group, forURL: "https://example.com/app").isEmpty)
    }

    // MARK: - URIMatchMode: never

    func testNeverModeEntryNeverMatchesAnyURL() {
        var entry = makeEntry(url: "https://example.com")
        entry.uriMatchMode = .never
        let group = makeGroup(entries: [entry])
        XCTAssertTrue(ExtensionEntryMatcher.matchingEntries(in: group, forURL: "https://example.com").isEmpty)
    }

    // MARK: - Every mode: empty URL matches nothing

    func testEveryModeTreatsAnEmptyTargetURLAsNoMatch() {
        for mode in URIMatchMode.allCases {
            var entry = makeEntry(url: "https://example.com")
            entry.uriMatchMode = mode
            let group = makeGroup(entries: [entry])
            XCTAssertTrue(
                ExtensionEntryMatcher.matchingEntries(in: group, forURL: "").isEmpty,
                "\(mode) must not match an empty page URL"
            )
        }
    }

    func testEveryModeTreatsAnEntryWithNoStoredURLAsNoMatch() {
        for mode in URIMatchMode.allCases {
            var entry = makeEntry(url: "")
            entry.uriMatchMode = mode
            let group = makeGroup(entries: [entry])
            XCTAssertTrue(
                ExtensionEntryMatcher.matchingEntries(in: group, forURL: "https://example.com").isEmpty,
                "\(mode) must not match an entry with no stored URL"
            )
        }
    }
```

- [ ] **Step 2: Run and confirm failure**

Run: `xcodebuild test -scheme MyPass -only-testing:MyPassTests/ExtensionEntryMatcherTests`
Expected: the new host/exact/starts-with/never tests fail — every mode today is silently
treated as `registrableDomain` because `matchingEntries` never reads `entry.uriMatchMode`
at all yet. The two "every mode" loop tests pass vacuously for `registrableDomain` (already
correct today) but fail for the other four modes as soon as the loop reaches them.

- [ ] **Step 3: Implement mode-aware matching**

Replace `MyPass/State/ExtensionBridge/ExtensionEntryMatcher.swift` in full:

```swift
import Foundation
import MyPassKit

enum ExtensionEntryMatcher {
    /// Public-suffix-list (PSL) lookup via `MyPassKit.PublicSuffixList`,
    /// correctly handling multi-label suffixes such as "co.uk", "com.ua", and
    /// private-section rules like "github.io" — "example.co.uk" resolves to
    /// "example.co.uk", not "co.uk".
    ///
    /// A host that is itself a public suffix (e.g. "co.uk", "github.io") has
    /// no registrable domain to reduce to, so — consistent with the
    /// single-label and IP-literal branches below — it is compared whole.
    ///
    /// IP literals have no registrable domain and are never reduced to their
    /// last two labels — they are compared whole. This matters for IPv4:
    /// without it, "127.0.0.1", "192.168.0.1", and "10.0.0.1" would all
    /// collapse to "0.1" and be treated as the same site, offering one
    /// host's saved credentials to another. IPv6 literals ("::1", "[::1]")
    /// are likewise compared whole.
    static func registrableDomain(from urlString: String) -> String? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var host = URL(string: trimmed)?.host
        if host == nil {
            host = URL(string: "https://" + trimmed)?.host
        }
        guard var resolvedHost = host?.lowercased(), !resolvedHost.isEmpty else { return nil }

        if resolvedHost.hasSuffix(".") {
            resolvedHost = String(resolvedHost.dropLast())
        }

        if resolvedHost.contains(":") {
            if resolvedHost.hasPrefix("[") && resolvedHost.hasSuffix("]") {
                resolvedHost = String(resolvedHost.dropFirst().dropLast())
            }
            return resolvedHost
        }

        let labels = resolvedHost.split(separator: ".")
        guard labels.count >= 2 else { return resolvedHost }

        let isIPv4Literal = labels.allSatisfy { label in
            !label.isEmpty && label.allSatisfy { $0.isASCII && $0.isNumber }
        }
        if isIPv4Literal { return resolvedHost }

        return PublicSuffixList.registrableDomain(of: resolvedHost) ?? resolvedHost
    }

    /// Whole-host string comparison, including port, case-insensitive — no PSL
    /// reduction at all. IP literals have nothing to reduce to, so this mode's
    /// behaviour for an IP-literal entry coincides with `registrableDomain`'s
    /// (Decision 9).
    private static func hostAndPort(from urlString: String) -> String? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var url = URL(string: trimmed)
        if url?.host == nil {
            url = URL(string: "https://" + trimmed)
        }
        guard let host = url?.host?.lowercased(), !host.isEmpty else { return nil }
        guard let port = url?.port else { return host }
        return "\(host):\(port)"
    }

    /// The scheme's own registered default port, so "https://x" and
    /// "https://x:443" normalise identically for starts-with/exact matching.
    private static let defaultPortsByScheme: [String: Int] = ["http": 80, "https": 443]

    /// Lowercases scheme and host, drops the port only when it equals the
    /// scheme's own default, and leaves path and query exactly as given —
    /// including case, since a case-sensitive API path (`/API/v2/Login` vs
    /// `/api/v2/login`) is a real, common shape. Used by both starts-with and
    /// exact matching (Decision 9).
    private static func normalizedURL(from urlString: String) -> String? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var url = URL(string: trimmed)
        if url?.scheme == nil || url?.host == nil {
            url = URL(string: "https://" + trimmed)
        }
        guard let resolved = url,
              let scheme = resolved.scheme?.lowercased(),
              let host = resolved.host?.lowercased(), !host.isEmpty else {
            return nil
        }
        var result = "\(scheme)://\(host)"
        if let port = resolved.port, defaultPortsByScheme[scheme] != port {
            result += ":\(port)"
        }
        result += resolved.path
        if let query = resolved.query {
            result += "?\(query)"
        }
        return result
    }

    /// Never-mode exclusion is enforced HERE, before a `credentialList` (or its
    /// equivalent for the inline panel and the save-banner check) is ever
    /// assembled by `ExtensionBridgeService` — never left to the extension to
    /// filter client-side (Decision 9). Every bridge request that resolves
    /// entries by URL goes through this one function.
    static func matchingEntries(in group: KdbxGroup, forURL urlString: String) -> [KdbxEntry] {
        EntrySearch.allEntries(in: group).filter { matches(entry: $0, forURL: urlString) }
    }

    private static func matches(entry: KdbxEntry, forURL urlString: String) -> Bool {
        switch entry.uriMatchMode {
        case .never:
            return false
        case .registrableDomain:
            guard let targetDomain = registrableDomain(from: urlString) else { return false }
            return entry.urls.contains { registrableDomain(from: $0) == targetDomain }
        case .host:
            guard let targetHost = hostAndPort(from: urlString) else { return false }
            return entry.urls.contains { hostAndPort(from: $0) == targetHost }
        case .exact:
            guard let targetNormalized = normalizedURL(from: urlString) else { return false }
            return entry.urls.contains { normalizedURL(from: $0) == targetNormalized }
        case .startsWith:
            guard let targetNormalized = normalizedURL(from: urlString) else { return false }
            return entry.urls.contains { entryURL in
                guard let entryNormalized = normalizedURL(from: entryURL) else { return false }
                return targetNormalized.hasPrefix(entryNormalized)
            }
        }
    }
}
```

Note on the two "empty URL" rules: neither needs its own special case above. An empty
target `urlString` already makes every normalisation helper return `nil` (each starts
with `guard !trimmed.isEmpty else { return nil }`), and an entry with no stored URL
already produces an empty `entry.urls` array (`KdbxEntry.urls` in
`KdbxEntry+Convenience.swift` only appends the primary `URL` field when it is
non-empty), so `.contains` over it is `false` for every mode without any extra code.
Both are proved by the tests above rather than asserted by inspection alone.

- [ ] **Step 4: Run and confirm pass**

Run: `xcodebuild test -scheme MyPass -only-testing:MyPassTests/ExtensionEntryMatcherTests`
Expected: PASS, every existing registrable-domain test plus all new tests from Step 1.

- [ ] **Step 5: Write and run the never-mode exclusion test at the bridge boundary**

Append to `MyPassTests/ExtensionBridgeServiceTests.swift` (reuses the file's `service`,
`authorizedPairingSecret`, and `addFixtureEntry` from `setUpWithError`):

```swift
    func testNeverModeEntryIsAbsentFromTheCredentialListTheBridgeAssembles() {
        let id = addFixtureEntry(title: "Legacy", username: "alice", password: "s3cret", url: "https://example.com")
        session.mutate { db in
            guard let index = db.rootGroup.entries.firstIndex(where: { $0.uuid == id }) else { return }
            db.rootGroup.entries[index].uriMatchMode = .never
        }
        let response = service.handle(.getCredentials(token: "t", url: "https://example.com", pairing: authorizedPairingSecret))
        guard case .credentialList(let summaries) = response else {
            return XCTFail("expected credentialList, got \(response)")
        }
        XCTAssertTrue(
            summaries.isEmpty,
            "a never-mode entry must never be assembled into the credential list the bridge sends across the wire"
        )
    }
```

Run: `xcodebuild test -scheme MyPass -only-testing:MyPassTests/ExtensionBridgeServiceTests/testNeverModeEntryIsAbsentFromTheCredentialListTheBridgeAssembles`
Expected: PASS — proving the exclusion at the actual boundary that ships data to the
extension, not only inside the matcher's own unit tests.

- [ ] **Step 6: Commit**

```bash
git add MyPass/State/ExtensionBridge/ExtensionEntryMatcher.swift \
        MyPassTests/ExtensionEntryMatcherTests.swift \
        MyPassTests/ExtensionBridgeServiceTests.swift
git commit -m "feat(app): match extension entries per their own URIMatchMode"
```

---

## Task 10 — Match-mode picker in the entry edit form

**Interfaces:**
- Consumes: `URIMatchMode` (Task 8), `KdbxEntry.uriMatchMode` (Task 8).
- Produces: a `Picker` in `MyPass/UI/EntryDetail/EntryEditView.swift`, plus a private
  `URIMatchMode` display-string extension local to that file.

**Where the URL field lives, and why no extra template gating is needed.**
`MyPass/ContentView.swift`'s `entryEdit(...)` (verified directly in the source, lines
132–202) switches on `resolvedType: EntryType` and instantiates exactly one of three
editors: `EntryEditView` for `.login`, `CardEditView` for `.card`, `NotesEditView` for
`.notes`. Only `EntryEditView` has a URL field at all — `CardEditView`/`NotesEditView`
are never reached with a `.login` entry and never render one. Because this picker is
added *inside* `EntryEditView`'s own body, unconditionally, it is automatically scoped
to the one template that has a URL field to begin with — there is no separate flag to
check and no additional gating code to write inside `EntryEditView` itself.

**No dedicated test for this task.** This repository has no SwiftUI view-rendering test
harness (confirmed: `MyPassTests` tests pure logic extracted into non-view types —
`EntryEditSaveLogic`, `EntryHistoryOperations`, etc. — never a `View`'s own body).
Verification here is a compile check via the app's own documented build script, not a
unit test; `Self-Review` below records this as a deliberate, narrow deviation from the
plan's usual write-test-first shape, not an oversight.

- [ ] **Step 1: Add the display-string extension and the picker to `EntryEditView.swift`**

In `MyPass/UI/EntryDetail/EntryEditView.swift`, add a new `@State` property near the
other `@State` declarations:

```swift
    @State private var uriMatchMode: URIMatchMode
```

In `init(...)`, alongside the other `_foo = State(initialValue: ...)` assignments:

```swift
        _uriMatchMode = State(initialValue: existingEntry?.uriMatchMode ?? .registrableDomain)
```

Replace the URL `HStack` block in `body`:

```swift
// Replace:
                    HStack {
                        TextField("URL", text: $url)
                        if existingEntry != nil {
                            Button("Edit Websites…") { showWebsitesSheet = true }
                        }
                    }
                    Divider().overlay(Color.primary.opacity(0.08))

// With:
                    HStack {
                        TextField("URL", text: $url)
                        if existingEntry != nil {
                            Button("Edit Websites…") { showWebsitesSheet = true }
                        }
                    }
                    Divider().overlay(Color.primary.opacity(0.08))

                    Picker("Match", selection: $uriMatchMode) {
                        ForEach(URIMatchMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                    Text(uriMatchMode.helpText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Divider().overlay(Color.primary.opacity(0.08))
```

At the bottom of the file, below `EntryEditFieldsCard`, add the display-string extension
(kept local to this file, not on `MyPassKit.URIMatchMode` itself, since `MyPassKit` is
the cross-platform vault engine and has no business holding SwiftUI-facing copy):

```swift
private extension URIMatchMode {
    var displayName: String {
        switch self {
        case .registrableDomain: return "Registrable domain (recommended)"
        case .host: return "Exact host"
        case .startsWith: return "Starts with"
        case .exact: return "Exact address"
        case .never: return "Never (hide from extension)"
        }
    }

    var helpText: String {
        switch self {
        case .registrableDomain:
            return "Matches example.com and any subdomain, such as login.example.com."
        case .host:
            return "Matches only this exact hostname and port. A different subdomain will not match."
        case .startsWith:
            return "Matches any page whose address begins with this one. Note: this can also match " +
                "unrelated pages that share the same prefix, such as example.com/app also matching " +
                "example.com/app-legacy."
        case .exact:
            return "Matches only this exact page address, including its path and query."
        case .never:
            return "Hides this entry from the browser extension only — it stays fully visible and " +
                "usable inside MyPass."
        }
    }
}
```

- [ ] **Step 2: Save the picker's value on the entry**

In `performSave()`, alongside the other `entry.<field> = <state>` assignments:

```swift
// Replace:
        entry.title = EntryEditSaveLogic.resolvedTitle(draftTitle: title, url: url)
        entry.login = login
        entry.password = password
        entry.url = url
        entry.notes = notes
        entry.isFavorite = isFavorite

// With:
        entry.title = EntryEditSaveLogic.resolvedTitle(draftTitle: title, url: url)
        entry.login = login
        entry.password = password
        entry.url = url
        entry.notes = notes
        entry.isFavorite = isFavorite
        entry.uriMatchMode = uriMatchMode
```

- [ ] **Step 3: Regenerate and build**

Run: `./scripts/generate.sh`
Expected: `MyPass.xcodeproj` regenerated with no errors (no new files were added in this
task, but regenerating stays cheap and keeps this step honest about what "builds" means).

Run: `./scripts/build-all.sh`
Expected: the app and `ChromeHost` build successfully, with no compiler errors or
warnings about `EntryEditView.swift`.

- [ ] **Step 4: Commit**

```bash
git add MyPass/UI/EntryDetail/EntryEditView.swift
git commit -m "feat(entry-edit): add a match-mode picker beside the URL field"
```

---

## Task 11 — The sixteenth bridge request, end to end in Swift

This is one task because adding the enum case breaks compilation everywhere at once —
`ExtensionBridgeRequest`/`ExtensionBridgeResponse` and every exhaustive `switch` over them
have no `default:` arm by design (see the doc comments already on `isAnswerableWhileLocked`
and `resetsAutoLockTimer`), so splitting this across commits would leave the tree
unbuildable between them.

**Interfaces:**
- Consumes: `PasswordGeneratorDefaults.load(from:)` (app target, shared contract),
  `PasswordRulesCatalog.rules(forHost:)` and `PasswordGenerator.generate(options:rules:)`
  (both `MyPassKit`, shared contract — already reachable from `ExtensionBridgeService.swift`
  via its existing `import MyPassKit`; `PasswordGeneratorDefaults` needs no import, being
  in the same `MyPass` module).
- Produces: `ExtensionBridgeRequest.generatePassword(token:domain:pairing:)`,
  `ExtensionBridgeResponse.generatedPassword(password:)`, both `Codable`; a
  `response(for:)` handler case in `ExtensionBridgeService.swift`; a `requestToken(from:)`
  case in `LoopbackServer.swift`.

- [ ] **Step 1: Write the failing tests — codec, lock gate, auto-lock, handler**

Append to `Packages/ExtensionBridgeKit/Tests/ExtensionBridgeKitTests/ExtensionBridgeMessagesTests.swift`
(reuses the file's own `jsonObject(from:)` helper):

```swift
    func testGeneratePasswordRoundTripsAndHasExpectedShape() throws {
        let request = ExtensionBridgeRequest.generatePassword(token: "tok-9", domain: "example.com", pairing: "pair-1")
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(ExtensionBridgeRequest.self, from: data)
        XCTAssertEqual(decoded, request)

        let object = try jsonObject(from: data)
        XCTAssertEqual(object["type"] as? String, "generatePassword")
        XCTAssertEqual(object["token"] as? String, "tok-9")
        XCTAssertEqual(object["domain"] as? String, "example.com")
        XCTAssertEqual(object["pairing"] as? String, "pair-1")
    }

    func testGeneratePasswordWithoutPairingOmitsPairingKey() throws {
        let request = ExtensionBridgeRequest.generatePassword(token: "tok-10", domain: "example.com", pairing: nil)
        let data = try JSONEncoder().encode(request)
        let object = try jsonObject(from: data)
        XCTAssertNil(object["pairing"])
    }

    func testGeneratePasswordIsAnswerableWhileLockedIsFalse() {
        let request = ExtensionBridgeRequest.generatePassword(token: "t", domain: "example.com", pairing: nil)
        XCTAssertFalse(request.isAnswerableWhileLocked)
    }

    func testGeneratePasswordResetsAutoLockTimerIsTrue() {
        let request = ExtensionBridgeRequest.generatePassword(token: "t", domain: "example.com", pairing: nil)
        XCTAssertTrue(request.resetsAutoLockTimer)
    }

    func testGeneratedPasswordResponseRoundTripsAndHasExpectedShape() throws {
        let response = ExtensionBridgeResponse.generatedPassword(password: "Tr0ub4dor&3xyz")
        let data = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(ExtensionBridgeResponse.self, from: data)
        XCTAssertEqual(decoded, response)

        let object = try jsonObject(from: data)
        XCTAssertEqual(object["type"] as? String, "generatedPassword")
        XCTAssertEqual(object["password"] as? String, "Tr0ub4dor&3xyz")
    }
```

Append to `MyPassTests/ExtensionBridgeServiceTests.swift` (reuses `service`,
`authorizedPairingSecret`, `session`, `SpyAutoLockActivityRecorder`):

```swift
    func testGeneratePasswordReturnsLockedWhenVaultIsLocked() {
        session.lock()
        let response = service.handle(.generatePassword(token: "t", domain: "example.com", pairing: authorizedPairingSecret))
        XCTAssertEqual(response, .locked)
    }

    func testGeneratePasswordNotifiesAutoLockActivityRecorderWhenServed() {
        let recorder = SpyAutoLockActivityRecorder()
        let store = InMemoryExtensionPairingStore()
        let secret = ExtensionBridgeTokenStore.generateToken()
        let hash = SHA256.hash(data: Data(secret.utf8))
            .compactMap { String(format: "%02x", $0) }
            .joined()
        try! store.add(PairedBrowser(id: UUID(), label: "Test", createdAt: Date(), secretHash: hash))
        let notifying = ExtensionBridgeService(
            vaultSession: session, pairingManager: ExtensionPairingManager(store: store),
            autoLockActivityRecorder: recorder
        )

        let response = notifying.handle(.generatePassword(token: "t", domain: "example.com", pairing: secret))

        guard case .generatedPassword = response else { return XCTFail("expected the request to actually be served") }
        XCTAssertEqual(recorder.recordActivityCallCount, 1, "a paired, served generatePassword is a deliberate user action and must reset the idle timer")
    }

    func testGeneratePasswordForADomainWithAKnownRuleProducesAPasswordSatisfyingItsLengthBounds() throws {
        let domain = "apple.com"
        let rules = try XCTUnwrap(
            PasswordRulesCatalog.rules(forHost: domain),
            "apple.com is expected to carry a rule in the vendored password-rules.json snapshot from Task 1"
        )
        let response = service.handle(.generatePassword(token: "t", domain: domain, pairing: authorizedPairingSecret))
        guard case .generatedPassword(let password) = response else {
            return XCTFail("expected generatedPassword, got \(response)")
        }
        if let minLength = rules.minLength {
            XCTAssertGreaterThanOrEqual(password.count, minLength)
        }
        if let maxLength = rules.maxLength {
            XCTAssertLessThanOrEqual(password.count, maxLength)
        }
    }
```

- [ ] **Step 2: Run and confirm failure**

Run: `swift test --package-path Packages/ExtensionBridgeKit --filter ExtensionBridgeMessagesTests`
Expected: build fails — `type 'ExtensionBridgeRequest' has no member 'generatePassword'`.

(The `MyPassTests` additions cannot even be attempted yet — `ExtensionBridgeService.swift`
and `LoopbackServer.swift` do not compile against the new case either. All three files
change together in the next three steps before anything is run again.)

- [ ] **Step 3: Add the case to `ExtensionBridgeMessages.swift` — both enums, both directions**

In `Packages/ExtensionBridgeKit/Sources/ExtensionBridgeKit/ExtensionBridgeMessages.swift`:

Add the case to the request enum, after `passkeyCancel`:

```swift
    case passkeyCancel(token: String, requestId: Int, pairing: String?)
    case generatePassword(token: String, domain: String, pairing: String?)
```

Add `domain` to `CodingKeys`:

```swift
// Replace:
    private enum CodingKeys: String, CodingKey {
        case type, token, url, id, username, password, pairing, browser, code, otpauthOrSecret, entryId
        case enabled, requestId, requestDetailsJson, originUrl, replace
    }

// With:
    private enum CodingKeys: String, CodingKey {
        case type, token, url, id, username, password, pairing, browser, code, otpauthOrSecret, entryId
        case enabled, requestId, requestDetailsJson, originUrl, replace, domain
    }
```

Add the decode branch in `init(from:)`, immediately before `default:`:

```swift
        case "generatePassword":
            let domain = try container.decode(String.self, forKey: .domain)
            let pairing = try container.decodeIfPresent(String.self, forKey: .pairing)
            self = .generatePassword(token: token, domain: domain, pairing: pairing)
```

Add the encode branch in `encode(to:)`, as the last case:

```swift
        case .generatePassword(let token, let domain, let pairing):
            try container.encode("generatePassword", forKey: .type)
            try container.encode(token, forKey: .token)
            try container.encode(domain, forKey: .domain)
            try container.encodeIfPresent(pairing, forKey: .pairing)
```

Update `isAnswerableWhileLocked` — `generatePassword` joins the `false` arm (it needs no
vault data, but per the spec's Decision 6 this is a deliberate trade-off, not served while
locked, to keep `isAnswerableWhileLocked` as short as it already is):

```swift
// Replace:
        case .getCredentials, .fillCredential, .getTotp, .proposeSaveLogin, .proposeSaveTotp, .startPairing, .completePairing,
             .setPasskeyProxyEnabled, .passkeyCreate, .passkeyCreateConfirm, .passkeyGet, .passkeyGetApprove, .passkeyCancel:
            return false

// With:
        case .getCredentials, .fillCredential, .getTotp, .proposeSaveLogin, .proposeSaveTotp, .startPairing, .completePairing,
             .setPasskeyProxyEnabled, .passkeyCreate, .passkeyCreateConfirm, .passkeyGet, .passkeyGetApprove, .passkeyCancel,
             .generatePassword:
            return false
```

Update `resetsAutoLockTimer` — `generatePassword` joins the `true` arm, grouped with the
other popup-button-click-gated requests, per the spec's Decision 6:

```swift
// Replace:
        case .fillCredential, .getTotp, .proposeSaveLogin, .proposeSaveTotp,
             .passkeyCreateConfirm, .passkeyGetApprove, .requestUnlock:
            return true

// With:
        case .fillCredential, .getTotp, .proposeSaveLogin, .proposeSaveTotp,
             .passkeyCreateConfirm, .passkeyGetApprove, .requestUnlock, .generatePassword:
            return true
```

Add the response case, after `passkeyCancelled`:

```swift
    case passkeyCancelled(requestId: Int)
    case generatedPassword(password: String)
    case error(String)
```

Add the decode branch in the response's `init(from:)` (reuses the existing `password` key
— no new `CodingKeys` case needed on the response side):

```swift
        case "generatedPassword":
            let password = try container.decode(String.self, forKey: .password)
            self = .generatedPassword(password: password)
```

Add the encode branch in the response's `encode(to:)`:

```swift
        case .generatedPassword(let password):
            try container.encode("generatedPassword", forKey: .type)
            try container.encode(password, forKey: .password)
```

- [ ] **Step 4: Run and confirm the package-level tests pass**

Run: `swift test --package-path Packages/ExtensionBridgeKit --filter ExtensionBridgeMessagesTests`
Expected: PASS, including all 5 new tests from Step 1.

- [ ] **Step 5: Add the handler in `ExtensionBridgeService.swift`**

In `MyPass/State/ExtensionBridge/ExtensionBridgeService.swift`, add `.generatedPassword` to
the served-classification list in `requestWasServed(_:)`:

```swift
// Replace:
        case .pairingStarted, .paired, .credentialList, .credential, .totp, .saveProposalAccepted,
             .unlockPresented, .unlockNotNeeded, .passkeyProxyStatus, .passkeyProxyEnabled,
             .passkeyCreatePending, .passkeyGetPending, .passkeyCancelled:
            return true

// With:
        case .pairingStarted, .paired, .credentialList, .credential, .totp, .saveProposalAccepted,
             .unlockPresented, .unlockNotNeeded, .passkeyProxyStatus, .passkeyProxyEnabled,
             .passkeyCreatePending, .passkeyGetPending, .passkeyCancelled, .generatedPassword:
            return true
```

Add the case to `response(for:)`'s switch, as the last case before the closing brace:

```swift
        case .generatePassword(_, let domain, let pairing):
            guard pairingManager.isAuthorized(pairing: pairing) else {
                return .pairingRequired
            }
            // No vault data is needed here — rules come from the bundled
            // PasswordRulesCatalog and preferences from PasswordGeneratorDefaults,
            // neither of which lives behind the vault key. The outer guard at the
            // top of this function (`vaultSession?.currentDatabase != nil ||
            // request.isAnswerableWhileLocked`) already turned away a locked vault
            // before this case is ever reached — generatePassword.isAnswerableWhileLocked
            // is false — so there is no redundant lock re-check to write here.
            let options = PasswordGeneratorDefaults.load()
            let rules = PasswordRulesCatalog.rules(forHost: domain)
            do {
                let password = try PasswordGenerator.generate(options: options, rules: rules)
                return .generatedPassword(password: password)
            } catch {
                // .unsatisfiableRules (and any other PasswordGeneratorError) surfaces
                // through the existing generic `.error(String)` response case — there
                // is no dedicated failure case for this request, matching how
                // .completePairing already reports its own failure via `.error("invalid_code")`.
                return .error("This site's password requirements could not be satisfied")
            }
```

- [ ] **Step 6: Add the token-extraction case in `LoopbackServer.swift`**

In `MyPass/State/ExtensionBridge/LoopbackServer.swift`, in `requestToken(from:)`:

```swift
// Replace:
        case .passkeyCancel(let token, _, _): return token
        }

// With:
        case .passkeyCancel(let token, _, _): return token
        case .generatePassword(let token, _, _): return token
        }
```

- [ ] **Step 7: Run and confirm every new test passes**

Run: `xcodebuild test -scheme MyPass -only-testing:MyPassTests/ExtensionBridgeServiceTests`
Expected: PASS, including `testGeneratePasswordReturnsLockedWhenVaultIsLocked`,
`testGeneratePasswordNotifiesAutoLockActivityRecorderWhenServed`, and
`testGeneratePasswordForADomainWithAKnownRuleProducesAPasswordSatisfyingItsLengthBounds`,
alongside every pre-existing test in the file.

Run: `swift test --package-path Packages/ExtensionBridgeKit`
Expected: PASS, full package suite, 0 failures — proves the new case did not silently
break any other exhaustive switch in `ExtensionBridgeKit`.

- [ ] **Step 8: Commit**

```bash
git add Packages/ExtensionBridgeKit/Sources/ExtensionBridgeKit/ExtensionBridgeMessages.swift \
        Packages/ExtensionBridgeKit/Tests/ExtensionBridgeKitTests/ExtensionBridgeMessagesTests.swift \
        MyPass/State/ExtensionBridge/ExtensionBridgeService.swift \
        MyPass/State/ExtensionBridge/LoopbackServer.swift \
        MyPassTests/ExtensionBridgeServiceTests.swift
git commit -m "feat(app): add the generatePassword bridge request and response"
```

---

## Task 12 — New-password field classification in the content script

**Interfaces:**
- Produces: `isNewPasswordCandidate(input, allPasswordInputs)` in `ChromeExtension/content.js`,
  exported for tests; `findFillableFields`'s password descriptors gain a boolean
  `isNewPassword` property (exact name required by the shared contract).
- Consumes: nothing new.

- [ ] **Step 1: Write the failing tests**

Create `ChromeExtension/tests/newPasswordDetection.test.js`:

```js
const assert = require('node:assert');
const path = require('node:path');
const { findFillableFields, isNewPasswordCandidate } = require(path.join(__dirname, '..', 'content.js'));

function fakeInput(attrs) {
  return {
    getAttribute(name) {
      return Object.prototype.hasOwnProperty.call(attrs, name) ? attrs[name] : null;
    },
    closest() {
      return null;
    },
    disabled: false,
    readOnly: false,
    offsetParent: {}
  };
}

// --- isNewPasswordCandidate: the pure classification decision ------------------------

{
  const field = fakeInput({ type: 'password', autocomplete: 'new-password' });
  assert.strictEqual(isNewPasswordCandidate(field, [field]), true, 'autocomplete=new-password is decisive');
}

{
  const field = fakeInput({ type: 'password', autocomplete: 'current-password' });
  assert.strictEqual(
    isNewPasswordCandidate(field, [field]),
    false,
    'autocomplete=current-password is decisive the other way, even with no sibling'
  );
}

{
  // No decisive attribute, only one password field on the page: treated as a login field.
  const field = fakeInput({ type: 'password' });
  assert.strictEqual(
    isNewPasswordCandidate(field, [field]),
    false,
    'a single unhinted password field is a login field, not a new-password field'
  );
}

{
  // No decisive attribute, two password fields (the confirm-password shape): both count.
  const newField = fakeInput({ type: 'password' });
  const confirmField = fakeInput({ type: 'password' });
  const all = [newField, confirmField];
  assert.strictEqual(isNewPasswordCandidate(newField, all), true, 'the confirm-password shape marks the first field as new-password');
  assert.strictEqual(isNewPasswordCandidate(confirmField, all), true, 'the confirm-password shape marks the second field as new-password too');
}

console.log('newPasswordDetection.test.js: isNewPasswordCandidate OK');

// --- findFillableFields: isNewPassword threaded onto each password descriptor --------

function fakeScope(inputs) {
  return {
    querySelectorAll(selector) {
      if (selector === 'input[type="password"]') return inputs.filter((i) => i.getAttribute('type') === 'password');
      return [];
    }
  };
}

{
  const loginField = fakeInput({ type: 'password', autocomplete: 'current-password' });
  const fields = findFillableFields(fakeScope([loginField]));
  const passwordField = fields.find((f) => f.kind === 'password');
  assert.ok(passwordField, 'expected a password field descriptor');
  assert.strictEqual(passwordField.isNewPassword, false, 'a login field must not be offered password generation');
}

{
  const signupField = fakeInput({ type: 'password', autocomplete: 'new-password' });
  const fields = findFillableFields(fakeScope([signupField]));
  const passwordField = fields.find((f) => f.kind === 'password');
  assert.ok(passwordField, 'expected a password field descriptor');
  assert.strictEqual(passwordField.isNewPassword, true, 'autocomplete=new-password must be offered password generation');
}

console.log('newPasswordDetection.test.js: findFillableFields isNewPassword wiring OK');
```

- [ ] **Step 2: Run and confirm failure**

Run: `node ChromeExtension/tests/newPasswordDetection.test.js`
Expected: `TypeError: isNewPasswordCandidate is not a function` (not yet exported —
`content.js` does not define it yet).

- [ ] **Step 3: Implement `isNewPasswordCandidate` and wire it into `findFillableFields`**

In `ChromeExtension/content.js`, add the new function immediately above `findFillableFields`:

```js
  // A password field's autocomplete attribute is a decisive signal when present — the
  // same trust level scoreOtpLikeness already gives autocomplete=one-time-code. When it
  // is absent, fall back to the confirm-password shape: a signup form's "new password"
  // and "confirm password" fields are the only common case with two or more password
  // fields visible at once. A single, unhinted password field is treated as a login
  // field, not a new-password field — offering "Generate password" there would replace
  // a credential the user is trying to type in order to sign in, not create.
  function isNewPasswordCandidate(input, allPasswordInputs) {
    const autocomplete = (input.getAttribute('autocomplete') || '').toLowerCase();
    if (autocomplete === 'new-password') return true;
    if (autocomplete === 'current-password') return false;
    return allPasswordInputs.length >= 2;
  }
```

Modify the password loop inside `findFillableFields`:

```js
// Replace:
    const passwords = Array.from(scope.querySelectorAll('input[type="password"]')).filter(isFieldVisible);
    for (const password of passwords) {
      fields.push({ input: password, kind: 'password' });
    }

// With:
    const passwords = Array.from(scope.querySelectorAll('input[type="password"]')).filter(isFieldVisible);
    for (const password of passwords) {
      fields.push({ input: password, kind: 'password', isNewPassword: isNewPasswordCandidate(password, passwords) });
    }
```

Add `isNewPasswordCandidate` to the `module.exports` list at the bottom of the file:

```js
// Replace:
      scoreUsernameLikeness, findBestUsernameInput, hostnameMatches, scoreOtpLikeness, findOtpField,
      isFieldVisible, findFillableFields, findLoginForm, resolveFillTargets,

// With:
      scoreUsernameLikeness, findBestUsernameInput, hostnameMatches, scoreOtpLikeness, findOtpField,
      isFieldVisible, findFillableFields, findLoginForm, resolveFillTargets, isNewPasswordCandidate,
```

- [ ] **Step 4: Run and confirm pass**

Run: `node ChromeExtension/tests/newPasswordDetection.test.js`
Expected: both `console.log` lines print, no assertion throws, exit code 0.

- [ ] **Step 5: Add the new test to the full suite runner**

In `scripts/test.sh`, add the new file to the node test block (after
`scriptScopes.test.js`):

```bash
# Replace:
  node ChromeExtension/tests/scriptScopes.test.js

# With:
  node ChromeExtension/tests/scriptScopes.test.js
  node ChromeExtension/tests/newPasswordDetection.test.js
```

- [ ] **Step 6: Commit**

```bash
git add ChromeExtension/content.js ChromeExtension/tests/newPasswordDetection.test.js scripts/test.sh
git commit -m "feat(extension): classify new-password fields in the inline field detector"
```

---

## Task 13 — Generation actions in the extension

**Interfaces:**
- Consumes: `isNewPassword` on password field descriptors (Task 12); the
  `generatePassword`/`generatedPassword` wire messages (Task 11).
- Produces: `"generatePassword"` in `background.js`'s `knownTypes`; a "Generate password"
  row in `content.js`'s inline panel, gated on `isNewPassword` and `event.isTrusted`; a
  "Generate password" button in `popup.js`, gated on the active tab reporting a
  new-password field via a new `queryNewPasswordField` runtime message (mirroring how
  `requestPageTotpCandidate` already asks the content script for page state).

**The one silent-at-runtime failure mode in this whole plan.** Every other mistake in
Tasks 8–12 is either a compile error (Swift's exhaustive switches) or a failing test
(the JS classification logic). Omitting `"generatePassword"` from `background.js`'s
`knownTypes` array is different: `handleRuntimeMessage`'s gate
(`if (!message || !knownTypes.includes(message.type)) { return false; }`) silently drops
the message before it ever reaches `sendNativeMessageWithPairing` — no error, no
console warning, just a popup button or inline action that quietly does nothing. This
is called out explicitly in Decision 6 of the spec and is why Step 1 below tests the
allowlist directly, not only the end-to-end forwarding behaviour.

- [ ] **Step 1: Write the failing tests**

Create `ChromeExtension/tests/generatePassword.test.js`:

```js
const assert = require('node:assert');
const path = require('node:path');

// --- background.js: the allowlist gate --------------------------------------------

const { knownTypes } = require(path.join(__dirname, '..', 'background.js'));
assert.ok(
  knownTypes.includes('generatePassword'),
  'generatePassword must be in the allowlist or the message is silently dropped before it ever reaches the native host'
);

// --- background.js: handleRuntimeMessage forwards it to the native host ------------

let sentNativeMessage = null;
global.chrome = {
  runtime: {
    lastError: null,
    id: 'test-extension-id',
    sendNativeMessage: (hostName, message, cb) => {
      sentNativeMessage = message;
      cb({ type: 'generatedPassword', password: 'Tr0ub4dor&3' });
    },
    onMessage: { addListener: () => {} }
  },
  storage: {
    local: {
      get: (_key, cb) => cb({}),
      set: (_obj, cb) => cb && cb(),
      remove: (_key, cb) => cb && cb()
    }
  }
};

delete require.cache[require.resolve(path.join(__dirname, '..', 'background.js'))];
const { handleRuntimeMessage } = require(path.join(__dirname, '..', 'background.js'));

{
  let responded = null;
  const keepChannelOpen = handleRuntimeMessage(
    { type: 'generatePassword', domain: 'example.com' },
    { tab: undefined },
    (response) => { responded = response; }
  );
  assert.strictEqual(keepChannelOpen, true, 'the async response path must keep the message channel open');
  assert.ok(sentNativeMessage, 'generatePassword must be forwarded to the native host');
  assert.strictEqual(sentNativeMessage.type, 'generatePassword');
  assert.strictEqual(sentNativeMessage.domain, 'example.com');
  assert.deepStrictEqual(responded, { type: 'generatedPassword', password: 'Tr0ub4dor&3' });
}

console.log('generatePassword.test.js: background.js allowlist + forwarding OK');

// --- content.js: buildNewPasswordFieldQueryResponse ---------------------------------

const { buildNewPasswordFieldQueryResponse } = require(path.join(__dirname, '..', 'content.js'));

function fakeInput(attrs) {
  return {
    getAttribute(name) { return Object.prototype.hasOwnProperty.call(attrs, name) ? attrs[name] : null; },
    closest() { return null; },
    disabled: false,
    readOnly: false,
    offsetParent: {}
  };
}

function fakeRoot(inputs) {
  return {
    querySelectorAll(selector) {
      if (selector === 'input[type="password"]') return inputs.filter((i) => i.getAttribute('type') === 'password');
      return [];
    }
  };
}

{
  const loginOnly = fakeRoot([fakeInput({ type: 'password', autocomplete: 'current-password' })]);
  assert.deepStrictEqual(buildNewPasswordFieldQueryResponse(loginOnly), { hasNewPasswordField: false });
}

{
  const signup = fakeRoot([fakeInput({ type: 'password', autocomplete: 'new-password' })]);
  assert.deepStrictEqual(buildNewPasswordFieldQueryResponse(signup), { hasNewPasswordField: true });
}

console.log('generatePassword.test.js: buildNewPasswordFieldQueryResponse OK');
```

- [ ] **Step 2: Run and confirm failure**

Run: `node ChromeExtension/tests/generatePassword.test.js`
Expected: the first `assert.ok(knownTypes.includes('generatePassword'), ...)` throws —
`knownTypes` does not contain `"generatePassword"` yet.

- [ ] **Step 3: Add `"generatePassword"` to `background.js`'s allowlist**

In `ChromeExtension/background.js`:

```js
// Replace:
const knownTypes = [
  "getCredentials", "fillCredential", "getTotp", "proposeSaveLogin", "proposeSaveTotp",
  "startPairing", "completePairing", "requestUnlock",
  "getPasskeyProxyStatus", "setPasskeyProxyEnabled", "passkeyCreateConfirm", "passkeyGetApprove"
];

// With:
const knownTypes = [
  "getCredentials", "fillCredential", "getTotp", "proposeSaveLogin", "proposeSaveTotp",
  "startPairing", "completePairing", "requestUnlock",
  "getPasskeyProxyStatus", "setPasskeyProxyEnabled", "passkeyCreateConfirm", "passkeyGetApprove",
  "generatePassword"
];
```

No other change to `background.js` is needed: `generatePassword` is not `fillCredential`,
`setPasskeyProxyEnabled`, `passkeyCreateConfirm`/`passkeyGetApprove`, `startPairing`, or
`completePairing`, so it falls through `handleRuntimeMessage` to the generic forwarding
branch at the bottom (`sendNativeMessageWithPairing(message).then((response) => { ...
sendResponse(response); })`), which already attaches the pairing token and forwards the
response verbatim — exactly what `generatePassword` needs.

- [ ] **Step 4: Run and confirm the background.js half passes**

Run: `node ChromeExtension/tests/generatePassword.test.js`
Expected: the allowlist assertion and the forwarding assertions pass; the
`buildNewPasswordFieldQueryResponse` require still fails — that function does not exist
in `content.js` yet.

- [ ] **Step 5: Add the new-password-field query responder to `content.js`**

In `ChromeExtension/content.js`, add `newPasswordFieldQuery` to `FRAME_FEATURE_POLICY`
(mirrors `totpCandidateQuery`'s top-only policy — a one-shot popup query must not race
between multiple frames answering it):

```js
// Replace:
  const FRAME_FEATURE_POLICY = {
    inlineIcon: 'allFrames',
    saveBanner: 'topOnly',
    totpBanner: 'topOnly',
    totpScan: 'topOnly',
    totpCandidateQuery: 'topOnly',
  };

// With:
  const FRAME_FEATURE_POLICY = {
    inlineIcon: 'allFrames',
    saveBanner: 'topOnly',
    totpBanner: 'topOnly',
    totpScan: 'topOnly',
    totpCandidateQuery: 'topOnly',
    newPasswordFieldQuery: 'topOnly',
  };
```

Add the exported, DOM-free responder near `buildTotpCandidateQueryResponse` (same reason
that function is separated from the `chrome.runtime.onMessage` listener: the listener
itself lives inside the browser-only wiring block below and is not reachable from node
tests without a full DOM/chrome stub):

```js
  // What the content script answers a popup's `{ type: 'queryNewPasswordField' }`
  // request with — whether this document currently has a field the popup could offer
  // to fill with a generated password. Exported (like buildTotpCandidateQueryResponse
  // above) so the classification is testable without a DOM.
  function buildNewPasswordFieldQueryResponse(root) {
    const hasNewPasswordField = findFillableFields(root).some((field) => field.kind === 'password' && field.isNewPassword);
    return { hasNewPasswordField };
  }
```

Wire it into the existing `chrome.runtime.onMessage` listener, alongside the
`queryTotpCandidate` branch:

```js
// Replace:
    chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
      if (message.type === 'queryTotpCandidate') {
        if (!runsHere('totpCandidateQuery')) return;
        sendResponse(buildTotpCandidateQueryResponse(document));
        return;
      }

// With:
    chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
      if (message.type === 'queryTotpCandidate') {
        if (!runsHere('totpCandidateQuery')) return;
        sendResponse(buildTotpCandidateQueryResponse(document));
        return;
      }
      if (message.type === 'queryNewPasswordField') {
        if (!runsHere('newPasswordFieldQuery')) return;
        sendResponse(buildNewPasswordFieldQueryResponse(document));
        return;
      }
```

Add `buildNewPasswordFieldQueryResponse` to `module.exports`:

```js
// Replace:
      buildTotpCandidateQueryResponse, showTotpSaveBanner, showSaveBanner,

// With:
      buildTotpCandidateQueryResponse, buildNewPasswordFieldQueryResponse, showTotpSaveBanner, showSaveBanner,
```

- [ ] **Step 6: Run and confirm pass**

Run: `node ChromeExtension/tests/generatePassword.test.js`
Expected: all three `console.log` lines print, no assertion throws, exit code 0.

- [ ] **Step 7: Add the inline panel's "Generate password" row in `content.js`**

Thread `isNewPassword` from `findFillableFields` through icon attachment to `togglePanel`.

```js
// Replace:
    function attachIconTo(input, kind) {
      if (attachedIcons.has(input)) return;
      if (!document.body) return;
      const { host, button } = buildIconHost(document);
      button.addEventListener('click', (event) => {
        handleIconActivate(event, () => togglePanel(input, kind));
      });

// With:
    function attachIconTo(input, kind, isNewPassword) {
      if (attachedIcons.has(input)) return;
      if (!document.body) return;
      const { host, button } = buildIconHost(document);
      button.addEventListener('click', (event) => {
        handleIconActivate(event, () => togglePanel(input, kind, isNewPassword));
      });
```

```js
// Replace:
    function attachIcons() {
      pruneDetachedIcons();
      for (const field of findFillableFields(document)) {
        attachIconTo(field.input, field.kind);
      }
    }

// With:
    function attachIcons() {
      pruneDetachedIcons();
      for (const field of findFillableFields(document)) {
        attachIconTo(field.input, field.kind, field.isNewPassword);
      }
    }
```

Add the row-building helper near `buildPanelContent`:

```js
  // The inline panel's "Generate password" action — a plain row, not one of
  // buildPanelContent's credential rows, since it has no entry behind it. Appended
  // by togglePanel only for a field kind === 'password' with isNewPassword === true.
  function buildGeneratePasswordRow(doc, onClick) {
    const row = doc.createElement('button');
    row.setAttribute('type', 'button');
    row.setAttribute('class', 'row generate-password-row');
    row.textContent = 'Generate password';
    row.addEventListener('click', onClick);
    return row;
  }
```

Thread `isNewPassword` through `togglePanel` and append the row when applicable:

```js
// Replace:
    function togglePanel(input, kind) {
      const wasOpenForThisInput = !!(openPanel && openPanel.input === input);
      closePanel();
      if (wasOpenForThisInput) return;

// With:
    function togglePanel(input, kind, isNewPassword) {
      const wasOpenForThisInput = !!(openPanel && openPanel.input === input);
      closePanel();
      if (wasOpenForThisInput) return;
```

```js
// Replace:
        shadow.appendChild(content.root);
        const rect = input.getBoundingClientRect();

// With:
        if (kind === 'password' && isNewPassword) {
          const generateRow = buildGeneratePasswordRow(document, trustedClickHandler(() => {
            sendRuntimeMessage({ type: 'generatePassword', domain: location.hostname }, (genResponse) => {
              if (genResponse && genResponse.type === 'generatedPassword' && genResponse.password) {
                setNativeValue(input, genResponse.password);
              }
              closePanel();
            });
          }));
          content.root.appendChild(generateRow);
        }
        shadow.appendChild(content.root);
        const rect = input.getBoundingClientRect();
```

Add `buildGeneratePasswordRow` to `module.exports`:

```js
// Replace:
      buildTotpCandidateQueryResponse, buildNewPasswordFieldQueryResponse, showTotpSaveBanner, showSaveBanner,

// With:
      buildTotpCandidateQueryResponse, buildNewPasswordFieldQueryResponse, buildGeneratePasswordRow, showTotpSaveBanner, showSaveBanner,
```

Filling is `setNativeValue(input, ...)` — the same fallback path `applyFill`'s handler
already uses for a direct DOM write to a field this content-script instance already
holds a reference to, scoped to this document because `input` came from this document's
own `findFillableFields(document)` call. The action is gated on `event.isTrusted` via
`trustedClickHandler`, the same gate every other inline-icon action in this file uses.

- [ ] **Step 8: Add the "Generate password" section to `popup.html`**

In `ChromeExtension/popup.html`, add a new section mirroring `add-totp-section`,
immediately before it:

```html
<div id="generate-password-section" hidden>
  <p id="generate-password-hint">This page has a new-password field</p>
  <button id="generate-password-btn" type="button" class="btn-primary">Generate password</button>
  <p id="generate-password-error" hidden></p>
</div>

<div id="add-totp-section" hidden>
```

- [ ] **Step 9: Add the popup's "Generate password" action in `popup.js`**

Add the two forward-declared function slots near the other `let ... = null;` declarations:

```js
// Replace:
let requestPageTotpCandidate = null;

// With:
let requestPageTotpCandidate = null;
let requestPageNewPasswordField = null;
let handleGeneratePasswordClick = null;
```

Inside the `if (typeof document !== 'undefined') { ... }` block, add the DOM references
alongside `addTotpSection`/`addTotpBtn`/`totpPasteInput`/`addTotpErrorEl`:

```js
// Replace:
  const addTotpSection = document.getElementById('add-totp-section');
  const addTotpBtn = document.getElementById('add-totp-btn');
  const totpPasteInput = document.getElementById('totp-paste-input');
  const addTotpErrorEl = document.getElementById('add-totp-error');
  addTotpSection.hidden = true;

// With:
  const addTotpSection = document.getElementById('add-totp-section');
  const addTotpBtn = document.getElementById('add-totp-btn');
  const totpPasteInput = document.getElementById('totp-paste-input');
  const addTotpErrorEl = document.getElementById('add-totp-error');
  addTotpSection.hidden = true;

  const generatePasswordSection = document.getElementById('generate-password-section');
  const generatePasswordBtn = document.getElementById('generate-password-btn');
  const generatePasswordErrorEl = document.getElementById('generate-password-error');
  generatePasswordSection.hidden = true;
```

Add the query function, mirroring `requestPageTotpCandidate`:

```js
  // Mirrors requestPageTotpCandidate: asks the active tab's content script whether this
  // page currently has a new-password field, and shows/hides the Generate section
  // accordingly. Restricted to "there is a field to fill" for a concrete reason (Decision
  // 7 of the design spec): without a target field, the only place to put a freshly
  // generated secret would be the system clipboard, and the extension has no bridge call
  // equivalent to the app's own ClipboardAutoClear — so this popup action must never
  // create that secret-in-clipboard state in the first place.
  requestPageNewPasswordField = function (tabId) {
    if (typeof tabId !== 'number' || typeof chrome.tabs.sendMessage !== 'function') return;
    chrome.tabs.sendMessage(tabId, { type: 'queryNewPasswordField' }, (resp) => {
      const lastError = chrome.runtime.lastError;
      if (lastError || !resp || !resp.hasNewPasswordField) return;
      generatePasswordSection.hidden = false;
    });
  };
```

Add the click handler:

```js
  // Generates a password via the bridge and fills it straight into the active tab's
  // new-password field — scoped to frameId 0 for the same reason sendApplyFill in
  // background.js already is: the popup only ever acts on the active tab's top-level
  // document (opening the popup is itself the gesture that grants activeTab there).
  handleGeneratePasswordClick = function (activeTabUrl) {
    generatePasswordErrorEl.hidden = true;
    let domain;
    try {
      domain = new URL(activeTabUrl).hostname;
    } catch (e) {
      generatePasswordErrorEl.textContent = "Couldn't determine this page's domain";
      generatePasswordErrorEl.hidden = false;
      return;
    }
    chrome.runtime.sendMessage({ type: 'generatePassword', domain }, (response) => {
      if (!response || response.type !== 'generatedPassword' || !response.password) {
        generatePasswordErrorEl.textContent = describeSaveProposalOutcome(response);
        generatePasswordErrorEl.hidden = false;
        return;
      }
      chrome.tabs.query({ active: true, currentWindow: true }, (tabs) => {
        const activeTab = tabs[0];
        if (!activeTab || activeTab.id === undefined) return;
        chrome.tabs.sendMessage(
          activeTab.id,
          { type: 'applyFill', username: null, password: response.password, totp: null, url: activeTabUrl },
          { frameId: 0 },
          () => { void chrome.runtime.lastError; }
        );
        window.close();
      });
    });
  };

  generatePasswordBtn.onclick = () => handleGeneratePasswordClick(currentTabUrl);
```

Call the query alongside the existing TOTP one, inside `initPasskeyPopupUI`:

```js
// Replace:
        queryCredentials(activeTab.url);
        requestPageTotpCandidate(activeTab.id);

// With:
        queryCredentials(activeTab.url);
        requestPageTotpCandidate(activeTab.id);
        requestPageNewPasswordField(activeTab.id);
```

Add both new functions to `module.exports`:

```js
// Replace:
    requestPageTotpCandidate,

// With:
    requestPageTotpCandidate,
    requestPageNewPasswordField,
    handleGeneratePasswordClick,
```

- [ ] **Step 10: Run and confirm the full node suite for this pair of files still passes**

Run: `node ChromeExtension/tests/generatePassword.test.js`
Expected: PASS, unchanged from Step 6 — Steps 7–9 add UI wiring the test file does not
re-exercise directly (the DOM-building helper and the popup click handler have no
dedicated DOM harness in this repo, matching Task 10's own note about the absence of a
view-rendering test harness).

Run: `node ChromeExtension/tests/inlineIcon.test.js`
Expected: PASS, unchanged — proves `togglePanel`'s new third parameter and the
conditional row append did not regress any existing inline-panel behaviour.

Run: `node ChromeExtension/tests/totpPicker.test.js`
Expected: PASS, unchanged — proves the `popup.js` edits (new DOM lookups, new exports)
did not break the file's existing module-load-time behaviour under node.

- [ ] **Step 11: Add the new test file to the full suite runner**

In `scripts/test.sh`:

```bash
# Replace:
  node ChromeExtension/tests/newPasswordDetection.test.js

# With:
  node ChromeExtension/tests/newPasswordDetection.test.js
  node ChromeExtension/tests/generatePassword.test.js
```

- [ ] **Step 12: Commit**

```bash
git add ChromeExtension/background.js ChromeExtension/content.js ChromeExtension/popup.js \
        ChromeExtension/popup.html ChromeExtension/tests/generatePassword.test.js scripts/test.sh
git commit -m "feat(extension): offer password generation from the inline panel and popup"
```

---

## Task 14 — Roadmap and full verification

**Interfaces:**
- Produces: a new stage in `docs/implementation/ROADMAP.md`, following the file's own
  established `## Stage N — <name>` / `- [ ] **Task N** — <description>` /
  `**⛳ Gate N —** ...` shape (verified directly against Stage 8's exact formatting).
- Consumes: nothing new — this task only verifies and documents everything Tasks 1–13
  produced.

- [ ] **Step 1: Add the new stage with every box unchecked**

Append to `docs/implementation/ROADMAP.md`, immediately before the `## Known trap when
running the suite` section (i.e. as the new final stage, after Stage 8):

```markdown
## Stage 9 — Site-aware password rules and per-entry URI match modes

Two related, fully offline capabilities: MyPass generates passwords that a site's own
Password Rules will actually accept, in both the app's generator and the browser
extension; and a vault entry can declare how its URL is matched against a page, via one
of five explicit `URIMatchMode` values, replacing the single hardcoded
registrable-domain rule. Spec:
[`2026-09-12-site-password-rules-and-uri-matching-design`](../superpowers/specs/2026-09-12-site-password-rules-and-uri-matching-design.md),
plan: [`2026-09-12-site-password-rules-and-uri-matching`](../superpowers/plans/2026-09-12-site-password-rules-and-uri-matching.md).

- [ ] **Task 1** — Vendor Apple's `password-rules.json` snapshot into `Packages/MyPassKit`, with its provenance file and `scripts/update-password-rules.sh`
- [ ] **Task 2** — `PasswordRulesParser` for the Password Rules grammar, with fixtures derived from Apple's own reference parser tests
- [ ] **Task 3** — `PasswordRulesCatalog`, a host-keyed rule lookup that walks up to (but never above) the registrable domain
- [ ] **Task 4** — `PasswordGenerator.generate(options:rules:)` honours required/allowed character classes, length clamping, `max-consecutive` repair, and a typed `.unsatisfiableRules` failure
- [ ] **Task 5** — `PasswordGeneratorView` surfaces the active rule in plain English, with a control to override it
- [ ] **Task 6** — `PasswordGeneratorDefaults` persists the user's generator toggles, shared by the app's own Generate button and the bridge handler
- [ ] **Task 7** — Property test against every rule in the vendored snapshot: every generated password satisfies its own rule
- [ ] **Task 8** — `URIMatchMode` and its hidden `MyPass.URIMatchMode` field on `KdbxEntry`, defaulting to `.registrableDomain` with no migration needed
- [ ] **Task 9** — `ExtensionEntryMatcher` matches per-entry against all five `URIMatchMode` values, with `never` excluded before any credential list is assembled
- [ ] **Task 10** — A match-mode picker beside the URL field in the entry edit form, with per-mode help text
- [ ] **Task 11** — The 16th bridge request/response pair, `generatePassword`/`generatedPassword`, wired through every exhaustive switch in `ExtensionBridgeKit`, `ExtensionBridgeService`, and `LoopbackServer`
- [ ] **Task 12** — `content.js` classifies password fields as `isNewPassword` via `autocomplete=new-password` or the confirm-password shape
- [ ] **Task 13** — "Generate password" actions in the inline panel and the popup, gated on `event.isTrusted` and on the page actually having a new-password field

**⛳ Gate 9** — `./scripts/test.sh` green, run unpiped and its actual output read (see
"Known trap when running the suite" below — piping to `tail` reports the pipe's exit
code, not the script's). Boxes above are ticked only once this run is confirmed green,
per this repository's rule that a roadmap box means "implemented AND its tests pass."
```

- [ ] **Step 2: Regenerate the Xcode project**

Run: `./scripts/generate.sh`
Expected: `MyPass.xcodeproj` regenerated with no errors, picking up every new file from
Tasks 8 and 11 (`URIMatchMode.swift`, `KdbxEntry+URIMatch.swift`,
`KdbxEntryURIMatchTests.swift`, `URIMatchModeTests.swift`).

- [ ] **Step 3: Run the full suite, unpiped, and read its actual output**

Run: `./scripts/test.sh`
Expected — read every line, do not pipe to `tail` or anything else (this exact mistake
is recorded in this file's own "Known trap" section as having once made a 4-failure run
read as a pass):
- `xcodebuild test -scheme MyPass` reports `** TEST SUCCEEDED **` with 0 failures,
  including every test added in Tasks 8, 9, 10 (compile-only), and 11.
- `swift test` in `Packages/MyPassKit` reports 0 failures, including `URIMatchModeTests`.
- `swift test` in `Packages/ExtensionBridgeKit` reports 0 failures, including the new
  `generatePassword`/`generatedPassword` codec tests.
- `swift test` in `Packages/SyncKit` reports 0 failures (unaffected by this plan, but
  part of the full suite).
- All 17 node scripts under `ChromeExtension/tests/` (15 pre-existing plus
  `newPasswordDetection.test.js` and `generatePassword.test.js`) print their `console.log`
  success lines with no thrown assertion.
- The script's own exit code is `0` (check directly: `echo $?` after the run, not by
  eyeballing the log for the word "PASS").

If anything is red, stop here and fix it — do not proceed to Step 4 with a red run.

- [ ] **Step 4: Tick every roadmap box now that the suite is confirmed green**

In `docs/implementation/ROADMAP.md`, change every `- [ ] **Task N**` line added in Step 1
to `- [x] **Task N**`, and update the gate line:

```markdown
// Replace:
**⛳ Gate 9** — `./scripts/test.sh` green, run unpiped and its actual output read (see
"Known trap when running the suite" below — piping to `tail` reports the pipe's exit
code, not the script's). Boxes above are ticked only once this run is confirmed green,
per this repository's rule that a roadmap box means "implemented AND its tests pass."

// With:
**⛳ Gate 9 — PASSED.** `./scripts/test.sh` green unpiped (`EXIT=0`,
`** TEST SUCCEEDED **`, 0 Swift-package failures, all 17 node scripts OK).
```

- [ ] **Step 5: Commit**

```bash
git add docs/implementation/ROADMAP.md
git commit -m "docs: add Stage 9 for site password rules and per-entry URI match modes"
```

---

## Self-Review

**Spec coverage (Decisions 6–9).**
- Decision 6 (16th bridge request) — Task 11 adds `generatePassword`/`generatedPassword`
  to every exhaustive switch the spec enumerates (`encode(to:)` and `init(from:)` on both
  enums, `isAnswerableWhileLocked`, `resetsAutoLockTimer`, `response(for:)`,
  `requestWasServed(_:)`, `LoopbackServer`'s token-extraction switch), places
  `generatePassword` in the `false` arm of `isAnswerableWhileLocked` and the `true` arm of
  `resetsAutoLockTimer` exactly as the spec directs, and names the `.error(String)` case
  as the shape an `.unsatisfiableRules` failure surfaces through. `background.js`'s
  `knownTypes` and `ChromeHost/Relay.swift`'s no-op status are both addressed (Task 13
  Step 3; Relay needs no plan step at all, matching the spec's own "verified to need no
  change" finding).
- Decision 7 (extension surfaces for generation) — Task 12 implements the `isNewPassword`
  classifier (`autocomplete=new-password` primary, confirm-password-shape fallback,
  exact property name `isNewPassword` as the shared contract requires). Task 13 wires the
  inline panel's generate action (gated on `isNewPassword` and `event.isTrusted`, filling
  via `setNativeValue` scoped to the sending document) and the popup's generate action
  (gated on the content script reporting a new-password field, exactly to avoid the
  secret-in-clipboard state the spec calls out as the reason for that gate), plus the
  `knownTypes` allowlist entry the spec flags as the one silently-broken-at-runtime spot.
- Decision 8 (per-entry URI match mode) — Task 8 adds `URIMatchMode` with the spec's exact
  kebab-case raw values and `CaseIterable` conformance, stores it as the hidden
  `MyPass.URIMatchMode` field via the same `standardFieldKeys` mechanism the
  `KPEX_PASSKEY_*` fields already use, and defaults absent/unrecognised values to
  `.registrableDomain` with no migration step — proved by a real KDBX save/reload cycle,
  not just an in-memory getter/setter test. Task 10 adds the picker with per-mode help
  text, including the disclosed starts-with prefix trade-off and the never-mode
  app-vs-extension distinction, and documents (rather than re-implements) why no
  template-gating code is needed.
- Decision 9 (matching semantics per mode) — Task 9 implements all five modes with the
  precise normalisation rules given (host mode: whole host + port, case-insensitive, no
  PSL reduction; starts-with/exact: lowercase scheme + host, drop the scheme's own
  default port, preserve path/query case exactly), the empty-URL-matches-nothing rule for
  every mode (achieved for free by `entry.urls`'s existing empty-string handling and the
  normalisation helpers' own empty-input guards, each proved by a dedicated loop test
  rather than asserted by inspection), the documented starts-with prefix trade-off
  (`.../app` matching `.../app-legacy`), and never-mode exclusion enforced inside
  `ExtensionEntryMatcher.matchingEntries` itself — proved once at the matcher level (one
  test per mode) and once more at the actual wire boundary via a dedicated
  `ExtensionBridgeServiceTests` test, exactly as the task instructions required.

**Placeholder scan.** No step in Tasks 8–14 contains "TBD", "add error handling", "similar
to Task N", or a description standing in for code. Every code block is a complete,
paste-able diff or a complete new file. The one place this plan deliberately narrows scope
relative to the spec's own prose — Decision 7's "absence of a matching saved credential"
as a *third* new-password signal — is called out explicitly in the task text itself as
out of scope for Task 12's two stated signals (`autocomplete=new-password` and the
confirm-password shape), not silently dropped.

**Type consistency across tasks.** `URIMatchMode` (Task 8) is consumed with identical case
names and raw values in Task 9 (`ExtensionEntryMatcher`), Task 10 (`EntryEditView`'s
picker and display-string extension), and referenced by name only (never redefined) in
both. `KdbxEntry.uriMatchMode`/`uriMatchModeFieldKey` (Task 8) are used, never redeclared,
in Tasks 9 and 10. `ExtensionBridgeRequest.generatePassword`/
`ExtensionBridgeResponse.generatedPassword` (Task 11) are referenced by their exact
associated-value shapes (`token: String, domain: String, pairing: String?` /
`password: String`) everywhere they appear, including the wire-format JSON keys
(`type`, `token`, `domain`, `pairing`, `password`) used identically in the Swift codec
tests (Task 11) and the JS-side messages (Task 13: `{ type: 'generatePassword', domain }`
sent from both `content.js` and `popup.js`, matching the "Extension runtime message
shape" the shared contract specifies verbatim). `isNewPassword` (Task 12) is produced by
`findFillableFields` and consumed under that exact property name in Task 13's
`attachIcons`/`attachIconTo`/`togglePanel` threading and in the new
`buildNewPasswordFieldQueryResponse`, with no renaming anywhere. `PasswordGeneratorDefaults.load()`,
`PasswordRulesCatalog.rules(forHost:)`, and `PasswordGenerator.generate(options:rules:)`
(all shared-contract, Tasks 1–7) are called in Task 11 with exactly the signatures given,
with no redefinition attempted in this half of the plan.

**Deliberate deviation from the plan's usual step shape.** Task 10 has no failing-test
step, because this repository has no SwiftUI view-rendering test harness (confirmed
against every file listed under `MyPass/UI/EntryDetail/` in `MyPassTests/` — each tests
extracted pure logic, never a `View`'s own body). A compile-and-build check
(`./scripts/generate.sh` + `./scripts/build-all.sh`) substitutes for a red/green test
cycle there; this is recorded as a conscious choice rather than a skipped step.
