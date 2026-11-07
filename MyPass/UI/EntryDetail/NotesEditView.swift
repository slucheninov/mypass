import SwiftUI
import MyPassKit

struct NotesEditView: View {
    let existingEntry: KdbxEntry?
    let rootGroup: KdbxGroup
    let recycleBinGroupUUID: UUID?
    let defaultGroupID: UUID
    let onCancel: () -> Void
    let onSave: (KdbxEntry, UUID) -> Void
    let onDelete: () -> Void

    @State private var selectedGroupID: UUID
    @State private var title: String = ""
    @State private var notesBody: String = ""
    @State private var isFavorite: Bool
    @State private var entryID: UUID
    @State private var preservedAdditionalFields: [KdbxField] = []
    @EnvironmentObject private var vaultSession: VaultSession
    @State private var drafts: NoteDraftEditorModel?

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
        _entryID = State(initialValue: existingEntry?.uuid ?? UUID())
        _title = State(initialValue: existingEntry?.title ?? "")
        _notesBody = State(initialValue: existingEntry?.notesBody ?? "")
        _isFavorite = State(initialValue: existingEntry?.isFavorite ?? false)
        _preservedAdditionalFields = State(initialValue: existingEntry?.additionalFields ?? [])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                TextField("Title", text: $title)
                    .font(.system(size: 28, weight: .bold))
                    .textFieldStyle(.plain)
                GroupPickerView(
                    rootGroup: rootGroup,
                    recycleBinGroupUUID: recycleBinGroupUUID,
                    selectedGroupID: $selectedGroupID
                )
            }

            if let drafts {
                NoteDraftRecoverySection(model: drafts)
            }

            NotesEditorCard(
                text: $notesBody,
                restoreRequest: restoreRequestBinding,
                entryID: entryID,
                controller: drafts?.controller,
                showsMarkdownToolbar: true
            )
            .frame(maxHeight: .infinity)

            if existingEntry != nil {
                Button("Delete", role: .destructive, action: onDelete)
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 20)
        .background(UIShellMetrics.detailColumnBackground)
        .navigationTitle(existingEntry == nil ? "New Note" : "Edit Note")
        .safeAreaInset(edge: .top, spacing: 0) {
            EntryEditActionRow(isFavorite: $isFavorite, onCancel: cancel, onSave: save)
        }
        .onAppear(perform: openDrafts)
        .onDisappear { drafts?.cancel() }
    }

    private var restoreRequestBinding: Binding<String?> {
        Binding(get: { drafts?.restoreRequest }, set: { drafts?.restoreRequest = $0 })
    }

    /// Editors exist only while the vault is unlocked, so the store's Keychain key is
    /// loaded here (a plain read, never an auth prompt).
    private func openDrafts() {
        guard drafts == nil, let store = vaultSession.noteDraftStore else { return }
        store.unlock()
        drafts = NoteDraftEditorModel(
            store: store, vaultID: vaultSession.draftVaultID, entryID: entryID,
            savedNotes: existingEntry?.notesBody ?? "", entryLastModified: existingEntry?.lastModificationTime)
    }

    private func cancel() {
        drafts?.cancel()
        onCancel()
    }

    private func save() {
        let now = Date()
        var entry = existingEntry ?? KdbxEntry(
            uuid: entryID,
            iconID: 0,
            fields: [],
            creationTime: now,
            lastModificationTime: now,
            lastAccessTime: now,
            locationChanged: now,
            history: []
        )
        entry.entryType = .notes
        entry.title = title
        entry.notesBody = notesBody
        entry.isFavorite = isFavorite
        entry.lastModificationTime = now
        entry.lastAccessTime = now

        entry.fields.removeAll { !KdbxEntry.standardFieldKeys.contains($0.key) }
        for field in preservedAdditionalFields {
            entry.fields.append(field)
        }

        onSave(entry, selectedGroupID)
        drafts?.discardAfterSave()
    }
}
