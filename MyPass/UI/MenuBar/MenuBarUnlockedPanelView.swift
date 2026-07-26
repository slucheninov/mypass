import SwiftUI
import AppKit

struct MenuBarUnlockedPanelView: View {
    @EnvironmentObject private var vaultSession: VaultSession
    @EnvironmentObject private var navigationState: NavigationState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let database = vaultSession.currentDatabase {
                let recents = RecentEntriesQuery.recent(in: database)
                if !recents.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(recents, id: \.uuid) { entry in
                            MenuBarRecentEntryRow(entry: entry) {
                                openEntry(entry.uuid)
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
        .frame(width: 300)
        .padding(.vertical, 8)
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

    private func openEntry(_ id: UUID) {
        activateMainWindow()
        navigationState.selectedEntryID = id
        vaultSession.touchAccess(entryID: id)
    }
}
