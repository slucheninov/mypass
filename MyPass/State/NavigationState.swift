import Foundation

/// A save-login proposal relayed from `ExtensionBridgeService.onSaveProposal`
/// (Phase 4, Task 5/13), waiting to be shown as a pre-filled create-entry sheet
/// by `ContentView`. `Identifiable` so it can drive `.sheet(item:)` directly.
struct PendingSaveProposal: Identifiable, Equatable, Hashable {
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

extension PendingSaveProposal {
    static func == (lhs: PendingSaveProposal, rhs: PendingSaveProposal) -> Bool {
        lhs.url == rhs.url && lhs.username == rhs.username && lhs.password == rhs.password
    }
}

/// A 2FA-setup proposal relayed from `ExtensionBridgeService.onTotpSaveProposal`,
/// mirroring `PendingSaveProposal` — waits to be shown as a pre-filled create or
/// edit sheet by `ContentView`. `entryId` selects edit (one/N-picker-resolved
/// domain match) vs. create (zero matches).
struct PendingTotpSaveProposal: Identifiable, Equatable, Hashable {
    let id = UUID()
    let url: String
    let otpauthOrSecret: String
    let entryId: UUID?

    var registrableDomain: String {
        ExtensionEntryMatcher.registrableDomain(from: url) ?? url
    }
}

extension PendingTotpSaveProposal {
    static func == (lhs: PendingTotpSaveProposal, rhs: PendingTotpSaveProposal) -> Bool {
        lhs.url == rhs.url && lhs.otpauthOrSecret == rhs.otpauthOrSecret && lhs.entryId == rhs.entryId
    }
}

enum DetailPresentation: Equatable, Hashable {
    case browse
    case edit(entryID: UUID)
    case create(defaultGroupID: UUID?, entryType: EntryType = .login)
    case createFromProposal(PendingSaveProposal)
    case createFromTotpProposal(PendingTotpSaveProposal)
    case editFromTotpProposal(entryID: UUID, otpauthInput: String)
}

final class NavigationState: ObservableObject {
    @Published var selectedGroupID: UUID?
    @Published var selectedEntryID: UUID?
    @Published var searchText: String = ""
    @Published var selectedSmartCategory: SmartCategory = .all
    @Published var pendingSaveProposal: PendingSaveProposal?
    @Published var pendingTotpSaveProposal: PendingTotpSaveProposal?
    @Published var pendingPairingCode: String?
    @Published var detailPresentation: DetailPresentation = .browse
    @Published var isCategoryMode: Bool = false
    @Published var activeCategoryFilter: SmartCategory = .all
    /// When Security is selected from group scope, keep list on the current group instead of vault-wide All.
    @Published private(set) var securityUsesGroupScope: Bool = false

    func selectSmartCategory(_ category: SmartCategory) {
        if category == .security {
            if selectedSmartCategory != .security {
                securityUsesGroupScope = !isCategoryMode
            }
        } else {
            securityUsesGroupScope = false
        }
        selectedSmartCategory = category
        isCategoryMode = true
        if category != .security {
            activeCategoryFilter = category
        }
    }

    func exitCategoryModeForGroupSelection() {
        isCategoryMode = false
        selectedSmartCategory = .all
        activeCategoryFilter = .all
        securityUsesGroupScope = false
    }

    /// The group to highlight in the sidebar's Groups `List` selection. `nil` while a
    /// smart category is active, so a group never appears selected at the same time as
    /// a category. The underlying `selectedGroupID` is preserved (not cleared) so
    /// group-scoped features like `securityUsesGroupScope` and the "Add" button's
    /// default group keep working once category mode exits.
    var sidebarSelectedGroupID: UUID? {
        get { isCategoryMode ? nil : selectedGroupID }
        set { selectedGroupID = newValue }
    }

    func isSmartCategorySelected(_ category: SmartCategory) -> Bool {
        isCategoryMode && selectedSmartCategory == category
    }

    func presentBrowse() {
        detailPresentation = .browse
    }

    func presentEdit(entryID: UUID) {
        detailPresentation = .edit(entryID: entryID)
    }

    func presentCreate(defaultGroupID: UUID?, entryType: EntryType = .login) {
        detailPresentation = .create(defaultGroupID: defaultGroupID, entryType: entryType)
    }

    func presentCreateFromProposal(_ proposal: PendingSaveProposal) {
        detailPresentation = .createFromProposal(proposal)
    }

    func presentCreateFromTotpProposal(_ proposal: PendingTotpSaveProposal) {
        detailPresentation = .createFromTotpProposal(proposal)
    }

    func presentEditFromTotpProposal(entryID: UUID, otpauthInput: String) {
        detailPresentation = .editFromTotpProposal(entryID: entryID, otpauthInput: otpauthInput)
    }
}
