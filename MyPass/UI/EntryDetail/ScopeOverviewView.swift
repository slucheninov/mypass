import SwiftUI

/// A scope summary, shown only when the list has no selected entry. Keeping this
/// view free of vault/session objects also permits previews with synthetic data.
struct ScopeOverviewView: View {
    let title: String
    let symbolName: String
    var emoji: String? = nil
    let accentColor: Color
    let itemCount: Int
    var isSearching = false
    var searchesWholeVault = false

    private var countText: String {
        if isSearching { return "\(itemCount) matching \(itemCount == 1 ? "item" : "items")" }
        return "\(itemCount) \(itemCount == 1 ? "item" : "items")"
    }

    var body: some View {
        VStack(spacing: 22) {
            ZStack {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(accentColor.opacity(0.10))
                if let emoji, !emoji.isEmpty {
                    Text(emoji).font(.system(size: 64))
                } else {
                    Image(systemName: symbolName)
                        .font(.system(size: 60, weight: .medium))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(accentColor)
                }
            }
            .frame(width: 120, height: 120)
            .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 27, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.primary)
                Text(countText)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                if isSearching && searchesWholeVault {
                    Text("Search results across the vault")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(UIShellMetrics.detailColumnBackground)
        .accessibilityElement(children: .combine)
    }
}
