import Foundation
import LocalAuthentication

enum DeviceUnlockAuthenticator {
    static func authenticate(
        accessControl: DeviceUnlockAccessControl,
        reason: String = String(localized: "Unlock MyPass", comment: "Touch ID / Mac password prompt reason shown by macOS"),
        completion: @escaping (Bool) -> Void
    ) {
        let context = LAContext()
        let policy = accessControl.laPolicy

        var error: NSError?
        guard context.canEvaluatePolicy(policy, error: &error) else {
            DispatchQueue.main.async {
                completion(false)
            }
            return
        }

        // Captured explicitly: `context` is otherwise only a local `let`, and the
        // trailing closure below doesn't reference it, so ARC could deallocate it
        // before the (asynchronous, system-driven) completion handler ever fires —
        // silently cancelling the evaluation and leaking a callback that never runs.
        context.evaluatePolicy(policy, localizedReason: reason) { [context] success, _ in
            _ = context
            DispatchQueue.main.async {
                completion(success)
            }
        }
    }
}
