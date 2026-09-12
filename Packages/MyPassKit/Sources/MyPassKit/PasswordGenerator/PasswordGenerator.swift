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
    /// before falling back to deterministic construction. Named and sized
    /// deliberately high rather than left as a small inline literal: a
    /// tight rule over a small character pool (e.g.
    /// `PasswordGeneratorRulesTests.testMaxConsecutiveIsNeverViolatedAcrossManyGenerations`,
    /// a 2-character pool with max-consecutive 2 over a 24-character
    /// password) has under a 1% chance of satisfying max-consecutive on
    /// any single draw, so a bound of 100 leaves roughly 40% of calls
    /// falling through to the deterministic-and-repair fallback below,
    /// which is a documented best-effort, not something this generator
    /// should lean on for a case plain sampling can solve honestly. At
    /// 2000 attempts that same case fails to converge with probability
    /// under 2e-8 per call. Each attempt costs microseconds (one candidate
    /// string plus a linear-time check), so the bound can be generous.
    private static let maxRejectionSamplingAttempts = 2000

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

        for _ in 0..<maxRejectionSamplingAttempts {
            let candidate = try randomString(length: length, from: pool.characters)
            if satisfies(candidate, requiredClauses: rules.requiredClauses, pool: pool, maxConsecutive: rules.maxConsecutive) {
                return candidate
            }
        }

        // Rejection sampling didn't converge in maxRejectionSamplingAttempts
        // tries -- realistic only for a pathologically tight rule. Fall back
        // to deterministic construction: place one guaranteed-satisfying character per
        // required clause, fill the rest from the pool, shuffle with an
        // unbiased Fisher-Yates so the anchors aren't predictably in the
        // first N positions, then repair any remaining max-consecutive
        // violation. Re-verify before returning either way.
        for _ in 0..<maxDeterministicFallbackAttempts {
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
        // An empty `allowedClasses` never comes out of the parser -- it
        // always defaults to `[.asciiPrintable]` when a rule has no
        // `allowed:` property (see `PasswordRulesParser`) -- but a rule
        // built directly (e.g. one that only constrains length) has no
        // such default, and the pool must not collapse to nothing in that
        // case: "the rule names no allowed classes at all" means "the rule
        // has no opinion here," so the user's own toggles decide, exactly
        // as if there were no rule.
        let noExplicitAllowList = rules.allowedClasses.isEmpty
        for (characterClass, toggleOn, baseline) in toggleBacked {
            let ruleAllows = noExplicitAllowList || rules.allowedClasses.contains(characterClass) || asciiPrintableInPlay
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
        return pool[try secureRandomIndex(modulo: pool.count)]
    }

    /// Returns an unbiased index in `0..<modulus`, drawn from the same
    /// rejection-sampled `SecRandomCopyBytes` source as every other random
    /// draw in this type.
    ///
    /// `modulus` here is a character pool size, which -- unlike the four
    /// baseline pools in `generateWithoutRules` (26, 26, 10, 25 and their
    /// sums, none of which happen to divide 256 evenly) -- can be anything
    /// a site's `required:`/`allowed:` custom class or `.custom` case
    /// names, including small values like 2. When `modulus` evenly divides
    /// 256, `256 - (256 % modulus)` is 256 itself, which cannot be
    /// represented as the `UInt8` limit `secureRandomByte` expects and
    /// traps if constructed directly. In that exact case every byte
    /// 0...255 is already perfectly unbiased for `byte % modulus` (each
    /// remainder occurs exactly `256 / modulus` times), so the fix is not
    /// to reject anything -- rejecting even a single byte value would
    /// itself reintroduce the bias this scheme exists to avoid.
    private static func secureRandomIndex(modulo modulus: Int) throws -> Int {
        guard modulus > 0 else { throw PasswordGeneratorError.unsatisfiableRules }
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
