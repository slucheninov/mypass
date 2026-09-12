import XCTest
import MyPassKit
@testable import MyPass

final class PasswordRulesSummaryTests: XCTestCase {
    // NOTE on the expected string below: Task 7's original brief specified
    // this test's expected string verbatim, joining the final "needs"
    // fragment with a bare comma ("...characters, at most 3 repeated...")
    // and rendering the third `required:` clause as plain "an uppercase
    // letter or a lowercase letter". Two later review rounds both flagged
    // that string: first for the bare-comma join (fixed by
    // `PasswordRulesSummary.joinedWithAnd(_:)`), and then for a defect that
    // shipped in the brief's own literal text and passed through both
    // rounds untouched -- "needs a digit, a symbol, an uppercase letter or
    // a lowercase letter, ..." reads, to an ordinary reader, as a flat
    // choice across all four items, when the rule actually means the first
    // two AND either of the last two. `requiredClauseFragment(for:)` now
    // marks a multi-member `required:` clause with "either ... or ..." so
    // it cannot be absorbed into the surrounding list. This expected
    // string is updated to match both fixes rather than left as the one
    // exception to either.
    func testDescribesRequiredClassesLengthAndMaxConsecutive() throws {
        // Real rule from the vendored 2026-09-12 snapshot, account.samsung.com.
        let ruleString = "minlength: 8; maxlength: 15; max-consecutive: 3; required: digit; required: special; required: upper,lower;"
        guard case .success(let rules) = PasswordRulesParser.parse(ruleString) else {
            return XCTFail("expected a valid parse")
        }
        let summary = PasswordRulesSummary.describe(rules, domain: "account.samsung.com")
        XCTAssertEqual(
            summary,
            "account.samsung.com needs a digit, a symbol, either an uppercase letter or a lowercase letter, 8 to 15 characters and at most 3 repeated characters in a row."
        )
    }

    // No vendored 2026-09-12 rule happens to name three or more classes in
    // a single `required:` clause, so this one is synthetic -- but the
    // parser and `PasswordRulesParser.parse` both accept the syntax, and
    // the same AND/OR ambiguity the "either ... or ..." fix addresses for
    // two members applies just as much for three or more, so the phrasing
    // needs its own direct coverage rather than relying on a real rule
    // that never exercises it.
    func testDescribesAThreeMemberRequiredClauseAsOneOf() throws {
        let ruleString = "minlength: 4; required: upper,lower,digit;"
        guard case .success(let rules) = PasswordRulesParser.parse(ruleString) else {
            return XCTFail("expected a valid parse")
        }
        let summary = PasswordRulesSummary.describe(rules, domain: "example.com")
        XCTAssertEqual(
            summary,
            "example.com needs one of an uppercase letter, a lowercase letter or a digit and at least 4 characters."
        )
    }

    func testDescribesALengthOnlyRule() throws {
        // Real rule from the vendored 2026-09-12 snapshot, 163.com. Only one
        // "needs" fragment, so the "and" join style doesn't change this one.
        let ruleString = "minlength: 6; maxlength: 16;"
        guard case .success(let rules) = PasswordRulesParser.parse(ruleString) else {
            return XCTFail("expected a valid parse")
        }
        let summary = PasswordRulesSummary.describe(rules, domain: "163.com")
        XCTAssertEqual(summary, "163.com needs 6 to 16 characters.")
    }

    // MARK: - Permitted-set sentence (review follow-up)
    //
    // The summary used to be built entirely from `required:`, the length
    // bounds and `max-consecutive`, and never read `allowedClasses` at
    // all -- so a rule that restricts the character set without requiring
    // anything (amundi-ee.com's six-digit PIN) rendered a sentence that
    // said nothing about digits being the only permitted character, while
    // `PasswordGeneratorView` sitting right next to the popover visibly
    // locked every other toggle off for that same rule.
    //
    // A first fix appended the permitted set as one more item in the same
    // comma-joined "needs" list, which produced "needs only digits are
    // permitted" (not a sentence -- a clause spliced into a noun-phrase
    // list) and, for aetna.com, "needs an uppercase letter, a digit, only
    // lowercase letters..." -- which reads as though "only lowercase
    // letters" were one more required item, the opposite of what it means.
    // These tests pin the corrected shape: the permitted set is its own
    // sentence, after the "needs" sentence is complete.

