import SwiftUI
import AppKit

/// Non-modal notice shown above the vault content when a newer release exists. It renders
/// nothing otherwise. "View release" opens the release page in the browser; "Later" hides
/// the banner for this release (see `AppUpdateChecker.dismissBanner()`).
struct UpdateBannerView: View {
    @EnvironmentObject var updateChecker: AppUpdateChecker

    var body: some View {
        if let release = updateChecker.bannerRelease, let text = updateChecker.bannerText {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundStyle(Color.accentColor)
                    Text(text)
                    Spacer()
                    Button("View release") { NSWorkspace.shared.open(release.url) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    Button("Later") { updateChecker.dismissBanner() }
                        .controlSize(.small)
                }
                .padding(.horizontal, UIShellMetrics.bannerHorizontalPadding)
                .padding(.vertical, UIShellMetrics.bannerVerticalPadding)
                .background(Color.accentColor.opacity(0.12))
                Divider()
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(text)
        }
    }
}
