import SwiftUI

/// Renders `AppUpdateChecker.status`. It lives in its own view so every place that shows the
/// update state (the About pane today) renders the same idle / checking / up to date /
/// available / failed states from one switch instead of copying it.
struct UpdateStatusView: View {
    @EnvironmentObject private var updateChecker: AppUpdateChecker

    var body: some View {
        switch updateChecker.status {
        case .idle:
            EmptyView()
        case .checking:
            ProgressView().controlSize(.small)
            Text("Checking…").foregroundStyle(.secondary)
        case .upToDate:
            Text("You have the latest version").foregroundStyle(.secondary)
        case .available(let release):
            Text("MyPass \(release.version.description) is available")
            Button("View release") { NSWorkspace.shared.open(release.url) }
                .buttonStyle(.link)
        case .failed(let message):
            Text(message).foregroundStyle(.red)
        }
    }
}
