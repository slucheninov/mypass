import SwiftUI

/// Reachable before authentication as well as after — unlike the old Sync
/// pane's iCloud button, "Change Location…" is never disabled on lock state;
/// `VaultLocationChangeSheet` handles proving ownership itself.
struct VaultLocationSettingsPane: View {
    @EnvironmentObject private var vaultSession: VaultSession
    @AppStorage("vaultLocation") private var vaultLocationRawValue: String = VaultLocationOption.local.rawValue
    @State private var showingChangeSheet = false
    @State private var pendingTargetLocation: VaultLocationOption?

    private var currentLocation: VaultLocationOption {
        VaultLocationOption(rawValue: vaultLocationRawValue) ?? .local
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Current Location", value: currentLocation.rawValue)
                if vaultSession.iCloudPrimaryFallbackActive {
                    Label(
                        "MyPass could not reach the configured iCloud Drive folder and is using the local copy on this Mac instead.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                    Button("Re-grant iCloud Drive Access…") {
                        pendingTargetLocation = .iCloudDrive
                        showingChangeSheet = true
                    }
                }
                Button(currentLocation == .local ? "Switch to iCloud Drive…" : "Switch to Local…") {
                    pendingTargetLocation = currentLocation == .local ? .iCloudDrive : .local
                    showingChangeSheet = true
                }
                SettingsHelperText(text: "Local keeps the vault only on this Mac. iCloud Drive keeps it in a folder that syncs between your Macs (and, in the future, other devices signed into the same iCloud account).")
            } header: {
                Text("Vault Location")
                    .font(.system(size: 13, weight: .semibold))
            }
        }
        .formStyle(.grouped)
        .padding()
        .sheet(isPresented: $showingChangeSheet) {
            if let pendingTargetLocation {
                VaultLocationChangeSheet(targetLocation: pendingTargetLocation)
            }
        }
    }
}
