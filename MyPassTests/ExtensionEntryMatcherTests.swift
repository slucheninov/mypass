import XCTest
import MyPassKit
@testable import MyPass

final class ExtensionEntryMatcherTests: XCTestCase {
    private func makeEntry(url: String, title: String = "Entry") -> KdbxEntry {
        let now = Date()
        var entry = KdbxEntry(
            uuid: UUID(),
            iconID: 0,
            fields: [],
            creationTime: now,
            lastModificationTime: now,
            lastAccessTime: now,
            locationChanged: now,
            history: []
        )
        entry.title = title
        entry.url = url
        return entry
    }

    private func makeGroup(entries: [KdbxEntry]) -> KdbxGroup {
        let now = Date()
        return KdbxGroup(
            uuid: UUID(),
            name: "Root",
            iconID: 0,
            creationTime: now,
            lastModificationTime: now,
            locationChanged: now,
            entries: entries,
            subgroups: []
        )
    }

    // MARK: - registrableDomain

    func testRegistrableDomainStripsOneSubdomainLabel() {
        XCTAssertEqual(ExtensionEntryMatcher.registrableDomain(from: "https://login.example.com/path"), "example.com")
    }

    func testRegistrableDomainOfBareApexDomainIsUnchanged() {
        XCTAssertEqual(ExtensionEntryMatcher.registrableDomain(from: "https://example.com"), "example.com")
    }

    func testRegistrableDomainHandlesUrlWithoutScheme() {
        XCTAssertEqual(ExtensionEntryMatcher.registrableDomain(from: "example.com/login"), "example.com")
    }

    func testRegistrableDomainIsCaseInsensitive() {
        XCTAssertEqual(ExtensionEntryMatcher.registrableDomain(from: "https://Example.COM"), "example.com")
    }

    func testRegistrableDomainOfEmptyStringIsNil() {
        XCTAssertNil(ExtensionEntryMatcher.registrableDomain(from: ""))
    }

    // MARK: - matchingEntries

    func testMatchingEntriesIncludesSubdomainMatch() {
        let entry = makeEntry(url: "https://example.com/login")
        let group = makeGroup(entries: [entry])
        let matches = ExtensionEntryMatcher.matchingEntries(in: group, forURL: "https://login.example.com/signin")
        XCTAssertEqual(matches.map(\.uuid), [entry.uuid])
    }

    func testMatchingEntriesExcludesNonMatchingDomain() {
        let entry = makeEntry(url: "https://example.com")
        let group = makeGroup(entries: [entry])
        let matches = ExtensionEntryMatcher.matchingEntries(in: group, forURL: "https://other.com")
        XCTAssertTrue(matches.isEmpty)
    }

    func testMatchingEntriesExcludesEntriesWithEmptyUrl() {
        let entry = makeEntry(url: "")
        let group = makeGroup(entries: [entry])
        let matches = ExtensionEntryMatcher.matchingEntries(in: group, forURL: "https://example.com")
        XCTAssertTrue(matches.isEmpty)
    }

    func testMatchingEntriesIsCaseInsensitive() {
        let entry = makeEntry(url: "https://Example.com")
        let group = makeGroup(entries: [entry])
        let matches = ExtensionEntryMatcher.matchingEntries(in: group, forURL: "https://EXAMPLE.COM")
        XCTAssertEqual(matches.map(\.uuid), [entry.uuid])
    }

    func testMatchingEntriesWalksSubgroups() {
        let entry = makeEntry(url: "https://example.com")
        let now = Date()
        let subgroup = KdbxGroup(
            uuid: UUID(), name: "Sub", iconID: 0,
            creationTime: now, lastModificationTime: now, locationChanged: now,
            entries: [entry], subgroups: []
        )
        let root = KdbxGroup(
            uuid: UUID(), name: "Root", iconID: 0,
            creationTime: now, lastModificationTime: now, locationChanged: now,
            entries: [], subgroups: [subgroup]
        )
        let matches = ExtensionEntryMatcher.matchingEntries(in: root, forURL: "https://example.com")
        XCTAssertEqual(matches.map(\.uuid), [entry.uuid])
    }

