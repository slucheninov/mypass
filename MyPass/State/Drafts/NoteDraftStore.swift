import CryptoKit
import Foundation

struct NoteDraftVersion: Codable, Equatable, Identifiable {
    let id: UUID
    let savedAt: Date
    let notes: String
}

/// Encrypted, bounded history of note drafts, one file per vault + entry.
///
/// Why there is no plaintext fallback: drafts exist so unsaved notes survive a crash or
/// auto-lock, but notes are vault secrets. If the Keychain key cannot be loaded (denied,
/// unsigned dev build, device locked) the store reports `isAvailable == false` and writes
/// nothing; the editor simply works without drafts. Drafts are never written into the vault.
///
/// File format: "MPD1" + ChaChaPoly combined box. The AAD is "<vaultID>|<entryID>" so a
/// file copied onto another entry's path fails authentication instead of leaking or
/// injecting notes.
final class NoteDraftStore {
    private static let magic = Data("MPD1".utf8)

    private let directory: URL
    private let keyProvider: DraftKeyProviding
    private let now: () -> Date
    private let capacity: Int
    private let timeToLive: TimeInterval
    private let mutex = NSLock()
    private var key: SymmetricKey?

    init(directory: URL,
         keyProvider: DraftKeyProviding,
         now: @escaping () -> Date = Date.init,
         capacity: Int = 10,
         timeToLive: TimeInterval = 7 * 24 * 3600) {
        self.directory = directory
        self.keyProvider = keyProvider
        self.now = now
        self.capacity = capacity
        self.timeToLive = timeToLive
    }

    /// False once a key load failed; true while a key is cached.
    var isAvailable: Bool {
        mutex.lock(); defer { mutex.unlock() }
        return key != nil
    }

    func unlock() {
        mutex.lock(); defer { mutex.unlock() }
        do {
            key = try keyProvider.loadOrCreateKey()
        } catch {
            key = nil
        }
    }

    func lock() {
        mutex.lock(); defer { mutex.unlock() }
        key = nil
    }

    @discardableResult
    func save(notes: String, vaultID: String, entryID: UUID) -> Bool {
        mutex.lock(); defer { mutex.unlock() }
        guard let key else { return false }
        var list = readLocked(vaultID: vaultID, entryID: entryID, key: key)
        if let newest = list.last, newest.notes == notes { return true }
        list.append(NoteDraftVersion(id: UUID(), savedAt: now(), notes: notes))
        if list.count > capacity { list.removeFirst(list.count - capacity) }
        return writeLocked(list, vaultID: vaultID, entryID: entryID, key: key)
    }

    /// Newest first.
    func versions(vaultID: String, entryID: UUID) -> [NoteDraftVersion] {
        mutex.lock(); defer { mutex.unlock() }
        guard let key else { return [] }
        return readLocked(vaultID: vaultID, entryID: entryID, key: key).reversed()
    }

    func deleteAll(vaultID: String, entryID: UUID) {
        mutex.lock(); defer { mutex.unlock() }
        try? FileManager.default.removeItem(at: fileURL(vaultID: vaultID, entryID: entryID))
    }

    /// Reaps whole files not touched for `timeToLive`, including drafts of entries that are
    /// never reopened (so `versions` never prunes them). Works from the file modification
    /// date because the vault ID is stored only as a hash, so the AAD cannot be rebuilt
    /// here; it therefore needs no key and runs while locked too. Per-version expiry inside
    /// a live file is handled by `versions`.
    func purgeExpired() {
        mutex.lock(); defer { mutex.unlock() }
        let fm = FileManager.default
        guard let vaultDirs = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for vaultDir in vaultDirs {
            guard let files = try? fm.contentsOfDirectory(at: vaultDir, includingPropertiesForKeys: nil) else { continue }
            for file in files where file.pathExtension == "draft" {
                if let attrs = try? fm.attributesOfItem(atPath: file.path),
                   let modified = attrs[.modificationDate] as? Date,
                   now().timeIntervalSince(modified) > timeToLive {
                    try? fm.removeItem(at: file)
                }
            }
        }
    }

    // MARK: - Private

    private func vaultDirectory(vaultID: String) -> URL {
        let digest = SHA256.hash(data: Data(vaultID.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined().prefix(16)
        return directory.appendingPathComponent(String(hex), isDirectory: true)
    }

    private func fileURL(vaultID: String, entryID: UUID) -> URL {
        vaultDirectory(vaultID: vaultID).appendingPathComponent("\(entryID.uuidString).draft")
    }

    private func aad(vaultID: String, entryID: UUID) -> Data {
        Data("\(vaultID)|\(entryID.uuidString)".utf8)
    }

    /// Chronological (oldest first). Prunes expired versions and removes unreadable files.
    private func readLocked(vaultID: String, entryID: UUID, key: SymmetricKey) -> [NoteDraftVersion] {
        let url = fileURL(vaultID: vaultID, entryID: entryID)
        guard let raw = try? Data(contentsOf: url) else { return [] }
        guard raw.starts(with: Self.magic),
              let box = try? ChaChaPoly.SealedBox(combined: raw.dropFirst(Self.magic.count)),
              let plain = try? ChaChaPoly.open(box, using: key, authenticating: aad(vaultID: vaultID, entryID: entryID)),
              let decoded = try? JSONDecoder().decode([NoteDraftVersion].self, from: plain) else {
            try? FileManager.default.removeItem(at: url)
            return []
        }
        let cutoff = now().addingTimeInterval(-timeToLive)
        let fresh = decoded.filter { $0.savedAt >= cutoff }
        if fresh.count != decoded.count {
            if fresh.isEmpty {
                try? FileManager.default.removeItem(at: url)
            } else {
                _ = writeLocked(fresh, vaultID: vaultID, entryID: entryID, key: key)
            }
        }
        return fresh
    }

    private func writeLocked(_ list: [NoteDraftVersion], vaultID: String, entryID: UUID, key: SymmetricKey) -> Bool {
        do {
            let plain = try JSONEncoder().encode(list)
            let box = try ChaChaPoly.seal(plain, using: key, authenticating: aad(vaultID: vaultID, entryID: entryID))
            var out = Self.magic
            out.append(box.combined)
            let dir = vaultDirectory(vaultID: vaultID)
            try FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try out.write(to: fileURL(vaultID: vaultID, entryID: entryID), options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
