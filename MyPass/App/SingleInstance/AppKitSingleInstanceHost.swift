import AppKit

/// Production `SingleInstanceHost`: NSRunningApplication for peer discovery,
/// the kernel process table for identity and liveness, and
/// `DistributedNotificationCenter` for the cooperative messages.
///
/// The notification name embeds the bundle identifier, so an isolated end-to-end
/// run under a throwaway bundle identifier can never address (or be addressed
/// by) the user's real `com.mypass.app`.
final class AppKitSingleInstanceHost: SingleInstanceHost {
    private let bundleIdentifier: String
    private let executableName: String
    private let center: DistributedNotificationCenter
    private let notificationName: Notification.Name

    init(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        executableName: String? = Bundle.main.executableURL?.lastPathComponent,
        center: DistributedNotificationCenter = .default()
    ) {
        self.bundleIdentifier = bundleIdentifier ?? ""
        self.executableName = executableName ?? ""
        self.center = center
        // v2: the two-phase probe/commit protocol; a v1 listener is never woken by it.
        notificationName = Notification.Name("\(self.bundleIdentifier).singleinstance.v2")
    }

    var selfIdentity: ProcessIdentity? {
        guard !bundleIdentifier.isEmpty else { return nil }
        return KernelProcessTable.current
    }

    func livePeers() -> Set<ProcessIdentity> {
        guard !bundleIdentifier.isEmpty else { return [] }
        let myPID = getpid()
        var peers = Set<ProcessIdentity>()
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        where app.processIdentifier != myPID && !app.isTerminated {
            if let identity = KernelProcessTable.identity(ofPID: app.processIdentifier) {
                peers.insert(identity)
            }
        }
        return peers
    }

    func isAlive(_ identity: ProcessIdentity) -> Bool {
        KernelProcessTable.isAlive(identity)
    }

    func isRecognizedPeer(_ identity: ProcessIdentity) -> Bool {
        guard !bundleIdentifier.isEmpty, !executableName.isEmpty,
              let app = NSRunningApplication(processIdentifier: identity.pid),
              !app.isTerminated else { return false }
        return app.bundleIdentifier == bundleIdentifier
            && app.executableURL?.lastPathComponent == executableName
    }

    func send(_ message: SingleInstanceMessage) {
        guard !bundleIdentifier.isEmpty else { return }
        // `userInfo` is intentionally nil: the system drops it for sandboxed
        // senders, so the whole payload rides in the `object` string.
        center.postNotificationName(notificationName, object: message.wire, userInfo: nil, deliverImmediately: true)
    }

    func startListening(_ handler: @escaping (String) -> Void) -> AnyObject {
        let observer = center.addObserver(forName: notificationName, object: nil, queue: .main) { notification in
            if let payload = notification.object as? String { handler(payload) }
        }
        return ObserverToken(center: center, observer: observer)
    }

    func monotonicNow() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    func nextAttemptID() -> UInt64 {
        UInt64.random(in: 1...UInt64.max)
    }

    func performSoon(_ block: @escaping () -> Void) {
        RunLoop.main.perform(inModes: [.common], block: block)
    }

    func pump(for interval: TimeInterval) {
        let deadline = Date(timeIntervalSinceNow: interval)
        // `RunLoop.run(mode:before:)` returns at once when the mode has no
        // sources yet; sleep the remainder so the election loop never spins hot.
        _ = RunLoop.current.run(mode: .default, before: deadline)
        let remaining = deadline.timeIntervalSinceNow
        if remaining > 0 { Thread.sleep(forTimeInterval: remaining) }
    }

    private final class ObserverToken {
        private let center: DistributedNotificationCenter
        private let observer: NSObjectProtocol

        init(center: DistributedNotificationCenter, observer: NSObjectProtocol) {
            self.center = center
            self.observer = observer
        }

        deinit { center.removeObserver(observer) }
    }
}
