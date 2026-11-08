import Foundation
import MyPassKit

/// The secondary line under an entry's title in the list and the menu bar.
enum EntryListSubtitle {
    static func text(for entry: KdbxEntry) -> String {
        switch entry.entryType {
        case .address:
            return entry.addressSummary
        case .files:
            // A Files item has no username; the useful summary is how many files it holds.
            // Localized through a plural variation so uk/ru get one/few/many forms.
            return fileCountText(entry.attachments.count)
        case .login, .card, .notes:
            return entry.login
        }
    }

    static func fileCountText(_ count: Int) -> String {
        String(localized: "\(count) files")
    }
}
