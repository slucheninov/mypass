import XCTest
@testable import MyPass

/// Scripted host with a virtual clock: `pump` advances time and fires due events.
final class FakeSingleInstanceHost: SingleInstanceHost {
    var selfIdentity: ProcessIdentity?
    var now: TimeInterval = 0
    var alive = Set<ProcessIdentity>()
    var visible = Set<ProcessIdentity>()
    var recognized = Set<ProcessIdentity>()
    private(set) var sent: [(at: TimeInterval, message: SingleInstanceMessage)] = []
    private(set) var listenerStarts = 0
    private var handler: ((String) -> Void)?
    private var events: [(at: TimeInterval, action: () -> Void)] = []
    /// When set, this host shares another host's clock and event queue, so several
    /// coordinators can live in one deterministic virtual world.
    var timeSource: FakeSingleInstanceHost?
    /// Called for every message this host sends (used to wire hosts together).
    var outbox: ((SingleInstanceMessage) -> Void)?
    /// How long `performSoon` blocks wait (a busy or slow main run loop).
    var performDelay: TimeInterval = 0
    private var attemptCounter: UInt64 = 1000

    init(me: ProcessIdentity?) {
        selfIdentity = me
        if let me { alive.insert(me); recognized.insert(me) }
    }

    func livePeers() -> Set<ProcessIdentity> { visible.filter { alive.contains($0) } }
    func isAlive(_ identity: ProcessIdentity) -> Bool { alive.contains(identity) }
    func isRecognizedPeer(_ identity: ProcessIdentity) -> Bool { recognized.contains(identity) }
    func send(_ message: SingleInstanceMessage) {
        sent.append((monotonicNow(), message))
        outbox?(message)
    }
    func nextAttemptID() -> UInt64 {
        attemptCounter += 1
        return attemptCounter
    }
    func performSoon(_ block: @escaping () -> Void) {
        at(monotonicNow() + performDelay, block)
    }
    func startListening(_ handler: @escaping (String) -> Void) -> AnyObject {
        listenerStarts += 1
        self.handler = handler
        return NSObject()
    }
    func monotonicNow() -> TimeInterval { (timeSource ?? self).now }
    func pump(for interval: TimeInterval) {
        let target = now + interval
        // Earliest event first (insertion order breaks ties), so events scheduled
        // dynamically by other hosts still fire in virtual-time order.
        while let index = events.indices.filter({ events[$0].at <= target }).min(by: { events[$0].at < events[$1].at }) {
            let event = events.remove(at: index)
            now = max(now, event.at)
            event.action()
        }
        now = target
    }

    // Scenario helpers
    func addPeer(_ peer: ProcessIdentity, recognized isRecognized: Bool = true, visible isVisible: Bool = true) {
        alive.insert(peer)
        if isRecognized { recognized.insert(peer) }
        if isVisible { visible.insert(peer) }
    }
    func killPeer(_ peer: ProcessIdentity) { alive.remove(peer); visible.remove(peer) }
    func at(_ time: TimeInterval, _ action: @escaping () -> Void) {
        if let timeSource { timeSource.at(time, action) } else { events.append((time, action)) }
    }
    func deliver(_ message: SingleInstanceMessage) { handler?(message.wire) }
    func deliverRaw(_ payload: String) { handler?(payload) }
    var probes: [SingleInstanceMessage] { sent.map(\.message).filter { if case .probe = $0.kind { return true } else { return false } } }
    var commits: [(at: TimeInterval, message: SingleInstanceMessage)] {
        sent.filter { if case .commit = $0.message.kind { return true } else { return false } }
    }
    var withdraws: [SingleInstanceMessage] { sent.map(\.message).filter { if case .withdraw = $0.kind { return true } else { return false } } }
    func acks(to target: ProcessIdentity) -> [SingleInstanceMessage] {
        sent.map(\.message).filter { if case .ack(let t, _) = $0.kind { return t == target } else { return false } }
    }
    func refusals(to target: ProcessIdentity) -> [SingleInstanceMessage] {
        sent.map(\.message).filter { if case .refuse(let t, _) = $0.kind { return t == target } else { return false } }
    }
    func readies(to target: ProcessIdentity) -> [SingleInstanceMessage] {
        sent.map(\.message).filter { if case .ready(let t, _, _) = $0.kind { return t == target } else { return false } }
    }
    /// A commit as a real requester would send it: the deadline is `window` after this host's now.
    func commit(from sender: ProcessIdentity, attempt: UInt64, window: TimeInterval = 3) -> SingleInstanceMessage {
        .commit(from: sender, attempt: attempt, deadlineMillis: UInt64((monotonicNow() + window) * 1000))
    }
}

final class SingleInstanceCoordinatorTests: XCTestCase {
    private let me = ProcessIdentity(pid: 500, startMicroseconds: 5_000_000)
    private let old = ProcessIdentity(pid: 100, startMicroseconds: 1_000_000)
    private let older = ProcessIdentity(pid: 90, startMicroseconds: 900_000)
    private let newer = ProcessIdentity(pid: 700, startMicroseconds: 7_000_000)
    private let newest = ProcessIdentity(pid: 800, startMicroseconds: 8_000_000)
    /// The first id a `FakeSingleInstanceHost` hands out, i.e. this process's attempt.
    private let attempt: UInt64 = 1001

    private var lockAttempts: [TimeInterval] = []
    private var quitRequests = 0
    private var abandons = 0

    private func makeCoordinator(
        _ host: FakeSingleInstanceHost,
        lock: @escaping () -> SingleInstanceCoordinator.LockAttempt = { .acquired(NSObject()) }
    ) -> SingleInstanceCoordinator {
        SingleInstanceCoordinator(
            host: host,
            tryLock: { [unowned host] in
                self.lockAttempts.append(host.now)
                return lock()
            },
            requestQuit: { self.quitRequests += 1 },
            abandonWhileInactive: { self.abandons += 1 }
        )
    }

