import SwiftUI

/// While a quit is flushing the vault to disk, `VaultSession` refuses every change
/// (`mutate` returns `false`). This makes that visible: the content below is disabled and a
/// small "saving" card covers it, so input is not typed into a field that silently discards it.
/// Cancelling the quit clears `isQuitInProgress` and the overlay disappears; on a real quit the
/// window simply goes away with the process. Apply it BEFORE (inside) the `environmentObject`
/// injection of the `VaultSession`: an environment object only reaches views below the
/// `.environmentObject` call, and this modifier reads it.
private struct QuitFreezeOverlay: ViewModifier {
    @EnvironmentObject private var vaultSession: VaultSession

    func body(content: Content) -> some View {
        content
            .disabled(vaultSession.isQuitInProgress)
            .overlay {
                if vaultSession.isQuitInProgress {
                    ZStack {
                        // Swallows clicks on the (already disabled) content below.
                        Color.black.opacity(0.12)
                        VStack(spacing: 8) {
                            ProgressView()
                            Text("Saving your vault before quitting…")
                                .font(.callout)
                                .multilineTextAlignment(.center)
                        }
                        .padding(16)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Saving your vault before quitting")
                    }
                }
            }
    }
}

extension View {
    /// Disables the view and shows a "saving" indicator while the app is quitting.
    func quitFreezeOverlay() -> some View {
        modifier(QuitFreezeOverlay())
    }
}
