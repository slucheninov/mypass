import Foundation

protocol AutoLockClock {
    func scheduleTick(after seconds: TimeInterval, _ action: @escaping () -> Void) -> AutoLockCancelable
}

protocol AutoLockCancelable {
    func cancel()
}

protocol AutoLockSleepObserving {
    func onWillSleep(_ handler: @escaping () -> Void) -> AutoLockCancelable
}

final class AutoLockController: ObservableObject {
    private let vaultSession: VaultSession
    private let clock: AutoLockClock
    private var pendingTick: AutoLockCancelable?
    private var sleepSubscription: AutoLockCancelable?

    var timeout: TimeInterval {
        didSet { recordActivity() }
    }

    init(vaultSession: VaultSession, clock: AutoLockClock, sleepObserver: AutoLockSleepObserving, timeout: TimeInterval) {
        self.vaultSession = vaultSession
        self.clock = clock
        self.timeout = timeout
        self.sleepSubscription = sleepObserver.onWillSleep { [weak self] in
            self?.lockNow()
        }
        recordActivity()
    }

    func recordActivity() {
        pendingTick?.cancel()
        pendingTick = clock.scheduleTick(after: timeout) { [weak self] in
            self?.lockNow()
        }
    }

    func lockNow() {
        vaultSession.lock()
    }
}
