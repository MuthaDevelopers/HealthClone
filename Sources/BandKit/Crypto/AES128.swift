import Foundation

/// AES-128 (FIPS 197) in CBC mode with PKCS#7 padding.
///
/// This is the only cipher the Honor Band 4 uses on its link. As with
/// `SHA256`, it is written in plain Swift so the tested code is the shipped
/// code. It is table-driven and makes no attempt at constant-time behaviour;
/// that is acceptable here because the only secret is a pairing key held on
/// the user's own phone, with no remote party able to time operations.
public enum AES128 {
    public static let blockSize = 16
    public static let keySize = 16

    public enum Failure: Error, Equatable {
        case invalidKeyLength(Int)
        case invalidIVLength(Int)
        case invalidCiphertextLength(Int)
        case invalidPadding
    }

    // MARK: - CBC

    public static func encryptCBC(_ plaintext: [UInt8], key: [UInt8], iv: [UInt8]) throws -> [UInt8] {
        let roundKeys = try expandKey(key)
        guard iv.count == blockSize else { throw Failure.invalidIVLength(iv.count) }

        let padLength = blockSize - plaintext.count % blockSize
        let padded = plaintext + [UInt8](repeating: UInt8(padLength), count: padLength)

        var output = [UInt8]()
        output.reserveCapacity(padded.count)
        var previous = iv
        var offset = 0
        while offset < padded.count {
            var block = [UInt8](repeating: 0, count: blockSize)
            for i in 0..<blockSize { block[i] = padded[offset + i] ^ previous[i] }
            encryptBlock(&block, roundKeys)
            output += block
            previous = block
            offset += blockSize
        }
        return output
    }

    public static func decryptCBC(_ ciphertext: [UInt8], key: [UInt8], iv: [UInt8]) throws -> [UInt8] {
        let roundKeys = try expandKey(key)
        guard iv.count == blockSize else { throw Failure.invalidIVLength(iv.count) }
        guard !ciphertext.isEmpty, ciphertext.count % blockSize == 0 else {
            throw Failure.invalidCiphertextLength(ciphertext.count)
        }

        var output = [UInt8]()
        output.reserveCapacity(ciphertext.count)
        var previous = iv
        var offset = 0
        while offset < ciphertext.count {
            let cipherBlock = Array(ciphertext[offset..<offset + blockSize])
            var block = cipherBlock
            decryptBlock(&block, roundKeys)
            for i in 0..<blockSize { block[i] ^= previous[i] }
            output += block
            previous = cipherBlock
            offset += blockSize
        }

        guard let last = output.last, last >= 1, Int(last) <= blockSize else { throw Failure.invalidPadding }
        let padLength = Int(last)
        guard output.suffix(padLength).allSatisfy({ $0 == last }) else { throw Failure.invalidPadding }
        return Array(output.dropLast(padLength))
    }

    // MARK: - Block primitives

    private static let roundCount = 10

    /// The S-box is generated from its definition (multiplicative inverse in
    /// GF(2^8) followed by the affine transform) instead of being typed in as a
    /// 256-entry table, which removes any chance of a transcription slip.
    private static let sbox: [UInt8] = {
        var table = [UInt8](repeating: 0, count: 256)
        var p: UInt8 = 1, q: UInt8 = 1
        repeat {
            // p walks the field by multiplying by 3; q by dividing by 3, so q is always p's inverse.
            p = p ^ (p << 1) ^ ((p & 0x80) != 0 ? 0x1b : 0)
            q ^= q << 1
            q ^= q << 2
            q ^= q << 4
            if (q & 0x80) != 0 { q ^= 0x09 }
            let x = q ^ rotl8(q, 1) ^ rotl8(q, 2) ^ rotl8(q, 3) ^ rotl8(q, 4)
            table[Int(p)] = x ^ 0x63
        } while p != 1
        table[0] = 0x63
        return table
    }()

    private static let inverseSbox: [UInt8] = {
        var table = [UInt8](repeating: 0, count: 256)
        for (index, value) in sbox.enumerated() { table[Int(value)] = UInt8(index) }
        return table
    }()

    @inline(__always)
    private static func rotl8(_ value: UInt8, _ count: UInt8) -> UInt8 {
        (value << count) | (value >> (8 - count))
    }

