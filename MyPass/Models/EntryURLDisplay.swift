import Foundation

/// Domain-only display text for a stored URL (e.g. the browse Website row). Delegates
/// to `ExtensionEntryMatcher.registrableDomain`, which documents the naive
/// last-two-DNS-labels heuristic this app uses (no Public Suffix List).
enum EntryURLDisplay {
    static func domain(from urlString: String) -> String? {
        ExtensionEntryMatcher.registrableDomain(from: urlString)
    }
}
