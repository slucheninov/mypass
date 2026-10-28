import Foundation

/// What the coordinator needs from the outside world. The production adapter
/// is `AppKitSingleInstanceHost`; tests drive a scripted fake with a virtual
/// clock, so every election below is deterministic.
protocol SingleInstanceHost: AnyObject {
    /// This process, or `nil` when the kernel cannot name it. The coordinator
    /// then fails closed instead of guessing it is the newest.
    var selfIdentity: ProcessIdentity? { get }
    /// Other live processes registered under this app's bundle identifier.
    func livePeers() -> Set<ProcessIdentity>
    /// `true` while exactly this pid + start time is alive.
    func isAlive(_ identity: ProcessIdentity) -> Bool
    /// `true` when `identity` is a running process of this same app (same
    /// bundle identifier and executable name). Hosted test runs and previews
    /// also pass this check; they stay safe because they never send a message.
    func isRecognizedPeer(_ identity: ProcessIdentity) -> Bool
    func send(_ message: SingleInstanceMessage)
    /// Delivers raw payload strings on the main thread until the returned token is released.
    func startListening(_ handler: @escaping (String) -> Void) -> AnyObject
    /// A monotonic clock that every process on the machine reads identically
    /// (system uptime): commit deadlines are exchanged in it.
    func monotonicNow() -> TimeInterval
    /// Lets the main run loop deliver notifications for roughly `interval` seconds.
    func pump(for interval: TimeInterval)
    /// A fresh, hard-to-collide number naming one election attempt.
    func nextAttemptID() -> UInt64
    /// Runs `block` on a later turn of the main run loop, never inline. A quit
    /// must start from a run-loop block, not from inside a notification callback.
    func performSoon(_ block: @escaping () -> Void)
}

struct SingleInstanceTiming: Equatable {
    /// Minimum time to listen for an answer before concluding "nobody else is
    /// here". `runningApplications` can transiently return an empty list and a
    /// direct-exec peer in another sandbox scope is invisible, but a live
    /// cooperative peer answers within milliseconds.
    var quietPeriod: TimeInterval = 0.25
    /// A live peer that has not answered the probe this long after it was first
    /// seen has no takeover listener (a pre-guard build, a test host, a foreign
    /// process, or a main thread stuck in a long operation). Nobody is asked to
    /// quit before every live peer has answered, so this never costs a quit.
    var ackGrace: TimeInterval = 2
    /// How long a `commit` stays acceptable. After its deadline nobody may start
    /// to quit because of it, however late the message is delivered.
    var commitWindow: TimeInterval = 3
    /// A peer accepts a `commit` only if at least this much of the window is
    /// left, so its `ack` still has time to reach the requester before the
    /// requester stops waiting for it.
    var acceptMargin: TimeInterval = 0.25
    /// Extra time the requester waits for an `ack` after the commit deadline
    /// (delivery latency only; nobody accepts after the deadline).
    var ackSlack: TimeInterval = 0.3
    /// Upper bound for the whole election. An acknowledged peer may legitimately
    /// spend this long on its save-flush before it exits.
    var waitBound: TimeInterval = 15
    var repostInterval: TimeInterval = 0.5
    var tick: TimeInterval = 0.05
}

enum SingleInstanceFailure: Error, Equatable {
    case identityUnavailable
    case lockUnavailable(String)
    /// Still-running processes of this app that never answered the probe.
    case unrecognizedPeers([Int32])
    case lockHeldByUnknownProcess
    /// Acknowledged peers that did not exit in time (for example one waiting on a save prompt).
    case timedOut([Int32])
    /// Peers that answered the probe but did not accept the commit in time.
    case notResponding([Int32])
    /// The running copy was asked to close and declined (the user cancelled its save prompt).
    case declined([Int32])

    var title: String {
        switch self {
        case .timedOut: return String(localized: "MyPass is still closing", comment: "Single-instance guard alert")
        case .declined: return String(localized: "MyPass did not close", comment: "Single-instance guard alert")
        default: return String(localized: "Another MyPass is already running", comment: "Single-instance guard alert")
        }
    }