    func testMatchingEntriesMatchesOnAdditionalUrlWhenPrimaryDiffers() {
        var entry = makeEntry(url: "https://primary-only.example.com", title: "Multi-URL Entry")
        entry.urls = ["https://primary-only.example.com", "https://secondary.example.com"]
        let group = makeGroup(entries: [entry])

        let matches = ExtensionEntryMatcher.matchingEntries(in: group, forURL: "https://secondary.example.com/login")

        XCTAssertEqual(matches.map(\.uuid), [entry.uuid])
    }

    func testMatchingEntriesDoesNotMatchUnrelatedDomainEvenWithExtras() {
        var entry = makeEntry(url: "https://primary-only.example.com", title: "Multi-URL Entry")
        entry.urls = ["https://primary-only.example.com", "https://secondary.example.com"]
        let group = makeGroup(entries: [entry])

        let matches = ExtensionEntryMatcher.matchingEntries(in: group, forURL: "https://totally-unrelated.example.org")

        XCTAssertTrue(matches.isEmpty)
    }

    // MARK: - registrableDomain: PSL-correct multi-label suffixes

    func testRegistrableDomainKeepsMultiLabelCoDotUkSuffixWhole() {
        // Previously collapsed to "co.uk" under the "last two labels"
        // heuristic; a real PSL lookup keeps "example.co.uk" whole.
        XCTAssertEqual(ExtensionEntryMatcher.registrableDomain(from: "https://example.co.uk"), "example.co.uk")
    }

    func testRegistrableDomainAccountsGoogleCoDotUk() {
        XCTAssertEqual(ExtensionEntryMatcher.registrableDomain(from: "https://accounts.google.co.uk/signin"), "google.co.uk")
    }

    func testMatchingEntriesDoesNotOverMatchAcrossDifferentCoDotUkSites() {
        let entry = makeEntry(url: "https://www.amazon.co.uk")
        let group = makeGroup(entries: [entry])
        let matches = ExtensionEntryMatcher.matchingEntries(in: group, forURL: "https://accounts.google.co.uk")
        XCTAssertTrue(matches.isEmpty, "amazon.co.uk and google.co.uk must not be treated as the same site")
    }

    func testMatchingEntriesMatchesSameCoDotUkSite() {
        let entry = makeEntry(url: "https://google.co.uk")
        let group = makeGroup(entries: [entry])
        let matches = ExtensionEntryMatcher.matchingEntries(in: group, forURL: "https://mail.google.co.uk")
        XCTAssertEqual(matches.map(\.uuid), [entry.uuid])
    }

    func testMatchingEntriesDoesNotOverMatchAcrossDifferentGithubIoSites() {
        let entry = makeEntry(url: "https://foo.github.io")
        let group = makeGroup(entries: [entry])
        let matches = ExtensionEntryMatcher.matchingEntries(in: group, forURL: "https://bar.github.io")
        XCTAssertTrue(matches.isEmpty, "foo.github.io and bar.github.io must not be treated as the same site")
    }

    func testRegistrableDomainOfBarePublicSuffixHostsComparesWhole() {
        XCTAssertEqual(ExtensionEntryMatcher.registrableDomain(from: "https://github.io"), "github.io")
        XCTAssertEqual(ExtensionEntryMatcher.registrableDomain(from: "https://co.uk"), "co.uk")
    }

    // MARK: - registrableDomain: IPv4 literals (the reported bug)

    func testRegistrableDomainDoesNotCollapseDistinctIPv4LoopbackAndPrivateAddresses() {
        // Reported bug: 127.0.0.1, 192.168.0.1, and 10.0.0.1 all reduced to
        // "0.1" under the old "last two labels" heuristic, so an entry saved
        // for one local IP was offered on any other ending in ".0.1". They
        // must now compare as different hosts.
        let loopback = ExtensionEntryMatcher.registrableDomain(from: "http://127.0.0.1:8766/")
        let privateAddr = ExtensionEntryMatcher.registrableDomain(from: "http://192.168.0.1/")
        XCTAssertNotEqual(loopback, privateAddr, "127.0.0.1 and 192.168.0.1 must not be treated as the same site")
    }

