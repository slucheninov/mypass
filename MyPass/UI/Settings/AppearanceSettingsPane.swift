import SwiftUI

struct AppearanceSettingsPane: View {
    @AppStorage(AppTheme.storageKey) private var themeRaw = AppTheme.system.rawValue

    /// Reads and writes go through `AppTheme(storedRaw:)` so an unknown stored value
    /// shows as "Match System" instead of leaving the picker with no selection.
    private var theme: Binding<AppTheme> {
        Binding(
            get: { AppTheme(storedRaw: themeRaw) },
            set: { themeRaw = $0.rawValue }
        )
    }

    var body: some View {
        Form {
            Section {
                Picker("Theme", selection: theme) {
                    ForEach(AppTheme.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .onChange(of: themeRaw) { _, newValue in
                    AppTheme.apply(AppTheme(storedRaw: newValue))
                }
                SettingsHelperText(text: "Match System follows the macOS appearance and switches with it.")
            } header: {
                Text("Theme")
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
