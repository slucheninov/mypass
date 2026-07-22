import XCTest
@testable import MyPassKit

final class KdbxModelTests: XCTestCase {
    func testEntryHistoryStoresPastVersionsWithoutNestedHistory() {
        let past = KdbxEntry(
            uuid: UUID(), iconID: 0,
            fields: [KdbxField(key: "Password", value: "old-pass", isProtected: true)],
            creationTime: Date(timeIntervalSince1970: 0),
            lastModificationTime: Date(timeIntervalSince1970: 100),
            lastAccessTime: Date(timeIntervalSince1970: 100),
            locationChanged: Date(timeIntervalSince1970: 0),
            history: []
        )
        let current = KdbxEntry(
            uuid: past.uuid, iconID: 0,
            fields: [KdbxField(key: "Password", value: "new-pass", isProtected: true)],
            creationTime: Date(timeIntervalSince1970: 0),
            lastModificationTime: Date(timeIntervalSince1970: 200),
            lastAccessTime: Date(timeIntervalSince1970: 200),
            locationChanged: Date(timeIntervalSince1970: 0),
            history: [past]
        )

        XCTAssertEqual(current.history.count, 1)
        XCTAssertEqual(current.history[0].fields.first?.value, "old-pass")
        XCTAssertTrue(current.history[0].history.isEmpty)
    }

    func testGroupTreeHoldsEntriesAndSubgroups() {
        let entry = KdbxEntry(uuid: UUID(), iconID: 0, fields: [], creationTime: Date(), lastModificationTime: Date(), lastAccessTime: Date(), locationChanged: Date(), history: [])
        let child = KdbxGroup(uuid: UUID(), name: "Work", iconID: 1, creationTime: Date(), lastModificationTime: Date(), locationChanged: Date(), entries: [entry], subgroups: [])
        let root = KdbxGroup(uuid: UUID(), name: "Root", iconID: 0, creationTime: Date(), lastModificationTime: Date(), locationChanged: Date(), entries: [], subgroups: [child])

        XCTAssertEqual(root.subgroups.count, 1)
        XCTAssertEqual(root.subgroups[0].entries.count, 1)
        XCTAssertEqual(root.subgroups[0].name, "Work")
    }

    func testDeletedObjectStoresUuidAndTimestamp() {
        let uuid = UUID()
        let deletionTime = Date(timeIntervalSince1970: 12345)
        let deleted = KdbxDeletedObject(uuid: uuid, deletionTime: deletionTime)

        XCTAssertEqual(deleted.uuid, uuid)
        XCTAssertEqual(deleted.deletionTime, deletionTime)
    }

    // MARK: - KdbxGroup Equatable

    private func makeEntry(
        uuid: UUID = UUID(),
        fields: [KdbxField] = [],
        history: [KdbxEntry] = []
    ) -> KdbxEntry {
        KdbxEntry(
            uuid: uuid, iconID: 0, fields: fields,
            creationTime: Date(timeIntervalSince1970: 0),
            lastModificationTime: Date(timeIntervalSince1970: 0),
            lastAccessTime: Date(timeIntervalSince1970: 0),
            locationChanged: Date(timeIntervalSince1970: 0),
            history: history
        )
    }

    private func makeGroup(
        uuid: UUID = UUID(),
        name: String = "Group",
        iconID: Int = 0,
        entries: [KdbxEntry] = [],
        subgroups: [KdbxGroup] = []
    ) -> KdbxGroup {
        KdbxGroup(
            uuid: uuid, name: name, iconID: iconID,
            creationTime: Date(timeIntervalSince1970: 0),
            lastModificationTime: Date(timeIntervalSince1970: 0),
            locationChanged: Date(timeIntervalSince1970: 0),
            entries: entries, subgroups: subgroups
        )
    }

    func testIdenticalGroupTreesCompareEqual() {
        let sharedUUID = UUID()
        let entryUUID = UUID()
        let childUUID = UUID()

        func buildTree() -> KdbxGroup {
            let entry = makeEntry(uuid: entryUUID, fields: [KdbxField(key: "Password", value: "secret", isProtected: true)])
            let child = makeGroup(uuid: childUUID, name: "Work", entries: [entry])
            return makeGroup(uuid: sharedUUID, name: "Root", subgroups: [child])
        }

        let lhs = buildTree()
        let rhs = buildTree()

        XCTAssertEqual(lhs, rhs)
    }

    func testGroupsDifferingOnlyByNameCompareNotEqual() {
        let uuid = UUID()
        let lhs = makeGroup(uuid: uuid, name: "Root")
        let rhs = makeGroup(uuid: uuid, name: "Root-Renamed")

        XCTAssertNotEqual(lhs, rhs)
    }

