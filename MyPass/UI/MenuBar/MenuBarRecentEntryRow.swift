import SwiftUI
import MyPassKit

struct MenuBarRecentEntryRow: View {
    let entry: KdbxEntry
    let action: () -> Void

    private var displayTitle: String {
        entry.displayTitle
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                LetterAvatarView(title: displayTitle, size: 28, cornerRadius: 6)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: displayTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    if !EntryListSubtitle.text(for: entry).isEmpty {
                        Text(verbatim: EntryListSubtitle.text(for: entry))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