    var message: String {
        switch self {
        case .identityUnavailable:
            return String(localized: "MyPass could not identify its own process, so it cannot safely check for another running copy. Your vault was not opened. Quit any other MyPass and open it again.", comment: "Single-instance guard alert")
        case .lockUnavailable(let detail):
            return String(localized: "MyPass could not take its single-instance lock (\(detail)). Your vault was not opened. Quit any other MyPass and open it again.", comment: "Single-instance guard alert")
        case .unrecognizedPeers(let pids):
            return String(localized: "Another MyPass (process \(Self.list(pids))) is running and did not respond to the request to hand over, which usually means it is an older build. The running copy was left untouched. Quit it manually, then open MyPass again. Your vault was not opened.", comment: "Single-instance guard alert")
        case .lockHeldByUnknownProcess:
            return String(localized: "Another MyPass is holding the single-instance lock but could not be identified. Quit it manually, then open MyPass again. Your vault was not opened.", comment: "Single-instance guard alert")
        case .timedOut(let pids):
            return String(localized: "The running MyPass (process \(Self.list(pids))) agreed to quit but has not finished, for example because it is waiting on a save prompt. Finish or cancel that prompt, then open MyPass again. Your vault was not opened.", comment: "Single-instance guard alert")
        case .notResponding(let pids):
            return String(localized: "The running MyPass (process \(Self.list(pids))) did not answer in time, for example because it is busy unlocking or saving. It was not asked to quit. Wait a moment, then open MyPass again. Your vault was not opened.", comment: "Single-instance guard alert")
        case .declined(let pids):
            return String(localized: "The running MyPass (process \(Self.list(pids))) did not close, for example because its changes could not be saved or its prompt was cancelled. It is still running. Close it yourself when you are ready, then open MyPass again. Your vault was not opened.", comment: "Single-instance guard alert")
        }
    }

    private static func list(_ pids: [Int32]) -> String {
        pids.sorted().map(String.init).joined(separator: ", ")
    }
}

/// Elects exactly one owner of the user's vault among concurrently running
/// MyPass processes, cooperatively, without any sandbox entitlement.
///
/// A newer production launch (the requester) runs a nondestructive discovery
/// first and a commit second:
///
/// 1. `probe`: it asks everybody to identify themselves. Every live older peer
///    must answer `ready` (owner, launcher or inactive); a live peer that stays
///    silent (a legacy build, a hosted test run, a stuck main thread) means the
///    newcomer cannot win, and it then fails WITHOUT ever having asked anyone to
///    quit. Nothing can be quit by a probe.
/// 2. `commit`: only once every live peer is accounted for, the requester sends
///    a commit that carries a deadline on the shared monotonic clock. An owner
///    that receives one before the deadline acknowledges and quits through the
///    normal AppKit path (`requestQuit`), which flushes the vault first. A
///    delayed or reordered commit that arrives after its deadline, after a
///    `withdraw`, or after the requester died is ignored; nothing is
///    ever force-killed.
///
/// Per attempt (requester identity + attempt number) the owner remembers what it
/// did: an attempt it declined stays declined, so retransmissions cannot raise
/// the save prompt again, while a genuinely new attempt is served normally. A
/// requester that gives up (or fails) sends `withdraw` and stays alive as an
/// `inactive` process that answers probes without holding anything.
///
/// Honest limit: this is not an atomic distributed commit. An owner that
/// accepted a commit just before the requester gave up has already started its
/// normal quit and cannot take it back; the requester then ends in a failure
/// message and the user simply opens MyPass again. The deadline plus the accept
/// margin keep that window to message latency.
///
/// Every received message is re-validated against the kernel: the sender must
/// be alive with exactly the claimed start time and be a recognised peer.
/// Anything stale, malformed, addressed to someone else, or sent by oneself is
/// ignored.
final class SingleInstanceCoordinator {
    enum Phase: Equatable {
        case idle, acquiring, owner, quitting, yielded
        /// This launch failed its election. It holds no vault, no bridge and no
        /// lock and only shows a message, but it keeps answering probes so it
        /// never blocks a later launch.
        case inactive
    }

    enum Outcome: Equatable {
        case owner
        /// A newer launch won the election. This process must exit without opening anything.
        case yielded
        case failed(SingleInstanceFailure)
    }

    enum LockAttempt {
        /// The returned object is retained for the coordinator's lifetime (it owns the descriptor).
        case acquired(AnyObject)
        case held
        case failed(String)
    }

    /// Longest commit window any receiver honours, whatever the sender claims.
    private static let maximumCommitWindow: TimeInterval = 30
    private static let maximumRecords = 32

    private struct AttemptRecord {
        enum Status: Equatable {
            case accepted(deadline: TimeInterval)
            case refused
            case withdrawn
        }

        let requester: ProcessIdentity
        let attempt: UInt64
        var status: Status
    }

    private let host: SingleInstanceHost
    private let tryLock: () -> LockAttempt
    private let requestQuit: () -> Void
    private let abandonWhileInactive: () -> Void
    private let timing: SingleInstanceTiming

