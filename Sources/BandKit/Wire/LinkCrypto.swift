import Foundation

/// The cryptographic steps of the band's pairing handshake and the per-command encryption.
///
/// Three things happen when a phone pairs with the band:
///
/// 1. *Authentication.* Both sides prove they know a fixed, model-wide secret by exchanging
///    HMAC digests over a pair of nonces. This gives no real security; it only gates the protocol.
/// 2. *Bonding.* The phone invents a 16-byte link key and sends it to the band, encrypted under a
///    key derived from fixed constants and the band's own Bluetooth address.
/// 3. *Commands.* From then on every command body is AES-CBC encrypted under the link key.
public enum LinkCrypto {
    public static let nonceLength = 16

    public enum Failure: Error, Equatable {
        case unsupportedAuthVersion(Int)
        case invalidAddress(String)
        case missingCipherFields
    }

    // MARK: Authentication

    private static let digestSecrets: [Int: [UInt8]] = [
        1: [0x70, 0xfb, 0x6c, 0x24, 0x03, 0x5f, 0xdb, 0x55, 0x2f, 0x38, 0x89, 0x8a, 0xee, 0xde, 0x3f, 0x69],
        2: [0x93, 0xac, 0xde, 0xf7, 0x6a, 0xcb, 0x09, 0x85, 0x7d, 0xbf, 0xe5, 0x26, 0x1a, 0xab, 0xcd, 0x78],
        3: [0x9c, 0x27, 0x63, 0xa9, 0xcc, 0xe1, 0x34, 0x76, 0x6d, 0xe3, 0xff, 0x61, 0x18, 0x20, 0x05, 0x53],
    ]

    private static func digestSecret(authVersion: Int) throws -> [UInt8] {
        // Version 4 reuses the version 1 secret.
        guard let secret = digestSecrets[authVersion == 4 ? 1 : authVersion] else {
            throw Failure.unsupportedAuthVersion(authVersion)
        }
        return secret
    }

    /// `HMAC(HMAC(secret ‖ label, nonces), nonces)`.
    static func digest(authVersion: Int, label: [UInt8], nonces: [UInt8]) throws -> [UInt8] {
        let key = try digestSecret(authVersion: authVersion) + label
        let inner = SHA256.hmac(key: key, message: nonces)
        return SHA256.hmac(key: inner, message: nonces)
    }

    /// What the phone sends to prove itself. `nonces` is the band's nonce followed by the phone's.
    public static func challenge(authVersion: Int, serverNonce: [UInt8], clientNonce: [UInt8]) throws -> [UInt8] {
        let label: [UInt8] = authVersion == 4 ? [0x04, 0x00] : [0x01, 0x00]
        return try digest(authVersion: authVersion, label: label, nonces: serverNonce + clientNonce)
    }

    /// What the band must answer with to prove itself.
    public static func expectedResponse(authVersion: Int, serverNonce: [UInt8], clientNonce: [UInt8]) throws -> [UInt8] {
        try digest(authVersion: authVersion, label: [0x01, 0x10], nonces: serverNonce + clientNonce)
    }

    // MARK: Bonding

    private static let mixKeysV1: ([UInt8], [UInt8]) = (
        [0x6f, 0x75, 0x6a, 0x79, 0x6d, 0x77, 0x71, 0x34, 0x63, 0x6c, 0x76, 0x39, 0x33, 0x37, 0x38, 0x79],
        [0x62, 0x31, 0x30, 0x6a, 0x67, 0x66, 0x64, 0x39, 0x79, 0x37, 0x76, 0x73, 0x75, 0x64, 0x61, 0x39]
    )
    private static let mixKeysV2: ([UInt8], [UInt8]) = (
        [0x55, 0x53, 0x86, 0xfc, 0x63, 0x20, 0x07, 0xaa, 0x86, 0x49, 0x35, 0x22, 0xb8, 0x6a, 0xe2, 0x5c],
        [0x33, 0x07, 0x9b, 0xc5, 0x7a, 0x88, 0x6d, 0x3c, 0xf5, 0x61, 0x37, 0x09, 0x6f, 0x22, 0x80, 0x00]
    )

