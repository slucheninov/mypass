import Foundation

/// The app-side "Use MyPass for Chrome passkeys" opt-in. It is the canonical value used
/// by the bridge: browser reports are snapshots and must never overwrite it with a
/// delayed observation, and the extension's own flag is only a cache of this one.
///
/// The default is ON. `UserDefaults.bool(forKey:)` cannot express that — it reports
/// `false` for a key that was never written, which is indistinguishable from an explicit
/// "off". So the value is read as `object(forKey:) as? Bool ?? defaultValue`: a stored
/// choice (either way) always wins, and only an untouched key falls back to ON.
///
/// This deliberately does not use `register(defaults:)`. A registered default depends on
/// launch ordering (it must run before the first read, in every process and every test
/// suite that builds a service), whereas this shared helper gives the same answer from
/// any `UserDefaults` at any time. The SwiftUI toggle in Settings > General reads the
/// same key through `@AppStorage` with `defaultValue` as its fallback, so the two stay in
/// agreement without a registration step.
enum PasskeyProxyPreference {
    static let defaultsKey = "passkeyProxyEnabled"
    static let defaultValue = true

    static func isEnabled(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: defaultsKey) as? Bool ?? defaultValue
    }

    static func set(_ enabled: Bool, in defaults: UserDefaults) {
        defaults.set(enabled, forKey: defaultsKey)
    }
}