    // Scripted answers of a peer to this process's probe and commit.
    private func answer(_ host: FakeSingleInstanceHost, _ peer: ProcessIdentity, role: SingleInstanceMessage.Role = .owner, at time: TimeInterval) {
        host.at(time) { host.deliver(.ready(from: peer, to: self.me, attempt: self.attempt, role: role)) }
    }

    private func acknowledge(_ host: FakeSingleInstanceHost, _ peer: ProcessIdentity, at time: TimeInterval) {
        host.at(time) { host.deliver(.ack(from: peer, to: self.me, attempt: self.attempt)) }
    }

    // MARK: - Newcomer

    func testFirstLaunchWithNoPeersOwnsAfterQuietPeriod() {
        let host = FakeSingleInstanceHost(me: me)
        let coordinator = makeCoordinator(host)
        XCTAssertEqual(coordinator.acquire(), .owner)
        XCTAssertEqual(coordinator.phase, .owner)
        XCTAssertEqual(host.listenerStarts, 1)
        XCTAssertFalse(host.probes.isEmpty, "the probe is always sent so an invisible cooperative peer can answer")
        XCTAssertTrue(host.commits.isEmpty, "nobody is ever asked to quit when nobody is there")
        XCTAssertGreaterThanOrEqual(host.now, SingleInstanceTiming().quietPeriod)
        XCTAssertEqual(quitRequests, 0)
    }

    func testOlderCooperativeOwnerFinishesBeforeWeInitialise() {
        let host = FakeSingleInstanceHost(me: me)
        host.addPeer(old)
        let coordinator = makeCoordinator(host)
        answer(host, old, at: 0.1)
        acknowledge(host, old, at: 0.5)
        host.at(3.0) { host.killPeer(self.old) }  // slow save-flush, longer than ackGrace

        XCTAssertEqual(coordinator.acquire(), .owner)
        XCTAssertGreaterThanOrEqual(lockAttempts.first ?? 0, 3.0, "no ownership before the old process is gone")
        XCTAssertEqual(lockAttempts.count, 1)
        XCTAssertEqual(host.commits.count > 0, true)
        XCTAssertGreaterThan(host.commits.first?.at ?? 0, 0.1, "the commit only follows the peer's readiness")
    }

    func testNobodyIsAskedToQuitBeforeEveryLivePeerAnswered() {
        let host = FakeSingleInstanceHost(me: me)
        host.addPeer(old)
        host.addPeer(older)
        let coordinator = makeCoordinator(host)
        answer(host, old, at: 0.1)
        answer(host, older, at: 1.2)  // slow, but within the grace
        acknowledge(host, old, at: 1.6)
        acknowledge(host, older, at: 1.6)
        host.at(2.0) { host.killPeer(self.old); host.killPeer(self.older) }
        XCTAssertEqual(coordinator.acquire(), .owner)
        XCTAssertGreaterThanOrEqual(host.commits.first?.at ?? 0, 1.2, "no commit while a live peer is still unaccounted for")
    }

    func testCommitIsRepostedWhileWaitingAndCarriesASharedDeadline() {
        let host = FakeSingleInstanceHost(me: me)
        host.addPeer(old)
        let coordinator = makeCoordinator(host)
        answer(host, old, at: 0.1)
        acknowledge(host, old, at: 0.6)
        host.at(2.2) { host.killPeer(self.old) }
        _ = coordinator.acquire()
        XCTAssertGreaterThanOrEqual(host.commits.count, 3, "the old process may be busy; retry")
        let deadlines = Set(host.commits.compactMap { entry -> UInt64? in
            if case .commit(_, let deadline) = entry.message.kind { return deadline } else { return nil }
        })
        XCTAssertEqual(deadlines.count, 1, "every retransmission carries the SAME deadline, so it can never extend the window")
        let first = host.commits[0]
        XCTAssertEqual(Double(deadlines.first ?? 0) / 1000, first.at + SingleInstanceTiming().commitWindow, accuracy: 0.06)
    }

    func testInvisibleCooperativePeerIsWaitedForViaItsReady() {
        // runningApplications is empty (direct-exec peer / flaky enumeration), but it answers.
        let host = FakeSingleInstanceHost(me: me)
        host.addPeer(old, visible: false)
        let coordinator = makeCoordinator(host)
        answer(host, old, at: 0.05)
        acknowledge(host, old, at: 0.5)
        host.at(1.0) { host.killPeer(self.old) }
        XCTAssertEqual(coordinator.acquire(), .owner)
        XCTAssertGreaterThanOrEqual(lockAttempts.first ?? 0, 1.0)
    }

    func testNewestLaunchWinsOverlappingRequests() {
        // Existing owner `old` and an older concurrent launcher `older`; we are the newest.
        let host = FakeSingleInstanceHost(me: me)
        host.addPeer(old)
        host.addPeer(older)
        let coordinator = makeCoordinator(host)
        answer(host, old, at: 0.1)
        answer(host, older, role: .launcher, at: 0.1)
        acknowledge(host, old, at: 0.5)
        acknowledge(host, older, at: 0.5)
        host.at(0.7) { host.killPeer(self.older) }
        host.at(1.4) { host.killPeer(self.old) }
        XCTAssertEqual(coordinator.acquire(), .owner)
        XCTAssertGreaterThanOrEqual(lockAttempts.first ?? 0, 1.4)
    }

    func testPeerThatFailedItsOwnElectionIsInactiveAndNeverBlocksUs() {
        let host = FakeSingleInstanceHost(me: me)
        host.addPeer(old)  // alive and visible, but only shows an error message
        let coordinator = makeCoordinator(host)
        answer(host, old, role: .inactive, at: 0.05)
        XCTAssertEqual(coordinator.acquire(), .owner)
        XCTAssertTrue(host.commits.isEmpty, "an inactive process needs neither a quit nor a wait")
        XCTAssertLessThan(host.now, 1)
    }

