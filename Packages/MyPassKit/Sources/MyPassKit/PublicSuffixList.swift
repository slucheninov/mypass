import Foundation

/// Public Suffix List (PSL) lookup, per the algorithm at
/// https://publicsuffix.org/list/. Rules are parsed once from the bundled
/// `public_suffix_list.dat` resource (ICANN + PRIVATE sections) into three
/// rule sets: exact, wildcard (`*.`), and exception (`!`).
///
/// Every comparison happens in one canonical form: lowercase ASCII-compatible
/// encoding (ACE, "xn--..." punycode labels). The data file spells IDN rules
/// in Unicode (e.g. `公司.hk`) while hosts reach this type either way — a
/// browser's `URL.hostname` is ACE, but Foundation's `URL.host` is ACE only
/// for a URL written with a literal Unicode host (`https://公司.hk/`): a
/// percent-encoded one (`https://%E5%85%AC%E5%8F%B8.hk/`) comes back as
/// Unicode, and a bare user-typed host may be either. Both sides are therefore
/// converted with `canonicalHost(_:)` (Foundation's IDNA mapping, via
/// `URLComponents`) so
/// "例え.公司.hk" and "xn--r8jz45g.xn--55qx5d.hk" resolve to the same suffix
/// and the same registrable domain, and returned values are always ACE.
/// Without this, a Unicode-form rule never matched an ACE host, the host fell
/// through to the implicit `*` rule (suffix "hk"), and two unrelated
/// "*.xn--55qx5d.hk" sites collapsed into one registrable domain.
///
/// A non-ASCII host that cannot be converted (malformed, or carrying URL
/// delimiters such as "/", "@", ":") is rejected rather than guessed at:
/// `publicSuffix(of:)` and `registrableDomain(of:)` return nil. Pure-ASCII
/// hosts are not re-validated and keep their historical behaviour.
///
/// The IDNA mapping is Foundation's, so its exact output is platform
/// dependent. This was developed and tested on macOS 27 only; the macOS 14
/// minimum deployment target has not been exercised. That is why a rule the
/// running OS cannot convert makes the whole registry unavailable (every
/// lookup returns nil, see `rules`) instead of crashing or being skipped.
public enum PublicSuffixList {
    struct Rules {
        let exact: Set<String>
        let wildcard: Set<String>
        let exception: Set<String>

        /// Parses PSL data (the `public_suffix_list.dat` line format) into
        /// ACE-canonical rule sets. Returns nil when any rule cannot be
        /// converted: silently dropping an IDN rule would widen matching
        /// (its names would fall back to a broader suffix), so the caller
        /// must fail closed instead.
        init?(parsing contents: String) {
            var exact = Set<String>()
            var wildcard = Set<String>()
            var exception = Set<String>()

            for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: true) {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty, !line.hasPrefix("//") else { continue }
                guard let token = line.split(whereSeparator: \.isWhitespace).first else { continue }
                let rule = String(token)

                if rule.hasPrefix("!") {
                    guard let canonical = PublicSuffixList.asciiCompatibleName(String(rule.dropFirst())) else { return nil }
                    exception.insert(canonical)
                } else if rule.hasPrefix("*.") {
                    guard let canonical = PublicSuffixList.asciiCompatibleName(String(rule.dropFirst(2))) else { return nil }
                    wildcard.insert(canonical)
                } else {
                    guard let canonical = PublicSuffixList.asciiCompatibleName(rule) else { return nil }
                    exact.insert(canonical)
                }
            }