    private(set) var phase: Phase = .idle
    private var me: ProcessIdentity?
    private var listenerToken: AnyObject?
    private var lockHolder: AnyObject?

    // Requester side (this process is in its own election).
    private var attempt: UInt64 = 0
    private var committedDeadline: TimeInterval?
    private var readiness: [ProcessIdentity: SingleInstanceMessage.Role] = [:]
    private var acknowledged = Set<ProcessIdentity>()
    private var declinedBy = Set<ProcessIdentity>()
    /// Newer launches that announced themselves and have not withdrawn: this
    /// process must not take ownership ahead of them and yields to their commit.
    private var superiors: [ProcessIdentity: UInt64] = [:]
    private var yieldTo: ProcessIdentity?

    // Receiver side (this process is the owner, or a launch deciding whether to yield).
    private var records: [AttemptRecord] = []
    private var quitStarted = false

    /// - Parameters:
    ///   - requestQuit: starts the normal AppKit termination. It is only ever
    ///     called from a run-loop block (`host.performSoon`), after the
    ///     acknowledgement went out and only while the request is still live.
    ///   - abandonWhileInactive: called when a newer launch commits while this
    ///     process is the inactive loser showing its failure message: it should
    ///     dismiss the message and exit.
    init(
        host: SingleInstanceHost,
        timing: SingleInstanceTiming = SingleInstanceTiming(),
        tryLock: @escaping () -> LockAttempt,
        requestQuit: @escaping () -> Void,
        abandonWhileInactive: @escaping () -> Void = {}
    ) {
        self.host = host
        self.timing = timing
        self.tryLock = tryLock
        self.requestQuit = requestQuit
        self.abandonWhileInactive = abandonWhileInactive
    }

    /// The owner's quit was cancelled (the user answered "Cancel" to the save
    /// prompt): go back to serving requests, but tell every requester whose
    /// commit started this quit that it was declined. Those attempts stay
    /// declined, so their retransmissions cannot raise the prompt again.
    func quitWasCancelled() {
        guard phase == .quitting, let me else { return }
        phase = .owner
        quitStarted = false
        for index in records.indices {
            guard case .accepted = records[index].status else { continue }
            records[index].status = .refused
            host.send(.refuse(from: me, to: records[index].requester, attempt: records[index].attempt))
        }
    }

    // MARK: - Election (requester)

    /// Runs the election. Pumps the main run loop while waiting so messages are
    /// delivered; call it before any other startup side effect.
    func acquire() -> Outcome {
        guard let me = host.selfIdentity else { return .failed(.identityUnavailable) }
        self.me = me
        attempt = host.nextAttemptID()
        phase = .acquiring
        // Listen BEFORE the first probe: two concurrent launches must be able to
        // see each other, and the newer one has to defeat the older.
        listenerToken = host.startListening { [weak self] payload in self?.handle(payload: payload) }

        let start = host.monotonicNow()
        var lastPost = -TimeInterval.infinity
        var firstSeen: [ProcessIdentity: TimeInterval] = [:]
        while true {
            let now = host.monotonicNow()
            let elapsed = now - start

            if yieldTo != nil {
                phase = .yielded
                listenerToken = nil
                return .yielded
            }
            let declined = declinedBy.filter(host.isAlive)
            if !declined.isEmpty { return fail(.declined(declined.map(\.pid))) }

            if now - lastPost >= timing.repostInterval {
                if let deadline = committedDeadline {
                    host.send(.commit(from: me, attempt: attempt, deadlineMillis: Self.millis(deadline)))
                } else {
                    host.send(.probe(from: me, attempt: attempt))
                }
                lastPost = now
            }

            readiness = readiness.filter { host.isAlive($0.key) }
            acknowledged = acknowledged.filter(host.isAlive)
            superiors = superiors.filter { host.isAlive($0.key) }
            let others = host.livePeers().union(readiness.keys).union(superiors.keys).subtracting([me])
            firstSeen = firstSeen.filter { others.contains($0.key) }
            for peer in others where firstSeen[peer] == nil { firstSeen[peer] = now }

            var cooperating = Set<ProcessIdentity>()
            var unknown = Set<ProcessIdentity>()
            var deferred = Set<ProcessIdentity>()
            for peer in others {
                if superiors[peer] != nil {
                    deferred.insert(peer)
                    continue
                }
                switch readiness[peer] {
                case .inactive?: continue
                case .owner?, .launcher?: cooperating.insert(peer)
                case nil: unknown.insert(peer)
                }
            }

            // A live peer that stays silent is not a cooperating MyPass. We fail
            // before the commit, so nobody has been asked to quit.
            let silent = unknown.filter { now - (firstSeen[$0] ?? now) >= timing.ackGrace }
            if !silent.isEmpty { return fail(.unrecognizedPeers(silent.map(\.pid))) }

            if let deadline = committedDeadline {
                let unacknowledged = cooperating.subtracting(acknowledged)
                if now >= deadline + timing.ackSlack, !unacknowledged.isEmpty {
                    return fail(.notResponding(unacknowledged.map(\.pid)))
                }
            }

            if elapsed >= timing.quietPeriod, deferred.isEmpty, unknown.isEmpty {
                if cooperating.isEmpty {
                    switch tryLock() {
                    case .acquired(let holder):
                        lockHolder = holder
                        phase = .owner
                        return .owner
                    case .failed(let detail):
                        return fail(.lockUnavailable(detail))
                    case .held:
                        if elapsed >= timing.ackGrace { return fail(.lockHeldByUnknownProcess) }
                    }
                } else if committedDeadline == nil {
                    // Every live peer answered: only now is anybody asked to leave.
                    committedDeadline = now + timing.commitWindow
                    lastPost = -TimeInterval.infinity  // send the commit on the next line of this loop
                }
            }

            if elapsed >= timing.waitBound {
                let stuck = cooperating.union(deferred).union(unknown).map(\.pid)
                if committedDeadline != nil, cooperating.subtracting(acknowledged).isEmpty, deferred.isEmpty, unknown.isEmpty {
                    return fail(.timedOut(stuck))
                }
                return fail(.notResponding(stuck))
            }
            host.pump(for: timing.tick)
        }
    }

