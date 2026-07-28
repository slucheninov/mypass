import SwiftUI
import Carbon
import AppKit

/// Observes the system's currently selected keyboard input source (e.g. "U.S.",
/// "Russian - PC"). SecureField hides typed characters, so switching layouts
/// between two password entries is otherwise invisible until the password is
/// rejected — this makes the active layout visible next to the field.
final class KeyboardLayoutObserver: ObservableObject {
    @Published private(set) var layoutName: String = KeyboardLayoutObserver.currentLayoutName()

    private var observerToken: NSObjectProtocol?

    init() {
        observerToken = NotificationCenter.default.addObserver(
            forName: NSTextInputContext.keyboardSelectionDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.layoutName = Self.currentLayoutName()
        }
    }

    deinit {
        if let observerToken {
            NotificationCenter.default.removeObserver(observerToken)
        }
    }

    static func currentLayoutName() -> String {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let rawName = TISGetInputSourceProperty(source, kTISPropertyLocalizedName) else {
            return "?"
        }
        return Unmanaged<CFString>.fromOpaque(rawName).takeUnretainedValue() as String
    }
}

/// Small badge showing the current keyboard layout, meant to sit next to a
/// SecureField used for entering the master password.
struct KeyboardLayoutIndicator: View {
    @StateObject private var observer = KeyboardLayoutObserver()

    var body: some View {
        Label(observer.layoutName, systemImage: "keyboard")
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)
    }
}
