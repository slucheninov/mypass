import Foundation

/// Builds the GitHub release page for a version.
///
/// The repository comes from `GitHubReleaseClient.defaultRepository`, the same constant the
/// update check reads, so the About pane can never point at a different project than the one
/// the app updates from. The version is parsed through `SemanticVersion` and re-printed rather
/// than interpolated raw: anything that is not a plain `MAJOR.MINOR.PATCH` (a dev build with an
/// unexpected `CFBundleShortVersionString`, a path fragment) yields no link instead of a URL to
/// a tag that cannot exist.
enum ReleaseNotesLink {
    static func url(forVersion version: String) -> URL? {
        guard let parsed = SemanticVersion(string: version) else { return nil }
        return URL(string: "https://github.com/\(GitHubReleaseClient.defaultRepository)/releases/tag/v\(parsed.description)")
    }
}
