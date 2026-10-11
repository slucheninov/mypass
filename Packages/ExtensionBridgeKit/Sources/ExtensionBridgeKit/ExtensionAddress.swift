import Foundation

/// Address data is returned only for an explicit fill request, never in browse lists.
public struct ExtensionAddress: Codable, Equatable {
    public var id: String
    public var label: String
    public var fullName: String
    public var givenName: String
    public var familyName: String
    public var organization: String
    public var addressLine1: String
    public var addressLine2: String
    public var city: String
    public var region: String
    public var postalCode: String
    public var countryCode: String
    public var countryName: String
    public var phone: String
    public var email: String

    public init(
        id: String = "",
        label: String = "Home",
        fullName: String = "",
        givenName: String = "",
        familyName: String = "",
        organization: String = "",
        addressLine1: String = "",
        addressLine2: String = "",
        city: String = "",
        region: String = "",
        postalCode: String = "",
        countryCode: String = "",
        countryName: String = "",
        phone: String = "",
        email: String = ""
    ) {
        self.id = id
        self.label = label
        self.fullName = fullName
        self.givenName = givenName
        self.familyName = familyName
        self.organization = organization
        self.addressLine1 = addressLine1
        self.addressLine2 = addressLine2
        self.city = city
        self.region = region
        self.postalCode = postalCode
        self.countryCode = countryCode
        self.countryName = countryName
        self.phone = phone
        self.email = email
    }
}
