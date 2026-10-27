import SwiftUI

/// A scope summary, shown only when the list has no selected entry. Keeping this
/// view free of vault/session objects also permits previews with synthetic data.
struct ScopeOverviewView: View {
    /// Already-final text: a vault group name (verbatim), or a smart category title the caller
    /// resolved with `String(localized:)`.
    let title: String
    let symbolName: String
    var emoji: String? = nil
    let accentColor: Color
    let itemCount: Int
    var isSearching = false
    var searchesWholeVault = false

    /// Four whole sentences instead of an interpolated "item"/"items" word, so the singular is
    /// correct in English today and a translator can inflect each sentence on its own. (They can
    /// later be folded into one plural-variation entry per sentence in the string catalog.)
    private var countText: String {
        switch (isSearching, itemCount) {
        case (true, 1):
            return String(localized: "1 matching item", comment: "Scope overview: result count while searching, singular")
        case (true, _):
            return String(localized: "\(itemCount) matching items", comment: "Scope overview: result count while searching; the argument is the number of results")
        case (false, 1):
            return String(localized: "1 item", comment: "Scope overview: number of entries, singular")
        case (false, _):
            return String(localized: "\(itemCount) items", comment: "Scope overview: number of entries; the argument is the count")
        }
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
                Text(verbatim: title)
                    .font(.system(size: 27, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.primary)
                Text(verbatim: countText)
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
