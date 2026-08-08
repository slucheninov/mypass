import Foundation
import MyPassKit

enum EntryEditSaveLogic {
    static func requiresReplaceConfirmation(existingEntry: KdbxEntry?, isFromTotpProposal: Bool) -> Bool {
        isFromTotpProposal && existingEntry?.totpSecretBase32?.isEmpty == false
    }

    static func resolvedTitle(draftTitle: String, url: String) -> String {
        let trimmed = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        guard !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        return ExtensionEntryMatcher.registrableDomain(from: url) ?? url
    }

    /// Seeds the editor's OTP field: an incoming save-proposal prefill always wins
    /// (it represents a fresh secret the user is actively setting up), otherwise the
    /// entry's own stored secret is shown so it can be viewed/edited, otherwise empty.
    static func initialOtpauthInput(prefilled: String?, existingSecret: String?) -> String {
        prefilled ?? existingSecret ?? ""
    }

    static func applyOTP(to entry: inout KdbxEntry, otpauthInput: String) {
        guard !otpauthInput.isEmpty else { return }
        if let parsed = TOTPCode.parse(otpauthURL: otpauthInput) {
            entry.totpSecretBase32 = TOTPCode.base32Encode(parsed.secret)
        } else {
            entry.totpSecretBase32 = otpauthInput
        }
    }

    /// Explicit removal path: unlike `applyOTP`'s empty-input no-op (which
    /// deliberately preserves an existing secret), this clears it. Only
    /// called when the user has actively removed 2FA via the editor's
    /// "Remove" button.
    static func applyOTPRemoval(to entry: inout KdbxEntry) {
        entry.totpSecretBase32 = nil
    }
}
