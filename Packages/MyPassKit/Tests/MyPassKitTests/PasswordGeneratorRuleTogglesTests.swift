import XCTest
@testable import MyPassKit

/// Covers the engine's answer to "what does this rule permit, given these
/// toggles?" -- the question `PasswordRulesToggleEvaluator` in the app target
/// used to answer a second, divergent time. Every rule string below is copied
/// verbatim out of the vendored 2026-09-12 `password-rules.json` and parsed by
/// the real parser rather than hand-built, because the divergence a
/// whole-branch review found was precisely between what the grammar says and
/// what each layer assumed it said.
final class PasswordGeneratorRuleTogglesTests: XCTestCase {
    private func parse(_ raw: String, file: StaticString = #filePath, line: UInt = #line) throws -> PasswordRules {
        switch PasswordRulesParser.parse(raw) {
        case .success(let rules):
            return rules
        case .failure(let error):
            XCTFail("expected \(raw) to parse, got \(error)", file: file, line: line)
            throw error
        }
    }

    private let lowercase = Set("abcdefghijklmnopqrstuvwxyz")
    private let uppercase = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
    private let digits = Set("0123456789")

    // amundi-ee.com's entire real rule: a six-digit PIN with no `required:`
    // clause at all.
    private let amundi = "minlength: 6; maxlength: 6; allowed: digit; max-consecutive: 3"
    // classmates.com's entire real rule: three named classes plus a bespoke
    // eight-character symbol set, and no `required:` clause.
    private let classmates = "minlength: 6; maxlength: 20; allowed: lower, upper, digit, [!@#$%^&*];"
    // acmemarkets.com's entire real rule: a REQUIRED custom class alongside an
    // `allowed:` list that never names `special`.
    private let acmemarkets = "minlength: 8; maxlength: 40; required: upper; required: [!#$%&*@^]; allowed: lower,digit;"

    func testSoleAllowedClassIsPermittedForcedOnAndExcludesTheRest() throws {
        let rules = try parse(amundi)
        XCTAssertEqual(PasswordGenerator.permittedToggleClasses(for: rules), [.digit])
        XCTAssertEqual(PasswordGenerator.forcedOnToggleClasses(for: rules), [.digit])
        XCTAssertEqual(PasswordGenerator.excludedToggleClasses(for: rules), [.lower, .upper, .special])
    }

    func testSoleAllowedClassIsGeneratedEvenWithItsOwnToggleOff() throws {
        // The exact divergence this consolidation exists to close. The
        // generator UI locked digits on for this rule, so the app succeeded;
        // the extension bridge reads the persisted toggles with no UI to
        // force anything, so it threw `noCharacterClassSelected` and told the
        // user no character types were enabled -- false, three of the four
        // were on. Both surfaces now go through the same forcing.
        let rules = try parse(amundi)
        let options = PasswordGeneratorOptions(
            length: 20, includeLowercase: true, includeUppercase: true, includeDigits: false, includeSymbols: true
        )
        let password = try PasswordGenerator.generate(options: options, rules: rules)
        XCTAssertEqual(password.count, 6)
        XCTAssertTrue(password.allSatisfy { digits.contains($0) }, "\(password) must be digits only")
    }

    func testAnAllowedCustomSymbolClassMakesSymbolsPermittedRatherThanExcluded() throws {
        // Before this, `permittedToggleClasses`'s predecessor saw only the
        // three NAMED classes, so the UI locked Symbols off and the popover
        // said only letters and digits were permitted -- while the generated
        // password carried the custom class's symbols anyway.
        let rules = try parse(classmates)
        XCTAssertEqual(PasswordGenerator.permittedToggleClasses(for: rules), [.lower, .upper, .digit, .special])
        XCTAssertTrue(PasswordGenerator.excludedToggleClasses(for: rules).isEmpty)
        XCTAssertTrue(PasswordGenerator.forcedOnToggleClasses(for: rules).isEmpty)
    }

    func testAnAllowedOnlyCustomClassIsSuppressedWhenItsToggleIsOff() throws {
        // The rule merely PERMITS those eight symbols; it does not require
        // them. With the user's Symbols toggle off, none may appear.
        let rules = try parse(classmates)
        let options = PasswordGeneratorOptions(
            length: 20, includeLowercase: true, includeUppercase: true, includeDigits: true, includeSymbols: false
        )
        for _ in 0..<50 {
            let password = try PasswordGenerator.generate(options: options, rules: rules)
            XCTAssertTrue(
                password.allSatisfy { lowercase.contains($0) || uppercase.contains($0) || digits.contains($0) },
                "\(password) must contain no symbol when the Symbols toggle is off"
            )
        }
    }

