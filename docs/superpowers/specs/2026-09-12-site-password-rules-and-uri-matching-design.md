# Site-Aware Password Rules and Per-Entry URI Match Modes

**Date:** 2026-09-12
**Status:** Proposed

## Goal

Two related, fully offline capabilities:

1. MyPass generates passwords that the target site will actually accept, by honouring Apple's per-site Password Rules data (`quirks/password-rules.json` from `apple/password-manager-resources`), both in the app's own generator and through the browser extension.
2. A vault entry can declare *how* its URL is matched against a page, replacing the single registrable-domain rule `ExtensionEntryMatcher` uses today with a per-entry choice of five explicit modes.

Both capabilities ship with no new network access at runtime: the password-rules data is vendored into the app bundle exactly as the Public Suffix List already is, and match-mode selection is pure local logic over data already in the vault.

## Context — the problem, with evidence

**The generator knows nothing about sites.** `Packages/MyPassKit/Sources/MyPassKit/PasswordGenerator/PasswordGenerator.swift` defines:

```swift
public struct PasswordGeneratorOptions {
    public var length: Int
    public var includeLowercase: Bool
    public var includeUppercase: Bool
    public var includeDigits: Bool
    public var includeSymbols: Bool
    ...
}

public enum PasswordGeneratorError: Error, Equatable {
    case noCharacterClassSelected
    case secureRandomUnavailable
}

public enum PasswordGenerator {
    ...
    public static func generate(options: PasswordGeneratorOptions) throws -> String { ... }
}
```

Generation builds a flat character pool from the four toggles, rejects biased bytes drawn via `SecRandomCopyBytes` (`let limit = UInt8(256 - (256 % pool.count))`), and picks `options.length` characters uniformly at random. There is no length ceiling, no "must include at least one digit" enforcement, no forbidden-character handling, and no way to express "at most 3 identical characters in a row." Any site with a maximum length, a mandatory-character-class rule, or a repeated-character cap can silently reject a MyPass-generated password, and the user only discovers this at the site's own sign-up form, disconnected from the moment MyPass generated the secret.

`MyPass/UI/PasswordGenerator/PasswordGeneratorView.swift` confirms there is also no persistence: `length`, `includeLowercase`, `includeUppercase`, `includeDigits`, and `includeSymbols` are plain `@State` properties on the view, defaulting to `16` and `true` for all four classes every time the view is created, with no `UserDefaults` read or write anywhere in the file. Every generator invocation today starts from that same hard-coded default.

**The matcher knows exactly one mode.** `MyPass/State/ExtensionBridge/ExtensionEntryMatcher.swift` implements:

```swift
static func registrableDomain(from urlString: String) -> String? { ... }
static func matchingEntries(in group: KdbxGroup, forURL urlString: String) -> [KdbxEntry] {
    guard let targetDomain = registrableDomain(from: urlString) else { return [] }
    return EntrySearch.allEntries(in: group).filter { entry in
        entry.urls.contains { registrableDomain(from: $0) == targetDomain }
    }
}
```

Every entry, unconditionally, is compared to the page by reducing both to a registrable domain via `MyPassKit.PublicSuffixList` and testing equality. This is the right default and it is already careful — it special-cases IPv4/IPv6 literals and hosts that are themselves a public suffix so they compare whole rather than collapsing to two labels (see the long comment block above `registrableDomain(from:)`). But it offers no way to say "this login only ever lives at this one exact host," "match anything under this URL prefix" (a multi-tenant SaaS path, say), or "never offer this entry to the extension at all" (a legacy credential kept for the app UI's own audit trail, never for autofill). Today the only way to get any of that behaviour is to not give the entry a URL, which also removes it from the app's own domain-based search convenience.

**Source of the password-rules data.** `https://github.com/apple/password-manager-resources`, file `quirks/password-rules.json`: 436 domain keys, roughly 64 KB, MIT-licensed, copyright Apple Inc. 2020–2026, and the upstream README explicitly invites password managers to incorporate the data; vendoring is permitted provided the copyright notice and licence text are retained. The canonical grammar is documented at `https://developer.apple.com/password-rules/`, and the same repository ships a reference parser at `tools/PasswordRulesParser/PasswordRulesParser.js` together with a parser test suite — the natural source for this project's own parser fixtures.

## Decisions

### Decision 1 — Vendor the Apple password rules data as a bundled resource

Commit a snapshot of `quirks/password-rules.json` at `Packages/MyPassKit/Sources/MyPassKit/Resources/password-rules.json`, next to the existing `Resources/public_suffix_list.dat`, and declare it in `Package.swift` the same way:

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
)
```

`PublicSuffixList` already establishes the loading pattern this follows exactly: `Bundle.module.url(forResource:withExtension:)`, read once, `fatalError` if the resource is missing or unreadable rather than silently degrading to an empty rule set (`PublicSuffixList.swift`'s own comment explains why: an empty PSL fallback would reintroduce the "co.uk over-matches co.uk" bug the type exists to prevent; an empty password-rules fallback would just as silently degrade every generated password back to "no site constraints," which is exactly the failure this feature exists to close). `PasswordRulesCatalog` (Decision 3) loads `password-rules.json` the same way, at first use, and treats a missing or unreadable resource as a build/packaging bug rather than a recoverable runtime condition.

**Attribution convention.** This repository already has two different vendoring conventions in play, and `password-rules.json` needs the one that actually fits its format:

- `public_suffix_list.dat` is self-documenting: the file itself opens with the upstream MPL-2.0 licence header and `VERSION`/`COMMIT` comment lines (`// VERSION: 2026-08-19_19-18-48_UTC`, `// COMMIT: e8c9a2b2...`), because the `.dat` format is line-comment-friendly and publicsuffix.org's own export already carries this header. No separate vendoring note exists for it, because none is needed.
- `Packages/MyPassKit/Sources/CArgon2/VENDORING.md` is the convention for a vendored *C source tree*, where the many individual files can't each carry a full licence block: one Markdown file states the upstream URL, the exact commit, which files were taken and which were deliberately left out, and reproduces the full licence text verbatim.
- `ChromeExtension/vendor/jsQR.js` uses a third, minimal convention because it is a single already-built JS file: one header comment line, `/* jsQR v1.4.0 — (c) Cosmo Wolfe, Apache License 2.0 — https://github.com/cozmo/jsQR */`.

