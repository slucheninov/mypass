import XCTest
@testable import MyPass

final class VaultLocationChangeBookmarkTests: XCTestCase {
    func testBookmarkMutationsWhenMovingLocalToICloud() {
        var localBookmark: Data? = Data("local-file-bookmark".utf8)
        var iCloudBookmark: Data? = nil
        VaultLocationChangeSheet.applyBookmarkChanges(
            targetLocation: .iCloudDrive,
            chosenICloudFolderBookmark: Data("icloud-folder".utf8),
            localVaultFileBookmark: &localBookmark,
            iCloudFolderBookmark: &iCloudBookmark
        )
        XCTAssertNil(localBookmark)
        XCTAssertEqual(iCloudBookmark, Data("icloud-folder".utf8))
    }

    func testBookmarkMutationsWhenMovingICloudToLocal() {
        var localBookmark: Data? = nil
        var iCloudBookmark: Data? = Data("icloud-folder".utf8)
        VaultLocationChangeSheet.applyBookmarkChanges(
            targetLocation: .local,
            chosenICloudFolderBookmark: nil,
            localVaultFileBookmark: &localBookmark,
            iCloudFolderBookmark: &iCloudBookmark
        )
        XCTAssertNil(iCloudBookmark)
        XCTAssertNil(localBookmark)
    }
}
