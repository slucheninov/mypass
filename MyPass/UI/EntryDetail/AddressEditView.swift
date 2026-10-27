import SwiftUI
import MyPassKit
import ExtensionBridgeKit

struct AddressEditView: View {
    let existingEntry: KdbxEntry?
    let rootGroup: KdbxGroup
    let recycleBinGroupUUID: UUID?
    let onCancel: () -> Void
    let onSave: (KdbxEntry, UUID) -> Void
    let onDelete: () -> Void

    @State private var selectedGroupID: UUID
    @State private var title: String
    @State private var address: ExtensionAddress
    @State private var notes: String
    @State private var isFavorite: Bool

    init(existingEntry: KdbxEntry?, rootGroup: KdbxGroup, recycleBinGroupUUID: UUID?, defaultGroupID: UUID,
         onCancel: @escaping () -> Void, onSave: @escaping (KdbxEntry, UUID) -> Void, onDelete: @escaping () -> Void) {
        self.existingEntry = existingEntry
        self.rootGroup = rootGroup
        self.recycleBinGroupUUID = recycleBinGroupUUID
        self.onCancel = onCancel
        self.onSave = onSave
        self.onDelete = onDelete
        _selectedGroupID = State(initialValue: defaultGroupID)
        _title = State(initialValue: existingEntry?.title ?? "")
        _address = State(initialValue: existingEntry?.storedAddress ?? ExtensionAddress())
        _notes = State(initialValue: existingEntry?.notes ?? "")
        _isFavorite = State(initialValue: existingEntry?.isFavorite ?? false)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: "house.fill")
                    .font(.system(size: 42)).foregroundStyle(.teal).padding(.top, 24)
                // Branches, not a ternary: a literal mixed with the typed title would make a `String`
                // and skip the string catalog for "New Address".
                Group {
                    if title.isEmpty { Text("New Address") } else { Text(verbatim: title) }
                }
                .font(.title2.bold())
                EntryEditFieldsCard {
                    GroupPickerView(rootGroup: rootGroup, recycleBinGroupUUID: recycleBinGroupUUID, selectedGroupID: $selectedGroupID)
                    TextField("Title (for example, Home)", text: $title)
                    Picker("Type", selection: $address.label) {
                        ForEach(KdbxEntry.addressLabels, id: \.self) { Text(verbatim: KdbxEntry.addressLabelTitle($0)).tag($0) }
                    }
                    Divider()
                    TextField("Full Name", text: $address.fullName)
                    TextField("Given Name (optional)", text: $address.givenName)
                    TextField("Family Name (optional)", text: $address.familyName)
                    Text("Given and family names fill separate name fields. If Full Name is empty, these two names are joined.")
                        .font(.caption).foregroundStyle(.secondary)
                    TextField("Organization", text: $address.organization)
                    Divider()
                    TextField("Address Line 1", text: $address.addressLine1, axis: .vertical)
                    TextField("Address Line 2", text: $address.addressLine2, axis: .vertical)
                    TextField("City", text: $address.city)
                    TextField("State / Province / Region", text: $address.region)
                    TextField("Postal Code", text: $address.postalCode)
                    Picker("Country", selection: $address.countryCode) {
                        Text("Not specified").tag("")
                        ForEach(AddressCountries.options, id: \.code) { country in
                            Text(verbatim: country.name).tag(country.code)
                        }
                    }
                    .onChange(of: address.countryCode) { _, code in
                        address.countryName = AddressCountries.options.first { $0.code == code }?.name ?? ""
                    }
                    Divider()
                    TextField("Phone (optional)", text: $address.phone)
                    TextField("Email (optional)", text: $address.email)
                    TextField("Notes", text: $notes, axis: .vertical).lineLimit(3...8)
                }
                Text("Saved in your encrypted vault. To fill a website, open the MyPass extension, choose Addresses, and select an address. MyPass does not submit the form.")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: UIShellMetrics.cardMaxWidth, alignment: .leading)
                if existingEntry != nil {
                    Button("Delete", role: .destructive, action: onDelete).foregroundStyle(.red)
                }
            }
            .frame(maxWidth: .infinity).padding(24)
        }
        .background(UIShellMetrics.detailColumnBackground)
        .navigationTitle(existingEntry == nil ? "New Address" : "Edit Address")
        .safeAreaInset(edge: .top, spacing: 0) {
            EntryEditActionRow(isFavorite: $isFavorite, onCancel: onCancel, onSave: {
                onSave(AddressEntryEditing.savedEntry(existing: existingEntry, title: title, address: address, favorite: isFavorite, notes: notes), selectedGroupID)
            })
        }
    }
}

enum AddressCountries {
    static let options: [(code: String, name: String)] = {
        let english = Locale(identifier: "en_US")
        return Locale.Region.isoRegions.compactMap { region in
            let code = region.identifier
            guard code.count == 2, let name = english.localizedString(forRegionCode: code) else { return nil }
            return (code: code, name: name)
        }.sorted { $0.name < $1.name }
    }()
}
