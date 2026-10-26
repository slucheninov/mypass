import Foundation

/// A plain `MAJOR.MINOR.PATCH` version, as used by the GitHub release tags.
///
/// Parsing is deliberately strict. Prerelease and build suffixes (`0.2.0-beta`,
/// `1.0.0+build`) are rejected rather than ignored, because the update check
/// must never guess an ordering it cannot prove. Any string it cannot order
/// strictly is treated as "no update available".
struct SemanticVersion: Comparable, Equatable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int

    init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// Accepts an optional single leading `v` followed by exactly three
    /// dot-separated components. Each component must be non-empty and made only
    /// of ASCII digits. `Int(_:)` alone is not enough for that check because it
    /// also accepts a leading `+` or `-` sign, and it returns nil on overflow.
    init?(string: String) {
        let unprefixed = string.hasPrefix("v") ? String(string.dropFirst()) : string
        let pieces = unprefixed.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 3 else { return nil }
        guard pieces.allSatisfy({ piece in
            !piece.isEmpty && piece.allSatisfy { $0 >= "0" && $0 <= "9" }
        }) else { return nil }
        guard let major = Int(pieces[0]),
              let minor = Int(pieces[1]),
              let patch = Int(pieces[2]) else { return nil }
        self.init(major: major, minor: minor, patch: patch)
    }

    var description: String {
        "\(major).\(minor).\(patch)"
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}
