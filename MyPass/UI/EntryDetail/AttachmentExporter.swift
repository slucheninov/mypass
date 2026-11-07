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
/// Why the write is direct: the app is sandboxed with `files.user-selected.read-write`,
/// and `NSSavePanel` grants access to the chosen file only, not to its parent
/// directory. A staging sibling (`mkstemp` next to the destination, then `rename`)
/// would be denied there, so every save would fail in the shipped build.
///
/// Why there is no staging anywhere: attachment bytes must never exist as plaintext
/// on disk except at the destination the user explicitly chose. No Quick Look, no
/// `NSItemProvider` file promise, no `NSTemporaryDirectory` copy, and no
/// `Data.write(options: .atomic)` either (Foundation may stage that in a
/// `TemporaryItems` folder outside the destination). The file is opened with
/// `O_TRUNC` and mode 0600, then `fchmod`ed to 0600 because an existing file keeps
/// its old mode. On any error the partial destination is unlinked. Trade-off: a
/// crash or power loss mid-write leaves at most a partial file at the user's chosen
/// path; the save panel already confirmed any overwrite with the user.
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
        try Self.writeDirectly(attachment.data, to: destination)
        return destination
    }

    private static func writeDirectly(_ data: Data, to destination: URL) throws {
        let path = destination.path
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw AttachmentExportError(operation: "open", errnoValue: errno) }
        // Only a file this call just created or truncated is unlinked on failure.
        func fail(_ op: String) -> AttachmentExportError {
            let e = errno
            close(fd)
            unlink(path)
            return AttachmentExportError(operation: op, errnoValue: e)
        }
        if fchmod(fd, 0o600) != 0 { throw fail("fchmod") }
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
        if close(fd) != 0 {
            let e = errno
            unlink(path)
            throw AttachmentExportError(operation: "close", errnoValue: e)
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
