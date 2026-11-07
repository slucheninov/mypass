import AppKit
import Foundation
import MyPassKit

/// Seam over `NSSavePanel` so the write logic can be tested with a fake panel
/// and a temp-directory destination.
protocol SavePanelPresenting {
    /// Returns the user-chosen destination, or nil when the user cancelled.
    func chooseDestination(suggestedName: String) -> URL?
}

/// Saves one attachment to a location the user picked.
///
/// Why this shape: attachment bytes must never exist as plaintext on disk
/// anywhere except the destination the user explicitly chose. So there is no
/// Quick Look preview, no `NSItemProvider` file promise and no staging file in
/// `NSTemporaryDirectory`: all of those would put a plaintext copy somewhere the
/// user never agreed to. `Data.write(options: .atomic)` is fine because
/// Foundation stages its auxiliary file in the destination's own directory and
/// renames it over the target, so the only file left behind is the destination.
struct AttachmentExporter {
    let panel: SavePanelPresenting

    init(panel: SavePanelPresenting) {
        self.panel = panel
    }

    /// Returns the written URL, or nil when the user cancelled (nothing written).
    @discardableResult
    func export(_ attachment: KdbxAttachment) throws -> URL? {
        let suggested = AttachmentFileName.sanitized(attachment.name)
        guard let destination = panel.chooseDestination(suggestedName: suggested) else { return nil }
        try attachment.data.write(to: destination, options: .atomic)
        return destination
    }
}

/// Production presenter backed by `NSSavePanel`.
struct NSSavePanelPresenter: SavePanelPresenting {
    func chooseDestination(suggestedName: String) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }
}
