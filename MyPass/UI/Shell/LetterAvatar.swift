import SwiftUI

enum LetterAvatar {
    private static let palette: [Color] = [
        .blue, .green, .orange, .purple, .pink, .teal, .indigo, .mint, .cyan, .brown
    ]

    static func letter(from title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "?" }
        return String(first).uppercased()
    }

    static func color(for title: String) -> Color {
        let hash = title.utf8.reduce(0) { ($0 &+ Int($1)) &* 31 }
        let index = ((hash % palette.count) + palette.count) % palette.count
        return palette[index]
    }
}

struct LetterAvatarView: View {
    let title: String
    let size: CGFloat
    let cornerRadius: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(LetterAvatar.color(for: title))
            Text(LetterAvatar.letter(from: title))
                .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .accessibilityLabel(Text("Icon for \(title.isEmpty ? "untitled entry" : title)"))
    }
}
