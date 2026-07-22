import SwiftUI
import MyPassKit

struct GroupSidebarView: View {
    let rootGroup: KdbxGroup

    var body: some View {
        Text(rootGroup.name) // replaced by a real tree in Task 11
    }
}
