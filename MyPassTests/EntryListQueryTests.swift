import XCTest
import MyPassKit
@testable import MyPass

final class EntryListQueryTests: XCTestCase {
    private func entry(_ title: String) -> KdbxEntry {
        let now = Date()
        var entry = KdbxEntry(uuid: UUID(), iconID: 0, fields: [], creationTime: now, lastModificationTime: now,
                              lastAccessTime: now, locationChanged: now, history: [])
        entry.title = title
        return entry
    }

    private func group(_ title: String, entries: [KdbxEntry], children: [KdbxGroup] = []) -> KdbxGroup {
        let now = Date()
        return KdbxGroup(uuid: UUID(), name: title, iconID: 0, creationTime: now, lastModificationTime: now,
                         locationChanged: now, entries: entries, subgroups: children)
    }

    func testGroupListAndOverviewQueryUseDirectEntriesButSearchAcrossSiblingGroups() {
        let direct = entry("Direct")
        let nested = entry("Needle nested")
        let siblingEntry = entry("Needle sibling")
        let selected = group("Selected", entries: [direct], children: [group("Nested", entries: [nested])])
        let root = group("Root", entries: [], children: [selected, group("Sibling", entries: [siblingEntry])])
        let db = KdbxDatabase(rootGroup: root, deletedObjects: [])
        let navigation = NavigationState()
        navigation.selectedGroupID = selected.uuid
        XCTAssertEqual(EntryListQuery.currentGroup(in: root, selectedID: selected.uuid).uuid, selected.uuid)
        XCTAssertEqual(EntryListQuery.entries(root: root, database: db, navigation: navigation).map(\.uuid), [direct.uuid])
        navigation.searchText = "Needle"
        XCTAssertEqual(EntryListQuery.entries(root: root, database: db, navigation: navigation).map(\.uuid), [nested.uuid, siblingEntry.uuid])
    }

    func testCategorySearchFiltersCategoryAndExcludesTrash() {
        var address = entry("Needle address")
        address.entryType = .address
        var trashed = entry("Needle deleted address")
        trashed.entryType = .address
        let root = group("Root", entries: [entry("Needle login"), address])
        var db = KdbxDatabase(rootGroup: root, deletedObjects: [])
        let bin = GroupTreeOperations.recycleBinGroup(in: root, recycleBinGroupUUID: &db.recycleBinGroupUUID)
        bin.entries.append(trashed)
        let navigation = NavigationState()
        navigation.selectSmartCategory(.addresses)
        navigation.searchText = "Needle"
        XCTAssertEqual(EntryListQuery.entries(root: root, database: db, navigation: navigation).map(\.uuid), [address.uuid])
        navigation.selectSmartCategory(.deleted)
        XCTAssertEqual(EntryListQuery.entries(root: root, database: db, navigation: navigation).map(\.uuid), [trashed.uuid])
        navigation.searchText = "No match"
        XCTAssertTrue(EntryListQuery.entries(root: root, database: db, navigation: navigation).isEmpty)
    }

    func testHistoryAndMissingGroupBehaviorMatchesList() {
        let visible = entry("Visible")
        let history = group("History", entries: [entry("Generated")])
        history.uuid = PasswordGeneratorHistoryStore.groupID
        let root = group("Root", entries: [visible], children: [history])
        let db = KdbxDatabase(rootGroup: root, deletedObjects: [])
        let navigation = NavigationState()
        navigation.selectedGroupID = UUID()
        XCTAssertEqual(EntryListQuery.currentGroup(in: root, selectedID: navigation.selectedGroupID).uuid, root.uuid)
        XCTAssertEqual(EntryListQuery.entries(root: root, database: db, navigation: navigation).map(\.uuid), [visible.uuid])
        navigation.selectedGroupID = history.uuid
        navigation.selectSmartCategory(.all)
        XCTAssertTrue(EntryListQuery.entries(root: root, database: db, navigation: navigation).isEmpty)
    }

    func testSecurityRetainsPriorCategoryOrGroupScopeForOverviewCount() {
        var address = entry("Address")
        address.entryType = .address
        let selected = group("Group", entries: [entry("Login")])
        let root = group("Root", entries: [address], children: [selected])
        let db = KdbxDatabase(rootGroup: root, deletedObjects: [])
        let navigation = NavigationState()
        navigation.selectedGroupID = selected.uuid
        navigation.selectSmartCategory(.security)
        XCTAssertEqual(EntryListQuery.entries(root: root, database: db, navigation: navigation).map(\.uuid), selected.entries.map(\.uuid))
        navigation.searchText = "Address"
        XCTAssertEqual(EntryListQuery.entries(root: root, database: db, navigation: navigation).map(\.uuid), [address.uuid])
        navigation.searchText = ""
        navigation.selectSmartCategory(.addresses)
        navigation.selectSmartCategory(.security)
        XCTAssertEqual(EntryListQuery.entries(root: root, database: db, navigation: navigation).map(\.uuid), [address.uuid])
    }
}