    func testDescribesASolePermittedClassWithNoRequiredClauseAsItsOwnSentence() throws {
        // Real rule from the vendored 2026-09-12 snapshot, amundi-ee.com --
        // a six-digit PIN with no `required:` clause at all.
        let ruleString = "minlength: 6; maxlength: 6; allowed: digit; max-consecutive: 3;"
        guard case .success(let rules) = PasswordRulesParser.parse(ruleString) else {
            return XCTFail("expected a valid parse")
        }
        let summary = PasswordRulesSummary.describe(rules, domain: "amundi-ee.com")
        XCTAssertEqual(
            summary,
            "amundi-ee.com needs exactly 6 characters and at most 3 repeated characters in a row. Only digits are permitted."
        )
    }

    func testDescribesAPermittedSetAsItsOwnSentenceAlongsideRequiredClauses() throws {
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
            "aetna.com needs an uppercase letter, a digit, 8 to 20 characters and at most 2 repeated characters in a row. Only lowercase letters, uppercase letters and digits are permitted."
        )
    }

    func testDescribesAPermittedSetWithNoOtherRequirementsWithoutADanglingNeedsSentence() throws {
        // A rule whose only content is an `allowed:` restriction -- no
        // `required:` clause, no length bounds, no `max-consecutive` --
        // has nothing to put in a "needs" sentence at all. This must not
        // produce a dangling "example.com needs ." with nothing after it;
        // the permitted set becomes the entire summary instead.
        let ruleString = "allowed: lower, upper;"
        guard case .success(let rules) = PasswordRulesParser.parse(ruleString) else {
            return XCTFail("expected a valid parse")
        }
        let summary = PasswordRulesSummary.describe(rules, domain: "example.com")
        XCTAssertEqual(summary, "example.com only allows lowercase letters and uppercase letters.")
    }

    // MARK: - Custom required class wording (review follow-up)
    //
    // A custom bracketed class (`[ABC]`) always rendered as "a required
    // symbol", regardless of what it actually contained. Apple's grammar
    // allows a custom class to name letters or digits, not just
    // punctuation, so calling one "a symbol" when its members are letters
    // is simply wrong. A follow-up review also pointed out that "required"
    // was redundant after "needs" ("needs a required letter" reads like a
    // stray label) and asked for it dropped, so these fixed strings read
    // "needs a letter", matching every other required-class fragment's own
    // article-plus-noun shape ("a digit", "an uppercase letter").

    func testDescribesARequiredCustomClassOfLettersAsALetter() throws {
        let ruleString = "minlength: 4; required: [ABC];"
        guard case .success(let rules) = PasswordRulesParser.parse(ruleString) else {
            return XCTFail("expected a valid parse")
        }
        let summary = PasswordRulesSummary.describe(rules, domain: "example.com")
        XCTAssertEqual(summary, "example.com needs a letter and at least 4 characters.")
    }

    func testDescribesARequiredCustomClassOfDigitsAsADigit() throws {
        let ruleString = "minlength: 4; required: [123];"
        guard case .success(let rules) = PasswordRulesParser.parse(ruleString) else {
            return XCTFail("expected a valid parse")
        }
        let summary = PasswordRulesSummary.describe(rules, domain: "example.com")
        XCTAssertEqual(summary, "example.com needs a digit and at least 4 characters.")
    }

    func testDescribesARequiredCustomClassOfPunctuationAsASymbol() throws {
        let ruleString = "minlength: 4; required: [!@#];"
        guard case .success(let rules) = PasswordRulesParser.parse(ruleString) else {
            return XCTFail("expected a valid parse")
        }
        let summary = PasswordRulesSummary.describe(rules, domain: "example.com")
        XCTAssertEqual(summary, "example.com needs a symbol and at least 4 characters.")
    }
}
