import SwiftUI
import MyPassKit

struct EntryEditView: View {
    let existingEntry: KdbxEntry?
    let rootGroup: KdbxGroup
    let recycleBinGroupUUID: UUID?
    let defaultGroupID: UUID
    let onCancel: () -> Void
    let onSave: (KdbxEntry, UUID) -> Void

    @State private var selectedGroupID: UUID
    @State private var showOTPField: Bool
    @State private var title: String = ""
    @State private var login: String = ""
    @State private var password: String = ""
    @State private var url: String = ""
    @State private var notes: String = ""
    @State private var otpauthInput: String = ""
    @State private var extraFields: [(key: String, value: String)] = []
    @State private var showPasswordGenerator = false

    init(
        existingEntry: KdbxEntry?,
        rootGroup: KdbxGroup,
        recycleBinGroupUUID: UUID?,
        defaultGroupID: UUID,
        onCancel: @escaping () -> Void,
        onSave: @escaping (KdbxEntry, UUID) -> Void
    ) {
        self.existingEntry = existingEntry
        self.rootGroup = rootGroup
        self.recycleBinGroupUUID = recycleBinGroupUUID
        self.defaultGroupID = defaultGroupID
        self.onCancel = onCancel
        self.onSave = onSave
        _selectedGroupID = State(initialValue: defaultGroupID)
        _showOTPField = State(initialValue: existingEntry?.totpSecretBase32?.isEmpty == false)
        _title = State(initialValue: existingEntry?.title ?? "")
        _login = State(initialValue: existingEntry?.login ?? "")
        _password = State(initialValue: existingEntry?.password ?? "")
        _url = State(initialValue: existingEntry?.url ?? "")
        _notes = State(initialValue: existingEntry?.notes ?? "")
        let standardKeys: Set<String> = ["Title", "UserName", "Password", "URL", "Notes", "otp"]
        _extraFields = State(initialValue: (existingEntry?.fields ?? [])
            .filter { !standardKeys.contains($0.key) }
            .map { (key: $0.key, value: $0.value) })
    }

    var body: some View {
        Form {
            GroupPickerView(
                rootGroup: rootGroup,
                recycleBinGroupUUID: recycleBinGroupUUID,
                selectedGroupID: $selectedGroupID
            )
            TextField("Title", text: $title)
            TextField("Username", text: $login)
            HStack {
                SecureField("Password", text: $password)
                Button("Generate") { showPasswordGenerator = true }
            }
            TextField("URL", text: $url)
            TextField("Notes", text: $notes, axis: .vertical)
                .lineLimit(3...8)
                .frame(minHeight: 80)
            if showOTPField {
                TextField("otpauth:// or secret", text: $otpauthInput)
            } else {
                Button("+ Add one-time password") { showOTPField = true }
            }

            Section("Additional Fields") {
                ForEach(extraFields.indices, id: \.self) { index in
                    HStack {
                        TextField("Key", text: $extraFields[index].key)
                        TextField("Value", text: $extraFields[index].value)
                        Button("Remove", systemImage: "minus.circle") {
                            extraFields.remove(at: index)
                        }
                    }
                }
                Button("Add Field", systemImage: "plus") {
                    extraFields.append((key: "", value: ""))
                }
            }
        }
        .padding()
        .navigationTitle(existingEntry == nil ? "New Entry" : "Edit Entry")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", action: onCancel)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save)
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .sheet(isPresented: $showPasswordGenerator) {
            PasswordGeneratorView { generated in
                password = generated
                showPasswordGenerator = false
            }
        }
    }

    private func save() {
        let now = Date()
        var entry = existingEntry ?? KdbxEntry(
            uuid: UUID(),
            iconID: 0,
            fields: [],
            creationTime: now,
            lastModificationTime: now,
            lastAccessTime: now,
            locationChanged: now,
            history: []
        )
        entry.title = EntryEditSaveLogic.resolvedTitle(draftTitle: title, url: url)
        entry.login = login
        entry.password = password
        entry.url = url
        entry.notes = notes
        entry.lastModificationTime = now
        entry.lastAccessTime = now
        EntryEditSaveLogic.applyOTP(to: &entry, otpauthInput: otpauthInput, isEditingExisting: existingEntry != nil)

        let standardKeys: Set<String> = ["Title", "UserName", "Password", "URL", "Notes", "otp"]
        entry.fields.removeAll { !standardKeys.contains($0.key) }
        for field in extraFields where !field.key.isEmpty {
            entry.fields.append(KdbxField(key: field.key, value: field.value, isProtected: false))
        }

        onSave(entry, selectedGroupID)
    }
}
