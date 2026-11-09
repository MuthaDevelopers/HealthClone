import XCTest
@testable import BandKit

final class StoreAndSyncTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("bandkit-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // 2023-11-14 00:00:00 UTC.
    private let midnight = 1_699_920_000

    // MARK: Store

    func testMinutesMergePersistAndSpanDays() async throws {
        let store = try HealthStore(directory: directory)
        let added = try await store.addMinutes([
            ActivityMinute(timestamp: midnight - 60, steps: 10),
            ActivityMinute(timestamp: midnight, steps: 20, heartRate: 61),
            ActivityMinute(timestamp: midnight + 60, steps: 30),
            ActivityMinute(timestamp: midnight + 120),   // carries nothing, so it is not stored
        ])
        XCTAssertEqual(added, 3)

        // A later sync re-reads the same minute with more fields: merged, not duplicated.
        let again = try await store.addMinutes([
            ActivityMinute(timestamp: midnight, steps: 25, calories: 2),
            ActivityMinute(timestamp: midnight + 180, steps: 5),
        ])
        XCTAssertEqual(again, 1)

        let all = try await store.minutes(from: midnight - 3600, to: midnight + 3600)
        XCTAssertEqual(all.map(\.timestamp), [midnight - 60, midnight, midnight + 60, midnight + 180])
        XCTAssertEqual(all[1], ActivityMinute(timestamp: midnight, steps: 25, calories: 2, heartRate: 61),
                       "new fields win, fields the new reading lacks are kept")

        // The range is half-open.
        let exact = try await store.minutes(from: midnight, to: midnight + 60)
        XCTAssertEqual(exact.map(\.timestamp), [midnight])
        let empty = try await store.minutes(from: midnight, to: midnight)
        XCTAssertTrue(empty.isEmpty)

        // One file per UTC day, and a fresh store reads the same data back.
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("activity").path).sorted()
        XCTAssertEqual(files, ["2023-11-13.json", "2023-11-14.json"])
        let reopened = try HealthStore(directory: directory)
        let reloaded = try await reopened.minutes(from: midnight - 3600, to: midnight + 3600)
        XCTAssertEqual(reloaded, all)
    }

    func testSleepUpsertsAndCrossesMonths() async throws {
        let store = try HealthStore(directory: directory)
        let monthEnd = 1_701_388_800   // 2023-12-01 00:00:00 UTC
        let added = try await store.addSleep([
            SleepSegment(start: monthEnd - 3600, end: monthEnd + 1800, rawStage: 6),   // starts in November, ends in December
            SleepSegment(start: monthEnd + 1800, end: monthEnd + 5400, rawStage: 7),
            SleepSegment(start: monthEnd + 9000, end: monthEnd + 9000, rawStage: 6),   // empty, ignored
        ])
        XCTAssertEqual(added, 2)

        // The first segment was still growing; the next sync reports it longer.
        let updated = try await store.addSleep([SleepSegment(start: monthEnd - 3600, end: monthEnd + 1900, rawStage: 6)])
        XCTAssertEqual(updated, 0)

        let december = try await store.sleep(from: monthEnd, to: monthEnd + 86_400)
        XCTAssertEqual(december.map(\.start), [monthEnd - 3600, monthEnd + 1800], "a segment that began last month but overlaps is included")
        XCTAssertEqual(december.first?.end, monthEnd + 1900)

        let before = try await store.sleep(from: monthEnd - 86_400, to: monthEnd - 3600)
        XCTAssertTrue(before.isEmpty, "touching the range boundary is not overlapping")

        let reopened = try HealthStore(directory: directory)
        let reloaded = try await reopened.sleep(from: monthEnd - 86_400, to: monthEnd + 86_400)
        XCTAssertEqual(reloaded.count, 2)
    }

    func testStatePersistsAndEraseClearsEverything() async throws {
        let store = try HealthStore(directory: directory)
        let initial = await store.state()
        XCTAssertEqual(initial, StoreState())

        let when = Date(timeIntervalSince1970: 1_700_000_000)
        try await store.updateState {
            $0.batteryLevel = 64
            $0.lastSync = when
            $0.device = DeviceInfo(softwareVersion: "1.1.0.74", model: "CRS-B19")
            $0.bandTotals = BandTotals(steps: 1, calories: 2, distance: 3)
        }
        try await store.addMinutes([ActivityMinute(timestamp: midnight, steps: 1)])

        let reopened = try HealthStore(directory: directory)
        let loaded = await reopened.state()
        XCTAssertEqual(loaded.batteryLevel, 64)
        XCTAssertEqual(loaded.lastSync, when)
        XCTAssertEqual(loaded.device?.model, "CRS-B19")
        XCTAssertEqual(loaded.bandTotals?.distance, 3)

        try await reopened.eraseAll()
        let erasedState = await reopened.state()
        XCTAssertEqual(erasedState, StoreState())
        let erasedMinutes = try await reopened.minutes(from: midnight - 86_400, to: midnight + 86_400)
        XCTAssertTrue(erasedMinutes.isEmpty)
        try await reopened.addMinutes([ActivityMinute(timestamp: midnight, steps: 7)])   // still usable
    }

    func testDayKeysHandleEarlyTimestamps() {
        XCTAssertEqual(HealthStore.dayNumber(0), 0)
        XCTAssertEqual(HealthStore.dayNumber(86_399), 0)
        XCTAssertEqual(HealthStore.dayNumber(86_400), 1)
        XCTAssertEqual(HealthStore.dayNumber(-1), -1)
        XCTAssertEqual(HealthStore.monthKey(1_701_388_799), "2023-11")
        XCTAssertEqual(HealthStore.monthKey(1_701_388_800), "2023-12")
    }

    // MARK: Summaries

    func testDaySummary() {
        let dayStart = midnight, dayEnd = midnight + 86_400
        let minutes = [
            ActivityMinute(timestamp: dayStart - 60, steps: 999),                                        // previous day
            ActivityMinute(timestamp: dayStart + 8 * 3600, steps: 100, calories: 4, distance: 70, heartRate: 90),
            ActivityMinute(timestamp: dayStart + 8 * 3600 + 60, steps: 50, calories: 2, distance: 35, heartRate: 110),
            ActivityMinute(timestamp: dayStart + 13 * 3600, heartRate: 62, restingHeartRate: 58),          // heart rate only
            ActivityMinute(timestamp: dayStart + 23 * 3600 + 59 * 60, steps: 7, calories: 1, distance: 5),
            ActivityMinute(timestamp: dayEnd, steps: 999),                                               // next day
        ]
        let summary = Summaries.day(dayStart: dayStart, dayEnd: dayEnd, minutes: minutes, sleep: [])
        XCTAssertEqual(summary.steps, 157)
        XCTAssertEqual(summary.calories, 7)
        XCTAssertEqual(summary.distance, 110)
        XCTAssertFalse(summary.usesBandTotals)
        XCTAssertEqual(summary.activeMinutes, 3)
        XCTAssertEqual(summary.hourlySteps[8], 150)
        XCTAssertEqual(summary.hourlySteps[23], 7)
        XCTAssertEqual(summary.hourlySteps.reduce(0, +), 157)
        XCTAssertEqual(summary.heartRate.map(\.bpm), [90, 110, 62])
        XCTAssertEqual(summary.heartRateMin, 62)
        XCTAssertEqual(summary.heartRateMax, 110)
        XCTAssertEqual(summary.heartRateAverage, 87)
        XCTAssertEqual(summary.restingHeartRate, 58)
        XCTAssertNil(summary.sleep)

        let withTotals = Summaries.day(dayStart: dayStart, dayEnd: dayEnd, minutes: minutes, sleep: [],
                                       bandTotals: BandTotals(steps: 200, calories: 9, distance: 150))
        XCTAssertEqual([withTotals.steps, withTotals.calories, withTotals.distance], [200, 9, 150])
        XCTAssertTrue(withTotals.usesBandTotals)
        XCTAssertEqual(withTotals.hourlySteps[8], 150, "the hourly chart still comes from the minutes")

        let empty = Summaries.day(dayStart: dayStart, dayEnd: dayEnd, minutes: [], sleep: [])
        XCTAssertEqual(empty.steps, 0)
        XCTAssertNil(empty.heartRateAverage)
    }

    func testDayWithExtraHourDoesNotOverflowTheChart() {
        // A 25-hour day when clocks go back: the last hour folds into the final bucket.
        let summary = Summaries.day(dayStart: midnight, dayEnd: midnight + 25 * 3600,
                                    minutes: [ActivityMinute(timestamp: midnight + 24 * 3600 + 60, steps: 9)], sleep: [])
        XCTAssertEqual(summary.hourlySteps.count, 24)
        XCTAssertEqual(summary.hourlySteps[23], 9)
    }

    func testSleepIsAttributedToTheDayItEndsOnAndNapsAreSeparate() {
        let dayStart = midnight, dayEnd = midnight + 86_400
        func segment(_ startHour: Double, _ minutes: Int, _ stage: Int) -> SleepSegment {
            let start = dayStart + Int(startHour * 3600)
            return SleepSegment(start: start, end: start + minutes * 60, rawStage: stage)
        }
        let segments = [
            segment(-30, 300, 6),   // the night before last: outside the window
            segment(-1, 90, 6),     // 23:00 light
            segment(0.5, 60, 7),    // 00:30 deep
            segment(1.75, 120, 6),  // 01:45 light, after a 15 minute gap awake
            segment(3.75, 75, 7),   // 03:45 deep
            segment(14, 25, 6),     // 14:00 nap
            segment(22.5, 60, 6),   // 22:30 that evening: belongs to tomorrow
        ]
        let summary = Summaries.sleepSummary(dayStart: dayStart, dayEnd: dayEnd, segments: segments)
        XCTAssertEqual(summary?.night.segments.count, 4)
        XCTAssertEqual(summary?.night.start, dayStart - 3600)
        XCTAssertEqual(summary?.night.end, dayStart + 5 * 3600)
        XCTAssertEqual(summary?.night.lightMinutes, 210)
        XCTAssertEqual(summary?.night.deepMinutes, 135)
        XCTAssertEqual(summary?.night.asleepMinutes, 345)
        XCTAssertEqual(summary?.night.awakeMinutes, 15)
        XCTAssertEqual(summary?.naps.count, 1)
        XCTAssertEqual(summary?.napMinutes, 25)

        let tomorrow = Summaries.sleepSummary(dayStart: dayEnd, dayEnd: dayEnd + 86_400, segments: segments)
        XCTAssertEqual(tomorrow?.night.segments.map(\.start), [dayStart + Int(22.5 * 3600)])
        XCTAssertNil(Summaries.sleepSummary(dayStart: dayStart + 10 * 86_400, dayEnd: dayStart + 11 * 86_400, segments: segments))
        XCTAssertEqual(Summaries.sleepWindow(dayStart: dayStart, dayEnd: dayEnd), (dayStart - 14_400)..<(dayEnd - 14_400))
    }

    // MARK: Address guessing

    func testAddressGuess() {
        XCTAssertEqual(AddressGuess.nameSuffix("HONOR Band 4-5F1"), "5F1")
        XCTAssertEqual(AddressGuess.nameSuffix("honor band 4-a0c"), "A0C")
        XCTAssertNil(AddressGuess.nameSuffix("HONOR Band 4"))
        XCTAssertNil(AddressGuess.nameSuffix("Some-Thing"))

        let address = BandAddress("6C:B7:49:12:35:F1")!
        // Forward, reversed and as text, each surrounded by unrelated bytes.
        XCTAssertEqual(AddressGuess.candidates(suffix: "5F1", in: [[0x01, 0x02, 0x6c, 0xb7, 0x49, 0x12, 0x35, 0xf1, 0x09]]), [address])
        XCTAssertEqual(AddressGuess.candidates(suffix: "5F1", in: [[0xf1, 0x35, 0x12, 0x49, 0xb7, 0x6c]]), [address])
        XCTAssertEqual(AddressGuess.candidates(suffix: "5F1", in: [Array("6C:B7:49:12:35:F1".utf8)]), [address])
        XCTAssertEqual(AddressGuess.candidates(suffix: "5F1", in: [[0x01, 0x02, 0x03], []]), [])
        XCTAssertEqual(AddressGuess.candidates(suffix: "5F1", in: [[0x6c, 0xb7, 0x49, 0x12, 0x35, 0xf2]]), [])
        XCTAssertEqual(AddressGuess.candidates(suffix: "5F1", in: [[0, 0, 0, 0x12, 0x35, 0xf1]]), [], "zero padding is not an address")

        XCTAssertTrue(AddressGuess.matches(address, name: "HONOR Band 4-5F1"))
        XCTAssertFalse(AddressGuess.matches(address, name: "HONOR Band 4-5F2"))
        XCTAssertTrue(AddressGuess.matches(address, name: "Unnamed"), "no suffix to check against")
    }

    // MARK: Sync

    private func pairedSession(_ band: SimulatedBand, logger: BandLogger = SilentLogger()) async throws -> BandSession {
        let session = BandSession(transport: band, logger: logger, timing: BandSession.Timing(reply: 0.4, bonding: 0.6))
        _ = try await session.open(identity: PairingIdentity.generate(deviceAddress: band.address))
        return session
    }

    func testSyncStoresEverythingAndResumesFromWhereItStopped() async throws {
        let band = SimulatedBand()
        let now = Date(timeIntervalSince1970: TimeInterval(midnight + 9 * 3600))
        let nightStart = midnight - 3600
        band.sleepBlocks = [SimulatedBand.sleepBlock([(start: nightStart, minutes: 90, stage: 6), (start: nightStart + 5400, minutes: 60, stage: 7)])]
        band.activityBlocks = [
            SimulatedBand.activityBlock(base: midnight + 7 * 3600, minutes: [
                (offset: 0, steps: 40, calories: 2, distance: 30, heartRate: 71),
                (offset: 1, steps: 60, calories: 3, distance: 45, heartRate: nil),
            ]),
            SimulatedBand.activityBlock(base: midnight + 8 * 3600, minutes: [(offset: 30, steps: 20, calories: 1, distance: 15, heartRate: 80)]),
        ]
        band.totals = SimulatedBand.totals([(kind: 1, steps: 120, calories: 6, distance: 90)])

        let store = try HealthStore(directory: directory)
        let session = try await pairedSession(band)
        let phases = Phases()
        let report = try await SyncEngine(session: session, store: store).run(now: now, timeZone: TimeZone(secondsFromGMT: 3600)!) { phases.add($0.phase) }

        XCTAssertEqual(report.newMinutes, 3)
        XCTAssertEqual(report.newSleepSegments, 2)
        XCTAssertEqual(report.batteryLevel, 73)
        XCTAssertEqual(report.totals?.steps, 120)
        XCTAssertEqual(report.warnings, [])
        XCTAssertEqual(phases.distinct, [.preparing, .sleep, .activity, .totals, .finished])
        XCTAssertEqual(band.clockSet, midnight + 9 * 3600, "the band's clock was corrected")

        let state = await store.state()
        XCTAssertEqual(state.activityCursor, midnight + 8 * 3600 + 30 * 60)
        XCTAssertEqual(state.sleepCursor, nightStart + 5400 + 3600)
        XCTAssertEqual(state.lastSync, now)
        XCTAssertEqual(state.bandTotals?.distance, 90)
        XCTAssertEqual(state.batteryLevel, 73)

        // The first sync asks for everything the band has.
        XCTAssertEqual(band.countRequests.map(\.start), [SyncEngine.earliestStart, SyncEngine.earliestStart])
        XCTAssertEqual(band.countRequests.map(\.end), [midnight + 9 * 3600, midnight + 9 * 3600])

        // Syncing again adds nothing and resumes just before the newest stored sample.
        let later = now.addingTimeInterval(600)
        let second = try await SyncEngine(session: session, store: store).run(now: later)
        XCTAssertEqual(second.newMinutes, 0)
        XCTAssertEqual(second.newSleepSegments, 0)
        XCTAssertEqual(band.countRequests[2].start, nightStart + 5400 + 3600 - SyncEngine.sleepOverlap)
        XCTAssertEqual(band.countRequests[3].start, midnight + 8 * 3600 + 30 * 60 - SyncEngine.activityOverlap)

        let day = try await store.minutes(from: midnight, to: midnight + 86_400)
        XCTAssertEqual(day.compactMap(\.steps).reduce(0, +), 120, "the per-minute steps add up to the band's own total")
    }

    func testSyncIgnoresSamplesWithImpossibleTimestamps() async throws {
        let band = SimulatedBand()
        let now = Date(timeIntervalSince1970: TimeInterval(midnight))
        band.activityBlocks = [
            SimulatedBand.activityBlock(base: 946_700_000, minutes: [(offset: 0, steps: 5, calories: nil, distance: nil, heartRate: nil)]),            // year 2000: clock was unset
            SimulatedBand.activityBlock(base: midnight + 30 * 86_400, minutes: [(offset: 0, steps: 5, calories: nil, distance: nil, heartRate: nil)]), // a month ahead
            SimulatedBand.activityBlock(base: midnight - 3600, minutes: [(offset: 0, steps: 5, calories: nil, distance: nil, heartRate: nil)]),
        ]
        band.sleepBlocks = [SimulatedBand.sleepBlock([(start: 946_700_000, minutes: 30, stage: 6)])]
        band.totals = SimulatedBand.totals([])

        let store = try HealthStore(directory: directory)
        let report = try await SyncEngine(session: try await pairedSession(band), store: store).run(now: now)
        XCTAssertEqual(report.newMinutes, 1)
        XCTAssertEqual(report.newSleepSegments, 0)
        XCTAssertEqual(report.rejectedSamples, 3)
        XCTAssertEqual(report.warnings.count, 1)
        let state = await store.state()
        XCTAssertEqual(state.activityCursor, midnight - 3600, "a bogus future sample must not push the cursor forward")
        XCTAssertNil(state.sleepCursor)
    }

    func testSyncRetriesALostReplyAndToleratesOptionalFailures() async throws {
        let band = SimulatedBand()
        band.activityBlocks = [SimulatedBand.activityBlock(base: midnight - 3600, minutes: [(offset: 0, steps: 5, calories: nil, distance: nil, heartRate: nil)])]
        band.silentCommands = [0x0108, 0x0703]   // battery and totals never answer
        let store = try HealthStore(directory: directory)
        let session = try await pairedSession(band)

        // Drop the reply to the first activity block; the retry gets it.
        band.refusedCommands = [0x0105]          // and the clock cannot be set
        let engine = SyncEngine(session: session, store: store)
        let dropper = Task {
            // Wait until the block count has been answered, then lose the next reply.
            while band.requests(service: 0x07, command: 0x0a).isEmpty { try await Task.sleep(nanoseconds: 5_000_000) }
            band.repliesToDrop = 1
        }
        let report = try await engine.run(now: Date(timeIntervalSince1970: TimeInterval(midnight)))
        _ = try await dropper.value

        XCTAssertEqual(report.newMinutes, 1)
        XCTAssertNil(report.batteryLevel)
        XCTAssertNil(report.totals)
        XCTAssertEqual(report.warnings.count, 3, "clock, battery and totals each produced a warning but did not stop the sync")
        XCTAssertGreaterThanOrEqual(band.requests(service: 0x07, command: 0x0b).count, 1)
    }

    func testSyncStopsWhenTheLinkDrops() async throws {
        let band = SimulatedBand()
        let store = try HealthStore(directory: directory)
        let session = try await pairedSession(band)
        band.disconnect()
        try await Task.sleep(nanoseconds: 50_000_000)
        do {
            _ = try await SyncEngine(session: session, store: store).run()
            XCTFail("expected the sync to fail")
        } catch {
            XCTAssertEqual(error as? BandError, .disconnected)
        }
        let state = await store.state()
        XCTAssertNil(state.lastSync, "a failed sync is not recorded as a sync")
    }
}

private final class Phases: @unchecked Sendable {
    private let lock = NSLock()
    private var seen = [SyncProgress.Phase]()

    func add(_ phase: SyncProgress.Phase) {
        lock.lock(); defer { lock.unlock() }
        seen.append(phase)
    }

    /// Phases in the order first seen.
    var distinct: [SyncProgress.Phase] {
        lock.lock(); defer { lock.unlock() }
        var result = [SyncProgress.Phase]()
        for phase in seen where result.last != phase { result.append(phase) }
        return result
    }
}
