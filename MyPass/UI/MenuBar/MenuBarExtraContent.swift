import SwiftUI

struct MenuBarExtraContent: View {
    @EnvironmentObject var vaultSession: VaultSession
    @EnvironmentObject var navigationState: NavigationState
    @State private var showPasswordGenerator = false

    private var statusText: String {
        switch vaultSession.state {
        case .locked: return "Заблокировано"
        case .unlocked: return "Разблокировано"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(statusText)
                .font(.headline)
            TextField("Быстрый поиск", text: $navigationState.searchText)
                .textFieldStyle(.roundedBorder)
            Button("Заблокировать") {
                vaultSession.lock()
            }
            .disabled({
                if case .locked = vaultSession.state { return true }
                return false
            }())
            Button("Генератор паролей") {
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