    /// The key that protects the link key in transit during bonding.
    ///
    /// It depends on the band's Bluetooth address, which is why the app has to know that address:
    /// with the wrong one the band decrypts a different link key and nothing after bonding works.
    public static func bondingKey(authVersion: Int, deviceAddress: BandAddress) -> [UInt8] {
        let (left, right) = authVersion == 1 ? mixKeysV1 : mixKeysV2
        let addressKey = Array((deviceAddress.compact + "0000").utf8)

        let mixed = (0..<16).map { (left[$0] << 4) ^ right[$0] }
        let mixedHash = SHA256.hash(mixed)
        let final = (0..<16).map { (mixedHash[$0] >> 6) ^ addressKey[$0] }
        return Array(SHA256.hash(final).prefix(16))
    }

    /// The link key encrypted for the bonding request.
    public static func wrapLinkKey(_ linkKey: [UInt8], authVersion: Int, deviceAddress: BandAddress, iv: [UInt8]) throws -> [UInt8] {
        try AES128.encryptCBC(linkKey, key: bondingKey(authVersion: authVersion, deviceAddress: deviceAddress), iv: iv)
    }

    // MARK: Command encryption

    static let tagEncrypted: UInt8 = 0x7c
    static let tagIV: UInt8 = 0x7d
    static let tagCiphertext: UInt8 = 0x7e

    /// Wraps a plain command body in the three-element encryption envelope.
    public static func seal(_ plain: [UInt8], key: [UInt8], iv: [UInt8]) throws -> [UInt8] {
        let ciphertext = try AES128.encryptCBC(plain, key: key, iv: iv)
        return TLV()
            .adding(tagEncrypted, byte: 1)
            .adding(tagIV, bytes: iv)
            .adding(tagCiphertext, bytes: ciphertext)
            .serialized()
    }

    /// Whether a body is an encryption envelope.
    public static func isSealed(_ body: TLV) -> Bool {
        body.bytes(tagEncrypted) == [1]
    }

    /// Opens an encryption envelope and returns the plain command body.
    public static func open(_ body: TLV, key: [UInt8]) throws -> [UInt8] {
        guard let iv = body.bytes(tagIV), let ciphertext = body.bytes(tagCiphertext) else {
            throw Failure.missingCipherFields
        }
        return try AES128.decryptCBC(ciphertext, key: key, iv: iv)
    }
}

/// Produces the initialisation vector for each encrypted command.
///
/// The band hands over a 32-bit counter when bonding parameters are exchanged. Each IV is twelve
/// random bytes followed by the next counter value; the counter skips zero when it wraps.
public struct IVSequence: Equatable, Sendable {
    public private(set) var counter: UInt32

    public init(counter: UInt32 = 0) {
        self.counter = counter
    }

    public mutating func next(random: RandomSource) -> [UInt8] {
        counter = counter == UInt32.max ? 1 : counter + 1
        return random.bytes(12) + Bytes.be32(Int(counter))
    }
}

/// A Bluetooth device address such as `6C:B7:49:12:34:56`.
public struct BandAddress: Equatable, Hashable, Sendable, Codable, CustomStringConvertible {
    /// Twelve upper-case hex digits, no separators.
    public let compact: String

    /// Accepts the address with or without separators, in either case.
    public init?(_ text: String) {
        guard let bytes = Bytes.fromHex(text.trimmingCharacters(in: .whitespacesAndNewlines)), bytes.count == 6 else {
            return nil
        }
        compact = Bytes.hex(bytes)
    }

    /// Colon-separated form.
    public var description: String {
        var parts = [String]()
        var index = compact.startIndex
        while index < compact.endIndex {
            let next = compact.index(index, offsetBy: 2)
            parts.append(String(compact[index..<next]))
            index = next
        }
        return parts.joined(separator: ":")
    }

    /// True if the address ends with the given hex digits, ignoring case. The band advertises the
    /// last three digits of its address in its name, which lets the app catch typing mistakes.
    public func hasSuffix(_ hexDigits: String) -> Bool {
        compact.hasSuffix(hexDigits.uppercased())
    }
}
