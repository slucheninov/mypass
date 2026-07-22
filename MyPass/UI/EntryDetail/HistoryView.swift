import SwiftUI
import MyPassKit

enum EntryHistoryOperations {
    static func restoreVersion(_ version: KdbxEntry, into entry: inout KdbxEntry) {
        var snapshot = entry
        snapshot.history = [] // history entries never carry their own history, per design
        entry.fields = version.fields
        entry.lastModificationTime = Date()
        entry.lastAccessTime = Date()
        entry.history.append(snapshot)
    }
}

struct HistoryView: View {
    let entry: KdbxEntry
    let onRestore: (KdbxEntry) -> Void

    var body: some View {
        List(entry.history.indices, id: \.self) { index in
            let version = entry.history[index]
            HStack {
                VStack(alignment: .leading) {
                    Text(version.title.isEmpty ? "(без названия)" : version.title)
                    Text(version.lastModificationTime.formatted())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Восстановить эту версию") {
                    var updated = entry
                    EntryHistoryOperations.restoreVersion(version, into: &updated)
                    onRestore(updated)
                }
            }
        }
    }
}
