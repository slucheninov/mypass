import SwiftUI
import MyPassKit

@main
struct MyPassApp: App {
    @StateObject private var vaultSession = VaultSession(
        fileStore: VaultFileStore(
            directory: FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("MyPass")
        )
    )

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(vaultSession)
        }
    }
}
