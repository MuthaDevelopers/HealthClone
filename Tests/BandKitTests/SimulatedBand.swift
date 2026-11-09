import Foundation
@testable import BandKit

/// A stand-in for the band that speaks the same wire protocol from the other side.
///
/// It lets the tests drive the real session code through pairing and sync without hardware. It was
/// written from the same understanding of the protocol as the client, so it proves the client is
/// self-consistent and robust to transport quirks; it cannot prove the real band agrees.
final class SimulatedBand: BandTransport, @unchecked Sendable {
    struct Request: Equatable {
        var service: UInt8
        var command: UInt8
        var body: TLV
    }

    // Configuration, set before use.
    var authVersion = 2
    var address = BandAddress("6C:B7:49:12:34:56")!
    var sliceSize = 0xf4
    var linkMTU = 20
    var maximumWriteLength = 182
    var securityScheme = 0
    var protocolVersion = 2
    /// Cuts every notification into pieces of this size, as a small ATT MTU would.
    var notificationChunk = 20
    var battery = 73
    var totals = TLV()
    var activityBlocks = [TLV]()
    var sleepBlocks = [TLV]()
    var deviceInfo = TLV()
        .adding(0x03, string: "CRS-B19 VER.A")
        .adding(0x05, string: "6C:B7:49:12:34:56")
        .adding(0x07, string: "1.1.0.74")
        .adding(0x09, string: "ABC123456789")
        .adding(0x0a, string: "CRS-B19 ")
    /// Commands the band stays silent on, to exercise timeouts. Keyed by `service << 8 | command`.
    var silentCommands = Set<Int>()
    /// Drops this many upcoming replies, then behaves again.
    var repliesToDrop = 0
    /// Commands answered with a bare failure code.
    var refusedCommands = Set<Int>()

    // Observed state.
    private(set) var received = [Request]()
    private(set) var knownClients = [String: [UInt8]]()
    private(set) var clockSet: Int?
    private(set) var countRequests = [(command: UInt8, start: Int, end: Int)]()

    private let lock = NSLock()
    private var decoder = FrameDecoder()
    private var serverNonce = [UInt8]()
    private var currentSerial: String?
    private var counter: UInt32 = 41
    private var authenticated = false
    private let random = SystemRandomSource()

    let notifications: AsyncStream<[UInt8]>
    private let sink: AsyncStream<[UInt8]>.Continuation

    init() {
        (notifications, sink) = AsyncStream<[UInt8]>.makeStream()
    }

    /// Pretends this phone paired earlier.
    func remember(_ identity: PairingIdentity) {
        lock.lock(); defer { lock.unlock() }
        knownClients[identity.clientSerial] = identity.linkKey
    }

    func disconnect() {
        sink.finish()
    }

    /// Sends something the phone did not ask for.
    func push(service: UInt8, command: UInt8, body: TLV, encrypted: Bool = true) {
        lock.lock(); defer { lock.unlock() }
        send(service, command, body, encrypted: encrypted)
    }

    func requests(service: UInt8, command: UInt8) -> [TLV] {
        lock.lock(); defer { lock.unlock() }
        return received.filter { $0.service == service && $0.command == command }.map(\.body)
    }

    // MARK: Transport

    func write(_ bytes: [UInt8]) async throws {
        accept(bytes)
    }

    private func accept(_ bytes: [UInt8]) {
        lock.lock(); defer { lock.unlock() }
        precondition(bytes.count <= maximumWriteLength, "the session wrote more than the transport allows")
        precondition(bytes.count <= linkMTU || !authenticated, "the session ignored the negotiated write size")
        for output in decoder.feed(bytes) {
            if case .message(let message) = output { handle(message) }
        }
    }

