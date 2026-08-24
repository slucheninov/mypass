import SwiftUI

struct MenuBarExtraContent: View {
    @EnvironmentObject var vaultSession: VaultSession
    @EnvironmentObject var navigationState: NavigationState
    @EnvironmentObject var deviceUnlockPromptCoordinator: DeviceUnlockPromptCoordinator

    var body: some View {
        Group {
            switch vaultSession.state {
            case .locked:
                MenuBarUnlockPanelView()
            case .unlocked:
                MenuBarUnlockedPanelView()
            }
        }
        .environmentObject(vaultSession)
        .environmentObject(navigationState)
        .environmentObject(deviceUnlockPromptCoordinator)
    }
}
