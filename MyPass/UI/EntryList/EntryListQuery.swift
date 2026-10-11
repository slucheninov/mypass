import Foundation
import MyPassKit

/// One query drives both the visible list and its empty-detail overview count.
/// In group mode a nonempty search has always searched the whole vault; retain
/// that behavior instead of giving the overview a misleading recursive group count.
enum EntryListQuery {
    static func currentGroup(in root: KdbxGroup, selectedID: UUID?) -> KdbxGroup {
        guard let selectedID else { return root }
        return findGroup(selectedID, in: root) ?? root
    }

    static func entries(root: KdbxGroup, database: KdbxDatabase?, navigation: NavigationState) -> [KdbxEntry] {
        let group = currentGroup(in: root, selectedID: navigation.selectedGroupID)
        if PasswordGeneratorHistoryStore.isHistoryGroup(group) { return [] }
        if navigation.selectedSmartCategory == .security, navigation.securityUsesGroupScope {
            return navigation.searchText.isEmpty
                ? group.entries
                : EntrySearch.entries(in: root, matching: navigation.searchText)
        }
        if navigation.isCategoryMode, let database {
            let scoped = EntryCategoryFilter.entries(for: navigation.activeCategoryFilter, in: database)
            return navigation.searchText.isEmpty
                ? scoped
                : scoped.filter { EntrySearch.matches(entry: $0, query: navigation.searchText) }
        }
        return navigation.searchText.isEmpty
            ? group.entries
            : EntrySearch.entries(in: root, matching: navigation.searchText)
    }

    private static func findGroup(_ id: UUID, in group: KdbxGroup) -> KdbxGroup? {
        if group.uuid == id { return group }
        for child in group.subgroups {
            if let found = findGroup(id, in: child) { return found }
        }
        return nil
    }
}
