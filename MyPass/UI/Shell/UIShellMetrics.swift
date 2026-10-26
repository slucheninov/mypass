import SwiftUI

enum UIShellMetrics {
    static let listIconSize: CGFloat = 36
    static let detailHeroIconSize: CGFloat = 72
    static let detailHeroLetterScale: CGFloat = 0.58
    static let listIconCornerRadius: CGFloat = 8
    static let detailHeroIconCornerRadius: CGFloat = 16
    static let cardCornerRadius: CGFloat = 12
    static let cardMaxWidth: CGFloat = 420
    static let sidebarPreferredWidth: CGFloat = 200
    static let listColumnMinWidth: CGFloat = 260
    static let selectionAccentBarWidth: CGFloat = 3
    static let emptyStateIconSize: CGFloat = 64
    static let bannerHorizontalPadding: CGFloat = 16
    static let bannerVerticalPadding: CGFloat = 8

    /// Detail column backdrop — semantic so light/dark stay readable.
    static var detailColumnBackground: Color {
        Color(nsColor: .windowBackgroundColor)
    }
}
