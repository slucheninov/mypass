import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MyPassKit

/// Editor-side state for an entry's attachments. Pure value type so the add/remove
/// rules are testable without UI. Edits stay here until Save applies them to the
/// entry (`applying(to:)`); Cancel simply drops the model.
struct AttachmentsEditModel: Equatable {
    var attachments: [KdbxAttachment]
    var errorMessage: String?

    init(attachments: [KdbxAttachment] = []) {
        self.attachments = attachments
    }

    /// Processes `urls` in order. Each valid file is added until the per-entry cap is
    /// hit; every rejection is collected (the cap error once) and shown together, so
    /// no file is ever dropped silently. `read` is injectable for tests; the real
    /// reader is `EntryAttachmentRules.readFile` (5 MiB at most, synchronous).
    mutating func add(
        urls: [URL],
        read: (URL) throws -> (name: String, data: Data) = EntryAttachmentRules.readFile(at:)
    ) {
        var scratch = KdbxEntry(uuid: UUID(), iconID: 0, fields: [], attachments: attachments,
                                creationTime: Date(), lastModificationTime: Date(),
                                lastAccessTime: Date(), locationChanged: Date(), history: [])
        var messages: [String] = []
        var reportedCap = false
        for url in urls {
            do {
                if scratch.attachments.count >= EntryAttachmentRules.maxFilesPerEntry {
                    // Do not read a file that cannot be added anyway.
                    throw AttachmentAddError.tooManyFiles
                }
                let file = try read(url)
                scratch = try scratch.addingAttachment(name: file.name, data: file.data)
            } catch {
                if let add = error as? AttachmentAddError, add == .tooManyFiles {
                    if reportedCap { continue }
                    reportedCap = true
                }
                messages.append(error.localizedDescription)
            }
        }
        attachments = scratch.attachments
        errorMessage = messages.isEmpty ? nil : messages.joined(separator: "\n")
    }

    mutating func remove(at index: Int) {
        guard attachments.indices.contains(index) else { return }
        attachments.remove(at: index)
        errorMessage = nil
    }

    /// Existing attachments keep their `isProtected` flags because they are carried
    /// over as-is; only new ones come in as protected (see `addingAttachment`).
    func applying(to entry: KdbxEntry) -> KdbxEntry {
        var copy = entry
        copy.attachments = attachments
        return copy
    }
}

struct AttachmentsEditSection: View {
    @Binding var model: AttachmentsEditModel
    let isDropTargeted: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Attachments").font(.headline)
                Spacer()
                Button("Add File…", systemImage: "paperclip", action: chooseFiles)
            }
            ForEach(Array(model.attachments.enumerated()), id: \.offset) { index, attachment in
                HStack {
                    Image(systemName: "doc")
                    Text(verbatim: attachment.name).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.data.count), countStyle: .file))
                        .foregroundStyle(.secondary)
                    // No confirmation: the delete only takes effect on Save.
                    Button("Delete", systemImage: "trash", role: .destructive) { model.remove(at: index) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .foregroundStyle(.red)
                        .accessibilityLabel(Text("Delete \(attachment.name)"))
                }
            }
            if isDropTargeted {
                Text("Drop files to attach").foregroundStyle(.secondary)
            }
            if let message = model.errorMessage {
                Text(verbatim: message).foregroundStyle(.red).font(.callout)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(Color.accentColor, lineWidth: isDropTargeted ? 2 : 0))
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        model.add(urls: panel.urls)
    }
}

extension View {
    /// Whole-form drop target for attachments. URLs are loaded asynchronously, then
    /// added in drop order on the main actor in one batch.
    func attachmentDrop(model: Binding<AttachmentsEditModel>, isTargeted: Binding<Bool>) -> some View {
        onDrop(of: [.fileURL], isTargeted: isTargeted) { providers in
            let group = DispatchGroup()
            var urls = [URL?](repeating: nil, count: providers.count)
            for (i, provider) in providers.enumerated() {
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                    var url: URL?
                    if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                    else if let u = item as? URL { url = u }
                    DispatchQueue.main.async { urls[i] = url; group.leave() }
                }
            }
            group.notify(queue: .main) { model.wrappedValue.add(urls: urls.compactMap { $0 }) }
            return !providers.isEmpty
        }
    }
}
