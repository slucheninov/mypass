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
    var letterScale: CGFloat = 0.42

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(LetterAvatar.color(for: title))
            Text(LetterAvatar.letter(from: title))
                .font(.system(size: size * letterScale, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        // Two whole sentences instead of one interpolated ternary: a literal mixed with a
        // `String` inside the interpolation would leave "untitled entry" out of the catalog.
        .accessibilityLabel(title.isEmpty ? Text("Icon for untitled entry") : Text("Icon for \(title)"))
    }
}
