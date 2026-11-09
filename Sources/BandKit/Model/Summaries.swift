import Foundation

public struct HeartRatePoint: Equatable, Sendable {
    public var timestamp: Int
    public var bpm: Int

    public init(timestamp: Int, bpm: Int) {
        self.timestamp = timestamp
        self.bpm = bpm
    }
}

/// One continuous period of sleep, made of light and deep segments.
public struct SleepSession: Equatable, Sendable {
    public var segments: [SleepSegment]

    public var start: Int { segments.first?.start ?? 0 }
    public var end: Int { segments.map(\.end).max() ?? 0 }
    public var lightMinutes: Int { minutes(of: .light) }
    public var deepMinutes: Int { minutes(of: .deep) }
    public var otherMinutes: Int { minutes(of: .other) }
    /// Minutes actually asleep.
    public var asleepMinutes: Int { segments.reduce(0) { $0 + $1.durationMinutes } }
    /// Minutes between falling asleep and finally waking that the band did not count as sleep.
    public var awakeMinutes: Int { max(0, (end - start) / 60 - asleepMinutes) }

    private func minutes(of stage: SleepStage) -> Int {
        segments.filter { $0.stage == stage }.reduce(0) { $0 + $1.durationMinutes }
    }
}

/// Sleep attributed to one calendar day: the main sleep that ended that day, plus any naps.
public struct SleepSummary: Equatable, Sendable {
    public var night: SleepSession
    public var naps: [SleepSession]

    public var napMinutes: Int { naps.reduce(0) { $0 + $1.asleepMinutes } }
}

/// Everything shown for one calendar day.
public struct DaySummary: Equatable, Sendable {
    public var dayStart: Int
    public var dayEnd: Int
    public var steps: Int
    /// Kilocalories.
    public var calories: Int
    /// Metres.
    public var distance: Int
    /// True when the three figures above are the band's own totals rather than sums of minutes.
    public var usesBandTotals: Bool
    /// Steps per hour of the day, starting at midnight.
    public var hourlySteps: [Int]
    /// Minutes in which at least one step was taken.
    public var activeMinutes: Int
    public var heartRate: [HeartRatePoint]
    public var heartRateMin: Int?
    public var heartRateMax: Int?
    public var heartRateAverage: Int?
    public var restingHeartRate: Int?
    public var sleep: SleepSummary?
}

public enum Summaries {
    /// A gap longer than this between two segments starts a new sleep session.
    static let sessionGap = 60 * 60
    /// Sleep is attributed to the day it ends on: the window runs from 20:00 the evening before.
    static let nightLeadIn = 4 * 60 * 60

    /// The time range to load sleep segments for, in order to summarise the day starting at `dayStart`.
    public static func sleepWindow(dayStart: Int, dayEnd: Int) -> Range<Int> {
        (dayStart - nightLeadIn)..<(dayEnd - nightLeadIn)
    }

    /// Builds the summary for one day.
    ///
    /// - Parameters:
    ///   - minutes: activity minutes within the day.
    ///   - sleep: segments overlapping `sleepWindow(dayStart:dayEnd:)`.
    ///   - bandTotals: the band's own totals, only if they were read during this same day.
    public static func day(dayStart: Int, dayEnd: Int, minutes: [ActivityMinute], sleep: [SleepSegment],
                           bandTotals: BandTotals? = nil) -> DaySummary {
        let inDay = minutes.filter { $0.timestamp >= dayStart && $0.timestamp < dayEnd }

        var hourly = [Int](repeating: 0, count: 24)
        var steps = 0, calories = 0, distance = 0, active = 0
        var points = [HeartRatePoint]()
        var resting: Int?
        for minute in inDay {
            let stepCount = minute.steps ?? 0
            steps += stepCount
            calories += minute.calories ?? 0
            distance += minute.distance ?? 0
            if stepCount > 0 { active += 1 }
            // A day with a clock change has 23 or 25 hours; the extra hour folds into the last bucket.
            hourly[min(23, (minute.timestamp - dayStart) / 3600)] += stepCount
            if let bpm = minute.heartRate { points.append(HeartRatePoint(timestamp: minute.timestamp, bpm: bpm)) }
            if let value = minute.restingHeartRate { resting = value }
        }

        let rates = points.map(\.bpm)
        var summary = DaySummary(
            dayStart: dayStart, dayEnd: dayEnd, steps: steps, calories: calories, distance: distance,
            usesBandTotals: false, hourlySteps: hourly, activeMinutes: active, heartRate: points,
            heartRateMin: rates.min(), heartRateMax: rates.max(),
            heartRateAverage: rates.isEmpty ? nil : Int((Double(rates.reduce(0, +)) / Double(rates.count)).rounded()),
            restingHeartRate: resting,
            sleep: sleepSummary(dayStart: dayStart, dayEnd: dayEnd, segments: sleep))

        if let bandTotals {
            summary.steps = bandTotals.steps
            summary.calories = bandTotals.calories
            summary.distance = bandTotals.distance
            summary.usesBandTotals = true
        }
        return summary
    }

