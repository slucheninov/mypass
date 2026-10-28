import SwiftUI
import AppKit

/// Non-modal notice shown in the window's titlebar accessory (see `updateBannerAccessory()`)
/// when a newer release exists. It renders nothing otherwise. "View release" opens the
/// release page in the browser; "Later" hides the banner for this release (see
/// `AppUpdateChecker.dismissBanner()`).
struct UpdateBannerView: View {
    @EnvironmentObject var updateChecker: AppUpdateChecker
    // The accessory is hosted outside the window's SwiftUI tree, so `quitFreezeOverlay()` does
    // not reach it; it has to disable itself while a quit is flushing the vault.
    @EnvironmentObject var vaultSession: VaultSession

    var body: some View {
        if let release = updateChecker.bannerRelease, let text = updateChecker.bannerText {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundStyle(Color.accentColor)
                    // The message truncates before the buttons shrink, so both stay clickable
                    // at the narrowest window width.
                    // Already localized by `AppUpdateChecker.bannerText`.
                    Text(verbatim: text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 8)
                    Button("View release") { NSWorkspace.shared.open(release.url) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .fixedSize()
                    Button("Later") { updateChecker.dismissBanner() }
                        .controlSize(.small)
                        .fixedSize()
                }
                .padding(.horizontal, UIShellMetrics.bannerHorizontalPadding)
                .padding(.vertical, UIShellMetrics.bannerVerticalPadding)
                .background(Color.accentColor.opacity(0.12))
                Divider()
            }
            .disabled(vaultSession.isQuitInProgress)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(text)
        }
    }
}
