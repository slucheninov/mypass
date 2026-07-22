import Foundation
import MyPassKit

enum TOTPCode {
    private static let base32Alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

    static func base32Encode(_ data: Data) -> String {
        guard !data.isEmpty else { return "" }
        var bits = 0
        var value = 0
        var output = ""
        for byte in data {
            value = (value << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                let index = (value >> (bits - 5)) & 0x1F
                output.append(base32Alphabet[index])
                bits -= 5
            }
        }
        if bits > 0 {
            let index = (value << (5 - bits)) & 0x1F
            output.append(base32Alphabet[index])
        }
        while output.count % 8 != 0 {
            output.append("=")
        }
        return output
    }

    static func base32Decode(_ s: String) -> Data? {
        let cleaned = s.uppercased().replacingOccurrences(of: "=", with: "")
        guard !cleaned.isEmpty else { return Data() }
        var bits = 0
        var value = 0
        var output = [UInt8]()
        for character in cleaned {
            guard let index = base32Alphabet.firstIndex(of: character) else { return nil }
            value = (value << 5) | index
            bits += 5
            if bits >= 8 {
                let byte = UInt8((value >> (bits - 8)) & 0xFF)
                output.append(byte)
                bits -= 8
            }
        }
        return Data(output)
    }

    static func parse(otpauthURL: String) -> (secret: Data, digits: Int, period: TimeInterval, algorithm: TOTPAlgorithm)? {
        guard let components = URLComponents(string: otpauthURL),
              components.scheme == "otpauth",
              let queryItems = components.queryItems,
              let secretBase32 = queryItems.first(where: { $0.name == "secret" })?.value,
              let secret = base32Decode(secretBase32) else {
            return nil
        }

        let digits = queryItems.first(where: { $0.name == "digits" })?.value.flatMap(Int.init) ?? 6
        let period = queryItems.first(where: { $0.name == "period" })?.value.flatMap(Double.init) ?? 30

        let algorithmName = queryItems.first(where: { $0.name == "algorithm" })?.value?.uppercased() ?? "SHA1"
        let algorithm: TOTPAlgorithm
        switch algorithmName {
        case "SHA256": algorithm = .sha256
        case "SHA512": algorithm = .sha512
        default: algorithm = .sha1
        }

        return (secret: secret, digits: digits, period: period, algorithm: algorithm)
    }

    static func currentCode(secretBase32: String, digits: Int, period: TimeInterval, algorithm: TOTPAlgorithm, now: Date) -> String? {
        guard let secret = base32Decode(secretBase32) else { return nil }
        return TOTPGenerator.generate(secret: secret, time: now, step: period, digits: digits, algorithm: algorithm)
    }

    static func secondsRemaining(period: TimeInterval, now: Date) -> TimeInterval {
        let elapsedInPeriod = now.timeIntervalSince1970.truncatingRemainder(dividingBy: period)
        let remaining = period - elapsedInPeriod
        return remaining == period ? period : remaining
    }
}
