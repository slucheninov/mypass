import Foundation
import os.log

/// Owns the "is a newer MyPass published?" state: one GitHub request per attempt, a daily
/// schedule, and the dismissal memory behind the banner. Nothing here downloads or installs
/// anything; it only reports what the release feed says.
@MainActor
final class AppUpdateChecker: ObservableObject {
    enum Status: Equatable {
        case idle
        case checking
        case upToDate(checkedAt: Date)
        case available(ReleaseInfo)
        case failed(message: String)
    }

    enum DefaultsKey {
        static let enabled = "updateCheckEnabled"
        static let lastRun = "updateCheckLastRunTimestamp"
        static let dismissedVersion = "updateCheckDismissedVersion"
    }

    static let initialDelay: TimeInterval = 10
    static let interval: TimeInterval = 86_400

    private static let log = OSLog(subsystem: "com.mypass.app", category: "UpdateCheck")

    @Published private(set) var status: Status = .idle
    @Published private(set) var bannerRelease: ReleaseInfo?

    let currentVersion: SemanticVersion?
    private(set) var isScheduled = false

    private let feed: ReleaseFeed
    private let defaults: UserDefaults
    private let now: () -> Date

    private var isChecking = false
    private var inFlightIsManual = false
    private var initialTimer: Timer?
    private var repeatingTimer: Timer?
    private var schedulingGeneration = 0

    init(feed: ReleaseFeed,
         currentVersion: SemanticVersion?,
         defaults: UserDefaults,
         now: @escaping () -> Date = Date.init) {
        self.feed = feed
        self.currentVersion = currentVersion
        self.defaults = defaults
        self.now = now
    }

    // MARK: - Settings-backed state

    /// Defaults to true when the key was never written.
    var isEnabled: Bool {
        get { defaults.object(forKey: DefaultsKey.enabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: DefaultsKey.enabled) }
    }

    var lastRun: Date? {
        let stamp = defaults.double(forKey: DefaultsKey.lastRun)
        return stamp > 0 ? Date(timeIntervalSince1970: stamp) : nil
    }

    var bannerText: String? {
        guard let release = bannerRelease, let current = currentVersion else { return nil }
        return String(localized: "MyPass \(release.version.description) is available (you have \(current.description))", comment: "Update banner; first argument is the new version, second the running version")
    }

    var menuItemTitle: String? {
        guard let release = bannerRelease else { return nil }
        return String(localized: "MyPass \(release.version.description) available…", comment: "Menu bar item title announcing a new version; the argument is the version")
    }

    // MARK: - Checking

    func scheduledTick() async {
        await check(manual: false)
    }

    func check(manual: Bool) async {
        // An explicit "Check now" press is the user's own request, so it runs even when the
        // automatic-check toggle is off. Only the schedule honours the toggle.
        if !manual && !isEnabled { return }

        guard let current = currentVersion else {
            os_log("Running version is unparsable; skipping update check", log: Self.log, type: .error)
            if manual { status = .failed(message: String(localized: "Cannot determine the running version.", comment: "Update check error")) }
            return
        }

        // In-flight guard: "Check now" and the launch tick (10 s after start) can overlap, and
        // two concurrent requests would race on status. The second caller returns at once; if
        // it is a manual press while a scheduled check runs, the running check is upgraded so
        // a failure is surfaced to the user who asked.
        if isChecking {
            if manual { inFlightIsManual = true }
            return
        }
        isChecking = true
        inFlightIsManual = manual
        let previousStatus = status
        status = .checking

        do {
            let release = try await feed.latestRelease()
            if release.version > current {
                status = .available(release)
                // Dismissal compares version strings, not ordering: a newer release than the
                // dismissed one must always bring the banner back.
                let dismissed = defaults.string(forKey: DefaultsKey.dismissedVersion)
                bannerRelease = dismissed == release.version.description ? nil : release
            } else {
                status = .upToDate(checkedAt: now())
                bannerRelease = nil
            }
        } catch {
            os_log("Update check failed: %{public}@", log: Self.log, type: .error,
                   String(describing: error))
            if inFlightIsManual {
                status = .failed(message: Self.message(for: error))
            } else {
                status = previousStatus
            }
        }

        defaults.set(now().timeIntervalSince1970, forKey: DefaultsKey.lastRun)
        isChecking = false
        inFlightIsManual = false
    }

    private static func message(for error: Error) -> String {
        if let feedError = error as? ReleaseFeedError {
            switch feedError {
            case .badStatus(let code) where code == 403 || code == 429:
                return String(localized: "GitHub rate limit reached; try again later.", comment: "Update check error")
            case .badStatus(let code):
                return String(localized: "GitHub answered with status \(code).", comment: "Update check error; the argument is an HTTP status code")
            case .malformedPayload, .unparsableVersion:
                return String(localized: "GitHub returned an unexpected answer.", comment: "Update check error")
            }
        }
        if error is URLError { return String(localized: "Could not reach GitHub.", comment: "Update check error") }
        return String(localized: "GitHub returned an unexpected answer.", comment: "Update check error")
    }

    // MARK: - Banner

    /// Persists the version the banner is actually showing (`bannerRelease`), not whatever
    /// `status` says: the banner stays up through a failed manual check or a running check,
    /// and Later must stick in those states too. The version string is stored so a newer
    /// release still brings the banner back.
    func dismissBanner() {
        if let release = bannerRelease {
            defaults.set(release.version.description, forKey: DefaultsKey.dismissedVersion)
        }
        bannerRelease = nil
    }

    func enabledDidChange() {
        guard !isEnabled else { return }
        bannerRelease = nil
        switch status {
        case .available, .failed:
            status = .idle
        case .idle, .checking, .upToDate:
            break
        }
    }

    // MARK: - Scheduling

    /// The timers hold `self` weakly so a deallocated checker never fires. The interval is
    /// re-read from the constant, not from defaults, and `scheduledTick` re-reads the toggle,
    /// so flipping the toggle while a timer is pending needs no timer teardown.
    func startScheduling() {
        stopScheduling()
        isScheduled = true
        schedulingGeneration += 1
        let generation = schedulingGeneration
        initialTimer = Timer.scheduledTimer(withTimeInterval: Self.initialDelay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.scheduledTick()
                // stopScheduling() may have run while the first tick was awaiting. The generation
                // counter also catches a stop followed by a new start, which flips isScheduled
                // back to true and would otherwise let this stale task arm a second timer.
                guard self.isScheduled, generation == self.schedulingGeneration else { return }
                self.repeatingTimer?.invalidate()
                self.repeatingTimer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
                    Task { @MainActor [weak self] in await self?.scheduledTick() }
                }
            }
        }
    }

    func stopScheduling() {
        initialTimer?.invalidate()
        initialTimer = nil
        repeatingTimer?.invalidate()
        repeatingTimer = nil
        isScheduled = false
    }
}
