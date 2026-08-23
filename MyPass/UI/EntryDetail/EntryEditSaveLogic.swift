import Foundation
import MyPassKit

enum EntryEditSaveLogic {
    /// Derived at Save time from the entry's stored secret and the OTP field's current
    /// value — not a one-shot flag set from whether the field was prefilled by a TOTP
    /// proposal. That one-shot approach missed the case where the user manually typed a
    /// differing secret, and never cleared itself when the field was cleared back out
    /// (clearing means "keep the existing secret", per `applyOTP`'s empty-input semantics,
    /// so it must not prompt).
    static func requiresReplaceConfirmation(existingSecret: String?, currentOtpauthInput: String) -> Bool {
        guard let existingSecret, !existingSecret.isEmpty else { return false }
        guard !currentOtpauthInput.isEmpty else { return false }
        return normalizedSecret(from: currentOtpauthInput) != existingSecret
    }

    /// Extracts the base32 secret an input represents, matching `applyOTP`'s own parsing:
    /// an `otpauth://` URL is decoded, otherwise the raw input is treated as the secret.
    private static func normalizedSecret(from otpauthInput: String) -> String {
        if let parsed = TOTPCode.parse(otpauthURL: otpauthInput) {
            return TOTPCode.base32Encode(parsed.secret)
        }
        return otpauthInput
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
        entry.totpSecretBase32 = normalizedSecret(from: otpauthInput)
    }

    /// Explicit removal path: unlike `applyOTP`'s empty-input no-op (which
    /// deliberately preserves an existing secret), this clears it. Only
    /// called when the user has actively removed 2FA via the editor's
    /// "Remove" button.
    static func applyOTPRemoval(to entry: inout KdbxEntry) {
        entry.totpSecretBase32 = nil
    }

    /// Removes every `KPEX_PASSKEY_*` field. Deferred to Save like `applyOTPRemoval`, so
    /// pressing Remove and then Cancel leaves the passkey intact — the private key is
    /// unrecoverable once gone, which makes an accidental in-place delete unforgiving.
    static func applyPasskeyRemoval(to entry: inout KdbxEntry) {
        entry.clearPasskey()
    }
}
