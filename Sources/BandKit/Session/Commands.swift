import Foundation

// The commands the app sends once the link is paired. Service 0x01 is device configuration,
// 0x07 is fitness data and 0x0C is locale.

extension BandSession {
    // MARK: Device

    public func deviceInfo() async throws -> DeviceInfo {
        // Each empty tag asks for one field; the band answers with the ones it has.
        var request = TLV()
        for tag: UInt8 in [0x01, 0x02, 0x03, 0x05, 0x07, 0x09, 0x0a, 0x11] { request = request.adding(tag) }
        let reply = try await query(0x01, 0x07, request)

        func text(_ tag: UInt8) -> String? {
            guard let value = reply.string(tag)?.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters)),
                  !value.isEmpty else { return nil }
            return value
        }
        return DeviceInfo(hardwareVersion: text(0x03), softwareVersion: text(0x07), serialNumber: text(0x09),
                          model: text(0x0a), name: text(0x11), reportedAddress: text(0x05))
    }

    /// Battery charge, 0 to 100.
    public func batteryLevel() async throws -> Int {
        let reply = try await query(0x01, 0x08, TLV().adding(0x01))
        guard let level = reply.unsigned(0x01) else {
            throw BandError.malformedReply(service: 0x01, command: 0x08, detail: "missing level")
        }
        return level
    }

    /// Sets the band's clock and time zone.
    public func setTime(_ date: Date = Date(), timeZone: TimeZone = .current) async throws {
        try await perform(0x01, 0x05, BandCommands.setTime(date, timeZone: timeZone))
    }

    /// Pushes every option in `settings` to the band.
    ///
    /// The options are independent, so one the band refuses does not stop the rest. The result
    /// lists each step with the error it hit, if any, for the diagnostics screen.
    @discardableResult
    public func apply(_ settings: BandSettings, now: Date = Date()) async -> [(step: String, error: Error?)] {
        var results = [(step: String, error: Error?)]()
        for (name, service, command, body) in BandCommands.settingsSteps(settings, now: now) {
            do {
                try await perform(service, command, body)
                results.append((name, nil))
            } catch {
                logger.log(.warning, "Setting '\(name)' was not applied: \(error)")
                results.append((name, error))
                // A dead link fails every remaining step the same way; do not wait on each one.
                if let bandError = error as? BandError, bandError == .disconnected { break }
            }
        }
        return results
    }

    // MARK: Fitness

    /// The band's running totals for today, as shown on its own screen.
    public func todayTotals() async throws -> BandTotals {
        let reply = try await query(0x07, 0x03, TLV().adding(0x01))
        guard let totals = ActivityParser.totals(reply) else {
            throw BandError.malformedReply(service: 0x07, command: 0x03, detail: "missing totals")
        }
        return totals
    }

    /// How many blocks of per-minute activity the band holds for the period.
    public func activityBlockCount(from start: Int, to end: Int) async throws -> Int {
        try await blockCount(command: 0x0a, from: start, to: end)
    }

    /// One block of per-minute activity. Call `activityBlockCount` first; indexes count from zero.
    public func activityBlock(_ index: Int) async throws -> [ActivityMinute] {
        let reply = try await query(0x07, 0x0b, BandCommands.blockRequest(index))
        let parsed = ActivityParser.minutes(reply)
        if parsed.skipped > 0 {
            logger.log(.warning, "Activity block \(index): \(parsed.skipped) unreadable minute(s) skipped")
        }
        return parsed.minutes
    }

    /// How many blocks of sleep data the band holds for the period.
    public func sleepBlockCount(from start: Int, to end: Int) async throws -> Int {
        try await blockCount(command: 0x0c, from: start, to: end)
    }

    /// One block of sleep segments. Call `sleepBlockCount` first; indexes count from zero.
    public func sleepBlock(_ index: Int) async throws -> [SleepSegment] {
        let reply = try await query(0x07, 0x0d, BandCommands.blockRequest(index))
        return ActivityParser.sleep(reply)
    }

    private func blockCount(command: UInt8, from start: Int, to end: Int) async throws -> Int {
        let reply = try await query(0x07, command, BandCommands.countRequest(from: start, to: end))
        guard let count = reply.nested(0x81)?.unsigned(0x02) else {
            throw BandError.malformedReply(service: 0x07, command: command, detail: "missing count")
        }
        return count
    }
}

