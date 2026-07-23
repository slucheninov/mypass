import XCTest
@testable import SyncKit

final class InMemoryStorageBackendTests: XCTestCase {
    func testExistsIsFalseWhenNoDataWritten() throws {
        let backend = InMemoryStorageBackend()
        XCTAssertFalse(try backend.exists())
        XCTAssertNil(try backend.read())
        XCTAssertNil(try backend.modificationDate())
    }

    func testWriteThenReadRoundTrips() throws {
        let backend = InMemoryStorageBackend()
        let payload = Data("hello sync".utf8)
        try backend.write(payload)
        XCTAssertEqual(try backend.read(), payload)
        XCTAssertTrue(try backend.exists())
    }

    func testModificationDateIsSetAfterWriteAndAdvancesOnSecondWrite() throws {
        let backend = InMemoryStorageBackend()
        try backend.write(Data("v1".utf8))
        let firstDate = try backend.modificationDate()
        XCTAssertNotNil(firstDate)

        Thread.sleep(forTimeInterval: 0.01)
        try backend.write(Data("v2".utf8))
        let secondDate = try backend.modificationDate()
        XCTAssertNotNil(secondDate)
        XCTAssertGreaterThan(secondDate!, firstDate!)
    }

    func testInitialDataIsReadableImmediately() throws {
        let seed = Data("seeded".utf8)
        let backend = InMemoryStorageBackend(initialData: seed)
        XCTAssertTrue(try backend.exists())
        XCTAssertEqual(try backend.read(), seed)
    }

    func testWriteErrorIsThrownWhenInjected() {
        struct InjectedError: Error, Equatable {}
        let backend = InMemoryStorageBackend()
        backend.writeError = InjectedError()
        XCTAssertThrowsError(try backend.write(Data("x".utf8))) { error in
            XCTAssertTrue(error is InjectedError)
        }
        // A failed write must not corrupt existing state.
        XCTAssertNoThrow(try backend.exists())
    }

    func testWriteErrorClearedAllowsSubsequentWriteToSucceed() throws {
        struct InjectedError: Error {}
        let backend = InMemoryStorageBackend()
        backend.writeError = InjectedError()
        XCTAssertThrowsError(try backend.write(Data("x".utf8)))
        backend.writeError = nil
        try backend.write(Data("y".utf8))
        XCTAssertEqual(try backend.read(), Data("y".utf8))
    }
}
