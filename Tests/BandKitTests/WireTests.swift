import XCTest
@testable import BandKit

final class WireTests: XCTestCase {
    private func hex(_ text: String) -> [UInt8] { Bytes.fromHex(text)! }

    // MARK: Bytes

    func testHexRoundTrip() {
        XCTAssertEqual(Bytes.hex([0x00, 0x0f, 0xa0, 0xff]), "000FA0FF")
        XCTAssertEqual(Bytes.hex([0x5a, 0x01], separator: " "), "5A 01")
        XCTAssertEqual(Bytes.fromHex("5a 00:0B-ff")!, [0x5a, 0x00, 0x0b, 0xff])
        XCTAssertNil(Bytes.fromHex("5"))
        XCTAssertNil(Bytes.fromHex("zz"))
        XCTAssertEqual(Bytes.be16(0x1234), [0x12, 0x34])
        XCTAssertEqual(Bytes.be32(0x01020304), [1, 2, 3, 4])
        XCTAssertEqual(Bytes.unsigned([0xca, 0xfe, 0xbe, 0xef]), 0xcafe_beef)
    }

    func testCRC16() {
        // The standard check value for CRC-16/XMODEM.
        XCTAssertEqual(CRC16.checksum(Array("123456789".utf8)), 0x31c3)
        XCTAssertEqual(CRC16.checksum([UInt8]()), 0)
    }

    // MARK: TLV

    func testLengthEncoding() {
        let cases: [(Int, [UInt8])] = [
            (0, [0x00]), (1, [0x01]), (127, [0x7f]), (128, [0x81, 0x00]),
            (8193, [0xc0, 0x01]), (16383, [0xff, 0x7f]), (16384, [0x81, 0x80, 0x00]),
        ]
        for (length, encoded) in cases {
            XCTAssertEqual(TLV.encodeLength(length), encoded, "length \(length)")
        }
    }

    func testTLVRoundTripIncludingLongValues() throws {
        for length in [0, 1, 127, 128, 300, 16384] {
            let value = (0..<length).map { UInt8(truncatingIfNeeded: $0) }
            let tlv = TLV().adding(0x01, bytes: value).adding(0x02, byte: 9)
            let parsed = try TLV(parsing: tlv.serialized())
            XCTAssertEqual(parsed, tlv, "length \(length)")
            XCTAssertEqual(parsed.bytes(0x01), value)
            XCTAssertEqual(parsed.unsigned(0x02), 9)
        }
    }

    func testTLVBuildersAndReaders() throws {
        let inner = TLV().adding(0x02, uint16: 0x1337).adding(0x03, uint32: 0xcafe_beef)
        let tlv = TLV()
            .adding(0x01)
            .adding(0x04, bool: true)
            .adding(0x05, string: "héllo")
            .adding(0x81, nested: inner)
            .adding(0x83, nested: TLV().adding(0x04, byte: 6))
            .adding(0x83, nested: TLV().adding(0x04, byte: 7))

        XCTAssertEqual(tlv.serialized().prefix(5), [0x01, 0x00, 0x04, 0x01, 0x01])
        let parsed = try TLV(parsing: tlv.serialized())
        XCTAssertTrue(parsed.contains(0x01))
        XCTAssertFalse(parsed.contains(0x09))
        XCTAssertEqual(parsed.bytes(0x01), [])
        XCTAssertNil(parsed.unsigned(0x01), "an empty value is not a number")
        XCTAssertEqual(parsed.unsigned(0x04), 1)
        XCTAssertEqual(parsed.string(0x05), "héllo")
        XCTAssertEqual(parsed.nested(0x81)?.unsigned(0x02), 0x1337)
        XCTAssertEqual(parsed.nested(0x81)?.unsigned(0x03), 0xcafe_beef)
        XCTAssertEqual(parsed.allNested(0x83).map { $0.unsigned(0x04) }, [6, 7])
        XCTAssertNil(parsed.nested(0x90))
        XCTAssertEqual(parsed.description, "01 04=01 05=68C3A96C6C6F 81={02=1337 03=CAFEBEEF} 83={04=06} 83={04=07}")
    }

