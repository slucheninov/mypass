import Foundation
import MyPassKit

/// Builds the entry `FilesEditView` saves, kept apart from the view so it can be tested.
enum FilesEntrySaveLogic {
    static func savedEntry(
        existing: KdbxEntry?,
        entryID: UUID,
        title: String,
        description: String,
        isFavorite: Bool,
        attachments: AttachmentsEditModel,
        preservedAdditionalFields: [KdbxField],
        now: Date
    ) -> KdbxEntry {
        var entry = existing ?? KdbxEntry(
            uuid: entryID,
            iconID: 0,
            fields: [],
            creationTime: now,
            lastModificationTime: now,
            lastAccessTime: now,
            locationChanged: now,
            history: []
        )
        entry = attachments.applying(to: entry)
        entry.entryType = .files
        entry.title = title
        entry.notes = description
        entry.isFavorite = isFavorite
        entry.lastModificationTime = now
        entry.lastAccessTime = now

        // Custom fields (including any passkey fields an imported vault carried) survive the edit.
        entry.fields.removeAll { !KdbxEntry.standardFieldKeys.contains($0.key) }
        for field in preservedAdditionalFields {
            entry.fields.append(field)
        }
        return entry
    }
}
