import Foundation
import MyPassKit

extension KdbxEntry {
    static let uriMatchModeFieldKey = "MyPass.URIMatchMode"

    /// Absent or unrecognised reads as `.registrableDomain` — the same matching
    /// behaviour every existing MyPass and KeePassXC vault already has, with no
    /// migration step required. Setting `.registrableDomain` removes the field
    /// again (mirroring `entryType`'s own default-removes-the-field convention
    /// in `KdbxEntry+Convenience.swift`), so a vault untouched by this feature
    /// stays byte-for-byte free of this key.
    var uriMatchMode: URIMatchMode {
        get {
            URIMatchMode(rawValue: fieldValue(forKey: Self.uriMatchModeFieldKey)) ?? .registrableDomain
        }
        set {
            if newValue == .registrableDomain {
                fields.removeAll { $0.key == Self.uriMatchModeFieldKey }
            } else {
                setFieldValue(newValue.rawValue, forKey: Self.uriMatchModeFieldKey, isProtected: false)
            }
        }
    }
}
