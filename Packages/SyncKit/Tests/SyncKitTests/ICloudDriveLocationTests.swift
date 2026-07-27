import XCTest
@testable import SyncKit

final class ICloudDriveLocationTests: XCTestCase {
    func testRootURLEndsWithMobileDocumentsCloudDocs() throws {
        let root = try XCTUnwrap(ICloudDriveLocation.iCloudDriveRootURL)
        XCTAssertTrue(root.path.hasSuffix("/Library/Mobile Documents/com~apple~CloudDocs"), root.path)
        XCTAssertTrue(root.path.hasPrefix("/"), root.path)
    }

    func testRootURLIsNotInsideTheSandboxContainer() throws {
        let root = try XCTUnwrap(ICloudDriveLocation.iCloudDriveRootURL)
        XCTAssertFalse(root.path.contains("/Library/Containers/"), root.path)
    }

    func testIsDescendantOrSameAcceptsTheRootItself() {
        let root = URL(fileURLWithPath: "/Users/tester/Library/Mobile Documents/com~apple~CloudDocs")
        XCTAssertTrue(ICloudDriveLocation.isDescendantOrSame(root, of: root))
    }

    func testIsDescendantOrSameAcceptsNestedFolder() {
        let root = URL(fileURLWithPath: "/Users/tester/Library/Mobile Documents/com~apple~CloudDocs")
        let nested = root.appendingPathComponent("MyPass").appendingPathComponent("vaults")
        XCTAssertTrue(ICloudDriveLocation.isDescendantOrSame(nested, of: root))
    }

    func testIsDescendantOrSameNormalizesRelativeComponents() {
        let root = URL(fileURLWithPath: "/Users/tester/Library/Mobile Documents/com~apple~CloudDocs")
        let noisy = URL(fileURLWithPath: "/Users/tester/Library/Mobile Documents/com~apple~CloudDocs/MyPass/../MyPass")
        XCTAssertTrue(ICloudDriveLocation.isDescendantOrSame(noisy, of: root))
    }

    func testIsDescendantOrSameRejectsSiblingFolder() {
        let root = URL(fileURLWithPath: "/Users/tester/Library/Mobile Documents/com~apple~CloudDocs")
        let sibling = URL(fileURLWithPath: "/Users/tester/Library/Mobile Documents/com~apple~Keynote")
        XCTAssertFalse(ICloudDriveLocation.isDescendantOrSame(sibling, of: root))
    }

    func testIsDescendantOrSameRejectsParentFolder() {
        let root = URL(fileURLWithPath: "/Users/tester/Library/Mobile Documents/com~apple~CloudDocs")
        let parent = URL(fileURLWithPath: "/Users/tester/Library/Mobile Documents")
        XCTAssertFalse(ICloudDriveLocation.isDescendantOrSame(parent, of: root))
    }

    func testIsDescendantOrSameRejectsPrefixLookalikeName() {
        let root = URL(fileURLWithPath: "/Users/tester/Library/Mobile Documents/com~apple~CloudDocs")
        let lookalike = URL(fileURLWithPath: "/Users/tester/Library/Mobile Documents/com~apple~CloudDocsBackup")
        XCTAssertFalse(ICloudDriveLocation.isDescendantOrSame(lookalike, of: root))
    }

    func testIsInsideICloudDriveAcceptsTheResolvedRoot() throws {
        let root = try XCTUnwrap(ICloudDriveLocation.iCloudDriveRootURL)
        XCTAssertTrue(ICloudDriveLocation.isInsideICloudDrive(root.appendingPathComponent("MyPass")))
    }

    func testIsInsideICloudDriveRejectsTempDirectory() {
        XCTAssertFalse(ICloudDriveLocation.isInsideICloudDrive(URL(fileURLWithPath: "/tmp/mypass")))
    }
}
