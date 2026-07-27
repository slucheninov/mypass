import Foundation
import Darwin

/// Locates the user's iCloud Drive folder (`~/Library/Mobile
/// Documents/com~apple~CloudDocs`). That folder is synced by the system file
/// provider and a sandboxed app may reach it through a user-selected
/// security-scoped bookmark, so it needs no iCloud container entitlement and
/// no paid Apple Developer account — unlike a real ubiquity container.
public enum ICloudDriveLocation {
    static let mobileDocumentsDirectoryName = "Mobile Documents"
    static let cloudDocsDirectoryName = "com~apple~CloudDocs"

    /// The conventional iCloud Drive path for the current user, computed
    /// without touching the filesystem. Used to pre-fill the folder open
    /// panel and to warn when a chosen folder sits outside iCloud Drive.
    ///
    /// No existence check: inside the sandbox, reading that path is denied
    /// until the user grants access through the open panel, so a check would
    /// report "absent" for every user who has not completed setup yet.
    public static var iCloudDriveRootURL: URL? {
        realHomeDirectoryURL?
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent(mobileDocumentsDirectoryName, isDirectory: true)
            .appendingPathComponent(cloudDocsDirectoryName, isDirectory: true)
    }

    /// `true` when `url` is the iCloud Drive root itself or anything beneath it.
    public static func isInsideICloudDrive(_ url: URL) -> Bool {
        guard let root = iCloudDriveRootURL else { return false }
        return isDescendantOrSame(url, of: root)
    }

    /// Pure path-prefix comparison, split out so it is unit-testable without
    /// a real iCloud Drive folder on the machine running the tests.
    static func isDescendantOrSame(_ url: URL, of root: URL) -> Bool {
        let urlComponents = url.standardizedFileURL.pathComponents
        let rootComponents = root.standardizedFileURL.pathComponents
        guard urlComponents.count >= rootComponents.count else { return false }
        return Array(urlComponents.prefix(rootComponents.count)) == rootComponents
    }

    /// `NSHomeDirectory()` and `FileManager.homeDirectoryForCurrentUser` both
    /// return the *container* path in a sandboxed app, so the real home
    /// directory has to be read from the password database.
    static var realHomeDirectoryURL: URL? {
        guard let passwd = getpwuid(getuid()), let directory = passwd.pointee.pw_dir else {
            return nil
        }
        return URL(fileURLWithPath: String(cString: directory), isDirectory: true)
    }
}
