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

    // MARK: - Unicode / punycode (IDNA) handling
    //
    // ACE reference values below ("xn--55qx5d" for 公司, "xn--r8jz45g" for 例え,
    // "xn--bcher-kva" for bücher) were produced independently of Foundation
    // with Python's `str.encode("idna")` and cross-checked against
    // `URL(string:).host`; none of them is derived from the code under test.

    /// `公司.hk` is a rule in the bundled data file, spelled in Unicode.
    func testBundledUnicodeSuffixMatchesItsPunycodeHost() {
        XCTAssertEqual(PublicSuffixList.publicSuffix(of: "example.xn--55qx5d.hk"), "xn--55qx5d.hk")
        XCTAssertEqual(PublicSuffixList.registrableDomain(of: "example.xn--55qx5d.hk"), "example.xn--55qx5d.hk")
        XCTAssertEqual(PublicSuffixList.registrableDomain(of: "www.example.xn--55qx5d.hk"), "example.xn--55qx5d.hk")
    }

    func testBundledUnicodeSuffixUnicodeAndPunycodeHostsAreEquivalent() {
        XCTAssertEqual(PublicSuffixList.publicSuffix(of: "example.公司.hk"), "xn--55qx5d.hk")
        XCTAssertEqual(PublicSuffixList.registrableDomain(of: "example.公司.hk"), "example.xn--55qx5d.hk")
        XCTAssertEqual(
            PublicSuffixList.registrableDomain(of: "www.例え.公司.hk"),
            PublicSuffixList.registrableDomain(of: "www.xn--r8jz45g.xn--55qx5d.hk")
        )
        XCTAssertEqual(PublicSuffixList.registrableDomain(of: "www.例え.公司.hk"), "xn--r8jz45g.xn--55qx5d.hk")
    }

    func testSiblingRegistrableDomainsUnderUnicodeSuffixStayIsolated() {
        let a = PublicSuffixList.registrableDomain(of: "login.alpha.xn--55qx5d.hk")
        let b = PublicSuffixList.registrableDomain(of: "login.beta.xn--55qx5d.hk")
        XCTAssertEqual(a, "alpha.xn--55qx5d.hk")
        XCTAssertEqual(b, "beta.xn--55qx5d.hk")
        XCTAssertNotEqual(a, b)
        // The suffix itself is not a registrable domain, in either spelling.
        XCTAssertNil(PublicSuffixList.registrableDomain(of: "xn--55qx5d.hk"))
        XCTAssertNil(PublicSuffixList.registrableDomain(of: "公司.hk"))
    }

    func testUnicodeCaseTrailingDotAndNormalizationFormsAreCanonicalized() {
        XCTAssertEqual(PublicSuffixList.registrableDomain(of: "Example.XN--55QX5D.HK."), "example.xn--55qx5d.hk")
        XCTAssertEqual(PublicSuffixList.registrableDomain(of: "EXAMPLE.公司.HK."), "example.xn--55qx5d.hk")
        // Ideographic full stop is a label separator under IDNA mapping.
        XCTAssertEqual(PublicSuffixList.registrableDomain(of: "example.公司。hk"), "example.xn--55qx5d.hk")
        // NFC and NFD spellings of the same label are the same host.
        let nfc = "b\u{00FC}cher.example.com"
        let nfd = "bu\u{0308}cher.example.com"
        XCTAssertNotEqual(nfc.unicodeScalars.count, nfd.unicodeScalars.count)
        XCTAssertEqual(PublicSuffixList.registrableDomain(of: nfc), "example.com")
        XCTAssertEqual(PublicSuffixList.registrableDomain(of: nfd), "example.com")
        XCTAssertEqual(PublicSuffixList.canonicalHost(nfc), "xn--bcher-kva.example.com")
        XCTAssertEqual(PublicSuffixList.canonicalHost(nfd), "xn--bcher-kva.example.com")
        XCTAssertEqual(PublicSuffixList.registrableDomain(of: "bücher.de"), "xn--bcher-kva.de")
    }

    func testUnicodeLabelUnderAsciiSuffixReturnsAce() {
        XCTAssertEqual(PublicSuffixList.registrableDomain(of: "www.bücher.co.uk"), "xn--bcher-kva.co.uk")
        XCTAssertEqual(PublicSuffixList.registrableDomain(of: "www.xn--bcher-kva.co.uk"), "xn--bcher-kva.co.uk")
    }

    func testMalformedNonAsciiHostsFailClosed() {
        for host in [
            "公司.hk/path", "公司.hk:8080", "user@公司.hk", "公司.hk?x=1", "公司.hk#frag",
            "公司 .hk", "a..公司.hk", ".公司.hk", "公司.hk..", "公司.hk\n", "公\u{0000}司.hk",
            "公司.hk%2f", "[公司.hk]", "公司.hk\\x",
            String(repeating: "公", count: 70) + ".hk",
        ] {
            XCTAssertNil(PublicSuffixList.publicSuffix(of: host), "publicSuffix(of: \(host.debugDescription))")
            XCTAssertNil(PublicSuffixList.registrableDomain(of: host), "registrableDomain(of: \(host.debugDescription))")
            XCTAssertNil(PublicSuffixList.canonicalHost(host), "canonicalHost(\(host.debugDescription))")
        }
    }

    func testAsciiAndIpBehaviourIsUnchanged() {
        XCTAssertEqual(PublicSuffixList.canonicalHost("Example.COM."), "example.com")
        XCTAssertNil(PublicSuffixList.canonicalHost(""))
        XCTAssertNil(PublicSuffixList.canonicalHost("."))
        XCTAssertEqual(PublicSuffixList.canonicalHost("localhost"), "localhost")
        XCTAssertEqual(PublicSuffixList.registrableDomain(of: "localhost"), nil)
        XCTAssertEqual(PublicSuffixList.publicSuffix(of: "localhost"), "localhost")
        // IP literals are the caller's concern (ExtensionEntryMatcher compares
        // them whole before reaching this type); ASCII input is not re-validated.
        XCTAssertEqual(PublicSuffixList.canonicalHost("127.0.0.1"), "127.0.0.1")
        XCTAssertEqual(PublicSuffixList.canonicalHost("::1"), "::1")
        XCTAssertEqual(PublicSuffixList.registrableDomain(of: "foo.bar.unknowntld"), "bar.unknowntld")
    }

    func testEveryBundledRuleConvertsAndUnicodeRulesAreStoredAsAce() throws {
        let contents = PublicSuffixList.bundledRuleData()
        XCTAssertNotNil(PublicSuffixList.Rules(parsing: contents), "a bundled rule failed ASCII-compatible conversion")
        let rules = try XCTUnwrap(PublicSuffixList.Rules(parsing: contents))
        for set in [rules.exact, rules.wildcard, rules.exception] {
            XCTAssertTrue(set.allSatisfy { $0.allSatisfy(\.isASCII) }, "a non-ASCII rule survived loading")
        }
        XCTAssertTrue(rules.exact.contains("xn--55qx5d.hk"))
        XCTAssertFalse(rules.exact.contains("公司.hk"))
    }

    // MARK: Custom Unicode fixtures (exact / wildcard / exception semantics)

    private static let unicodeFixture = """
    // ===BEGIN ICANN DOMAINS===
    example
    公司.example
    *.日本.example
    !例.日本.example
    // ===END ICANN DOMAINS===
    """

    private func fixtureRules() throws -> PublicSuffixList.Rules {
        try XCTUnwrap(PublicSuffixList.Rules(parsing: Self.unicodeFixture))
    }

    func testCustomUnicodeExactRule() throws {
        let rules = try fixtureRules()
        for host in ["shop.公司.example", "shop.xn--55qx5d.example", "SHOP.公司.EXAMPLE."] {
            XCTAssertEqual(PublicSuffixList.publicSuffix(of: host, using: rules), "xn--55qx5d.example", host)
            XCTAssertEqual(PublicSuffixList.registrableDomain(of: host, using: rules), "shop.xn--55qx5d.example", host)
        }
        XCTAssertNil(PublicSuffixList.registrableDomain(of: "公司.example", using: rules))
        XCTAssertNil(PublicSuffixList.registrableDomain(of: "xn--55qx5d.example", using: rules))
    }

    func testCustomUnicodeWildcardRule() throws {
        let rules = try fixtureRules()
        for host in ["a.b.日本.example", "a.b.xn--wgv71a.example"] {
            XCTAssertEqual(PublicSuffixList.publicSuffix(of: host, using: rules), "b.xn--wgv71a.example", host)
            XCTAssertEqual(PublicSuffixList.registrableDomain(of: host, using: rules), "a.b.xn--wgv71a.example", host)
        }
        // The wildcard's own parent is not covered by `*.`; only "日本.example"
        // under the exact "example" rule applies, so it is registrable there.
        XCTAssertEqual(PublicSuffixList.registrableDomain(of: "日本.example", using: rules), "xn--wgv71a.example")
        // Wildcard children are public suffixes themselves.
        XCTAssertNil(PublicSuffixList.registrableDomain(of: "b.日本.example", using: rules))
    }

    func testCustomUnicodeExceptionRule() throws {
        let rules = try fixtureRules()
        for host in ["例.日本.example", "www.例.日本.example", "www.xn--fsq.xn--wgv71a.example"] {
            XCTAssertEqual(PublicSuffixList.publicSuffix(of: host, using: rules), "xn--wgv71a.example", host)
            XCTAssertEqual(PublicSuffixList.registrableDomain(of: host, using: rules), "xn--fsq.xn--wgv71a.example", host)
        }
        // A sibling that is not the exception stays under the wildcard.
        XCTAssertEqual(PublicSuffixList.registrableDomain(of: "x.y.日本.example", using: rules), "x.y.xn--wgv71a.example")
    }

    func testUnconvertibleRuleRejectsTheWholeRuleSet() {
        XCTAssertNil(PublicSuffixList.Rules(parsing: "com\n公司/x.hk\n"))
        XCTAssertNil(PublicSuffixList.Rules(parsing: "*.a..公司\n"))
        XCTAssertNil(PublicSuffixList.Rules(parsing: "!公司.hk:80\n"))
    }

    /// The lookups behind the public API take an optional rule set; `nil` is the
    /// state `PublicSuffixList` is in when the bundled data holds a rule this
    /// OS cannot convert. It must answer nil for everything — ASCII and IDN
    /// alike — never fall back to the implicit `*` rule (which would make
    /// "evil.co.uk" and "bank.co.uk" one registrable domain "co.uk").
    func testUnavailableRegistryReturnsNilForAsciiAndIdnHosts() throws {
        let unavailable = PublicSuffixList.Rules(parsing: "com\nco.uk\n公司/x.hk\n")
        XCTAssertNil(unavailable)

        let valid = try XCTUnwrap(PublicSuffixList.Rules(parsing: "com\nco.uk\n公司.hk\n"))
        for (host, expectedSuffix) in [
            ("www.example.com", "com"),
            ("www.example.co.uk", "co.uk"),
            ("例え.公司.hk", "xn--55qx5d.hk"),
            ("www.example.xn--55qx5d.hk", "xn--55qx5d.hk"),
        ] {
            XCTAssertEqual(PublicSuffixList.publicSuffix(of: host, using: valid), expectedSuffix, host)
            XCTAssertNotNil(PublicSuffixList.registrableDomain(of: host, using: valid), host)

            XCTAssertNil(PublicSuffixList.publicSuffix(of: host, using: unavailable), host)
            XCTAssertNil(PublicSuffixList.registrableDomain(of: host, using: unavailable), host)
        }
    }

    /// `canonicalHost` needs no rule data, so it stays usable when the registry
    /// is unavailable (callers compare canonical hosts whole in that case).
    func testCanonicalHostIsIndependentOfRuleData() {
        XCTAssertEqual(PublicSuffixList.canonicalHost("公司.hk"), "xn--55qx5d.hk")
        XCTAssertEqual(PublicSuffixList.canonicalHost("XN--55QX5D.HK."), "xn--55qx5d.hk")
        XCTAssertEqual(PublicSuffixList.canonicalHost("LOCALHOST"), "localhost")
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
