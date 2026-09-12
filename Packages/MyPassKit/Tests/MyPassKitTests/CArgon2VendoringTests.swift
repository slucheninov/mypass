import XCTest
import CArgon2

/// Sanity check that the vendored C target builds and computes Argon2id
/// correctly, calling the C entry point directly — before any MyPass Swift
/// code (`KeyDerivation`, Task 2) depends on this library at all.
///
/// Uses the exact same independently-generated known-answer vector as
/// `KeyDerivationTests.testTransformedKeyMatchesIndependentArgon2idKnownAnswer`
/// (see that test's doc comment for the full `argon2-cffi` provenance:
/// secret "correct horse battery staple", salt `0x00..0x0F`, time_cost=2,
/// memory_cost=19*1024 KiB, parallelism=1, type=ID, version=19) — a vector
/// generated with a *different* Argon2id implementation (Python's
/// `argon2-cffi`, itself wrapping this same phc-winner-argon2 reference
/// code) than the one this test calls. An identical result here means the
/// vendored C sources were copied and built without alteration, and gives
/// Task 2 a foundation it can build on: this test proves the library is
/// right, Task 2's untouched test proves the Swift wrapper doesn't break it.
final class CArgon2VendoringTests: XCTestCase {
    func testArgon2idHashRawMatchesIndependentKnownAnswer() {
        let password = Array("correct horse battery staple".utf8)
        let salt = Array((0..<16).map { UInt8($0) })
        var hash = [UInt8](repeating: 0, count: 32)

        let result = password.withUnsafeBufferPointer { pwdPtr in
            salt.withUnsafeBufferPointer { saltPtr in
                hash.withUnsafeMutableBufferPointer { hashPtr in
                    argon2id_hash_raw(
                        2, UInt32(19 * 1024), 1,
                        pwdPtr.baseAddress, pwdPtr.count,
                        saltPtr.baseAddress, saltPtr.count,
                        hashPtr.baseAddress, hashPtr.count
                    )
                }
            }
        }

        XCTAssertEqual(result, ARGON2_OK.rawValue)
        let expected: [UInt8] = [
            0x81, 0x82, 0x59, 0xb6, 0x31, 0x00, 0x26, 0xa8,
            0xe0, 0xdb, 0xac, 0x5d, 0x2e, 0x69, 0x27, 0xab,
            0xcf, 0xdb, 0x07, 0xb3, 0x22, 0x58, 0xfa, 0xc4,
            0xf6, 0x1b, 0x18, 0xb8, 0x0f, 0x92, 0x90, 0x85,
        ]
        XCTAssertEqual(hash, expected)
    }
}
