import Foundation

/// Domain-only display text for a stored URL (e.g. the browse Website row). Delegates
/// to `ExtensionEntryMatcher.registrableDomain`, which resolves the registrable
/// domain via a Public Suffix List lookup (`MyPassKit.PublicSuffixList`).
enum EntryURLDisplay {
    static func domain(from urlString: String) -> String? {
        ExtensionEntryMatcher.registrableDomain(from: urlString)
    }
}
