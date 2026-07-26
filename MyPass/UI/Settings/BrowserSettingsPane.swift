import SwiftUI

struct BrowserSettingsPane: View {
    @EnvironmentObject private var pairingStoreModel: ExtensionPairingStoreModel
    @State private var pairedBrowsers: [PairedBrowser] = []

    var body: some View {
        Form {
            Section {
                if pairedBrowsers.isEmpty {
                    Text("No paired browsers.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(pairedBrowsers) { browser in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(browser.label)
                                Text(browser.createdAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Revoke") {
                                try? pairingStoreModel.store.remove(id: browser.id)
                                pairedBrowsers = pairingStoreModel.refresh()
                            }
                        }
                    }
                }
            } header: {
                Text("Paired browsers")
                    .font(.system(size: 13, weight: .semibold))
            }
            .onAppear {
                pairedBrowsers = pairingStoreModel.refresh()
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
