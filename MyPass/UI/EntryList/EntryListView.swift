import SwiftUI
import MyPassKit

struct EntryListView: View {
    let rootGroup: KdbxGroup

    var body: some View {
        Text("\(rootGroup.entries.count) entries") // replaced by a real list in Task 12
    }
}
