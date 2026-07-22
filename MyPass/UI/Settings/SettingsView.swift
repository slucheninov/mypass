import SwiftUI
import MyPassKit

enum SyncBackendOption: String, CaseIterable, Identifiable {
    case local = "Локальный файл"
    case iCloud = "iCloud Drive"
    case sftp = "SFTP"

    var id: String { rawValue }

    // Only .local is functional in Phase 2. iCloud/SFTP are Phase 3 (see design spec §"Синхронизация").
    // The picker below persists the user's choice to UserDefaults now so Phase 3 can read
    // an existing preference on first launch, but no sync code runs for the other two options yet.
    var isAvailable: Bool { self == .local }
}

struct SettingsView: View {
    @AppStorage("autoLockTimeoutMinutes") private var autoLockTimeoutMinutes: Double = 15
    @AppStorage("backupCount") private var backupCount: Int = 10
    @AppStorage("syncBackend") private var syncBackendRawValue: String = SyncBackendOption.local.rawValue

    // Bridges the persisted timeout to the live, running AutoLockController (Task 5) so that
    // changing the stepper actually affects autolock behavior in this session, and so a value
    // persisted in a previous session is restored into the controller on next launch too —
    // otherwise UserDefaults would hold a value the running controller never reads.
    @EnvironmentObject private var autoLockController: AutoLockController

    var body: some View {
        Form {
            Section("Автоблокировка") {
                Stepper("Таймаут: \(Int(autoLockTimeoutMinutes)) мин", value: $autoLockTimeoutMinutes, in: 1...120)
            }
            Section("Резервные копии") {
                Stepper("Хранить последних: \(backupCount)", value: $backupCount, in: 1...50)
            }
            Section("Синхронизация") {
                Picker("Бэкенд", selection: $syncBackendRawValue) {
                    ForEach(SyncBackendOption.allCases) { option in
                        Text(option.isAvailable ? option.rawValue : "\(option.rawValue) (скоро)")
                            .tag(option.rawValue)
                    }
                }
                .disabled(false) // the Picker itself stays enabled so the user can record a preference;
                                  // individual non-local options are visually marked "(скоро)" above.
            }
        }
        .padding()
        .frame(width: 360)
        .onAppear {
            // Restore a persisted value into the live controller at view-appear time — covers
            // the case where a timeout was changed in a previous session but the controller
            // (constructed once in MyPassApp.init with a hardcoded default) never saw it.
            autoLockController.timeout = autoLockTimeoutMinutes * 60
        }
        .onChange(of: autoLockTimeoutMinutes) { _, newValue in
            autoLockController.timeout = newValue * 60
        }
    }
}