    func testRegistrableDomainDistinguishesThirdIPv4Address() {
        let a = ExtensionEntryMatcher.registrableDomain(from: "http://127.0.0.1/")
        let b = ExtensionEntryMatcher.registrableDomain(from: "http://192.168.0.1/")
        let c = ExtensionEntryMatcher.registrableDomain(from: "http://10.0.0.1/")
        XCTAssertNotEqual(a, c, "127.0.0.1 and 10.0.0.1 must not be treated as the same site")
        XCTAssertNotEqual(b, c, "192.168.0.1 and 10.0.0.1 must not be treated as the same site")
    }

    func testRegistrableDomainIPv4WithPortAndPathStillMatchesBareAddress() {
        let bare = ExtensionEntryMatcher.registrableDomain(from: "127.0.0.1")
        let withPortAndPath = ExtensionEntryMatcher.registrableDomain(from: "http://127.0.0.1:8766/callback?x=1")
        XCTAssertEqual(bare, withPortAndPath)
    }

    // MARK: - registrableDomain: IPv6 literals
    //
    // NOTE: "::1", "[::1]", and "::2" below contain no ".", so they never
    // reach the split-by-"." / label logic at all — they hit the
    // pre-existing `guard labels.count >= 2 else { return resolvedHost }`
    // single-label passthrough (already on master, unrelated to this fix)
    // and are returned whole from there. These cases do NOT exercise the
    // IPv6 branch above; deleting that branch entirely still leaves them
    // passing. The IPv4-mapped dotted forms below ("::ffff:127.0.0.1" etc.)
    // are what actually exercise it, because they contain "." and would
    // otherwise fall into the IPv4-collapse path.

    func testRegistrableDomainIPv6BracketedAndUnbracketedFormsAreEqual() {
        let unbracketed = ExtensionEntryMatcher.registrableDomain(from: "[::1]")
        let bracketedInUrl = ExtensionEntryMatcher.registrableDomain(from: "http://[::1]:8080/path")
        XCTAssertEqual(unbracketed, bracketedInUrl, "::1 and [::1] must compare equal")
    }

    func testRegistrableDomainIPv6DiffersFromDifferentAddress() {
        let loopback = ExtensionEntryMatcher.registrableDomain(from: "http://[::1]/")
        let other = ExtensionEntryMatcher.registrableDomain(from: "http://[::2]/")
        XCTAssertNotEqual(loopback, other, "::1 and ::2 must not be treated as the same site")
    }

    func testRegistrableDomainDottedIPv4MappedIPv6AddressesAreDistinct() {
        // ::ffff:127.0.0.1 and ::ffff:192.168.0.1 are the IPv4-mapped IPv6
        // forms of the two hosts from the original bug report. Unlike
        // "::1"/"::2" above, these contain "." and so are only kept apart
        // by the IPv6 branch returning them whole before the dot-splitting
        // IPv4/DNS logic ever runs.
        let loopback = ExtensionEntryMatcher.registrableDomain(from: "http://[::ffff:127.0.0.1]/")
        let privateAddr = ExtensionEntryMatcher.registrableDomain(from: "http://[::ffff:192.168.0.1]/")
        XCTAssertNotEqual(
            loopback, privateAddr,
            "::ffff:127.0.0.1 and ::ffff:192.168.0.1 (IPv4-mapped forms of 127.0.0.1 and 192.168.0.1) must not be treated as the same site"
        )
    }

    func testRegistrableDomainDottedIPv4MappedIPv6ThirdAddressIsDistinct() {
        let a = ExtensionEntryMatcher.registrableDomain(from: "http://[::ffff:127.0.0.1]/")
        let b = ExtensionEntryMatcher.registrableDomain(from: "http://[::ffff:192.168.0.1]/")
        let c = ExtensionEntryMatcher.registrableDomain(from: "http://[::ffff:10.0.0.1]/")
        XCTAssertNotEqual(a, c, "::ffff:127.0.0.1 and ::ffff:10.0.0.1 must not be treated as the same site")
        XCTAssertNotEqual(b, c, "::ffff:192.168.0.1 and ::ffff:10.0.0.1 must not be treated as the same site")
    }

