import SwiftUI
import MyPassKit

/// Read-only list of an entry's attachments with a "Save to disk…" action per row.
/// Hidden when there are none. There is deliberately no preview and no "open":
/// attachment bytes must never reach disk except at a destination the user picks
/// (see `AttachmentExporter`). Names and sizes are not secret, so they are not blurred.
struct AttachmentsDetailSection: View {
    let attachments: [KdbxAttachment]
    @State private var showError = false

    var body: some View {
        if !attachments.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Attachments").font(.headline)
                DetailFieldsCard {
                    if attachments.count > Self.visibleRows {
                        // Imported vaults can hold many files; scroll instead of growing the pane.
                        ScrollView { attachmentRows }
                            .frame(height: CGFloat(Self.visibleRows) * Self.rowHeight)
                    } else {
                        attachmentRows
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .alert("Could not save the file.", isPresented: $showError) {
                Button("OK", role: .cancel) {}
            }
        }
    }

    private static let visibleRows = 6
    private static let rowHeight: CGFloat = 44

    private var attachmentRows: some View {
        VStack(spacing: 0) {
            ForEach(Array(attachments.enumerated()), id: \.offset) { index, attachment in
                if index > 0 { DetailFieldDivider() }
                HStack {
                    Image(systemName: "doc")
                    Text(verbatim: attachment.name).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.data.count), countStyle: .binary))
                        .foregroundStyle(.secondary)
                    Button("Save to disk…") { save(attachment) }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
        }
    }

    private func save(_ attachment: KdbxAttachment) {
        do {
            // A cancelled panel returns nil and is intentionally silent.
            try AttachmentExporter(panel: NSSavePanelPresenter()).export(attachment)
        } catch {
            showError = true
        }
    }
}
