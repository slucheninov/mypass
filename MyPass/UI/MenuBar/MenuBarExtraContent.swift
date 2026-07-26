import SwiftUI

struct MenuBarExtraContent: View {
    @EnvironmentObject var vaultSession: VaultSession
    @EnvironmentObject var navigationState: NavigationState
    @State private var showPasswordGenerator = false

    private var statusText: String {
        switch vaultSession.state {
        case .locked: return "Locked"
        case .unlocked: return "Unlocked"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(statusText)
                .font(.headline)
            TextField("Quick Search", text: $navigationState.searchText)
                .textFieldStyle(.roundedBorder)
            Button("Lock") {
                vaultSession.lock()
            }
            .disabled({
                if case .locked = vaultSession.state { return true }
                return false
            }())
            Button("Password Generator") {
                showPasswordGenerator = true
            }
        }
        .padding(12)
        .frame(width: 240)
        .sheet(isPresented: $showPasswordGenerator) {
            PasswordGeneratorView()
        }
    }
}
