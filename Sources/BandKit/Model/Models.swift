import Foundation

/// What the band reports about the link when a connection opens.
public struct LinkParameters: Equatable, Sendable {
    public var protocolVersion: Int
    /// Largest frame either side may send.
    public var sliceSize: Int
    /// Largest single write the band accepts.
    public var linkMTU: Int
    /// Which set of handshake constants the band expects.
    public var authVersion: Int
    public var serverNonce: [UInt8]
    /// Non-zero on newer devices that use a different pairing scheme this library does not speak.
    public var securityScheme: Int
    public var bondState: Int?
    public var encryptMethod: Int
}

/// Identity and firmware details read from the band.
public struct DeviceInfo: Equatable, Sendable, Codable {
    public var hardwareVersion: String?
    public var softwareVersion: String?
    public var serialNumber: String?
    public var model: String?
    public var name: String?
    /// The band's own Bluetooth address, when it chooses to report it.
    public var reportedAddress: String?

    public init(hardwareVersion: String? = nil, softwareVersion: String? = nil, serialNumber: String? = nil,
                model: String? = nil, name: String? = nil, reportedAddress: String? = nil) {
        self.hardwareVersion = hardwareVersion
        self.softwareVersion = softwareVersion
        self.serialNumber = serialNumber
        self.model = model
        self.name = name
        self.reportedAddress = reportedAddress
    }
}

/// One minute of activity as recorded by the band.
///
/// A field is nil when the band did not include it for that minute, which is different from zero.
public struct ActivityMinute: Equatable, Sendable, Codable {
    /// Start of the minute, seconds since 1970 UTC.
    public var timestamp: Int
    public var steps: Int?
    /// Active energy for the minute as the band reports it (kilocalories).
    public var calories: Int?
    /// Distance for the minute in metres.
    public var distance: Int?
    /// Beats per minute.
    public var heartRate: Int?
    /// Blood oxygen percentage. The Honor Band 4 has no sensor for this; newer bands fill it in.
    public var spo2: Int?
    public var restingHeartRate: Int?

    public init(timestamp: Int, steps: Int? = nil, calories: Int? = nil, distance: Int? = nil,
                heartRate: Int? = nil, spo2: Int? = nil, restingHeartRate: Int? = nil) {
        self.timestamp = timestamp
        self.steps = steps
        self.calories = calories
        self.distance = distance
        self.heartRate = heartRate
        self.spo2 = spo2
        self.restingHeartRate = restingHeartRate
    }

    enum CodingKeys: String, CodingKey {
        case timestamp = "t", steps = "s", calories = "c", distance = "d"
        case heartRate = "h", spo2 = "o", restingHeartRate = "r"
    }

    /// True if the minute carries any measurement at all.
    public var hasData: Bool {
        steps != nil || calories != nil || distance != nil || heartRate != nil || spo2 != nil || restingHeartRate != nil
    }

    /// Combines two readings of the same minute, preferring the newer one field by field.
    public func merged(with newer: ActivityMinute) -> ActivityMinute {
        ActivityMinute(
            timestamp: timestamp,
            steps: newer.steps ?? steps,
            calories: newer.calories ?? calories,
            distance: newer.distance ?? distance,
            heartRate: newer.heartRate ?? heartRate,
            spo2: newer.spo2 ?? spo2,
            restingHeartRate: newer.restingHeartRate ?? restingHeartRate)
    }
}

public enum SleepStage: String, Sendable, Codable, CaseIterable {
    case light
    case deep
    /// A code this app does not recognise; the raw value is kept on the segment.
    case other
}

/// One stretch of sleep at a single depth.
public struct SleepSegment: Equatable, Hashable, Sendable, Codable {
    /// Seconds since 1970 UTC.
    public var start: Int
    public var end: Int
    public var stage: SleepStage
    /// The band's own code for the stage, kept so unknown codes can be diagnosed later.
    public var rawStage: Int

    public init(start: Int, end: Int, rawStage: Int) {
        self.start = start
        self.end = end
        self.rawStage = rawStage
        self.stage = SleepSegment.stage(forRaw: rawStage)
    }

