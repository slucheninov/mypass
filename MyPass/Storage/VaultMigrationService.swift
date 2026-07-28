import Foundation
import MyPassKit
import SyncKit

/// How a local vault and a remote mirror are reconciled the first time they
/// are connected.
enum VaultMigrationStrategy: String, CaseIterable, Identifiable {
    /// Remote is empty: upload the local vault, leave local untouched.
    case seedRemote
    /// Remote holds a vault: run one `SyncEngine` pass and keep everything
    /// from both sides. The default offer.
    case merge
    /// Remote holds a vault: replace the local working copy with it.
    case adoptRemote
    /// Remote holds a vault: replace it with the local working copy.
    case overwriteRemote

    var id: String { rawValue }
}

/// What a remote backend currently holds, established without ever decrypting
/// it — probing needs no vault password.
struct VaultMigrationTargetProbe: Equatable {
    let exists: Bool
    let modificationDate: Date?
    let byteCount: Int?
}

struct VaultMigrationOutcome {
    let strategy: VaultMigrationStrategy
    /// Non-nil when the local in-memory database was replaced, so the caller
    /// can republish it and avoid showing stale entries.
    let mergedDatabase: KdbxDatabase?
    let remoteWritten: Bool
    let localReplaced: Bool
}

enum VaultMigrationError: Error {
    case vaultLocked
    case remoteUnreadable(underlying: Error)
    case remoteNotAValidVault
    case remotePasswordMismatch
    case remoteWriteFailed(underlying: Error)
    case localWriteFailed(underlying: Error)
    /// Serializing the in-memory vault produced bytes that are not a KDBX
    /// file. Nothing is written anywhere when this is thrown.
    case serializedVaultInvalid
}

/// Connects a local vault to a remote mirror for the first time. Backend
/// agnostic: it accepts any `StorageBackend`, so the same logic later serves
/// the SFTP and local-folder connect flows. No UI, no UserDefaults.
///
/// Governing rule for every branch: never destroy a copy before its
/// replacement has been validated.
final class VaultMigrationService {
    private let fileStore: VaultFileStore
    private let cipher: KdbxCipher
    private let compression: KdbxCompression

    init(fileStore: VaultFileStore, cipher: KdbxCipher = .aes256, compression: KdbxCompression = .gzip) {
        self.fileStore = fileStore
        self.cipher = cipher
        self.compression = compression
    }

    /// Reports what the remote currently holds. Reads the whole file rather
    /// than just stat-ing it: `StorageBackend` exposes no size API, and for an
    /// iCloud folder the read also forces an evicted file to materialise, so a
    /// download timeout surfaces here instead of mid-migration.
    func probe(remote: StorageBackend) throws -> VaultMigrationTargetProbe {
        do {
            guard try remote.exists() else {
                return VaultMigrationTargetProbe(exists: false, modificationDate: nil, byteCount: nil)
            }
            let modificationDate = try remote.modificationDate()
            let data = try remote.read()
            return VaultMigrationTargetProbe(
                exists: true,
                modificationDate: modificationDate,
                byteCount: data?.count
            )
        } catch {
            throw VaultMigrationError.remoteUnreadable(underlying: error)
        }
    }

    func migrate(
        local: KdbxDatabase,
        password: String,
        remote: StorageBackend,
        strategy: VaultMigrationStrategy
    ) throws -> VaultMigrationOutcome {
        switch strategy {
        case .seedRemote, .overwriteRemote:
            return try uploadLocal(local, password: password, remote: remote, strategy: strategy)
        case .adoptRemote:
            return try adoptRemote(password: password, remote: remote)
        case .merge:
            return try mergeBothSides(local: local, password: password, remote: remote)
        }
    }

    /// `seedRemote` and `overwriteRemote` differ only in when the UI offers
    /// them; the mechanics are identical. Serialize and validate in memory
    /// first, and never touch the local file.
    private func uploadLocal(
        _ local: KdbxDatabase,
        password: String,
        remote: StorageBackend,
        strategy: VaultMigrationStrategy
    ) throws -> VaultMigrationOutcome {
        let data: Data
        do {
            data = try local.save(password: password, cipher: cipher, compression: compression)
        } catch {
            throw VaultMigrationError.serializedVaultInvalid
        }
        guard Self.looksLikeKdbx(data) else {
            throw VaultMigrationError.serializedVaultInvalid
        }
        do {
            try remote.write(data)
        } catch {
            throw VaultMigrationError.remoteWriteFailed(underlying: error)
        }
        return VaultMigrationOutcome(
            strategy: strategy,
            mergedDatabase: nil,
            remoteWritten: true,
            localReplaced: false
        )
    }

