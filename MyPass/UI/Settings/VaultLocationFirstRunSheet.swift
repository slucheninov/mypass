import SwiftUI
import AppKit
import SyncKit

/// Shown once, before any vault has ever been created, per the approved
/// design: "Use iCloud Drive" (default) or "Skip for now (local only)".
/// There is no password-confirmation step here — nothing exists yet to
/// verify against, unlike `VaultLocationChangeSheet`.
struct VaultLocationFirstRunSheet: View {
    @EnvironmentObject private var vaultSession: VaultSession
    @AppStorage("vaultLocation") private var vaultLocationRawValue: String = VaultLocationOption.local.rawValue
    @AppStorage(SyncBackendResolver.iCloudFolderBookmarkKey) private var syncICloudFolderBookmarkData: Data?

    let onFinished: () -> Void

    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Where should MyPass keep your vault?")
                .font(.headline)
            Text("iCloud Drive keeps the vault in a folder that syncs between your Macs. You can change this later in Settings.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Skip for Now (Local Only)") {
                    vaultLocationRawValue = VaultLocationOption.local.rawValue
                    onFinished()
                }
                Button("Use iCloud Drive") { useICloudDrive() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func useICloudDrive() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        panel.message = "Choose a folder inside iCloud Drive for the MyPass vault."
        panel.directoryURL = ICloudDriveLocation.iCloudDriveRootURL

        guard panel.runModal() == .OK, let folderURL = panel.url else { return }

        do {
            // Wherever the user grants access, keep the vault in its own
            // "MyPass" subfolder rather than dropping it loose into whatever
            // folder they picked (which defaults to the iCloud Drive root).
            let vaultFolderURL = folderURL.appendingPathComponent("MyPass", isDirectory: true)
            try FileManager.default.createDirectory(at: vaultFolderURL, withIntermediateDirectories: true)
            let bookmark = try iCloudBackend.createFolderBookmark(for: vaultFolderURL)
            let applicationSupportDirectory = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("MyPass")
            let store = try ICloudDriveVaultStore(
                bookmarkData: bookmark,
                localBackupDirectory: applicationSupportDirectory.appendingPathComponent("backups")
            )
            vaultSession.updatePrimaryStore(store)
            syncICloudFolderBookmarkData = bookmark
            vaultLocationRawValue = VaultLocationOption.iCloudDrive.rawValue
            onFinished()
        } catch {
            errorMessage = "MyPass could not use that folder: \(error)"
        }
    }
}
