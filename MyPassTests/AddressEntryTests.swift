import XCTest
import MyPassKit
import ExtensionBridgeKit
@testable import MyPass

final class AddressEntryTests: XCTestCase {
    private func addressEntry() -> KdbxEntry {
        AddressEntryEditing.savedEntry(existing: nil, title: "", address: ExtensionAddress(
            label: "Work", givenName: "Ada", familyName: "Example", organization: "Example Company",
            addressLine1: "12 Example Street", addressLine2: "Suite 2", city: "Warsaw", region: "Mazovia",
            postalCode: "00-001", countryCode: "PL", countryName: "Poland", phone: "+48000000000", email: "ada@example.com"
        ), favorite: true, notes: "Delivery instructions")
    }

    private func database(_ entries: [KdbxEntry]) -> KdbxDatabase {
        let now = Date()
        return KdbxDatabase(rootGroup: KdbxGroup(uuid: UUID(), name: "Root", iconID: 0,
            creationTime: now, lastModificationTime: now, locationChanged: now, entries: entries, subgroups: []), deletedObjects: [])
    }

    func testCreationDefaultsTitleAndProtectsAllStructuredFields() {
        let entry = addressEntry()
        XCTAssertEqual(entry.entryType, .address)
        XCTAssertEqual(entry.title, "Work")
        XCTAssertEqual(entry.address.fullName, "Ada Example")
        XCTAssertEqual(entry.storedAddress.fullName, "")
        XCTAssertEqual(entry.address.countryCode, "PL")
        XCTAssertEqual(entry.address.id, entry.uuid.uuidString)
        XCTAssertTrue(entry.isFavorite)
        XCTAssertTrue(entry.additionalFields.isEmpty)
        XCTAssertTrue(entry.fields.filter { KdbxEntry.addressFieldKeys.contains($0.key) }.allSatisfy(\.isProtected))
        XCTAssertTrue(KdbxEntry.addressFieldKeys.isSubset(of: KdbxEntry.standardFieldKeys))
    }

    func testEditPreservesIdentityHistoryCustomFieldsAndClearsOptionalData() {
        var original = addressEntry()
        original.fields.append(KdbxField(key: "Custom", value: "kept", isProtected: true))
        var historical = original
        historical.title = "Earlier"
        original.history = [historical]
        var edited = original.address
        edited.email = ""
        edited.fullName = "An explicit display name"
        let saved = AddressEntryEditing.savedEntry(existing: original, title: "Office", address: edited, favorite: false, notes: "")
        XCTAssertEqual(saved.uuid, original.uuid)
        XCTAssertEqual(saved.creationTime, original.creationTime)
        XCTAssertEqual(saved.locationChanged, original.locationChanged)
        XCTAssertEqual(saved.history, original.history)
        XCTAssertEqual(saved.additionalFields, original.additionalFields)
        XCTAssertEqual(saved.address.fullName, "An explicit display name")
        XCTAssertEqual(saved.address.email, "")
        XCTAssertEqual(saved.address.givenName, "Ada")
        XCTAssertFalse(saved.isFavorite)
    }

    func testFullNameIsNeverSplitAndMissingLabelFailsToOther() {
        var entry = addressEntry()
        entry.address = ExtensionAddress(label: "Unknown", fullName: "A Compound Family Name")
        XCTAssertEqual(entry.address.label, "Other")
        XCTAssertEqual(entry.address.givenName, "")
        XCTAssertEqual(entry.address.familyName, "")
    }

    func testAddressCategoryCountSearchAndNestedTrashExclusion() {
        let live = addressEntry()
        var deleted = addressEntry()
        deleted.title = "Deleted"
        var db = database([live])
        let bin = GroupTreeOperations.recycleBinGroup(in: db.rootGroup, recycleBinGroupUUID: &db.recycleBinGroupUUID)
        let nested = database([deleted]).rootGroup
        bin.subgroups.append(nested)
        XCTAssertEqual(EntryCategoryFilter.entries(for: .addresses, in: db).map(\.uuid), [live.uuid])
        XCTAssertEqual(SmartCategory.addresses.countDisplay(for: db), "1")
        for query in ["Warsaw", "Suite 2", "Mazovia", "00-001", "ada@example.com", "Poland"] {
            XCTAssertTrue(EntrySearch.matches(entry: live, query: query), query)
        }
        XCTAssertFalse(EntrySearch.matches(entry: live, query: "missing-value"))
    }

    func testKdbxRoundTripPreservesProtectedAddressAndCustomFields() throws {
        var entry = addressEntry()
        entry.fields.append(KdbxField(key: "Custom", value: "kept", isProtected: true))
        let data = try database([entry]).save(password: "test-fixture-password", cipher: .aes256, compression: .gzip)
        let reopened = try KdbxDatabase.open(data: data, password: "test-fixture-password")
        let restored = try XCTUnwrap(reopened.rootGroup.entries.first)
        XCTAssertEqual(restored.address, entry.address)
        XCTAssertEqual(restored.additionalFields, entry.additionalFields)
        XCTAssertEqual(restored.entryType, .address)
        XCTAssertTrue(restored.fields.filter { KdbxEntry.addressFieldKeys.contains($0.key) }.allSatisfy(\.isProtected))
    }
}
