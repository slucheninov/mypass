import Foundation

/// Owns the one and only lookup of the vendored `password-rules.json` inside the
/// package bundle.
///
/// This exists as a named type rather than a bare `Bundle.module` call at each use
/// site for a concrete reason: `Bundle.module` is generated per target, so the same
/// expression written inside `MyPassKitTests` resolves to the TEST target's own
/// resource bundle (it declares `resources: [.copy("Fixtures")]`), not this one.
/// Tests reach the real data through `@testable import MyPassKit` and this type.
enum PasswordRulesResource {
    /// Raw bytes of the vendored rules file, read once.
    ///
    /// A missing or unreadable resource is a packaging bug, not a recoverable runtime
    /// condition, so this traps rather than degrading to an empty rule set — the same
    /// call this codebase already makes in `PublicSuffixList`, and for the same reason:
    /// silently behaving as "this site has no password rules" would hide exactly the
    /// failure the feature exists to prevent.
    static let rawJSON: Data = {
        guard let url = Bundle.module.url(forResource: "password-rules", withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            fatalError("PasswordRulesResource: missing or unreadable password-rules.json resource")
        }
        return data
    }()
}
