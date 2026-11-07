import Foundation
import MyPassKit

/// Limits and file-reading rules for per-entry attachments.
///
/// The limits are enforced here (UI add time and the model API) and nowhere in the
/// KDBX engine: a KeePassXC vault that already exceeds them must round-trip
/// untouched, so only *further* adds are refused.
enum EntryAttachmentRules {
    static let maxFilesPerEntry = 8
    static let maxBytesPerFile = 5 * 1024 * 1024

    /// Reads a file for attaching. The size is checked from metadata before any
    /// bytes are read so a huge file is never loaded into memory.
    static func readFile(at url: URL) throws -> (name: String, data: Data) {
        let name = url.lastPathComponent
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey])
        } catch {
            throw AttachmentAddError.unreadable(name: name)
        }
        if values.isDirectory == true || values.isRegularFile != true {
            throw AttachmentAddError.notARegularFile(name: name)
        }
        if let size = values.fileSize, size > maxBytesPerFile {
            throw AttachmentAddError.fileTooLarge(name: name)
        }
        do {
            let data = try Data(contentsOf: url)
            // The file may have grown between the metadata check and the read.
            if data.count > maxBytesPerFile { throw AttachmentAddError.fileTooLarge(name: name) }
            return (name, data)
        } catch let error as AttachmentAddError {
            throw error
        } catch {
            throw AttachmentAddError.unreadable(name: name)
        }
    }
}

enum AttachmentAddError: LocalizedError, Equatable {
    case tooManyFiles
    case fileTooLarge(name: String)
    case unreadable(name: String)
    case notARegularFile(name: String)

    var errorDescription: String? {
        switch self {
        case .tooManyFiles:
            return String(localized: "An entry can have at most 8 files.", comment: "Attachment add error")
        case .fileTooLarge(let name):
            return String(format: String(localized: "“%@” is larger than 5 MB.", comment: "Attachment add error; argument is the file name"), name)
        case .unreadable(let name):
            return String(format: String(localized: "“%@” could not be read.", comment: "Attachment add error; argument is the file name"), name)
        case .notARegularFile(let name):
            return String(format: String(localized: "“%@” is a folder, not a file.", comment: "Attachment add error; argument is the file name"), name)
        }
    }
}

enum AttachmentFileName {
    static let fallback = "attachment"

    /// Keeps only the last path component (so `../x/evil.txt` becomes `evil.txt`),
    /// removes `:` and NUL, trims whitespace, and falls back for empty or dot-only names.
    static func sanitized(_ raw: String) -> String {
        let lastComponent = raw.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? ""
        let cleaned = lastComponent
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "\u{0}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty || cleaned == "." || cleaned == ".." { return fallback }
        return cleaned
    }

    /// `report.pdf` -> `report (2).pdf` -> `report (3).pdf`, extension preserved.
    static func unique(_ name: String, among existing: [String]) -> String {
        if !existing.contains(name) { return name }
        let ns = name as NSString
        let ext = ns.pathExtension
        let base = ext.isEmpty ? name : ns.deletingPathExtension
        var n = 2
        while true {
            let candidate = ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)"
            if !existing.contains(candidate) { return candidate }
            n += 1
        }
    }
}

extension KdbxEntry {
    /// Adds an attachment, refusing only the add when the entry is at or over the
    /// limits. Bumps `lastModificationTime` because MergeEngine picks the winning
    /// version by mtime; an attachment-only edit would otherwise be lost on sync.
    func addingAttachment(name: String, data: Data, now: Date = Date()) throws -> KdbxEntry {
        let display = AttachmentFileName.sanitized(name)
        guard attachments.count < EntryAttachmentRules.maxFilesPerEntry else {
            throw AttachmentAddError.tooManyFiles
        }
        guard data.count <= EntryAttachmentRules.maxBytesPerFile else {
            throw AttachmentAddError.fileTooLarge(name: display)
        }
        var copy = self
        let unique = AttachmentFileName.unique(display, among: attachments.map(\.name))
        copy.attachments.append(KdbxAttachment(name: unique, data: data, isProtected: true))
        copy.lastModificationTime = now
        return copy
    }

    /// Out-of-range indices are a no-op and do not touch the modification time.
    func removingAttachment(at index: Int, now: Date = Date()) -> KdbxEntry {
        guard attachments.indices.contains(index) else { return self }
        var copy = self
        copy.attachments.remove(at: index)
        copy.lastModificationTime = now
        return copy
    }
}
