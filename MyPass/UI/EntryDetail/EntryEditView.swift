import SwiftUI
import MyPassKit

struct EntryEditView: View {
    let existingEntry: KdbxEntry?
    let rootGroup: KdbxGroup
    let recycleBinGroupUUID: UUID?
    let defaultGroupID: UUID
    let onCancel: () -> Void
    let onSave: (KdbxEntry, UUID) -> Void
    let onDelete: () -> Void

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
    @State private var isPasswordRevealed = false
    @State private var showWebsitesSheet = false
    @State private var isFavorite: Bool

    init(
        existingEntry: KdbxEntry?,
        rootGroup: KdbxGroup,
        recycleBinGroupUUID: UUID?,
        defaultGroupID: UUID,
        onCancel: @escaping () -> Void,
        onSave: @escaping (KdbxEntry, UUID) -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.existingEntry = existingEntry
        self.rootGroup = rootGroup
        self.recycleBinGroupUUID = recycleBinGroupUUID
        self.defaultGroupID = defaultGroupID
        self.onCancel = onCancel
        self.onSave = onSave
        self.onDelete = onDelete
        _selectedGroupID = State(initialValue: defaultGroupID)
        _showOTPField = State(initialValue: existingEntry?.totpSecretBase32?.isEmpty == false)
        _title = State(initialValue: existingEntry?.title ?? "")
        _login = State(initialValue: existingEntry?.login ?? "")
        _password = State(initialValue: existingEntry?.password ?? "")
        _url = State(initialValue: existingEntry?.url ?? "")
        _notes = State(initialValue: existingEntry?.notes ?? "")
        _extraFields = State(initialValue: (existingEntry?.additionalFields ?? [])
            .map { (key: $0.key, value: $0.value) })
        _isFavorite = State(initialValue: existingEntry?.isFavorite ?? false)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(spacing: 12) {
                    LetterAvatarView(
                        title: title.isEmpty ? "(untitled)" : title,
                        size: UIShellMetrics.detailHeroIconSize,
                        cornerRadius: UIShellMetrics.detailHeroIconCornerRadius,
                        letterScale: UIShellMetrics.detailHeroLetterScale
                    )
                    Text(title.isEmpty ? "(untitled)" : title)
                        .font(.system(size: 22, weight: .bold))
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 24)

                EntryEditFieldsCard {
                    GroupPickerView(
                        rootGroup: rootGroup,
                        recycleBinGroupUUID: recycleBinGroupUUID,
                        selectedGroupID: $selectedGroupID
                    )
                    Divider().overlay(Color.primary.opacity(0.08))

                    TextField("Title", text: $title)
                    Divider().overlay(Color.primary.opacity(0.08))

                    TextField("Username", text: $login)
                    Divider().overlay(Color.primary.opacity(0.08))

                    HStack {
                        Group {
                            if isPasswordRevealed {
                                TextField("Password", text: $password)
                            } else {
                                SecureField("Password", text: $password)
                            }
                        }
                        Button {
                            isPasswordRevealed.toggle()
                        } label: {
                            Image(systemName: isPasswordRevealed ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(isPasswordRevealed ? "Hide password" : "Show password")
                        Button("Generate") { showPasswordGenerator = true }
                    }
                    Divider().overlay(Color.primary.opacity(0.08))

                    HStack {
                        TextField("URL", text: $url)
                        if existingEntry != nil {
                            Button("Edit Websites…") { showWebsitesSheet = true }
                        }
                    }
                    Divider().overlay(Color.primary.opacity(0.08))

                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(3...8)
                        .frame(minHeight: 80)
                    Divider().overlay(Color.primary.opacity(0.08))

                    if showOTPField {
                        TextField("otpauth:// or secret", text: $otpauthInput)
                    } else {
                        Button("+ Add one-time password") { showOTPField = true }
                    }

                    if !extraFields.isEmpty {
                        Divider().overlay(Color.primary.opacity(0.08))
                    }
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

                if existingEntry != nil {
                    Button("Delete", role: .destructive, action: onDelete)
                        .buttonStyle(.plain)
                        .foregroundStyle(.red)
                        .padding(.bottom, 24)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
        }
        .background(UIShellMetrics.detailColumnBackground)
        .navigationTitle(existingEntry == nil ? "New Entry" : "Edit Entry")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", action: onCancel)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isFavorite.toggle()
                } label: {
                    Image(systemName: isFavorite ? "star.fill" : "star")
                }
                .accessibilityLabel(isFavorite ? "Remove from Favorites" : "Add to Favorites")
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
        .sheet(isPresented: $showWebsitesSheet) {
            if let existingEntry {
                WebsitesSheet(
                    entryID: existingEntry.uuid,
                    entryTitle: title,
                    initialURLs: existingEntry.urls,
                    onDone: { newURLs in
                        url = newURLs.first ?? ""
                        showWebsitesSheet = false
                    },
                    onCancel: { showWebsitesSheet = false }
                )
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
        entry.isFavorite = isFavorite
        entry.lastModificationTime = now
        entry.lastAccessTime = now
        EntryEditSaveLogic.applyOTP(to: &entry, otpauthInput: otpauthInput)

        entry.fields.removeAll { !KdbxEntry.standardFieldKeys.contains($0.key) }
        for field in extraFields where !field.key.isEmpty {
            entry.fields.append(KdbxField(key: field.key, value: field.value, isProtected: false))
        }

        onSave(entry, selectedGroupID)
    }
}

private struct EntryEditFieldsCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 12) {
            content()
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: UIShellMetrics.cardCornerRadius, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: UIShellMetrics.cardCornerRadius, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.04), radius: 8, y: 2)
        .frame(maxWidth: UIShellMetrics.cardMaxWidth)
    }
}
