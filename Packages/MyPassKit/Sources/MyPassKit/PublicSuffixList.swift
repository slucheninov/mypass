import Foundation

/// Public Suffix List (PSL) lookup, per the algorithm at
/// https://publicsuffix.org/list/. Rules are parsed once from the bundled
/// `public_suffix_list.dat` resource (ICANN + PRIVATE sections) into three
/// rule sets: exact, wildcard (`*.`), and exception (`!`).
///
/// All matching is byte/label comparison against the rules exactly as they
/// appear in the data file — including its Unicode-form rules (e.g. IDN
/// TLDs). There is no IDNA/punycode conversion here, so a Unicode rule only
/// matches a host already given in the same Unicode form; a punycode-encoded
/// host (e.g. "xn--...") will not match its Unicode-form rule counterpart.
public enum PublicSuffixList {
    private struct Rules {
        let exact: Set<String>
        let wildcard: Set<String>
        let exception: Set<String>
    }

    private static let rules: Rules = loadRules()

    private static func loadRules() -> Rules {
        guard let url = Bundle.module.url(forResource: "public_suffix_list", withExtension: "dat"),
              let contents = try? String(contentsOf: url, encoding: .utf8) else {
            fatalError("PublicSuffixList: missing or unreadable public_suffix_list.dat resource")
        }

        var exact = Set<String>()
        var wildcard = Set<String>()
        var exception = Set<String>()

        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("//") else { continue }
            guard let token = line.split(whereSeparator: \.isWhitespace).first else { continue }
            let rule = String(token).lowercased()

            if rule.hasPrefix("!") {
                exception.insert(String(rule.dropFirst()))
            } else if rule.hasPrefix("*.") {
                wildcard.insert(String(rule.dropFirst(2)))
            } else {
                exact.insert(rule)
            }
        }

        return Rules(exact: exact, wildcard: wildcard, exception: exception)
    }

    /// Longest matching public suffix for a lowercased DNS host, per the
    /// publicsuffix.org algorithm (exact rules, `*.` wildcards, `!` exceptions,
    /// implicit `*` rule for unknown TLDs). Returns nil for an empty host.
    public static func publicSuffix(of host: String) -> String? {
        var normalized = host.lowercased()
        guard !normalized.isEmpty else { return nil }
        if normalized.hasSuffix(".") {
            normalized = String(normalized.dropLast())
        }
        guard !normalized.isEmpty else { return nil }

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

    /// Public suffix plus one label. Returns nil when the host IS a public
    /// suffix (e.g. "co.uk", "github.io") or has a single label.
    public static func registrableDomain(of host: String) -> String? {
        var normalized = host.lowercased()
        guard !normalized.isEmpty else { return nil }
        if normalized.hasSuffix(".") {
            normalized = String(normalized.dropLast())
        }
        guard !normalized.isEmpty else { return nil }

        guard let suffix = publicSuffix(of: normalized) else { return nil }

        let hostLabels = normalized.split(separator: ".").map(String.init)
        let suffixLabelCount = suffix.split(separator: ".").count

        guard hostLabels.count > suffixLabelCount else { return nil }

        let startIndex = hostLabels.count - suffixLabelCount - 1
        return hostLabels[startIndex...].joined(separator: ".")
    }
}
