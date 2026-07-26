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

    // Regression test for the review finding on Task 12: EntryListView.displayedEntries
    // originally passed `currentGroup` (the currently selected group) as the `in:` argument
    // to EntrySearch.entries(in:matching:), instead of `rootGroup` (the true database root).
    // Because EntrySearch.entries's internal findRoot(from:) is a documented no-op passthrough
    // (KdbxGroup has no parent pointer by design), passing a subgroup as `in:` silently narrows
    // "global" search to that subgroup's own subtree, missing sibling branches — contradicting
    // the design spec's requirement that search be global across the whole database.
    //
    // This test pins EntrySearch's own correct multi-branch traversal behavior: given a root
    // with two SIBLING subgroups, each holding a different entry, searching from the root must
    // find an entry that lives only under the sibling branch not directly related to the first.
    // NOTE: this cannot exercise the actual regression at the EntryListView call-site level
    // (passing rootGroup vs. currentGroup) directly, since EntryListView is a SwiftUI view with
    // no XCTest target here. It documents the correct EntrySearch behavior the fix at the
    // call site (EntryListView.displayedEntries) now correctly relies on, so that an accidental
    // revert of that call-site fix is easier to diagnose against this pinned expectation.
    func testEntriesInRootFindsEntryInSiblingSubgroupNotJustSelectedBranch() {
        let now = Date()
        let entryInFirstSubgroup = makeEntry(title: "Alpha Entry")
        let firstSubgroup = KdbxGroup(uuid: UUID(), name: "First", iconID: 0, creationTime: now, lastModificationTime: now, locationChanged: now, entries: [entryInFirstSubgroup], subgroups: [])

        let entryInSiblingSubgroup = makeEntry(title: "Beta Entry", login: "beta-user")
        let siblingSubgroup = KdbxGroup(uuid: UUID(), name: "Sibling", iconID: 0, creationTime: now, lastModificationTime: now, locationChanged: now, entries: [entryInSiblingSubgroup], subgroups: [])

        let root = KdbxGroup(uuid: UUID(), name: "Root", iconID: 0, creationTime: now, lastModificationTime: now, locationChanged: now, entries: [], subgroups: [firstSubgroup, siblingSubgroup])

        let result = EntrySearch.entries(in: root, matching: "beta")
        XCTAssertEqual(result.map(\.title), ["Beta Entry"])
    }

    func testNavigationStateDefaultsSelectedSmartCategoryToAll() {
        let state = NavigationState()
        XCTAssertEqual(state.selectedSmartCategory, .all)
    }
}
