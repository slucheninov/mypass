import SwiftUI
import MyPassKit

struct GroupPickerView: View {
    let rootGroup: KdbxGroup
    let recycleBinGroupUUID: UUID?
    @Binding var selectedGroupID: UUID

    var body: some View {
        Picker("Group", selection: $selectedGroupID) {
            ForEach(selectableGroups, id: \.uuid) { group in
                Text(group.name).tag(group.uuid)
            }
        }
    }

    private var selectableGroups: [KdbxGroup] {
        flatten(rootGroup).filter { group in
            if let binUUID = recycleBinGroupUUID, group.uuid == binUUID { return false }
            return !GroupTreeOperations.isRecycleBinGroup(group)
        }
    }

    private func flatten(_ group: KdbxGroup) -> [KdbxGroup] {
        [group] + group.subgroups.flatMap { flatten($0) }
    }
}
