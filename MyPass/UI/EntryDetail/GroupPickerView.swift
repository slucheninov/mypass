import SwiftUI
import MyPassKit

struct GroupPickerView: View {
    let rootGroup: KdbxGroup
    let recycleBinGroupUUID: UUID?
    @Binding var selectedGroupID: UUID

    var body: some View {
        Picker("Group", selection: $selectedGroupID) {
            ForEach(selectableGroups, id: \.uuid) { group in
                Text(group.name)
                    .tag(group.uuid)
            }
        }
    }

    private var selectableGroups: [KdbxGroup] {
        GroupTreeOperations.selectableGroups(in: rootGroup, excludingRecycleBin: recycleBinGroupUUID)
    }
}
