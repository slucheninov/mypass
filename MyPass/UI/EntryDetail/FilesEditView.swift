import SwiftUI
import MyPassKit

/// Editor for a Files item. Mirrors `NotesEditView` (title, group, favourite, drop target,
/// Save blocked while dropped files are still loading, Delete for existing entries), but the
/// attachments are the main content and the free text is a short plain description stored in
/// the standard Notes field. There is no Markdown editor and so no encrypted draft machinery.
struct FilesEditView: View {
    let existingEntry: KdbxEntry?
    let rootGroup: KdbxGroup
    let recycleBinGroupUUID: UUID?
    let defaultGroupID: UUID
    let onCancel: () -> Void
    let onSave: (KdbxEntry, UUID) -> Void
    let onDelete: () -> Void

    @State private var selectedGroupID: UUID
    @State private var title: String = ""
    @State private var descriptionText: String = ""
    @State private var isFavorite: Bool
    @State private var entryID: UUID
    @State private var preservedAdditionalFields: [KdbxField] = []
    @State private var attachmentsModel: AttachmentsEditModel
    @State private var isDropTargeted = false

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
        _descriptionText = State(initialValue: existingEntry?.notes ?? "")
        _isFavorite = State(initialValue: existingEntry?.isFavorite ?? false)
        _attachmentsModel = State(initialValue: AttachmentsEditModel(attachments: existingEntry?.attachments ?? []))
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

            AttachmentsEditSection(model: $attachmentsModel, isDropTargeted: isDropTargeted)

            VStack(alignment: .leading, spacing: 6) {
                Text("Description").font(.headline)
                TextEditor(text: $descriptionText)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: UIShellMetrics.cardCornerRadius, style: .continuous)
                            .fill(Color(nsColor: .controlBackgroundColor))
                    )
                    .frame(minHeight: 80, maxHeight: .infinity)
            }

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
        .attachmentDrop(model: $attachmentsModel, isTargeted: $isDropTargeted)
        .navigationTitle(existingEntry == nil ? "New Files" : "Edit Files")
        .safeAreaInset(edge: .top, spacing: 0) {
            EntryEditActionRow(isFavorite: $isFavorite, onCancel: onCancel, onSave: save,
                               canSave: !attachmentsModel.isLoadingDrops)
        }
    }

    private func save() {
        // Same guard as the Notes editor: a drop still reading would be silently lost.
        guard !attachmentsModel.isLoadingDrops else { return }
        let entry = FilesEntrySaveLogic.savedEntry(
            existing: existingEntry, entryID: entryID, title: title, description: descriptionText,
            isFavorite: isFavorite, attachments: attachmentsModel, preservedAdditionalFields: preservedAdditionalFields,
            now: Date())
        onSave(entry, selectedGroupID)
    }
}