    func testOlderLauncherYieldsToANewerCommitWithoutEverOwning() {
        let host = FakeSingleInstanceHost(me: me)
        host.addPeer(newer)
        let coordinator = makeCoordinator(host)
        host.at(0.1) { host.deliver(.probe(from: self.newer, attempt: 7)) }
        host.at(0.3) { host.deliver(host.commit(from: self.newer, attempt: 7)) }
        XCTAssertEqual(coordinator.acquire(), .yielded)
        XCTAssertTrue(lockAttempts.isEmpty, "a defeated launcher never touches the lock")
        XCTAssertEqual(host.readies(to: newer).count, 1, "it told the newcomer it is a cooperating launcher")
        XCTAssertEqual(host.acks(to: newer).count, 1, "tells the winner it is leaving")
        XCTAssertEqual(quitRequests, 0)
    }

    func testOlderLauncherDoesNotYieldToAProbeAloneButWaitsForTheCommit() {
        let host = FakeSingleInstanceHost(me: me)
        host.addPeer(newer)
        let coordinator = makeCoordinator(host)
        host.at(0.1) { host.deliver(.probe(from: self.newer, attempt: 7)) }
        host.at(4.0) { host.deliver(host.commit(from: self.newer, attempt: 7)) }
        XCTAssertEqual(coordinator.acquire(), .yielded)
        XCTAssertGreaterThanOrEqual(host.now, 4.0, "a probe causes no yield; waiting is bounded but longer than the grace")
        XCTAssertTrue(lockAttempts.isEmpty)
    }

    func testOlderLauncherResumesWhenTheNewcomerWithdrawsAndNeverBlocksIt() {
        let host = FakeSingleInstanceHost(me: me)
        host.addPeer(newer)  // stays alive, showing its failure message
        let coordinator = makeCoordinator(host)
        host.at(0.1) { host.deliver(.probe(from: self.newer, attempt: 7)) }
        host.at(1.0) { host.deliver(.withdraw(from: self.newer, attempt: 7)) }
        XCTAssertEqual(coordinator.acquire(), .owner)
        XCTAssertGreaterThanOrEqual(lockAttempts.first ?? 0, 1.0)
    }

    func testNewestOfSeveralConcurrentRequestersIsTheOneAcknowledgedAsWinner() {
        let host = FakeSingleInstanceHost(me: me)
        host.addPeer(newer)
        host.addPeer(newest)
        let coordinator = makeCoordinator(host)
        host.at(0.1) {
            host.deliver(.probe(from: self.newest, attempt: 8))
            host.deliver(.probe(from: self.newer, attempt: 7))
        }
        host.at(0.3) {
            host.deliver(host.commit(from: self.newest, attempt: 8))
            host.deliver(host.commit(from: self.newer, attempt: 7))
        }
        XCTAssertEqual(coordinator.acquire(), .yielded)
        XCTAssertEqual(host.acks(to: newest).count, 1)
        XCTAssertEqual(host.acks(to: newer).count, 1)
    }

    func testAnOlderRequestDoesNotDefeatUs() {
        let host = FakeSingleInstanceHost(me: me)
        host.addPeer(old)
        let coordinator = makeCoordinator(host)
        host.at(0.1) { host.deliver(.probe(from: self.old, attempt: 3)) }  // the older launcher will yield to us instead
        host.at(0.2) { host.deliver(host.commit(from: self.old, attempt: 3)) }
        answer(host, old, role: .launcher, at: 0.2)
        acknowledge(host, old, at: 0.5)
        host.at(0.6) { host.killPeer(self.old) }
        XCTAssertEqual(coordinator.acquire(), .owner)
        XCTAssertTrue(host.acks(to: old).isEmpty)
        XCTAssertTrue(host.readies(to: old).isEmpty)
    }

    func testUnresponsiveOlderPeerFailsClosedBeforeAnyoneIsAskedToQuit() {
        // A pre-guard build or a hosted test run: alive, recognised, never answers.
        let host = FakeSingleInstanceHost(me: me)
        host.addPeer(old)
        let coordinator = makeCoordinator(host)
        XCTAssertEqual(coordinator.acquire(), .failed(.unrecognizedPeers([old.pid])))
        XCTAssertTrue(lockAttempts.isEmpty)
        XCTAssertTrue(host.commits.isEmpty, "no commit may ever be sent while a peer is silent")
        XCTAssertEqual(host.withdraws.count, 1, "the failed attempt is withdrawn")
        XCTAssertGreaterThanOrEqual(host.now, SingleInstanceTiming().ackGrace)
        XCTAssertLessThan(host.now, SingleInstanceTiming().waitBound, "no point waiting out the full bound for a silent peer")
        XCTAssertEqual(coordinator.phase, .inactive)
    }

    func testSilentPeerBesideACooperativeOwnerBlocksTheCommit() {
        let host = FakeSingleInstanceHost(me: me)
        host.addPeer(old)
        host.addPeer(older)
        let coordinator = makeCoordinator(host)
        answer(host, old, at: 0.1)  // `older` never answers
        XCTAssertEqual(coordinator.acquire(), .failed(.unrecognizedPeers([older.pid])))
        XCTAssertTrue(host.commits.isEmpty, "the owner is never asked while another peer is unaccounted for")
    }

    func testSilentNewerPeerFailsClosed() {
        let host = FakeSingleInstanceHost(me: me)
        host.addPeer(newer)  // appeared after us but never announced itself
        let coordinator = makeCoordinator(host)
        XCTAssertEqual(coordinator.acquire(), .failed(.unrecognizedPeers([newer.pid])))
        XCTAssertTrue(lockAttempts.isEmpty)
    }

    func testAcknowledgedPeerThatNeverExitsTimesOutAndNeverOwns() {
        let host = FakeSingleInstanceHost(me: me)
        host.addPeer(old)
        let coordinator = makeCoordinator(host)
        answer(host, old, at: 0.1)
        acknowledge(host, old, at: 0.5)  // e.g. user sits on a Cancel/Quit Anyway dialog
        XCTAssertEqual(coordinator.acquire(), .failed(.timedOut([old.pid])))
        XCTAssertTrue(lockAttempts.isEmpty, "refusal or timeout creates no vault, bridge or lock")
        XCTAssertGreaterThanOrEqual(host.now, SingleInstanceTiming().waitBound)
        XCTAssertEqual(coordinator.phase, .inactive)
    }