/// Request bodies, kept as pure functions so they can be checked byte for byte in tests.
public enum BandCommands {
    public static func setTime(_ date: Date, timeZone: TimeZone) -> TLV {
        let offset = timeZone.secondsFromGMT(for: date)
        let magnitude = abs(offset)
        // The hour byte carries the sign in its top bit.
        let hours = UInt8(magnitude / 3600) | (offset < 0 ? 0x80 : 0)
        let minutes = UInt8((magnitude % 3600) / 60)
        return TLV()
            .adding(0x01, uint32: Int(date.timeIntervalSince1970))
            .adding(0x02, bytes: [hours, minutes])
    }

    /// Asks how many blocks exist between two timestamps.
    public static func countRequest(from start: Int, to end: Int) -> TLV {
        TLV().adding(0x81).adding(0x03, uint32: start).adding(0x04, uint32: end)
    }

    /// Asks for one block by index.
    public static func blockRequest(_ index: Int) -> TLV {
        TLV().adding(0x81, nested: TLV().adding(0x02, uint16: index))
    }

    public static func userProfile(_ profile: UserProfile, now: Date) -> TLV {
        let height = min(max(profile.heightCm, 50), 250)
        let weight = min(max(profile.weightKg, 10), 250)
        let birthday = profile.birthYear << 16 | profile.birthMonth << 8 | profile.birthDay
        return TLV()
            .adding(0x01, byte: UInt8(height))
            .adding(0x02, byte: UInt8(weight))
            .adding(0x03, byte: UInt8(profile.age(on: now)))
            .adding(0x04, uint32: birthday)
            .adding(0x05, byte: UInt8(profile.sex.rawValue))
            // Stride lengths for walking and running, estimated from height.
            .adding(0x06, byte: UInt8((Double(height) * 0.42).rounded()))
            .adding(0x07, byte: UInt8((Double(height) * 0.83).rounded()))
    }

    public static func stepGoal(_ steps: Int) -> TLV {
        let goal = TLV()
            .adding(0x03, byte: 1)
            .adding(0x04, byte: 0)
            .adding(0x05, uint32: min(max(steps, 0), 1_000_000))
        return TLV().adding(0x81, nested: TLV().adding(0x82, nested: goal))
    }

    /// Every settings command, in the order it is sent: name, service, command, body.
    public static func settingsSteps(_ settings: BandSettings, now: Date) -> [(String, UInt8, UInt8, TLV)] {
        let dateFormat = TLV().adding(0x81, nested: TLV()
            .adding(0x02, byte: UInt8(settings.dateOrder.rawValue))
            .adding(0x03, byte: settings.use24HourClock ? 2 : 1))
        let locale = TLV()
            .adding(0x01, string: settings.languageTag)
            .adding(0x02, byte: settings.useMetricUnits ? 0 : 1)

        return [
            ("date and time format", 0x01, 0x04, dateFormat),
            ("language and units", 0x0c, 0x01, locale),
            ("wrist", 0x01, 0x1a, TLV().adding(0x01, byte: settings.wornOnLeftWrist ? 1 : 0)),
            ("raise to wake", 0x01, 0x09, TLV().adding(0x01, bool: settings.raiseToWake)),
            ("rotate to switch", 0x01, 0x1b, TLV().adding(0x01, bool: settings.rotateToSwitchScreens)),
            ("profile", 0x07, 0x02, userProfile(settings.profile, now: now)),
            ("step goal", 0x07, 0x01, stepGoal(settings.stepGoal)),
            // With this mode off the band works out light and deep sleep itself and hands over the
            // result. With it on, the band expects the vendor's own app to do that analysis.
            ("on-band sleep analysis", 0x07, 0x16, TLV().adding(0x01, bool: false)),
            ("continuous heart rate", 0x07, 0x17, TLV().adding(0x01, bool: settings.continuousHeartRate)),
        ]
    }
}

