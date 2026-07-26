import SwiftUI

enum SettingsPane: String, CaseIterable, Identifiable {
    case general
    case security
    case browser
    case sync
    case backups

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .security: return "Security"
        case .browser: return "Browser"
        case .sync: return "Sync"
        case .backups: return "Backups"
        }
    }

    var symbolName: String {
        switch self {
        case .general: return "gearshape"
        case .security: return "lock.fill"
        case .browser: return "globe"
        case .sync: return "arrow.triangle.2.circlepath"
        case .backups: return "externaldrive"
        }
    }

    var detailTitle: String { title }
}
