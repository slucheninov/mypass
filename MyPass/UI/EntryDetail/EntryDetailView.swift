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
            ScrollView {
                VStack(spacing: 20) {
                    VStack(spacing: 12) {
                        LetterAvatarView(
                            title: entry.title.isEmpty ? "(untitled)" : entry.title,
                            size: UIShellMetrics.detailHeroIconSize,
                            cornerRadius: UIShellMetrics.detailHeroIconCornerRadius
                        )
                        Text(entry.title.isEmpty ? "(untitled)" : entry.title)
                            .font(.system(size: 22, weight: .bold))
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 24)

                    DetailFieldsCard {
                        HStack(alignment: .center, spacing: 12) {
                            Text("Username")
                                .foregroundStyle(.secondary)
                                .frame(width: 100, alignment: .leading)
                            Text(entry.login)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                            Button("Copy", systemImage: "doc.on.doc") { copy(entry.login) }
                                .buttonStyle(.borderless)
                        }
                        .font(.body)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)

                        DetailFieldDivider()

                        HStack(alignment: .center, spacing: 12) {
                            Text("Password")
                                .foregroundStyle(.secondary)
                                .frame(width: 100, alignment: .leading)
                            Text(isPasswordRevealed ? entry.password : String(repeating: "•", count: max(entry.password.count, 8)))
                                .frame(maxWidth: .infinity, alignment: .trailing)
                            Button(isPasswordRevealed ? "Hide" : "Show") { isPasswordRevealed.toggle() }
                                .buttonStyle(.borderless)
                            Button("Copy", systemImage: "doc.on.doc") { copy(entry.password) }
                                .buttonStyle(.borderless)
                        }
                        .font(.body)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)

                        if !entry.url.isEmpty {
                            DetailFieldDivider()
                            DetailFieldRow(label: "Website", value: entry.url, isLink: true)
                        }

                        DetailFieldDivider()

                        DetailFieldRow(
                            label: "Modified",
                            value: entry.lastModificationTime.formatted(date: .abbreviated, time: .shortened)
                        )

                        if !entry.notes.isEmpty {
                            DetailFieldDivider()
                            DetailFieldRow(label: "Notes", value: entry.notes)
                        }

                        if let secret = entry.totpSecretBase32 {
                            DetailFieldDivider()
                            let code = TOTPCode.currentCode(secretBase32: secret, digits: 6, period: 30, algorithm: .sha1, now: now) ?? "------"
                            HStack(alignment: .center, spacing: 12) {
                                Text("Verification Code")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 100, alignment: .leading)
                                Spacer(minLength: 0)
                                Text(code)
                                    .font(.system(.body, design: .monospaced))
                                TOTPRingChrome()
                                Button("Copy", systemImage: "doc.on.doc") { copy(code) }
                                    .buttonStyle(.borderless)
                            }
                            .font(.body)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                        }
                    }

                    Button("View History") { showHistory = true }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)

                    SecurityWarningStubView()

                    HStack(spacing: 16) {
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
                    .padding(.bottom, 24)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
            }
            .background(UIShellMetrics.detailColumnBackground)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button("Share", systemImage: "square.and.arrow.up") { }
                        .disabled(true)
                        .help("Share is not available yet")
                    Button("Edit", systemImage: "square.and.pencil") { showEdit = true }
                }
            }
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

private struct DetailFieldDivider: View {
    var body: some View {
        Divider().overlay(Color.primary.opacity(0.08))
    }
}

private struct DetailFieldRow: View {
    let label: String
    let value: String
    var isLink: Bool = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .leading)
            if isLink, let url = URL(string: value), !value.isEmpty {
                Link(value, destination: url)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            } else {
                Text(value)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .font(.body)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

private struct DetailFieldsCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            content()
        }
        .background(
            RoundedRectangle(cornerRadius: UIShellMetrics.cardCornerRadius, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: UIShellMetrics.cardCornerRadius, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.04), radius: 8, y: 2)
        .frame(maxWidth: UIShellMetrics.cardMaxWidth)
    }
}

private struct TOTPRingChrome: View {
    var body: some View {
        Circle()
            .stroke(Color.secondary.opacity(0.35), lineWidth: 2)
            .frame(width: 22, height: 22)
            .accessibilityHidden(true)
    }
}

private struct SecurityWarningStubView: View {
    var body: some View {
        Text("Security warning (coming later)")
            .font(.body.italic())
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.vertical, 20)
            .padding(.horizontal, 16)
            .frame(maxWidth: UIShellMetrics.cardMaxWidth)
            .background(
                RoundedRectangle(cornerRadius: UIShellMetrics.cardCornerRadius, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: UIShellMetrics.cardCornerRadius, style: .continuous)
                    .stroke(style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
                    .foregroundStyle(Color.secondary.opacity(0.5))
            )
            .accessibilityLabel(Text("Security warning placeholder"))
    }
}
