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
    @State private var pendingMarkdownAction: MarkdownWrapAction?
    @State private var preservedAdditionalFields: [KdbxField] = []

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
        _title = State(initialValue: existingEntry?.title ?? "")
        _notesBody = State(initialValue: existingEntry?.notesBody ?? "")
        _isFavorite = State(initialValue: existingEntry?.isFavorite ?? false)
        _preservedAdditionalFields = State(initialValue: existingEntry?.additionalFields ?? [])
    }

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                TextField("Title", text: $title)
                    .font(.system(size: 17, weight: .semibold))
                    .textFieldStyle(.plain)
                GroupPickerView(
                    rootGroup: rootGroup,
                    recycleBinGroupUUID: recycleBinGroupUUID,
                    selectedGroupID: $selectedGroupID
                )
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)

            markdownToolbar
                .padding(.horizontal, 24)

            MarkdownTextEditor(text: $notesBody, wrapAction: $pendingMarkdownAction)
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if existingEntry != nil {
                Button("Delete", role: .destructive, action: onDelete)
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                    .padding(.bottom, 20)
            }
        }
        .background(UIShellMetrics.detailColumnBackground)
        .navigationTitle(existingEntry == nil ? "New Note" : "Edit Note")
        .toolbar {
            EditActionsToolbarContent(onCancel: onCancel, onSave: save)
            FavoriteToggleToolbarItem(isFavorite: $isFavorite)
        }
    }

    // Only B/I/inline-code are offered here: U, H1-H3, HR, and fenced code blocks all
    // require block-level or raw-HTML rendering that NotesBodyRenderer's plain-Text
    // display can't show (see NotesBodyRenderer's doc comment) — offering a formatting
    // action with no visible effect would be worse than not offering it at all.
    private var markdownToolbar: some View {
        HStack(spacing: 8) {
            toolbarButton("bold", "B") { pendingMarkdownAction = .wrap(prefix: "**", suffix: "**") }
            toolbarButton("italic", "I") { pendingMarkdownAction = .wrap(prefix: "*", suffix: "*") }
            Divider().frame(height: 16)
            toolbarButton("code", "`code`") { pendingMarkdownAction = .wrap(prefix: "`", suffix: "`") }
            Spacer(minLength: 0)
        }
    }

    private func toolbarButton(_ id: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(label, action: action)
            .buttonStyle(.bordered)
            .accessibilityIdentifier("markdownToolbar.\(id)")
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
    }
}
