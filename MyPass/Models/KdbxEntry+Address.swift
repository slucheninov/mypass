import Foundation
import MyPassKit
import ExtensionBridgeKit

extension KdbxEntry {
    static let addressLabels = ["Home", "Work", "Other"]
    static let addressFields: [(String, WritableKeyPath<ExtensionAddress, String>)] = [
        ("label", \.label),
        ("fullName", \.fullName),
        ("givenName", \.givenName),
        ("familyName", \.familyName),
        ("organization", \.organization),
        ("addressLine1", \.addressLine1),
        ("addressLine2", \.addressLine2),
        ("city", \.city),
        ("region", \.region),
        ("postalCode", \.postalCode),
        ("countryCode", \.countryCode),
        ("countryName", \.countryName),
        ("phone", \.phone),
        ("email", \.email)
    ]
    static let addressFieldKeys = Set(addressFields.map { "MyPass.Address." + $0.0 })

    /// The editor uses the stored fullName, not its display fallback, so editing a
    /// given/family name cannot accidentally freeze an old synthesized full name.
    var storedAddress: ExtensionAddress {
        var result = ExtensionAddress(id: uuid.uuidString)
        for (name, keyPath) in Self.addressFields {
            result[keyPath: keyPath] = fieldValue(forKey: "MyPass.Address." + name)
        }
        if !Self.addressLabels.contains(result.label) { result.label = "Other" }
        return result
    }

    var address: ExtensionAddress {
        get {
            var result = storedAddress
            // Given/family names are explicit data. Never split a full name by guessing.
            if result.fullName.isEmpty {
                result.fullName = [result.givenName, result.familyName].filter { !$0.isEmpty }.joined(separator: " ")
            }
            return result
        }
        set {
            fields.removeAll { Self.addressFieldKeys.contains($0.key) }
            for (name, keyPath) in Self.addressFields {
                fields.append(KdbxField(key: "MyPass.Address." + name, value: newValue[keyPath: keyPath], isProtected: true))
            }
        }
    }

    var addressSummary: String {
        [address.label, address.fullName, address.city].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

enum AddressEntryEditing {
    static func savedEntry(existing: KdbxEntry?, title: String, address: ExtensionAddress, favorite: Bool, notes: String) -> KdbxEntry {
        let now = Date()
        var entry = existing ?? KdbxEntry(uuid: UUID(), iconID: 0, fields: [], creationTime: now, lastModificationTime: now, lastAccessTime: now, locationChanged: now, history: [])
        entry.entryType = .address
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        entry.title = trimmedTitle.isEmpty ? address.label : trimmedTitle
        entry.address = address
        entry.isFavorite = favorite
        entry.notes = notes
        entry.lastModificationTime = now
        return entry
    }
}
