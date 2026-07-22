import XCTest
import MyPassKit
@testable import MyPass

final class NavigationStateSearchTests: XCTestCase {
    func makeEntry(title: String, login: String = "", url: String = "", notes: String = "") -> KdbxEntry {
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
        entry.login = login
        entry.url = url
        entry.notes = notes
        return entry
    }

    func testMatchesTitleCaseInsensitive() {
        let entry = makeEntry(title: "GitHub")
        XCTAssertTrue(EntrySearch.matches(entry: entry, query: "github"))
        XCTAssertTrue(EntrySearch.matches(entry: entry, query: "HUB"))
    }

    func testMatchesLoginURLNotes() {
        let entry = makeEntry(title: "x", login: "alice@example.com", url: "https://example.com", notes: "work account")
        XCTAssertTrue(EntrySearch.matches(entry: entry, query: "alice"))
        XCTAssertTrue(EntrySearch.matches(entry: entry, query: "example.com"))
        XCTAssertTrue(EntrySearch.matches(entry: entry, query: "work"))
    }

    func testNoMatchReturnsFalse() {
        let entry = makeEntry(title: "GitHub")
        XCTAssertFalse(EntrySearch.matches(entry: entry, query: "gitlab"))
    }

    func testEmptyQueryMatchesEverything() {
        let entry = makeEntry(title: "GitHub")
        XCTAssertTrue(EntrySearch.matches(entry: entry, query: ""))
    }

    func testEntriesInGroupMatchingEmptyQueryReturnsOnlyGroupOwnEntries() {
        let now = Date()
        let child = makeEntry(title: "Child Entry")
        let subgroup = KdbxGroup(uuid: UUID(), name: "Sub", iconID: 0, creationTime: now, lastModificationTime: now, locationChanged: now, entries: [child], subgroups: [])
        let rootEntry = makeEntry(title: "Root Entry")
        let root = KdbxGroup(uuid: UUID(), name: "Root", iconID: 0, creationTime: now, lastModificationTime: now, locationChanged: now, entries: [rootEntry], subgroups: [subgroup])

        let result = EntrySearch.entries(in: root, matching: "")
        XCTAssertEqual(result.map(\.title), ["Root Entry"])
    }

    func testEntriesInGroupMatchingNonEmptyQuerySearchesGlobally() {
        let now = Date()
        let child = makeEntry(title: "Child Entry")
        let subgroup = KdbxGroup(uuid: UUID(), name: "Sub", iconID: 0, creationTime: now, lastModificationTime: now, locationChanged: now, entries: [child], subgroups: [])
        let rootEntry = makeEntry(title: "Root Entry")
        let root = KdbxGroup(uuid: UUID(), name: "Root", iconID: 0, creationTime: now, lastModificationTime: now, locationChanged: now, entries: [rootEntry], subgroups: [subgroup])

        let result = EntrySearch.entries(in: root, matching: "child")
        XCTAssertEqual(result.map(\.title), ["Child Entry"])
    }
}
