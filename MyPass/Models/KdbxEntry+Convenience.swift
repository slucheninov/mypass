import Foundation
import MyPassKit

private extension KdbxEntry {
    func fieldValue(forKey key: String) -> String {
        fields.first(where: { $0.key == key })?.value ?? ""
    }

    mutating func setFieldValue(_ value: String, forKey key: String, isProtected: Bool) {
        if let index = fields.firstIndex(where: { $0.key == key }) {
            fields[index].value = value
        } else {
            fields.append(KdbxField(key: key, value: value, isProtected: isProtected))
        }
    }
}

extension KdbxEntry {
    var title: String {
        get { fieldValue(forKey: "Title") }
        set { setFieldValue(newValue, forKey: "Title", isProtected: false) }
    }

    var login: String {
        get { fieldValue(forKey: "UserName") }
        set { setFieldValue(newValue, forKey: "UserName", isProtected: false) }
    }

    var password: String {
        get { fieldValue(forKey: "Password") }
        set { setFieldValue(newValue, forKey: "Password", isProtected: true) }
    }

    var url: String {
        get { fieldValue(forKey: "URL") }
        set { setFieldValue(newValue, forKey: "URL", isProtected: false) }
    }

    var notes: String {
        get { fieldValue(forKey: "Notes") }
        set { setFieldValue(newValue, forKey: "Notes", isProtected: false) }
    }

    var totpSecretBase32: String? {
        get { fields.first(where: { $0.key == "otp" })?.value }
        set {
            guard let newValue else {
                fields.removeAll(where: { $0.key == "otp" })
                return
            }
            setFieldValue(newValue, forKey: "otp", isProtected: true)
        }
    }
}

public extension KdbxEntry {
    static let standardFieldKeys: Set<String> = ["Title", "UserName", "Password", "URL", "Notes", "otp"]
    static let additionalURLsStringArrayKey = "KP2A_URL"

    /// Primary URL (if non-empty) followed by `KP2A_URL` StringArray extras, deduplicated,
    /// order preserved. Setting the first element becomes the primary `URL` field; the
    /// remainder is stored as the `KP2A_URL` StringArray. An empty array clears both.
    var urls: [String] {
        get {
            var result: [String] = []
            if !url.isEmpty {
                result.append(url)
            }
            if let array = stringArrays.first(where: { $0.key == Self.additionalURLsStringArrayKey }) {
                for value in array.values where !result.contains(value) {
                    result.append(value)
                }
            }
            return result
        }
        set {
            var remaining = newValue
            url = remaining.isEmpty ? "" : remaining.removeFirst()
            stringArrays.removeAll { $0.key == Self.additionalURLsStringArrayKey }
            if !remaining.isEmpty {
                stringArrays.append(KdbxStringArray(key: Self.additionalURLsStringArrayKey, values: remaining))
            }
        }
    }

    /// Non-standard fields to render as browse/edit custom-field rows. `KP2A_URL` is never
    /// present here — it lives in `stringArrays`, a separate collection from `fields`.
    var additionalFields: [KdbxField] {
        fields.filter { !Self.standardFieldKeys.contains($0.key) }
    }
}
