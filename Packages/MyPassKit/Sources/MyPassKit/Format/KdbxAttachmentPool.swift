import CryptoKit
import Foundation

/// The KDBX4 inner-header binary pool, rebuilt from the entry model at save time.
///
/// Attachments live embedded on each `KdbxEntry` (so history snapshots and merges
/// carry their bytes with the entry value); the on-disk format wants one shared,
/// index-referenced pool instead. This type bridges the two:
///
/// - **Dedupe.** Identical content with the same protected flag is stored once
///   (KeePassXC dedupes by content too). The flag is part of the key because it is
///   a property of the inner-header record: the same bytes protected and
///   unprotected must stay two records or one of the flags would be lost.
/// - **Garbage collection.** The pool is built only from attachments some entry or
///   history item still references, so orphaned binaries are never written.
/// - **Order.** First-use order in exactly the traversal the XML encoder uses (per
///   group: each entry's own attachments, then each history entry's, then the
///   subgroups), so a `Ref="N"` the encoder emits always matches `binaries[N]`.
///
/// No size or count limit is applied here on purpose: the engine must round-trip
/// vaults that are already over the UI's limits untouched.
struct KdbxAttachmentPool: Equatable {
    static let empty = KdbxAttachmentPool()

    private(set) var binaries: [KdbxInnerBinary] = []
    private var indexByKey: [Key: Int] = [:]

    /// SHA-256 of the content plus the protected flag. Hashing keeps the key small
    /// for large files; a collision is cryptographically negligible.
    private struct Key: Hashable {
        let digest: SHA256.Digest
        let isProtected: Bool

        init(_ attachment: KdbxAttachment) {
            digest = SHA256.hash(data: attachment.data)
            isProtected = attachment.isProtected
        }
    }

    private init() {}

    init(collecting root: KdbxGroup) {
        collect(root)
    }

    /// Pool index for an attachment that was collected. Asking for one that was not
    /// is a programmer error (the encoder must only see the tree it collected).
    func index(of attachment: KdbxAttachment) -> Int {
        guard let index = indexByKey[Key(attachment)] else {
            preconditionFailure("attachment \(attachment.name) was not collected into the pool")
        }
        return index
    }

    // History is collected at any depth, in the same order the XML encoder walks it
    // (an entry's own attachments, then each snapshot depth-first). The coder reads
    // and writes `<History>` recursively, so a file from another client may nest
    // snapshots; collecting only one level would leave a deeper attachment out of
    // the pool and `index(of:)` would trap on every save of that vault.
    private mutating func collect(_ group: KdbxGroup) {
        for entry in group.entries {
            collect(entry)
        }
        for subgroup in group.subgroups {
            collect(subgroup)
        }
    }

    private mutating func collect(_ entry: KdbxEntry) {
        add(entry.attachments)
        for snapshot in entry.history {
            collect(snapshot)
        }
    }

    private mutating func add(_ attachments: [KdbxAttachment]) {
        for attachment in attachments {
            let key = Key(attachment)
            if indexByKey[key] == nil {
                indexByKey[key] = binaries.count
                binaries.append(KdbxInnerBinary(isProtected: attachment.isProtected, content: attachment.data))
            }
        }
    }
}
