import Foundation
import MyPassKit

enum VaultState {
    case locked
    case unlocked(KdbxDatabase)
}

extension VaultState: Equatable {
    static func == (lhs: VaultState, rhs: VaultState) -> Bool {
        switch (lhs, rhs) {
        case (.locked, .locked): return true
        case (.unlocked, .unlocked): return true
        default: return false
        }
    }
}

enum VaultSessionError: Error {
    case notUnlocked
}

final class VaultSession: ObservableObject {
    @Published private(set) var state: VaultState = .locked
    @Published private(set) var lastSaveError: String?

    private let fileStore: VaultFileStore

    /// Retained for the lifetime of the unlocked session so every mutation can be
    /// autosaved without re-prompting the user. Wiped on `lock()`.
    private var sessionPassword: String?

    init(fileStore: VaultFileStore) {
        self.fileStore = fileStore
    }

    var currentDatabase: KdbxDatabase? {
        guard case .unlocked(let db) = state else { return nil }
        return db
    }

    func unlock(password: String) throws {
        if let existingData = try fileStore.load() {
            let db = try KdbxDatabase.open(data: existingData, password: password)
            state = .unlocked(db)
            sessionPassword = password
        } else {
            let now = Date()
            let rootGroup = KdbxGroup(
                uuid: UUID(),
                name: "MyPass",
                iconID: 0,
                creationTime: now,
                lastModificationTime: now,
                locationChanged: now,
                entries: [],
                subgroups: []
            )
            let db = KdbxDatabase(rootGroup: rootGroup, deletedObjects: [])
            state = .unlocked(db)
            try save(password: password)
            sessionPassword = password
        }
    }

    func lock() {
        state = .locked
        sessionPassword = nil
    }

    func save(password: String) throws {
        guard case .unlocked(let db) = state else {
            throw VaultSessionError.notUnlocked
        }
        let data = try db.save(password: password, cipher: .aes256, compression: .gzip)
        try fileStore.save(data: data)
    }

    func mutate(_ body: (inout KdbxDatabase) -> Void) {
        guard case .unlocked(var db) = state else { return }
        body(&db)
        state = .unlocked(db)
        persist(db)
    }

    /// Dismisses a surfaced save-error alert without affecting vault state.
    func acknowledgeSaveError() {
        lastSaveError = nil
    }

    private func persist(_ db: KdbxDatabase) {
        guard let sessionPassword else { return }
        do {
            let data = try db.save(password: sessionPassword, cipher: .aes256, compression: .gzip)
            try fileStore.save(data: data)
            lastSaveError = nil
        } catch {
            lastSaveError = "Не удалось сохранить изменения: \(error)"
        }
    }
}