            self.exact = exact
            self.wildcard = wildcard
            self.exception = exception
        }
    }

    /// nil when the bundled data holds a rule this OS's IDNA mapping cannot
    /// convert. Every public lookup then returns nil — the callers already
    /// treat nil as "no registrable domain" and fall back to comparing the
    /// whole host, which can only narrow a match, never widen it.
    private static let rules: Rules? = loadRules()

    /// The bundled `public_suffix_list.dat` text. `Bundle.module` resolves to
    /// this package's own bundle only from inside the module, so tests that
    /// check the real data go through here.
    static func bundledRuleData() -> String {
        guard let url = Bundle.module.url(forResource: "public_suffix_list", withExtension: "dat"),
              let contents = try? String(contentsOf: url, encoding: .utf8) else {
            fatalError("PublicSuffixList: missing or unreadable public_suffix_list.dat resource")
        }
        return contents
    }

    private static func loadRules() -> Rules? {
        // Fail closed rather than falling back to an empty rule set: an empty
        // rule set would make every host fall through to the implicit `*`
        // rule and silently reintroduce the "co.uk over-matches co.uk"
        // security bug this type exists to fix. A missing resource is a
        // packaging defect that no runtime can recover from, so it still
        // traps in `bundledRuleData()`. A rule that cannot be converted to
        // ACE depends on the OS's IDNA tables, so it must not crash the app:
        // `Rules(parsing:)` returns nil for it (dropping just that rule would
        // widen matching) and every lookup then returns nil.
        Rules(parsing: bundledRuleData())
    }

    /// Lowercased, ASCII-compatible (punycode) form of a dotted DNS name, or
    /// nil when it cannot be converted safely. Pure-ASCII input is returned
    /// lowercased and otherwise untouched (including any "xn--" labels, which
    /// are compared as given). Non-ASCII input goes through Foundation's IDNA
    /// mapping (case folding, NFC/NFD normalisation, ideographic full stop
    /// "。" as a label separator, non-transitional "ß") by assigning it as a
    /// `URLComponents.host`; that setter percent-encodes anything that is not
    /// a legal host character, so a "%" in the result means the input carried
    /// a URL delimiter (path, userinfo, port, query, whitespace) and is
    /// refused rather than reinterpreted. Empty labels are refused too.
    static func asciiCompatibleName(_ name: String) -> String? {
        let lowered = name.lowercased()
        if lowered.allSatisfy(\.isASCII) { return lowered }

        var components = URLComponents()
        components.host = lowered
        guard let encoded = components.encodedHost,
              !encoded.isEmpty,
              encoded.allSatisfy(\.isASCII),
              !encoded.contains("%") else {
            return nil
        }
        let ace = encoded.lowercased()
        // An empty label ("a..b", a leading dot) is not a DNS name. A single
        // trailing root dot is allowed here and stripped by `canonicalHost`.
        let body = ace.hasSuffix(".") ? String(ace.dropLast()) : ace
        guard !body.isEmpty, !body.split(separator: ".", omittingEmptySubsequences: false).contains(where: \.isEmpty) else {
            return nil
        }
        return ace
    }

    /// Canonical form of a host for comparison: lowercase ACE with one
    /// trailing root dot removed, so "公司.hk", "XN--55QX5D.HK." and
    /// "xn--55qx5d.hk" all yield "xn--55qx5d.hk". Independent of the rule
    /// data. Nil for an empty host, or a non-ASCII host that cannot be
    /// converted (malformed, or carrying a URL delimiter such as "/", "@" or
    /// ":"); callers must treat nil as "not a comparable host", never fall
    /// back to the raw string. Pure-ASCII input is not re-validated.
    public static func canonicalHost(_ host: String) -> String? {
        guard var canonical = asciiCompatibleName(host) else { return nil }
        if canonical.hasSuffix(".") {
            canonical = String(canonical.dropLast())
        }
        return canonical.isEmpty ? nil : canonical
    }

    /// Longest matching public suffix for a DNS host, per the
    /// publicsuffix.org algorithm (exact rules, `*.` wildcards, `!` exceptions,
    /// implicit `*` rule for unknown TLDs). The host may be Unicode or ACE and
    /// any case; the result is lowercase ACE. Returns nil for an empty host, a
    /// non-ASCII host that cannot be converted, or when the registry is
    /// unavailable on this OS.
    public static func publicSuffix(of host: String) -> String? {
        publicSuffix(of: host, using: rules)
    }

    /// `rules == nil` is the unavailable-registry state: nil for every host.
    static func publicSuffix(of host: String, using rules: Rules?) -> String? {
        guard let rules, let normalized = canonicalHost(host) else { return nil }

        let labels = normalized.split(separator: ".").map(String.init)
        guard !labels.isEmpty else { return nil }

        var longestMatch: [String]? = nil

        for startIndex in 0..<labels.count {
            let candidateLabels = Array(labels[startIndex...])
            let candidate = candidateLabels.joined(separator: ".")

            if rules.exception.contains(candidate) {
                // Exception match wins immediately; its suffix is the
                // exception rule's parent (drop one label).
                let parent = Array(candidateLabels.dropFirst())
                return parent.joined(separator: ".")
            }

            if candidateLabels.count >= 2 {
                let wildcardParent = candidateLabels.dropFirst().joined(separator: ".")
                if rules.wildcard.contains(wildcardParent) {
                    if longestMatch == nil || candidateLabels.count > longestMatch!.count {
                        longestMatch = candidateLabels
                    }
                }
            }

            if rules.exact.contains(candidate) {
                if longestMatch == nil || candidateLabels.count > longestMatch!.count {
                    longestMatch = candidateLabels
                }
            }
        }

        if let longestMatch {
            return longestMatch.joined(separator: ".")
        }

        // Implicit `*` rule: no explicit rule matched, suffix is the last label.
        return labels.last
    }

    /// Public suffix plus one label, as lowercase ACE. Returns nil when the
    /// host IS a public suffix (e.g. "co.uk", "github.io"), has a single
    /// label, is a non-ASCII host that cannot be converted, or the registry is
    /// unavailable on this OS.
    public static func registrableDomain(of host: String) -> String? {
        registrableDomain(of: host, using: rules)
    }

    static func registrableDomain(of host: String, using rules: Rules?) -> String? {
        guard let rules, let normalized = canonicalHost(host),
              let suffix = publicSuffix(of: normalized, using: rules) else { return nil }

        let hostLabels = normalized.split(separator: ".").map(String.init)
        let suffixLabelCount = suffix.split(separator: ".").count

        guard hostLabels.count > suffixLabelCount else { return nil }

        let startIndex = hostLabels.count - suffixLabelCount - 1
        return hostLabels[startIndex...].joined(separator: ".")
    }
}
