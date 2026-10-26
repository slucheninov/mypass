import XCTest
@testable import MyPass

/// Hand-written feed double. The optional gate lets a test hold a request in flight so the
/// overlap rules (second call ignored, scheduled check upgraded to manual) can be observed.
private final class StubReleaseFeed: ReleaseFeed, @unchecked Sendable {
    private let lock = NSLock()
    private var _callCount = 0
    private var _result: Result<ReleaseInfo, Error>
    private var _holdUntilReleased = false
    private var continuation: CheckedContinuation<Void, Never>?

    init(result: Result<ReleaseInfo, Error>) { _result = result }

    var callCount: Int { lock.lock(); defer { lock.unlock() }; return _callCount }
    var result: Result<ReleaseInfo, Error> {
        get { lock.lock(); defer { lock.unlock() }; return _result }
        set { lock.lock(); defer { lock.unlock() }; _result = newValue }
    }
    var holdUntilReleased: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _holdUntilReleased }
        set { lock.lock(); defer { lock.unlock() }; _holdUntilReleased = newValue }
    }

    // NSLock is unavailable from async contexts, so the locked sections live in sync helpers.
    // `released` makes the gate race-free: release() may run before the continuation is stored
    // (the checker flips to .checking before the feed is entered), and that wakeup must not be lost.
    private var _released = false

    private func recordCall() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        _callCount += 1
        return _holdUntilReleased
    }

    /// Stores the continuation, or returns it for immediate resumption when release() already ran.
    private func storeOrResume(_ c: CheckedContinuation<Void, Never>) {
        lock.lock()
        if _released {
            lock.unlock()
            c.resume()
        } else {
            continuation = c
            lock.unlock()
        }
    }

    func latestRelease() async throws -> ReleaseInfo {
        if recordCall() {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                storeOrResume(c)
            }
        }
        return try result.get()
    }

    func release() {
        lock.lock()
        _released = true
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume()
    }
}

