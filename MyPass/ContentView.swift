import SwiftUI

struct ContentView: View {
    @EnvironmentObject var vaultSession: VaultSession

    var body: some View {
        switch vaultSession.state {
        case .locked:
            UnlockView()
        case .unlocked:
            Text("Hello, MyPass") // replaced by NavigationSplitView in Task 10
                .padding()
        }
    }
}
