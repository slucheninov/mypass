import SwiftUI
import MyPassKit

/// Apple Passwords–style URL editor, shared by browse ("Change Website" context menu)
/// and edit ("Edit Websites…"). Persists immediately via `vaultSession.mutate` on
/// Done — it does not wait for the caller's own Save. List order is authoritative:
/// after trimming and dropping blank rows, the first remaining row becomes the
/// primary `URL`; the rest become the `KP2A_URL` StringArray extras.
struct WebsitesSheet: View {
    let entryID: UUID
    let entryTitle: String
    let onDone: ([String]) -> Void
    let onCancel: () -> Void

    @EnvironmentObject private var vaultSession: VaultSession
    @State private var rows: [String]

    init(
        entryID: UUID,
        entryTitle: String,
        initialURLs: [String],
        onDone: @escaping ([String]) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.entryID = entryID
        self.entryTitle = entryTitle
        self.onDone = onDone
        self.onCancel = onCancel
        _rows = State(initialValue: initialURLs.isEmpty ? [""] : initialURLs)
    }

    static func normalizedURLs(from rows: [String]) -> [String] {
        rows
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Websites")
                .font(.title3.bold())
            Text("These websites will be used to autofill **\(entryTitle)**.")
                .font(.callout)
                .foregroundStyle(.secondary)

            List {
                ForEach(rows.indices, id: \.self) { index in
                    HStack {
                        Group {
                            if index == 0 { Text("Primary") } else { Text(verbatim: "") }
                        }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 56, alignment: .leading)
                        TextField("https://example.com", text: $rows[index])
                        Button("Remove", systemImage: "minus.circle") {
                            rows.remove(at: index)
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                    }
                }
            }
            .listStyle(.inset)
            .frame(minHeight: 120, maxHeight: 240)

            Button("Add Website", systemImage: "plus") {
                rows.append("")
            }
            .labelStyle(.iconOnly)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Done", action: done)
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(24)
        .frame(width: 420)
    }

    private func done() {
        let trimmed = Self.normalizedURLs(from: rows)
        vaultSession.mutate { database in
            guard let location = GroupTreeOperations.entryLocation(entryID: entryID, in: database.rootGroup) else { return }
            location.group.entries[location.index].urls = trimmed
            location.group.entries[location.index].lastModificationTime = Date()
        }
        onDone(trimmed)
    }
}