/// Turns the band's fitness replies into model values.
public enum ActivityParser {
    /// Parses one block of per-minute activity.
    ///
    /// The block has a base timestamp and a list of minutes, each with an offset in minutes and a
    /// packed record. The record starts with a bitmap saying which fields follow; a set top bit
    /// means a second bitmap comes next.
    public static func minutes(_ reply: TLV) -> (minutes: [ActivityMinute], skipped: Int) {
        guard let block = reply.nested(0x81), let base = block.unsigned(0x03) else { return ([], 0) }
        var minutes = [ActivityMinute]()
        var skipped = 0
        for entry in block.allNested(0x84) {
            guard let offset = entry.unsigned(0x05), let record = entry.bytes(0x06) else {
                skipped += 1
                continue
            }
            if let minute = minute(timestamp: base + 60 * offset, record: record) {
                minutes.append(minute)
            } else {
                skipped += 1
            }
        }
        return (minutes, skipped)
    }

    static func minute(timestamp: Int, record: [UInt8]) -> ActivityMinute? {
        guard !record.isEmpty else { return nil }
        var index = 0
        let first = record[index]
        index += 1
        var second: UInt8 = 0
        if first & 0x80 != 0 {
            guard index < record.count else { return nil }
            second = record[index]
            index += 1
        }

        var minute = ActivityMinute(timestamp: timestamp)
        for bit in [0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40] as [UInt8] where first & bit != 0 {
            let width = (bit == 0x20 || bit == 0x40) ? 1 : 2
            guard index + width <= record.count else { return nil }
            let value = Int(Bytes.unsigned(record[index..<index + width]))
            index += width
            switch bit {
            case 0x02: minute.steps = value
            case 0x04: minute.calories = value
            case 0x08: minute.distance = value
            case 0x40: minute.heartRate = plausibleHeartRate(value)
            default: break   // Fields this app does not interpret are stepped over.
            }
        }
        for bit in [0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80] as [UInt8] where second & bit != 0 {
            guard index < record.count else { return nil }
            let value = Int(record[index])
            index += 1
            switch bit {
            case 0x01: minute.spo2 = (1...100).contains(value) ? value : nil
            case 0x02: minute.restingHeartRate = plausibleHeartRate(value)
            default: break
            }
        }
        return minute
    }

    /// The band writes 0 or 255 when it has no reading.
    private static func plausibleHeartRate(_ value: Int) -> Int? {
        (1..<255).contains(value) ? value : nil
    }

    /// Parses one block of sleep segments. Each is a stage code and six bytes: a four-byte start
    /// time and a two-byte length in minutes.
    public static func sleep(_ reply: TLV) -> [SleepSegment] {
        guard let block = reply.nested(0x81) else { return [] }
        return block.allNested(0x83).compactMap { entry in
            guard let stage = entry.unsigned(0x04), let time = entry.bytes(0x05), time.count >= 6 else { return nil }
            let start = Int(Bytes.unsigned(time[0..<4]))
            let minutes = Int(Bytes.unsigned(time[4..<6]))
            guard minutes > 0 else { return nil }
            return SleepSegment(start: start, end: start + minutes * 60, rawStage: stage)
        }
    }

    /// Parses the band's totals for today: one entry per kind of activity, summed for the headline.
    public static func totals(_ reply: TLV) -> BandTotals? {
        guard let block = reply.nested(0x81) else { return nil }
        let activities = block.allNested(0x83).map { entry in
            BandTotals.Activity(kind: entry.unsigned(0x04) ?? 0, steps: entry.unsigned(0x05), calories: entry.unsigned(0x06),
                                distance: entry.unsigned(0x07), minutes: entry.unsigned(0x08))
        }
        return BandTotals(
            steps: activities.reduce(0) { $0 + ($1.steps ?? 0) },
            calories: activities.reduce(0) { $0 + ($1.calories ?? 0) },
            distance: activities.reduce(0) { $0 + ($1.distance ?? 0) },
            activities: activities)
    }
}
