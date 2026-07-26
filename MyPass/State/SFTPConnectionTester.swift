import Foundation
import SyncKit

enum SFTPConnectionTesterError: Error, Equatable {
    case missingConfiguration
}

/// Wraps a single `StorageBackend.exists()` call as a connectivity probe for
/// the Settings "Test connection" button. `backendFactory` defaults to
/// building a real `SFTPBackend`, but is injectable so tests can supply a
/// fake `StorageBackend` without any network/Docker dependency — this is
/// the preferred design flagged in this task's spec over gating the whole
/// type behind an integration-test environment variable.
struct SFTPConnectionTester {
    private let configurationProvider: () -> SFTPBackendConfiguration?
    private let backendFactory: (SFTPBackendConfiguration) -> StorageBackend

    init(
        configurationProvider: @escaping () -> SFTPBackendConfiguration?,
        backendFactory: @escaping (SFTPBackendConfiguration) -> StorageBackend = { config in
            SFTPBackend(configuration: config, trustedHostKeyStore: UserDefaultsTrustedHostKeyStore())
        }
    ) {
        self.configurationProvider = configurationProvider
        self.backendFactory = backendFactory
    }

    func testConnection() -> Result<Void, Error> {
        guard let configuration = configurationProvider() else {
            return .failure(SFTPConnectionTesterError.missingConfiguration)
        }
        let backend = backendFactory(configuration)
        do {
            _ = try backend.exists()
            return .success(())
        } catch {
            return .failure(error)
        }
    }
}
