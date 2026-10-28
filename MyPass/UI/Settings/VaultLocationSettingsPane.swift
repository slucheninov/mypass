import SwiftUI

/// The "Location" section of the Vault pane. It is not a pane of its own any more: it is a
/// section hosted by `VaultSettingsPane`, which supplies the single grouped `Form` (and its
/// scrolling) around it.
///
/// Reachable before authentication as well as after — unlike the old Sync
/// pane's iCloud button, "Change Location…" is never disabled on lock state;
/// `VaultLocationChangeSheet` handles proving ownership itself.
struct VaultLocationSettingsPane: View {
    @EnvironmentObject private var vaultSession: VaultSession
    @AppStorage("vaultLocation") private var vaultLocationRawValue: String = VaultLocationOption.local.rawValue
    @State private var pendingTargetLocation: VaultLocationOption?

    private var currentLocation: VaultLocationOption {
        VaultLocationOption(rawValue: vaultLocationRawValue) ?? .local
    }

    var body: some View {
        Group {
            Section {
                LabeledContent("Current Location") {
                    Text(currentLocation.title)
                }
                Text(verbatim: vaultSession.primaryVaultPathDisplay)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                if vaultSession.iCloudPrimaryFallbackActive {
                    Label(
                        "MyPass could not reach the configured iCloud Drive folder and is using the local copy on this Mac instead.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                    Button("Re-grant iCloud Drive Access…") {
                        pendingTargetLocation = .iCloudDrive
                    }
                }
                if vaultSession.localFileFallbackActive {
                    Label(
                        "MyPass could not reach your previously opened vault file and is using a local copy instead.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                }
                Button(currentLocation == .local ? "Move to iCloud Drive…" : "Move to Local…") {
                    pendingTargetLocation = currentLocation == .local ? .iCloudDrive : .local
                }
                // Attached to this one Button, not to the root `Group`: inside the Vault pane's
                // List-backed grouped Form, a modifier on a `Group` is distributed to every child
                // and Section content flattens into rows, so the sheet could be attached many
                // times to the same `pendingTargetLocation` binding. The Button is a single,
                // unconditional row (only its title changes), so the sheet has exactly one host.
                .sheet(item: $pendingTargetLocation) { target in
                    VaultLocationChangeSheet(targetLocation: target)
                }
                SettingsHelperText(text: "Local keeps the vault only on this Mac. iCloud Drive keeps it in a folder that syncs between your Macs (and, in the future, other devices signed into the same iCloud account).")
            } header: {
                Text("Location")
                    .font(.system(size: 13, weight: .semibold))
            }
        }
    }
}
