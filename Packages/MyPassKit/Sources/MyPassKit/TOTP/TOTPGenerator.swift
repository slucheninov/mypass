import Foundation
import CryptoKit

/// HMAC algorithm used to compute an HOTP/TOTP value.
public enum TOTPAlgorithm {
    case sha1
    case sha256
    case sha512
}

/// RFC 6238 (TOTP: Time-Based One-Time Password Algorithm) implementation.
///
/// Builds on RFC 4226 (HOTP) by deriving the moving factor from the current
/// Unix time rather than a counter: `counter = floor(unixTime / step)`.
public enum TOTPGenerator {
    /// Generates a TOTP code for the given shared secret and point in time.
    ///
    /// - Parameters:
    ///   - secret: The shared secret (already decoded, e.g. from Base32), as raw bytes.
    ///   - time: The point in time to compute the code for.
    ///   - step: The time step in seconds (commonly 30).
    ///   - digits: The number of digits in the resulting code (commonly 6).
    ///   - algorithm: The HMAC hash algorithm to use.
    /// - Returns: A zero-padded decimal string with `digits` characters.
    public static func generate(
        secret: Data,
        time: Date,
        step: TimeInterval,
        digits: Int,
        algorithm: TOTPAlgorithm
    ) -> String {
        let counter = UInt64(time.timeIntervalSince1970 / step)
        let counterBytes = withUnsafeBytes(of: counter.bigEndian) { Data($0) }
        let key = SymmetricKey(data: secret)

        let hmac: Data
        switch algorithm {
        case .sha1:
            hmac = Data(HMAC<Insecure.SHA1>.authenticationCode(for: counterBytes, using: key))
        case .sha256:
            hmac = Data(HMAC<SHA256>.authenticationCode(for: counterBytes, using: key))
        case .sha512:
            hmac = Data(HMAC<SHA512>.authenticationCode(for: counterBytes, using: key))
        }

        // RFC 4226 dynamic truncation.
        let offset = Int(hmac[hmac.count - 1] & 0x0F)
        let truncatedBytes = hmac[offset..<(offset + 4)]
        let binCode = truncatedBytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } & 0x7FFF_FFFF

        let modulus = UInt32(pow(10.0, Double(digits)))
        let code = binCode % modulus
        return String(format: "%0\(digits)d", code)
    }
}