    func testPeerThatAnsweredButNeverAcceptedTheCommitIsNotWaitedForForever() {
        let host = FakeSingleInstanceHost(me: me)
        host.addPeer(old)
        let coordinator = makeCoordinator(host)
        answer(host, old, at: 0.1)  // a busy main thread: answers once, then nothing
        XCTAssertEqual(coordinator.acquire(), .failed(.notResponding([old.pid])))
        let timing = SingleInstanceTiming()
        let commitAt = host.commits.first?.at ?? 0
        XCTAssertGreaterThanOrEqual(host.now, commitAt + timing.commitWindow, "waits out the commit's own deadline")
        XCTAssertLessThan(host.now, commitAt + timing.commitWindow + 1, "and no longer: the commit is dead afterwards")
        XCTAssertEqual(host.withdraws.count, 1)
    }

    func testAnExplicitRefusalEndsTheAttemptAtOnce() {
        let host = FakeSingleInstanceHost(me: me)
        host.addPeer(old)
        let coordinator = makeCoordinator(host)
        answer(host, old, at: 0.1)
        acknowledge(host, old, at: 0.4)
        host.at(0.6) { host.deliver(.refuse(from: self.old, to: self.me, attempt: self.attempt)) }
        XCTAssertEqual(coordinator.acquire(), .failed(.declined([old.pid])))
        XCTAssertLessThan(host.now, 1, "stops immediately, does not wait out the bound")
        XCTAssertTrue(lockAttempts.isEmpty)
        XCTAssertEqual(host.withdraws.count, 1)
        let commitsBefore = host.commits.count
        for _ in 0..<40 { host.pump(for: 0.05) }
        XCTAssertEqual(host.commits.count, commitsBefore, "no further request after the denial")
    }

    func testUnknownIdentityFailsClosedBeforeAnyMessage() {
        let host = FakeSingleInstanceHost(me: nil)
        let coordinator = makeCoordinator(host)
        XCTAssertEqual(coordinator.acquire(), .failed(.identityUnavailable))
        XCTAssertTrue(host.sent.isEmpty)
        XCTAssertEqual(host.listenerStarts, 0)
        XCTAssertTrue(lockAttempts.isEmpty)
    }

    func testLockHeldByAnInvisibleSilentProcessFailsClosed() {
        let host = FakeSingleInstanceHost(me: me)
        let coordinator = makeCoordinator(host, lock: { .held })
        XCTAssertEqual(coordinator.acquire(), .failed(.lockHeldByUnknownProcess))
    }

    func testLockErrorFailsClosed() {
        let host = FakeSingleInstanceHost(me: me)
        let coordinator = makeCoordinator(host, lock: { .failed("boom") })
        XCTAssertEqual(coordinator.acquire(), .failed(.lockUnavailable("boom")))
    }

    func testFailureMessagesAreActionableEnglish() {
        let all: [SingleInstanceFailure] = [
            .identityUnavailable, .lockUnavailable("x"), .unrecognizedPeers([1, 2]), .lockHeldByUnknownProcess,
            .timedOut([3]), .notResponding([4]), .declined([5]),
        ]
        for failure in all {
            XCTAssertFalse(failure.title.isEmpty)
            XCTAssertTrue(failure.message.contains("Your vault was not opened"), failure.message)
            XCTAssertNil(failure.message.range(of: "\\p{Cyrillic}", options: .regularExpression))
        }
        XCTAssertTrue(SingleInstanceFailure.notResponding([4]).message.contains("not asked to quit"))
    }

    // MARK: - Spurious, stale and forged answers

    func testAckAndRefuseNeedAReadyAnswerTheCommitAndTheRightAttemptAndTarget() {
        let host = FakeSingleInstanceHost(me: me)
        host.addPeer(old)  // silent: never says ready
        let coordinator = makeCoordinator(host)
        host.at(0.05) { host.deliver(.ack(from: self.old, to: self.me, attempt: self.attempt)) }      // no ready, no commit yet
        host.at(0.06) { host.deliver(.refuse(from: self.old, to: self.me, attempt: self.attempt)) }
        host.at(0.07) { host.deliver(.ack(from: self.old, to: self.older, attempt: self.attempt)) }    // wrong target
        host.at(0.08) { host.deliver(.ack(from: self.old, to: self.me, attempt: self.attempt + 5)) }   // wrong attempt
        XCTAssertEqual(coordinator.acquire(), .failed(.unrecognizedPeers([old.pid])), "still just a silent peer")
        XCTAssertTrue(host.commits.isEmpty)
    }

    func testReadyFromDeadForgedOrWrongAttemptAnswersIsIgnored() {
        let host = FakeSingleInstanceHost(me: me)
        host.addPeer(old)
        let stranger = ProcessIdentity(pid: 300, startMicroseconds: 3_000_000)
        host.addPeer(stranger, recognized: false, visible: false)
        let deadPeer = ProcessIdentity(pid: 310, startMicroseconds: 3_100_000)
        let coordinator = makeCoordinator(host)
        host.at(0.05) { host.deliver(.ready(from: self.old, to: self.me, attempt: self.attempt + 1, role: .owner)) }  // wrong attempt
        host.at(0.06) { host.deliver(.ready(from: self.old, to: self.older, attempt: self.attempt, role: .owner)) }   // wrong target
        host.at(0.07) { host.deliver(.ready(from: stranger, to: self.me, attempt: self.attempt, role: .inactive)) }   // not a MyPass
        host.at(0.08) { host.deliver(.ready(from: deadPeer, to: self.me, attempt: self.attempt, role: .inactive)) }   // not alive
        host.at(0.09) { host.deliverRaw("v2 ready garbage") }
        XCTAssertEqual(coordinator.acquire(), .failed(.unrecognizedPeers([old.pid])))
        XCTAssertTrue(host.commits.isEmpty, "none of those answers counts as readiness")
    }

    // MARK: - Owner

