import AppKit
import SwiftUI

/// Shared "update available" row for both menu bar panels. It reads `bannerRelease`, so it
/// disappears as soon as the user dismisses the banner with Later.
struct MenuBarUpdateRow: View {
    @EnvironmentObject private var updateChecker: AppUpdateChecker

    var body: some View {
        if let title = updateChecker.menuItemTitle, let release = updateChecker.bannerRelease {
            Button {
                MenuBarPanelDismisser.dismiss()
                NSWorkspace.shared.open(release.url)
            } label: {
                HStack {
                    Text(title)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Divider()
        }
    }
}
