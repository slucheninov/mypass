import Foundation

/// How a vault entry's saved URL is matched against the page the browser
/// extension is currently looking at. `.registrableDomain` is the default —
/// unchanged behaviour from `ExtensionEntryMatcher.registrableDomain(from:)`
/// before this type existed. Raw values are kebab-case, matching the
/// lowercase-hyphenated style the Password Rules grammar already uses for its
/// own multi-word tokens (`max-consecutive`, `ascii-printable`).
///
/// `CaseIterable` is what lets the entry edit form's picker enumerate every
/// mode without a second, hand-maintained list that could drift out of sync
/// with this enum.
public enum URIMatchMode: String, CaseIterable, Hashable {
    case registrableDomain = "registrable-domain"
    case host = "host"
    case startsWith = "starts-with"
    case exact = "exact"
    case never = "never"
}
