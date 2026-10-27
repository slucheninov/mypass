import SwiftUI

struct AppearanceSettingsPane: View {
    @AppStorage(AppTheme.storageKey) private var themeRaw = AppTheme.system.rawValue
    @EnvironmentObject private var restartController: LanguageRestartController

    private let languageStore = AppLanguageStore()
    /// Mirrors the stored override so the picker redraws; the store (`AppleLanguages` in the
    /// app's own defaults domain) stays the source of truth.
    @State private var language = AppLanguageStore().storedOverride

    private var restartPending: Bool {
        AppLanguageStore.isRestartPending(launch: AppLanguageStore.launchSelection, current: language)
    }

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

            Section {
                Picker("Language", selection: $language) {
                    ForEach(AppLanguage.allCases) { option in
                        if let nativeName = option.nativeName {
                            // Endonym: never translated, so it is rendered verbatim.
                            Text(verbatim: nativeName).tag(option)
                        } else {
                            Text("Use System Default").tag(option)
                        }
                    }
                }
                .onChange(of: language) { _, newValue in
                    languageStore.select(newValue)
                    restartController.languageSelectionChanged()
                }
                // Both hints only while the chosen language differs from the running one;
                // a failed launch for a choice the user has since reverted shows nothing.
                if restartPending {
                    if restartController.phase == .manualRestartNeeded {
                        SettingsHelperText(text: "Quit MyPass and open it again to apply the language")
                    } else {
                        HStack {
                            SettingsHelperText(text: "Restart MyPass to apply the language")
                            Spacer()
                            Button("Restart Now") {
                                restartController.restartNow(selecting: language, store: languageStore)
                            }
                            .disabled(restartController.phase == .restarting)
                        }
                    }
                }
            } header: {
                Text("Language")
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