`password-rules.json` is JSON, which has no comment syntax at all, so the `public_suffix_list.dat` approach (embed the header in the file) is not available. It follows the `CArgon2/VENDORING.md` convention instead: a sibling provenance file, `Packages/MyPassKit/Sources/MyPassKit/Resources/PASSWORD_RULES_PROVENANCE.md`, recording:

- Upstream URL: `https://github.com/apple/password-manager-resources`
- Vendored file: `quirks/password-rules.json`
- Pinned upstream commit SHA (recorded at vendoring time, not "latest")
- Retrieval date
- Entry count at that commit (436, matching the count above)
- The MIT licence text, copied verbatim from upstream's `LICENSE` file, with Apple's copyright notice intact

This file is excluded from the `MyPassKit` target's build inputs via `exclude:` in `Package.swift` (shown above) — it is documentation, not a resource the app needs to load, exactly as `CArgon2`'s own target excludes its `VENDORING.md` (`exclude: ["VENDORING.md"]`) for the identical reason.

**Staleness is visible by construction**, not by discipline alone: `scripts/update-password-rules.sh` re-fetches `quirks/password-rules.json` from the pinned upstream repository, overwrites `Resources/password-rules.json`, and rewrites `PASSWORD_RULES_PROVENANCE.md` with the new commit SHA, retrieval date, and entry count in the same run, so the data file and its provenance record can never independently drift out of sync. It follows the repository's established shell-script shape (`set -euo pipefail`, resolves the repo root itself, preflight-checks `curl`/`git`/`jq` before doing anything) — the same shape as every script under `scripts/`.

No code path reads `password-rules.json` from anywhere but the compiled bundle; the update script runs only as a manual, deliberate maintenance step, never at app launch or in a build phase.

### Decision 2 — A Swift parser for the Password Rules grammar

New `PasswordRulesParser` in `Packages/MyPassKit/Sources/MyPassKit/PasswordRules/`, producing a `PasswordRules` value type:

```swift
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

    /// Each inner array is one `required:` clause — its members are ORed.
    /// The outer array is the AND of every `required:` clause present.
    public var requiredClauses: [[CharacterClass]]
    /// The cumulative `allowed:` set, with every class named by any
    /// `requiredClauses` member already folded in.
    public var allowedClasses: [CharacterClass]
    public var minLength: Int?
    public var maxLength: Int?
    public var maxConsecutive: Int?
    /// Parsed and stored, never enforced — see the note below.
    public var maxRepeating: Int?
    /// Parsed and stored, never enforced — see the note below.
    public var maxSequential: Int?
}

public enum PasswordRulesParseError: Error, Equatable {
    case emptyInput
    case unknownProperty(String)
    case malformedValue(property: String, value: String)
    case unterminatedCustomClass
}

public enum PasswordRulesParser {
    public static func parse(_ raw: String) -> Result<PasswordRules, PasswordRulesParseError>
}
```

**Grammar**, matching `https://developer.apple.com/password-rules/` and the reference `PasswordRulesParser.js`: properties separated by `;`, each `name: values`, values separated by `,`. Recognized property names: `required`, `allowed`, `max-consecutive`, `max-repeating`, `max-sequential`, `minlength`, `maxlength`. Named character classes: `upper`, `lower`, `digit`, `special`, `ascii-printable`, `unicode`. A custom class is a bracketed literal set, e.g. `[!@#]`.

**Semantics**, matching the reference parser exactly rather than a plausible-looking approximation:

- Multiple `required:` clauses are **ANDed** — every one of them must be satisfiable.
- Comma-separated classes inside a single `required:` clause are **ORed** — satisfying any one member of that clause satisfies the clause.
- `allowed:` clauses are **cumulative** — every class named by any `allowed:` property in the rule is added to the effective allowed set, not just the last one seen.
- Every class named anywhere in `requiredClauses` is folded into the effective allowed set — a required class is, definitionally, also allowed.
- Conflicting numeric properties resolve to the **minimum** for `max-consecutive` and `maxlength`, and the **maximum** for `minlength` — the more restrictive bound wins in each case, matching the reference parser's own conflict resolution.
- If no `allowed:` classes are specified anywhere in the rule, the effective allowed set defaults to `ascii-printable`.

