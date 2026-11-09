import Foundation

/// SHA-256 (FIPS 180-4) and HMAC-SHA256 (RFC 2104).
///
/// The band's handshake needs these two primitives. They are implemented here
/// in plain Swift rather than through CryptoKit so that the exact code that
/// ships in the app is the code the Linux unit tests exercise against the
/// published test vectors.
public enum SHA256 {
    public static let blockSize = 64
    public static let digestSize = 32

    private static let roundConstants: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    public static func hash(_ message: [UInt8]) -> [UInt8] {
        var state: [UInt32] = [
            0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
            0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
        ]

        // Padding: a single 1 bit, zeros, then the bit length as a 64-bit big-endian integer.
        var padded = message
        let bitLength = UInt64(message.count) &* 8
        padded.append(0x80)
        while padded.count % blockSize != 56 { padded.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) {
            padded.append(UInt8(truncatingIfNeeded: bitLength >> UInt64(shift)))
        }

        var schedule = [UInt32](repeating: 0, count: 64)
        var offset = 0
        while offset < padded.count {
            for i in 0..<16 {
                let base = offset + i * 4
                schedule[i] = UInt32(padded[base]) << 24 | UInt32(padded[base + 1]) << 16
                    | UInt32(padded[base + 2]) << 8 | UInt32(padded[base + 3])
            }
            for i in 16..<64 {
                let w15 = schedule[i - 15], w2 = schedule[i - 2]
                let s0 = rotr(w15, 7) ^ rotr(w15, 18) ^ (w15 >> 3)
                let s1 = rotr(w2, 17) ^ rotr(w2, 19) ^ (w2 >> 10)
                schedule[i] = schedule[i - 16] &+ s0 &+ schedule[i - 7] &+ s1
            }

            var a = state[0], b = state[1], c = state[2], d = state[3]
            var e = state[4], f = state[5], g = state[6], h = state[7]
            for i in 0..<64 {
                let big1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let choice = (e & f) ^ (~e & g)
                let t1 = h &+ big1 &+ choice &+ roundConstants[i] &+ schedule[i]
                let big0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let majority = (a & b) ^ (a & c) ^ (b & c)
                let t2 = big0 &+ majority
                h = g; g = f; f = e; e = d &+ t1
                d = c; c = b; b = a; a = t1 &+ t2
            }
            state[0] = state[0] &+ a; state[1] = state[1] &+ b
            state[2] = state[2] &+ c; state[3] = state[3] &+ d
            state[4] = state[4] &+ e; state[5] = state[5] &+ f
            state[6] = state[6] &+ g; state[7] = state[7] &+ h
            offset += blockSize
        }

        var digest = [UInt8]()
        digest.reserveCapacity(digestSize)
        for word in state {
            digest.append(UInt8(truncatingIfNeeded: word >> 24))
            digest.append(UInt8(truncatingIfNeeded: word >> 16))
            digest.append(UInt8(truncatingIfNeeded: word >> 8))
            digest.append(UInt8(truncatingIfNeeded: word))
        }
        return digest
    }

    public static func hmac(key: [UInt8], message: [UInt8]) -> [UInt8] {
        var blockKey = key.count > blockSize ? hash(key) : key
        blockKey += [UInt8](repeating: 0, count: blockSize - blockKey.count)
        let inner = blockKey.map { $0 ^ 0x36 }
        let outer = blockKey.map { $0 ^ 0x5c }
        return hash(outer + hash(inner + message))
    }

    @inline(__always)
    private static func rotr(_ value: UInt32, _ count: UInt32) -> UInt32 {
        (value >> count) | (value << (32 - count))
    }
}
