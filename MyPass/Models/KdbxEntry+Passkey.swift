import Foundation
import MyPassKit

/// Passkey material attached to a Login entry via KeePassXC's `KPEX_PASSKEY_*`
/// custom fields, so a vault written here stays readable by KeePassXC and vice versa.
///
/// Note the accessors read through `fields.first(where:)?.value` rather than
/// `fieldValue(forKey:)`: that helper returns `""` for a missing field, while every
/// property here must report a genuinely absent passkey as `nil`. This mirrors how
/// `totpSecretBase32` already handles the same distinction.
extension KdbxEntry {
    static let passkeyFieldKeys = [
        "KPEX_PASSKEY_RELYING_PARTY",
        "KPEX_PASSKEY_CREDENTIAL_ID",
        "KPEX_PASSKEY_PRIVATE_KEY_PEM",
        "KPEX_PASSKEY_USER_HANDLE",
        "KPEX_PASSKEY_USERNAME",
        "KPEX_PASSKEY_FLAG_BE",
        "KPEX_PASSKEY_FLAG_BS",
        "KPEX_PASSKEY_CREATED",
    ]

    /// `KPEX_PASSKEY_CREATED` is MyPass's own addition — KeePassXC's field set has no
    /// creation date. It is a plain custom string field, so KeePassXC simply shows it
    /// alongside the others and ignores it; a passkey imported from KeePassXC has no
    /// date at all, which reads as `nil` rather than as an error.
    private static let passkeyDateFormatter = ISO8601DateFormatter()

    private func passkeyField(_ key: String) -> String? {
        fields.first(where: { $0.key == key })?.value
    }

    private mutating func setPasskeyField(_ value: String?, forKey key: String, isProtected: Bool) {
        guard let value else {
            fields.removeAll(where: { $0.key == key })
            return
        }
        setFieldValue(value, forKey: key, isProtected: isProtected)
    }

    var passkeyRelyingParty: String? {
        get { passkeyField("KPEX_PASSKEY_RELYING_PARTY") }
        set { setPasskeyField(newValue, forKey: "KPEX_PASSKEY_RELYING_PARTY", isProtected: false) }
    }

    var passkeyCredentialId: Data? {
        get { passkeyField("KPEX_PASSKEY_CREDENTIAL_ID").flatMap(PasskeyBase64URL.decode) }
        set {
            setPasskeyField(
                newValue.map(PasskeyBase64URL.encode),
                forKey: "KPEX_PASSKEY_CREDENTIAL_ID",
                isProtected: true
            )
        }
    }

    var passkeyPrivateKeyPEM: String? {
        get { passkeyField("KPEX_PASSKEY_PRIVATE_KEY_PEM") }
        set { setPasskeyField(newValue, forKey: "KPEX_PASSKEY_PRIVATE_KEY_PEM", isProtected: true) }
    }

    var passkeyUserHandle: Data? {
        get { passkeyField("KPEX_PASSKEY_USER_HANDLE").flatMap(PasskeyBase64URL.decode) }
        set {
            setPasskeyField(
                newValue.map(PasskeyBase64URL.encode),
                forKey: "KPEX_PASSKEY_USER_HANDLE",
                isProtected: true
            )
        }
    }

    var passkeyUsername: String? {
        get { passkeyField("KPEX_PASSKEY_USERNAME") }
        set { setPasskeyField(newValue, forKey: "KPEX_PASSKEY_USERNAME", isProtected: false) }
    }

    /// When this passkey was created, for display in the entry card. Absent for any
    /// passkey MyPass did not create itself (an import from KeePassXC, say).
    var passkeyCreatedAt: Date? {
        get { passkeyField("KPEX_PASSKEY_CREATED").flatMap(Self.passkeyDateFormatter.date(from:)) }
        set {
            setPasskeyField(
                newValue.map(Self.passkeyDateFormatter.string(from:)),
                forKey: "KPEX_PASSKEY_CREATED",
                isProtected: false
            )
        }
    }

    /// True when this entry carries usable passkey material — the two fields a
    /// signing ceremony cannot proceed without.
    var hasPasskey: Bool {
        passkeyCredentialId != nil && passkeyPrivateKeyPEM != nil
    }

    mutating func clearPasskey() {
        for key in Self.passkeyFieldKeys {
            fields.removeAll(where: { $0.key == key })
        }
    }

    /// Sets the KeePassXC backup-eligible/backup-state flags — both default `1`
    /// at write time for interop with KeePassXC's own passkey convention.
    mutating func setPasskeyBackupFlags(eligible: Bool = true, state: Bool = true) {
        setFieldValue(eligible ? "1" : "0", forKey: "KPEX_PASSKEY_FLAG_BE", isProtected: false)
        setFieldValue(state ? "1" : "0", forKey: "KPEX_PASSKEY_FLAG_BS", isProtected: false)
    }
}

/// Base64url (RFC 4648 §5) without padding — used for every binary WebAuthn
/// value (credential IDs, user handles, challenges) per the spec's wire format.
/// Shared between `KdbxEntry+Passkey.swift` and `PasskeyCeremony.swift`.
enum PasskeyBase64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ string: String) -> Data? {
        var base64 = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        return Data(base64Encoded: base64)
    }
}
