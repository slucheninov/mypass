import Foundation
import CommonCrypto

enum CipherError: Error, Equatable {
    case invalidKeyOrIVLength
    case operationFailed
}

enum AES256CBCCipher {
    static func encrypt(plaintext: Data, key: Data, iv: Data) throws -> Data {
        try crypt(input: plaintext, key: key, iv: iv, operation: CCOperation(kCCEncrypt), padding: plaintext.count % 16 == 0 ? CCOptions(0) : CCOptions(kCCOptionPKCS7Padding))
    }

    static func decrypt(ciphertext: Data, key: Data, iv: Data) throws -> Data {
        try crypt(input: ciphertext, key: key, iv: iv, operation: CCOperation(kCCDecrypt), padding: CCOptions(kCCOptionPKCS7Padding))
    }

    private static func crypt(input: Data, key: Data, iv: Data, operation: CCOperation, padding: CCOptions) throws -> Data {
        guard key.count == kCCKeySizeAES256, iv.count == kCCBlockSizeAES128 else {
            throw CipherError.invalidKeyOrIVLength
        }
        var outLength = 0
        var outBuffer = [UInt8](repeating: 0, count: input.count + kCCBlockSizeAES128)

        let status = outBuffer.withUnsafeMutableBytes { outPtr in
            input.withUnsafeBytes { inPtr in
                iv.withUnsafeBytes { ivPtr in
                    key.withUnsafeBytes { keyPtr in
                        CCCrypt(operation,
                                CCAlgorithm(kCCAlgorithmAES),
                                padding,
                                keyPtr.baseAddress, key.count,
                                ivPtr.baseAddress,
                                inPtr.baseAddress, input.count,
                                outPtr.baseAddress, outPtr.count,
                                &outLength)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw CipherError.operationFailed }
        return Data(outBuffer.prefix(outLength))
    }
}
