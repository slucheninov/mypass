import XCTest
import MyPassKit
@testable import MyPass

final class PasskeyCategoryTests: XCTestCase {
    private func entry(title: String, password: String = "") -> KdbxEntry {
        let now = Date()
        var entry = KdbxEntry(
            uuid: UUID(), iconID: 0, fields: [],
            creationTime: now, lastModificationTime: now, lastAccessTime: now,
            locationChanged: now, history: []
        )
        entry.title = title
        entry.password = password
        entry.passkeyCredentialId = Data([1, 2, 3])
        entry.passkeyPrivateKeyPEM = "fixture-key"
        return entry
    }

    private func group(name: String, entries: [KdbxEntry], uuid: UUID = UUID()) -> KdbxGroup {
        let now = Date()
        return KdbxGroup(
            uuid: uuid, name: name, iconID: 0,
            creationTime: now, lastModificationTime: now, locationChanged: now,
            entries: entries, subgroups: []
        )
    }

    func testPasskeyFilterAndCountIncludePasskeyOnlyAndMixedEntriesAndExcludeTrashAndHistory() {
        let only = entry(title: "Passkey only")
        let mixed = entry(title: "Password and passkey", password: "fixture-password")
        var missingKey = entry(title: "Missing key")
        missingKey.passkeyPrivateKeyPEM = nil
        var malformedID = entry(title: "Malformed ID")
        malformedID.setFieldValue("not base64!", forKey: "KPEX_PASSKEY_CREDENTIAL_ID", isProtected: true)
        var emptyKey = entry(title: "Empty key")
        emptyKey.passkeyPrivateKeyPEM = ""
        var emptyID = entry(title: "Empty ID")
        emptyID.passkeyCredentialId = Data()
        let root = group(name: "Root", entries: [only, missingKey, malformedID, emptyKey, emptyID])
        root.subgroups.append(group(name: "Nested", entries: [mixed]))
        root.subgroups.append(group(
            name: "History", entries: [entry(title: "Generated history")],
            uuid: PasswordGeneratorHistoryStore.groupID
        ))
        var database = KdbxDatabase(rootGroup: root, deletedObjects: [])
        let bin = GroupTreeOperations.recycleBinGroup(in: root, recycleBinGroupUUID: &database.recycleBinGroupUUID)
        bin.entries.append(entry(title: "Deleted"))
        bin.subgroups.append(group(name: "Deleted group", entries: [entry(title: "Deleted nested")]))

        let matches = EntryCategoryFilter.entries(for: .passkeys, in: database)

        XCTAssertEqual(matches.map(\.uuid), [only.uuid, mixed.uuid])
        XCTAssertEqual(SmartCategory.passkeys.countDisplay(for: database), "2")
        XCTAssertEqual(matches.filter { EntrySearch.matches(entry: $0, query: "only") }.map(\.uuid), [only.uuid])
    }

    func testHasPasskeyRequiresBothNonemptyFieldsAndADecodableCredentialID() {
        var candidate = entry(title: "Candidate")
        XCTAssertTrue(candidate.hasPasskey)
        candidate.passkeyPrivateKeyPEM = ""
        XCTAssertFalse(candidate.hasPasskey)
        candidate.passkeyPrivateKeyPEM = "fixture-key"
        candidate.passkeyCredentialId = nil
        XCTAssertFalse(candidate.hasPasskey)
        candidate.passkeyCredentialId = Data()
        XCTAssertFalse(candidate.hasPasskey)
        candidate.setFieldValue("%%%", forKey: "KPEX_PASSKEY_CREDENTIAL_ID", isProtected: true)
        XCTAssertFalse(candidate.hasPasskey)
    }
}