    func testGroupsDifferingOnlyByNestedEntryCompareNotEqual() {
        let uuid = UUID()
        let entryUUID = UUID()
        let childUUID = UUID()

        let entryA = makeEntry(uuid: entryUUID, fields: [KdbxField(key: "Password", value: "secret-a", isProtected: true)])
        let entryB = makeEntry(uuid: entryUUID, fields: [KdbxField(key: "Password", value: "secret-b", isProtected: true)])

        let childA = makeGroup(uuid: childUUID, name: "Work", entries: [entryA])
        let childB = makeGroup(uuid: childUUID, name: "Work", entries: [entryB])

        let lhs = makeGroup(uuid: uuid, name: "Root", subgroups: [childA])
        let rhs = makeGroup(uuid: uuid, name: "Root", subgroups: [childB])

        XCTAssertNotEqual(lhs, rhs)
    }

    func testEmptyGroupsConstructAndCompareEqual() {
        let uuid = UUID()
        let lhs = makeGroup(uuid: uuid, name: "Empty")
        let rhs = makeGroup(uuid: uuid, name: "Empty")

        XCTAssertTrue(lhs.entries.isEmpty)
        XCTAssertTrue(lhs.subgroups.isEmpty)
        XCTAssertEqual(lhs, rhs)
    }

    // MARK: - Multi-level tree structure

    func testThreeLevelTreeStructureAndNestingDepth() {
        let leafEntry = makeEntry(fields: [KdbxField(key: "Password", value: "leaf-pass", isProtected: true)])
        let rootEntry = makeEntry(fields: [KdbxField(key: "Password", value: "root-pass", isProtected: true)])

        let subSubgroup = makeGroup(name: "SubSubgroup", entries: [leafEntry])
        let subgroup = makeGroup(name: "Subgroup", subgroups: [subSubgroup])
        let root = makeGroup(name: "Root", entries: [rootEntry], subgroups: [subgroup])

        // Depth/counts at root level.
        XCTAssertEqual(root.name, "Root")
        XCTAssertEqual(root.entries.count, 1)
        XCTAssertEqual(root.subgroups.count, 1)

        // Depth 2.
        let level2 = root.subgroups[0]
        XCTAssertEqual(level2.name, "Subgroup")
        XCTAssertEqual(level2.entries.count, 0)
        XCTAssertEqual(level2.subgroups.count, 1)

        // Depth 3 (leaf).
        let level3 = level2.subgroups[0]
        XCTAssertEqual(level3.name, "SubSubgroup")
        XCTAssertEqual(level3.entries.count, 1)
        XCTAssertEqual(level3.subgroups.count, 0)
        XCTAssertEqual(level3.entries[0].fields.first?.value, "leaf-pass")

        // Entries exist at more than one level (root and leaf).
        XCTAssertEqual(root.entries[0].fields.first?.value, "root-pass")
    }

    // MARK: - Entry history with multiple past versions

    func testEntryHistoryPreservesMultiplePastVersionsInAppendedOrder() {
        let entryUUID = UUID()
        let version1 = makeEntry(uuid: entryUUID, fields: [KdbxField(key: "Password", value: "v1", isProtected: true)])
        let version2 = makeEntry(uuid: entryUUID, fields: [KdbxField(key: "Password", value: "v2", isProtected: true)])
        let version3 = makeEntry(uuid: entryUUID, fields: [KdbxField(key: "Password", value: "v3", isProtected: true)])

        let current = makeEntry(
            uuid: entryUUID,
            fields: [KdbxField(key: "Password", value: "current", isProtected: true)],
            history: [version1, version2, version3]
        )

        XCTAssertEqual(current.history.count, 3)
        XCTAssertEqual(current.history[0].fields.first?.value, "v1")
        XCTAssertEqual(current.history[1].fields.first?.value, "v2")
        XCTAssertEqual(current.history[2].fields.first?.value, "v3")
        XCTAssertTrue(current.history.allSatisfy { $0.history.isEmpty })
    }

    // MARK: - Custom fields

    func testEntrySupportsMultipleHeterogeneousCustomFields() {
        let entry = makeEntry(fields: [
            KdbxField(key: "Title", value: "My Bank", isProtected: false),
            KdbxField(key: "UserName", value: "alice", isProtected: false),
            KdbxField(key: "Password", value: "hunter2", isProtected: true),
            KdbxField(key: "URL", value: "https://bank.example.com", isProtected: false),
            KdbxField(key: "TOTP Seed", value: "JBSWY3DPEHPK3PXP", isProtected: true),
            KdbxField(key: "Security Question", value: "What is your pet's name?", isProtected: false)
        ])

        XCTAssertEqual(entry.fields.count, 6)
        XCTAssertEqual(entry.fields.map(\.key), ["Title", "UserName", "Password", "URL", "TOTP Seed", "Security Question"])
        XCTAssertEqual(entry.fields.first(where: { $0.key == "TOTP Seed" })?.isProtected, true)
        XCTAssertEqual(entry.fields.first(where: { $0.key == "URL" })?.value, "https://bank.example.com")
    }
}
