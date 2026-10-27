import SwiftUI
import MyPassKit

enum SmartCategory: String, CaseIterable, Identifiable, Hashable {
    case all
    case favorites
    case codes
    case passkeys
    case addresses
    case cards
    case notes
    case security
    case deleted

    var id: String { rawValue }

    /// A `LocalizedStringResource` so the computed title passes through the string catalog.
    var title: LocalizedStringResource {
        switch self {
        case .all: return "All"
        case .favorites: return "Favorites"
        case .codes: return "Codes"
        case .passkeys: return "Passkeys"
        case .addresses: return "Addresses"
        case .cards: return "Cards"
        case .notes: return "Notes"
        case .security: return "Security"
        case .deleted: return "Deleted"
        }
    }

    func countDisplay(for database: KdbxDatabase) -> String {
        SmartCategoryCounts.countDisplay(for: self, database: database)
    }

    var symbolName: String {
        switch self {
        case .all: return "square.grid.2x2.fill"
        case .favorites: return "star.fill"
        case .codes: return "number.square.fill"
        case .passkeys: return "person.badge.key.fill"
        case .addresses: return "house.fill"
        case .cards: return "creditcard.fill"
        case .notes: return "note.text"
        case .security: return "shield.lefthalf.filled"
        case .deleted: return "trash.fill"
        }
    }

    /// Shared tint for the category symbol and its selected-row background.
    var accentColor: Color {
        switch self {
        case .all: return Color.accentColor
        case .favorites: return Color(red: 1.0, green: 0.8, blue: 0.0)
        case .codes: return Color.orange
        case .passkeys: return Color.purple
        case .addresses: return Color.teal
        case .cards: return Color.blue
        case .notes: return Color.orange
        case .security: return Color.red
        case .deleted: return Color.secondary
        }
    }
}