**`max-repeating` and `max-sequential` are parsed and stored on `PasswordRules`, but the generator (Decision 4) enforces `max-consecutive` only.** This is a deliberate, documented limitation, not an oversight: across all 436 rules in the vendored snapshot, zero entries set `max-repeating` or `max-sequential`. Writing enforcement code for a constraint no shipped rule ever exercises would be untested code sitting in the single most security-relevant code path in the app — the exact "self-rolled, unscrutinized logic" risk this codebase already refuses to take in `KeyDerivation.swift` (see `docs/superpowers/specs/2026-09-12-kdbx4-argon2-interop-design.md`, Decision 1). If a future snapshot refresh (via `scripts/update-password-rules.sh`) introduces a rule using either property, that is the trigger to add enforcement and its own known-answer tests — not something to build speculatively now.

**Parse errors are typed and never crash.** `PasswordRulesParser.parse` returns `Result`, never `fatalError`s or force-unwraps on malformed input. `PasswordRulesCatalog` (Decision 3) treats a parse failure for a given domain identically to that domain having no rule at all — the generator falls back to the user's plain toggles, which is strictly safer than refusing to generate a password because one upstream data row was malformed.

### Decision 3 — Rule lookup keyed by host

New `PasswordRulesCatalog`:

```swift
public enum PasswordRulesCatalog {
    /// Nil when no rule applies — the caller falls back to plain generator options.
    public static func rules(forHost host: String) -> PasswordRules?
}
```

Lookup walks upward from the full host — `login.accounts.example.com` → `accounts.example.com` → `example.com` — checking each level against the catalog's keys, and stops at the registrable domain computed via the existing `MyPassKit.PublicSuffixList` (the same type `ExtensionEntryMatcher` already depends on for domain reduction). It never walks above the registrable domain, so `example.com`'s rule is never mistakenly applied to an unrelated site that happens to share a public suffix. A rule keyed at any level matches every subdomain underneath it down to (and including) the exact host, unless the schema's `exact-domain-match-only` boolean is set on that entry, in which case only the exact key matches — honoured even though no rule in the current 436-entry snapshot sets it, because the schema supports it and a future refresh may add one.

Parsing is lazy: `PasswordRulesCatalog` loads and indexes the raw JSON once, on first use, and caches each domain's *parsed* `PasswordRules` after its first successful parse, so a hot path (the extension asking for a password on every popup open) does not re-run the grammar parser on every lookup.

### Decision 4 — The generator honours rules

`PasswordGenerator.generate` gains an optional `rules` parameter; existing callers with no site context are unaffected:

```swift
public static func generate(options: PasswordGeneratorOptions, rules: PasswordRules? = nil) throws -> String
```

**Effective character pool.** When `rules` is provided, the pool is the intersection of the rule's effective allowed classes with the user's enabled toggles (`includeLowercase`/`includeUppercase`/`includeDigits`/`includeSymbols`), **except** that any class named in `rules.requiredClauses` is forced into the pool regardless of the user's toggles — a site that mandates a digit gets one even if the user turned digits off. A `.custom([...])` required class contributes its literal characters directly to the pool, independent of MyPass's own four baseline character sets (`lowercase`, `uppercase`, `digits`, `symbols` as currently defined in `PasswordGenerator.swift`) — a site's bespoke required symbol set is not filtered through MyPass's own 25-character `symbols` pool (`"!@#$%^&*()-_=+[]{};:,.<>?"`), because Apple's `special` class and this app's `symbols` pool are not the same set, and a required literal character must be usable even if it happens to fall outside MyPass's own baseline choices.

**Length clamping.** The requested `options.length` is clamped into `[rules.minLength ?? options.length, rules.maxLength ?? options.length]` before generation begins, so a 20-character request against a site with `maxlength: 12` produces a 12-character password rather than one the site will reject outright.

**Post-generation verification and repair.** After a candidate is drawn, it is checked against every required clause and against `maxConsecutive`. On failure, the generator regenerates from scratch, up to 100 attempts. If 100 attempts all fail — realistic only for a pathologically tight rule — it falls back to deterministic construction: place one character satisfying each required clause first, fill the remaining length from the effective pool, shuffle the whole result with an unbiased Fisher-Yates shuffle (driven by the same rejection-sampled `SecRandomCopyBytes` source `PasswordGenerator` already uses for character selection, so the shuffle carries the identical no-modulo-bias guarantee), then repair any remaining `max-consecutive` violation by resampling just the offending run's characters rather than starting over. All randomness — pool selection and the shuffle alike — continues to come from `SecRandomCopyBytes` with rejection sampling; the existing `secureRandomByte(below:)` helper's rejection-sampling technique is reused for the shuffle's index draws, not reimplemented.

**Unsatisfiable rules get a typed error**, a new case on the existing error enum:

```swift
public enum PasswordGeneratorError: Error, Equatable {
    case noCharacterClassSelected
    case secureRandomUnavailable
    case unsatisfiableRules
}
```

