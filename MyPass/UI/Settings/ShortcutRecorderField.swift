import SwiftUI
import AppKit

struct ShortcutRecorderField: View {
    let label: String
    let storageKey: String
    let defaultValue: String

    @AppStorage private var storedValue: String
    @State private var isRecording = false
    @State private var monitor: Any?

    init(label: String, storageKey: String, defaultValue: String) {
        self.label = label
        self.storageKey = storageKey
        self.defaultValue = defaultValue
        _storedValue = AppStorage(wrappedValue: defaultValue, storageKey)
    }

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Button(action: beginRecording) {
                Text(isRecording ? "Press shortcut…" : ShortcutCodec.displayString(forStorage: storedValue))
                    .frame(minWidth: 80, alignment: .trailing)
            }
            .buttonStyle(.bordered)
            Button("Clear") { storedValue = "" }
                .disabled(storedValue.isEmpty)
        }
    }

    private func beginRecording() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // Escape
                stopRecording()
                return nil
            }
            if let shortcut = ShortcutCodec.from(event: event) {
                storedValue = ShortcutCodec.encode(shortcut)
                stopRecording()
                return nil
            }
            return event
        }
    }

    private func stopRecording() {
        isRecording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
