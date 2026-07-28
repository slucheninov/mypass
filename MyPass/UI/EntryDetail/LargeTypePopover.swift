import SwiftUI

/// Large-text popover content shown from a field row's "Show Large Type" context
/// menu item. The caller is responsible for supplying already-cleartext `text` —
/// this view has no reveal/mask logic of its own.
struct LargeTypePopover: View {
    let text: String
    var isMonospaced: Bool = true

    var body: some View {
        Text(text)
            .font(.system(size: 48, weight: .medium, design: isMonospaced ? .monospaced : .rounded))
            .padding(32)
            .frame(minWidth: 200)
    }
}