    /// Parses the remote bytes with the session password BEFORE any local
    /// write, so a wrong password or a non-vault file leaves both sides
    /// byte-identical. `VaultFileStore.save` rotates the previous local vault
    /// into `backups/`, so the replaced copy stays recoverable.
    private func adoptRemote(password: String, remote: StorageBackend) throws -> VaultMigrationOutcome {
        let remoteData: Data?
        do {
            remoteData = try remote.read()
        } catch {
            throw VaultMigrationError.remoteUnreadable(underlying: error)
        }
        guard let remoteData, Self.looksLikeKdbx(remoteData) else {
            throw VaultMigrationError.remoteNotAValidVault
        }

        let remoteDatabase: KdbxDatabase
        do {
            remoteDatabase = try KdbxDatabase.open(data: remoteData, password: password)
        } catch KdbxDatabaseError.wrongPassword {
            throw VaultMigrationError.remotePasswordMismatch
        } catch {
            throw VaultMigrationError.remoteNotAValidVault
        }

        do {
            try fileStore.save(data: remoteData)
        } catch {
            throw VaultMigrationError.localWriteFailed(underlying: error)
        }
        return VaultMigrationOutcome(
            strategy: .adoptRemote,
            mergedDatabase: remoteDatabase,
            remoteWritten: false,
            localReplaced: true
        )
    }

    /// One `SyncEngine` pass, reusing the app's merge semantics instead of a
    /// bespoke merge. The checkpoint store is deliberately in-memory and
    /// seeded with `.distantPast`: a persisted checkpoint could short-circuit
    /// this one-off pass into a plain re-upload, and a `nil` seed would do the
    /// same for any remote whose `modificationDate()` is `nil`.
    private func mergeBothSides(
        local: KdbxDatabase,
        password: String,
        remote: StorageBackend
    ) throws -> VaultMigrationOutcome {
        let engine = SyncEngine(
            remote: remote,
            checkpointStore: InMemorySyncCheckpointStore(initialCheckpoint: .distantPast)
        )
        let result: SyncResult
        do {
            result = try engine.sync(local: local, password: password, cipher: cipher, compression: compression)
        } catch KdbxDatabaseError.wrongPassword {
            throw VaultMigrationError.remotePasswordMismatch
        } catch is KdbxDatabaseError {
            throw VaultMigrationError.remoteNotAValidVault
        } catch {
            throw VaultMigrationError.remoteWriteFailed(underlying: error)
        }

        guard case .merged(let mergedDatabase) = result else {
            // `.uploadedInitial` / `.uploadedDirect`: nothing came back from
            // the remote, so the local working copy is already correct.
            return VaultMigrationOutcome(
                strategy: .merge,
                mergedDatabase: nil,
                remoteWritten: true,
                localReplaced: false
            )
        }

        let mergedData: Data
        do {
            mergedData = try mergedDatabase.save(password: password, cipher: cipher, compression: compression)
        } catch {
            throw VaultMigrationError.localWriteFailed(underlying: error)
        }
        do {
            try fileStore.save(data: mergedData)
        } catch {
            throw VaultMigrationError.localWriteFailed(underlying: error)
        }
        return VaultMigrationOutcome(
            strategy: .merge,
            mergedDatabase: mergedDatabase,
            remoteWritten: true,
            localReplaced: true
        )
    }

    /// Cheap KDBX4 signature check (`0x9AA2D903` `0xB54BFB67`, little-endian),
    /// so obvious non-vault bytes are rejected before paying for an Argon2id
    /// key derivation.
    static func looksLikeKdbx(_ data: Data) -> Bool {
        guard data.count >= 12 else { return false }
        let signature: [UInt8] = [0x03, 0xD9, 0xA2, 0x9A, 0x67, 0xFB, 0x4B, 0xB5]
        return Array(data.prefix(8)) == signature
    }
}
