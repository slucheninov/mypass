import SwiftUI

/// About pane: app identity, version, release notes and the update controls that used to live
/// in General. The controls moved here unchanged (same `updateCheckEnabled` key, same
/// `AppUpdateChecker` calls) so the stored preference and the scheduler keep working as before.
struct AboutSettingsPane: View {
    @AppStorage("updateCheckEnabled") private var updateCheckEnabled = true
    @EnvironmentObject private var updateChecker: AppUpdateChecker

    /// The checker's parsed version is preferred; the bundle string is the fallback for a build
    /// whose version the checker could not parse (the checker then reports `currentVersion == nil`).
    private var versionText: String? {
        if let version = updateChecker.currentVersion?.description { return version }
        return Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 6) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 80, height: 80)
                    Text("MyPass")
                        .font(.title2.weight(.semibold))
                    if let versionText {
                        Text("Version \(versionText)")
                            .foregroundStyle(.secondary)
                    }
                    if let versionText, let notesURL = ReleaseNotesLink.url(forVersion: versionText) {
                        Link("Release Notes", destination: notesURL)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }

            Section {
                HStack {
                    Button("Check for Updates") {
                        Task { await updateChecker.check(manual: true) }
                    }
                    .disabled(updateChecker.status == .checking)
                    UpdateStatusView()
                }
                Toggle("Check for updates automatically", isOn: $updateCheckEnabled)
                    .onChange(of: updateCheckEnabled) { _, _ in
                        updateChecker.enabledDidChange()
                    }
                SettingsHelperText(text: "When on, MyPass contacts api.github.com a few seconds after launch and then once a day to read the tag of the latest release. Nothing else is sent: no account, vault or device information.")
                LabeledContent("Last checked") {
                    if let lastRun = updateChecker.lastRun {
                        // Already localized by the formatter, so it is shown verbatim.
                        Text(verbatim: RelativeDateTimeFormatter().localizedString(for: lastRun, relativeTo: Date()))
                    } else {
                        Text("Never")
                    }
                }
            } header: {
                Text("Updates")
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
