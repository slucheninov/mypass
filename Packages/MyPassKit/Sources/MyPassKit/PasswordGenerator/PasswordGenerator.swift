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

    /// Plain rejection sampling in `generateHonoringRules`: draw a full
    /// random candidate of the target length and check whether it happens
    /// to satisfy every rule constraint, retrying up to this many times
    /// before falling back to deterministic construction. 100 is generous
    /// for every real rule in the vendored 2026-09-12 snapshot -- most
    /// rules have large enough character pools and loose enough
    /// max-consecutive limits that a satisfying candidate turns up within
    /// a handful of draws. Rules tight enough to defeat honest rejection
    /// sampling routinely (e.g. a 2-character pool with a strict
    /// max-consecutive over a long password, as in
    /// `PasswordGeneratorRulesTests.testMaxConsecutiveIsNeverViolatedAcrossManyGenerations`)
    /// are exactly what the deterministic-construction-and-repair fallback
    /// below exists for, and that fallback now has its own direct tests
    /// (`testRepairMaxConsecutiveFixesARunCreatedByItsOwnEarlierRepair`,
    /// `testDeterministicFallbackConstructsASatisfyingCandidateDirectly`)
    /// proving it reliably, rather than this bound being inflated to
    /// avoid ever exercising it -- an earlier version of this file raised
    /// this to 2000 for exactly that avoidance reason, which just hid a
    /// real bug in the fallback's repair step instead of fixing it.
    private static let maxRejectionSamplingAttempts = 100

    /// Deterministic-construction-with-repair fallback attempts, tried
    /// only once `maxRejectionSamplingAttempts` above is exhausted. See
    /// the doc comment on `generateHonoringRules` for why this bound
    /// cannot be proven sufficient for every possible rule by static
    /// reasoning alone -- if a future conformance run against the real
    /// vendored rule catalog (Task 5) ever exhausts it, the fix is to
    /// raise it further, not to weaken what that gate checks.
    private static let maxDeterministicFallbackAttempts = 10

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
    /// user's own toggles. `internal` (no access modifier) rather than
    /// `private`, the same testability seam used elsewhere in this file,
    /// so `PasswordGeneratorRulesTests` can construct one directly (via
    /// `effectivePool`, also `internal` for the same reason) to pin
    /// `satisfies`'s exclusion check.
    struct EffectivePool {
        let characters: [Character]
        /// The exact set `characters` also holds, kept separately as a
        /// `Set` for O(1) membership tests -- this is "the rule's
        /// effective allowed set" `satisfies` checks every candidate
        /// character against: every character ever added to `membership`
        /// for ANY class (allowed, required, custom, or toggle-backed) is
        /// in here, so a required class counts as allowed (Decision 4:
        /// what a rule requires it also permits) and a rule with no
        /// explicit `allowed:` at all still populates this from the
        /// caller's own toggles (`noExplicitAllowList` in `effectivePool`)
        /// rather than leaving it empty.
        private let allowedCharacters: Set<Character>
        private let membership: [PasswordRules.CharacterClass: Set<Character>]

        init(characters: [Character], membership: [PasswordRules.CharacterClass: Set<Character>]) {
            self.characters = characters
            self.allowedCharacters = Set(characters)
            self.membership = membership
        }

        func characters(for characterClass: PasswordRules.CharacterClass) -> [Character] {
            Array(membership[characterClass] ?? [])
        }

        func contains(_ character: Character, in characterClass: PasswordRules.CharacterClass) -> Bool {
            membership[characterClass]?.contains(character) ?? false
        }

        func isAllowed(_ character: Character) -> Bool {
            allowedCharacters.contains(character)
        }
    }

    /// `PasswordRules.maxRepeating` and `.maxSequential` are parsed and
    /// stored by `PasswordRulesParser` but deliberately NOT enforced here,
    /// unlike `.maxConsecutive` -- `.maxConsecutive` IS enforced, by
    /// `satisfies` below and by `repairMaxConsecutive`, and 82 of the 436
    /// rules in the vendored 2026-09-12 snapshot set it. `maxRepeating`
    /// and `maxSequential` are different: zero of those 436 rules set
    /// either one (see
    /// docs/superpowers/specs/2026-09-12-site-password-rules-and-uri-matching-design.md,
    /// Decision 4). Writing enforcement code for a constraint no shipped
    /// rule ever exercises would be untested code sitting in the single
    /// most security-relevant path in this app -- the same
    /// "self-rolled, unscrutinized logic" risk this codebase already
    /// refuses to take in `KeyDerivation.swift` (see
    /// docs/superpowers/specs/2026-09-12-kdbx4-argon2-interop-design.md,
    /// Decision 1). If a future snapshot refresh
    /// (`scripts/update-password-rules.sh`) ever vendors a rule using
    /// either property, that is the trigger to add enforcement and its
    /// own known-answer tests here -- not something to build
    /// speculatively ahead of a real rule that needs it. This is the doc
    /// comment `PasswordRules.swift` points readers at for that decision.
    private static func generateHonoringRules(options: PasswordGeneratorOptions, rules: PasswordRules) throws -> String {
        // Defensive only -- no rule in the vendored 2026-09-12 snapshot has
        // minlength > maxlength (verified while writing this plan), but a
        // future refresh (scripts/update-password-rules.sh) could vendor
        // one, and an inverted range must never silently produce a
        // negative-length request below. This compares the RULE's own two
        // bounds against each other, and only fires when the rule states
        // BOTH of them -- an earlier version defaulted an absent bound to
        // `options.length` before this comparison, which meant a rule
        // stating only `maxlength` (e.g. bhphotovideo.com's entire rule is
        // `maxlength: 15`) compared the caller's REQUESTED length against
        // the site's maximum instead of the rule's own bounds against each
        // other, and threw `unsatisfiableRules` for a twenty-character
        // request against that fifteen-character maximum -- a rule that is
        // trivially satisfiable by clamping down to fifteen, exactly the
        // shape Decision 4 uses as its worked example of correct behavior.
        if let ruleMin = rules.minLength, let ruleMax = rules.maxLength, ruleMin > ruleMax {
            throw PasswordGeneratorError.unsatisfiableRules
        }
        // Clamp the requested length against whichever bounds the rule
        // actually states, independently: raise it to the rule's minimum
        // if there is one, then lower it to the rule's maximum if there is
        // one. A bound the rule doesn't state applies no constraint at
        // all, rather than silently substituting the caller's own request
        // as a stand-in bound (the bug fixed above).
        var length = options.length
        if let ruleMin = rules.minLength {
            length = Swift.max(length, ruleMin)
        }
        if let ruleMax = rules.maxLength {
            length = Swift.min(length, ruleMax)
        }
        // Defensive and explicit rather than relying on the
        // `length >= rules.requiredClauses.count` guard below to rule out
        // a negative length as an accidental side effect (an `Array`'s
        // `count` is never negative, so that guard happens to forbid a
        // negative length today, but that is a coincidence of a check
        // meant for a different purpose, not a documented invariant). A
        // negative length reaching `0..<length` in `randomString` or the
        // deterministic fallback below would trap, the same class of
        // silent precondition as the `secureRandomIndex` modulus bound.
        guard length >= 0 else {
            throw PasswordGeneratorError.unsatisfiableRules
        }

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
        // satisfied no matter how many attempts are made. Deduplicated
        // through a `Set` before the anchor draw below: a clause naming
        // two classes with overlapping members (e.g. a required custom
        // class that happens to include a digit, alongside `.digit`
        // itself) would otherwise list the shared characters twice,
        // over-weighting them relative to the clause's other members when
        // `randomElement(of:)` picks the one guaranteed-satisfying anchor
        // character for this clause.
        let clauseCharacterSets = try rules.requiredClauses.map { clause -> [Character] in
            let members = Set(clause.flatMap { pool.characters(for: $0) })
            guard !members.isEmpty else {
                throw PasswordGeneratorError.unsatisfiableRules
            }
            return Array(members)
        }

        for _ in 0..<maxRejectionSamplingAttempts {
            let candidate = try randomString(length: length, from: pool.characters)
            if satisfies(candidate, requiredClauses: rules.requiredClauses, pool: pool, maxConsecutive: rules.maxConsecutive) {
                return candidate
            }
        }

        // Rejection sampling didn't converge in maxRejectionSamplingAttempts
        // tries -- realistic only for a pathologically tight rule. Fall
        // back to deterministic construction, re-verifying with `satisfies`
        // before returning either way.
        for _ in 0..<maxDeterministicFallbackAttempts {
            let characters = try deterministicCandidate(
                length: length,
                clauseCharacterSets: clauseCharacterSets,
                pool: pool.characters,
                maxConsecutive: rules.maxConsecutive
            )
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

    /// `internal` (no access modifier) rather than `private` -- see
    /// `EffectivePool`'s doc comment for why.
    static func effectivePool(options: PasswordGeneratorOptions, rules: PasswordRules) throws -> EffectivePool {
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
        // An empty `allowedClasses` never comes out of the parser -- it
        // always defaults to `[.asciiPrintable]` when a rule has no
        // `allowed:` property (see `PasswordRulesParser`) -- but a rule
        // built directly (e.g. one that only constrains length) has no
        // such default, and the pool must not collapse to nothing in that
        // case: "the rule names no allowed classes at all" means "the rule
        // has no opinion here," so the user's own toggles decide, exactly
        // as if there were no rule.
        let noExplicitAllowList = rules.allowedClasses.isEmpty
        // Classes forced in regardless of the user's toggle. This used to be
        // `requiredClassesFlat` alone, which disagreed with the generator UI:
        // the UI also locks ON the single class a restrictive `allowed:`
        // leaves (amundi-ee.com's `allowed: digit`), so the app succeeded
        // with digits toggled off while the extension bridge -- which reads
        // the persisted toggles with no UI to force anything -- threw
        // `noCharacterClassSelected` on the identical rule. See
        // `forcedOnToggleClasses(for:)`, now the single answer both read.
        let forcedOn = forcedOnToggleClasses(for: rules)
        // "Is this class in play at all," used below to decide which members
        // of an `allowed:`-only custom class the user has actually asked for.
        var toggleInPlay: [PasswordRules.CharacterClass: Bool] = [:]
        for (characterClass, toggleOn, _) in toggleBacked {
            toggleInPlay[characterClass] = toggleOn || forcedOn.contains(characterClass)
        }
        for (characterClass, _, baseline) in toggleBacked {
            let ruleAllows = noExplicitAllowList || rules.allowedClasses.contains(characterClass) || asciiPrintableInPlay
            let ruleRequires = requiredClassesFlat.contains(characterClass)
            // `ruleAllows` still gates the baseline pool even for a forced-on
            // class, and that is load-bearing rather than redundant:
            // `forcedOn` can name `.special` because a custom class
            // contributes a symbol character, and such a rule permits that
            // custom class's own members ONLY -- never MyPass's whole
            // 25-character symbol pool. `ruleRequires` keeps its own
            // unconditional branch because a literal `required:` clause has
            // always folded its class into `allowedClasses` too, so the two
            // can never contradict each other there.
            guard ruleRequires || (ruleAllows && toggleInPlay[characterClass] == true) else { continue }
            membership[characterClass, default: []].formUnion(baseline)
            allCharacters.formUnion(baseline)
        }

        // Custom classes contribute their literal characters directly,
        // independent of MyPass's own four baseline pools (Decision 4) --
        // Apple's `special` class and this app's `symbols` pool are not the
        // same set, and a site's bespoke required symbol may fall outside
        // it.
        //
        // A REQUIRED custom class bypasses the toggles entirely, exactly as
        // Decision 4 grants: the site mandates one of those characters, so
        // the password gets one whatever the user prefers.
        //
        // An `allowed:`-only custom class is NOT the same thing, and used to
        // be treated as if it were. The rule merely *permits* those
        // characters, so whether MyPass draws from them is the user's choice
        // -- expressed, as for every other character, through the toggle
        // backing each member's own class (`toggleBackedClass(of:)`). Before
        // this, classmates.com's `allowed: lower, upper, digit, [!@#$%^&*]`
        // put those eight symbols in every generated password while the
        // generator UI showed Symbols locked off and the popover said only
        // letters and digits were permitted.
        let requiredCustomClasses = requiredClassesFlat.filter(isCustomClass)
        for characterClass in rules.allowedClasses
        where isCustomClass(characterClass) && !requiredCustomClasses.contains(characterClass) {
            if case .custom(let members) = characterClass {
                let requested = members.filter { toggleInPlay[toggleBackedClass(of: $0)] == true }
                guard !requested.isEmpty else { continue }
                membership[characterClass, default: []].formUnion(requested)
                allCharacters.formUnion(requested)
            }
        }
        for characterClass in requiredCustomClasses {
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

    /// `internal` (no access modifier) rather than `private` so
    /// `PasswordGeneratorRulesTests` can pin the exclusion check below
    /// directly, by handing it a candidate that violates it -- the check
    /// is otherwise a no-op against every candidate this generator's own
    /// draw functions can produce (see the exclusion check's own comment
    /// for why), so a test going only through the public `generate` API
    /// could never exercise the rejecting branch.
    static func satisfies(
        _ candidate: String,
        requiredClauses: [[PasswordRules.CharacterClass]],
        pool: EffectivePool,
        maxConsecutive: Int?
    ) -> Bool {
        let characters = Array(candidate)
        // Every character must belong to the rule's effective allowed
        // set -- the single most important guarantee the rule system
        // makes, and until now the one thing nothing in this function (or
        // the independent conformance-test check under Task 5) verified.
        // `pool.isAllowed` is exactly the set `effectivePool` builds:
        // a required class is also an allowed one (Decision 4), and a
        // rule stating no explicit `allowed:` at all falls back to the
        // caller's own toggles rather than to an empty set, so this check
        // stays honest about both semantics rather than reimplementing a
        // stricter, wrong version of them. This check gates the return
        // (a `false` here sends the caller back to another draw, or
        // eventually to `unsatisfiableRules`), so a defect in pool
        // construction becomes a loud thrown error instead of a
        // silently-wrong password handed to the user -- the failure
        // direction a password manager wants. On every one of the 436
        // vendored rules this is a no-op: every character this
        // generator's `randomString`/`deterministicCandidate` can
        // produce is drawn from `pool.characters` in the first place, so
        // it is already a member of `pool.isAllowed` by construction --
        // this exists to catch a FUTURE regression in that construction,
        // not a defect either of them currently exhibits.
        guard characters.allSatisfy({ pool.isAllowed($0) }) else { return false }
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

    /// One attempt at deterministic construction: place one guaranteed-
    /// satisfying character per required clause, fill the rest from the
    /// pool, shuffle with Fisher-Yates so the anchors are not predictably
    /// in the first few positions, then repair any remaining
    /// max-consecutive violation. `internal` (no access modifier) rather
    /// than `private` specifically so `PasswordGeneratorRulesTests` can
    /// call this fallback path directly -- see
    /// `testDeterministicFallbackConstructsASatisfyingCandidateDirectly`
    /// for why a test that only goes through `generate` cannot reliably
    /// exercise this path: at any bound on
    /// `maxRejectionSamplingAttempts` big enough to be practical, honest
    /// rejection sampling has excellent odds of succeeding on its own for
    /// most rules, so reaching this fallback "by chance" through the
    /// public API is not something a test can depend on.
    static func deterministicCandidate(
        length: Int,
        clauseCharacterSets: [[Character]],
        pool: [Character],
        maxConsecutive: Int?
    ) throws -> [Character] {
        var characters: [Character] = try clauseCharacterSets.map { members in
            try randomElement(of: members)
        }
        while characters.count < length {
            characters.append(try randomElement(of: pool))
        }
        try fisherYatesShuffle(&characters)
        if let maxConsecutive {
            try repairMaxConsecutive(&characters, maxConsecutive: maxConsecutive, pool: pool)
        }
        return characters
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
        return pool[try secureRandomIndex(modulo: pool.count)]
    }

    /// Returns an unbiased index in `0..<modulus`, drawn from the same
    /// rejection-sampled `SecRandomCopyBytes` source as every other random
    /// draw in this type.
    ///
    /// `modulus` here is a character pool size or a shuffle position
    /// count, which -- unlike the four baseline pools in
    /// `generateWithoutRules` (26, 26, 10, 25 and their sums, none of
    /// which happen to divide 256 evenly) -- can be anything a site's
    /// `required:`/`allowed:` custom class names, or anything up to the
    /// password length. Nothing in this generator can produce a modulus
    /// above 256 today (character pools are bounded by ASCII-printable,
    /// under 100 characters even summed across every class, and password
    /// lengths are capped well under 256 by both the standalone
    /// generator UI and the vendored rule catalog's `maxlength` values),
    /// but `generate` is public API with no such cap enforced at this
    /// layer, so both branches below are real rather than dead code for
    /// a hypothetical caller.
    private static func secureRandomIndex(modulo modulus: Int) throws -> Int {
        guard modulus > 0 else { throw PasswordGeneratorError.unsatisfiableRules }
        guard modulus <= 256 else {
            return try secureRandomIndexWide(modulo: modulus)
        }
        // When `modulus` evenly divides 256, `256 - (256 % modulus)` is
        // 256 itself, which cannot be represented as the `UInt8` limit
        // `secureRandomByte` expects and traps if constructed directly.
        // In that exact case every byte 0...255 is already perfectly
        // unbiased for `byte % modulus` (each remainder occurs exactly
        // `256 / modulus` times), so the fix is not to reject anything --
        // rejecting even a single byte value would itself reintroduce the
        // bias this scheme exists to avoid.
        guard 256 % modulus != 0 else {
            var byte: UInt8 = 0
            let status = SecRandomCopyBytes(kSecRandomDefault, 1, &byte)
            guard status == errSecSuccess else {
                throw PasswordGeneratorError.secureRandomUnavailable
            }
            return Int(byte) % modulus
        }
        let limit = UInt8(256 - (256 % modulus))
        let byte = try secureRandomByte(below: limit)
        return Int(byte) % modulus
    }

    /// Handles a `modulus` above 256, which a single random byte cannot
    /// cover without the same "limit doesn't fit the integer type" trap
    /// `secureRandomIndex` guards against for `UInt8`. Draws two bytes
    /// (0..<65536) instead of one and applies the identical
    /// rejection-sampling technique, but computed in `Int` rather than a
    /// fixed-width integer type: `Int` represents 65536 without
    /// difficulty, so there is no parallel boundary case here for a
    /// modulus that evenly divides the range -- unlike `UInt8`, which
    /// cannot represent 256, `Int` has no trouble representing 65536, so
    /// the ordinary rejection-sampling formula just works.
    ///
    /// `internal` (no access modifier) rather than `private`, the same
    /// testability seam used for `repairMaxConsecutive` and
    /// `deterministicCandidate`, and more important here than either of
    /// those: this is the only genuinely new randomness primitive in this
    /// file, nothing `generate` can construct today drives `modulus`
    /// above 256, and an untested primitive is exactly the risk this
    /// generator's own design otherwise refuses to take. See
    /// `PasswordGeneratorRulesTests` for direct coverage of the in-range,
    /// no-bias, and above-65536 behavior.
    static func secureRandomIndexWide(modulo modulus: Int) throws -> Int {
        let range = 65536
        guard modulus <= range else {
            // Not reachable by anything this generator can construct
            // (see `secureRandomIndex`'s doc comment), but a silent
            // infinite loop is a worse failure mode for public API than a
            // typed error for a modulus this generator has no way to
            // service.
            throw PasswordGeneratorError.unsatisfiableRules
        }
        let limit = range - (range % modulus)
        while true {
            var bytes = [UInt8](repeating: 0, count: 2)
            let status = SecRandomCopyBytes(kSecRandomDefault, 2, &bytes)
            guard status == errSecSuccess else {
                throw PasswordGeneratorError.secureRandomUnavailable
            }
            let value = Int(bytes[0]) << 8 | Int(bytes[1])
            if value < limit {
                return value % modulus
            }
        }
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
            let j = try secureRandomIndex(modulo: upperBoundExclusive)
            characters.swapAt(index, j)
            index -= 1
        }
    }

    /// Resamples individual characters so no run exceeds `maxConsecutive`,
    /// processing strictly left to right and comparing each position only
    /// against the already-finalized character immediately before it.
    /// This single forward pass is sufficient by induction: once position
    /// `index - 1` is finalized, the prefix `characters[0..<index]` has no
    /// run longer than `maxConsecutive`, so fixing position `index`
    /// against only its immediate predecessor can never leave a violation
    /// behind it, and the next position's own check accounts for whatever
    /// this position was just resampled to.
    ///
    /// An earlier version of this function tracked run boundaries against
    /// the ORIGINAL (pre-repair) characters and, after repairing a run,
    /// skipped forward past the whole run without re-examining the
    /// boundary with whatever followed it -- code review caught that the
    /// repaired run's own tail character could equal the next run's
    /// untouched leading character, silently creating a brand-new
    /// violation. `PasswordGeneratorRulesTests.testRepairMaxConsecutiveFixesARunCreatedByItsOwnEarlierRepair`
    /// exercises exactly that shape: "a a a b b" with max-consecutive 2
    /// used to repair to "a a b b b" -- a fresh run of three b's -- under
    /// the old algorithm. Measured over 200,000 trials at exactly that
    /// input, the old algorithm failed to fully repair the string 58.8%
    /// of the time on a single call. This rewrite was checked against
    /// that same input over 200,000 trials with zero failures, and
    /// independently against an exhaustive enumeration of every possible
    /// resample outcome for every input of length one to eight over
    /// two- and three-character pools at three different
    /// `maxConsecutive` limits (93,444 reachable states), also zero
    /// violations. This rewrite can still fail in the same degenerate
    /// case the caller's `satisfies`
    /// re-check exists for: a pool with no usable alternative character to
    /// resample into (e.g. a one-character pool), where satisfying
    /// max-consecutive for a string longer than `maxConsecutive` is
    /// genuinely impossible regardless of algorithm.
    ///
    /// `internal` (no access modifier) rather than `private` specifically
    /// so `PasswordGeneratorRulesTests` can call this directly with a
    /// hand-picked starting array -- the exact bug above is only checkable
    /// by controlling the input precisely, which a test going through the
    /// public `generate` API and hoping randomness lands on this shape
    /// cannot do reliably.
    static func repairMaxConsecutive(_ characters: inout [Character], maxConsecutive: Int, pool: [Character]) throws {
        guard maxConsecutive > 0, characters.count > 1, !pool.isEmpty else { return }
        var runLength = 1
        var index = 1
        while index < characters.count {
            runLength = characters[index] == characters[index - 1] ? runLength + 1 : 1
            if runLength > maxConsecutive {
                var attempt = characters[index]
                var guardCount = 0
                while attempt == characters[index - 1], guardCount < 20 {
                    attempt = try randomElement(of: pool)
                    guardCount += 1
                }
                characters[index] = attempt
                runLength = attempt == characters[index - 1] ? runLength : 1
            }
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
