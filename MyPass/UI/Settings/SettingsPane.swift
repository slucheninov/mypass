import SwiftUI

enum SettingsPane: String, CaseIterable, Identifiable {
    case general
    case vault
    case security
    case browser
    case appearance
    case about

    /// The `UserDefaults` key holding the selected pane's raw value. `SettingsView` and
    /// `BrowserSettingsActivator` both use it, so the name lives in one place.
    static let storageKey = "settingsSelectedPane"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .vault: return "Vault"
        case .security: return "Security"
        case .browser: return "Browser"
        case .appearance: return "Appearance"
        case .about: return "About"
        }
    }

    var symbolName: String {
        switch self {
        case .general: return "gearshape"
        case .vault: return "folder"
        case .security: return "lock.fill"
        case .browser: return "globe"
        case .appearance: return "paintbrush"
        case .about: return "info.circle"
        }
    }

    var detailTitle: String { title }

    /// Maps a stored selection to a pane. Vault Location, Sync and Backups used to be three
    /// separate panes and are now sections of `.vault`, so a profile that last left Settings on
    /// one of them must open Vault rather than silently falling back to General. The legacy
    /// names are handled here as plain strings on purpose: keeping them as enum cases would
    /// leave dead panes in the sidebar and in every exhaustive switch. Anything else (nil, empty,
    /// unknown, wrong case) is General.
    static func resolve(storedRaw: String?) -> SettingsPane {
        switch storedRaw {
        case "vaultLocation", "sync", "backups":
            return .vault
        case let raw?:
            return SettingsPane(rawValue: raw) ?? .general
        case nil:
            return .general
        }
    }
}
