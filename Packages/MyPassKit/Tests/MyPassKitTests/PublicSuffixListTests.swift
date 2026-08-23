import Foundation
import XCTest
@testable import MyPassKit

final class PublicSuffixListTests: XCTestCase {
    func testExactRuleComTLD() {
        XCTAssertEqual(PublicSuffixList.publicSuffix(of: "example.com"), "com")
        XCTAssertEqual(PublicSuffixList.registrableDomain(of: "example.com"), "example.com")
    }

    func testSubdomainReducesToRegistrableDomain() {
        XCTAssertEqual(PublicSuffixList.registrableDomain(of: "www.example.com"), "example.com")
    }

    func testMultiLabelSuffixCoUk() {
        XCTAssertEqual(PublicSuffixList.publicSuffix(of: "accounts.google.co.uk"), "co.uk")
        XCTAssertEqual(PublicSuffixList.registrableDomain(of: "accounts.google.co.uk"), "google.co.uk")
    }

    func testMultiLabelSuffixComUa() {
        XCTAssertEqual(PublicSuffixList.registrableDomain(of: "shop.example.com.ua"), "example.com.ua")
    }

    func testPrivateSectionRuleGithubIo() {
        XCTAssertEqual(PublicSuffixList.publicSuffix(of: "foo.github.io"), "github.io")
        XCTAssertEqual(PublicSuffixList.registrableDomain(of: "foo.github.io"), "foo.github.io")
    }

    func testImplicitRuleForUnknownTLD() {
        XCTAssertEqual(PublicSuffixList.registrableDomain(of: "foo.bar.unknowntld"), "bar.unknowntld")
    }

    func testWildcardRule() {
        XCTAssertEqual(PublicSuffixList.publicSuffix(of: "a.b.ck"), "b.ck")
        XCTAssertEqual(PublicSuffixList.registrableDomain(of: "a.b.ck"), "a.b.ck")
    }

    func testExceptionRule() {
        XCTAssertEqual(PublicSuffixList.registrableDomain(of: "www.ck"), "www.ck")
    }

    func testHostThatIsItselfAPublicSuffixHasNoRegistrableDomain() {
        XCTAssertNil(PublicSuffixList.registrableDomain(of: "co.uk"))
        XCTAssertNil(PublicSuffixList.registrableDomain(of: "com"))
    }

    func testEmptyHostIsNil() {
        XCTAssertNil(PublicSuffixList.publicSuffix(of: ""))
        XCTAssertNil(PublicSuffixList.registrableDomain(of: ""))
    }

    func testLowercasesAndStripsTrailingDot() {
        XCTAssertEqual(PublicSuffixList.registrableDomain(of: "Example.COM."), "example.com")
    }

    func testPerformanceOfRepeatedLookups() {
        // Warm the cache before timing so the measured loop reflects steady-state lookup
        // cost rather than the one-time PSL parse/load.
        _ = PublicSuffixList.registrableDomain(of: "www.example.co.uk")

        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<10_000 {
            _ = PublicSuffixList.registrableDomain(of: "www.example.co.uk")
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        XCTAssertLessThan(elapsed, 1.0, "10,000 registrableDomain(of:) lookups took \(elapsed)s, expected under 1.0s")
    }
}
