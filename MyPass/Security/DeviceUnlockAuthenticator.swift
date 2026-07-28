import Foundation
import LocalAuthentication

enum DeviceUnlockAuthenticator {
    static func authenticate(
        accessControl: DeviceUnlockAccessControl,
        reason: String = "Unlock MyPass",
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

        context.evaluatePolicy(policy, localizedReason: reason) { success, _ in
            DispatchQueue.main.async {
                completion(success)
            }
        }
    }
}
