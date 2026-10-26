import Foundation

struct ReleaseInfo: Equatable {
    let version: SemanticVersion
    let tag: String
    let url: URL
}

protocol ReleaseFeed: Sendable {
    func latestRelease() async throws -> ReleaseInfo
}

enum ReleaseFeedError: Error, Equatable {
    case badStatus(Int)
    case malformedPayload
    case unparsableVersion(String)
}

/// Asks the GitHub REST API for the latest published release. A plain unauthenticated GET:
/// nothing about the user, the vault or the machine is sent beyond the app version in the
/// User-Agent header that GitHub requires.
final class GitHubReleaseClient: ReleaseFeed {
    static let defaultRepository = "slucheninov/mypass"

    private let session: URLSession
    private let endpoint: URL
    private let currentVersion: String

    init(session: URLSession = .shared,
         repository: String = GitHubReleaseClient.defaultRepository,
         currentVersion: String) {
        self.session = session
        self.endpoint = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
        self.currentVersion = currentVersion
    }

    private struct Payload: Decodable {
        let tag_name: String
        let html_url: String
    }

    func latestRelease() async throws -> ReleaseInfo {
        // The cache is bypassed so a stale CDN or URLCache copy never hides a freshly
        // published release from the user.
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 10)
        request.httpMethod = "GET"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("MyPass/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ReleaseFeedError.malformedPayload }
        // Status is checked before the body is touched: an error body (rate limit, outage page)
        // is not a release and must not be parsed as one.
        guard http.statusCode == 200 else { throw ReleaseFeedError.badStatus(http.statusCode) }

        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            throw ReleaseFeedError.malformedPayload
        }
        // `releases/latest` already excludes drafts and prereleases, so the client does no
        // filtering of its own. This is why the release pipeline publishes as a draft first:
        // the release only becomes "latest" once its assets are attached.
        guard let version = SemanticVersion(string: payload.tag_name) else {
            throw ReleaseFeedError.unparsableVersion(payload.tag_name)
        }
        // The URL is later handed to NSWorkspace.open, so a compromised or confused response
        // must not be able to point the user at another host or a non-web scheme.
        guard let url = URL(string: payload.html_url),
              url.scheme == "https",
              url.host == "github.com" else {
            throw ReleaseFeedError.malformedPayload
        }
        return ReleaseInfo(version: version, tag: payload.tag_name, url: url)
    }
}
