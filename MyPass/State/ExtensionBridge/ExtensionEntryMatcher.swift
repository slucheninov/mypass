import Foundation
import MyPassKit

enum ExtensionEntryMatcher {
    /// Public-suffix-list (PSL) lookup via `MyPassKit.PublicSuffixList`,
    /// correctly handling multi-label suffixes such as "co.uk", "com.ua", and
    /// private-section rules like "github.io" — "example.co.uk" resolves to
    /// "example.co.uk", not "co.uk".
    ///
    /// A host that is itself a public suffix (e.g. "co.uk", "github.io") has
    /// no registrable domain to reduce to, so — consistent with the
    /// single-label and IP-literal branches below — it is compared whole.
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

        return PublicSuffixList.registrableDomain(of: resolvedHost) ?? resolvedHost
    }

    /// Whole-host string comparison, including port, case-insensitive — no PSL
    /// reduction at all. IP literals have nothing to reduce to, so this mode's
    /// behaviour for an IP-literal entry coincides with `registrableDomain`'s
    /// (Decision 9).
    private static func hostAndPort(from urlString: String) -> String? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var url = URL(string: trimmed)
        if url?.host == nil {
            url = URL(string: "https://" + trimmed)
        }
        guard let host = url?.host?.lowercased(), !host.isEmpty else { return nil }
        guard let port = url?.port else { return host }
        return "\(host):\(port)"
    }

    /// The scheme's own registered default port, so "https://x" and
    /// "https://x:443" normalise identically for starts-with/exact matching.
    private static let defaultPortsByScheme: [String: Int] = ["http": 80, "https": 443]

    /// Lowercases scheme and host, drops the port only when it equals the
    /// scheme's own default, and leaves path and query exactly as given —
    /// including case, since a case-sensitive API path (`/API/v2/Login` vs
    /// `/api/v2/login`) is a real, common shape. Used by both starts-with and
    /// exact matching (Decision 9).
    private static func normalizedURL(from urlString: String) -> String? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var url = URL(string: trimmed)
        if url?.scheme == nil || url?.host == nil {
            url = URL(string: "https://" + trimmed)
        }
        guard let resolved = url,
              let scheme = resolved.scheme?.lowercased(),
              let host = resolved.host?.lowercased(), !host.isEmpty else {
            return nil
        }
        var result = "\(scheme)://\(host)"
        if let port = resolved.port, defaultPortsByScheme[scheme] != port {
            result += ":\(port)"
        }
        result += resolved.path
        if let query = resolved.query {
            result += "?\(query)"
        }
        return result
    }

    /// Never-mode exclusion is enforced HERE, before a `credentialList` (or its
    /// equivalent for the inline panel and the save-banner check) is ever
    /// assembled by `ExtensionBridgeService` — never left to the extension to
    /// filter client-side (Decision 9). Every bridge request that resolves
    /// entries by URL goes through this one function.
    static func matchingEntries(in group: KdbxGroup, forURL urlString: String) -> [KdbxEntry] {
        EntrySearch.allEntries(in: group).filter { matches(entry: $0, forURL: urlString) }
    }

    private static func matches(entry: KdbxEntry, forURL urlString: String) -> Bool {
        switch entry.uriMatchMode {
        case .never:
            return false
        case .registrableDomain:
            guard let targetDomain = registrableDomain(from: urlString) else { return false }
            return entry.urls.contains { registrableDomain(from: $0) == targetDomain }
        case .host:
            guard let targetHost = hostAndPort(from: urlString) else { return false }
            return entry.urls.contains { hostAndPort(from: $0) == targetHost }
        case .exact:
            guard let targetNormalized = normalizedURL(from: urlString) else { return false }
            return entry.urls.contains { normalizedURL(from: $0) == targetNormalized }
        case .startsWith:
            guard let targetNormalized = normalizedURL(from: urlString) else { return false }
            return entry.urls.contains { entryURL in
                guard let entryNormalized = normalizedURL(from: entryURL) else { return false }
                return targetNormalized.hasPrefix(entryNormalized)
            }
        }
    }
}
