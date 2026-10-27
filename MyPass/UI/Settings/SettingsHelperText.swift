import SwiftUI

struct SettingsHelperText: View {
    /// Stored as a `Text` so the two initialisers decide the localization path once. A literal
    /// goes through `init(text:)` as a `LocalizedStringKey` and reaches the string catalog.
    /// `init(verbatim:)` is for a computed message that was already localized with
    /// `String(localized:)` (a `Text(String)` would not look it up a second time anyway, but this
    /// makes the intent explicit and keeps `LocalizedStringKey(someString)` out of call sites).
    private let content: Text

    init(text: LocalizedStringKey) {
        content = Text(text)
    }

    init(verbatim: String) {
        content = Text(verbatim: verbatim)
    }

    var body: some View {
        content
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 2)
    }
}
