import XCTest
@testable import MyPass

/// Serves canned responses to a `URLSession` so the real client runs end to end without a network.
final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var lastRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (response, data) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class GitHubReleaseClientTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.handler = nil
        StubURLProtocol.lastRequest = nil
        super.tearDown()
    }

    private func makeClient() -> GitHubReleaseClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return GitHubReleaseClient(session: URLSession(configuration: configuration), currentVersion: "0.3.0")
    }

    private func respond(status: Int, body: String) {
        StubURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (response, Data(body.utf8))
        }
    }

    func testDecodesTagAndUrl() async throws {
        respond(status: 200, body: #"{"tag_name":"v0.3.0","html_url":"https://github.com/slucheninov/mypass/releases/tag/v0.3.0","draft":false}"#)
        let release = try await makeClient().latestRelease()
        XCTAssertEqual(release, ReleaseInfo(
            version: SemanticVersion(major: 0, minor: 3, patch: 0),
            tag: "v0.3.0",
            url: URL(string: "https://github.com/slucheninov/mypass/releases/tag/v0.3.0")!))
    }

    func testTagWithoutLeadingVIsAccepted() async throws {
        respond(status: 200, body: #"{"tag_name":"0.4.0","html_url":"https://github.com/slucheninov/mypass/releases/tag/0.4.0"}"#)
        let release = try await makeClient().latestRelease()
        XCTAssertEqual(release.version, SemanticVersion(major: 0, minor: 4, patch: 0))
        XCTAssertEqual(release.tag, "0.4.0")
    }

    func testPrereleaseStyleTagThrowsUnparsableVersion() async throws {
        respond(status: 200, body: #"{"tag_name":"v0.4.0-rc1","html_url":"https://github.com/slucheninov/mypass/releases/tag/v0.4.0-rc1"}"#)
        await assertThrows(ReleaseFeedError.unparsableVersion("v0.4.0-rc1"))
    }

    func testRateLimitStatusThrowsBadStatus() async throws {
        respond(status: 403, body: #"{"message":"API rate limit exceeded"}"#)
        await assertThrows(ReleaseFeedError.badStatus(403))
    }

    func testNonJsonBodyThrowsMalformedPayload() async throws {
        respond(status: 200, body: "<html>captive portal</html>")
        await assertThrows(ReleaseFeedError.malformedPayload)
    }

    func testMissingFieldsThrowMalformedPayload() async throws {
        respond(status: 200, body: "{}")
        await assertThrows(ReleaseFeedError.malformedPayload)
    }

    func testNonGithubReleaseUrlIsRejected() async throws {
        for badURL in ["http://github.com/x", "https://evil.example/x", "file:///etc/passwd"] {
            respond(status: 200, body: #"{"tag_name":"v0.4.0","html_url":"\#(badURL)"}"#)
            await assertThrows(ReleaseFeedError.malformedPayload, "html_url \(badURL)")
        }
    }

    func testRequestCarriesRequiredHeadersAndTimeout() async throws {
        respond(status: 200, body: #"{"tag_name":"v0.3.0","html_url":"https://github.com/slucheninov/mypass/releases/tag/v0.3.0"}"#)
        _ = try await makeClient().latestRelease()
        let request = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.absoluteString, "https://api.github.com/repos/slucheninov/mypass/releases/latest")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-GitHub-Api-Version"), "2022-11-28")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "MyPass/0.3.0")
        XCTAssertEqual(request.timeoutInterval, 10)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    private func assertThrows(_ expected: ReleaseFeedError, _ message: String = "",
                              file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await makeClient().latestRelease()
            XCTFail("expected \(expected) \(message)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? ReleaseFeedError, expected, message, file: file, line: line)
        }
    }
}
