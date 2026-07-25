import Foundation

enum NativeMessagingHostInstaller {
    /// Placeholder until Task 12 (loading the unpacked extension via
    /// chrome://extensions) produces a real ID. Rewriting the manifest with
    /// the real ID after that point is a manual dev-workflow step — see the
    /// Task 12 checklist. Not suitable for distribution as-is.
    static let developmentPlaceholderExtensionID = "REPLACE_WITH_UNPACKED_EXTENSION_ID"

    /// Debug build product path convention for local development. Not a
    /// stable path for distribution — revisit before shipping outside a dev
    /// machine (e.g. resolve the real installed ChromeHost path instead).
    static var debugChromeHostBinaryPath: String {
        NSHomeDirectory() + "/Library/Developer/Xcode/DerivedData/MyPass/Build/Products/Debug/ChromeHost"
    }

    static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Google/Chrome/NativeMessagingHosts")
    }

    static func installIfNeeded(
        hostBinaryPath: String,
        extensionID: String,
        directory: URL = defaultDirectory
    ) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let manifest: [String: Any] = [
            "name": "com.mypass.chromehost",
            "description": "MyPass native messaging host",
            "path": hostBinaryPath,
            "type": "stdio",
            "allowed_origins": ["chrome-extension://\(extensionID)/"]
        ]
        let newData = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])

        let fileURL = directory.appendingPathComponent("com.mypass.chromehost.json")
        if let existingData = try? Data(contentsOf: fileURL), existingData == newData {
            return
        }
        try newData.write(to: fileURL, options: .atomic)
    }
}