    // MARK: - registrableDomain: trailing DNS-root dot

    func testRegistrableDomainIPv4TrailingDotMatchesWithoutTrailingDot() {
        let withDot = ExtensionEntryMatcher.registrableDomain(from: "http://127.0.0.1./")
        let withoutDot = ExtensionEntryMatcher.registrableDomain(from: "http://127.0.0.1/")
        XCTAssertEqual(withDot, withoutDot, "127.0.0.1. and 127.0.0.1 name the same host and must compare equal")
    }

    func testRegistrableDomainTrailingDotDomainBehaviorUnchanged() {
        XCTAssertEqual(ExtensionEntryMatcher.registrableDomain(from: "https://example.com./path"), "example.com")
    }

    // MARK: - registrableDomain: localhost stays distinct from IP literals

    func testRegistrableDomainLocalhostStillMatchesLocalhost() {
        XCTAssertEqual(ExtensionEntryMatcher.registrableDomain(from: "http://localhost:8080/"), "localhost")
    }

    func testRegistrableDomainLocalhostDiffersFromLoopbackIPv4() {
        let localhost = ExtensionEntryMatcher.registrableDomain(from: "http://localhost/")
        let loopback = ExtensionEntryMatcher.registrableDomain(from: "http://127.0.0.1/")
        XCTAssertNotEqual(localhost, loopback, "localhost and 127.0.0.1 are different hosts and must stay so")
    }

    // MARK: - matchingEntries: real entry point for the reported bug

    func testMatchingEntriesDoesNotOfferPrivateAddressEntryOnLoopback() {
        let entry = makeEntry(url: "http://192.168.0.1/admin", title: "Router Admin")
        let group = makeGroup(entries: [entry])

        let matches = ExtensionEntryMatcher.matchingEntries(in: group, forURL: "http://127.0.0.1:8766/login")

        XCTAssertTrue(matches.isEmpty, "an entry saved for 192.168.0.1 must not be offered on 127.0.0.1")
    }

    func testMatchingEntriesOffersPrivateAddressEntryOnItsOwnHost() {
        let entry = makeEntry(url: "http://192.168.0.1/admin", title: "Router Admin")
        let group = makeGroup(entries: [entry])

        let matches = ExtensionEntryMatcher.matchingEntries(in: group, forURL: "http://192.168.0.1/login")

        XCTAssertEqual(matches.map(\.uuid), [entry.uuid])
    }

    // MARK: - URIMatchMode: host

    func testHostModeMatchesExactHostAndPortCaseInsensitively() {
        var entry = makeEntry(url: "https://Example.com:8443/login")
        entry.uriMatchMode = .host
        let group = makeGroup(entries: [entry])
        XCTAssertEqual(
            ExtensionEntryMatcher.matchingEntries(in: group, forURL: "https://example.com:8443/anything").map(\.uuid),
            [entry.uuid]
        )
    }

    func testHostModeDoesNotMatchASubdomain() {
        var entry = makeEntry(url: "https://example.com")
        entry.uriMatchMode = .host
        let group = makeGroup(entries: [entry])
        XCTAssertTrue(ExtensionEntryMatcher.matchingEntries(in: group, forURL: "https://login.example.com").isEmpty)
    }

    func testHostModeDoesNotMatchADifferentPort() {
        var entry = makeEntry(url: "https://example.com:8443")
        entry.uriMatchMode = .host
        let group = makeGroup(entries: [entry])
        XCTAssertTrue(ExtensionEntryMatcher.matchingEntries(in: group, forURL: "https://example.com:9443").isEmpty)
    }

    func testHostModeComparesIPLiteralsWhole() {
        var entry = makeEntry(url: "http://192.168.0.1/admin")
        entry.uriMatchMode = .host
        let group = makeGroup(entries: [entry])
        XCTAssertEqual(
            ExtensionEntryMatcher.matchingEntries(in: group, forURL: "http://192.168.0.1/login").map(\.uuid),
            [entry.uuid]
        )
        XCTAssertTrue(ExtensionEntryMatcher.matchingEntries(in: group, forURL: "http://127.0.0.1/login").isEmpty)
    }