    public var durationMinutes: Int { max(0, end - start) / 60 }

    static func stage(forRaw raw: Int) -> SleepStage {
        switch raw {
        case 6: return .light
        case 7: return .deep
        default: return .other
        }
    }
}

/// The band's own running totals for the current day, exactly as shown on its screen.
public struct BandTotals: Equatable, Sendable, Codable {
    public var steps: Int
    /// Kilocalories.
    public var calories: Int
    /// Metres.
    public var distance: Int
    /// Per-activity breakdown as the band reports it.
    public var activities: [Activity]

    public struct Activity: Equatable, Sendable, Codable {
        /// 1 walking, 2 running, 3 climbing, 4 cycling, 6 light sleep, 7 deep sleep.
        public var kind: Int
        public var steps: Int?
        public var calories: Int?
        public var distance: Int?
        public var minutes: Int?

        public init(kind: Int, steps: Int? = nil, calories: Int? = nil, distance: Int? = nil, minutes: Int? = nil) {
            self.kind = kind
            self.steps = steps
            self.calories = calories
            self.distance = distance
            self.minutes = minutes
        }
    }

    public init(steps: Int, calories: Int, distance: Int, activities: [Activity] = []) {
        self.steps = steps
        self.calories = calories
        self.distance = distance
        self.activities = activities
    }
}

/// Personal details the band uses for its calorie and distance estimates.
public struct UserProfile: Equatable, Sendable, Codable {
    public enum Sex: Int, Sendable, Codable, CaseIterable {
        case male = 1
        case female = 2
    }

    public var heightCm: Int
    public var weightKg: Int
    public var sex: Sex
    public var birthYear: Int
    public var birthMonth: Int
    public var birthDay: Int

    public init(heightCm: Int = 170, weightKg: Int = 65, sex: Sex = .male,
                birthYear: Int = 1990, birthMonth: Int = 1, birthDay: Int = 1) {
        self.heightCm = heightCm
        self.weightKg = weightKg
        self.sex = sex
        self.birthYear = birthYear
        self.birthMonth = birthMonth
        self.birthDay = birthDay
    }

    /// Whole years between the birth date and the given date.
    public func age(on date: Date, calendar: Calendar = Calendar(identifier: .gregorian)) -> Int {
        let now = calendar.dateComponents([.year, .month, .day], from: date)
        var years = (now.year ?? birthYear) - birthYear
        let month = now.month ?? 1, day = now.day ?? 1
        if month < birthMonth || (month == birthMonth && day < birthDay) { years -= 1 }
        return min(max(years, 0), 150)
    }
}

/// Options pushed to the band after every connection.
public struct BandSettings: Equatable, Sendable, Codable {
    public enum DateOrder: Int, Sendable, Codable, CaseIterable {
        case yearFirst = 1
        case monthFirst = 2
        case dayFirst = 3
    }

    public var use24HourClock: Bool
    public var dateOrder: DateOrder
    public var wornOnLeftWrist: Bool
    public var raiseToWake: Bool
    public var rotateToSwitchScreens: Bool
    public var continuousHeartRate: Bool
    public var useMetricUnits: Bool
    /// BCP 47 tag such as `en-GB`.
    public var languageTag: String
    public var stepGoal: Int
    public var profile: UserProfile

    public init(use24HourClock: Bool = true, dateOrder: DateOrder = .dayFirst, wornOnLeftWrist: Bool = true,
                raiseToWake: Bool = true, rotateToSwitchScreens: Bool = false, continuousHeartRate: Bool = true,
                useMetricUnits: Bool = true, languageTag: String = "en-GB", stepGoal: Int = 10_000,
                profile: UserProfile = UserProfile()) {
        self.use24HourClock = use24HourClock
        self.dateOrder = dateOrder
        self.wornOnLeftWrist = wornOnLeftWrist
        self.raiseToWake = raiseToWake
        self.rotateToSwitchScreens = rotateToSwitchScreens
        self.continuousHeartRate = continuousHeartRate
        self.useMetricUnits = useMetricUnits
        self.languageTag = languageTag
        self.stepGoal = stepGoal
        self.profile = profile
    }
}