    private func makeOwner(_ host: FakeSingleInstanceHost) -> SingleInstanceCoordinator {
        let coordinator = makeCoordinator(host)
        XCTAssertEqual(coordinator.acquire(), .owner)
        quitRequests = 0
        return coordinator
    }

    func testOwnerAnswersAProbeButNeverQuitsBecauseOfIt() {
        let host = FakeSingleInstanceHost(me: me)
        let owner = makeOwner(host)
        host.addPeer(newer)
        host.deliver(.probe(from: newer, attempt: 7))
        host.deliver(.probe(from: newer, attempt: 7))  // retransmission
        for _ in 0..<100 { host.pump(for: 0.05) }
        XCTAssertEqual(host.readies(to: newer).count, 2)
        if case .ready(_, let a, let role) = host.readies(to: newer)[0].kind {
            XCTAssertEqual(a, 7)
            XCTAssertEqual(role, .owner)
        } else { XCTFail() }
        XCTAssertEqual(quitRequests, 0)
        XCTAssertEqual(owner.phase, .owner)
    }

    func testOwnerQuitsNormallyAndAcknowledgesAValidNewerCommit() {
        let host = FakeSingleInstanceHost(me: me)
        let owner = makeOwner(host)
        host.addPeer(newer)
        host.deliver(host.commit(from: newer, attempt: 7))
        XCTAssertEqual(owner.phase, .quitting)
        XCTAssertEqual(host.acks(to: newer).count, 1)
        host.pump(for: 0.05)
        XCTAssertEqual(quitRequests, 1)
        host.deliver(host.commit(from: newer, attempt: 7))  // duplicate / retry
        host.pump(for: 0.05)
        XCTAssertEqual(quitRequests, 1, "one quit per quit attempt")
        XCTAssertEqual(host.acks(to: newer).count, 2, "the retry is still acknowledged")
    }

    func testOwnerAcknowledgesBeforeItAsksToQuitAndNeverQuitsInline() {
        // NSApp.terminate blocks while the save-flush is pending, so the ack must already be out.
        let host = FakeSingleInstanceHost(me: me)
        var acksSentWhenQuitRequested: Int?
        let coordinator = SingleInstanceCoordinator(
            host: host, tryLock: { .acquired(NSObject()) },
            requestQuit: { acksSentWhenQuitRequested = host.acks(to: self.newer).count }
        )
        XCTAssertEqual(coordinator.acquire(), .owner)
        host.addPeer(newer)
        host.deliver(host.commit(from: newer, attempt: 7))
        XCTAssertNil(acksSentWhenQuitRequested, "the quit starts on a later run-loop turn, not inside the notification callback")
        host.pump(for: 0.05)
        XCTAssertEqual(acksSentWhenQuitRequested, 1)
    }

    func testCancelledQuitRefusesThatAttemptAndTheSameAttemptNeverPromptsAgain() {
        let host = FakeSingleInstanceHost(me: me)
        let owner = makeOwner(host)
        host.addPeer(newer)
        host.deliver(host.commit(from: newer, attempt: 7))
        host.pump(for: 0.05)
        XCTAssertEqual(quitRequests, 1)
        owner.quitWasCancelled()
        XCTAssertEqual(owner.phase, .owner)
        XCTAssertEqual(host.refusals(to: newer).count, 1, "the requester is told at once")

        // Retransmissions of the very same attempt, arbitrarily later, are declined again without a prompt.
        for _ in 0..<5 {
            host.pump(for: 0.5)
            host.deliver(host.commit(from: newer, attempt: 7))
        }
        host.pump(for: 0.05)
        XCTAssertEqual(quitRequests, 1, "no prompt loop")
        XCTAssertEqual(owner.phase, .owner)
        XCTAssertEqual(host.refusals(to: newer).count, 6)
    }

    func testANewAttemptAfterARefusalIsServedNormally() {
        let host = FakeSingleInstanceHost(me: me)
        let owner = makeOwner(host)
        host.addPeer(newer)
        host.addPeer(newest)
        host.deliver(host.commit(from: newer, attempt: 7))
        host.pump(for: 0.05)
        owner.quitWasCancelled()
        host.deliver(host.commit(from: newer, attempt: 8))     // the same process, a genuinely new attempt
        host.pump(for: 0.05)
        XCTAssertEqual(quitRequests, 2)
        owner.quitWasCancelled()
        host.deliver(host.commit(from: newest, attempt: 7))    // another requester, same attempt number
        host.pump(for: 0.05)
        XCTAssertEqual(quitRequests, 3, "refusals are per requester AND attempt, not a permanent ban")
    }

    func testExpiredOrImplausibleCommitsAreIgnored() {
        let host = FakeSingleInstanceHost(me: me)
        let owner = makeOwner(host)
        host.addPeer(newer)
        host.now = 10
        host.deliver(host.commit(from: newer, attempt: 1, window: -1))      // already over
        host.deliver(host.commit(from: newer, attempt: 2, window: 0.1))     // under the accept margin: its ack could not arrive in time
        host.deliver(host.commit(from: newer, attempt: 3, window: 3600))    // absurdly far ahead
        host.deliver(.commit(from: newer, attempt: 4, deadlineMillis: 0))
        host.deliver(.commit(from: newer, attempt: 5, deadlineMillis: UInt64.max))
        host.pump(for: 0.2)
        XCTAssertEqual(quitRequests, 0)
        XCTAssertEqual(owner.phase, .owner)
        XCTAssertTrue(host.acks(to: newer).isEmpty, "an expired commit is not even acknowledged")
    }

    func testWithdrawBeforeTheScheduledQuitStartsCancelsIt() {
        let host = FakeSingleInstanceHost(me: me)
        let owner = makeOwner(host)
        host.performDelay = 0.5  // the run loop is busy for a moment
        host.addPeer(newer)
        host.deliver(host.commit(from: newer, attempt: 7))
        XCTAssertEqual(owner.phase, .quitting)
        host.at(host.now + 0.2) { host.deliver(.withdraw(from: self.newer, attempt: 7)) }
        host.pump(for: 1)
        XCTAssertEqual(quitRequests, 0)
        XCTAssertEqual(owner.phase, .owner, "an abandoned request leaves the owner running")
        host.deliver(host.commit(from: newer, attempt: 7))   // a stale retransmission of the withdrawn attempt
        host.pump(for: 1)
        XCTAssertEqual(quitRequests, 0)
    }

