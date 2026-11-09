import Foundation

/// One open connection to a band: sends commands, matches replies, and runs the pairing handshake.
///
/// The band answers one command at a time and labels each reply with the same service and command
/// numbers as the request, so the session lets only one request be outstanding and pairs the next
/// matching message with it. Anything else that arrives is treated as an event.
public actor BandSession {
    public struct Timing: Sendable {
        /// How long to wait for an ordinary reply.
        public var reply: TimeInterval
        /// How long to wait for the bonding reply; the band may ask its wearer to confirm first.
        public var bonding: TimeInterval
        /// A half-received frame older than this is discarded when new data arrives.
        public var staleFrame: TimeInterval

        /// How long to wait when asking an unpaired band for its own address. Bands that will not
        /// say simply stay silent, so this is kept short.
        public var addressProbe: TimeInterval

        public init(reply: TimeInterval = 8, bonding: TimeInterval = 60, staleFrame: TimeInterval = 3,
                    addressProbe: TimeInterval = 2.5) {
            self.reply = reply
            self.bonding = bonding
            self.staleFrame = staleFrame
            self.addressProbe = addressProbe
        }
    }

    public enum BondPolicy: Equatable, Sendable {
        /// Send the link key only if the band says it does not know this phone. Right for
        /// reconnecting with an identity the band has seen before.
        case ifNeeded
        /// Always send the link key. Right for a first pairing, where the identity is brand new
        /// and whatever the band claims to remember cannot be this phone's key.
        case always
    }

    public enum BondOutcome: Equatable, Sendable {
        /// The band already knew this phone.
        case existing
        /// The band accepted this phone as new.
        case created
    }

    public struct OpenResult: Equatable, Sendable {
        public var link: LinkParameters
        public var bond: BondOutcome
        public var device: DeviceInfo
        /// The band's address used for a new bond: the one supplied, or the one the band reported
        /// when none was. Nil when the band already knew this phone.
        public var deviceAddress: BandAddress?
    }

    static let resultTag: UInt8 = 0x7f
    static let resultSuccess = 100_000

    private let transport: BandTransport
    private let random: RandomSource
    let logger: BandLogger
    private let timing: Timing

    private var decoder = FrameDecoder()
    private var lastReceive: Date?
    private var receiveTask: Task<Void, Never>?
    private var closed = false

    private var linkKey: [UInt8]?
    private var ivSequence = IVSequence()
    private var sliceSize = Frame.defaultSliceSize
    private var linkMTU = 20

    private struct Pending {
        let id: Int
        let service: UInt8
        let command: UInt8
        let continuation: CheckedContinuation<Message, Error>
        var timeout: Task<Void, Never>?
    }

    private var pending: Pending?
    private var requestCounter = 0
    private var gateHeld = false
    private var gateQueue: [CheckedContinuation<Void, Never>] = []

    /// Events the band raises on its own. Finishes when the connection closes.
    public nonisolated let events: AsyncStream<BandEvent>
    private let eventSink: AsyncStream<BandEvent>.Continuation

    public init(transport: BandTransport, random: RandomSource = SystemRandomSource(),
                logger: BandLogger = SilentLogger(), timing: Timing = Timing()) {
        self.transport = transport
        self.random = random
        self.logger = logger
        self.timing = timing
        (events, eventSink) = AsyncStream<BandEvent>.makeStream()
    }

    /// Whether pairing has completed and encrypted commands can be sent.
    public var isPaired: Bool { linkKey != nil }

    // MARK: - Receiving

    /// Starts listening to the band. Safe to call more than once.
    public func start() {
        guard receiveTask == nil, !closed else { return }
        let stream = transport.notifications
        receiveTask = Task { [weak self] in
            for await bytes in stream {
                await self?.receive(bytes)
            }
            await self?.connectionClosed()
        }
    }

    /// Stops listening and fails anything still waiting. The transport itself is left to its owner.
    public func close() {
        receiveTask?.cancel()
        connectionClosed()
    }

    private func connectionClosed() {
        guard !closed else { return }
        closed = true
        logger.log(.info, "Link closed")
        resolvePending(with: .failure(BandError.disconnected))
        eventSink.finish()
    }

    private func receive(_ bytes: [UInt8]) {
        logger.log(.debug, "RX \(Bytes.hex(bytes))")
        let now = Date()
        if decoder.hasPartialData, let last = lastReceive, now.timeIntervalSince(last) > timing.staleFrame {
            logger.log(.warning, "Dropping a half-received frame after \(Int(now.timeIntervalSince(last)))s of silence")
            decoder.reset()
        }
        lastReceive = now

        for output in decoder.feed(bytes) {
            switch output {
            case .failure(let failure):
                logger.log(.warning, "Discarded unreadable data: \(failure)")
            case .message(let message):
                handle(message)
            }
        }
    }

    private func handle(_ message: Message) {
        let label = "\(Bytes.hex([message.service]))/\(Bytes.hex([message.command]))"
        var plain = message
        var decryptionFailed = false

        if let envelope = try? TLV(parsing: message.body), LinkCrypto.isSealed(envelope) {
            if let key = linkKey, let opened = try? LinkCrypto.open(envelope, key: key) {
                plain.body = opened
            } else {
                decryptionFailed = true
                logger.log(.error, "Could not decrypt reply \(label)")
            }
        }

        if !decryptionFailed {
            let text = (try? TLV(parsing: plain.body))?.description ?? "raw \(Bytes.hex(plain.body))"
            logger.log(.debug, "<- \(label) \(text)")
        }

        if let waiting = pending, waiting.service == message.service, waiting.command == message.command {
            resolvePending(with: decryptionFailed ? .failure(BandError.decryptionFailed) : .success(plain))
        } else if !decryptionFailed {
            handleEvent(plain)
        }
    }

    private func handleEvent(_ message: Message) {
        // 01/27 is the band announcing a battery change, in the same shape as the battery reply.
        if message.service == 0x01, message.command == 0x27,
           let level = (try? TLV(parsing: message.body))?.unsigned(0x01) {
            eventSink.yield(.batteryLevel(level))
        } else {
            eventSink.yield(.unhandled(service: message.service, command: message.command))
        }
    }

    // MARK: - Sending

    private func acquireGate() async {
        if !gateHeld {
            gateHeld = true
            return
        }
        await withCheckedContinuation { gateQueue.append($0) }
    }

    private func releaseGate() {
        if gateQueue.isEmpty {
            gateHeld = false
        } else {
            gateQueue.removeFirst().resume()
        }
    }

    private func resolvePending(with result: Result<Message, Error>) {
        guard let waiting = pending else { return }
        pending = nil
        waiting.timeout?.cancel()
        waiting.continuation.resume(with: result)
    }

    private func failPending(id: Int, error: Error) {
        guard pending?.id == id else { return }
        resolvePending(with: .failure(error))
    }

    /// Sends one message and waits for the reply with the same service and command numbers.
    private func exchange(_ message: Message, timeout: TimeInterval) async throws -> Message {
        await acquireGate()
        defer { releaseGate() }
        guard !closed else { throw BandError.disconnected }

        let frames = Frame.encode(message, sliceSize: sliceSize)
        requestCounter += 1
        let id = requestCounter
        let service = message.service, command = message.command

        return try await withCheckedThrowingContinuation { continuation in
            // Register interest before the first byte goes out so a fast reply cannot be missed.
            pending = Pending(id: id, service: service, command: command, continuation: continuation, timeout: nil)
            pending?.timeout = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await self?.failPending(id: id, error: BandError.timeout(service: service, command: command))
            }
            Task { await self.transmit(frames, requestID: id) }
        }
    }

    private func transmit(_ frames: [[UInt8]], requestID: Int) async {
        let chunkSize = max(1, min(linkMTU, transport.maximumWriteLength))
        do {
            for frame in frames {
                var offset = 0
                while offset < frame.count {
                    let end = min(offset + chunkSize, frame.count)
                    try await transport.write(Array(frame[offset..<end]))
                    offset = end
                }
            }
        } catch {
            logger.log(.error, "Write failed: \(error)")
            failPending(id: requestID, error: BandError.disconnected)
        }
    }

    /// Sends a command and returns the reply body.
    ///
    /// - Parameters:
    ///   - encrypted: false only for the handshake commands that run before a link key exists.
    ///   - redactLog: keeps the request body out of the log, for the one request that carries key material.
    func query(_ service: UInt8, _ command: UInt8, _ body: TLV, encrypted: Bool = true,
               timeout: TimeInterval? = nil, redactLog: Bool = false) async throws -> TLV {
        let label = "\(Bytes.hex([service]))/\(Bytes.hex([command]))"
        var bytes = body.serialized()
        if encrypted {
            guard let key = linkKey else { throw BandError.notPaired }
            bytes = try LinkCrypto.seal(bytes, key: key, iv: ivSequence.next(random: random))
        }
        logger.log(.debug, "-> \(label) \(redactLog ? "(contents withheld)" : body.description)")

        let reply = try await exchange(Message(service: service, command: command, body: bytes),
                                       timeout: timeout ?? timing.reply)
        guard let tlv = try? TLV(parsing: reply.body) else {
            throw BandError.malformedReply(service: service, command: command, detail: "body is not a tag list")
        }
        // A reply that is nothing but a failure code means the band refused the command.
        if tlv.items.count == 1, let code = tlv.unsigned(BandSession.resultTag), code != BandSession.resultSuccess {
            throw BandError.rejected(service: service, command: command, code: code)
        }
        return tlv
    }

    /// Sends a command whose only expected reply is a success code.
    func perform(_ service: UInt8, _ command: UInt8, _ body: TLV) async throws {
        let reply = try await query(service, command, body)
        if let code = reply.unsigned(BandSession.resultTag), code != BandSession.resultSuccess {
            throw BandError.rejected(service: service, command: command, code: code)
        }
    }

    // MARK: - Pairing

    /// Runs the whole handshake and leaves the link ready for encrypted commands.
    ///
    /// If the band does not know this phone yet, its Bluetooth address is needed. When
    /// `identity.deviceAddress` is nil the band is asked for it; if it will not say, this throws
    /// `BandError.deviceAddressRequired` and the caller should ask the user. The band may also ask
    /// its wearer to confirm the pairing on its screen.
    ///
    /// - Parameters:
    ///   - nameHint: the band's advertised name, used to sanity-check a reported address.
    ///   - bondPolicy: whether to send the link key even if the band claims to know this phone.
    public func open(identity: PairingIdentity, nameHint: String? = nil,
                     bondPolicy: BondPolicy = .ifNeeded) async throws -> OpenResult {
        start()
        linkKey = nil

        let link = try await requestLinkParameters()
        logger.log(.info, "Link: protocol \(link.protocolVersion), frame \(link.sliceSize), write \(link.linkMTU), "
            + "auth v\(link.authVersion), scheme \(link.securityScheme)")
        guard link.protocolVersion == 2 else { throw BandError.unsupportedProtocol(version: link.protocolVersion) }
        guard link.securityScheme == 0 else { throw BandError.unsupportedSecurity(scheme: link.securityScheme) }
        guard (1...4).contains(link.authVersion) else { throw BandError.unsupportedAuthVersion(link.authVersion) }
        sliceSize = link.sliceSize
        linkMTU = link.linkMTU

        try await authenticate(link)
        logger.log(.info, "Handshake check passed")

        let parameters = try await requestBondParameters(identity)
        ivSequence = IVSequence(counter: parameters.counter)
        if let frameSize = parameters.frameSize, frameSize >= 32 { sliceSize = min(sliceSize, frameSize) }

        let outcome: BondOutcome
        var bondedAddress: BandAddress?
        if parameters.bonded && bondPolicy == .ifNeeded {
            outcome = .existing
            logger.log(.info, "Band recognises this phone")
        } else {
            var address = identity.deviceAddress
            if address == nil {
                address = await reportedAddress(nameHint: nameHint)
            }
            guard let address else { throw BandError.deviceAddressRequired }
            logger.log(.info, parameters.bonded
                ? "Band claims to know this phone; sending the link key anyway"
                : "Band does not know this phone; sending pairing request")
            try await bond(identity, address: address, authVersion: link.authVersion)
            outcome = .created
            bondedAddress = address
        }
        linkKey = identity.linkKey

        // The handshake so far cannot tell whether the band ended up with the same link key.
        // The first encrypted exchange can: a band holding a different key will not answer usefully.
        let device: DeviceInfo
        do {
            device = try await deviceInfo()
        } catch let error as BandError {
            switch error {
            case .timeout, .decryptionFailed, .rejected, .malformedReply:
                linkKey = nil
                logger.log(.error, "First encrypted exchange failed (\(error)); the band is not using our link key")
                throw BandError.linkKeyRejected(firstPairing: outcome == .created)
            default:
                throw error
            }
        }
        logger.log(.info, "Paired with \(device.model ?? "band"), firmware \(device.softwareVersion ?? "unknown")")
        return OpenResult(link: link, bond: outcome, device: device, deviceAddress: bondedAddress)
    }

    /// Asks a band that is not yet paired for its own Bluetooth address.
    ///
    /// iOS hides the address, so this is the only way to get it without the user typing it in.
    /// Not every band answers before pairing; one that stays silent costs a short wait and nothing
    /// else. An address that contradicts the band's advertised name is not trusted.
    private func reportedAddress(nameHint: String?) async -> BandAddress? {
        guard let reply = try? await query(0x01, 0x07, TLV().adding(0x05), encrypted: false, timeout: timing.addressProbe),
              let text = reply.string(0x05), let address = BandAddress(text) else {
            logger.log(.info, "Band did not report its address before pairing")
            return nil
        }
        if let nameHint, !AddressGuess.matches(address, name: nameHint) {
            logger.log(.warning, "Band reported an address that does not match its name; ignoring it")
            return nil
        }
        logger.log(.info, "Band reported its address")
        return address
    }

    private func requestLinkParameters() async throws -> LinkParameters {
        let reply = try await query(0x01, 0x01, TLV().adding(1).adding(2).adding(3).adding(4), encrypted: false)
        // Tag 5 carries the auth version (two bytes) followed by the band's 16-byte nonce.
        guard let nonceField = reply.bytes(0x05), nonceField.count >= 18 else {
            throw BandError.malformedReply(service: 1, command: 1, detail: "missing nonce")
        }
        return LinkParameters(
            protocolVersion: reply.unsigned(0x01) ?? 0,
            sliceSize: reply.unsigned(0x02) ?? Frame.defaultSliceSize,
            linkMTU: reply.unsigned(0x03) ?? 20,
            authVersion: Int(nonceField[0]) << 8 | Int(nonceField[1]),
            serverNonce: Array(nonceField[2..<18]),
            securityScheme: reply.unsigned(0x07) ?? 0,
            bondState: reply.unsigned(0x09),
            encryptMethod: reply.unsigned(0x0c) ?? 0)
    }

    private func authenticate(_ link: LinkParameters) async throws {
        let clientNonce = random.bytes(LinkCrypto.nonceLength)
        let challenge = try LinkCrypto.challenge(authVersion: link.authVersion, serverNonce: link.serverNonce, clientNonce: clientNonce)
        let body = TLV()
            .adding(0x01, bytes: challenge)
            .adding(0x02, bytes: Bytes.be16(link.authVersion) + clientNonce)
        let reply = try await query(0x01, 0x13, body, encrypted: false)

        let expected = try LinkCrypto.expectedResponse(authVersion: link.authVersion, serverNonce: link.serverNonce, clientNonce: clientNonce)
        guard reply.bytes(0x01) == expected else { throw BandError.authenticationFailed }
    }

    private struct BondParameters {
        var bonded: Bool
        var counter: UInt32
        var frameSize: Int?
    }

    private func requestBondParameters(_ identity: PairingIdentity) async throws -> BondParameters {
        let body = TLV()
            .adding(0x01)
            .adding(0x03, string: identity.clientSerial)
            .adding(0x04, byte: 2)
            .adding(0x05)
            .adding(0x07, string: identity.clientAddress)
            .adding(0x09)
        let reply = try await query(0x01, 0x0f, body, encrypted: false)
        guard let status = reply.unsigned(0x01) else {
            throw BandError.malformedReply(service: 1, command: 0x0f, detail: "missing bond status")
        }
        return BondParameters(
            bonded: status == 1,
            counter: UInt32(truncatingIfNeeded: reply.unsigned(0x09) ?? 0),
            frameSize: reply.unsigned(0x05))
    }

    private func bond(_ identity: PairingIdentity, address: BandAddress, authVersion: Int) async throws {
        let iv = ivSequence.next(random: random)
        let wrapped = try LinkCrypto.wrapLinkKey(identity.linkKey, authVersion: authVersion, deviceAddress: address, iv: iv)
        let body = TLV()
            .adding(0x01)
            .adding(0x03, byte: 0)
            .adding(0x05, string: identity.clientSerial)
            .adding(0x06, bytes: wrapped)
            .adding(0x07, bytes: iv)
        // The log must not carry this body: with the band's address it would reveal the link key.
        let reply = try await query(0x01, 0x0e, body, encrypted: false, timeout: timing.bonding, redactLog: true)
        if let code = reply.unsigned(BandSession.resultTag), code != BandSession.resultSuccess {
            throw BandError.rejected(service: 0x01, command: 0x0e, code: code)
        }
    }
}
