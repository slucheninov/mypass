import SwiftUI
import AppKit
import MyPassKit

struct NSPasteboardClearing: PasteboardClearing {
    func currentString() -> String? {
        NSPasteboard.general.string(forType: .string)
    }

    func clearIfStillContains(_ value: String) {
        if currentString() == value {
            NSPasteboard.general.clearContents()
        }
    }
}

final class RealAutoLockClock: AutoLockClock {
    func scheduleTick(after seconds: TimeInterval, _ action: @escaping () -> Void) -> AutoLockCancelable {
        let timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in action() }
        return TimerCancelable(timer: timer)
    }
}

final class TimerCancelable: AutoLockCancelable {
    private let timer: Timer
    init(timer: Timer) { self.timer = timer }
    func cancel() { timer.invalidate() }
}

struct EntryDetailView: View {
    @EnvironmentObject var vaultSession: VaultSession
    @EnvironmentObject var navigationState: NavigationState
    @State private var isPasswordRevealed = false
    @State private var now = Date()

    private let pasteboard = NSPasteboardClearing()
    private let clock = RealAutoLockClock()
    @State private var timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var currentEntry: KdbxEntry? {
        guard let database = vaultSession.currentDatabase, let id = navigationState.selectedEntryID else { return nil }
        return EntrySearch.allEntries(in: database.rootGroup).first { $0.uuid == id }
    }

    var body: some View {
        if let entry = currentEntry {
            Form {
                LabeledContent("Название", value: entry.title)
                HStack {
                    LabeledContent("Логин", value: entry.login)
                    Button("Copy", systemImage: "doc.on.doc") { copy(entry.login) }
                }
                HStack {
                    LabeledContent("Пароль", value: isPasswordRevealed ? entry.password : String(repeating: "•", count: max(entry.password.count, 8)))
                    Button(isPasswordRevealed ? "Скрыть" : "Показать") { isPasswordRevealed.toggle() }
                    Button("Copy", systemImage: "doc.on.doc") { copy(entry.password) }
                }
                if !entry.url.isEmpty {
                    HStack {
                        LabeledContent("URL", value: entry.url)
                        Button("Открыть") {
                            if let url = URL(string: entry.url) { NSWorkspace.shared.open(url) }
                        }
                    }
                }
                if !entry.notes.isEmpty {
                    LabeledContent("Заметки", value: entry.notes)
                }
                if let secret = entry.totpSecretBase32 {
                    let code = TOTPCode.currentCode(secretBase32: secret, digits: 6, period: 30, algorithm: .sha1, now: now) ?? "------"
                    let remaining = TOTPCode.secondsRemaining(period: 30, now: now)
                    HStack {
                        Text("TOTP: \(code)")
                        Text("(\(Int(remaining))s)")
                            .foregroundStyle(.secondary)
                        Button("Copy", systemImage: "doc.on.doc") { copy(code) }
                    }
                }
            }
            .padding()
            .onReceive(timer) { now = $0 }
        } else {
            Text("Выберите запись")
        }
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        ClipboardAutoClear.schedule(value: value, after: 30, pasteboard: pasteboard, clock: clock)
    }
}
