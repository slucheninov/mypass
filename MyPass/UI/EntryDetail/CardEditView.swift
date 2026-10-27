import SwiftUI
import MyPassKit

struct CardEditView: View {
    let existingEntry: KdbxEntry?
    let rootGroup: KdbxGroup
    let recycleBinGroupUUID: UUID?
    let defaultGroupID: UUID
    let onCancel: () -> Void
    let onSave: (KdbxEntry, UUID) -> Void
    let onDelete: () -> Void

    @State private var selectedGroupID: UUID
    @State private var title: String = ""
    @State private var cardNumber: String = ""
    @State private var cardholderName: String = ""
    @State private var expiryDate: String = ""
    @State private var cvv: String = ""
    @State private var extraFields: [(key: String, value: String)] = []
    @State private var isCardNumberRevealed = false
    @State private var isCVVRevealed = false
    @State private var isFavorite: Bool

    init(
        existingEntry: KdbxEntry?,
        rootGroup: KdbxGroup,
        recycleBinGroupUUID: UUID?,
        defaultGroupID: UUID,
        onCancel: @escaping () -> Void,
        onSave: @escaping (KdbxEntry, UUID) -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.existingEntry = existingEntry
        self.rootGroup = rootGroup
        self.recycleBinGroupUUID = recycleBinGroupUUID
        self.defaultGroupID = defaultGroupID
        self.onCancel = onCancel
        self.onSave = onSave
        self.onDelete = onDelete
        _selectedGroupID = State(initialValue: defaultGroupID)
        _title = State(initialValue: existingEntry?.title ?? "")
        _cardNumber = State(initialValue: existingEntry?.cardNumber ?? "")
        _cardholderName = State(initialValue: existingEntry?.cardholderName ?? "")
        _expiryDate = State(initialValue: existingEntry?.expiryDate ?? "")
        _cvv = State(initialValue: existingEntry?.cvv ?? "")
        _extraFields = State(initialValue: (existingEntry?.additionalFields ?? [])
            .map { (key: $0.key, value: $0.value) })
        _isFavorite = State(initialValue: existingEntry?.isFavorite ?? false)
    }

    private var formattedCardNumberBinding: Binding<String> {
        Binding(
            get: {
                cardNumber.enumerated().map { index, character in
                    (index != 0 && index % 4 == 0) ? " \(character)" : String(character)
                }.joined()
            },
            set: { newValue in
                cardNumber = newValue.filter(\.isNumber)
            }
        )
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(spacing: 12) {
                    LetterAvatarView(
                        title: KdbxEntry.displayTitle(for: title),
                        size: UIShellMetrics.detailHeroIconSize,
                        cornerRadius: UIShellMetrics.detailHeroIconCornerRadius,
                        letterScale: UIShellMetrics.detailHeroLetterScale
                    )
                    Text(verbatim: KdbxEntry.displayTitle(for: title))
                        .font(.system(size: 22, weight: .bold))
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 24)

                EntryEditFieldsCard {
                    GroupPickerView(
                        rootGroup: rootGroup,
                        recycleBinGroupUUID: recycleBinGroupUUID,
                        selectedGroupID: $selectedGroupID
                    )
                    Divider().overlay(Color.primary.opacity(0.08))

                    TextField("Title", text: $title)
                    Divider().overlay(Color.primary.opacity(0.08))

                    HStack {
                        Group {
                            if isCardNumberRevealed {
                                TextField("Card Number", text: formattedCardNumberBinding)
                            } else {
                                SecureField("Card Number", text: formattedCardNumberBinding)
                            }
                        }
                        Button {
                            isCardNumberRevealed.toggle()
                        } label: {
                            Image(systemName: isCardNumberRevealed ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(isCardNumberRevealed ? "Hide card number" : "Show card number")
                    }
                    Divider().overlay(Color.primary.opacity(0.08))

                    TextField("Cardholder Name", text: $cardholderName)
                    Divider().overlay(Color.primary.opacity(0.08))

                    TextField("Expiry Date (MM/YY)", text: $expiryDate)
                    Divider().overlay(Color.primary.opacity(0.08))

                    HStack {
                        Group {
                            if isCVVRevealed {
                                TextField("CVV", text: $cvv)
                            } else {
                                SecureField("CVV", text: $cvv)
                            }
                        }
                        Button {
                            isCVVRevealed.toggle()
                        } label: {
                            Image(systemName: isCVVRevealed ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(isCVVRevealed ? "Hide CVV" : "Show CVV")
                    }

                    if !extraFields.isEmpty {
                        Divider().overlay(Color.primary.opacity(0.08))
                    }
                    ForEach(extraFields.indices, id: \.self) { index in
                        HStack {
                            TextField("Key", text: $extraFields[index].key)
                            TextField("Value", text: $extraFields[index].value)
                            Button("Remove", systemImage: "minus.circle") {
                                extraFields.remove(at: index)
                            }
                        }
                    }
                    Button("Add Field", systemImage: "plus") {
                        extraFields.append((key: "", value: ""))
                    }
                }

                if existingEntry != nil {
                    Button("Delete", role: .destructive, action: onDelete)
                        .buttonStyle(.plain)
                        .foregroundStyle(.red)
                        .padding(.bottom, 24)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
        }
        .background(UIShellMetrics.detailColumnBackground)
        .navigationTitle(existingEntry == nil ? "New Card" : "Edit Card")
        .safeAreaInset(edge: .top, spacing: 0) {
            EntryEditActionRow(isFavorite: $isFavorite, onCancel: onCancel, onSave: save)
        }
    }

    private func save() {
        let now = Date()
        var entry = existingEntry ?? KdbxEntry(
            uuid: UUID(),
            iconID: 0,
            fields: [],
            creationTime: now,
            lastModificationTime: now,
            lastAccessTime: now,
            locationChanged: now,
            history: []
        )
        entry.entryType = .card
        entry.title = title.isEmpty ? cardholderName : title
        entry.cardNumber = cardNumber
        entry.cardholderName = cardholderName
        entry.expiryDate = expiryDate
        entry.cvv = cvv
        entry.isFavorite = isFavorite
        entry.lastModificationTime = now
        entry.lastAccessTime = now

        entry.fields.removeAll { !KdbxEntry.standardFieldKeys.contains($0.key) }
        for field in extraFields where !field.key.isEmpty {
            entry.fields.append(KdbxField(key: field.key, value: field.value, isProtected: false))
        }

        onSave(entry, selectedGroupID)
    }
}
