import AppKit
import Foundation
import MyPassKit

/// Seam over `NSSavePanel` so the write logic can be tested with a fake panel
/// and a temp-directory destination. Main-actor because the real panel runs modally.
@MainActor
protocol SavePanelPresenting {
    /// Returns the user-chosen destination, or nil when the user cancelled.
    func chooseDestination(suggestedName: String) -> URL?
}

struct AttachmentExportError: Error, Equatable {
    let operation: String
    let errnoValue: Int32
}

/// Saves one attachment to a location the user picked.
///
/// Why this shape: attachment bytes must never exist as plaintext on disk
/// anywhere except the destination the user explicitly chose. So there is no
/// Quick Look preview, no `NSItemProvider` file promise and no `NSTemporaryDirectory` copy.
/// We also avoid `Data.write(options: .atomic)`: Apple documents only "an auxiliary
/// file", and Foundation may place it in a `TemporaryItems` folder outside the
/// destination directory. Instead we stage explicitly: `mkstemp` creates
/// `<destination dir>/.<name>.mypass-XXXXXX` (mode 0600, same directory and volume),
/// the bytes are written and `fsync`ed, and `rename(2)` swaps it over the destination.
/// On any error the staging file is unlinked, so the destination directory ends up
/// holding either the finished file or nothing new.
@MainActor
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
        try Self.writeStagedInPlace(attachment.data, to: destination)
        return destination
    }

    private static func writeStagedInPlace(_ data: Data, to destination: URL) throws {
        let dir = destination.deletingLastPathComponent().path
        var template = Array("\(dir)/.\(destination.lastPathComponent).mypass-XXXXXX".utf8CString)
        let fd = mkstemp(&template)
        guard fd >= 0 else { throw AttachmentExportError(operation: "mkstemp", errnoValue: errno) }
        let stagingPath = String(cString: template)
        var closed = false
        func fail(_ op: String) -> AttachmentExportError {
            let e = errno
            if !closed { close(fd); closed = true }
            unlink(stagingPath)
            return AttachmentExportError(operation: op, errnoValue: e)
        }

        var offset = 0
        while offset < data.count {
            let n = data.withUnsafeBytes { raw in
                write(fd, raw.baseAddress!.advanced(by: offset), data.count - offset)
            }
            if n < 0 {
                if errno == EINTR { continue }
                throw fail("write")
            }
            offset += n
        }
        if fsync(fd) != 0 { throw fail("fsync") }
        closed = true
        if close(fd) != 0 { let e = errno; unlink(stagingPath); throw AttachmentExportError(operation: "close", errnoValue: e) }
        if rename(stagingPath, destination.path) != 0 {
            let e = errno
            unlink(stagingPath)
            throw AttachmentExportError(operation: "rename", errnoValue: e)
        }
    }
}

/// Production presenter backed by `NSSavePanel`.
@MainActor
struct NSSavePanelPresenter: SavePanelPresenting {
    func chooseDestination(suggestedName: String) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }
}
