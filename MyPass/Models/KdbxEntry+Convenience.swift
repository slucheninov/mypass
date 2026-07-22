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
