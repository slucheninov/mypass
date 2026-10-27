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
    /// Internationalised names compare in ACE (punycode) form. Foundation's
    /// `URL.host` is ACE ("xn--...") for a URL written with a literal Unicode
    /// host, but Unicode for a percent-encoded one
    /// (`https://%E5%85%AC%E5%8F%B8.hk/`), so the resolved host is canonicalised
    /// once with `PublicSuffixList.canonicalHost(_:)` before anything else.
    /// `PublicSuffixList` canonicalises its Unicode-form rules (e.g. `公司.hk`)
    /// the same way, so "公司.hk", its percent-encoded form and "xn--55qx5d.hk"
    /// are one site — including when the host is itself a public suffix or
    /// has no PSL entry and is compared whole — and two sites beneath that
    /// suffix stay distinct. A non-ASCII host that cannot be converted has no
    /// comparable identity: it yields nil and matches nothing. Only
    /// registrable-domain mode canonicalises; host, exact and starts-with
    /// matching still compare `URL.host` as Foundation spells it, and the
    /// port/origin rules are unchanged. The mapping is Foundation's, verified
    /// on macOS 27 only; the macOS 14 runtime is untested. If the PSL registry
    /// is unavailable (see `PublicSuffixList`), the lookup returns nil and the
    /// canonical host is compared whole, which can only narrow a match.
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

        // Canonicalise once, up front, so every return below (bare public
        // suffix, single label, IP literal, PSL fallback) compares one spelling.
        // Pure-ASCII hosts are deliberately left to the existing handling.
        if !resolvedHost.allSatisfy(\.isASCII) {
            guard let canonical = PublicSuffixList.canonicalHost(resolvedHost) else { return nil }
            resolvedHost = canonical
        }

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

    /// The URL's bare host, lowercased, with no port and no PSL reduction at
    /// all — the shape `PasswordRulesCatalog.rules(forHost:)` expects, since
    /// that catalog does its own upward walk from the full host to the
    /// registrable-domain ceiling. Reducing a host before handing it over
    /// throws away every catalog key below that ceiling
    /// (`account.samsung.com`, `key.harvard.edu`, `id.nfpa.org` and
    /// `app.digio.in` all carry rules their apex domains do not), which is
    /// exactly what `EntryEditView`'s generator sheet used to do.
    ///
    /// Accepts a bare host or a scheme-less string too ("example.com",
    /// "example.com/login"), the same tolerance `registrableDomain(from:)`
    /// above already extends to a user-typed entry URL.
    static func host(from urlString: String) -> String? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var url = URL(string: trimmed)
        if url?.host == nil {
            url = URL(string: "https://" + trimmed)
        }
        guard let host = url?.host?.lowercased(), !host.isEmpty else { return nil }
        return host
    }

    /// Whole-host string comparison, including port, case-insensitive — no PSL
    /// reduction at all. IP literals have nothing to reduce to, so this mode's
    /// behaviour for an IP-literal entry coincides with `registrableDomain`'s
    /// (Decision 9).
    private static func hostAndPort(from urlString: String) -> String? {
        guard let host = host(from: urlString) else { return nil }
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        var url = URL(string: trimmed)
        if url?.host == nil {
            url = URL(string: "https://" + trimmed)
        }
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
    /// exact matching (Decision 9). Split into `origin` (scheme, host, non-
    /// default port) and `rest` (path plus `?query`) so starts-with matching
    /// can require the origin to match exactly and confine its prefix
    /// comparison to `rest` alone — see `matches(entry:forURL:)` below.
    private static func normalizedOriginAndRest(from urlString: String) -> (origin: String, rest: String)? {
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
        var origin = "\(scheme)://\(host)"
        if let port = resolved.port, defaultPortsByScheme[scheme] != port {
            origin += ":\(port)"
        }
        var rest = resolved.path
        if let query = resolved.query {
            rest += "?\(query)"
        }
        return (origin, rest)
    }

    /// The full normalised string, `origin` and `rest` concatenated. Used by
    /// exact matching, which compares the whole thing.
    private static func normalizedURL(from urlString: String) -> String? {
        guard let parts = normalizedOriginAndRest(from: urlString) else { return nil }
        return parts.origin + parts.rest
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
            // The prefix rule is deliberately scoped to path-and-query only, never to
            // the origin. Two costs were on the table and only one was ever accepted:
            //
            // - Path-suffix overmatch (accepted, Decision 9): a stored prefix ending
            //   mid-path, e.g. ".../app", also matches a longer segment with the same
            //   start, e.g. ".../app-legacy". That is a scoping choice about one site's
            //   own path layout, made by the user who saved the entry for that site.
            // - Cross-origin overmatch (NOT accepted, and prevented here): comparing
            //   the full normalised string as one blob would let a stored
            //   "https://example.com" (empty path) match "https://example.com.attacker.com"
            //   purely because the origin's characters happen to be a string prefix of
            //   the lookalike's origin. That is not a scoping choice the user made about
            //   their own site — it is a way for an unrelated, attacker-controlled
            //   domain to receive a credential the user pointed at the real one. So the
            //   origin (scheme, host, non-default port) must match exactly before the
            //   prefix rule is ever applied, and only `rest` (path + query) is compared
            //   with `hasPrefix`.
            guard let target = normalizedOriginAndRest(from: urlString) else { return false }
            return entry.urls.contains { entryURL in
                guard let entryParts = normalizedOriginAndRest(from: entryURL) else { return false }
                guard entryParts.origin == target.origin else { return false }
                return target.rest.hasPrefix(entryParts.rest)
            }
        }
    }
}
