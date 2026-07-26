import SwiftUI
import MyPassKit

struct HistoryVersionDetailView: View {
    let version: KdbxEntry
    let liveEntry: KdbxEntry
    let onRestore: (KdbxEntry) -> Void

    var body: some View {
        Form {
            LabeledContent("Title", value: version.title.isEmpty ? "(untitled)" : version.title)
            LabeledContent("Username", value: version.login)
            LabeledContent("Password", value: String(repeating: "•", count: max(version.password.count, 8)))
            if !version.url.isEmpty { LabeledContent("URL", value: version.url) }
        }
        .navigationTitle("Version")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Restore") {
                    var updated = liveEntry
                    EntryHistoryOperations.restoreVersion(version, into: &updated)
                    onRestore(updated)
                }
            }
        }
    }
}
