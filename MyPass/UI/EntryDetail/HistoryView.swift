import SwiftUI
import MyPassKit

struct HistoryView: View {
    let entry: KdbxEntry
    let onRestore: (KdbxEntry) -> Void
    let onClearHistory: (KdbxEntry) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var showClearConfirm = false

    fileprivate static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    var body: some View {
        NavigationStack {
            Group {
                if entry.history.isEmpty {
                    ContentUnavailableView("No previous versions", systemImage: "clock.arrow.circlepath")
                } else {
                    List(entry.history.indices, id: \.self) { index in
                        let version = entry.history[index]
                        NavigationLink {
                            HistoryVersionDetailView(version: version, liveEntry: entry, onRestore: onRestore)
                        } label: {
                            HistoryVersionRow(version: version, currentEntry: entry)
                        }
                    }
                }
            }
            .navigationTitle("History")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !entry.history.isEmpty {
                    Button("Clear History…", role: .destructive) { showClearConfirm = true }
                        .frame(maxWidth: .infinity)
                        .padding()
                }
            }
            .alert("Clear History?", isPresented: $showClearConfirm) {
                Button("Cancel", role: .cancel) {}
                Button("Clear History", role: .destructive) {
                    var cleared = entry
                    EntryHistoryOperations.clearHistory(on: &cleared)
                    onClearHistory(cleared)
                }
            } message: {
                Text("Previous versions cannot be recovered.")
            }
        }
        .frame(minWidth: 420, minHeight: 400)
    }
}

private struct HistoryVersionRow: View {
    let version: KdbxEntry
    let currentEntry: KdbxEntry

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Color.secondary.opacity(0.15)).frame(width: 32, height: 32)
                Image(systemName: "pencil").font(.system(size: 14)).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: rowTitle)
                    .font(.body.weight(.medium))
                Text(verbatim: HistoryView.relativeFormatter.localizedString(for: version.lastModificationTime, relativeTo: Date()))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }

    private var rowTitle: String {
        if version.password != currentEntry.password { return String(localized: "Password updated", comment: "Entry history row title") }
        if !version.title.isEmpty { return version.title }
        return String(localized: "Password updated", comment: "Entry history row title")
    }
}
