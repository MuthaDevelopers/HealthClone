import Foundation

/// Small helpers for the big-endian byte twiddling the link protocol needs.
public enum Bytes {
    public static func be16(_ value: Int) -> [UInt8] {
        [UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]
    }

    public static func be32(_ value: Int) -> [UInt8] {
        [
            UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value),
        ]
    }

    /// Reads an unsigned big-endian integer of 1 to 8 bytes.
    public static func unsigned<S: Sequence>(_ bytes: S) -> UInt64 where S.Element == UInt8 {
        var result: UInt64 = 0
        for byte in bytes { result = (result << 8) | UInt64(byte) }
        return result
    }

    public static func hex<S: Sequence>(_ bytes: S, separator: String = "") -> String where S.Element == UInt8 {
        bytes.map { byte in
            let text = String(byte, radix: 16, uppercase: true)
            return text.count == 1 ? "0" + text : text
        }.joined(separator: separator)
    }

    /// Parses a hex string, ignoring spaces, colons and dashes. Returns nil on any other character
    /// or an odd number of digits.
    public static func fromHex(_ text: String) -> [UInt8]? {
        var digits = [UInt8]()
        for scalar in text.unicodeScalars {
            switch scalar {
            case " ", ":", "-", "\n", "\t": continue
            case "0"..."9": digits.append(UInt8(scalar.value - 48))
            case "a"..."f": digits.append(UInt8(scalar.value - 87))
            case "A"..."F": digits.append(UInt8(scalar.value - 55))
            default: return nil
            }
        }
        guard digits.count % 2 == 0 else { return nil }
        return stride(from: 0, to: digits.count, by: 2).map { digits[$0] << 4 | digits[$0 + 1] }
    }
}

/// Source of random bytes, injectable so tests can make the handshake deterministic.
public protocol RandomSource: Sendable {
    func bytes(_ count: Int) -> [UInt8]
}

/// Uses the operating system's cryptographically secure generator.
public struct SystemRandomSource: RandomSource {
    public init() {}

    public func bytes(_ count: Int) -> [UInt8] {
        var generator = SystemRandomNumberGenerator()
        return (0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
    }
}
