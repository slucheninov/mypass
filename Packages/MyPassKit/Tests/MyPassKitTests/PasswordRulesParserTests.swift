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
    // The real aeon.co.jp rule in the vendored 2026-09-12 snapshot ends its
    // custom class with a doubled "]]" (a literal ']' member, then the real
    // closing bracket) -- exactly like admiral.com below. This fixture is
    // that same rule with the trailing ']' removed on purpose, so it
    // exercises the OTHER, more common termination shape instead: a class
    // that ends on the FIRST ']', with nothing doubled. That is the
    // majority form among the vendored rules that use a custom class (230
    // of 275), and admiral.com does not cover it, so this fixture proves
    // single-bracket termination while admiral.com proves the doubled form
    // -- together they cover both ways a custom class can legally close.

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
        let raw = ##"minlength: 8; required: digit; required: [- !"#$&'()*+,.:;<=>?@[^_`{|}~]]; allowed: lower, upper;"##
        guard case .success(let rules) = PasswordRulesParser.parse(raw) else {
            return XCTFail("expected a successful parse")
        }
        XCTAssertEqual(rules.minLength, 8)
        XCTAssertEqual(rules.requiredClauses.count, 2)
        guard case .custom(let members)? = rules.requiredClauses.last?.first else {
            return XCTFail("expected the second required clause to be a single custom class")
        }
        // Exact-set equality, not spot-check `contains` calls: `,` sits
        // right next to `;` in this class and is the OR-separator's exact
        // sibling trap -- a parser that silently dropped it (or dropped
        // '%', '/', '\', or any other member) would still pass a
        // `contains` check on just '[', ']', '-' and ';', and Task 5's
        // conformance gate would then generate a password against the
        // wrong effective rule without ever failing a test. Derived
        // directly from the real vendored string above: everything between
        // the opening '[' and the doubled "]]" is a literal member, in
        // order '-', ' ', '!', '"', '#', '$', '&', '\'', '(', ')', '*',
        // '+', ',', '.', ':', ';', '<', '=', '>', '?', '@', '[', '^', '_',
        // '`', '{', '|', '}', '~', plus the first ']' of the doubled
        // ending -- 30 members total.
        let expectedMembers: Set<Character> = [
            "-", " ", "!", "\"", "#", "$", "&", "'", "(", ")", "*", "+", ",", ".", ":",
            ";", "<", "=", ">", "?", "@", "[", "^", "_", "`", "{", "|", "}", "~", "]",
        ]
        XCTAssertEqual(members.count, 30)
        XCTAssertEqual(members, expectedMembers)
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