    func testCommitReorderedBehindItsWithdrawIsIgnored() {
        let host = FakeSingleInstanceHost(me: me)
        let owner = makeOwner(host)
        host.addPeer(newer)
        host.deliver(.withdraw(from: newer, attempt: 7))
        host.deliver(host.commit(from: newer, attempt: 7))
        host.pump(for: 1)
        XCTAssertEqual(quitRequests, 0)
        XCTAssertEqual(owner.phase, .owner)
        XCTAssertTrue(host.acks(to: newer).isEmpty)
        // A withdraw is honoured even from a sender that already exited.
        host.killPeer(newer)
        host.deliver(.withdraw(from: newer, attempt: 9))
    }

    func testRequesterDyingBeforeTheQuitStartsCancelsIt() {
        let host = FakeSingleInstanceHost(me: me)
        let owner = makeOwner(host)
        host.performDelay = 0.5
        host.addPeer(newer)
        host.deliver(host.commit(from: newer, attempt: 7))
        host.at(host.now + 0.2) { host.killPeer(self.newer) }
        host.pump(for: 1)
        XCTAssertEqual(quitRequests, 0)
        XCTAssertEqual(owner.phase, .owner)
    }

    func testQuitDelayedPastTheCommitDeadlineDoesNotStart() {
        let host = FakeSingleInstanceHost(me: me)
        let owner = makeOwner(host)
        host.performDelay = 3.5  // main thread stuck (for example in a key derivation) past the 3 s window
        host.addPeer(newer)
        host.deliver(host.commit(from: newer, attempt: 7))
        host.pump(for: 5)
        XCTAssertEqual(quitRequests, 0)
        XCTAssertEqual(owner.phase, .owner)
    }

    func testSecondRequesterWhileQuittingJoinsTheSameQuit() {
        let host = FakeSingleInstanceHost(me: me)
        let owner = makeOwner(host)
        host.addPeer(newer)
        host.addPeer(newest)
        host.deliver(host.commit(from: newer, attempt: 7))
        host.pump(for: 0.05)
        host.deliver(host.commit(from: newest, attempt: 2))
        host.pump(for: 0.05)
        XCTAssertEqual(quitRequests, 1, "one quit serves both")
        XCTAssertEqual(host.acks(to: newest).count, 1)
        owner.quitWasCancelled()
        XCTAssertEqual(host.refusals(to: newer).count, 1)
        XCTAssertEqual(host.refusals(to: newest).count, 1, "a cancelled quit is reported to every requester it was accepted for")
    }

    func testAppearanceOfPeersNeverMakesTheOwnerQuitOrSpeak() {
        let host = FakeSingleInstanceHost(me: me)
        let owner = makeOwner(host)
        let testHost = ProcessIdentity(pid: 9000, startMicroseconds: 9_000_000)
        host.addPeer(testHost)  // a hosted test run / preview: newer, recognised, visible, silent
        for _ in 0..<400 { host.pump(for: 0.05) }
        XCTAssertEqual(quitRequests, 0)
        XCTAssertEqual(owner.phase, .owner)
        XCTAssertTrue(host.sent.filter { $0.message.kind != .probe(attempt: 1001) }.isEmpty, "the owner sends nothing unprompted")
    }

    func testOlderProbeIsIgnoredByTheOwner() {
        let host = FakeSingleInstanceHost(me: me)
        let owner = makeOwner(host)
        host.addPeer(old)
        host.deliver(.probe(from: old, attempt: 3))
        host.deliver(host.commit(from: old, attempt: 3))
        host.pump(for: 0.2)
        XCTAssertEqual(quitRequests, 0)
        XCTAssertEqual(owner.phase, .owner)
        XCTAssertTrue(host.readies(to: old).isEmpty)
    }

    func testStaleMalformedAndWrongIdentityMessagesAreIgnoredByTheOwner() {
        let host = FakeSingleInstanceHost(me: me)
        let owner = makeOwner(host)
        let sentBefore = host.sent.count
        let deadNewer = ProcessIdentity(pid: 7100, startMicroseconds: 7_100_000)
        let recycledPid = ProcessIdentity(pid: newer.pid, startMicroseconds: newer.startMicroseconds + 5)
        let stranger = ProcessIdentity(pid: 7300, startMicroseconds: 7_300_000)
        host.addPeer(newer)
        host.addPeer(stranger, recognized: false)
        host.addPeer(old)

        host.deliverRaw("")
        host.deliverRaw("garbage with spaces")
        host.deliverRaw("v1 takeover \(newer.pid) \(newer.startMicroseconds)")           // the old protocol
        host.deliverRaw("v9 commit \(newer.pid) \(newer.startMicroseconds) 1 99999999")
        host.deliverRaw("v2 commit \(newer.pid)")
        host.deliver(host.commit(from: deadNewer, attempt: 1))      // not alive
        host.deliver(host.commit(from: recycledPid, attempt: 1))    // pid alive, start time forged
        host.deliver(host.commit(from: stranger, attempt: 1))       // alive but not a MyPass process
        host.deliver(host.commit(from: old, attempt: 1))            // older than the owner
        host.deliver(host.commit(from: me, attempt: 1))             // our own broadcast echoed back
        host.deliver(.ack(from: newer, to: old, attempt: 1))        // someone else's ack
        host.deliver(.ready(from: newer, to: me, attempt: 1, role: .owner))  // an answer when we asked nothing
        host.deliver(.refuse(from: newer, to: me, attempt: 1))
        host.pump(for: 0.5)
        XCTAssertEqual(quitRequests, 0)
        XCTAssertEqual(owner.phase, .owner)
        XCTAssertEqual(host.sent.count, sentBefore, "nothing was answered")
    }

