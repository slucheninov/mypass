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

    private let fileStore: VaultFileStore

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
        }
    }

    func lock() {
        state = .locked
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
    }
}