    func testAnAllowedOnlyCustomClassContributesOnlyItsOwnMembersWhenItsToggleIsOn() throws {
        // The other half: with Symbols on, the site's own eight symbols are
        // in play -- and ONLY those. MyPass's baseline symbol pool holds 25
        // characters, seventeen of which this rule never allowed, and
        // `.special` never appears in its `allowed:` list, so the baseline
        // pool must stay out even though `.special` now counts as permitted.
        let rules = try parse(classmates)
        let siteSymbols = Set("!@#$%^&*")
        let options = PasswordGeneratorOptions(
            length: 20, includeLowercase: true, includeUppercase: true, includeDigits: true, includeSymbols: true
        )
        var sawSiteSymbol = false
        for _ in 0..<50 {
            let password = try PasswordGenerator.generate(options: options, rules: rules)
            XCTAssertTrue(
                password.allSatisfy {
                    lowercase.contains($0) || uppercase.contains($0) || digits.contains($0) || siteSymbols.contains($0)
                },
                "\(password) must draw symbols only from the site's own set"
            )
            if password.contains(where: { siteSymbols.contains($0) }) { sawSiteSymbol = true }
        }
        // 50 draws of 20 characters from a 70-character pool: the odds of
        // never landing on one of the eight are about 1 in 10^52.
        XCTAssertTrue(sawSiteSymbol, "the site's permitted symbols must actually be in play when Symbols is on")
    }

    func testARequiredCustomClassStillIgnoresTheToggle() throws {
        // Decision 4 grants the unconditional bypass to REQUIRED custom
        // classes, and the gate above must not have taken it away: the site
        // mandates one of these characters, so the password gets one whatever
        // the user prefers.
        let rules = try parse(acmemarkets)
        let siteSymbols = Set("!#$%&*@^")
        let options = PasswordGeneratorOptions(
            length: 12, includeLowercase: true, includeUppercase: true, includeDigits: true, includeSymbols: false
        )
        for _ in 0..<20 {
            let password = try PasswordGenerator.generate(options: options, rules: rules)
            XCTAssertTrue(
                password.contains(where: { siteSymbols.contains($0) }),
                "\(password) must contain a required custom-class character even with Symbols off"
            )
        }
    }

    func testEffectiveOptionsDerivesWithoutMutatingTheUsersOwnChoice() throws {
        let rules = try parse(amundi)
        let userOptions = PasswordGeneratorOptions(
            length: 20, includeLowercase: true, includeUppercase: true, includeDigits: false, includeSymbols: true
        )
        let effective = PasswordGenerator.effectiveOptions(for: userOptions, rules: rules)

        XCTAssertEqual(effective.length, 6)
        XCTAssertTrue(effective.includeDigits, "the sole permitted class is forced on")
        XCTAssertFalse(effective.includeLowercase)
        XCTAssertFalse(effective.includeUppercase)
        XCTAssertFalse(effective.includeSymbols)

        // `PasswordGeneratorOptions` is a struct, so this is a tautology at
        // the language level -- it is asserted anyway because the whole point
        // of introducing this function was to stop the caller writing the
        // derived values back over the user's own, and a future refactor to a
        // reference type or an `inout` signature must fail here loudly.
        XCTAssertEqual(userOptions.length, 20)
        XCTAssertFalse(userOptions.includeDigits)
        XCTAssertTrue(userOptions.includeLowercase)
        XCTAssertTrue(userOptions.includeUppercase)
        XCTAssertTrue(userOptions.includeSymbols)
    }

    func testANonASCIICustomClassMemberCountsAsASymbol() throws {
        // dkb.de's real rule. The umlauts are not characters MyPass ever
        // emits, but a rule naming them is still saying it permits more than
        // letters and digits, and classifying them as `.special` is what
        // keeps the Symbols toggle from being locked off on such a rule.
        let rules = try parse("minlength: 8; maxlength: 38; required: lower, upper; required: digit; allowed: [-äüöÄÜÖß!$%&/()=?+#,.:];")
        XCTAssertEqual(PasswordGenerator.toggleBackedClass(of: "ä"), .special)
        XCTAssertEqual(PasswordGenerator.toggleBackedClass(of: "7"), .digit)
        XCTAssertEqual(PasswordGenerator.toggleBackedClass(of: "Q"), .upper)
        XCTAssertEqual(PasswordGenerator.toggleBackedClass(of: "q"), .lower)
        XCTAssertTrue(PasswordGenerator.excludedToggleClasses(for: rules).isEmpty)
    }
}
