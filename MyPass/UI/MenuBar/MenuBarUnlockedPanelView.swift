import SwiftUI
import AppKit
import MyPassKit

struct MenuBarUnlockedPanelView: View {
    @EnvironmentObject private var vaultSession: VaultSession

    @State private var detailEntryID: UUID?

    private var detailEntry: KdbxEntry? {
        guard let database = vaultSession.currentDatabase, let id = detailEntryID else { return nil }
        return EntrySearch.allEntries(in: database.rootGroup).first { $0.uuid == id }
    }

    var body: some View {
        Group {
            if let entry = detailEntry {
                MenuBarEntryDetailPanelView(entry: entry, onBack: { detailEntryID = nil })
            } else {
                listContent
            }
        }
        .padding(.vertical, detailEntry == nil ? 8 : 0)
    }

    private var listContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let database = vaultSession.currentDatabase {
                let recents = RecentEntriesQuery.recent(in: database)
                if !recents.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(recents, id: \.uuid) { entry in
                            MenuBarRecentEntryRow(entry: entry) {
                                detailEntryID = entry.uuid
                                vaultSession.touchAccess(entryID: entry.uuid)
                            }
                        }
                    }
                    Divider()
                }
            }

            menuRow("Open MyPass") { activateMainWindow() }

            HStack {
                Text("Open Quick Access")
                Spacer()
                Text("Coming later")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .foregroundStyle(.secondary)

            Divider()

            menuRow("Lock") {
                vaultSession.lock()
            }
            .disabled({
                if case .locked = vaultSession.state { return true }
                return false
            }())

            menuRow("Settings…") {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }

            menuRow("Quit MyPass") {
                NSApplication.shared.terminate(nil)
            }
        }
        .frame(width: 320)
    }

    @ViewBuilder
    private func menuRow(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func activateMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.canBecomeMain || $0.isVisible }?.makeKeyAndOrderFront(nil)
    }
}
