import Foundation

/// One tag-length-value element.
public struct TLVItem: Equatable, Sendable {
    public var tag: UInt8
    public var value: [UInt8]

    public init(tag: UInt8, value: [UInt8] = []) {
        self.tag = tag
        self.value = value
    }
}

/// An ordered list of tag-length-value elements: the body of every command the band understands.
///
/// On the wire each element is a one-byte tag, a variable-length length and the value. Tags with
/// the top bit set (0x81, 0x83, …) hold a nested list. Order matters and tags may repeat, so this
/// is a list rather than a dictionary.
public struct TLV: Equatable, Sendable {
    public var items: [TLVItem]

    public enum Failure: Error, Equatable {
        /// An element claims more bytes than are left in the buffer.
        case truncated(tag: UInt8, needed: Int, available: Int)
        /// A length field ran off the end of the buffer or is implausibly long.
        case badLength(tag: UInt8)
    }

    public init(_ items: [TLVItem] = []) {
        self.items = items
    }

    // MARK: Parsing

    public init(parsing bytes: [UInt8]) throws {
        var items = [TLVItem]()
        var index = 0
        while index < bytes.count {
            let tag = bytes[index]
            index += 1
            // Decrypted bodies sometimes carry one stray zero byte at the very end; it is not an element.
            if index == bytes.count && tag == 0 { break }

            var length = 0
            var lengthBytes = 0
            while true {
                guard index < bytes.count, lengthBytes < 4 else { throw Failure.badLength(tag: tag) }
                let byte = bytes[index]
                index += 1
                lengthBytes += 1
                length = (length << 7) | Int(byte & 0x7f)
                if byte & 0x80 == 0 { break }
            }

            guard length <= bytes.count - index else {
                throw Failure.truncated(tag: tag, needed: length, available: bytes.count - index)
            }
            items.append(TLVItem(tag: tag, value: Array(bytes[index..<index + length])))
            index += length
        }
        self.items = items
    }

    // MARK: Serialising

    public func serialized() -> [UInt8] {
        var output = [UInt8]()
        for item in items {
            output.append(item.tag)
            output += TLV.encodeLength(item.value.count)
            output += item.value
        }
        return output
    }

    /// Lengths are base-128, most significant group first, with the top bit set on every byte
    /// except the last.
    static func encodeLength(_ length: Int) -> [UInt8] {
        var groups = [UInt8(length & 0x7f)]
        var remaining = length >> 7
        while remaining > 0 {
            groups.append(UInt8(remaining & 0x7f) | 0x80)
            remaining >>= 7
        }
        return groups.reversed()
    }

    // MARK: Building

    public func adding(_ tag: UInt8) -> TLV { adding(tag, bytes: []) }

    public func adding(_ tag: UInt8, bytes: [UInt8]) -> TLV {
        var copy = self
        copy.items.append(TLVItem(tag: tag, value: bytes))
        return copy
    }

    public func adding(_ tag: UInt8, byte: UInt8) -> TLV { adding(tag, bytes: [byte]) }
    public func adding(_ tag: UInt8, bool: Bool) -> TLV { adding(tag, bytes: [bool ? 1 : 0]) }
    public func adding(_ tag: UInt8, uint16: Int) -> TLV { adding(tag, bytes: Bytes.be16(uint16)) }
    public func adding(_ tag: UInt8, uint32: Int) -> TLV { adding(tag, bytes: Bytes.be32(uint32)) }
    public func adding(_ tag: UInt8, string: String) -> TLV { adding(tag, bytes: Array(string.utf8)) }
    public func adding(_ tag: UInt8, nested: TLV) -> TLV { adding(tag, bytes: nested.serialized()) }

    // MARK: Reading

    public func contains(_ tag: UInt8) -> Bool { items.contains { $0.tag == tag } }

    /// The value of the first element with this tag.
    public func bytes(_ tag: UInt8) -> [UInt8]? { items.first { $0.tag == tag }?.value }

    /// The first element with this tag read as an unsigned big-endian integer (1 to 8 bytes).
    public func unsigned(_ tag: UInt8) -> Int? {
        guard let value = bytes(tag), (1...8).contains(value.count) else { return nil }
        return Int(truncatingIfNeeded: Bytes.unsigned(value))
    }

    public func string(_ tag: UInt8) -> String? {
        guard let value = bytes(tag) else { return nil }
        return String(decoding: value, as: UTF8.self)
    }

    /// The first element with this tag parsed as a nested list, or nil if absent or malformed.
    public func nested(_ tag: UInt8) -> TLV? {
        guard let value = bytes(tag) else { return nil }
        return try? TLV(parsing: value)
    }

    /// Every element with this tag parsed as a nested list; malformed ones are skipped.
    public func allNested(_ tag: UInt8) -> [TLV] {
        items.filter { $0.tag == tag }.compactMap { try? TLV(parsing: $0.value) }
    }
}

extension TLV: CustomStringConvertible {
    /// Compact, loggable form such as `01=0A 81={02=1337}`.
    public var description: String {
        items.map { item in
            let tag = Bytes.hex([item.tag])
            if item.tag & 0x80 != 0, !item.value.isEmpty, let inner = try? TLV(parsing: item.value) {
                return "\(tag)={\(inner.description)}"
            }
            return item.value.isEmpty ? tag : "\(tag)=\(Bytes.hex(item.value))"
        }.joined(separator: " ")
    }
}