    private func handle(_ message: Message) {
        guard var body = try? TLV(parsing: message.body) else { return }
        let wasEncrypted = LinkCrypto.isSealed(body)
        if wasEncrypted {
            // A band holding a different key cannot read the command and says nothing.
            guard let serial = currentSerial, let key = knownClients[serial],
                  let plain = try? LinkCrypto.open(body, key: key), let parsed = try? TLV(parsing: plain) else { return }
            body = parsed
        }
        received.append(Request(service: message.service, command: message.command, body: body))

        let code = Int(message.service) << 8 | Int(message.command)
        if silentCommands.contains(code) { return }
        if repliesToDrop > 0 {
            repliesToDrop -= 1
            return
        }
        if refusedCommands.contains(code) {
            send(message.service, message.command, TLV().adding(0x7f, uint32: 100_009), encrypted: wasEncrypted)
            return
        }

        switch (message.service, message.command) {
        case (0x01, 0x01):
            serverNonce = random.bytes(16)
            authenticated = false
            send(0x01, 0x01, TLV()
                .adding(0x01, byte: UInt8(protocolVersion))
                .adding(0x02, uint16: sliceSize)
                .adding(0x03, uint16: linkMTU)
                .adding(0x04, uint16: 10)
                .adding(0x05, bytes: Bytes.be16(authVersion) + serverNonce)
                .adding(0x07, byte: UInt8(securityScheme)), encrypted: false)

        case (0x01, 0x13):
            guard let challenge = body.bytes(0x01), let nonceField = body.bytes(0x02), nonceField.count == 18 else { return }
            let clientNonce = Array(nonceField[2...])
            let expected = try? LinkCrypto.challenge(authVersion: authVersion, serverNonce: serverNonce, clientNonce: clientNonce)
            guard challenge == expected,
                  let answer = try? LinkCrypto.expectedResponse(authVersion: authVersion, serverNonce: serverNonce, clientNonce: clientNonce) else {
                send(0x01, 0x13, TLV().adding(0x7f, uint32: 100_009), encrypted: false)
                return
            }
            authenticated = true
            send(0x01, 0x13, TLV().adding(0x01, bytes: answer), encrypted: false)

        case (0x01, 0x0f):
            guard authenticated, let serial = body.string(0x03) else { return }
            currentSerial = serial
            send(0x01, 0x0f, TLV()
                .adding(0x01, byte: knownClients[serial] != nil ? 1 : 0)
                .adding(0x02, byte: 0)
                .adding(0x04, byte: 2)
                .adding(0x05, uint16: sliceSize)
                .adding(0x09, uint32: Int(counter)), encrypted: false)

        case (0x01, 0x0e):
            guard authenticated, let serial = body.string(0x05), let wrapped = body.bytes(0x06), let iv = body.bytes(0x07) else { return }
            // Whatever comes out of the unwrap becomes the link key, right or wrong, as on a real device.
            let unwrapKey = LinkCrypto.bondingKey(authVersion: authVersion, deviceAddress: address)
            let key = (try? AES128.decryptCBC(wrapped, key: unwrapKey, iv: iv)) ?? random.bytes(16)
            knownClients[serial] = key.count == 16 ? key : random.bytes(16)
            currentSerial = serial
            send(0x01, 0x0e, TLV().adding(0x02, byte: 1), encrypted: false)

        case (0x01, 0x07):
            send(0x01, 0x07, deviceInfo, encrypted: true)
        case (0x01, 0x08):
            send(0x01, 0x08, TLV().adding(0x01, byte: UInt8(battery)), encrypted: true)
        case (0x01, 0x05):
            clockSet = body.unsigned(0x01)
            succeed(message)
        case (0x07, 0x0a), (0x07, 0x0c):
            countRequests.append((message.command, body.unsigned(0x03) ?? -1, body.unsigned(0x04) ?? -1))
            let blocks = message.command == 0x0a ? activityBlocks : sleepBlocks
            send(0x07, message.command, TLV().adding(0x81, nested: TLV().adding(0x02, uint16: blocks.count)), encrypted: true)
        case (0x07, 0x0b), (0x07, 0x0d):
            let blocks = message.command == 0x0b ? activityBlocks : sleepBlocks
            guard let index = body.nested(0x81)?.unsigned(0x02), index < blocks.count else {
                send(0x07, message.command, TLV().adding(0x7f, uint32: 100_009), encrypted: true)
                return
            }
            send(0x07, message.command, blocks[index], encrypted: true)
        case (0x07, 0x03):
            send(0x07, 0x03, totals, encrypted: true)
        default:
            succeed(message)
        }
    }

