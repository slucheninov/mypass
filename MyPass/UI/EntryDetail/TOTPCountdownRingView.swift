import SwiftUI

/// Live green countdown ring for the browse TOTP row, replacing the old static
/// `TOTPRingChrome`. Ticks alongside the parent view's existing 1 s timer.
struct TOTPCountdownRingView: View {
    let period: TimeInterval
    let now: Date
    var diameter: CGFloat = 17

    static func progress(period: TimeInterval, now: Date) -> Double {
        guard period > 0 else { return 0 }
        return TOTPCode.secondsRemaining(period: period, now: now) / period
    }

    var body: some View {
        Circle()
            .trim(from: 0, to: Self.progress(period: period, now: now))
            .stroke(Color.green, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .rotationEffect(.degrees(-90))
            .frame(width: diameter, height: diameter)
            .animation(.linear(duration: 1), value: now)
            .accessibilityHidden(true)
    }
}
