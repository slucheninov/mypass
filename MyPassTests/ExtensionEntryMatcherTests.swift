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
}
