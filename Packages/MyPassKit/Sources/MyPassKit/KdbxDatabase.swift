import Foundation
import CryptoKit

/// Errors surfaced by `KdbxDatabase.open`/`save` — the public facade over the
/// full KDBX4 read/write pipeline (Tasks 3–14).
enum KdbxDatabaseError: Error, Equatable {
    /// The outer-header authentication (`HeaderHMAC-SHA256`) did not match —
    /// this is how a wrong password is distinguished from generic corruption,
    /// since the HMAC key is derived from the password via the KDF.
    case wrongPassword
    /// The file is truncated, has a bad checksum, or otherwise fails a
    /// structural/integrity check unrelated to the password.
    case corruptFile(String)
    /// A structurally valid field (e.g. KDF UUID, inner stream ID) names a
    /// feature this reader/writer does not implement.
    case unsupportedFeature(String)
}

/// The public facade over a KDBX4 database: reads a raw `.kdbx` file's bytes
/// into a `KdbxGroup` tree (+ tombstones), and writes them back out.
///
/// This ties together, in order:
/// 1. `KdbxSignature`/`KdbxOuterHeader` (Task 4) — parse the outer header.
/// 2. `KdbxHeaderAuthentication` (Task 5) — verify the header's own integrity
///    tag BEFORE trusting anything else in the file.
/// 3. `KeyDerivation` (Task 6) — derive `transformedKey`/`masterKey`/
///    `hmacKeyBase` from the outer header's KDF parameters and the password.
/// 4. `HmacBlockStream` (Task 7/8) — verify and strip the HMAC block framing.
/// 5. `AES256CBCCipher`/`ChaCha20StreamCipher` (Task 9/10) — decrypt the outer
///    cipher, selected by the outer header's `CipherID`.
/// 6. Decompress (gzip), if `CompressionFlags` says so.
/// 7. `KdbxInnerHeader` (Task 12) — parse the inner header from the
///    decrypted/decompressed payload.
/// 8. `InnerRandomStreamCipher` (Task 11) — construct the protected-value
///    stream cipher from the inner header's stream ID/key.
/// 9. `KdbxXmlCoder` (Task 14) — decode the XML into a `KdbxXmlPayload`.
///
/// KNOWN LIMITATION (tracked for Task 16): `gzip`/`gunzip` below use
/// `NSData.compressed(using: .zlib)`/`decompressed(using: .zlib)`, which
/// implement raw DEFLATE/zlib framing, NOT the gzip container (magic bytes
/// `1F 8B`) that KDBX4's `CompressionFlags == 1` actually specifies. This is
/// internally self-consistent (this package compresses and decompresses with
/// the same mismatched function), so `save` → `open` round-trips still work,
/// but a real gzip-compressed KDBX4 file written by KeePassXC will NOT
/// decompress correctly with this code. Task 16 replaces this with true gzip
/// framing and validates against real KeePassXC reference files.
struct KdbxDatabase {
    var rootGroup: KdbxGroup
    var deletedObjects: [KdbxDeletedObject]

