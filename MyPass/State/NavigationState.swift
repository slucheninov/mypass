import Foundation

/// A save-login proposal relayed from `ExtensionBridgeService.onSaveProposal`
/// (Phase 4, Task 5/13), waiting to be shown as a pre-filled create-entry sheet
/// by `ContentView`. `Identifiable` so it can drive `.sheet(item:)` directly.
struct PendingSaveProposal: Identifiable {
    let id = UUID()
    let url: String
    let username: String
    let password: String

    /// Best-effort registrable domain for use as the draft entry's title —
    /// falls back to the raw URL when `ExtensionEntryMatcher` can't parse a
    /// host out of it (e.g. malformed or non-HTTP input from the extension).
    var registrableDomain: String {
        ExtensionEntryMatcher.registrableDomain(from: url) ?? url
    }
}

final class NavigationState: ObservableObject {
    @Published var selectedGroupID: UUID?
    @Published var selectedEntryID: UUID?
    @Published var searchText: String = ""
    @Published var pendingSaveProposal: PendingSaveProposal?
}