    func testAttemptRecordsAreBoundedAndTheOwnerStaysResponsive() {
        let host = FakeSingleInstanceHost(me: me)
        let owner = makeOwner(host)
        host.addPeer(newer)
        for attempt in 1...500 { host.deliver(.withdraw(from: newer, attempt: UInt64(attempt))) }
        host.deliver(host.commit(from: newer, attempt: 9999))
        host.pump(for: 0.05)
        XCTAssertEqual(quitRequests, 1)
        XCTAssertEqual(owner.phase, .quitting)
    }

    func testTakeoverMessagesAreIgnoredBeforeTheElectionStarts() {
        let host = FakeSingleInstanceHost(me: me)
        let coordinator = makeCoordinator(host)
        coordinator.handle(payload: host.commit(from: newer, attempt: 7).wire)
        coordinator.handle(payload: SingleInstanceMessage.probe(from: newer, attempt: 7).wire)
        XCTAssertEqual(coordinator.phase, .idle)
        XCTAssertEqual(quitRequests, 0)
        XCTAssertTrue(host.sent.isEmpty)
    }

    // MARK: - Inactive loser

    func testFailedLaunchStaysResponsiveAsInactiveAndLeavesWhenANewerLaunchCommits() {
        let host = FakeSingleInstanceHost(me: me)
        host.addPeer(old)  // silent
        let coordinator = makeCoordinator(host)
        guard case .failed = coordinator.acquire() else { return XCTFail() }
        XCTAssertEqual(coordinator.phase, .inactive)

        host.addPeer(newer)
        host.deliver(.probe(from: newer, attempt: 7))
        host.deliver(.probe(from: old, attempt: 7))  // even an older prober gets an answer: it holds nothing
        XCTAssertEqual(host.readies(to: newer).count, 1)
        if case .ready(_, _, let role) = host.readies(to: newer)[0].kind { XCTAssertEqual(role, .inactive) } else { XCTFail() }
        XCTAssertEqual(host.readies(to: old).count, 1)
        XCTAssertEqual(abandons, 0, "a probe alone never makes it leave")

        host.deliver(host.commit(from: newer, attempt: 7))
        XCTAssertEqual(host.acks(to: newer).count, 1)
        XCTAssertEqual(abandons, 1)
        XCTAssertEqual(quitRequests, 0, "an inactive launch has no vault to flush")
    }

    // MARK: - Process entry policy

    func testHostedTestsAndPreviewsAreInertInTheLauncher() {
        XCTAssertEqual(AppLauncher.mode(isTestOrPreviewHost: true), .inertTestOrPreviewHost)
        XCTAssertEqual(AppLauncher.mode(isTestOrPreviewHost: false), .guarded)
    }

    func testThisHostedTestProcessTookNoPartInTheElection() throws {
        XCTAssertEqual(AppLauncher.mode(isTestOrPreviewHost: AppRuntimeEnvironment.isTestOrPreviewHost), .inertTestOrPreviewHost)
        XCTAssertNil(AppDelegate.singleInstance, "a test host must never listen, send or hold the lock")
        XCTAssertEqual(AppDelegate().applicationShouldTerminate(NSApplication.shared), .terminateNow)
    }
}

// MARK: - Two coordinators in one virtual world

/// An already-elected owner living in the requester's virtual world: messages
/// between the two travel with a latency, and the owner can be "busy" (its main
/// run loop stuck in a long operation) so deliveries queue up behind it.
private final class LiveOwner {
    let identity: ProcessIdentity
    let host: FakeSingleInstanceHost
    private(set) var coordinator: SingleInstanceCoordinator!
    private(set) var quitRequests = 0
    private let world: FakeSingleInstanceHost
    /// Everything addressed to the owner before this virtual time waits in its queue.
    var busyUntil: TimeInterval = 0
    var latency: TimeInterval = 0.005
    /// Simulates a `withdraw` that never arrives: only the deadline may then protect the owner.
    var dropsWithdraws = false
    /// What the user does with the save prompt once the owner starts to quit.
    enum Reaction { case exit(after: TimeInterval), cancel(after: TimeInterval), hang }
    var reaction: Reaction = .exit(after: 0.3)

    init(_ identity: ProcessIdentity, world: FakeSingleInstanceHost, requester: ProcessIdentity) {
        self.identity = identity
        self.world = world
        host = FakeSingleInstanceHost(me: identity)
        coordinator = SingleInstanceCoordinator(
            host: host,
            tryLock: { .acquired(NSObject()) },
            requestQuit: { [unowned self] in self.userSeesQuit() }
        )
        XCTAssertEqual(coordinator.acquire(), .owner)
        host.timeSource = world
        host.addPeer(requester)
        world.addPeer(identity)
        host.outbox = { [unowned self] message in
            let wire = message.wire
            world.at(world.now + self.latency) { world.deliverRaw(wire) }
        }
        world.outbox = { [unowned self] message in
            if self.dropsWithdraws, case .withdraw = message.kind { return }
            let wire = message.wire
            world.at(max(world.now + self.latency, self.busyUntil)) { self.host.deliverRaw(wire) }
        }
    }

    private func userSeesQuit() {
        quitRequests += 1
        switch reaction {
        case .exit(let delay):
            world.at(world.now + delay) { [self] in
                host.killPeer(identity)
                world.killPeer(identity)
            }
        case .cancel(let delay):
            world.at(world.now + delay) { [self] in coordinator.quitWasCancelled() }
        case .hang:
            break
        }
    }
}

final class SingleInstanceRaceTests: XCTestCase {
    private let me = ProcessIdentity(pid: 500, startMicroseconds: 5_000_000)
    private let owner = ProcessIdentity(pid: 100, startMicroseconds: 1_000_000)
    private let legacy = ProcessIdentity(pid: 90, startMicroseconds: 900_000)

    private func makeRequester(_ world: FakeSingleInstanceHost) -> SingleInstanceCoordinator {
        SingleInstanceCoordinator(host: world, tryLock: { .acquired(NSObject()) }, requestQuit: {})
    }

