import Foundation

/// Everything the app remembers besides the health samples themselves.
public struct StoreState: Equatable, Sendable, Codable {
    /// Timestamp of the newest activity minute stored; the next sync resumes from here.
    public var activityCursor: Int?
    /// End of the newest sleep segment stored.
    public var sleepCursor: Int?
    public var lastSync: Date?
    public var batteryLevel: Int?
    public var batteryUpdated: Date?
    public var device: DeviceInfo?
    /// The band's own totals from the most recent sync, and when they were read.
    public var bandTotals: BandTotals?
    public var bandTotalsUpdated: Date?

    public init() {}
}

/// On-disk store for synced health data.
///
/// Activity is kept in one small JSON file per UTC day and sleep in one per UTC month, so a sync
/// only rewrites the few files it touches and reading a week never loads a year. Files are keyed
/// by UTC rather than local time so that travelling across time zones cannot split or duplicate
/// data; callers ask for a time range and get whatever falls inside it.
public actor HealthStore {
    private let root: URL
    private let fileManager = FileManager.default
    private var dayCache = [Int: [ActivityMinute]]()
    private var monthCache = [String: [SleepSegment]]()
    private var cachedState: StoreState?

    private static let secondsPerDay = 86_400
    private static let cacheLimit = 62

    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    public init(directory: URL) throws {
        root = directory
        try fileManager.createDirectory(at: directory.appendingPathComponent("activity"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: directory.appendingPathComponent("sleep"), withIntermediateDirectories: true)
    }

    // MARK: Activity

    /// Adds minutes, merging with any already stored for the same timestamp.
    /// - Returns: how many minutes were new rather than updates.
    @discardableResult
    public func addMinutes(_ minutes: [ActivityMinute]) throws -> Int {
        var added = 0
        let groups = Dictionary(grouping: minutes.filter(\.hasData)) { HealthStore.dayNumber($0.timestamp) }
        for (day, incoming) in groups {
            var byTimestamp = Dictionary(try loadDay(day).map { ($0.timestamp, $0) }, uniquingKeysWith: { _, latest in latest })
            for minute in incoming {
                if let existing = byTimestamp[minute.timestamp] {
                    byTimestamp[minute.timestamp] = existing.merged(with: minute)
                } else {
                    byTimestamp[minute.timestamp] = minute
                    added += 1
                }
            }
            let merged = byTimestamp.values.sorted { $0.timestamp < $1.timestamp }
            try write(merged, to: dayURL(day))
            cache(day: day, merged)
        }
        return added
    }

    /// Minutes with `start <= timestamp < end`, oldest first.
    public func minutes(from start: Int, to end: Int) throws -> [ActivityMinute] {
        guard end > start else { return [] }
        var result = [ActivityMinute]()
        for day in HealthStore.dayNumber(start)...HealthStore.dayNumber(end - 1) {
            result += try loadDay(day).filter { $0.timestamp >= start && $0.timestamp < end }
        }
        return result
    }

    private func loadDay(_ day: Int) throws -> [ActivityMinute] {
        if let cached = dayCache[day] { return cached }
        let loaded: [ActivityMinute] = try read(dayURL(day)) ?? []
        cache(day: day, loaded)
        return loaded
    }

    private func cache(day: Int, _ minutes: [ActivityMinute]) {
        if dayCache.count >= HealthStore.cacheLimit, dayCache[day] == nil { dayCache.removeAll() }
        dayCache[day] = minutes
    }

    // MARK: Sleep

    /// Adds sleep segments. A segment with the same start as a stored one replaces it, which is how
    /// a segment that was still growing at the last sync gets its final length.
    /// - Returns: how many segments were new rather than updates.
    @discardableResult
    public func addSleep(_ segments: [SleepSegment]) throws -> Int {
        var added = 0
        let groups = Dictionary(grouping: segments.filter { $0.end > $0.start }) { HealthStore.monthKey($0.start) }
        for (month, incoming) in groups {
            var byStart = Dictionary(try loadMonth(month).map { ($0.start, $0) }, uniquingKeysWith: { _, latest in latest })
            for segment in incoming {
                if byStart[segment.start] == nil { added += 1 }
                byStart[segment.start] = segment
            }
            let merged = byStart.values.sorted { $0.start < $1.start }
            try write(merged, to: monthURL(month))
            monthCache[month] = merged
        }
        return added
    }

    /// Segments that overlap `start..<end`, oldest first.
    public func sleep(from start: Int, to end: Int) throws -> [SleepSegment] {
        guard end > start else { return [] }
        var result = [SleepSegment]()
        // A segment belongs to the month it starts in and is at most a few hours long, so looking
        // one day back is enough to catch one that began in the previous month.
        var months = [String]()
        var cursor = start - HealthStore.secondsPerDay
        while cursor < end {
            let key = HealthStore.monthKey(cursor)
            if months.last != key { months.append(key) }
            cursor += HealthStore.secondsPerDay
        }
        let lastKey = HealthStore.monthKey(end - 1)
        if months.last != lastKey { months.append(lastKey) }

        for month in months {
            result += try loadMonth(month).filter { $0.end > start && $0.start < end }
        }
        return result
    }

    private func loadMonth(_ month: String) throws -> [SleepSegment] {
        if let cached = monthCache[month] { return cached }
        let loaded: [SleepSegment] = try read(monthURL(month)) ?? []
        if monthCache.count >= HealthStore.cacheLimit { monthCache.removeAll() }
        monthCache[month] = loaded
        return loaded
    }

    // MARK: State

    public func state() -> StoreState {
        if let cachedState { return cachedState }
        let loaded: StoreState = ((try? read(stateURL)) ?? nil) ?? StoreState()
        cachedState = loaded
        return loaded
    }

    public func updateState(_ change: @Sendable (inout StoreState) -> Void) throws {
        var current = state()
        change(&current)
        try write(current, to: stateURL)
        cachedState = current
    }

    /// Deletes every sample and all remembered state.
    public func eraseAll() throws {
        for name in ["activity", "sleep"] {
            let directory = root.appendingPathComponent(name)
            if fileManager.fileExists(atPath: directory.path) { try fileManager.removeItem(at: directory) }
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        if fileManager.fileExists(atPath: stateURL.path) { try fileManager.removeItem(at: stateURL) }
        dayCache.removeAll()
        monthCache.removeAll()
        cachedState = nil
    }

    // MARK: Files

    private var stateURL: URL { root.appendingPathComponent("state.json") }

    private func dayURL(_ day: Int) -> URL {
        let date = Date(timeIntervalSince1970: TimeInterval(day * HealthStore.secondsPerDay))
        let parts = HealthStore.utcCalendar.dateComponents([.year, .month, .day], from: date)
        let name = String(format: "%04d-%02d-%02d.json", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        return root.appendingPathComponent("activity").appendingPathComponent(name)
    }

    private func monthURL(_ month: String) -> URL {
        root.appendingPathComponent("sleep").appendingPathComponent(month + ".json")
    }

    private func read<Value: Decodable>(_ url: URL) throws -> Value? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(Value.self, from: Data(contentsOf: url))
    }

    private func write<Value: Encodable>(_ value: Value, to url: URL) throws {
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
    }

    static func dayNumber(_ timestamp: Int) -> Int {
        Int((Double(timestamp) / Double(secondsPerDay)).rounded(.down))
    }

    static func monthKey(_ timestamp: Int) -> String {
        let parts = utcCalendar.dateComponents([.year, .month], from: Date(timeIntervalSince1970: TimeInterval(timestamp)))
        return String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
    }
}