@MainActor
final class AppUpdateCheckerTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        super.setUp()
        suiteName = "AppUpdateCheckerTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func release(_ v: String) -> ReleaseInfo {
        ReleaseInfo(version: SemanticVersion(string: v)!,
                    tag: "v\(v)",
                    url: URL(string: "https://github.com/slucheninov/mypass/releases/tag/v\(v)")!)
    }

    private func makeChecker(feed: ReleaseFeed, current: String? = "0.3.0") -> AppUpdateChecker {
        AppUpdateChecker(feed: feed,
                         currentVersion: current.flatMap { SemanticVersion(string: $0) },
                         defaults: defaults,
                         now: { [fixedNow] in fixedNow })
    }

    private func waitForChecking(_ checker: AppUpdateChecker) async {
        for _ in 0..<2000 where checker.status != .checking {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(checker.status, .checking)
    }

    func testNewerReleaseBecomesAvailableAndShowsBanner() async {
        let rel = release("0.4.0")
        let checker = makeChecker(feed: StubReleaseFeed(result: .success(rel)))
        await checker.check(manual: false)
        XCTAssertEqual(checker.status, .available(rel))
        XCTAssertEqual(checker.bannerRelease, rel)
        XCTAssertEqual(checker.bannerText, "MyPass 0.4.0 is available (you have 0.3.0)")
        XCTAssertEqual(checker.menuItemTitle, "MyPass 0.4.0 available…")
    }

    func testSameVersionIsUpToDate() async {
        let checker = makeChecker(feed: StubReleaseFeed(result: .success(release("0.3.0"))))
        await checker.check(manual: false)
        XCTAssertEqual(checker.status, .upToDate(checkedAt: fixedNow))
        XCTAssertNil(checker.bannerRelease)
        XCTAssertNil(checker.bannerText)
    }

    func testCurrentVersionNewerThanLatestIsUpToDate() async {
        let checker = makeChecker(feed: StubReleaseFeed(result: .success(release("0.3.0"))), current: "0.4.0")
        await checker.check(manual: false)
        XCTAssertEqual(checker.status, .upToDate(checkedAt: fixedNow))
        XCTAssertNil(checker.bannerRelease)
    }

    func testDismissedVersionHidesBannerButKeepsAvailableStatus() async {
        defaults.set("0.4.0", forKey: "updateCheckDismissedVersion")
        let rel = release("0.4.0")
        let checker = makeChecker(feed: StubReleaseFeed(result: .success(rel)))
        await checker.check(manual: false)
        XCTAssertNil(checker.bannerRelease)
        XCTAssertEqual(checker.status, .available(rel))
    }

    func testDismissBannerPersistsAndHides() async {
        let rel = release("0.4.0")
        let checker = makeChecker(feed: StubReleaseFeed(result: .success(rel)))
        await checker.check(manual: false)
        checker.dismissBanner()
        XCTAssertNil(checker.bannerRelease)
        XCTAssertEqual(defaults.string(forKey: "updateCheckDismissedVersion"), "0.4.0")
        XCTAssertEqual(checker.status, .available(rel))
    }

    func testDismissedVersionSurvivesRelaunchAndNewerReleaseReturns() async {
        let feed = StubReleaseFeed(result: .success(release("0.4.0")))
        let first = makeChecker(feed: feed)
        await first.check(manual: false)
        first.dismissBanner()

        let second = makeChecker(feed: feed)
        await second.check(manual: false)
        XCTAssertNil(second.bannerRelease)

        feed.result = .success(release("0.5.0"))
        await second.check(manual: false)
        XCTAssertEqual(second.bannerRelease?.version.description, "0.5.0")
    }

    func testDisabledScheduledCheckMakesNoRequest() async {
        defaults.set(false, forKey: "updateCheckEnabled")
        let feed = StubReleaseFeed(result: .success(release("0.4.0")))
        let checker = makeChecker(feed: feed)
        await checker.check(manual: false)
        XCTAssertEqual(feed.callCount, 0)
        XCTAssertEqual(checker.status, .idle)
        XCTAssertNil(defaults.object(forKey: "updateCheckLastRunTimestamp"))
    }

    func testDisabledManualCheckStillRuns() async {
        defaults.set(false, forKey: "updateCheckEnabled")
        let feed = StubReleaseFeed(result: .success(release("0.4.0")))
        let checker = makeChecker(feed: feed)
        await checker.check(manual: true)
        XCTAssertEqual(feed.callCount, 1)
    }

    func testEnabledDefaultsToTrueWhenUnset() {
        let checker = makeChecker(feed: StubReleaseFeed(result: .success(release("0.3.0"))))
        XCTAssertTrue(checker.isEnabled)
        checker.isEnabled = false
        XCTAssertEqual(defaults.object(forKey: "updateCheckEnabled") as? Bool, false)
        XCTAssertFalse(checker.isEnabled)
    }

    func testScheduledFailureKeepsPreviousStatus() async {
        let rel = release("0.4.0")
        let feed = StubReleaseFeed(result: .success(rel))
        let checker = makeChecker(feed: feed)
        await checker.check(manual: false)
        defaults.set(0.0, forKey: "updateCheckLastRunTimestamp")

        feed.result = .failure(ReleaseFeedError.badStatus(403))
        await checker.check(manual: false)
        XCTAssertEqual(checker.status, .available(rel))
        XCTAssertEqual(checker.bannerRelease, rel)
        XCTAssertEqual(defaults.double(forKey: "updateCheckLastRunTimestamp"), 1_800_000_000)
    }

    func testManualFailureShowsMessage() async {
        let feed = StubReleaseFeed(result: .failure(ReleaseFeedError.badStatus(403)))
        let checker = makeChecker(feed: feed)
        await checker.check(manual: true)
        XCTAssertEqual(checker.status, .failed(message: "GitHub rate limit reached; try again later."))

        feed.result = .failure(ReleaseFeedError.malformedPayload)
        await checker.check(manual: true)
        XCTAssertEqual(checker.status, .failed(message: "GitHub returned an unexpected answer."))

        feed.result = .failure(URLError(.notConnectedToInternet))
        await checker.check(manual: true)
        XCTAssertEqual(checker.status, .failed(message: "Could not reach GitHub."))
    }

    func testLastRunTimestampWrittenOnSuccessAndFailure() async {
        let feed = StubReleaseFeed(result: .success(release("0.3.0")))
        let checker = makeChecker(feed: feed)
        await checker.check(manual: false)
        XCTAssertEqual(defaults.double(forKey: "updateCheckLastRunTimestamp"), 1_800_000_000)
        XCTAssertEqual(checker.lastRun, fixedNow)

        defaults.set(0.0, forKey: "updateCheckLastRunTimestamp")
        XCTAssertNil(checker.lastRun)
        feed.result = .failure(ReleaseFeedError.badStatus(500))
        await checker.check(manual: false)
        XCTAssertEqual(defaults.double(forKey: "updateCheckLastRunTimestamp"), 1_800_000_000)
    }

    func testSecondCheckWhileInFlightIsIgnored() async {
        let feed = StubReleaseFeed(result: .success(release("0.4.0")))
        feed.holdUntilReleased = true
        let checker = makeChecker(feed: feed)
        let first = Task { await checker.check(manual: false) }
        await waitForChecking(checker)
        await checker.check(manual: true)
        XCTAssertEqual(checker.status, .checking)
        feed.release()
        await first.value
        XCTAssertEqual(feed.callCount, 1)
    }

    func testManualCheckDuringScheduledCheckSurfacesFailure() async {
        let feed = StubReleaseFeed(result: .failure(ReleaseFeedError.badStatus(500)))
        feed.holdUntilReleased = true
        let checker = makeChecker(feed: feed)
        let first = Task { await checker.check(manual: false) }
        await waitForChecking(checker)
        await checker.check(manual: true)
        feed.release()
        await first.value
        XCTAssertEqual(checker.status, .failed(message: "GitHub answered with status 500."))
    }

    func testUnparsableRunningVersionNeverTouchesNetwork() async {
        let feed = StubReleaseFeed(result: .success(release("0.4.0")))
        let checker = makeChecker(feed: feed, current: nil)
        await checker.check(manual: false)
        XCTAssertEqual(feed.callCount, 0)
        XCTAssertEqual(checker.status, .idle)
        await checker.check(manual: true)
        XCTAssertEqual(checker.status, .failed(message: "Cannot determine the running version."))
        XCTAssertEqual(feed.callCount, 0)
    }

    func testDisablingClearsBanner() async {
        let checker = makeChecker(feed: StubReleaseFeed(result: .success(release("0.4.0"))))
        await checker.check(manual: false)
        XCTAssertNotNil(checker.bannerRelease)
        defaults.set(false, forKey: "updateCheckEnabled")
        checker.enabledDidChange()
        XCTAssertNil(checker.bannerRelease)
        XCTAssertEqual(checker.status, .idle)
    }

    func testScheduledTickAfterDisablingMakesNoRequest() async {
        let feed = StubReleaseFeed(result: .success(release("0.4.0")))
        let checker = makeChecker(feed: feed)
        checker.startScheduling()
        XCTAssertTrue(checker.isScheduled)
        defaults.set(false, forKey: "updateCheckEnabled")
        await checker.scheduledTick()
        XCTAssertEqual(feed.callCount, 0)
        checker.stopScheduling()
        XCTAssertFalse(checker.isScheduled)
        checker.startScheduling()
        checker.startScheduling()
        XCTAssertTrue(checker.isScheduled)
        checker.stopScheduling()
        XCTAssertFalse(checker.isScheduled)
    }
}
