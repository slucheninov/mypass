import SwiftUI

/// The kept draft versions (the store keeps at most 10), newest first, each restorable.
struct NoteDraftVersionsSheet: View {
    let versions: [NoteDraftVersion]
    let onRestore: (NoteDraftVersion) -> Void
    var onClose: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Draft versions")
                .font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(versions.prefix(10)) { version in
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(version.savedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(verbatim: version.notes.isEmpty ? " " : version.notes)
                                    .lineLimit(3)
                                    .font(.callout)
                            }
                            Spacer(minLength: 8)
                            Button("Restore") { onRestore(version) }
                        }
                        Divider()
                    }
                }
            }
            HStack {
                Spacer()
                Button("Done", action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 440, height: 360)
    }
}
