import SwiftUI

struct GroupEditorSheet: View {
    enum Mode { case create, edit }

    let mode: Mode
    @State var name: String
    @State var emoji: String?
    let onSave: (String, String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var isNameFocused: Bool
    @State private var customEmojiInput: String = ""

    private static let presetEmojis = [
        "🔐", "💼", "🏦", "💳", "🌐", "📧", "🎮", "🛒",
        "✈️", "🏠", "❤️", "⭐️", "📱", "💻", "🎵", "🎬",
        "📚", "🧾", "🔧", "🚗", "🍔", "☁️", "🧪", "🗝️"
    ]

    private let gridColumns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 8)

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isCustomEmojiSelected: Bool {
        guard let emoji else { return false }
        return !Self.presetEmojis.contains(emoji)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(mode == .create ? "New Group" : "Edit Group")
                .font(.headline)

            TextField("Group name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($isNameFocused)

            Text("Icon")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            emojiPickerGrid

            HStack {
                Text("Custom")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Paste emoji", text: $customEmojiInput)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 80)
                    .padding(4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(isCustomEmojiSelected ? Color.accentColor.opacity(0.2) : Color.clear)
                    )
                    .onChange(of: customEmojiInput) { _, newValue in
                        guard !newValue.isEmpty else { return }
                        let firstGrapheme = String(newValue.prefix(1))
                        emoji = firstGrapheme
                        if customEmojiInput != firstGrapheme {
                            customEmojiInput = firstGrapheme
                        }
                    }
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") {
                    onSave(trimmedName, emoji)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedName.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 360)
        .onAppear {
            isNameFocused = true
            if let emoji, !Self.presetEmojis.contains(emoji) {
                customEmojiInput = emoji
            }
        }
    }

    private var emojiPickerGrid: some View {
        LazyVGrid(columns: gridColumns, spacing: 8) {
            emojiOptionButton(label: Text("None"), display: noneIcon, isSelected: emoji == nil) {
                emoji = nil
                customEmojiInput = ""
            }

            ForEach(Self.presetEmojis, id: \.self) { preset in
                emojiOptionButton(label: Text(verbatim: preset), display: Text(verbatim: preset).font(.title3), isSelected: emoji == preset) {
                    emoji = preset
                    customEmojiInput = ""
                }
            }
        }
    }

    private var noneIcon: some View {
        Image(systemName: "folder")
            .font(.title3)
            .foregroundStyle(.secondary)
    }

    private func emojiOptionButton<Label: View>(
        label: Text,
        display: Label,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            display
                .frame(width: 32, height: 32)
                .background(
                    Circle()
                        .fill(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
