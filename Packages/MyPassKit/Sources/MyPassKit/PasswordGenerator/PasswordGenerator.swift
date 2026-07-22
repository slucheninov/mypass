import Foundation
import Security

public struct PasswordGeneratorOptions {
    public var length: Int
    public var includeLowercase: Bool
    public var includeUppercase: Bool
    public var includeDigits: Bool
    public var includeSymbols: Bool

    public init(length: Int, includeLowercase: Bool, includeUppercase: Bool, includeDigits: Bool, includeSymbols: Bool) {
        self.length = length
        self.includeLowercase = includeLowercase
        self.includeUppercase = includeUppercase
        self.includeDigits = includeDigits
        self.includeSymbols = includeSymbols
    }
}

public enum PasswordGeneratorError: Error, Equatable {
    case noCharacterClassSelected
    case secureRandomUnavailable
}

public enum PasswordGenerator {
    private static let lowercase = Array("abcdefghijklmnopqrstuvwxyz")
    private static let uppercase = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
    private static let digits = Array("0123456789")
    private static let symbols = Array("!@#$%^&*()-_=+[]{};:,.<>?")

    public static func generate(options: PasswordGeneratorOptions) throws -> String {
        var pool: [Character] = []
        if options.includeLowercase { pool.append(contentsOf: lowercase) }
        if options.includeUppercase { pool.append(contentsOf: uppercase) }
        if options.includeDigits { pool.append(contentsOf: digits) }
        if options.includeSymbols { pool.append(contentsOf: symbols) }
        guard !pool.isEmpty else { throw PasswordGeneratorError.noCharacterClassSelected }
        guard options.length > 0 else { return "" }

        // Reject bytes that would introduce modulo bias for a non-power-of-two
        // pool size: only accept bytes below the largest multiple of
        // pool.count that fits in a UInt8 range.
        let limit = UInt8(256 - (256 % pool.count))

        var result = ""
        result.reserveCapacity(options.length)
        for _ in 0..<options.length {
            let byte = try secureRandomByte(below: limit)
            result.append(pool[Int(byte) % pool.count])
        }
        return result
    }

    /// Returns a cryptographically secure random byte in `0..<limit`,
    /// rejecting biased values by re-drawing.
    private static func secureRandomByte(below limit: UInt8) throws -> UInt8 {
        while true {
            var byte: UInt8 = 0
            let status = SecRandomCopyBytes(kSecRandomDefault, 1, &byte)
            guard status == errSecSuccess else {
                throw PasswordGeneratorError.secureRandomUnavailable
            }
            if byte < limit {
                return byte
            }
        }
    }
}
