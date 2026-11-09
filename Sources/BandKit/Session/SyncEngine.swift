import Foundation

public struct SyncProgress: Equatable, Sendable {
    public enum Phase: String, Sendable {
        case preparing, sleep, activity, totals, finished
    }

    public var phase: Phase
    public var completed: Int
    public var total: Int

    public init(phase: Phase, completed: Int = 0, total: Int = 0) {
        self.phase = phase
        self.completed = completed
        self.total = total
    }
}

public struct SyncReport: Equatable, Sendable {
    public var newMinutes = 0
    public var newSleepSegments = 0
    public var totals: BandTotals?
    public var batteryLevel: Int?
    /// Samples dropped because their timestamps made no sense, usually from a band whose clock
    /// had been reset.
    public var rejectedSamples = 0
    /// Steps that failed without stopping the sync.
    public var warnings = [String]()
}

/// Copies new data from the band into the store.
///
/// The band keeps several days of history. Each sync asks for everything since the newest sample
/// already stored, minus a little overlap, and the store merges by timestamp, so syncing twice or
/// being interrupted part-way never loses or doubles anything.
public struct SyncEngine: Sendable {
    /// The band rejects a start time of zero; this is 2000-01-01.
    static let earliestStart = 946_684_800
    /// Samples older than this (2015-01-01) predate the band and can only come from an unset clock.
    static let earliestPlausible = 1_420_070_400
    static let activityOverlap = 60 * 60
    static let sleepOverlap = 12 * 60 * 60
    /// Stops a corrupt count from starting an endless transfer.
    static let maximumBlocks = 20_000

    private let session: BandSession
    private let store: HealthStore
    private let logger: BandLogger

    public init(session: BandSession, store: HealthStore, logger: BandLogger = SilentLogger()) {
        self.session = session
        self.store = store
        self.logger = logger
    }

    public func run(now: Date = Date(), timeZone: TimeZone = .current,
                    progress: (@Sendable (SyncProgress) -> Void)? = nil) async throws -> SyncReport {
        var report = SyncReport()
        let end = Int(now.timeIntervalSince1970)
        let latestPlausible = end + 86_400
        let state = await store.state()
        progress?(SyncProgress(phase: .preparing))

        // Correct the band's clock first so that everything it records from here on is timed right.
        do {
            try await session.setTime(now, timeZone: timeZone)
        } catch {
            try rethrowIfFatal(error)
            report.warnings.append("Could not set the band's clock: \(describe(error))")
        }

        do {
            let level = try await session.batteryLevel()
            report.batteryLevel = level
            try await store.updateState { $0.batteryLevel = level; $0.batteryUpdated = now }
        } catch {
            try rethrowIfFatal(error)
            report.warnings.append("Could not read the battery level: \(describe(error))")
        }

        // Sleep.
        let sleepStart = max(SyncEngine.earliestStart, (state.sleepCursor ?? SyncEngine.earliestStart) - SyncEngine.sleepOverlap)
        let sleepBlocks = min(try await session.sleepBlockCount(from: sleepStart, to: end), SyncEngine.maximumBlocks)
        logger.log(.info, "Sleep: \(sleepBlocks) block(s) since \(sleepStart)")
        var sleepCursor = state.sleepCursor ?? 0
        for index in 0..<sleepBlocks {
            progress?(SyncProgress(phase: .sleep, completed: index, total: sleepBlocks))
            let segments = try await retrying { try await session.sleepBlock(index) }
            let valid = segments.filter { $0.start >= SyncEngine.earliestPlausible && $0.end <= latestPlausible }
            report.rejectedSamples += segments.count - valid.count
            report.newSleepSegments += try await store.addSleep(valid)
            if let newest = valid.map(\.end).max(), newest > sleepCursor {
                sleepCursor = newest
                let cursor = sleepCursor
                try await store.updateState { $0.sleepCursor = cursor }
            }
        }

        // Activity: steps, distance, energy and heart rate, minute by minute.
        let activityStart = max(SyncEngine.earliestStart, (state.activityCursor ?? SyncEngine.earliestStart) - SyncEngine.activityOverlap)
        let activityBlocks = min(try await session.activityBlockCount(from: activityStart, to: end), SyncEngine.maximumBlocks)
        logger.log(.info, "Activity: \(activityBlocks) block(s) since \(activityStart)")
        var activityCursor = state.activityCursor ?? 0
        for index in 0..<activityBlocks {
            progress?(SyncProgress(phase: .activity, completed: index, total: activityBlocks))
            let minutes = try await retrying { try await session.activityBlock(index) }
            let valid = minutes.filter { $0.timestamp >= SyncEngine.earliestPlausible && $0.timestamp <= latestPlausible }
            report.rejectedSamples += minutes.count - valid.count
            report.newMinutes += try await store.addMinutes(valid)
            if let newest = valid.map(\.timestamp).max(), newest > activityCursor {
                activityCursor = newest
                let cursor = activityCursor
                try await store.updateState { $0.activityCursor = cursor }
            }
        }

        // The band's own headline figures for today.
        progress?(SyncProgress(phase: .totals))
        do {
            let totals = try await session.todayTotals()
            report.totals = totals
            try await store.updateState { $0.bandTotals = totals; $0.bandTotalsUpdated = now }
        } catch {
            try rethrowIfFatal(error)
            report.warnings.append("Could not read today's totals: \(describe(error))")
        }

        try await store.updateState { $0.lastSync = now }
        if report.rejectedSamples > 0 {
            report.warnings.append("\(report.rejectedSamples) sample(s) had impossible timestamps and were ignored.")
        }
        for warning in report.warnings { logger.log(.warning, warning) }
        logger.log(.info, "Sync finished: \(report.newMinutes) new minute(s), \(report.newSleepSegments) new sleep segment(s)")
        progress?(SyncProgress(phase: .finished))
        return report
    }

    /// One retry on a timeout: a single lost notification should not abandon a long transfer.
    private func retrying<Value: Sendable>(_ operation: @Sendable () async throws -> Value) async throws -> Value {
        do {
            return try await operation()
        } catch let error as BandError {
            guard case .timeout = error else { throw error }
            logger.log(.warning, "Timed out; retrying once")
            return try await operation()
        }
    }

    /// Optional steps may fail quietly, but not when the link itself is gone.
    private func rethrowIfFatal(_ error: Error) throws {
        if let bandError = error as? BandError, bandError == .disconnected || bandError == .notPaired { throw error }
    }

    private func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}
