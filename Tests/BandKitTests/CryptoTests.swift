import XCTest
@testable import BandKit

/// Checks the hand-written primitives against published vectors (FIPS 180-4, RFC 4231, FIPS 197,
/// NIST SP 800-38A) and against values computed independently with Python's `hashlib`, `hmac` and
/// `cryptography` packages.
final class CryptoTests: XCTestCase {
    private func hex(_ text: String) -> [UInt8] { Bytes.fromHex(text)! }

    func testSHA256PublishedVectors() {
        XCTAssertEqual(Bytes.hex(SHA256.hash([])),
                       "E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855")
        XCTAssertEqual(Bytes.hex(SHA256.hash(Array("abc".utf8))),
                       "BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD")
        XCTAssertEqual(Bytes.hex(SHA256.hash(Array("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8))),
                       "248D6A61D20638B8E5C026930C3E6039A33CE45964FF2167F6ECEDD419DB06C1")
    }

    func testSHA256AcrossPaddingBoundaries() {
        // 1000 bytes exercises many blocks; the lengths around 55/56/64 exercise the padding edge.
        XCTAssertEqual(Bytes.hex(SHA256.hash([UInt8](repeating: 0xa5, count: 1000))),
                       "30C623EA6BEC69E841AEE3FC41DCB6CABBE74C11B1404BCFBB026706CE608906")
        for length in [55, 56, 57, 63, 64, 65, 119, 120] {
            XCTAssertEqual(SHA256.hash([UInt8](repeating: 0x61, count: length)).count, 32)
        }
    }

    func testHMACPublishedVectors() {
        XCTAssertEqual(Bytes.hex(SHA256.hmac(key: [UInt8](repeating: 0x0b, count: 20), message: Array("Hi There".utf8))),
                       "B0344C61D8DB38535CA8AFCEAF0BF12B881DC200C9833DA726E9376C2E32CFF7")
        XCTAssertEqual(Bytes.hex(SHA256.hmac(key: Array("Jefe".utf8), message: Array("what do ya want for nothing?".utf8))),
                       "5BDCC146BF60754E6A042426089575C75A003F089D2739839DEC58B964EC3843")
        // A key longer than one block is hashed first.
        XCTAssertEqual(Bytes.hex(SHA256.hmac(key: [UInt8](repeating: 0xaa, count: 131),
                                             message: Array("Test Using Larger Than Block-Size Key - Hash Key First".utf8))),
                       "60E431591EE0B67F0D8A26AACBF5B77F8E0BC6213728C5140546040F0EE37F54")
    }

    func testAESSingleBlockPublishedVector() throws {
        // FIPS 197 appendix C.1, read through CBC with a zero IV: the first block is plain ECB.
        let key = hex("000102030405060708090A0B0C0D0E0F")
        let plain = hex("00112233445566778899AABBCCDDEEFF")
        let cipher = try AES128.encryptCBC(plain, key: key, iv: [UInt8](repeating: 0, count: 16))
        XCTAssertEqual(Bytes.hex(cipher.prefix(16)), "69C4E0D86A7B0430D8CDB78070B4C55A")
        XCTAssertEqual(try AES128.decryptCBC(cipher, key: key, iv: [UInt8](repeating: 0, count: 16)), plain)
    }

    func testAESCBCPublishedVector() throws {
        // NIST SP 800-38A F.2.1, first two blocks.
        let key = hex("2B7E151628AED2A6ABF7158809CF4F3C")
        let iv = hex("000102030405060708090A0B0C0D0E0F")
        let plain = hex("6BC1BEE22E409F96E93D7E117393172AAE2D8A571E03AC9C9EB76FAC45AF8E51")
        let cipher = try AES128.encryptCBC(plain, key: key, iv: iv)
        XCTAssertEqual(Bytes.hex(cipher.prefix(32)),
                       "7649ABAC8119B246CEE98E9B12E9197D5086CB9B507219EE95DB113A917678B2")
    }

    func testAESCBCPaddingAgainstIndependentImplementation() throws {
        let key = hex("2B7E151628AED2A6ABF7158809CF4F3C")
        let iv = hex("0102030405060708090A0B0C0D0E0F10")
        let expected: [Int: String] = [
            0: "FF2C1B0269FDB4149972CFFE997DD7CD",
            1: "CE07A9E493BC0C5AD4CD5892E0053E65",
            15: "6B258CED9537494C52504E5A73584156",
            16: "A1273F304D209A8985D8469D4442CF1069D45D249C80F409023A38A0EAEC7AC6",
            17: "A1273F304D209A8985D8469D4442CF10B9C153E4D23190322F86802776C0D9FD",
            31: "A1273F304D209A8985D8469D4442CF107421684D9F7127291C04D738362AA18A",
            32: "A1273F304D209A8985D8469D4442CF10069BFCA346A7684AB9AEFEE80D6A101354FF773F448CF97199D09B955A0E2128",
            33: "A1273F304D209A8985D8469D4442CF10069BFCA346A7684AB9AEFEE80D6A1013FE0505F818345022A8F865A5831499C8",
            100: "A1273F304D209A8985D8469D4442CF10069BFCA346A7684AB9AEFEE80D6A101323180739D388D23D6067B60858316762"
                + "A3E852DECA6466F8F2C714EAEF4F88D6E1FF148ED73F139A7EB66FEA72C357614A550312FACD3C248CC6669561B60E04"
                + "665B0E0DE7B2FD637275A076F26652D4",
        ]
        for (length, cipherHex) in expected {
            let plain = (0..<length).map { UInt8(truncatingIfNeeded: $0 * 7 + 3) }
            let cipher = try AES128.encryptCBC(plain, key: key, iv: iv)
            XCTAssertEqual(Bytes.hex(cipher), cipherHex, "length \(length)")
            XCTAssertEqual(try AES128.decryptCBC(cipher, key: key, iv: iv), plain, "length \(length)")
        }
    }

    func testAESRejectsBadInput() {
        let key = [UInt8](repeating: 1, count: 16)
        let iv = [UInt8](repeating: 2, count: 16)
        XCTAssertThrowsError(try AES128.encryptCBC([1], key: [1, 2, 3], iv: iv))
        XCTAssertThrowsError(try AES128.encryptCBC([1], key: key, iv: [1]))
        XCTAssertThrowsError(try AES128.decryptCBC([], key: key, iv: iv))
        XCTAssertThrowsError(try AES128.decryptCBC([UInt8](repeating: 0, count: 15), key: key, iv: iv))
        // Decrypting with the wrong key must not silently return garbage as if it were valid.
        let cipher = try! AES128.encryptCBC(Array("sixteen byte msg".utf8), key: key, iv: iv)
        let wrongKey = [UInt8](repeating: 9, count: 16)
        if let garbage = try? AES128.decryptCBC(cipher, key: wrongKey, iv: iv) {
            XCTAssertNotEqual(garbage, Array("sixteen byte msg".utf8))
        }
    }

    // MARK: Handshake maths

    private let serverNonce = (0x10..<0x20).map { UInt8($0) }
    private let clientNonce = (0xa0..<0xb0).map { UInt8($0) }

    func testDigestMatchesReferenceVector() throws {
        // Known value from an existing open-source client that talks to this band.
        XCTAssertEqual(Bytes.hex(try LinkCrypto.digest(authVersion: 1, label: [], nonces: [])),
                       "BD376640CD6273FBAEA3251BF34F513DE3B5F34A95DC9B6FFDDB93AD596703B0")
    }

    func testChallengeAndResponsePerAuthVersion() throws {
        let expected: [Int: (String, String)] = [
            1: ("57D783573D7D50E1705F77A14E714E80FACDE2F35F62F0AFC00EDC3DFC60A783",
                "DD58237A48470472E66A524E180FC048502904611A8C5FDB5D434F71B9D245CD"),
            2: ("13395841C74F29B6CB1E2A775D004A4E1BBC30989C78852FE0FF197DC03EBD0B",
                "954F0CAEF40DD51F2730686DB1FE3F1378192871BF6F254EE9419AFE5959C927"),
            3: ("1400BBA5524922BEAAF47F5BC03B6754128C19096026300372DAA567794E1228",
                "EAC89088A90BF9B9AF7FC77012A6A466A4687CFF2FE1E5BA1554E6BC644C9AE0"),
        ]
        for (version, (challenge, response)) in expected {
            XCTAssertEqual(Bytes.hex(try LinkCrypto.challenge(authVersion: version, serverNonce: serverNonce, clientNonce: clientNonce)),
                           challenge, "challenge v\(version)")
            XCTAssertEqual(Bytes.hex(try LinkCrypto.expectedResponse(authVersion: version, serverNonce: serverNonce, clientNonce: clientNonce)),
                           response, "response v\(version)")
        }
        XCTAssertThrowsError(try LinkCrypto.challenge(authVersion: 9, serverNonce: serverNonce, clientNonce: clientNonce))
    }

    func testBondingKey() throws {
        XCTAssertEqual(Bytes.hex(LinkCrypto.bondingKey(authVersion: 1, deviceAddress: BandAddress("FF:FF:FF:FF:FF:CC")!)),
                       "EEFF25872ABB191A15378524AFC089E6")
        let address = BandAddress("6c:b7:49:12:34:56")!
        XCTAssertEqual(Bytes.hex(LinkCrypto.bondingKey(authVersion: 1, deviceAddress: address)),
                       "86A807AA461537E026E16CE7D62C9B42")
        XCTAssertEqual(Bytes.hex(LinkCrypto.bondingKey(authVersion: 2, deviceAddress: address)),
                       "66BF67BF9A38C7BE7F62A7D4D618F4EB")
        // Versions 2 and 3 share constants.
        XCTAssertEqual(LinkCrypto.bondingKey(authVersion: 3, deviceAddress: address),
                       LinkCrypto.bondingKey(authVersion: 2, deviceAddress: address))
    }

    func testWrappedLinkKey() throws {
        let linkKey = (0x40..<0x50).map { UInt8($0) }
        let iv = (0x01..<0x11).map { UInt8($0) }
        let wrapped = try LinkCrypto.wrapLinkKey(linkKey, authVersion: 2, deviceAddress: BandAddress("6C:B7:49:12:34:56")!, iv: iv)
        XCTAssertEqual(Bytes.hex(wrapped), "438E5BE5BF3EA72DE68552BDA5E35EBD06D3B31B9126510FB74771172E777CFC")
    }

    func testBandAddressParsing() {
        XCTAssertEqual(BandAddress("6c:b7:49:12:34:56")?.description, "6C:B7:49:12:34:56")
        XCTAssertEqual(BandAddress("6CB749123456")?.compact, "6CB749123456")
        XCTAssertEqual(BandAddress(" 6C-B7-49-12-34-56 ")?.compact, "6CB749123456")
        XCTAssertNil(BandAddress("6C:B7:49:12:34"))
        XCTAssertNil(BandAddress("6C:B7:49:12:34:5G"))
        XCTAssertNil(BandAddress(""))
        XCTAssertTrue(BandAddress("6C:B7:49:12:34:56")!.hasSuffix("456"))
        XCTAssertFalse(BandAddress("6C:B7:49:12:34:56")!.hasSuffix("457"))
    }

    func testIVSequenceCountsAndWraps() {
        struct Zeros: RandomSource { func bytes(_ count: Int) -> [UInt8] { [UInt8](repeating: 0, count: count) } }
        var sequence = IVSequence(counter: 7)
        XCTAssertEqual(sequence.next(random: Zeros()), [UInt8](repeating: 0, count: 12) + [0, 0, 0, 8])
        XCTAssertEqual(sequence.counter, 8)
        var wrapping = IVSequence(counter: UInt32.max)
        XCTAssertEqual(wrapping.next(random: Zeros()).suffix(4), [0, 0, 0, 1])
        XCTAssertEqual(SystemRandomSource().bytes(16).count, 16)
        XCTAssertNotEqual(SystemRandomSource().bytes(16), SystemRandomSource().bytes(16))
    }
}
