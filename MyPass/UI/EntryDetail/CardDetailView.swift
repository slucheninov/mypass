import SwiftUI
import AppKit
import MyPassKit

struct CardDetailView: View {
    let entry: KdbxEntry
    @EnvironmentObject var vaultSession: VaultSession
    @EnvironmentObject var navigationState: NavigationState
    @State private var isCardNumberRevealed = false
    @State private var isCVVRevealed = false
    @State private var largeTypeField: LargeTypeField?

    private let pasteboard = NSPasteboardClearing()
    private let clock = RealAutoLockClock()

    private enum LargeTypeField: Equatable {
        case cardNumber
        case cvv
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(spacing: 12) {
                    LetterAvatarView(
                        title: entry.title.isEmpty ? "(untitled)" : entry.title,
                        size: UIShellMetrics.detailHeroIconSize,
                        cornerRadius: UIShellMetrics.detailHeroIconCornerRadius,
                        letterScale: UIShellMetrics.detailHeroLetterScale
                    )
                    Text(entry.title.isEmpty ? "(untitled)" : entry.title)
                        .font(.system(size: 22, weight: .bold))
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 24)

                DetailFieldsCard {
                    cardNumberRow
                    DetailFieldDivider()
                    DetailFieldRow(label: "Cardholder", value: entry.cardholderName)
                    DetailFieldDivider()
                    DetailFieldRow(label: "Expiry", value: entry.expiryDate)
                    DetailFieldDivider()
                    cvvRow

                    ForEach(entry.additionalFields, id: \.key) { field in
                        DetailFieldDivider()
                        DetailFieldRow(label: field.key, value: field.value)
                            .contextMenu {
                                Button("Copy \(field.key)") { copy(field.value) }
                            }
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
        }
        .background(UIShellMetrics.detailColumnBackground)
        .navigationTitle("Card")
        .toolbar {
            DetailActionsToolbarContent(onEdit: { navigationState.presentEdit(entryID: entry.uuid) })
        }
        .onChange(of: navigationState.selectedEntryID) { _, newID in
            isCardNumberRevealed = false
            isCVVRevealed = false
            largeTypeField = nil
            if let newID {
                vaultSession.touchAccess(entryID: newID)
            }
        }
    }

    private var cardNumberRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("Card Number")
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .leading)
            Text(isCardNumberRevealed ? entry.cardNumber : String(repeating: "•", count: max(entry.cardNumber.count, 8)))
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
            Button {
                isCardNumberRevealed.toggle()
            } label: {
                Image(systemName: isCardNumberRevealed ? "eye.slash" : "eye")
            }
            .buttonStyle(.borderless)
        }
        .font(.body)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contextMenu {
            Button("Copy Card Number") { copy(entry.cardNumber) }
            Button("Show Large Type") { largeTypeField = .cardNumber }
        }
        .popover(isPresented: largeTypeBinding(.cardNumber)) {
            LargeTypePopover(text: entry.cardNumber, isMonospaced: true)
        }
    }

    private var cvvRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("CVV")
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .leading)
            Text(isCVVRevealed ? entry.cvv : String(repeating: "•", count: max(entry.cvv.count, 3)))
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
            Button {
                isCVVRevealed.toggle()
            } label: {
                Image(systemName: isCVVRevealed ? "eye.slash" : "eye")
            }
            .buttonStyle(.borderless)
        }
        .font(.body)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contextMenu {
            Button("Copy CVV") { copy(entry.cvv) }
            Button("Show Large Type") { largeTypeField = .cvv }
        }
        .popover(isPresented: largeTypeBinding(.cvv)) {
            LargeTypePopover(text: entry.cvv, isMonospaced: true)
        }
    }

    private func largeTypeBinding(_ field: LargeTypeField) -> Binding<Bool> {
        Binding(
            get: { largeTypeField == field },
            set: { isPresented in largeTypeField = isPresented ? field : nil }
        )
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        ClipboardAutoClear.schedule(value: value, after: ClipboardClearInterval.seconds(), pasteboard: pasteboard, clock: clock)
        if let id = navigationState.selectedEntryID {
            vaultSession.touchAccess(entryID: id)
        }
    }
}