    private func succeed(_ message: Message) {
        send(message.service, message.command, TLV().adding(0x7f, uint32: 100_000), encrypted: true)
    }

    private func send(_ service: UInt8, _ command: UInt8, _ body: TLV, encrypted: Bool) {
        var bytes = body.serialized()
        if encrypted {
            guard let serial = currentSerial, let key = knownClients[serial] else { return }
            counter += 1
            bytes = try! LinkCrypto.seal(bytes, key: key, iv: random.bytes(12) + Bytes.be32(Int(counter)))
        }
        for frame in Frame.encode(Message(service: service, command: command, body: bytes), sliceSize: sliceSize) {
            var offset = 0
            while offset < frame.count {
                let end = min(offset + notificationChunk, frame.count)
                sink.yield(Array(frame[offset..<end]))
                offset = end
            }
        }
    }

    // MARK: Fixture builders

    /// One block of per-minute activity in the band's packed form.
    static func activityBlock(base: Int, minutes: [(offset: Int, steps: Int?, calories: Int?, distance: Int?, heartRate: Int?)]) -> TLV {
        var block = TLV().adding(0x02, uint16: 0).adding(0x03, uint32: base)
        for minute in minutes {
            var bitmap: UInt8 = 0
            var fields = [UInt8]()
            if let steps = minute.steps { bitmap |= 0x02; fields += Bytes.be16(steps) }
            if let calories = minute.calories { bitmap |= 0x04; fields += Bytes.be16(calories) }
            if let distance = minute.distance { bitmap |= 0x08; fields += Bytes.be16(distance) }
            if let heartRate = minute.heartRate { bitmap |= 0x40; fields.append(UInt8(heartRate)) }
            block = block.adding(0x84, nested: TLV().adding(0x05, byte: UInt8(minute.offset)).adding(0x06, bytes: [bitmap] + fields))
        }
        return TLV().adding(0x81, nested: block)
    }

    static func sleepBlock(_ segments: [(start: Int, minutes: Int, stage: Int)]) -> TLV {
        var block = TLV().adding(0x02, uint16: 0)
        for segment in segments {
            block = block.adding(0x83, nested: TLV()
                .adding(0x04, byte: UInt8(segment.stage))
                .adding(0x05, bytes: Bytes.be32(segment.start) + Bytes.be16(segment.minutes)))
        }
        return TLV().adding(0x81, nested: block)
    }

    static func totals(_ activities: [(kind: Int, steps: Int, calories: Int, distance: Int)]) -> TLV {
        var block = TLV().adding(0x02, uint16: activities.reduce(0) { $0 + $1.calories })
        for activity in activities {
            block = block.adding(0x83, nested: TLV()
                .adding(0x04, byte: UInt8(activity.kind))
                .adding(0x05, uint32: activity.steps)
                .adding(0x06, uint16: activity.calories)
                .adding(0x07, uint32: activity.distance))
        }
        return TLV().adding(0x81, nested: block)
    }
}

/// Collects log lines so tests can assert on what was, and was not, written.
final class RecordingLogger: BandLogger, @unchecked Sendable {
    private let lock = NSLock()
    private var storage = [String]()

    func log(_ level: LogLevel, _ message: String) {
        lock.lock(); defer { lock.unlock() }
        storage.append("\(level.rawValue) \(message)")
    }

    var lines: [String] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}
