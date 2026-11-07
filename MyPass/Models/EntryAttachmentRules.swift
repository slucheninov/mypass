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
    /// bytes are read so a huge file is never loaded into memory, and the read itself
    /// is bounded (see `boundedRead`) so a file that grows after that check is never
    /// fully loaded either. Symlinks are resolved first: `isRegularFileKey` describes
    /// the link itself, so without this a link to a regular file would be refused,
    /// while a link to a directory still resolves to a directory and is refused.
    static func readFile(at url: URL) throws -> (name: String, data: Data) {
        let name = url.lastPathComponent
        let resolved = url.resolvingSymlinksInPath()
        let values: URLResourceValues
        do {
            values = try resolved.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey])
        } catch {
            throw AttachmentAddError.unreadable(name: name)
        }
        if values.isDirectory == true || values.isRegularFile != true {
            throw AttachmentAddError.notARegularFile(name: name)
        }
        if let size = values.fileSize, size > maxBytesPerFile {
            throw AttachmentAddError.fileTooLarge(name: name)
        }
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: resolved)
        } catch {
            throw AttachmentAddError.unreadable(name: name)
        }
        defer { try? handle.close() }
        return (name, try boundedRead(from: handle, name: name))
    }

    /// Reads at most `maxBytesPerFile + 1` bytes; one byte over the limit proves the
    /// file is too large without loading the rest of it.
    static func boundedRead(from handle: FileHandle, name: String) throws -> Data {
        let data: Data
        do {
            data = try handle.read(upToCount: maxBytesPerFile + 1) ?? Data()
        } catch {
            throw AttachmentAddError.unreadable(name: name)
        }
        if data.count > maxBytesPerFile { throw AttachmentAddError.fileTooLarge(name: name) }
        return data
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
    /// removes `:` and control characters (U+0000-U+001F, U+007F), trims whitespace, and falls back for empty or dot-only names.
    static func sanitized(_ raw: String) -> String {
        let lastComponent = raw.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? ""
        let cleaned = lastComponent
            .replacingOccurrences(of: ":", with: "")
            .unicodeScalars.filter { $0.value > 0x1F && $0.value != 0x7F }
            .reduce(into: "") { $0.unicodeScalars.append($1) }
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
