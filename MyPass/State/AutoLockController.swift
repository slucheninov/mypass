import Foundation
import AppKit

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

final class NSWorkspaceSleepObserver: AutoLockSleepObserving {
    func onWillSleep(_ handler: @escaping () -> Void) -> AutoLockCancelable {
        let token = NotificationCenter.default.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { _ in handler() }
        return NotificationTokenCancelable(token: token)
    }
}

final class NotificationTokenCancelable: AutoLockCancelable {
    private let token: NSObjectProtocol
    init(token: NSObjectProtocol) { self.token = token }
    func cancel() { NotificationCenter.default.removeObserver(token) }
}
