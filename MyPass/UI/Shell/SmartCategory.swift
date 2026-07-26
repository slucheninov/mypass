import SwiftUI
import MyPassKit

enum SmartCategory: String, CaseIterable, Identifiable, Hashable {
    case all
    case favorites
    case codes
    case security
    case deleted

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All"
        case .favorites: return "Favorites"
        case .codes: return "Codes"
        case .security: return "Security"
        case .deleted: return "Deleted"
        }
    }

    func countDisplay(for database: KdbxDatabase) -> String {
        SmartCategoryCounts.countDisplay(for: self, database: database)
    }

    /// Accent tint for category dot and selection pill (mockup reference colors; semantic where possible).
    var accentColor: Color {
        switch self {
        case .all: return Color.accentColor
        case .favorites: return Color(red: 1.0, green: 0.8, blue: 0.0)
        case .codes: return Color.orange
        case .security: return Color.red
        case .deleted: return Color.secondary
        }
    }
}