    func testTLVParsingEdgeCases() throws {
        XCTAssertEqual(try TLV(parsing: []).items, [])
        XCTAssertEqual(try TLV(parsing: hex("01 00 02 00 03 00 04 00")).items.map(\.tag), [1, 2, 3, 4])
        // One stray trailing zero byte is tolerated.
        XCTAssertEqual(try TLV(parsing: hex("01 01 05 00")).items, [TLVItem(tag: 1, value: [5])])
        // A zero tag that is followed by a length is a real element, not padding.
        XCTAssertEqual(try TLV(parsing: hex("00 01 05")).items, [TLVItem(tag: 0, value: [5])])
        XCTAssertThrowsError(try TLV(parsing: hex("01 05 00"))) { error in
            XCTAssertEqual(error as? TLV.Failure, .truncated(tag: 1, needed: 5, available: 1))
        }
        XCTAssertThrowsError(try TLV(parsing: hex("01"))) { error in
            XCTAssertEqual(error as? TLV.Failure, .badLength(tag: 1))
        }
        XCTAssertThrowsError(try TLV(parsing: hex("01 FF FF FF FF FF 00")))
    }

    // MARK: Framing

    func testEncodeMatchesReferenceFrame() {
        let message = Message(service: 1, command: 2, tlv: TLV().adding(3, string: "abc"))
        XCTAssertEqual(Frame.encode(message), [hex("5A 00 08 00 01 02 03 03 61 62 63 E1 D3")])
    }

