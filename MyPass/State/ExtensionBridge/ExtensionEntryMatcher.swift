import Foundation
import MyPassKit

enum ExtensionEntryMatcher {
    /// Naive "last two DNS labels" heuristic — NOT a real public-suffix-list
    /// lookup. It misidentifies multi-part suffixes such as "example.co.uk"
    /// (collapses to "co.uk" instead of "example.co.uk"). Accepted as a known
    /// limitation for the Phase 4 MVP; revisit with a PSL library before
    /// widening scope beyond simple .com/.org/.net-style domains.
    static func registrableDomain(from urlString: String) -> String? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var host = URL(string: trimmed)?.host
        if host == nil {
            host = URL(string: "https://" + trimmed)?.host
        }
        guard let resolvedHost = host?.lowercased(), !resolvedHost.isEmpty else { return nil }

        let labels = resolvedHost.split(separator: ".")
        guard labels.count >= 2 else { return resolvedHost }
        return labels.suffix(2).joined(separator: ".")
    }

    static func matchingEntries(in group: KdbxGroup, forURL urlString: String) -> [KdbxEntry] {
        guard let targetDomain = registrableDomain(from: urlString) else { return [] }
        return EntrySearch.allEntries(in: group).filter { entry in
            guard !entry.url.isEmpty, let entryDomain = registrableDomain(from: entry.url) else {
                return false
            }
            return entryDomain == targetDomain
        }
    }
}
