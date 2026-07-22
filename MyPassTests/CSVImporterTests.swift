import XCTest
import MyPassKit
@testable import MyPass

final class CSVImporterTests: XCTestCase {
    func testParsesStandardColumns() throws {
        let csv = """
        title,url,username,password,notes
        GitHub,https://github.com,alice,s3cret,work account
        """
        let entries = try CSVImporter.parse(csvData: Data(csv.utf8))
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.title, "GitHub")
        XCTAssertEqual(entries.first?.url, "https://github.com")
        XCTAssertEqual(entries.first?.login, "alice")
        XCTAssertEqual(entries.first?.password, "s3cret")
        XCTAssertEqual(entries.first?.notes, "work account")
    }

    func testColumnHeadersAreCaseInsensitive() throws {
        let csv = """
        Title,URL,Username,Password,Notes
        GitHub,https://github.com,alice,s3cret,work account
        """
        let entries = try CSVImporter.parse(csvData: Data(csv.utf8))
        XCTAssertEqual(entries.first?.title, "GitHub")
    }

    func testUnknownColumnsAreIgnored() throws {
        let csv = """
        title,username,password,favoriteColor
        GitHub,alice,s3cret,blue
        """
        let entries = try CSVImporter.parse(csvData: Data(csv.utf8))
        XCTAssertEqual(entries.first?.title, "GitHub")
        XCTAssertEqual(entries.first?.login, "alice")
    }

    func testMissingRequiredColumnThrows() {
        let csv = """
        title,password
        GitHub,s3cret
        """
        XCTAssertThrowsError(try CSVImporter.parse(csvData: Data(csv.utf8))) { error in
            XCTAssertEqual(error as? CSVImportError, .missingRequiredColumn("username"))
        }
    }

    func testParsesCRLFLineEndingsWithoutMissingColumnError() throws {
        let csv = "title,username,password\r\nGitHub,alice,s3cret\r\n"
        let entries = try CSVImporter.parse(csvData: Data(csv.utf8))
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.title, "GitHub")
        XCTAssertEqual(entries.first?.login, "alice")
        XCTAssertEqual(entries.first?.password, "s3cret")
    }

    func testMixedCRLFAndLFLineEndingsDoNotLeakCarriageReturn() throws {
        let csv = "title,username,password\r\nGitHub,alice,s3cret\r\nBitbucket,bob,hunter2\n"
        let entries = try CSVImporter.parse(csvData: Data(csv.utf8))
        XCTAssertEqual(entries.count, 2)
        for entry in entries {
            XCTAssertFalse(entry.title.contains("\r"))
            XCTAssertFalse(entry.login.contains("\r"))
            XCTAssertFalse(entry.password.contains("\r"))
        }
        XCTAssertEqual(entries.first?.password, "s3cret")
        XCTAssertEqual(entries.last?.password, "hunter2")
    }
}
