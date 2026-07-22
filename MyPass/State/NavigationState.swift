import Foundation

final class NavigationState: ObservableObject {
    @Published var selectedGroupID: UUID?
    @Published var selectedEntryID: UUID?
    @Published var searchText: String = ""
}
