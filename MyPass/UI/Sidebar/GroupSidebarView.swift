import SwiftUI
import MyPassKit

struct GroupSidebarView: View {
    let rootGroup: KdbxGroup
    @EnvironmentObject var navigationState: NavigationState

    var body: some View {
        List(selection: $navigationState.selectedGroupID) {
            OutlineGroup([rootGroup], children: \.subgroupsForOutline) { group in
                Text(group.name)
                    .tag(group.uuid)
                    .onDrop(of: [.text], isTargeted: nil) { providers in
                        // Full move-on-drop logic wired in Task 15; this task only
                        // establishes the drop target per the sidebar's spec responsibility.
                        false
                    }
            }
            Text("Корзина")
                .foregroundStyle(.secondary)
        }
        .listStyle(.sidebar)
    }
}

private extension KdbxGroup {
    var subgroupsForOutline: [KdbxGroup]? {
        subgroups.isEmpty ? nil : subgroups
    }
}
