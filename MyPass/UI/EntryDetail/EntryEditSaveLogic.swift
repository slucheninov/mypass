import Foundation
import MyPassKit

enum EntryEditSaveLogic {
    static func resolvedTitle(draftTitle: String, url: String) -> String {
        let trimmed = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        guard !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        return ExtensionEntryMatcher.registrableDomain(from: url) ?? url
    }

    static func applyOTP(to entry: inout KdbxEntry, otpauthInput: String, isEditingExisting: Bool) {
        guard !otpauthInput.isEmpty else { return }
        if let parsed = TOTPCode.parse(otpauthURL: otpauthInput) {
            entry.totpSecretBase32 = TOTPCode.base32Encode(parsed.secret)
        } else {
            entry.totpSecretBase32 = otpauthInput
        }
    }
}
