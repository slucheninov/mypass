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
    ///
    /// Uses `realHomeDirectoryPath` rather than `NSHomeDirectory()` — see
    /// that property's doc comment for why `NSHomeDirectory()` gives the
    /// wrong answer here under the App Sandbox.
    static var debugChromeHostBinaryPath: String {
        realHomeDirectoryPath + "/Library/Developer/Xcode/DerivedData/MyPass/Build/Products/Debug/ChromeHost"
    }

    /// The real (non-container-redirected) home directory path of the
    /// current user, e.g. `/Users/alice`.
    ///
    /// `NSHomeDirectory()` and `FileManager.default.homeDirectoryForCurrentUser`
    /// are both redirected by the App Sandbox to the app's container
    /// directory (`~/Library/Containers/<bundle-id>/Data`) once the
    /// `com.apple.security.app-sandbox` entitlement is enabled — which it is
    /// for MyPass.app. Neither is usable here: this string is only ever used
    /// to *construct a display/debug path string*, never for direct file
    /// I/O (actual sandboxed file access to locations outside the container,
    /// like Chrome's NativeMessagingHosts directory, requires a
    /// security-scoped bookmark the user grants explicitly via NSOpenPanel —
    /// see `SettingsView`'s Chrome-extension section).
    ///
    /// `getpwuid(getuid())` reads the real home directory straight out of
    /// the system's password database (Open Directory / `/etc/passwd`
    /// equivalent), bypassing the sandbox's home-directory redirection
    /// entirely. This does not require any additional entitlement — it's a
    /// well-known technique for sandboxed apps that need the real home path
    /// for display purposes.
    static var realHomeDirectoryPath: String {
        if let pwd = getpwuid(getuid()), let homeDir = pwd.pointee.pw_dir {
            return String(cString: homeDir)
        }
        return NSHomeDirectory()
    }

    /// WARNING: broken under the App Sandbox — `homeDirectoryForCurrentUser`
    /// resolves to the app's sandbox container, not the real home directory,
    /// so this points at a location Chrome never reads. Kept only as the
    /// parameter default below for source compatibility with existing test
    /// call sites; production callers MUST pass an explicit `directory`
    /// resolved from a user-granted security-scoped bookmark instead (see
    /// `SettingsView`'s Chrome-extension section and `MyPassApp.init()`).
    static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Google/Chrome/NativeMessagingHosts")
    }

    /// Resolves a security-scoped bookmark (as created by
    /// `LocalFolderBackend.createBookmark(for:)`-style `.withSecurityScope`
    /// bookmark data, e.g. the one the user grants via NSOpenPanel in
    /// `SettingsView`'s Chrome-extension section) to a real, sandbox-escaping
    /// directory `URL`. Returns `nil` for missing/invalid/stale bookmark
    /// data — callers treat that as "not configured yet", not a crash.
    static func resolveBookmarkedDirectory(bookmarkData: Data) -> URL? {
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ), !isStale else {
            return nil
        }
        return url
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
