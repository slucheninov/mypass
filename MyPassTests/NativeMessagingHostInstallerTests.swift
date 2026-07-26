import XCTest
@testable import MyPass

final class NativeMessagingHostInstallerTests: XCTestCase {
    var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MyPassNativeMessagingHostInstallerTests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testInstallWritesManifestWithExpectedShape() throws {
        try NativeMessagingHostInstaller.installIfNeeded(
            hostBinaryPath: "/usr/local/bin/ChromeHost",
            extensionID: "abcdefghijklmnop",
            directory: tempDir
        )
        let fileURL = tempDir.appendingPathComponent("com.mypass.chromehost.json")
        let data = try Data(contentsOf: fileURL)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["name"] as? String, "com.mypass.chromehost")
        XCTAssertEqual(object["path"] as? String, "/usr/local/bin/ChromeHost")
        XCTAssertEqual(object["type"] as? String, "stdio")
        let allowedOrigins = try XCTUnwrap(object["allowed_origins"] as? [String])
        XCTAssertEqual(allowedOrigins, ["chrome-extension://abcdefghijklmnop/"])
    }

    func testInstallCreatesDirectoryIfMissing() throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir.path))
        try NativeMessagingHostInstaller.installIfNeeded(
            hostBinaryPath: "/usr/local/bin/ChromeHost",
            extensionID: "abcdefghijklmnop",
            directory: tempDir
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.path))
    }

    func testInstallIsIdempotentWhenContentIsUnchanged() throws {
        try NativeMessagingHostInstaller.installIfNeeded(
            hostBinaryPath: "/usr/local/bin/ChromeHost", extensionID: "abcdefghijklmnop", directory: tempDir
        )
        let fileURL = tempDir.appendingPathComponent("com.mypass.chromehost.json")
        let firstContent = try Data(contentsOf: fileURL)

        try NativeMessagingHostInstaller.installIfNeeded(
            hostBinaryPath: "/usr/local/bin/ChromeHost", extensionID: "abcdefghijklmnop", directory: tempDir
        )
        let secondContent = try Data(contentsOf: fileURL)
        XCTAssertEqual(firstContent, secondContent, "content should be byte-identical after a no-op reinstall")
    }

    /// Regression guard for the sandbox-redirection bug: `NSHomeDirectory()`
    /// resolves to `~/Library/Containers/<bundle-id>/Data` under the App
    /// Sandbox, which `getpwuid`-based `realHomeDirectoryPath` must not.
    /// This doesn't exercise the sandboxed-app runtime path directly (the
    /// XCTest host process isn't itself sandboxed the same way), but it does
    /// confirm the `getpwuid` codepath returns a real, non-container path in
    /// this test environment rather than silently falling back to the
    /// broken `NSHomeDirectory()` value.
    func testRealHomeDirectoryPathDoesNotContainContainers() {
        let path = NativeMessagingHostInstaller.realHomeDirectoryPath
        XCTAssertFalse(path.isEmpty)
        XCTAssertFalse(path.contains("Containers"), "expected the real POSIX home directory, got: \(path)")
    }

    func testInstallRewritesWhenContentChanges() throws {
        try NativeMessagingHostInstaller.installIfNeeded(
            hostBinaryPath: "/usr/local/bin/ChromeHost", extensionID: "abcdefghijklmnop", directory: tempDir
        )
        try NativeMessagingHostInstaller.installIfNeeded(
            hostBinaryPath: "/usr/local/bin/ChromeHost", extensionID: "zzzzzzzzzzzzzzzz", directory: tempDir
        )
        let fileURL = tempDir.appendingPathComponent("com.mypass.chromehost.json")
        let data = try Data(contentsOf: fileURL)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let allowedOrigins = try XCTUnwrap(object["allowed_origins"] as? [String])
        XCTAssertEqual(allowedOrigins, ["chrome-extension://zzzzzzzzzzzzzzzz/"])
    }
}
