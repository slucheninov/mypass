import CoreGraphics

/// Pure geometry for where the Settings window should appear. Kept free of AppKit types so it
/// can be unit-tested with synthetic screens; `SettingsWindowPlacer` feeds it real `NSScreen`
/// values. All rectangles are in AppKit (bottom-left origin) global screen coordinates.
enum SettingsWindowPlacement {
    struct Screen: Equatable {
        let frame: CGRect
        let visibleFrame: CGRect
    }

    /// Frame for a Settings window of `windowSize`, or `nil` when there is no screen at all.
    ///
    /// - The target screen is the one with the largest intersection area with `anchor` (ties go
    ///   to the earlier screen). Without an anchor, or when the anchor touches no screen, it is
    ///   the screen whose `frame` contains `pointer`, and failing that `screens.first`.
    /// - The window is centred on the anchor's midpoint, or on the target screen's
    ///   `visibleFrame` midpoint when there is no anchor.
    /// - The origin is then clamped into the target `visibleFrame` so the window never hangs
    ///   under the menu bar, the Dock or off the display. A window wider than the visible frame
    ///   pins to `minX`; a taller one pins to the top (`y = maxY - height`). The size is never
    ///   changed: Settings keeps its own minimum size.
    static func targetFrame(
        windowSize: CGSize,
        anchor: CGRect?,
        pointer: CGPoint,
        screens: [Screen]
    ) -> CGRect? {
        guard let firstScreen = screens.first else { return nil }

        var target: Screen?
        if let anchor {
            var bestArea: CGFloat = 0
            for screen in screens {
                let overlap = screen.frame.intersection(anchor)
                guard !overlap.isNull else { continue }
                let area = overlap.width * overlap.height
                // Strictly greater: on a tie the earlier screen wins.
                if area > bestArea {
                    bestArea = area
                    target = screen
                }
            }
        }
        if target == nil {
            target = screens.first { $0.frame.contains(pointer) }
        }
        let screen = target ?? firstScreen

        let visible = screen.visibleFrame
        let center = anchor.map { CGPoint(x: $0.midX, y: $0.midY) }
            ?? CGPoint(x: visible.midX, y: visible.midY)

        var x = center.x - windowSize.width / 2
        var y = center.y - windowSize.height / 2

        if windowSize.width > visible.width {
            x = visible.minX
        } else {
            x = min(max(x, visible.minX), visible.maxX - windowSize.width)
        }
        if windowSize.height > visible.height {
            y = visible.maxY - windowSize.height
        } else {
            y = min(max(y, visible.minY), visible.maxY - windowSize.height)
        }
        return CGRect(origin: CGPoint(x: x, y: y), size: windowSize)
    }
}
