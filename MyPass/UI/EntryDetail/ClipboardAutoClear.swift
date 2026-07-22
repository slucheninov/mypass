import Foundation

protocol PasteboardClearing {
    func currentString() -> String?
    func clearIfStillContains(_ value: String)
}

enum ClipboardAutoClear {
    @discardableResult
    static func schedule(value: String, after seconds: TimeInterval, pasteboard: PasteboardClearing, clock: AutoLockClock) -> AutoLockCancelable {
        clock.scheduleTick(after: seconds) {
            pasteboard.clearIfStillContains(value)
        }
    }
}
