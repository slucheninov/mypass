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
    /// What the saved entry held when the editor opened; used to tell files that are
    /// already stored (deleting them is irreversible after Save) from new ones.
    private let originals: [KdbxAttachment]
    /// Drops whose file URLs are still loading asynchronously. Save stays disabled
    /// while this is above zero; otherwise the saved list would miss the dropped files.
    private(set) var pendingLoads = 0
    var isLoadingDrops: Bool { pendingLoads > 0 }

    init(attachments: [KdbxAttachment] = []) {
        self.attachments = attachments
        self.originals = attachments
    }

    /// A delete needs confirmation only for a file that is already in the saved
    /// entry (same name and bytes). A file added during this editing session can be
    /// dropped freely because nothing stored is lost.
    func needsDeleteConfirmation(at index: Int) -> Bool {
        guard attachments.indices.contains(index) else { return false }
        let a = attachments[index]
        return originals.contains { $0.name == a.name && $0.data == a.data }
    }

    /// Processes `urls` in order. Each valid file is added until the per-entry cap is
    /// hit; every rejection is collected (the cap error once) and shown together, so
    /// no file is ever dropped silently. `read` is injectable for tests; the real
    /// reader is `EntryAttachmentRules.readFile` (5 MiB at most, synchronous).
    mutating func add(
        urls: [URL],
        extraErrors: [String] = [],
        read: (URL) throws -> (name: String, data: Data) = EntryAttachmentRules.readFile(at:)
    ) {
        var scratch = KdbxEntry(uuid: UUID(), iconID: 0, fields: [], attachments: attachments,
                                creationTime: Date(), lastModificationTime: Date(),
                                lastAccessTime: Date(), locationChanged: Date(), history: [])
        var messages: [String] = extraErrors
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
        // Errors are sticky: overlapping drops must not let a later success hide an
        // earlier failure. New messages append; only `dismissError()` clears them.
        if !messages.isEmpty {
            errorMessage = ([errorMessage].compactMap { $0 } + messages).joined(separator: "\n")
        }
    }

    mutating func beginDropLoad() { pendingLoads += 1 }

    /// Ends one drop load. A `nil` entry is an item provider that failed; it is
    /// reported with the other rejections. The counter always drops, so Save is
    /// never left blocked by a failed load.
    mutating func finishDropLoad(
        urls: [URL?],
        read: (URL) throws -> (name: String, data: Data) = EntryAttachmentRules.readFile(at:)
    ) {
        pendingLoads = max(0, pendingLoads - 1)
        let failures = urls.filter { $0 == nil }.map { _ in AttachmentAddError.dropLoadFailed.localizedDescription }
        add(urls: urls.compactMap { $0 }, extraErrors: failures, read: read)
    }

    mutating func remove(at index: Int) {
        guard attachments.indices.contains(index) else { return }
        attachments.remove(at: index)
    }

    /// Explicit user acknowledgement of the pending error message.
    mutating func dismissError() { errorMessage = nil }

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
    @State private var pendingDeleteIndex: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Attachments").font(.headline)
                Spacer()
                Button("Add File…", systemImage: "paperclip", action: chooseFiles)
            }
            if model.attachments.count > Self.visibleRows {
                // Imported vaults can hold many files; scroll instead of pushing the form away.
                ScrollView { rows }.frame(height: CGFloat(Self.visibleRows) * Self.rowHeight)
            } else {
                rows
            }
            if model.isLoadingDrops {
                ProgressView().controlSize(.small)
            }
            if isDropTargeted {
                Text("Drop files to attach").foregroundStyle(.secondary)
            }
            if let message = model.errorMessage {
                HStack(alignment: .firstTextBaseline) {
                    Text(verbatim: message).foregroundStyle(.red).font(.callout)
                    Spacer()
                    Button("OK") { model.dismissError() }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(Color.accentColor, lineWidth: isDropTargeted ? 2 : 0))
        .confirmationDialog(
            Text("Delete “\(pendingName)”?"),
            isPresented: Binding(get: { pendingDeleteIndex != nil }, set: { if !$0 { pendingDeleteIndex = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let i = pendingDeleteIndex { model.remove(at: i) }
                pendingDeleteIndex = nil
            }
            Button("Cancel", role: .cancel) { pendingDeleteIndex = nil }
        } message: {
            Text("The file is removed when you save. This can't be undone after saving.")
        }
    }

    private static let visibleRows = 6
    private static let rowHeight: CGFloat = 28

    private var rows: some View {
        VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(model.attachments.enumerated()), id: \.offset) { index, attachment in
                    HStack {
                        Image(systemName: "doc")
                        Text(verbatim: attachment.name).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.data.count), countStyle: .binary))
                            .foregroundStyle(.secondary)
                        // Stored files ask first (irreversible after Save); files added in this session do not.
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            if model.needsDeleteConfirmation(at: index) { pendingDeleteIndex = index }
                            else { model.remove(at: index) }
                        }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.plain)
                            .foregroundStyle(.red)
                            .accessibilityLabel(Text("Delete \(attachment.name)"))
                    }
                }
        }
    }

    private var pendingName: String {
        guard let i = pendingDeleteIndex, model.attachments.indices.contains(i) else { return "" }
        return model.attachments[i].name
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
            model.wrappedValue.beginDropLoad()
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
            group.notify(queue: .main) { model.wrappedValue.finishDropLoad(urls: urls) }
            return !providers.isEmpty
        }
    }
}
