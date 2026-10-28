import XCTest
@testable import MyPass

final class ReleaseNotesLinkTests: XCTestCase {
    func testBuildsTheTagURLForTheCurrentVersion() {
        XCTAssertEqual(
            ReleaseNotesLink.url(forVersion: "0.4.2")?.absoluteString,
            "https://github.com/slucheninov/mypass/releases/tag/v0.4.2"
        )
    }

    func testRejectsNonSemanticVersions() {
        // Mirrors what `SemanticVersion(string:)` refuses: no link beats a link to a tag
        // that cannot exist.
        for candidate in ["", "unknown", "0.4", "0.4.2-beta", "1.0.0+build", "0.4.2.1", "../0.4.2"] {
            XCTAssertNil(ReleaseNotesLink.url(forVersion: candidate), "\(candidate) must not produce a link")
        }
    }

    func testAcceptsASingleLeadingVAndNormalisesIt() {
        // `SemanticVersion(string:)` tolerates one leading `v`; the tag must still carry exactly one.
        XCTAssertEqual(
            ReleaseNotesLink.url(forVersion: "v0.4.2")?.absoluteString,
            "https://github.com/slucheninov/mypass/releases/tag/v0.4.2"
        )
    }

    func testRepositoryMatchesTheUpdateFeed() throws {
        let url = try XCTUnwrap(ReleaseNotesLink.url(forVersion: "0.4.2"))
        XCTAssertEqual(url.host, "github.com")
        XCTAssertTrue(url.path.hasPrefix("/" + GitHubReleaseClient.defaultRepository))
    }
}
