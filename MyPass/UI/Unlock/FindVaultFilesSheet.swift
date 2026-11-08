import SwiftUI

/// Lists the `.kdbx` files `KdbxFileScanner` finds below `folder` and hands the chosen one back.
/// The caller keeps the folder's security-scoped access alive (`FolderAccessGrant`) until the
/// follow-up open flow finishes; this sheet only scans while it is shown.
struct FindVaultFilesSheet: View {
    let folder: URL
    /// The vault file currently in use, marked in the list.
    let connectedFile: URL?
    let onSelect: (URL) -> Void
    let onCancel: () -> Void

    @State private var results: [FoundVaultFile] = []
    @State private var isScanning = true
    @State private var selection: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Find .kdbx Files")
                .font(.headline)

            if isScanning {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Searching…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 80)
            } else if results.isEmpty {
                Text("No .kdbx files found in \(VaultFileInfo.abbreviatedPath(folder.path)).")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            }

            if !results.isEmpty {
                List(results, selection: $selection) { file in
                    row(for: file)
                        .tag(file.url)
                }
                .frame(minHeight: 200)
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Open") {
                    if let selection { onSelect(selection) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(selection == nil)
            }
        }
        .padding(20)
        .frame(width: 520)
        .task {
            // `scanAsync` runs off the main actor and stops when this task is cancelled
            // (sheet dismissed).
            let found = await KdbxFileScanner().scanAsync(folder: folder, home: RealHomeDirectory.url)
            results = found
            isScanning = false
        }
    }

    @ViewBuilder
    private func row(for file: FoundVaultFile) -> some View {
        let info = VaultFileInfo(url: file.url, modified: file.modified, size: file.size)
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(verbatim: info.fileName).fontWeight(.medium)
                if let connectedFile, connectedFile.standardizedFileURL.path == file.url.standardizedFileURL.path {
                    Text("Current")
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .background(Capsule().fill(Color.accentColor.opacity(0.2)))
                }
            }
            Text(verbatim: info.abbreviatedPath)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if let summary = info.summary {
                Text(verbatim: summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if file.isCloudPlaceholder {
                Text("In iCloud, not downloaded yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
