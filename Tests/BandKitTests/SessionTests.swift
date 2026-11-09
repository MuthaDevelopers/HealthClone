import XCTest
@testable import BandKit

/// Drives the real session code against `SimulatedBand`.
final class SessionTests: XCTestCase {
    private let fastTiming = BandSession.Timing(reply: 0.4, bonding: 0.6, staleFrame: 3)

    private func makeIdentity(address: String? = "6C:B7:49:12:34:56") -> PairingIdentity {
        PairingIdentity.generate(deviceAddress: address.flatMap(BandAddress.init))
    }

    private func assertThrows<T>(_ expected: BandError, file: StaticString = #filePath, line: UInt = #line,
                                 _ body: () async throws -> T) async {
        do {
            _ = try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? BandError, expected, file: file, line: line)
        }
    }

    // MARK: Pairing

    func testFirstPairingThenReconnect() async throws {
        let band = SimulatedBand()
        let identity = makeIdentity()

        let first = BandSession(transport: band, timing: fastTiming)
        let opened = try await first.open(identity: identity)
        XCTAssertEqual(opened.bond, .created)
        XCTAssertEqual(opened.link.authVersion, 2)
        XCTAssertEqual(opened.device.model, "CRS-B19", "padding around text fields is trimmed")
        XCTAssertEqual(opened.device.softwareVersion, "1.1.0.74")
        XCTAssertEqual(opened.device.reportedAddress, "6C:B7:49:12:34:56")
        XCTAssertEqual(band.knownClients[identity.clientSerial], identity.linkKey, "the band unwrapped the same link key")
        let paired = await first.isPaired
        XCTAssertTrue(paired)

        await first.close()

        // A later connection with the same identity is recognised and does not bond again.
        let returning = SimulatedBand()
        returning.remember(identity)
        let reopened = try await BandSession(transport: returning, timing: fastTiming).open(identity: identity)
        XCTAssertEqual(reopened.bond, .existing)
        XCTAssertTrue(returning.requests(service: 0x01, command: 0x0e).isEmpty, "no bonding request for a known phone")
    }

    func testEveryAuthVersion() async throws {
        for version in [1, 2, 3] {
            let band = SimulatedBand()
            band.authVersion = version
            let identity = makeIdentity()
            let opened = try await BandSession(transport: band, timing: fastTiming).open(identity: identity)
            XCTAssertEqual(opened.bond, .created, "auth v\(version)")
            XCTAssertEqual(band.knownClients[identity.clientSerial], identity.linkKey, "auth v\(version)")
        }
    }

    func testHandshakeRequestsHaveTheDocumentedShape() async throws {
        let band = SimulatedBand()
        let identity = makeIdentity()
        _ = try await BandSession(transport: band, timing: fastTiming).open(identity: identity)

        XCTAssertEqual(band.requests(service: 0x01, command: 0x01), [TLV().adding(1).adding(2).adding(3).adding(4)])

        let auth = try XCTUnwrap(band.requests(service: 0x01, command: 0x13).first)
        XCTAssertEqual(auth.bytes(0x01)?.count, 32)
        XCTAssertEqual(auth.bytes(0x02)?.prefix(2), [0x00, 0x02], "auth version precedes the phone's nonce")
        XCTAssertEqual(auth.bytes(0x02)?.count, 18)

        let parameters = try XCTUnwrap(band.requests(service: 0x01, command: 0x0f).first)
        XCTAssertEqual(parameters.items.map(\.tag), [0x01, 0x03, 0x04, 0x05, 0x07, 0x09])
        XCTAssertEqual(parameters.string(0x03), identity.clientSerial)
        XCTAssertEqual(parameters.bytes(0x04), [2])
        XCTAssertEqual(parameters.string(0x07), identity.clientAddress)

        let bond = try XCTUnwrap(band.requests(service: 0x01, command: 0x0e).first)
        XCTAssertEqual(bond.items.map(\.tag), [0x01, 0x03, 0x05, 0x06, 0x07])
        XCTAssertEqual(bond.bytes(0x06)?.count, 32, "a 16-byte key padded to two cipher blocks")
        XCTAssertEqual(bond.bytes(0x07)?.suffix(4), [0, 0, 0, 42], "the IV ends with the band's counter plus one")
    }

    func testIdentityGeneration() {
        let identity = PairingIdentity.generate()
        XCTAssertTrue(identity.clientAddress.hasPrefix("FF:FF:FF:"))
        XCTAssertEqual(identity.clientAddress.count, 17)
        XCTAssertEqual(identity.clientSerial.count, 6)
        XCTAssertEqual(identity.linkKey.count, 16)
        XCTAssertNotEqual(identity.linkKey, PairingIdentity.generate().linkKey)
    }

    func testWrongAddressIsReportedAsFailedPairing() async {
        let band = SimulatedBand()
        // One digit off: the band derives a different unwrap key and ends up with a different link key.
        let identity = makeIdentity(address: "6C:B7:49:12:34:57")
        await assertThrows(.linkKeyRejected(firstPairing: true)) {
            try await BandSession(transport: band, timing: fastTiming).open(identity: identity)
        }
    }

    func testStaleBondIsReportedDifferently() async {
        let band = SimulatedBand()
        var identity = makeIdentity()
        band.remember(identity)
        identity.linkKey = [UInt8](repeating: 9, count: 16)   // the phone lost its key; the band still has the old one
        await assertThrows(.linkKeyRejected(firstPairing: false)) {
            try await BandSession(transport: band, timing: fastTiming).open(identity: identity)
        }
    }

    func testFirstPairingNeedsTheAddress() async {
        let band = SimulatedBand()
        await assertThrows(.deviceAddressRequired) {
            try await BandSession(transport: band, timing: fastTiming).open(identity: makeIdentity(address: nil))
        }
        XCTAssertTrue(band.requests(service: 0x01, command: 0x0e).isEmpty)
    }

    func testNewerDevicesAreRefusedClearly() async {
        let scheme = SimulatedBand()
        scheme.securityScheme = 4
        await assertThrows(.unsupportedSecurity(scheme: 4)) {
            try await BandSession(transport: scheme, timing: fastTiming).open(identity: makeIdentity())
        }
        let version = SimulatedBand()
        version.protocolVersion = 3
        await assertThrows(.unsupportedProtocol(version: 3)) {
            try await BandSession(transport: version, timing: fastTiming).open(identity: makeIdentity())
        }
    }

    func testBandFailingTheHandshakeCheck() async {
        let band = SimulatedBand()
        band.refusedCommands = [0x0113]
        await assertThrows(.rejected(service: 0x01, command: 0x13, code: 100_009)) {
            try await BandSession(transport: band, timing: fastTiming).open(identity: makeIdentity())
        }
    }

    func testLinkKeyNeverReachesTheLog() async throws {
        let band = SimulatedBand()
        let logger = RecordingLogger()
        let identity = makeIdentity()
        _ = try await BandSession(transport: band, logger: logger, timing: fastTiming).open(identity: identity)

        let log = logger.lines.joined(separator: "\n")
        XCTAssertFalse(log.contains(Bytes.hex(identity.linkKey)))
        let wrapped = try XCTUnwrap(band.requests(service: 0x01, command: 0x0e).first?.bytes(0x06))
        XCTAssertFalse(log.contains(Bytes.hex(wrapped)), "the wrapped key would reveal the link key to anyone who knows the address")
        XCTAssertTrue(log.contains("01/0E (contents withheld)"))
        XCTAssertTrue(log.contains("Paired with CRS-B19"))
    }

    // MARK: Transport behaviour

    func testCommandsBeforePairingAreRefused() async {
        let band = SimulatedBand()
        let session = BandSession(transport: band, timing: fastTiming)
        await session.start()
        await assertThrows(.notPaired) { try await session.batteryLevel() }
    }

    func testSilentBandTimesOut() async throws {
        let band = SimulatedBand()
        let session = BandSession(transport: band, timing: fastTiming)
        _ = try await session.open(identity: makeIdentity())
        band.silentCommands = [0x0108]
        await assertThrows(.timeout(service: 0x01, command: 0x08)) { try await session.batteryLevel() }
        // The session is still usable afterwards.
        band.silentCommands = []
        let level = try await session.batteryLevel()
        XCTAssertEqual(level, 73)
    }

    func testDisconnectFailsTheWaitingRequestAndLaterOnes() async throws {
        let band = SimulatedBand()
        let session = BandSession(transport: band, timing: BandSession.Timing(reply: 5, bonding: 5))
        _ = try await session.open(identity: makeIdentity())
        band.silentCommands = [0x0108]

        async let level = session.batteryLevel()
        try await Task.sleep(nanoseconds: 100_000_000)
        band.disconnect()
        do {
            _ = try await level
            XCTFail("expected a disconnect")
        } catch {
            XCTAssertEqual(error as? BandError, .disconnected)
        }
        await assertThrows(.disconnected) { try await session.batteryLevel() }
    }

    func testRequestsIssuedTogetherAreAnsweredInTurn() async throws {
        let band = SimulatedBand()
        let session = BandSession(transport: band, timing: fastTiming)
        _ = try await session.open(identity: makeIdentity())

        async let first = session.batteryLevel()
        async let second = session.deviceInfo()
        async let third = session.batteryLevel()
        let (a, b, c) = try await (first, second, third)
        XCTAssertEqual(a, 73)
        XCTAssertEqual(b.softwareVersion, "1.1.0.74")
        XCTAssertEqual(c, 73)
    }

    func testLongRepliesAcrossSmallFramesAndTinyNotifications() async throws {
        let band = SimulatedBand()
        band.sliceSize = 64          // forces replies into several slices
        band.notificationChunk = 7   // and every slice into several notifications
        band.linkMTU = 20
        let session = BandSession(transport: band, timing: fastTiming)
        _ = try await session.open(identity: makeIdentity())

        let base = 1_700_000_000
        band.activityBlocks = [SimulatedBand.activityBlock(base: base, minutes: (0..<50).map {
            (offset: $0, steps: 100 + $0, calories: 4, distance: 70, heartRate: 60 + $0)
        })]
        let minutes = try await session.activityBlock(0)
        XCTAssertEqual(minutes.count, 50)
        XCTAssertEqual(minutes[49], ActivityMinute(timestamp: base + 49 * 60, steps: 149, calories: 4, distance: 70, heartRate: 109))
    }

    func testUnsolicitedBatteryEvent() async throws {
        let band = SimulatedBand()
        let session = BandSession(transport: band, timing: fastTiming)
        _ = try await session.open(identity: makeIdentity())

        band.push(service: 0x01, command: 0x27, body: TLV().adding(0x01, byte: 12))
        band.push(service: 0x0b, command: 0x01, body: TLV().adding(0x01, byte: 1))
        var seen = [BandEvent]()
        for await event in session.events {
            seen.append(event)
            if seen.count == 2 { break }
        }
        XCTAssertEqual(seen, [.batteryLevel(12), .unhandled(service: 0x0b, command: 0x01)])
    }

    // MARK: Commands

    func testSetTimeEncoding() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(BandCommands.setTime(date, timeZone: TimeZone(secondsFromGMT: 0)!).serialized(),
                       [0x01, 0x04, 0x65, 0x53, 0xf1, 0x00, 0x02, 0x02, 0x00, 0x00])
        XCTAssertEqual(BandCommands.setTime(date, timeZone: TimeZone(secondsFromGMT: 19_800)!).bytes(0x02), [5, 30], "+05:30")
        XCTAssertEqual(BandCommands.setTime(date, timeZone: TimeZone(secondsFromGMT: -18_000)!).bytes(0x02), [0x85, 0], "-05:00")
        XCTAssertEqual(BandCommands.setTime(date, timeZone: TimeZone(secondsFromGMT: -12_600)!).bytes(0x02), [0x83, 30], "-03:30")
    }

    func testSettingsAreSentAndRefusalsDoNotStopTheRest() async throws {
        let band = SimulatedBand()
        let session = BandSession(transport: band, timing: fastTiming)
        _ = try await session.open(identity: makeIdentity())
        band.refusedCommands = [0x011b]

        var settings = BandSettings()
        settings.use24HourClock = false
        settings.dateOrder = .monthFirst
        settings.wornOnLeftWrist = false
        settings.stepGoal = 8000
        settings.languageTag = "en-US"
        settings.useMetricUnits = false
        settings.profile = UserProfile(heightCm: 180, weightKg: 75, sex: .female, birthYear: 1990, birthMonth: 6, birthDay: 15)
        let now = Date(timeIntervalSince1970: 1_700_000_000)   // 14 November 2023
        let results = await session.apply(settings, now: now)

        XCTAssertEqual(results.count, 9)
        XCTAssertEqual(results.filter { $0.error != nil }.map(\.step), ["rotate to switch"])

        XCTAssertEqual(band.requests(service: 0x01, command: 0x04), [TLV().adding(0x81, nested: TLV().adding(0x02, byte: 2).adding(0x03, byte: 1))])
        XCTAssertEqual(band.requests(service: 0x0c, command: 0x01), [TLV().adding(0x01, string: "en-US").adding(0x02, byte: 1)])
        XCTAssertEqual(band.requests(service: 0x01, command: 0x1a), [TLV().adding(0x01, byte: 0)])
        XCTAssertEqual(band.requests(service: 0x01, command: 0x09), [TLV().adding(0x01, byte: 1)])
        XCTAssertEqual(band.requests(service: 0x07, command: 0x16), [TLV().adding(0x01, byte: 0)], "on-band sleep analysis stays on")
        XCTAssertEqual(band.requests(service: 0x07, command: 0x17), [TLV().adding(0x01, byte: 1)])
        XCTAssertEqual(band.requests(service: 0x07, command: 0x01),
                       [TLV().adding(0x81, nested: TLV().adding(0x82, nested: TLV().adding(0x03, byte: 1).adding(0x04, byte: 0).adding(0x05, uint32: 8000)))])
        XCTAssertEqual(band.requests(service: 0x07, command: 0x02), [TLV()
            .adding(0x01, byte: 180).adding(0x02, byte: 75).adding(0x03, byte: 33)
            .adding(0x04, bytes: [0x07, 0xc6, 0x06, 0x0f]).adding(0x05, byte: 2)
            .adding(0x06, byte: 76).adding(0x07, byte: 149)])
    }

    func testProfileAge() {
        let profile = UserProfile(birthYear: 1990, birthMonth: 6, birthDay: 15)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
            calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
        }
        XCTAssertEqual(profile.age(on: date(2023, 6, 14), calendar: calendar), 32)
        XCTAssertEqual(profile.age(on: date(2023, 6, 15), calendar: calendar), 33)
        XCTAssertEqual(profile.age(on: date(1980, 1, 1), calendar: calendar), 0, "never negative")
    }

    // MARK: Parsing

    func testActivityRecordParsing() {
        // Layout taken from another open-source implementation's test data for this message.
        let reply = TLV().adding(0x81, nested: TLV()
            .adding(0x02, uint16: 0x1337)
            .adding(0x03, uint32: 0x6553_f100)
            .adding(0x84, nested: TLV().adding(0x05, byte: 0).adding(0x06, bytes: []))
            .adding(0x84, nested: TLV().adding(0x05, byte: 1).adding(0x06, bytes: [0x01, 0x02]))
            .adding(0x84, nested: TLV().adding(0x05, byte: 2).adding(0x06, bytes: [0x0e, 0x00, 0x01, 0x00, 0x02, 0x00, 0x03]))
            .adding(0x84, nested: TLV().adding(0x05, byte: 3).adding(0x06, bytes: [0x01, 0x00, 0x01])))
        let parsed = ActivityParser.minutes(reply)
        XCTAssertEqual(parsed.skipped, 2, "an empty record and a truncated one")
        XCTAssertEqual(parsed.minutes, [
            ActivityMinute(timestamp: 0x6553_f100 + 120, steps: 1, calories: 2, distance: 3),
            ActivityMinute(timestamp: 0x6553_f100 + 180),   // only a field this app does not interpret
        ])
        XCTAssertFalse(parsed.minutes[1].hasData)
    }

    func testActivityRecordWithHeartRateAndSecondBitmap() {
        // steps + heart rate, then a second bitmap carrying blood oxygen and resting heart rate.
        XCTAssertEqual(ActivityParser.minute(timestamp: 60, record: [0xc2, 0x03, 0x00, 0x2a, 0x48, 0x61, 0x37]),
                       ActivityMinute(timestamp: 60, steps: 42, heartRate: 72, spo2: 97, restingHeartRate: 55))
        // 0x20 is a one-byte field that must be stepped over to reach the heart rate.
        XCTAssertEqual(ActivityParser.minute(timestamp: 60, record: [0x60, 0x09, 0x50])?.heartRate, 80)
        // 0 and 255 mean "no reading".
        XCTAssertNil(ActivityParser.minute(timestamp: 60, record: [0x40, 0x00])?.heartRate)
        XCTAssertNil(ActivityParser.minute(timestamp: 60, record: [0x40, 0xff])?.heartRate)
        // Truncated in the second bitmap.
        XCTAssertNil(ActivityParser.minute(timestamp: 60, record: [0x80]))
        XCTAssertNil(ActivityParser.minute(timestamp: 60, record: [0x80, 0x01]))
        // Offsets above 127 are unsigned.
        let block = SimulatedBand.activityBlock(base: 1000, minutes: [(offset: 200, steps: 5, calories: nil, distance: nil, heartRate: nil)])
        XCTAssertEqual(ActivityParser.minutes(block).minutes.first?.timestamp, 1000 + 200 * 60)
    }

    func testSleepParsing() {
        let reply = TLV().adding(0x81, nested: TLV()
            .adding(0x02, uint16: 0)
            .adding(0x83, nested: TLV().adding(0x04, byte: 6).adding(0x05, bytes: [0x65, 0x53, 0xf1, 0x00, 0x00, 0x2d]))
            .adding(0x83, nested: TLV().adding(0x04, byte: 7).adding(0x05, bytes: [0x65, 0x53, 0xfb, 0x8c, 0x01, 0x00]))
            .adding(0x83, nested: TLV().adding(0x04, byte: 1).adding(0x05, bytes: [0x01, 0x02]))        // too short
            .adding(0x83, nested: TLV().adding(0x04, byte: 6).adding(0x05, bytes: [0x65, 0x53, 0xf1, 0x00, 0x00, 0x00])))  // zero length
        let segments = ActivityParser.sleep(reply)
        XCTAssertEqual(segments, [
            SleepSegment(start: 0x6553_f100, end: 0x6553_f100 + 45 * 60, rawStage: 6),
            SleepSegment(start: 0x6553_fb8c, end: 0x6553_fb8c + 256 * 60, rawStage: 7),
        ])
        XCTAssertEqual(segments.map(\.stage), [.light, .deep])
        XCTAssertEqual(SleepSegment(start: 0, end: 60, rawStage: 3).stage, .other)
    }

    func testTotalsParsing() {
        let reply = SimulatedBand.totals([(kind: 1, steps: 5000, calories: 180, distance: 3600), (kind: 2, steps: 1200, calories: 90, distance: 1100)])
        let totals = ActivityParser.totals(reply)
        XCTAssertEqual(totals?.steps, 6200)
        XCTAssertEqual(totals?.calories, 270)
        XCTAssertEqual(totals?.distance, 4700)
        XCTAssertEqual(totals?.activities.map(\.kind), [1, 2])
        XCTAssertNil(ActivityParser.totals(TLV().adding(0x7f, uint32: 100_000)))
    }
}
