import Foundation

/// A command or reply: which service and command it belongs to, plus its raw body.
///
/// The body is a serialised `TLV`. Once the link is paired the body is an encryption wrapper
/// around the real one; see `LinkCipher`.
public struct Message: Equatable, Sendable {
    public var service: UInt8
    public var command: UInt8
    public var body: [UInt8]

    public init(service: UInt8, command: UInt8, body: [UInt8] = []) {
        self.service = service
        self.command = command
        self.body = body
    }

    public init(service: UInt8, command: UInt8, tlv: TLV) {
        self.init(service: service, command: command, body: tlv.serialized())
    }
}

/// CRC-16/XMODEM: polynomial 0x1021, initial value 0, no reflection.
public enum CRC16 {
    public static func checksum<S: Sequence>(_ bytes: S) -> UInt16 where S.Element == UInt8 {
        var crc: UInt16 = 0
        for byte in bytes {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 {
                crc = (crc & 0x8000) != 0 ? (crc << 1) ^ 0x1021 : crc << 1
            }
        }
        return crc
    }
}

/// Link-layer framing.
///
/// Every frame is
///
///     5A | length (2, big-endian) | slice marker | [slice index] | payload | CRC-16 (2, big-endian)
///
/// where `length` counts everything between itself and the CRC. A message that fits in one frame
/// uses slice marker 0 and has no index byte. A longer one is cut into slices marked 1 (first),
/// 2 (middle) and 3 (last), each followed by an index counting from zero. The payload of a whole
/// message starts with the service and command bytes.
public enum Frame {
    public static let magic: UInt8 = 0x5a
    /// Frame size both sides assume until the band says otherwise.
    public static let defaultSliceSize = 0xf4

    static let slicedOverhead = 7   // magic + length + marker + index + CRC
    static let wholeOverhead = 6    // magic + length + marker + CRC

    /// Encodes a message as one or more frames, none longer than `sliceSize` bytes.
    public static func encode(_ message: Message, sliceSize: Int = defaultSliceSize) -> [[UInt8]] {
        let payload = [message.service, message.command] + message.body
        // Guard against a nonsensical negotiated size; 32 still leaves 25 payload bytes per slice.
        let chunkSize = max(sliceSize, 32) - slicedOverhead

        if payload.count <= chunkSize {
            return [seal([magic] + Bytes.be16(payload.count + 1) + [0] + payload)]
        }

        var frames = [[UInt8]]()
        var offset = 0
        var index: UInt8 = 0
        while offset < payload.count {
            let end = min(offset + chunkSize, payload.count)
            let marker: UInt8 = offset == 0 ? 1 : (end == payload.count ? 3 : 2)
            let chunk = payload[offset..<end]
            frames.append(seal([magic] + Bytes.be16(chunk.count + 2) + [marker, index] + chunk))
            offset = end
            index &+= 1
        }
        return frames
    }

    private static func seal(_ frame: [UInt8]) -> [UInt8] {
        frame + Bytes.be16(Int(CRC16.checksum(frame)))
    }
}

/// Reassembles messages from the notification byte stream.
///
/// A frame may arrive split across several notifications, several frames may arrive in one, and a
/// message may span several frames. Feed every notification in order and collect what falls out.
public struct FrameDecoder: Sendable {
    public enum Failure: Error, Equatable {
        case badMagic(UInt8)
        case badLength(Int)
        case badChecksum(expected: UInt16, actual: UInt16)
        case unexpectedSlice(marker: UInt8)
        case emptyPayload
    }

    public enum Output: Equatable, Sendable {
        case message(Message)
        /// Bytes had to be thrown away. The decoder has already reset itself.
        case failure(Failure)
    }

    /// Longest `length` field accepted. Real frames are a few hundred bytes at most.
    static let maximumLength = 4096

    private var buffer = [UInt8]()
    private var slices: [UInt8]?

    public init() {}

    /// True while a frame or a sliced message is only partly received.
    public var hasPartialData: Bool { !buffer.isEmpty || slices != nil }

    /// Drops any partly received data, for example after a long silence mid-frame.
    public mutating func reset() {
        buffer.removeAll()
        slices = nil
    }

    public mutating func feed(_ bytes: [UInt8]) -> [Output] {
        buffer += bytes
        var outputs = [Output]()

        while !buffer.isEmpty {
            guard buffer[0] == Frame.magic else {
                outputs.append(.failure(.badMagic(buffer[0])))
                reset()
                break
            }
            guard buffer.count >= 3 else { break }

            let length = Int(buffer[1]) << 8 | Int(buffer[2])
            guard length >= 1, length <= FrameDecoder.maximumLength else {
                outputs.append(.failure(.badLength(length)))
                reset()
                break
            }
            let frameSize = 3 + length + 2
            guard buffer.count >= frameSize else { break }

            let frame = Array(buffer[0..<frameSize])
            buffer.removeFirst(frameSize)

            let expected = UInt16(frame[frameSize - 2]) << 8 | UInt16(frame[frameSize - 1])
            let actual = CRC16.checksum(frame[0..<frameSize - 2])
            guard expected == actual else {
                outputs.append(.failure(.badChecksum(expected: expected, actual: actual)))
                reset()
                break
            }

            let marker = frame[3]
            if (1...3).contains(marker) {
                guard length >= 2 else {
                    outputs.append(.failure(.badLength(length)))
                    reset()
                    break
                }
                let chunk = frame[5..<frameSize - 2]
                if marker == 1 {
                    slices = Array(chunk)
                } else if slices != nil {
                    slices?.append(contentsOf: chunk)
                } else {
                    // A continuation with no beginning: the start was lost, so this cannot be used.
                    outputs.append(.failure(.unexpectedSlice(marker: marker)))
                    continue
                }
                if marker == 3, let payload = slices {
                    slices = nil
                    outputs.append(FrameDecoder.output(for: payload))
                }
            } else {
                outputs.append(FrameDecoder.output(for: Array(frame[4..<frameSize - 2])))
            }
        }
        return outputs
    }

    private static func output(for payload: [UInt8]) -> Output {
        guard payload.count >= 2 else { return .failure(.emptyPayload) }
        return .message(Message(service: payload[0], command: payload[1], body: Array(payload[2...])))
    }
}
