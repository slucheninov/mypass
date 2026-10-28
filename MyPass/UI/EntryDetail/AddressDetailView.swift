import SwiftUI
import AppKit
import MyPassKit

struct AddressDetailView: View {
    let entry: KdbxEntry
    @EnvironmentObject private var vaultSession: VaultSession
    @EnvironmentObject private var navigationState: NavigationState

    /// Labels are interface text, resolved with `String(localized:)` here because the rows are
    /// plain tuples that feed both a row label and the "Copy <label>" menu item. The values are
    /// vault data and stay as stored, except the address type, which is one of three stored
    /// English identifiers (Home / Work / Other) and is shown through `addressLabelTitle`.
    private var rows: [(label: String, value: String)] {
        let a = entry.address
        func label(_ resource: LocalizedStringResource) -> String { String(localized: resource) }
        return [
            (label("Type"), KdbxEntry.addressLabelTitle(a.label)), (label("Full Name"), a.fullName), (label("Given Name"), a.givenName),
            (label("Family Name"), a.familyName), (label("Organization"), a.organization),
            (label("Address Line 1"), a.addressLine1), (label("Address Line 2"), a.addressLine2),
            (label("City"), a.city), (label("Region"), a.region), (label("Postal Code"), a.postalCode),
            (label("Country"), a.countryName.isEmpty ? a.countryCode : a.countryName),
            (label("Phone"), a.phone), (label("Email"), a.email), (label("Notes"), entry.notes)
        ].filter { !$0.1.isEmpty }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: "house.fill").font(.system(size: 42)).foregroundStyle(.teal).padding(.top, 24)
                Text(verbatim: entry.title).font(.title2.bold()).multilineTextAlignment(.center)
                DetailFieldsCard {
                    ForEach(rows, id: \.label) { row in
                        DetailFieldRow(verbatimLabel: row.label, value: row.value)
                            .contextMenu { Button("Copy \(row.label)") { copy(row.value) } }
                        DetailFieldDivider()
                    }
                    ForEach(entry.additionalFields, id: \.key) { field in
                        DetailFieldRow(verbatimLabel: field.key, value: field.isProtected ? "••••••••" : field.value)
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
