import Foundation
import MyPassKit

/// Pure description of the content and order of the ⋮ (entry actions) menu, so the
/// visible row can be built from it and the order can be unit-tested without SwiftUI.
///
/// `sections` are separated by dividers in the rendered menu. A section is never empty:
/// an entry kind with nothing to put in the copy group (Address) simply has no such
/// section, which avoids both an empty group and a doubled separator.
///
/// Empty username / password stay in the menu as *disabled* items rather than being
/// hidden, so a Login entry keeps the same menu shape whatever it contains. The
/// one-time code and the Open Website item are different: they are shown only when the
/// entry actually has a TOTP secret / a website (the primary URL or an additional one), because a permanently dead item for a
/// feature the entry does not use is just noise.
struct EntryActionMenuModel: Equatable {
    enum CopyKind: Equatable {
        case username, password, code, cardNumber, cvv, note
    }

    enum Item: Equatable {
        case toggleFavorite(isFavorite: Bool)
        case moveToGroup
        case copy(CopyKind, isEnabled: Bool)
        case openWebsite
        case viewHistory
        case delete
        case restore
        case deletePermanently
    }

    let sections: [[Item]]

    init(entry: KdbxEntry, isInRecycleBin: Bool) {
        var sections: [[Item]] = [
            [.toggleFavorite(isFavorite: entry.isFavorite), .moveToGroup]
        ]

        var copyGroup: [Item] = []
        switch entry.entryType {
        case .login:
            copyGroup.append(.copy(.username, isEnabled: !entry.login.isEmpty))
            copyGroup.append(.copy(.password, isEnabled: !entry.password.isEmpty))
            if entry.totpSecretBase32 != nil {
                copyGroup.append(.copy(.code, isEnabled: true))
            }
            if entry.primaryWebsiteURL != nil {
                copyGroup.append(.openWebsite)
            }
        case .card:
            copyGroup.append(.copy(.cardNumber, isEnabled: !entry.cardNumber.isEmpty))
            copyGroup.append(.copy(.cvv, isEnabled: !entry.cvv.isEmpty))
        case .notes:
            copyGroup.append(.copy(.note, isEnabled: !entry.notesBody.isEmpty))
        case .address:
            break
        }
        if !copyGroup.isEmpty {
            sections.append(copyGroup)
        }

        sections.append([.viewHistory])
        sections.append(isInRecycleBin ? [.restore, .deletePermanently] : [.delete])

        self.sections = sections
    }
}