    static func open(data: Data, password: String) throws -> KdbxDatabase {
        guard data.count >= 12 else {
            throw KdbxDatabaseError.corruptFile("file too short for KDBX signature")
        }

        // Step 1: Signature + Version (Task 4).
        let signatureEnd = data.index(data.startIndex, offsetBy: 12)
        do {
            _ = try KdbxSignature.parse(Data(data[data.startIndex..<signatureEnd]))
        } catch {
            throw KdbxDatabaseError.corruptFile("signature/version: \(error)")
        }

        // Step 1 (cont'd): Outer header TLV fields (Task 4). `rawHeaderStart`
        // is explicitly `data.startIndex` (NOT `signatureEnd`) so that
        // `rawHeaderBytes` spans Signature + Version + OuterHeaderFields
        // through EndOfHeader inclusive — the exact byte range that
        // `HeaderSHA256`/`HeaderHMAC-SHA256` are computed over. Passing
        // `signatureEnd` here instead would silently exclude the 12-byte
        // signature/version prefix from that range and produce a header
        // authentication that can never match a real KDBX4 file.
        var offset = signatureEnd
        let outerHeader: KdbxOuterHeader
        do {
            outerHeader = try KdbxOuterHeader.parse(from: data, startingAt: &offset, rawHeaderStart: data.startIndex)
        } catch {
            throw KdbxDatabaseError.corruptFile("outer header: \(error)")
        }
        let rawHeaderBytes = outerHeader.rawHeaderBytes

        // Step 2: Header authentication values follow immediately after the
        // outer header: HeaderSHA256 (32 bytes) then HeaderHMAC-SHA256 (32 bytes).
        guard data.distance(from: offset, to: data.endIndex) >= 64 else {
            throw KdbxDatabaseError.corruptFile("truncated header authentication values")
        }
        let storedSha256End = data.index(offset, offsetBy: 32)
        let storedSha256 = Data(data[offset..<storedSha256End])
        offset = storedSha256End
        let storedHmacEnd = data.index(offset, offsetBy: 32)
        let storedHmac = Data(data[offset..<storedHmacEnd])
        offset = storedHmacEnd

        // Verify the header's own integrity tag BEFORE trusting anything
        // else in the file (deferred here from Tasks 5/7 per design).
        guard KdbxHeaderAuthentication.sha256(ofHeader: rawHeaderBytes) == storedSha256 else {
            throw KdbxDatabaseError.corruptFile("header SHA-256 mismatch")
        }

        // Step 3: Key derivation (Task 6). Composite key for a password-only
        // database is SHA256(SHA256(passwordUTF8Bytes)) — KeePass's
        // CompositeKey hashes each sub-key (PasswordKey::rawKey() =
        // SHA256(password)) and then hashes the concatenation of all sub-key
        // hashes; with a single sub-key that concatenation is just that one
        // hash, so the composite key is the double SHA-256.
        let compositeKey = Self.compositeKey(fromPassword: password)
        let transformedKey: Data
        do {
            transformedKey = try KeyDerivation.transformedKey(compositeKey: compositeKey, kdfParameters: outerHeader.kdfParameters)
        } catch let error as KeyDerivationError {
            throw KdbxDatabaseError.unsupportedFeature("KDF: \(error)")
        }
        let hmacKeyBase = KeyDerivation.hmacKeyBase(masterSeed: outerHeader.masterSeed, transformedKey: transformedKey)

        // Header HMAC is keyed off the password-derived hmacKeyBase, so a
        // mismatch here — given the SHA-256 check above already passed —
        // means the password is wrong, not that the file is corrupt.
        guard KdbxHeaderAuthentication.hmacSHA256(ofHeader: rawHeaderBytes, hmacKeyBase: hmacKeyBase) == storedHmac else {
            throw KdbxDatabaseError.wrongPassword
        }

        let masterKey = KeyDerivation.masterKey(masterSeed: outerHeader.masterSeed, transformedKey: transformedKey)

        // Step 4: HMAC block stream (Task 7/8).
        let blockStreamData = Data(data[offset...])
        let decryptedBlocks: Data
        do {
            decryptedBlocks = try HmacBlockStream.read(blockStreamData, hmacKeyBase: hmacKeyBase)
        } catch let error as HmacBlockStreamError {
            throw KdbxDatabaseError.corruptFile("HMAC block stream: \(error)")
        }

        // Step 5: Outer cipher decrypt (Task 9/10).
        let cipherPlaintext: Data
        do {
            switch outerHeader.cipher {
            case .aes256:
                cipherPlaintext = try AES256CBCCipher.decrypt(ciphertext: decryptedBlocks, key: masterKey, iv: outerHeader.encryptionIV)
            case .chaCha20:
                cipherPlaintext = try ChaCha20StreamCipher.apply(to: decryptedBlocks, key: masterKey, nonce: outerHeader.encryptionIV)
            }
        } catch {
            throw KdbxDatabaseError.corruptFile("outer cipher decrypt: \(error)")
        }

        // Step 6: Decompress (gzip), if flagged. See the known-limitation
        // note on the type for the gzip-vs-raw-deflate caveat (Task 16).
        let decompressed: Data
        switch outerHeader.compression {
        case .none:
            decompressed = cipherPlaintext
        case .gzip:
            do {
                decompressed = try Self.gunzip(cipherPlaintext)
            } catch {
                throw KdbxDatabaseError.corruptFile("decompression: \(error)")
            }
        }

        // Step 7: Inner header (Task 12).
        var innerOffset = decompressed.startIndex
        let innerHeader: KdbxInnerHeader
        do {
            innerHeader = try KdbxInnerHeader.parse(from: decompressed, startingAt: &innerOffset)
        } catch {
            throw KdbxDatabaseError.corruptFile("inner header: \(error)")
        }
        let xmlData = Data(decompressed[innerOffset...])

        // Step 8: Inner random stream cipher (Task 11).
        let streamCipher: InnerRandomStreamCipher
        do {
            streamCipher = try InnerRandomStreamCipher(streamID: innerHeader.innerRandomStreamID, rawKey: innerHeader.innerRandomStreamKey)
        } catch let error as InnerRandomStreamCipherError {
            throw KdbxDatabaseError.unsupportedFeature("inner random stream: \(error)")
        }

        // Step 9: XML payload (Task 14).
        let payload: KdbxXmlPayload
        do {
            payload = try KdbxXmlCoder.decode(xmlData) { ciphertext in
                let keystream = streamCipher.nextBytes(ciphertext.count)
                return Data(zip(ciphertext, keystream).map { $0 ^ $1 })
            }
        } catch {
            throw KdbxDatabaseError.corruptFile("xml payload: \(error)")
        }

        return KdbxDatabase(rootGroup: payload.rootGroup, deletedObjects: payload.deletedObjects)
    }