    // MARK: - URIMatchMode: exact

    func testExactModeMatchesOnlyTheIdenticalNormalizedURL() {
        var entry = makeEntry(url: "https://Example.com:443/Login?x=1")
        entry.uriMatchMode = .exact
        let group = makeGroup(entries: [entry])
        XCTAssertEqual(
            ExtensionEntryMatcher.matchingEntries(in: group, forURL: "https://example.com/Login?x=1").map(\.uuid),
            [entry.uuid],
            "default port 443 must drop out of both sides so they normalise identically"
        )
    }

    func testExactModeIsCaseSensitiveOnThePath() {
        var entry = makeEntry(url: "https://example.com/API/v2/Login")
        entry.uriMatchMode = .exact
        let group = makeGroup(entries: [entry])
        XCTAssertTrue(
            ExtensionEntryMatcher.matchingEntries(in: group, forURL: "https://example.com/api/v2/login").isEmpty,
            "a case-sensitive API path must not fold to lowercase"
        )
    }

    func testExactModeDoesNotMatchADifferentPath() {
        var entry = makeEntry(url: "https://example.com/app")
        entry.uriMatchMode = .exact
        let group = makeGroup(entries: [entry])
        XCTAssertTrue(ExtensionEntryMatcher.matchingEntries(in: group, forURL: "https://example.com/app/extra").isEmpty)
    }

    // MARK: - URIMatchMode: starts-with

    func testStartsWithModeMatchesAnyPageUnderThePrefix() {
        var entry = makeEntry(url: "https://example.com/app")
        entry.uriMatchMode = .startsWith
        let group = makeGroup(entries: [entry])
        XCTAssertEqual(
            ExtensionEntryMatcher.matchingEntries(in: group, forURL: "https://example.com/app/settings").map(\.uuid),
            [entry.uuid]
        )
    }

    func testStartsWithModeAcceptsTheDocumentedPrefixOverMatch() {
        // The accepted trade-off from Decision 9: a plain string prefix, not a
        // path-boundary-aware one, so "…/app" also matches "…/app-legacy".
        var entry = makeEntry(url: "https://example.com/app")
        entry.uriMatchMode = .startsWith
        let group = makeGroup(entries: [entry])
        XCTAssertEqual(
            ExtensionEntryMatcher.matchingEntries(in: group, forURL: "https://example.com/app-legacy").map(\.uuid),
            [entry.uuid]
        )
    }

    func testStartsWithModeDoesNotMatchAShorterURL() {
        var entry = makeEntry(url: "https://example.com/app/settings")
        entry.uriMatchMode = .startsWith
        let group = makeGroup(entries: [entry])
        XCTAssertTrue(ExtensionEntryMatcher.matchingEntries(in: group, forURL: "https://example.com/app").isEmpty)
    }

    // MARK: - URIMatchMode: never

    func testNeverModeEntryNeverMatchesAnyURL() {
        var entry = makeEntry(url: "https://example.com")
        entry.uriMatchMode = .never
        let group = makeGroup(entries: [entry])
        XCTAssertTrue(ExtensionEntryMatcher.matchingEntries(in: group, forURL: "https://example.com").isEmpty)
    }

    // MARK: - Every mode: empty URL matches nothing

    func testEveryModeTreatsAnEmptyTargetURLAsNoMatch() {
        for mode in URIMatchMode.allCases {
            var entry = makeEntry(url: "https://example.com")
            entry.uriMatchMode = mode
            let group = makeGroup(entries: [entry])
            XCTAssertTrue(
                ExtensionEntryMatcher.matchingEntries(in: group, forURL: "").isEmpty,
                "\(mode) must not match an empty page URL"
            )
        }
    }

    func testEveryModeTreatsAnEntryWithNoStoredURLAsNoMatch() {
        for mode in URIMatchMode.allCases {
            var entry = makeEntry(url: "")
            entry.uriMatchMode = mode
            let group = makeGroup(entries: [entry])
            XCTAssertTrue(
                ExtensionEntryMatcher.matchingEntries(in: group, forURL: "https://example.com").isEmpty,
                "\(mode) must not match an entry with no stored URL"
            )
        }
    }
}
