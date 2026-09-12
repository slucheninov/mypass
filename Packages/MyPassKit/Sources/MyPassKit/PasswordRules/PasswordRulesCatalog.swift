import Foundation

/// Dependency-free index over the Password Rules catalog's raw shape,
/// separated out from `PasswordRulesCatalog` purely so
/// `PasswordRulesCatalogTests` can construct one directly with a small
/// synthetic fixture (via `@testable import`) to test the
/// registrable-domain-walk and `exact-domain-match-only` boundary
/// conditions precisely, without needing the real 436-entry vendored
/// catalog to happen to contain a fixture shaped the right way.
final class PasswordRulesIndex {
    struct Entry {
        let passwordRules: String
        let exactDomainMatchOnly: Bool

        init(passwordRules: String, exactDomainMatchOnly: Bool = false) {
            self.passwordRules = passwordRules
            self.exactDomainMatchOnly = exactDomainMatchOnly
        }
    }

    private let entries: [String: Entry] // key: lowercased domain
    private let lock = NSLock()
    private var parseCache: [String: PasswordRules?] = [:]

    init(entries: [String: Entry]) {
        var lowercased: [String: Entry] = [:]
        lowercased.reserveCapacity(entries.count)
        for (domain, entry) in entries {
            lowercased[domain.lowercased()] = entry
        }
        self.entries = lowercased
    }

    /// Nil when no rule applies. Walks upward from `host` -- the full host,
    /// then each parent label, down to (and including) its registrable
    /// domain computed via `PublicSuffixList.registrableDomain(of:)`, the
    /// same type `ExtensionEntryMatcher` already depends on for domain
    /// reduction -- and never above it, so a rule can never apply to an
    /// unrelated site that happens to share a public suffix. A rule keyed
    /// at any level matches every subdomain underneath it down to (and
    /// including) the exact host, UNLESS that entry's
    /// `exactDomainMatchOnly` is set, in which case it matches only the
    /// exact host it was looked up with, never a longer subdomain
    /// discovered by walking upward past it.
    func rules(forHost host: String) -> PasswordRules? {
        let normalizedHost = host.lowercased()
        guard !normalizedHost.isEmpty else { return nil }

        let ceiling = PublicSuffixList.registrableDomain(of: normalizedHost) ?? normalizedHost
        var candidate = normalizedHost

        while true {
            let isExactHost = (candidate == normalizedHost)
            if let entry = entries[candidate], isExactHost || !entry.exactDomainMatchOnly {
                if let parsed = parsedRules(forDomain: candidate, raw: entry.passwordRules) {
                    return parsed
                }
            }

            if candidate == ceiling {
                return nil
            }
            guard let dotIndex = candidate.firstIndex(of: ".") else {
                return nil
            }
            candidate = String(candidate[candidate.index(after: dotIndex)...])
        }
    }

    /// A rule string that fails to parse behaves as "this domain has no
    /// rule" (Decision 2/3 of the spec) -- cached the same as a successful
    /// parse, so a bad row in the catalog only ever costs one parse
    /// attempt per domain, not one per lookup.
    private func parsedRules(forDomain domain: String, raw: String) -> PasswordRules? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = parseCache[domain] {
            return cached
        }
        let parsed: PasswordRules?
        switch PasswordRulesParser.parse(raw) {
        case .success(let rules): parsed = rules
        case .failure: parsed = nil
        }
        parseCache[domain] = .some(parsed)
        return parsed
    }
}

/// Rule lookup keyed by host, over the vendored `password-rules.json`
/// (Task 1). See `PasswordRulesIndex.rules(forHost:)` for the actual
/// registrable-domain walk; this type only owns loading and decoding the
/// bundled resource, lazily, once, on first use.
public enum PasswordRulesCatalog {
    private struct RawJSONEntry: Decodable {
        let passwordRules: String
        let exactDomainMatchOnly: Bool

        enum CodingKeys: String, CodingKey {
            case passwordRules = "password-rules"
            case exactDomainMatchOnly = "exact-domain-match-only"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            passwordRules = try container.decode(String.self, forKey: .passwordRules)
            exactDomainMatchOnly = try container.decodeIfPresent(Bool.self, forKey: .exactDomainMatchOnly) ?? false
        }
    }

    private static let index: PasswordRulesIndex = loadIndex()

    private static func loadIndex() -> PasswordRulesIndex {
        // Fail closed rather than falling back to an empty catalog,
        // matching PublicSuffixList.swift's own justification for
        // fatalError over a silent empty fallback: an empty catalog
        // wouldn't crash anything downstream (PasswordGenerator already
        // treats `rules: nil` as "use plain toggles"), but it would
        // silently and permanently disable this entire feature for every
        // site, indistinguishable from "this site simply has no known
        // rule" -- exactly the failure mode a missing/corrupt bundled
        // resource should never be allowed to hide as normal behavior.
        // (The lookup itself already traps this way inside
        // `PasswordRulesResource`, below.)
        let data = PasswordRulesResource.rawJSON
        guard let decoded = try? JSONDecoder().decode([String: RawJSONEntry].self, from: data) else {
            fatalError("PasswordRulesCatalog: password-rules.json failed to decode as [String: RawJSONEntry]")
        }
        let entries = decoded.mapValues {
            PasswordRulesIndex.Entry(passwordRules: $0.passwordRules, exactDomainMatchOnly: $0.exactDomainMatchOnly)
        }
        return PasswordRulesIndex(entries: entries)
    }

    /// Nil when no rule applies -- the caller falls back to plain generator
    /// options.
    public static func rules(forHost host: String) -> PasswordRules? {
        index.rules(forHost: host)
    }
}
