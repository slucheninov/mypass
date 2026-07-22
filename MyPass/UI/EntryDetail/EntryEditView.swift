import SwiftUI
import MyPassKit

struct EntryEditView: View {
    let existingEntry: KdbxEntry?
    let onSave: (KdbxEntry) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title: String = ""
    @State private var login: String = ""
    @State private var password: String = ""
    @State private var url: String = ""
    @State private var notes: String = ""
    @State private var otpauthInput: String = ""
    @State private var extraFields: [(key: String, value: String)] = []
    @State private var showPasswordGenerator = false

    init(existingEntry: KdbxEntry?, onSave: @escaping (KdbxEntry) -> Void) {
        self.existingEntry = existingEntry
        self.onSave = onSave
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
            TextField("Название", text: $title)
            TextField("Логин", text: $login)
            HStack {
                SecureField("Пароль", text: $password)
                Button("Сгенерировать") { showPasswordGenerator = true }
            }
            TextField("URL", text: $url)
            TextField("Заметки", text: $notes, axis: .vertical)
            TextField("otpauth:// или secret", text: $otpauthInput)

            Section("Дополнительные поля") {
                ForEach(extraFields.indices, id: \.self) { index in
                    HStack {
                        TextField("Ключ", text: $extraFields[index].key)
                        TextField("Значение", text: $extraFields[index].value)
                        Button("Удалить", systemImage: "minus.circle") {
                            extraFields.remove(at: index)
                        }
                    }
                }
                Button("Добавить поле", systemImage: "plus") {
                    extraFields.append((key: "", value: ""))
                }
            }

            HStack {
                Button("Отмена") { dismiss() }
                Button("Сохранить", action: save)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding()
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
        entry.title = title
        entry.login = login
        entry.password = password
        entry.url = url
        entry.notes = notes
        entry.lastModificationTime = now
        entry.lastAccessTime = now

        if !otpauthInput.isEmpty {
            if let parsed = TOTPCode.parse(otpauthURL: otpauthInput) {
                entry.totpSecretBase32 = TOTPCode.base32Encode(parsed.secret)
            } else {
                entry.totpSecretBase32 = otpauthInput // treat as a raw Base32 secret pasted directly
            }
        }

        let standardKeys: Set<String> = ["Title", "UserName", "Password", "URL", "Notes", "otp"]
        entry.fields.removeAll { !standardKeys.contains($0.key) }
        for field in extraFields where !field.key.isEmpty {
            entry.fields.append(KdbxField(key: field.key, value: field.value, isProtected: false))
        }

        onSave(entry)
        dismiss()
    }
}
