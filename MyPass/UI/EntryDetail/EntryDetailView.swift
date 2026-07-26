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
    @State private var showHistory = false
    @State private var showEdit = false

    private let pasteboard = NSPasteboardClearing()
    private let clock = RealAutoLockClock()
    @State private var timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var currentEntry: KdbxEntry? {
        guard let database = vaultSession.currentDatabase, let id = navigationState.selectedEntryID else { return nil }
        return EntrySearch.allEntries(in: database.rootGroup).first { $0.uuid == id }
    }

    /// True when the current entry currently lives in the Recycle Bin group, i.e. it
    /// was soft-deleted and is awaiting restore or permanent purge.
    private func isInRecycleBin(_ entry: KdbxEntry) -> Bool {
        guard let database = vaultSession.currentDatabase,
              let binUUID = database.recycleBinGroupUUID,
              let bin = database.rootGroup.subgroups.first(where: { $0.uuid == binUUID }) else { return false }
        return bin.entries.contains(where: { $0.uuid == entry.uuid })
    }

    var body: some View {
        if let entry = currentEntry {
            Form {
                LabeledContent("Title", value: entry.title)
                HStack {
                    LabeledContent("Username", value: entry.login)
                    Button("Copy", systemImage: "doc.on.doc") { copy(entry.login) }
                }
                HStack {
                    LabeledContent("Password", value: isPasswordRevealed ? entry.password : String(repeating: "•", count: max(entry.password.count, 8)))
                    Button(isPasswordRevealed ? "Hide" : "Show") { isPasswordRevealed.toggle() }
                    Button("Copy", systemImage: "doc.on.doc") { copy(entry.password) }
                }
                if !entry.url.isEmpty {
                    HStack {
                        LabeledContent("URL", value: entry.url)
                        Button("Open") {
                            if let url = URL(string: entry.url) { NSWorkspace.shared.open(url) }
                        }
                    }
                }
                if !entry.notes.isEmpty {
                    LabeledContent("Notes", value: entry.notes)
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
                Button("History") { showHistory = true }
                Button("Edit") { showEdit = true }
                if isInRecycleBin(entry) {
                    Button("Restore") {
                        vaultSession.mutate { database in
                            // The entry's original source group isn't tracked once soft-deleted,
                            // so root is the safe, predictable restore destination.
                            GroupTreeOperations.restoreEntry(withID: entry.uuid, to: database.rootGroup.uuid, in: database.rootGroup)
                        }
                        navigationState.selectedEntryID = nil
                    }
                } else {
                    Button("Delete", role: .destructive) {
                        vaultSession.mutate { database in
                            GroupTreeOperations.softDeleteEntry(withID: entry.uuid, in: database.rootGroup, deletedObjects: &database.deletedObjects, recycleBinGroupUUID: &database.recycleBinGroupUUID)
                        }
                        navigationState.selectedEntryID = nil
                    }
                }
            }
            .padding()
            .onReceive(timer) { now = $0 }
            .sheet(isPresented: $showHistory) {
                HistoryView(entry: entry) { updated in
                    vaultSession.mutate { database in
                        replaceEntry(updated, in: database.rootGroup)
                    }
                    showHistory = false
                }
            }
            .sheet(isPresented: $showEdit) {
                EntryEditView(existingEntry: entry) { updated in
                    vaultSession.mutate { database in
                        replaceEntry(updated, in: database.rootGroup)
                    }
                    showEdit = false
                }
            }
        } else {
            DetailEmptyStateView()
        }
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        ClipboardAutoClear.schedule(value: value, after: 30, pasteboard: pasteboard, clock: clock)
    }

    private func replaceEntry(_ updated: KdbxEntry, in group: KdbxGroup) {
        if let index = group.entries.firstIndex(where: { $0.uuid == updated.uuid }) {
            group.entries[index] = updated
            return
        }
        for subgroup in group.subgroups {
            replaceEntry(updated, in: subgroup)
        }
    }
}

private struct DetailEmptyStateView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.crop.circle.badge.key")
                .font(.system(size: UIShellMetrics.emptyStateIconSize))
                .foregroundStyle(.secondary.opacity(0.35))
            Text("Nothing Selected")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("Select an entry from the list")
                .font(.system(size: 13))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(UIShellMetrics.detailColumnBackground)
    }
}
