import XCTest
@testable import MyPassKit

/// Proves the bidirectional interoperability claim literally, not just by
/// inference from known-answer vectors: a vault saved by `KdbxDatabase.save`
/// must open in a genuinely independent implementation. Skips (does not
/// fail) when `python3`/`pykeepass` aren't available — matching this
/// repo's convention at `Packages/SyncKit/Tests/SyncKitTests/CitadelDependencySmokeTests.swift`.
final class PykeepassBidirectionalTests: XCTestCase {
    override func setUpWithError() throws {
        let check = Process()
        check.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        check.arguments = ["python3", "-c", "import pykeepass"]
        check.standardOutput = Pipe()
        check.standardError = Pipe()
        try check.run()
        check.waitUntilExit()
        try XCTSkipUnless(
            check.terminationStatus == 0,
            "python3 with pykeepass not available — install with 'pip3 install --user pykeepass' to run this bidirectional interop test."
        )
    }

    func testMyPassWrittenVaultOpensInPykeepass() throws {
        let entry = KdbxEntry(
            uuid: UUID(), iconID: 0,
            fields: [
                KdbxField(key: "Title", value: "Round Trip Entry", isProtected: false),
                KdbxField(key: "UserName", value: "roundtrip-user", isProtected: false),
                KdbxField(key: "Password", value: "roundtrip-pass", isProtected: true),
            ],
            creationTime: Date(), lastModificationTime: Date(), lastAccessTime: Date(), locationChanged: Date(),
            history: []
        )
        let root = KdbxGroup(uuid: UUID(), name: "Root", iconID: 0, creationTime: Date(), lastModificationTime: Date(), locationChanged: Date(), entries: [entry], subgroups: [])
        let database = KdbxDatabase(rootGroup: root, deletedObjects: [])
        let saved = try database.save(password: "RoundTripPass123", cipher: .aes256, compression: .gzip)

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".kdbx")
        try saved.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let script = """
        from pykeepass import PyKeePass
        kp = PyKeePass("\(tempURL.path)", password="RoundTripPass123")
        entry = kp.entries[0]
        assert entry.title == "Round Trip Entry", entry.title
        assert entry.username == "roundtrip-user", entry.username
        assert entry.password == "roundtrip-pass", entry.password
        print("PYKEEPASS_OK")
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-c", script]
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        try process.run()
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: outputData, encoding: .utf8) ?? ""

        XCTAssertEqual(process.terminationStatus, 0, "pykeepass failed to open a MyPass-written vault:\n\(output)")
        XCTAssertTrue(output.contains("PYKEEPASS_OK"), "unexpected pykeepass output:\n\(output)")
    }
}
