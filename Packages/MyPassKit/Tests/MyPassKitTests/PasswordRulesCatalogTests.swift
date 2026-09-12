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
