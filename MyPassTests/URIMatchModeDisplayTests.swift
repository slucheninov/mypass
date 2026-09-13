import XCTest
import MyPassKit
@testable import MyPass

/// Direct tests for the match-mode picker's display copy, defined as a (deliberately
/// non-private) extension on `URIMatchMode` at the bottom of `EntryEditView.swift`.
/// `EntryEditView` itself has no test coverage -- this repo has no SwiftUI
/// view-inspection harness, the same reason `EntryEditSaveLogic` and
/// `PasswordRulesSummary` were pulled out of their views -- but the strings a user
/// actually reads are real, assertable logic, not view layout, so they get real
/// assertions here instead of only a compile check.
final class URIMatchModeDisplayTests: XCTestCase {
    func testDisplayNames() {
        XCTAssertEqual(URIMatchMode.registrableDomain.displayName, "Registrable domain (recommended)")
        XCTAssertEqual(URIMatchMode.host.displayName, "Exact host")
        XCTAssertEqual(URIMatchMode.startsWith.displayName, "Starts with")
        XCTAssertEqual(URIMatchMode.exact.displayName, "Exact address")
        XCTAssertEqual(URIMatchMode.never.displayName, "Never (hide from extension)")
    }

    func testRegistrableDomainHelpText() {
        XCTAssertEqual(
            URIMatchMode.registrableDomain.helpText,
            "Matches example.com and any subdomain, such as login.example.com."
        )
    }

    func testHostHelpText() {
        XCTAssertEqual(
            URIMatchMode.host.helpText,
            "Matches only this exact hostname and port. A different subdomain will not match."
        )
    }

    /// Task 9 required `startsWith` matching to compare `rest` (path and query) only
    /// after `origin` (scheme, host, non-default port) matches exactly -- comparing
    /// the whole URL as one string let a stored "https://example.com" match a
    /// lookalike like "https://example.com.attacker.com". This help text must
    /// disclose the cost Task 9 kept deliberately: a prefix ending mid-path still
    /// matches a longer path sharing that start (an "app" prefix also covers
    /// "app-legacy"), rather than describing the older, less precise whole-URL
    /// prefix behaviour from the original spec.
    func testStartsWithHelpTextDisclosesPathSuffixOvermatch() {
        XCTAssertEqual(
            URIMatchMode.startsWith.helpText,
            "Matches any page whose address begins with this one. Note: this can also match " +
                "unrelated pages that share the same prefix, such as example.com/app also matching " +
                "example.com/app-legacy."
        )
    }

    func testExactHelpText() {
        XCTAssertEqual(
            URIMatchMode.exact.helpText,
            "Matches only this exact page address, including its path and query."
        )
    }

    /// `.never` hides the entry from the browser extension only -- it is not a
    /// security boundary against someone who already has the vault open, and it must
    /// stay fully visible and usable inside the app. The help text must say so, not
    /// imply the entry is hidden or locked within MyPass itself.
    func testNeverHelpTextScopesTheHidingToTheExtensionOnly() {
        XCTAssertEqual(
            URIMatchMode.never.helpText,
            "Hides this entry from the browser extension only — it stays fully visible and " +
                "usable inside MyPass."
        )
    }
}
