import XCTest
import NIO
import NIOSSH
@testable import SyncKit

final class TrustOnFirstUseHostKeyValidatorTests: XCTestCase {
    // Real, unencrypted ed25519 keypairs generated via:
    // ssh-keygen -t ed25519 -N "" -f /tmp/hostkey_a -C "host-a"
    // ssh-keygen -t ed25519 -N "" -f /tmp/hostkey_b -C "host-b"
    // NIOSSHPublicKey's wire format (and `String(openSSHPublicKey:)`) never
    // carries the trailing OpenSSH comment field from the .pub file, so the
    // fixtures below omit it to match what the validator actually stores/compares.
    let hostAPublicKeyLine = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICwluIDLAtkcBQEjHCCSjAVTfNso7AGpm7oLDvX13MKZ"
    let hostBPublicKeyLine = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDLcvC+13rtoilJLRR9u9fcdC4R5SijkkCUcWvvqAuCV"

    func validate(_ validator: TrustOnFirstUseHostKeyValidator, publicKeyLine: String, eventLoop: EmbeddedEventLoop) throws {
        let hostKey = try NIOSSHPublicKey(openSSHPublicKey: publicKeyLine)
        let promise = eventLoop.makePromise(of: Void.self)
        validator.validateHostKey(hostKey: hostKey, validationCompletePromise: promise)
        try promise.futureResult.wait()
    }

    func testFirstConnectionTrustsAndSucceeds() throws {
        let eventLoop = EmbeddedEventLoop()
        defer { try? eventLoop.syncShutdownGracefully() }
        let store = InMemoryTrustedHostKeyStore()
        let validator = TrustOnFirstUseHostKeyValidator(host: "sftp.example.com", store: store)

        XCTAssertNil(store.trustedKey(forHost: "sftp.example.com"))
        try validate(validator, publicKeyLine: hostAPublicKeyLine, eventLoop: eventLoop)
        XCTAssertEqual(store.trustedKey(forHost: "sftp.example.com"), hostAPublicKeyLine)
    }

    func testSecondConnectionWithSameKeySucceeds() throws {
        let eventLoop = EmbeddedEventLoop()
        defer { try? eventLoop.syncShutdownGracefully() }
        let store = InMemoryTrustedHostKeyStore()
        let validator = TrustOnFirstUseHostKeyValidator(host: "sftp.example.com", store: store)

        try validate(validator, publicKeyLine: hostAPublicKeyLine, eventLoop: eventLoop)
        try validate(validator, publicKeyLine: hostAPublicKeyLine, eventLoop: eventLoop)

        XCTAssertEqual(store.trustedKey(forHost: "sftp.example.com"), hostAPublicKeyLine)
    }

    func testDifferentKeyForSameHostFails() throws {
        let eventLoop = EmbeddedEventLoop()
        defer { try? eventLoop.syncShutdownGracefully() }
        let store = InMemoryTrustedHostKeyStore()
        let validator = TrustOnFirstUseHostKeyValidator(host: "sftp.example.com", store: store)

        try validate(validator, publicKeyLine: hostAPublicKeyLine, eventLoop: eventLoop)

        XCTAssertThrowsError(try validate(validator, publicKeyLine: hostBPublicKeyLine, eventLoop: eventLoop)) { error in
            XCTAssertEqual(error as? TrustOnFirstUseError, TrustOnFirstUseError(host: "sftp.example.com"))
        }
        // The originally-trusted key must remain unchanged after a rejected attempt.
        XCTAssertEqual(store.trustedKey(forHost: "sftp.example.com"), hostAPublicKeyLine)
    }

    func testDifferentHostsAreTrustedIndependently() throws {
        let eventLoop = EmbeddedEventLoop()
        defer { try? eventLoop.syncShutdownGracefully() }
        let store = InMemoryTrustedHostKeyStore()
        let validatorA = TrustOnFirstUseHostKeyValidator(host: "host-a.example.com", store: store)
        let validatorB = TrustOnFirstUseHostKeyValidator(host: "host-b.example.com", store: store)

        try validate(validatorA, publicKeyLine: hostAPublicKeyLine, eventLoop: eventLoop)
        try validate(validatorB, publicKeyLine: hostBPublicKeyLine, eventLoop: eventLoop)

        XCTAssertEqual(store.trustedKey(forHost: "host-a.example.com"), hostAPublicKeyLine)
        XCTAssertEqual(store.trustedKey(forHost: "host-b.example.com"), hostBPublicKeyLine)
    }
}