    func testLinkParametersRequestFrame() {
        let body = TLV().adding(1).adding(2).adding(3).adding(4)
        let frames = Frame.encode(Message(service: 1, command: 1, tlv: body))
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].prefix(14), hex("5A 00 0B 00 01 01 01 00 02 00 03 00 04 00")[...])
        XCTAssertEqual(frames[0].count, 16, "must fit a single 20-byte write")
    }

    func testDecodeWholeFrame() {
        var decoder = FrameDecoder()
        let outputs = decoder.feed(hex("5A 00 08 00 01 02 03 03 61 62 63 E1 D3"))
        XCTAssertEqual(outputs, [.message(Message(service: 1, command: 2, body: hex("03 03 61 62 63")))])
        XCTAssertFalse(decoder.hasPartialData)
    }

    func testDecodeFrameSplitAcrossNotificationsAtEveryPosition() {
        let frame = hex("5A 00 08 00 01 02 03 03 61 62 63 E1 D3")
        for split in 1..<frame.count {
            var decoder = FrameDecoder()
            XCTAssertEqual(decoder.feed(Array(frame[..<split])), [], "split \(split)")
            XCTAssertTrue(decoder.hasPartialData)
            XCTAssertEqual(decoder.feed(Array(frame[split...])),
                           [.message(Message(service: 1, command: 2, body: hex("03 03 61 62 63")))], "split \(split)")
        }
    }

    func testDecodeSeveralFramesInOneNotification() {
        let first = Frame.encode(Message(service: 1, command: 8, tlv: TLV().adding(1, byte: 55)))[0]
        let second = Frame.encode(Message(service: 7, command: 3, tlv: TLV().adding(1)))[0]
        var decoder = FrameDecoder()
        let outputs = decoder.feed(first + second + Array(first.prefix(4)))
        XCTAssertEqual(outputs, [
            .message(Message(service: 1, command: 8, body: [1, 1, 55])),
            .message(Message(service: 7, command: 3, body: [1, 0])),
        ])
        XCTAssertTrue(decoder.hasPartialData)
        XCTAssertEqual(decoder.feed(Array(first.dropFirst(4))), [.message(Message(service: 1, command: 8, body: [1, 1, 55]))])
    }

    func testSlicingRoundTrip() {
        for bodyLength in [0, 1, 200, 235, 236, 237, 238, 500, 1000, 3000] {
            for sliceSize in [0xf4, 64, 20] {
                let body = (0..<bodyLength).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }
                let message = Message(service: 0x17, command: 0x0c, body: body)
                let frames = Frame.encode(message, sliceSize: sliceSize)
                let limit = max(sliceSize, 32)
                XCTAssertTrue(frames.allSatisfy { $0.count <= limit }, "body \(bodyLength) slice \(sliceSize)")

                var decoder = FrameDecoder()
                var outputs = [FrameDecoder.Output]()
                for frame in frames { outputs += decoder.feed(frame) }
                XCTAssertEqual(outputs, [.message(message)], "body \(bodyLength) slice \(sliceSize)")
                XCTAssertFalse(decoder.hasPartialData)
            }
        }
    }

    func testSlicedFrameLayout() {
        // 237 payload bytes are the most that fit in one 244-byte slice; one more forces two slices.
        let fits = Frame.encode(Message(service: 1, command: 2, body: [UInt8](repeating: 0xaa, count: 235)))
        XCTAssertEqual(fits.count, 1)
        XCTAssertEqual(fits[0][3], 0, "an unsliced frame has marker 0")

        let spills = Frame.encode(Message(service: 1, command: 2, body: [UInt8](repeating: 0xaa, count: 236)))
        XCTAssertEqual(spills.count, 2)
        XCTAssertEqual(Array(spills[0][0..<7]), [0x5a, 0x00, 0xef, 0x01, 0x00, 0x01, 0x02], "first slice: marker 1, index 0, then ids")
        XCTAssertEqual(spills[0].count, 0xf4)
        XCTAssertEqual(Array(spills[1][0..<5]), [0x5a, 0x00, 0x03, 0x03, 0x01], "last slice: marker 3, index 1")

        let three = Frame.encode(Message(service: 1, command: 2, body: [UInt8](repeating: 0xaa, count: 600)))
        XCTAssertEqual(three.map { $0[3] }, [1, 2, 3])
        XCTAssertEqual(three.map { $0[4] }, [0, 1, 2])
    }

    func testDecoderRecoversFromGarbage() {
        let good = Frame.encode(Message(service: 1, command: 8, tlv: TLV().adding(1, byte: 55)))[0]
        var decoder = FrameDecoder()

        XCTAssertEqual(decoder.feed([0x00, 0x01, 0x02]), [.failure(.badMagic(0x00))])
        XCTAssertFalse(decoder.hasPartialData)
        XCTAssertEqual(decoder.feed(good), [.message(Message(service: 1, command: 8, body: [1, 1, 55]))])

        var corrupted = good
        corrupted[5] ^= 0xff
        let outputs = decoder.feed(corrupted)
        XCTAssertEqual(outputs.count, 1)
        guard case .failure(.badChecksum) = outputs[0] else { return XCTFail("expected a checksum failure") }
        XCTAssertEqual(decoder.feed(good), [.message(Message(service: 1, command: 8, body: [1, 1, 55]))])

        XCTAssertEqual(decoder.feed([0x5a, 0x00, 0x00]), [.failure(.badLength(0))])
        XCTAssertEqual(decoder.feed([0x5a, 0xff, 0xff]), [.failure(.badLength(0xffff))])

        // A continuation slice with no first slice is reported and skipped, not treated as a message.
        let slices = Frame.encode(Message(service: 1, command: 2, body: [UInt8](repeating: 1, count: 600)))
        XCTAssertEqual(decoder.feed(slices[1]), [.failure(.unexpectedSlice(marker: 2))])
        XCTAssertEqual(decoder.feed(good), [.message(Message(service: 1, command: 8, body: [1, 1, 55]))])

        // reset() drops a half-received frame.
        _ = decoder.feed(Array(good.prefix(5)))
        XCTAssertTrue(decoder.hasPartialData)
        decoder.reset()
        XCTAssertEqual(decoder.feed(good), [.message(Message(service: 1, command: 8, body: [1, 1, 55]))])
    }

    // MARK: Encrypted frames

    private let zeroKey = [UInt8](repeating: 0, count: 16)
    private let zeroIV = [UInt8](repeating: 0, count: 16)

    /// Frames below were produced by another open-source implementation of this protocol using an
    /// all-zero key and IV, so matching them shows this one is byte-compatible end to end.
    func testEncryptedRequestsMatchReferenceFrames() throws {
        let sleepCount = TLV().adding(0x81).adding(0x03, uint32: 0).adding(0x04, uint32: 0x0102_0304)
        XCTAssertEqual(
            Frame.encode(Message(service: 7, command: 0x0c, body: try LinkCrypto.seal(sleepCount.serialized(), key: zeroKey, iv: zeroIV))),
            [hex("5A002A00070C7C01017D10000000000000000000000000000000007E1032697B5185209B166B938A3DD59AF929DF07")])

        let stepCount = TLV().adding(0x81).adding(0x03, uint32: 0x0102_0304).adding(0x04, uint32: 0x1020_3040)
        XCTAssertEqual(
            Frame.encode(Message(service: 7, command: 0x0a, body: try LinkCrypto.seal(stepCount.serialized(), key: zeroKey, iv: zeroIV))),
            [hex("5A002A00070A7C01017D10000000000000000000000000000000007E104D5279574930 75C6285B79D5AB890D1EA9C9")])

        let fetch = TLV().adding(0x81, nested: TLV().adding(0x02, uint16: 0x1337))
        XCTAssertEqual(
            Frame.encode(Message(service: 7, command: 0x0d, body: try LinkCrypto.seal(fetch.serialized(), key: zeroKey, iv: zeroIV))),
            [hex("5A002A00070D7C01017D10000000000000000000000000000000007E10F6FBC0B64F9AFA7753287D13CA49DAFD7DAD")])
        XCTAssertEqual(
            Frame.encode(Message(service: 7, command: 0x0b, body: try LinkCrypto.seal(fetch.serialized(), key: zeroKey, iv: zeroIV))),
            [hex("5A002A00070B7C01017D10000000000000000000000000000000007E10F6FBC0B64F9AFA7753287D13CA49DAFD3A37")])
    }

    func testEncryptedResponsesDecodeLikeReference() throws {
        var decoder = FrameDecoder()
        let outputs = decoder.feed(hex(
            "5A003A00070D7C01017D10000000000000000000000000000000007E20A49ED8D37A0E5155C5480799F599483E"
                + "41ED16F152D29F38E8B183D6CB52B09F4805"))
        guard case .message(let message)? = outputs.first else { return XCTFail("no message") }
        XCTAssertEqual(message.service, 7)
        XCTAssertEqual(message.command, 0x0d)

        let envelope = try TLV(parsing: message.body)
        XCTAssertTrue(LinkCrypto.isSealed(envelope))
        let plain = try TLV(parsing: try LinkCrypto.open(envelope, key: zeroKey))
        let expected = TLV().adding(0x81, nested: TLV()
            .adding(0x02, uint16: 0x1337)
            .adding(0x83, nested: TLV().adding(0x04, byte: 0).adding(0x05, bytes: []))
            .adding(0x83, nested: TLV().adding(0x04, byte: 1).adding(0x05, bytes: [1, 2])))
        XCTAssertEqual(plain, expected)
    }

    func testSealAndOpenRoundTrip() throws {
        let key = (0..<16).map { UInt8($0) }
        let iv = (16..<32).map { UInt8($0) }
        let plain = TLV().adding(1, uint32: 12345).adding(0x81, nested: TLV().adding(2, string: "x"))
        let envelope = try TLV(parsing: try LinkCrypto.seal(plain.serialized(), key: key, iv: iv))
        XCTAssertEqual(envelope.bytes(0x7d), iv)
        XCTAssertEqual(try TLV(parsing: try LinkCrypto.open(envelope, key: key)), plain)
        XCTAssertFalse(LinkCrypto.isSealed(plain))
        XCTAssertThrowsError(try LinkCrypto.open(TLV().adding(0x7c, byte: 1), key: key))
    }
}