    /// Finding 1: after the user cancels the save prompt, the requester's own
    /// retransmissions must not raise the prompt again.
    func testCancelledQuitIsNotRepromptedByRetransmissionsAndTheRequesterStopsAtOnce() {
        let world = FakeSingleInstanceHost(me: me)
        let live = LiveOwner(owner, world: world, requester: me)
        live.reaction = .cancel(after: 0.2)
        let outcome = makeRequester(world).acquire()

        XCTAssertEqual(outcome, .failed(.declined([owner.pid])), "a refused takeover must not become ownership")
        XCTAssertEqual(live.quitRequests, 1, "the same request must not prompt twice")
        XCTAssertLessThan(world.now, 3, "the requester must stop right after an explicit denial, not wait out the bound")
        world.pump(for: 5)
        XCTAssertEqual(live.quitRequests, 1, "nothing retransmitted after the failure may re-quit the owner")
        XCTAssertEqual(live.coordinator.phase, .owner)
    }

    /// Finding 2: a silent older peer means the newcomer cannot win, so the live owner must never be asked.
    func testOwnerIsNeverAskedToQuitWhenASilentPeerMeansTheNewcomerCannotWin() {
        let world = FakeSingleInstanceHost(me: me)
        let live = LiveOwner(owner, world: world, requester: me)
        world.addPeer(legacy)  // a pre-guard build or hosted test run: alive, recognised, never answers
        let outcome = makeRequester(world).acquire()

        XCTAssertEqual(outcome, .failed(.unrecognizedPeers([legacy.pid])))
        XCTAssertEqual(live.quitRequests, 0, "the owner must stay untouched")
        XCTAssertEqual(live.coordinator.phase, .owner)
        world.pump(for: 5)
        XCTAssertEqual(live.quitRequests, 0)
    }

    /// Finding 3: the owner's main thread is busy for longer than the newcomer waits.
    /// The newcomer gave up, so the delayed, queued messages must not make the owner quit.
    func testQueuedRequestDeliveredAfterTheRequesterGaveUpNeverQuitsTheOwner() {
        let world = FakeSingleInstanceHost(me: me)
        let live = LiveOwner(owner, world: world, requester: me)
        live.busyUntil = 3.5
        let outcome = makeRequester(world).acquire()

        guard case .failed = outcome else { return XCTFail("expected the newcomer to give up: \(outcome)") }
        XCTAssertEqual(live.quitRequests, 0)
        world.pump(for: 10)  // the owner finally drains its queue
        XCTAssertEqual(live.quitRequests, 0, "an abandoned request must not quit the owner later")
        XCTAssertEqual(live.coordinator.phase, .owner)
    }

    /// The owner is slow, not silent: it answers inside the grace and accepts inside the window.
    func testSlowButResponsiveOwnerStillHandsOver() {
        let world = FakeSingleInstanceHost(me: me)
        let live = LiveOwner(owner, world: world, requester: me)
        live.busyUntil = 1.2  // the probe waits behind a long main-thread operation
        let coordinator = makeRequester(world)
        XCTAssertEqual(coordinator.acquire(), .owner)
        XCTAssertEqual(live.quitRequests, 1)
        XCTAssertGreaterThanOrEqual(world.commits.first?.at ?? 0, 1.2)
    }

    /// The commit itself reaches the owner after the requester stopped waiting for it
    /// (probe answered in time, then the main thread blocks): the deadline kills it.
    func testCommitThatReachesTheOwnerAfterItsDeadlineNeverQuitsIt() {
        let world = FakeSingleInstanceHost(me: me)
        let live = LiveOwner(owner, world: world, requester: me)
        live.dropsWithdraws = true  // the deadline alone must protect the owner
        // Answer the probe immediately, then go busy right after the first commit leaves.
        world.at(0.05) { live.busyUntil = 30 }
        var outcome: SingleInstanceCoordinator.Outcome?
        let coordinator = makeRequester(world)
        // Let the first probe through before the owner stops processing messages.
        world.at(0.0) { live.busyUntil = 0 }
        outcome = coordinator.acquire()
        if case .failed(.notResponding(let pids)) = outcome ?? .owner { XCTAssertEqual(pids, [owner.pid]) } else {
            XCTFail("expected the unanswered commit to end in notResponding: \(String(describing: outcome))")
        }
        XCTAssertEqual(live.quitRequests, 0)
        live.busyUntil = 0
        world.pump(for: 60)  // the owner finally drains everything it was sent
        XCTAssertEqual(live.quitRequests, 0, "expired commit + withdraw are both dead on arrival")
        XCTAssertEqual(live.coordinator.phase, .owner)
    }

    /// A refusal is remembered per attempt only: a different launch later is served normally.
    func testALaterLaunchAfterARefusalGetsItsOwnPrompt() {
        let world = FakeSingleInstanceHost(me: me)
        let live = LiveOwner(owner, world: world, requester: me)
        live.reaction = .cancel(after: 0.2)
        XCTAssertEqual(makeRequester(world).acquire(), .failed(.declined([owner.pid])))

        let later = ProcessIdentity(pid: 600, startMicroseconds: 6_000_000)
        world.selfIdentity = later
        world.addPeer(later)
        live.host.addPeer(later)
        live.reaction = .exit(after: 0.3)
        XCTAssertEqual(makeRequester(world).acquire(), .owner)
        XCTAssertEqual(live.quitRequests, 2, "once for each launch, no ban")
    }

    /// Two live owners' worth of silence is still silence: both peers must answer.
    func testNobodyIsAskedWhileOneOfTwoPeersIsSilent() {
        let world = FakeSingleInstanceHost(me: me)
        let first = LiveOwner(owner, world: world, requester: me)
        world.addPeer(legacy)
        XCTAssertEqual(makeRequester(world).acquire(), .failed(.unrecognizedPeers([legacy.pid])))
        XCTAssertEqual(first.quitRequests, 0)
        XCTAssertTrue(world.commits.isEmpty)
    }
}