    /// Multiplication by x in GF(2^8) modulo the AES polynomial.
    @inline(__always)
    private static func xtime(_ value: UInt8) -> UInt8 {
        (value << 1) ^ ((value & 0x80) != 0 ? 0x1b : 0)
    }

    @inline(__always)
    private static func multiply(_ a: UInt8, _ b: UInt8) -> UInt8 {
        var result: UInt8 = 0
        var x = a, y = b
        while y != 0 {
            if (y & 1) != 0 { result ^= x }
            x = xtime(x)
            y >>= 1
        }
        return result
    }

    /// Expands a 16-byte key into 11 round keys, stored flat (176 bytes).
    private static func expandKey(_ key: [UInt8]) throws -> [UInt8] {
        guard key.count == keySize else { throw Failure.invalidKeyLength(key.count) }
        var expanded = key
        expanded.reserveCapacity(blockSize * (roundCount + 1))
        var roundConstant: UInt8 = 1
        while expanded.count < blockSize * (roundCount + 1) {
            let count = expanded.count
            var word = Array(expanded[(count - 4)..<count])
            if count % keySize == 0 {
                word = [sbox[Int(word[1])] ^ roundConstant, sbox[Int(word[2])], sbox[Int(word[3])], sbox[Int(word[0])]]
                roundConstant = xtime(roundConstant)
            }
            for i in 0..<4 { expanded.append(expanded[count - keySize + i] ^ word[i]) }
        }
        return expanded
    }

    @inline(__always)
    private static func addRoundKey(_ state: inout [UInt8], _ roundKeys: [UInt8], _ round: Int) {
        let base = round * blockSize
        for i in 0..<blockSize { state[i] ^= roundKeys[base + i] }
    }

    // The state is kept in the standard column-major order: byte i sits in row i % 4, column i / 4.

    private static func encryptBlock(_ state: inout [UInt8], _ roundKeys: [UInt8]) {
        addRoundKey(&state, roundKeys, 0)
        for round in 1...roundCount {
            for i in 0..<blockSize { state[i] = sbox[Int(state[i])] }

            // ShiftRows: row r rotates left by r columns.
            let s = state
            for column in 0..<4 {
                for row in 1..<4 { state[column * 4 + row] = s[((column + row) % 4) * 4 + row] }
            }

            if round != roundCount {
                for column in 0..<4 {
                    let base = column * 4
                    let a0 = state[base], a1 = state[base + 1], a2 = state[base + 2], a3 = state[base + 3]
                    state[base] = xtime(a0) ^ (xtime(a1) ^ a1) ^ a2 ^ a3
                    state[base + 1] = a0 ^ xtime(a1) ^ (xtime(a2) ^ a2) ^ a3
                    state[base + 2] = a0 ^ a1 ^ xtime(a2) ^ (xtime(a3) ^ a3)
                    state[base + 3] = (xtime(a0) ^ a0) ^ a1 ^ a2 ^ xtime(a3)
                }
            }
            addRoundKey(&state, roundKeys, round)
        }
    }

    private static func decryptBlock(_ state: inout [UInt8], _ roundKeys: [UInt8]) {
        addRoundKey(&state, roundKeys, roundCount)
        for round in stride(from: roundCount - 1, through: 0, by: -1) {
            // Inverse ShiftRows: row r rotates right by r columns.
            let s = state
            for column in 0..<4 {
                for row in 1..<4 { state[((column + row) % 4) * 4 + row] = s[column * 4 + row] }
            }

            for i in 0..<blockSize { state[i] = inverseSbox[Int(state[i])] }
            addRoundKey(&state, roundKeys, round)

            if round != 0 {
                for column in 0..<4 {
                    let base = column * 4
                    let a0 = state[base], a1 = state[base + 1], a2 = state[base + 2], a3 = state[base + 3]
                    state[base] = multiply(a0, 14) ^ multiply(a1, 11) ^ multiply(a2, 13) ^ multiply(a3, 9)
                    state[base + 1] = multiply(a0, 9) ^ multiply(a1, 14) ^ multiply(a2, 11) ^ multiply(a3, 13)
                    state[base + 2] = multiply(a0, 13) ^ multiply(a1, 9) ^ multiply(a2, 14) ^ multiply(a3, 11)
                    state[base + 3] = multiply(a0, 11) ^ multiply(a1, 13) ^ multiply(a2, 9) ^ multiply(a3, 14)
                }
            }
        }
    }
}
