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

    // MARK: - Permitted-set fragment (review follow-up)
    //
    // The summary used to be built entirely from `required:`, the length
    // bounds and `max-consecutive`, and never read `allowedClasses` at
    // all -- so a rule that restricts the character set without requiring
    // anything (amundi-ee.com's six-digit PIN) rendered a sentence that
    // said nothing about digits being the only permitted character, while
    // `PasswordGeneratorView` sitting right next to the popover visibly
    // locked every other toggle off for that same rule. These two tests
    // pin the fix: the permitted set is now named whenever `allowed:`
    // restricts it beyond what `required:` alone conveys.

    func testDescribesASolePermittedClassWithNoRequiredClause() throws {
        // Real rule from the vendored 2026-09-12 snapshot, amundi-ee.com --
        // a six-digit PIN with no `required:` clause at all.
        let ruleString = "minlength: 6; maxlength: 6; allowed: digit; max-consecutive: 3;"
        guard case .success(let rules) = PasswordRulesParser.parse(ruleString) else {
            return XCTFail("expected a valid parse")
        }
        let summary = PasswordRulesSummary.describe(rules, domain: "amundi-ee.com")
        XCTAssertEqual(
            summary,
            "amundi-ee.com needs only digits are permitted, exactly 6 characters, at most 3 repeated characters in a row."
        )
    }

    func testDescribesAPermittedSetAlongsideRequiredClasses() throws {
        // Real rule from the vendored 2026-09-12 snapshot, aetna.com --
        // requires an uppercase letter and a digit, and additionally
        // restricts `allowed:` to exclude symbols entirely (beyond the
        // bespoke `[-_&#@]` custom class, which this summary deliberately
        // does not spell out -- see `PasswordRulesSummary.name(for:)`).
        let ruleString = "minlength: 8; maxlength: 20; max-consecutive: 2; required: upper; required: digit; allowed: lower, [-_&#@];"
        guard case .success(let rules) = PasswordRulesParser.parse(ruleString) else {
            return XCTFail("expected a valid parse")
        }
        let summary = PasswordRulesSummary.describe(rules, domain: "aetna.com")
        XCTAssertEqual(
            summary,
            "aetna.com needs an uppercase letter, a digit, only lowercase letters, uppercase letters, digits are permitted, 8 to 20 characters, at most 2 repeated characters in a row."
        )
    }

    // MARK: - Custom required class wording (review follow-up)
    //
    // A custom bracketed class (`[ABC]`) always rendered as "a required
    // symbol", regardless of what it actually contained. Apple's grammar
    // allows a custom class to name letters or digits, not just
    // punctuation, so calling one "a symbol" when its members are letters
    // is simply wrong. These tests pin the fix: the wording now follows
    // what the class's members actually are.

    func testDescribesARequiredCustomClassOfLettersAsALetter() throws {
        let ruleString = "minlength: 4; required: [ABC];"
        guard case .success(let rules) = PasswordRulesParser.parse(ruleString) else {
            return XCTFail("expected a valid parse")
        }
        let summary = PasswordRulesSummary.describe(rules, domain: "example.com")
        XCTAssertEqual(summary, "example.com needs a required letter, at least 4 characters.")
    }

    func testDescribesARequiredCustomClassOfDigitsAsADigit() throws {
        let ruleString = "minlength: 4; required: [123];"
        guard case .success(let rules) = PasswordRulesParser.parse(ruleString) else {
            return XCTFail("expected a valid parse")
        }
        let summary = PasswordRulesSummary.describe(rules, domain: "example.com")
        XCTAssertEqual(summary, "example.com needs a required digit, at least 4 characters.")
    }

    func testDescribesARequiredCustomClassOfPunctuationAsASymbol() throws {
        let ruleString = "minlength: 4; required: [!@#];"
        guard case .success(let rules) = PasswordRulesParser.parse(ruleString) else {
            return XCTFail("expected a valid parse")
        }
        let summary = PasswordRulesSummary.describe(rules, domain: "example.com")
        XCTAssertEqual(summary, "example.com needs a required symbol, at least 4 characters.")
    }
}