`.unsatisfiableRules` covers, for example, a `maxlength` smaller than the number of distinct mandatory clauses, or required classes whose combined character sets have no room left after `maxlength` clamping. This is a caller-visible, typed failure rather than an infinite loop or a password that silently violates the site's own rule.

### Decision 5 — Generator UI surfaces the active rule

`PasswordGeneratorView` (`MyPass/UI/PasswordGenerator/PasswordGeneratorView.swift`) gains:

- A label naming which domain's rule is in effect (when one is), and a popover explaining the constraint in plain English (e.g. "example.com requires a digit, a symbol, and at most 3 repeated characters in a row, max length 24") rather than surfacing the raw grammar string.
- A control to ignore the active rule and fall back to plain toggle-driven generation.
- While a rule is active and not overridden: the length `Slider` is constrained to `rules.minLength...rules.maxLength` (clamped against the view's existing `8...64` bounds), toggles for classes the rule requires are shown locked on, and toggles for classes the rule's effective allowed set excludes are shown locked off.

**Domain source.** When the generator is opened from an entry's edit screen, the domain comes from that entry's `URL` field (reduced via the same `ExtensionEntryMatcher.registrableDomain(from:)` / `PublicSuffixList` machinery used everywhere else in the app, so "which rule applies" is computed identically no matter which surface asks). The standalone generator (opened with no entry context) gains an optional free-text site field so a rule can still be looked up without an entry to anchor it.

### Decision 6 — A 16th bridge request so the extension can generate site-aware passwords

Add a case to the 15-case request enum in `Packages/ExtensionBridgeKit/Sources/ExtensionBridgeKit/ExtensionBridgeMessages.swift`:

```swift
case generatePassword(token: String, domain: String, pairing: String?)
```

and a matching response case:

```swift
case generatedPassword(password: String)
```

carrying the same per-launch `token` and optional `pairing` token every other request already carries, encoded/decoded via the same hand-written `Codable` conformance (a `"generatePassword"` string in `CodingKeys.type`, `domain` reusing a new `CodingKeys` case since no existing key fits, `token`/`pairing` reusing the existing keys).

**Every exhaustive switch over the enum must gain the new case explicitly** — this codebase deliberately has no `default:` arm on any switch over `ExtensionBridgeRequest` or `ExtensionBridgeResponse`, specifically so a new case forces a conscious decision at every call site rather than silently inheriting whatever the `default` branch happened to do. The sites, verified directly in the source:

- `Packages/ExtensionBridgeKit/Sources/ExtensionBridgeKit/ExtensionBridgeMessages.swift`:
  - `encode(to:)`'s `switch self` over all 15 request cases (exhaustive, no `default`) — needs an `encode` branch for `.generatePassword`.
  - `init(from:)`'s `switch type` (a `switch` over the decoded `String`, which already carries a `default:` that throws `DecodingError.dataCorruptedError` for an unknown type) — needs a `case "generatePassword":` decode branch added before that `default`, or the wire format is simply unreadable even though the Swift compiler would not flag the omission.
  - `isAnswerableWhileLocked` (exhaustive `switch self`, no `default`) — see below for the decision this case gets.
  - `resetsAutoLockTimer` (exhaustive `switch self`, no `default`) — see below.
  - The equivalent `switch self` in `ExtensionBridgeResponse`'s `encode(to:)` and the `switch type` in its `init(from:)` need the matching `.generatedPassword` branches for the response side.
- `MyPass/State/ExtensionBridge/ExtensionBridgeService.swift`:
  - `response(for request: ExtensionBridgeRequest) -> ExtensionBridgeResponse`'s `switch request` (exhaustive, one case arm per request, no `default`) — needs the actual handling logic for `.generatePassword`.
  - `requestWasServed(_ response: ExtensionBridgeResponse) -> Bool`'s `switch response` (exhaustive, no `default`) — needs to classify `.generatedPassword` as "served" (`true`), alongside the existing successful cases (`.credentialList`, `.credential`, `.totp`, etc.).
- `MyPass/State/ExtensionBridge/LoopbackServer.swift`:
  - The token-extraction `switch request` at line 186 (`case .getCredentials(let token, _, _): return token`, one arm per case, no `default`) — needs `case .generatePassword(let token, _, _): return token`.

Two places are verified to need **no** change:

- `ChromeHost/Relay.swift` performs no per-message-type dispatch at all — its only `switch` is over its own connection `state` (`.ready`/`.failed`/`.cancelled`/`.waiting`), unrelated to the bridge protocol. The host relays native-messaging bytes to the TCP loopback and back as an opaque byte stream; a new request type requires no host-side code change, only that the new JSON shape round-trips, which it does automatically.
- `ChromeExtension/background.js` has no *exhaustive switch* (JavaScript enforces nothing here), but it does gate every outbound message through an explicit allowlist, `const knownTypes = [...]` (currently 12 entries: `getCredentials`, `fillCredential`, `getTotp`, `proposeSaveLogin`, `proposeSaveTotp`, `startPairing`, `completePairing`, `requestUnlock`, `getPasskeyProxyStatus`, `setPasskeyProxyEnabled`, `passkeyCreateConfirm`, `passkeyGetApprove`) checked in `handleRuntimeMessage` (`if (!message || !knownTypes.includes(message.type)) { return false; }`). `"generatePassword"` must be added to this array or the popup's/content script's request is silently dropped before it ever reaches `sendNativeMessageWithPairing`.

**Auto-lock participation.** `generatePassword` is added to the `true` arm of `resetsAutoLockTimer`, grouped with the other popup-button-click-gated requests (`fillCredential`, `getTotp`, `proposeSaveLogin`, `proposeSaveTotp`, `passkeyCreateConfirm`, `passkeyGetApprove`, `requestUnlock`) — it is only ever issued from behind a trusted user gesture (a "Generate password" button click), exactly like `fillCredential`, never on a page's own timing the way `getCredentials`/`passkeyCreate`/`passkeyGet` can be.

**Lock gating.** `generatePassword` is *not* added to `isAnswerableWhileLocked`; it is served only while the vault is unlocked, returning `.locked` exactly like every other non-exempted request. This is a deliberate trade-off worth recording rather than an oversight: generating a password from site rules and user preferences needs no vault data at all — the rules come from the bundled catalog and the preferences from persisted defaults (introduced later in this decision), neither of which lives behind the vault key. Answering it while locked would work mechanically and would save the user one unlock prompt. But `isAnswerableWhileLocked` currently has exactly two members — `requestUnlock` (needs to work precisely because the vault is locked) and `getPasskeyProxyStatus` (reports lock state itself, so answering it with a blanket `.locked` would be self-defeating) — and the type's own doc comment says plainly: "Keep this list as short as the spec allows." Adding a third, functionally unrelated exemption opens a second "serviceable while locked" code path in a protocol where every other one of fifteen (soon sixteen) cases requires unlock, and every future reviewer of `isAnswerableWhileLocked` has to re-derive why this one case is safe to serve without vault access. The audit cost of a permanent, protocol-wide exception outweighs saving the user a single unlock tap on an action they take rarely enough (registering a new account) that the friction is negligible.

**Preferences.** Generation uses the user's persisted generator defaults (below) overlaid with `PasswordRulesCatalog.rules(forHost: domain)` exactly as Decision 4 describes. Since `PasswordGeneratorView.swift` was verified above to persist nothing today (`length`/four booleans are transient `@State`), this work introduces the first persisted generator defaults, stored in `UserDefaults.standard` under keys in the `MyPass.PasswordGenerator.` namespace (matching the `MyPass.`-prefixed custom-field key convention already used elsewhere in this codebase, e.g. `MyPass.CVV`, `MyPass.NotesBody`, in `MyPass/Models/KdbxEntry+Convenience.swift`):

| Key | Default |
|---|---|
| `MyPass.PasswordGenerator.length` | `20` |
| `MyPass.PasswordGenerator.includeLowercase` | `true` |
| `MyPass.PasswordGenerator.includeUppercase` | `true` |
| `MyPass.PasswordGenerator.includeDigits` | `true` |
| `MyPass.PasswordGenerator.includeSymbols` | `true` |

These defaults are shared by `PasswordGeneratorView`'s own "Generate" button and by the `generatePassword` bridge handler — one persisted source of truth, so a preference changed in the app's generator UI is what the extension uses on its very next password generation, with no separate settings surface to keep in sync.

### Decision 7 — Extension surfaces for generation

**Inline fill panel** (`ChromeExtension/content.js`). `findFillableFields` currently classifies every visible `input[type="password"]` uniformly as `kind: 'password'` — it does not distinguish a signup/new-password field from a login form's current-password field; there is no `autocomplete="new-password"` check anywhere in the file today (`grep` for `new-password`/`current-password` in `content.js` returns nothing). This classifier needs extending: a password field is offered "Generate password" only when it is judged to be a *new*-password field, which this work defines primarily via `autocomplete="new-password"` (a decisive, purpose-built browser signal, exactly the same trust level `content.js` already gives `autocomplete="one-time-code"` in `scoreOtpLikeness`) falling back to a heuristic (a second, adjacent password field — the "confirm password" pattern — or absence of a matching saved credential for the page) when the attribute is missing, since not every signup form sets it correctly. A field not classified as new-password gets the existing fill-only icon behaviour, unchanged.

**Popup.** The popup (`ChromeExtension/popup.js`) offers generation only when the active tab is judged to have a new-password field — via the same classification `content.js` performs, queried the way `queryTotpCandidate` already asks the content script for page state today. This restriction exists for a concrete reason, not merely as a simplification: if the popup could generate a password with no target field to place it into, the only place to put the freshly generated secret would be the system clipboard — and the extension has no way to invoke the app's own `ClipboardAutoClear` mechanism (`MyPass/UI/PasswordGenerator/PasswordGeneratorView.swift` schedules `ClipboardAutoClear.schedule(...)` in-process, entirely inside the app; the extension has no bridge call that does the equivalent, and adding one is out of scope here). A generated secret with no auto-clear path would sit in the clipboard indefinitely, available to anything else running on the machine, for as long as the user forgets to overwrite it. Restricting popup-driven generation to "there is a field to fill it into directly" avoids ever creating that secret-in-clipboard state in the first place.

**Trust gating.** Both the inline "Generate password" action and the popup's generation action are gated on `event.isTrusted`, consistent with every other inline-icon action in `content.js` (`trustedClickHandler`) — a page script cannot synthesize the click that triggers generation, for the same reason it cannot synthesize a fill click today.

**Filling and saving.** Filling the generated value reuses the existing fill path (`setNativeValue`/`applyFill`), scoped to the sending document exactly as every other fill already is — no new fill mechanism is introduced. Saving the newly generated credential needs no new work at all: the existing save-login proposal banner (`showSaveBanner` in `content.js`, wired to `proposeSaveLogin` and triggered on form submit when `state.lastCredentialList.length === 0`) already captures username and password on submit regardless of whether the password was typed or generated — from the banner's point of view a generated password is indistinguishable from a typed one.

### Decision 8 — Per-entry URI match mode

New enum in `MyPassKit`:

```swift
public enum URIMatchMode: String, CaseIterable, Hashable {
    case registrableDomain = "registrable-domain"
    case host = "host"
    case startsWith = "starts-with"
    case exact = "exact"
    case never = "never"
}
```

Raw values are kebab-case for the multi-word cases (`registrable-domain`, `starts-with`), matching the lowercase-hyphenated style the Password Rules grammar itself uses for its own multi-word property names (`max-consecutive`, `ascii-printable`) — one convention for "a machine-readable multi-word token" across this codebase's newly-introduced string constants, rather than inventing a second casing style in the same spec. `CaseIterable` is what lets the entry edit form's picker enumerate the modes without a second hand-maintained list that could drift out of sync with the enum.

**Regular-expression matching was considered and deliberately rejected** — recorded here as a decision with its reasoning, not filed away as a mere non-goal, because it was seriously discussed and the reason it lost matters: the user authors the match pattern, but the *page* controls the string being matched against it (the URL the browser navigated to). A hostile or merely malformed page can choose a URL engineered to trigger catastrophic backtracking against an otherwise-innocent user-authored regular expression, and `NSRegularExpression` — Foundation's only regex engine available here — offers no API to abort a match already in progress. The only mitigations available would be a length cap on the input plus a watchdog timer that gives up and returns *some* answer while the runaway matching work keeps burning a thread underneath it, unkillable, for as long as the page's chosen string keeps it busy. That is a real, standing liability sitting in the same request-handling path `ExtensionBridgeService` uses for every popup click and every automatic `getCredentials` call from `content.js` — a single crafted URL could stall bridge request handling for every entry, not just the one entry with the offending pattern, since matching for a `getCredentials` request walks every entry in the vault. Weighed against what it would buy — expressive power the five fixed modes below do not need for any use case this spec's brainstorming session actually raised — the feature is not worth that exposure.

**Storage.** One hidden custom field on the `KdbxEntry`, `MyPass.URIMatchMode`, in the same `MyPass.`-prefixed namespace as the app's other custom fields (`MyPass.CVV`, `MyPass.CardNumber`, `MyPass.NotesBody`, etc., all in `MyPass/Models/KdbxEntry+Convenience.swift`). It is hidden from the custom-field UI by the exact mechanism `KPEX_PASSKEY_*` already uses: added to `KdbxEntry.standardFieldKeys`, the `Set<String>` in `MyPass/Models/KdbxEntry+Convenience.swift` documented as "Fields that have a dedicated UI of their own, so they must never be rendered as generic custom-field rows... and must never be dropped on save either" (today built as `Set([...]).union(KdbxEntry.passkeyFieldKeys)`). `MyPass.URIMatchMode` joins that literal `Set([...])` the same way the passkey keys join it via `.union`.

An **absent field means registrable-domain matching** — `URIMatchMode(rawValue: entry.matchModeFieldValue) ?? .registrableDomain`, never a required migration step. Every existing MyPass vault, and every vault written by KeePassXC (which has never heard of this field and never will write it), keeps behaving exactly as it does today: no format change, no migration pass, no version bump to the KDBX4 file itself. This mirrors the same "no migration needed" property Decision 4 of the Argon2 interop spec relies on for KDF parameters — a field genuinely absent from the file, not a field present-with-a-default, is what makes an old file behave identically to a new one without MyPass ever touching it.

The entry edit form gains a match-mode picker beside the `URL` field, with per-mode help text explaining what each mode does in the terms Decision 9 defines below.

### Decision 9 — Matching semantics per mode

- **Registrable domain** — unchanged from today's `ExtensionEntryMatcher.registrableDomain(from:)` behaviour in every particular already verified in the source: IP literals (IPv4 and IPv6, bracketed or not) compare whole rather than being reduced; a host that is itself a public suffix (`co.uk`, `github.io`) compares whole rather than being reduced past its own boundary; multi-label public suffixes are resolved correctly via `PublicSuffixList.registrableDomain(of:)`. This mode is, and remains, the default.
- **Host** — whole-host string comparison, including port, case-insensitive. IP literals are compared whole (there is nothing to reduce them to in the first place, so this mode's behaviour for an IP-literal entry coincides with registrable-domain mode's).
- **Starts-with / exact** — both compare a normalised URL string, with normalisation defined precisely so the rule is unambiguous for the single Swift implementation and so anyone reading a stored URL can predict whether it will match: lowercase the scheme and the host; drop the port if it is the scheme's registered default (`80` for `http`, `443` for `https`); leave the path and query exactly as given, including case — a case-sensitive API path is a real, common shape (`/API/v2/Login` versus `/api/v2/login` are frequently different endpoints) and silently folding it would be a correctness regression, not a convenience. **Exact** requires whole-string equality against the normalised target URL. **Starts-with** requires the stored, normalised value to be a literal prefix of the normalised target URL — a plain string comparison, not a path-boundary-aware one, so `https://example.com/app` intentionally also matches `https://example.com/app-legacy`; this is the accepted cost of "no regular expressions" (Decision 8) and is disclosed in the picker's per-mode help text so it is a known, chosen trade-off rather than a discovered surprise.
- **Every mode**: an entry with an empty `URL` matches nothing, full stop — never "matches everything," which would be the dangerous failure mode for a password manager (an empty-URL entry offering itself for autofill on every site visited). This holds even for `starts-with`, where an empty prefix would otherwise trivially match every string.
- **Never** — the entry is excluded from every extension-facing matching surface, enumerated here against what was actually verified in the extension source rather than assumed:
  - The popup's matched credential list (`renderCredentials`/`list-panel` in `ChromeExtension/popup.js`, populated from the `credentialList` response `ExtensionBridgeService.response(for:)` builds via `matchingEntries(forURL:in:)`).
  - The popup's own empty state when nothing matches — verified to be `showPanel('empty')`, rendering the fixed string `EMPTY_LIST_TITLE_TEXT` ("No saved logins for this site"), **not** a broader fallback list of unrelated vault entries; there is no such "show everything" fallback anywhere in `popup.js` today (the file's `popup-fallback.test.js` name refers to the *app-unavailable* retry panel — native host not found — a different condition entirely). A never-mode entry that happens to be the vault's only saved login for a site must still result in this same empty state, not in the entry appearing anyway because "there was nothing else to show."
  - The inline fill icon panel (`findFillableFields`'s consumer in `content.js`, which sources its candidate list from the same `getCredentials` round trip and therefore the same server-side filter).
  - The save banner's decision of whether a login already exists for this site (`state.lastCredentialList` in `content.js`, populated from the identical `getCredentials` call `attachSubmitListener` consults before deciding to show `showSaveBanner` at all). A never-mode entry must be invisible here too, for the same reason it is invisible everywhere else: if it silently kept the save banner from ever appearing (by counting as "an existing match") while never being offered as something to update or reuse, the user would be stuck with no discoverable way to save a new login for that site through the extension — the entry has to behave, from the banner's point of view, as if it does not exist at all, so a genuinely new login for that site still gets offered a save banner.

  The entry stays fully visible and fully usable inside the MyPass app itself in every mode — never mode is an extension-surface exclusion, not a vault-wide visibility flag, and it is not a security boundary against another user of the same vault, only against the browser extension's own autofill surfaces.

  This exclusion is enforced **app-side**, inside `ExtensionEntryMatcher`/`ExtensionBridgeService`, before a `credentialList` (or its equivalent for the inline panel and the save-banner check) is ever assembled and sent across the bridge — never left to the extension to filter out of a list it already received. A bug in `popup.js` or `content.js` therefore cannot resurrect a never-mode entry by forgetting to apply a client-side filter, because the entry was never transmitted across the bridge in the first place; the trust boundary between "vault contents" and "what the (less-trusted, page-adjacent) browser extension is shown" sits on the app side of the wire, consistent with how `passkeyCreateConfirm`'s handling in `ExtensionBridgeService.swift` already re-derives its own candidate set server-side rather than trusting an `entryId` the extension merely echoes back.

## Testing

- **The headline test is a property test over the shipped data.** For every one of the 436 domain rules in the vendored `password-rules.json`, parse it, generate a batch of passwords against it through `PasswordGenerator.generate(options:rules:)`, and assert every generated password satisfies the parsed rule (every required clause, `minLength`/`maxLength`, `maxConsecutive`). This is the test that actually proves the parser and the generator agree with each other and with the real-world data, as opposed to agreeing only with each other's assumptions.
- **Parser tests** driven by fixtures derived from Apple's own `tools/PasswordRulesParser` test cases, covering: the AND-across-clauses / OR-within-a-clause distinction, custom bracketed classes, conflicting numeric properties (asserting the documented min/max resolution), and malformed input (asserting a typed `PasswordRulesParseError`, never a crash).
- **Catalog tests**: the subdomain walk (`login.accounts.example.com` finding a rule keyed at `example.com`), the registrable-domain ceiling (a rule must never apply above the registrable domain even if a key superficially looks like it should), `exact-domain-match-only` honoured when set, and an unknown host correctly returning `nil`.
- **Generator tests**: length clamping against `minLength`/`maxLength`, a rule-required class overriding a user's toggle that turned that class off, `max-consecutive` repair actually firing and producing a compliant result, and `.unsatisfiableRules` thrown for a genuinely impossible combination (e.g. `maxlength` smaller than the number of distinct required clauses).
- **Matcher tests** for each of the five `URIMatchMode` cases, including the empty-URL-matches-nothing case for every mode and the IP-literal case for both `registrableDomain` and `host` modes.
- **A dedicated test that a `never`-mode entry is absent from every surface enumerated in Decision 9** — not just the primary matched list, but the empty-state path, the inline-panel candidate list, and the save-banner's existing-login check, each exercised independently so a regression in one surface cannot hide behind the other three still passing.
- **A KDBX round-trip test** proving `MyPass.URIMatchMode` survives a save-then-reload cycle intact, and proving separately that a vault file with no such field (a fresh KeePassXC-authored fixture, or any pre-existing MyPass fixture) loads as `registrableDomain` — the same "old files behave identically" guarantee this codebase already demands of format changes (see the Argon2 interop spec's Decision 4, where old vaults upgrade themselves silently on next save with no migration code).
- **Node tests in `ChromeExtension/tests/`**, following the plain-node-script convention every one of the 15 existing files there already uses (`node ChromeExtension/tests/*.test.js`, no test framework, `assert` from `node:assert`): one exercising the new `generatePassword` message end-to-end through `background.js`'s `knownTypes` gate and `handleRuntimeMessage`, and one proving a never-mode entry cannot appear in `popup.js`'s rendered list even when it is the only entry the mock native host would otherwise return — mirroring the fixture style already used in `popup-fallback.test.js`.
- The full suite is run through `./scripts/test.sh` — `xcodebuild test -scheme MyPass`, then `swift test` in each of the three `Packages/*` directories, then the 15 (soon 17) standalone node scripts. There is no CI in this repository, so this must be run locally, in full, before any of this work is called done — matching this repository's standing rule (`AGENTS.md`, "Not valid reasons to skip a dispatch": *"A hook will catch me if I'm wrong" — A hook is a safety net, not a steering wheel*, and the top-level *"No CI. Nothing runs the tests for you."*).

## Non-goals and out of scope

- **Apple's other seven `password-manager-resources` data files** — change-password URLs, shared credential backends, the app-identifier map, browser distribution data, and the two special-case site lists. Only `quirks/password-rules.json` is vendored by this work.
- **Breach checking, password health reports, and strength estimation.** Unrelated to either capability this spec covers.
- **Passphrase generation and excluding visually ambiguous characters** (`0`/`O`, `1`/`l`, etc.) from the generator's pool. Real, requested generator features, but independent of site-rule awareness.
- **Multiple URIs per entry.** `URIMatchMode` applies to the entry's existing single `URL` field (plus its `KP2A_URL` extras, which remain untouched by this work); a match mode that varies per-URI on a multi-URI entry is a larger data-model change than adding one hidden field.
- **Bitwarden-style security hardening** — per-entry master-password re-prompt, failed-unlock-attempt lockout, a privacy/blur overlay. Unrelated to matching or generation.
- **Reading a page's own `passwordrules` HTML attribute.** A real alternative signal Apple's own Safari uses, but a separate content-script feature with its own trust and precedence questions (does a page's self-declared rule ever override or merge with the vendored catalog's rule for the same domain?) that this spec does not settle.
- **Any runtime network access.** Both capabilities are, and remain, fully offline; the only network access anywhere in this spec is the manual, developer-run `scripts/update-password-rules.sh`.

## Risks

- **Snapshot staleness.** The vendored `password-rules.json` is a point-in-time copy; if `scripts/update-password-rules.sh` is simply never run again after this work lands, generated passwords silently drift out of date with sites that change their own rules. The provenance file at least makes this auditable (a stale commit SHA and retrieval date are visible on inspection), but nothing currently forces a periodic refresh.
- **Rules no generator configuration can satisfy.** `.unsatisfiableRules` handles this without crashing, but a user who hits it mid-signup gets a dead end rather than a usable password — the UI's error messaging (Decision 5) needs to be clear enough that this reads as "this site's requirements conflict with your current options" rather than as an unexplained app failure.
- **The 16th protocol case touches many exhaustive switches at once**, across `ExtensionBridgeKit` (shared), the app (`ExtensionBridgeService.swift`, `LoopbackServer.swift`), and the extension's own allowlist (`background.js`'s `knownTypes`). Missing any one of the six Swift switch sites enumerated in Decision 6 fails to compile (the whole point of "no `default`"); missing the `knownTypes` addition compiles fine and fails silently at runtime instead, which is the one spot in this list a missed step would not be caught by the Swift compiler.
- **A never-mode entry leaking through a path not enumerated in Decision 9.** The enumeration there was built by reading `popup.js` and `content.js` as they exist today; a bridge feature added later that lists entries by any path other than `matchingEntries(forURL:in:)` needs its own explicit check against never-mode, and nothing in the type system forces that the way the exhaustive-switch convention forces bridge-request handling.
- **The generator's deterministic fallback being weaker than pure rejection sampling if implemented carelessly** — the 100-attempt-then-deterministic-construction path in Decision 4 exists precisely because pure rejection sampling can in principle loop forever against a tight rule; but the deterministic fallback's own shuffle and its `max-consecutive` repair step must themselves stay bias-free, or a small but real class of generated passwords becomes measurably less random than the rest.

## Follow-ups

- The remaining Apple `password-manager-resources` datasets, especially change-password URLs and shared credential backends, as their own separate specs.
- Multiple URIs per entry, and what `URIMatchMode` should mean once an entry can have more than one.
- Persisted generator presets scoped per-entry rather than one global default, once the single global default introduced here (Decision 6) is in use and its limits are felt in practice.