    func save(password: String, cipher: KdbxCipher, compression: KdbxCompression) throws -> Data {
        let masterSeed = Self.randomBytes(count: 32)
        let salt = Self.randomBytes(count: 16)
        var kdfParameters = VariantDictionary()
        kdfParameters.items["$UUID"] = .byteArray(KdbxKdfUUID.argon2id)
        kdfParameters.items["S"] = .byteArray(salt)
        kdfParameters.items["M"] = .uint64(64 * 1024 * 1024) // 64 MiB
        kdfParameters.items["I"] = .uint64(3)
        kdfParameters.items["P"] = .uint32(1)
        kdfParameters.items["V"] = .uint32(0x13)

        let encryptionIV = Self.randomBytes(count: cipher == .aes256 ? 16 : 12)
        let outerHeader = KdbxOuterHeader(
            cipher: cipher, compression: compression,
            masterSeed: masterSeed, encryptionIV: encryptionIV,
            kdfParameters: kdfParameters, publicCustomData: nil, rawHeaderBytes: Data()
        )

        let compositeKey = Self.compositeKey(fromPassword: password)
        let transformedKey = try KeyDerivation.transformedKey(compositeKey: compositeKey, kdfParameters: kdfParameters)
        let masterKey = KeyDerivation.masterKey(masterSeed: masterSeed, transformedKey: transformedKey)
        let hmacKeyBase = KeyDerivation.hmacKeyBase(masterSeed: masterSeed, transformedKey: transformedKey)

        let innerStreamKey = Self.randomBytes(count: 64)
        let innerHeader = KdbxInnerHeader(innerRandomStreamID: .chaCha20, innerRandomStreamKey: innerStreamKey, binaries: [])
        let streamCipher = try InnerRandomStreamCipher(streamID: .chaCha20, rawKey: innerStreamKey)

        let payload = KdbxXmlPayload(rootGroup: rootGroup, deletedObjects: deletedObjects)
        let xmlData = KdbxXmlCoder.encode(payload) { plaintext in
            let keystream = streamCipher.nextBytes(plaintext.count)
            return Data(zip(plaintext, keystream).map { $0 ^ $1 })
        }

        var innerPlaintext = innerHeader.serialize()
        innerPlaintext.append(xmlData)

        let compressed: Data
        switch compression {
        case .none: compressed = innerPlaintext
        case .gzip: compressed = try Self.gzip(innerPlaintext)
        }

        let cipherText: Data
        switch cipher {
        case .aes256:
            cipherText = try AES256CBCCipher.encrypt(plaintext: compressed, key: masterKey, iv: encryptionIV)
        case .chaCha20:
            cipherText = try ChaCha20StreamCipher.apply(to: compressed, key: masterKey, nonce: encryptionIV)
        }

        let blockStream = HmacBlockStream.write(cipherText, hmacKeyBase: hmacKeyBase)

        var signatureAndVersion = Data()
        signatureAndVersion.append(contentsOf: withUnsafeBytes(of: UInt32(0x9AA2D903).littleEndian) { Data($0) })
        signatureAndVersion.append(contentsOf: withUnsafeBytes(of: UInt32(0xB54BFB67).littleEndian) { Data($0) })
        signatureAndVersion.append(contentsOf: withUnsafeBytes(of: UInt16(0x0000).littleEndian) { Data($0) }) // minor
        signatureAndVersion.append(contentsOf: withUnsafeBytes(of: UInt16(0x0004).littleEndian) { Data($0) }) // major

        let headerFieldBytes = outerHeader.serialize()

        // The raw byte range that HeaderSHA256/HeaderHMAC-SHA256 are computed
        // over MUST include the signature+version prefix, matching exactly
        // what `open` reconstructs via `rawHeaderStart: data.startIndex` —
        // otherwise a file written here could never re-verify its own
        // header authentication.
        var rawHeaderBytes = signatureAndVersion
        rawHeaderBytes.append(headerFieldBytes)

        var out = signatureAndVersion
        out.append(headerFieldBytes)
        out.append(KdbxHeaderAuthentication.sha256(ofHeader: rawHeaderBytes))
        out.append(KdbxHeaderAuthentication.hmacSHA256(ofHeader: rawHeaderBytes, hmacKeyBase: hmacKeyBase))
        out.append(blockStream)

        return out
    }

    // MARK: - Private helpers

    /// KeePass's CompositeKey for a password-only database: SHA256 of the
    /// SHA256 of the password's UTF-8 bytes (each sub-key contributes its own
    /// hash; with a single sub-key, "hash of the concatenation" collapses to
    /// hashing that one hash again).
    private static func compositeKey(fromPassword password: String) -> Data {
        let passwordHash = Data(SHA256.hash(data: Data(password.utf8)))
        return Data(SHA256.hash(data: passwordHash))
    }

    private static func randomBytes(count: Int) -> Data {
        var data = Data(count: count)
        _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        return data
    }

    /// KNOWN LIMITATION (see type-level doc comment and Task 16): this is raw
    /// zlib/DEFLATE framing via `NSData`, NOT the gzip container that KDBX4
    /// actually specifies for `CompressionFlags == 1`. Self-consistent for
    /// this package's own `save`/`open` round-trip; not compatible with real
    /// gzip-compressed KDBX4 files until Task 16 replaces this.
    private static func gzip(_ data: Data) throws -> Data {
        try (data as NSData).compressed(using: .zlib) as Data
    }

    private static func gunzip(_ data: Data) throws -> Data {
        try (data as NSData).decompressed(using: .zlib) as Data
    }
}
