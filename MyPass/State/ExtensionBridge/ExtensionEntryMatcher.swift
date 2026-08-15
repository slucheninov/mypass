import Foundation
import MyPassKit

enum ExtensionEntryMatcher {
    /// Naive "last two DNS labels" heuristic — NOT a real public-suffix-list
    /// lookup. It misidentifies multi-part suffixes such as "example.co.uk"
    /// (collapses to "co.uk" instead of "example.co.uk"). Accepted as a known
    /// limitation for the Phase 4 MVP; revisit with a PSL library before
    /// widening scope beyond simple .com/.org/.net-style domains.
    ///
    /// IP literals have no registrable domain and are never reduced to their
    /// last two labels — they are compared whole. This matters for IPv4:
    /// without it, "127.0.0.1", "192.168.0.1", and "10.0.0.1" would all
    /// collapse to "0.1" and be treated as the same site, offering one
    /// host's saved credentials to another. IPv6 literals ("::1", "[::1]")
    /// are likewise compared whole.
    static func registrableDomain(from urlString: String) -> String? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var host = URL(string: trimmed)?.host
        if host == nil {
            host = URL(string: "https://" + trimmed)?.host
        }
        guard var resolvedHost = host?.lowercased(), !resolvedHost.isEmpty else { return nil }

        // A trailing DNS-root dot ("example.com.", "127.0.0.1.") names the
        // same host as the form without it. The label-rebuild below already
        // drops it for DNS names (split omits the empty trailing component),
        // so strip it here too — otherwise the IP paths, which return
        // `resolvedHost` verbatim, would treat "127.0.0.1." and "127.0.0.1"
        // as different hosts.
        if resolvedHost.hasSuffix(".") {
            resolvedHost = String(resolvedHost.dropLast())
        }

        // IPv6 literal: a DNS name can never contain ":", so any host that
        // does is an IPv6 literal. Strip surrounding brackets if present so
        // "::1" and "[::1]" compare equal, then return it whole. On this
        // platform Foundation's `URL.host` already strips brackets before we
        // ever see the string, so this branch is currently unreachable — it
        // is kept defensively in case a platform or URL implementation ever
        // stops doing that.
        if resolvedHost.contains(":") {
            if resolvedHost.hasPrefix("[") && resolvedHost.hasSuffix("]") {
                resolvedHost = String(resolvedHost.dropFirst().dropLast())
            }
            return resolvedHost
        }

        let labels = resolvedHost.split(separator: ".")
        guard labels.count >= 2 else { return resolvedHost }

        // IPv4 literal: every label is entirely (ASCII) numeric. A real DNS
        // name's final label is never all-digits, so this is a safe test
        // without validating octet ranges — "192.168.1" and "1.2.3.4.5"
        // returning themselves unchanged is correct, not a bug.
        let isIPv4Literal = labels.allSatisfy { label in
            !label.isEmpty && label.allSatisfy { $0.isASCII && $0.isNumber }
        }
        if isIPv4Literal { return resolvedHost }

        return labels.suffix(2).joined(separator: ".")
    }

    static func matchingEntries(in group: KdbxGroup, forURL urlString: String) -> [KdbxEntry] {
        guard let targetDomain = registrableDomain(from: urlString) else { return [] }
        return EntrySearch.allEntries(in: group).filter { entry in
            entry.urls.contains { registrableDomain(from: $0) == targetDomain }
        }
    }
}