    /// The election was lost or abandoned. Withdraw the attempt so nobody can
    /// still be made to quit for it, and stay alive as an inactive process that
    /// keeps answering probes (it holds nothing).
    private func fail(_ failure: SingleInstanceFailure) -> Outcome {
        if let me { host.send(.withdraw(from: me, attempt: attempt)) }
        phase = .inactive
        readiness = [:]
        acknowledged = []
        superiors = [:]
        return .failed(failure)
    }

    private static func millis(_ seconds: TimeInterval) -> UInt64 {
        UInt64(max(0, seconds * 1000).rounded(.up))
    }

    // MARK: - Messages

    /// Entry point for every raw notification payload. Public to the module so
    /// tests can feed forged, stale or malformed payloads directly.
    func handle(payload: String) {
        guard let me, phase != .idle, let message = SingleInstanceMessage(wire: payload), message.sender != me else { return }
        let sender = message.sender
        switch message.kind {
        case .probe(let attempt):
            handleProbe(from: sender, attempt: attempt, me: me)
        case .commit(let attempt, let deadlineMillis):
            handleCommit(from: sender, attempt: attempt, deadlineMillis: deadlineMillis, me: me)
        case .withdraw(let attempt):
            handleWithdraw(from: sender, attempt: attempt)
        case .ready(let target, let attempt, let role):
            guard phase == .acquiring, target == me, attempt == self.attempt, isLivePeer(sender) else { return }
            readiness[sender] = role
        case .ack(let target, let attempt):
            guard isAnswerToMyCommit(from: sender, target: target, attempt: attempt, me: me) else { return }
            acknowledged.insert(sender)
        case .refuse(let target, let attempt):
            guard isAnswerToMyCommit(from: sender, target: target, attempt: attempt, me: me) else { return }
            declinedBy.insert(sender)
        }
    }

    private func isLivePeer(_ identity: ProcessIdentity) -> Bool {
        host.isAlive(identity) && host.isRecognizedPeer(identity)
    }

    /// An ack or refuse counts only if it answers THIS attempt's commit, from a
    /// peer that answered the probe, while it is alive.
    private func isAnswerToMyCommit(from sender: ProcessIdentity, target: ProcessIdentity, attempt: UInt64, me: ProcessIdentity) -> Bool {
        guard phase == .acquiring, committedDeadline != nil, target == me, attempt == self.attempt else { return false }
        guard let role = readiness[sender], role != .inactive else { return false }
        return isLivePeer(sender)
    }

    private func handleProbe(from sender: ProcessIdentity, attempt: UInt64, me: ProcessIdentity) {
        guard isLivePeer(sender), record(for: sender, attempt)?.status != .withdrawn else { return }
        switch phase {
        case .inactive:
            // Holds nothing, so it answers anyone, whichever is newer.
            host.send(.ready(from: me, to: sender, attempt: attempt, role: .inactive))
        case .acquiring:
            guard sender > me else { return }
            superiors[sender] = attempt
            host.send(.ready(from: me, to: sender, attempt: attempt, role: .launcher))
        case .owner, .quitting:
            guard sender > me else { return }
            host.send(.ready(from: me, to: sender, attempt: attempt, role: .owner))
        case .idle, .yielded:
            return
        }
    }

