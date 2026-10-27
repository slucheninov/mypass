import SwiftUI
import AppKit
import MyPassKit

struct AddressDetailView: View {
    let entry: KdbxEntry
    @EnvironmentObject private var vaultSession: VaultSession
    @EnvironmentObject private var navigationState: NavigationState

    private var rows: [(label: String, value: String)] {
        let a = entry.address
        return [
            ("Type", a.label), ("Full Name", a.fullName), ("Given Name", a.givenName),
            ("Family Name", a.familyName), ("Organization", a.organization),
            ("Address Line 1", a.addressLine1), ("Address Line 2", a.addressLine2),
            ("City", a.city), ("Region", a.region), ("Postal Code", a.postalCode),
            ("Country", a.countryName.isEmpty ? a.countryCode : a.countryName),
            ("Phone", a.phone), ("Email", a.email), ("Notes", entry.notes)
        ].filter { !$0.1.isEmpty }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: "house.fill").font(.system(size: 42)).foregroundStyle(.teal).padding(.top, 24)
                Text(entry.title).font(.title2.bold()).multilineTextAlignment(.center)
                DetailFieldsCard {
                    ForEach(rows, id: \.label) { row in
                        DetailFieldRow(label: row.label, value: row.value)
                            .contextMenu { Button("Copy \(row.label)") { copy(row.value) } }
                        DetailFieldDivider()
                    }
                    ForEach(entry.additionalFields, id: \.key) { field in
                        DetailFieldRow(label: field.key, value: field.isProtected ? "••••••••" : field.value)
                            .contextMenu { Button("Copy \(field.key)") { copy(field.value) } }
                    }
                }
                Text("Autofill from the MyPass extension: Addresses → select this address. Only the selected address form is filled.")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: UIShellMetrics.cardMaxWidth, alignment: .leading)
            }
            .frame(maxWidth: .infinity).padding(24)
        }
        .background(UIShellMetrics.detailColumnBackground)
        .navigationTitle("Address")
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        ClipboardAutoClear.schedule(value: value, after: ClipboardClearInterval.seconds(), pasteboard: NSPasteboardClearing(), clock: RealAutoLockClock())
        vaultSession.touchAccess(entryID: entry.uuid)
    }
}