    /// Groups segments into sessions and picks the longest as the night's sleep.
    public static func sleepSummary(dayStart: Int, dayEnd: Int, segments: [SleepSegment]) -> SleepSummary? {
        let window = sleepWindow(dayStart: dayStart, dayEnd: dayEnd)
        let relevant = segments
            .filter { window.contains($0.start) && $0.end > $0.start }
            .sorted { $0.start < $1.start }
        guard !relevant.isEmpty else { return nil }

        var sessions = [SleepSession]()
        var current = [SleepSegment]()
        var currentEnd = 0
        for segment in relevant {
            if !current.isEmpty, segment.start - currentEnd > sessionGap {
                sessions.append(SleepSession(segments: current))
                current = []
            }
            current.append(segment)
            currentEnd = max(currentEnd, segment.end)
        }
        sessions.append(SleepSession(segments: current))

        guard let night = sessions.max(by: { $0.asleepMinutes < $1.asleepMinutes }) else { return nil }
        return SleepSummary(night: night, naps: sessions.filter { $0 != night })
    }
}

/// Helps find the band's Bluetooth address, which iOS keeps from apps.
///
/// The band puts the last three hex digits of its address in its advertised name
/// ("HONOR Band 4-5F1"). Sometimes the full address also appears in other data the band exposes;
/// this looks for six bytes, in either order, that end with those digits.
public enum AddressGuess {
    /// The hex digits after the last dash in the band's name, if they look like an address tail.
    public static func nameSuffix(_ name: String) -> String? {
        guard let dash = name.lastIndex(of: "-") else { return nil }
        let tail = name[name.index(after: dash)...].trimmingCharacters(in: .whitespaces)
        guard (3...6).contains(tail.count), tail.allSatisfy(\.isHexDigit) else { return nil }
        return tail.uppercased()
    }

    /// Addresses found in `blobs` that end with `suffix`, most plausible first.
    public static func candidates(suffix: String, in blobs: [[UInt8]]) -> [BandAddress] {
        var found = [BandAddress]()
        func consider(_ bytes: [UInt8]) {
            // An all-zero or all-ones prefix is padding, not an address.
            guard Set(bytes.prefix(3)).count > 1 || !(bytes[0] == 0 || bytes[0] == 0xff) else { return }
            guard let address = BandAddress(Bytes.hex(bytes)), address.hasSuffix(suffix), !found.contains(address) else { return }
            found.append(address)
        }

        for blob in blobs {
            if blob.count >= 6 {
                for start in 0...(blob.count - 6) {
                    let window = Array(blob[start..<start + 6])
                    consider(window)
                    consider(window.reversed())
                }
            }
            // The address may also be spelled out as text.
            let text = String(decoding: blob, as: UTF8.self)
            let digits = text.filter { $0.isHexDigit }
            if digits.count == 12, let bytes = Bytes.fromHex(digits) { consider(bytes) }
        }
        return found
    }

    /// Whether `address` is consistent with the band's advertised name.
    public static func matches(_ address: BandAddress, name: String) -> Bool {
        guard let suffix = nameSuffix(name) else { return true }
        return address.hasSuffix(suffix)
    }
}