    private func handleCommit(from sender: ProcessIdentity, attempt: UInt64, deadlineMillis: UInt64, me: ProcessIdentity) {
        guard sender > me, isLivePeer(sender) else { return }
        switch record(for: sender, attempt)?.status {
        case .withdrawn?:
            return
        case .refused?:
            // Declined once for this very attempt: say so again, never ask again.
            host.send(.refuse(from: me, to: sender, attempt: attempt))
            return
        case .accepted?:
            host.send(.ack(from: me, to: sender, attempt: attempt))  // a retransmission
            return
        case nil:
            break
        }
        let now = host.monotonicNow()
        let deadline = TimeInterval(deadlineMillis) / 1000
        // A commit that is already (almost) over or absurdly far ahead is no commit.
        guard deadline >= now + timing.acceptMargin, deadline <= now + Self.maximumCommitWindow else { return }

        switch phase {
        case .idle:
            return
        case .acquiring:
            // A newer launch won: acknowledge and leave without ever owning.
            setRecord(for: sender, attempt, status: .accepted(deadline: deadline))
            host.send(.ack(from: me, to: sender, attempt: attempt))
            if yieldTo.map({ sender > $0 }) ?? true { yieldTo = sender }
        case .yielded:
            host.send(.ack(from: me, to: sender, attempt: attempt))
        case .inactive:
            host.send(.ack(from: me, to: sender, attempt: attempt))
            abandonWhileInactive()
        case .owner:
            setRecord(for: sender, attempt, status: .accepted(deadline: deadline))
            phase = .quitting
            quitStarted = false
            // Acknowledge BEFORE asking to quit. `NSApp.terminate` does not
            // return while a `terminateLater` (the save-flush) is pending, so
            // an ack sent afterwards would arrive only once the old process
            // is already gone and the newcomer would mistake it for a silent
            // build. The quit itself starts on a later run-loop turn and only
            // if the request is still live then.
            host.send(.ack(from: me, to: sender, attempt: attempt))
            host.performSoon { [weak self] in self?.startQuitIfStillRequested() }
        case .quitting:
            // Already on the way out: this requester can wait for the same exit.
            setRecord(for: sender, attempt, status: .accepted(deadline: deadline))
            host.send(.ack(from: me, to: sender, attempt: attempt))
        }
    }

    private func handleWithdraw(from sender: ProcessIdentity, attempt: UInt64) {
        // Withdrawing can only make the system quieter, so it is honoured even
        // from a sender that has already exited (the message may simply be late).
        setRecord(for: sender, attempt, status: .withdrawn)
        if superiors[sender] == attempt { superiors[sender] = nil }
        if phase == .acquiring, isLivePeer(sender) {
            // A requester that withdrew holds nothing: nobody has to wait for it.
            readiness[sender] = .inactive
        }
    }

    /// Runs on a run-loop turn after the acknowledgement. Starts the normal quit
    /// only while some accepted request is still live: its requester alive and
    /// its deadline not over. Otherwise the request was abandoned or expired
    /// while queued, and the owner simply stays the owner.
    private func startQuitIfStillRequested() {
        guard phase == .quitting, !quitStarted else { return }
        let now = host.monotonicNow()
        let live = records.contains { record in
            guard case .accepted(let deadline) = record.status else { return false }
            return now <= deadline && host.isAlive(record.requester)
        }
        guard live else {
            for index in records.indices where records[index].status != .refused {
                if case .accepted = records[index].status { records[index].status = .withdrawn }
            }
            phase = .owner
            return
        }
        quitStarted = true
        requestQuit()
    }

    // MARK: - Attempt records

    private func record(for requester: ProcessIdentity, _ attempt: UInt64) -> AttemptRecord? {
        records.first { $0.requester == requester && $0.attempt == attempt }
    }

    private func setRecord(for requester: ProcessIdentity, _ attempt: UInt64, status: AttemptRecord.Status) {
        if let index = records.firstIndex(where: { $0.requester == requester && $0.attempt == attempt }) {
            // A withdrawal is final for the attempt, and so is a refusal (it can only become a withdrawal).
            switch (records[index].status, status) {
            case (.withdrawn, _), (.refused, .accepted): return
            default: records[index].status = status
            }
            return
        }
        records.append(AttemptRecord(requester: requester, attempt: attempt, status: status))
        if records.count > Self.maximumRecords { records.removeFirst(records.count - Self.maximumRecords) }
    }
}
