import XCTest
import MyPassKit
@testable import MyPass

/// The Recycle Bin is the one group whose name the UI replaces with a localized label. The
/// stored name is data and must never change; every other group name is the user's own and is
/// shown exactly as stored.
final class RecycleBinDisplayNameTests: XCTestCase {
    private func makeGroup(name: String) -> KdbxGroup {
        let now = Date()
        return KdbxGroup(uuid: UUID(), name: name, iconID: 0, creationTime: now, lastModificationTime: now, locationChanged: now, entries: [], subgroups: [])
    }

    func testTrackedRecycleBinShowsTheLocalizedLabelButKeepsItsStoredName() {
        let bin = makeGroup(name: "Bin")

        let shown = GroupTreeOperations.displayName(for: bin, recycleBinGroupUUID: bin.uuid)

        XCTAssertEqual(shown, GroupTreeOperations.recycleBinDisplayName)
        XCTAssertEqual(bin.name, "Bin", "Showing the label must not rename the stored group")
    }

    func testAnotherGroupNamedRecycleBinIsShownVerbatimWhenAUUIDIsTracked() {
        let trackedBin = makeGroup(name: "Bin")
        let lookalike = makeGroup(name: GroupTreeOperations.recycleBinGroupName)

        let shown = GroupTreeOperations.displayName(for: lookalike, recycleBinGroupUUID: trackedBin.uuid)

        XCTAssertEqual(shown, lookalike.name)
    }

    func testNameFallbackAppliesOnlyWhenNoUUIDIsTracked() {
        let named = makeGroup(name: GroupTreeOperations.recycleBinGroupName)

        XCTAssertEqual(
            GroupTreeOperations.displayName(for: named, recycleBinGroupUUID: nil),
            GroupTreeOperations.recycleBinDisplayName
        )
    }

    func testOrdinaryGroupNameIsNeverTranslated() {
        for name in ["Work", "Корзина2"] {
            let group = makeGroup(name: name)
            XCTAssertEqual(GroupTreeOperations.displayName(for: group, recycleBinGroupUUID: UUID()), name)
            XCTAssertEqual(GroupTreeOperations.displayName(for: group, recycleBinGroupUUID: nil), name)
        }
    }

    func testStoredConstantStaysEnglish() {
        XCTAssertEqual(GroupTreeOperations.recycleBinGroupName, "Recycle Bin")
    }
}
