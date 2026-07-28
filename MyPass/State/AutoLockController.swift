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

    /// `nil` means "never auto-lock on inactivity".
    var timeout: TimeInterval? {
        didSet { recordActivity() }
    }

    var lockOnSleepEnabled: Bool

    init(
        vaultSession: VaultSession,
        clock: AutoLockClock,
        sleepObserver: AutoLockSleepObserving,
        timeout: TimeInterval?,
        lockOnSleepEnabled: Bool = true
    ) {
        self.vaultSession = vaultSession
        self.clock = clock
        self.timeout = timeout
        self.lockOnSleepEnabled = lockOnSleepEnabled
        self.sleepSubscription = sleepObserver.onWillSleep { [weak self] in
            guard self?.lockOnSleepEnabled == true else { return }
            self?.lockNow()
        }
        recordActivity()
    }

    func recordActivity() {
        pendingTick?.cancel()
        guard let timeout else {
            pendingTick = nil
            return
        }
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
