import BandKit
import Foundation

/// Fills the store with made-up data when the app is launched with `-demo`.
///
/// This exists so the screens can be looked at in the simulator, which has no Bluetooth. Nothing
/// here is ever mixed with real data: demo mode uses its own throwaway store.
enum DemoData {
    /// The screen to open on, from `-screen <name>`, for taking screenshots.
    static var requestedScreen: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-screen"), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    static let discovered = [
        DiscoveredBand(id: UUID(), name: "HONOR Band 4-5F1", rssi: -52, advertisedData: [], isLikelyBand: true),
        DiscoveredBand(id: UUID(), name: "Living Room Speaker", rssi: -71, advertisedData: [], isLikelyBand: false),
    ]

    static func fill(_ store: HealthStore, now: Date = Date(), days: Int = 30) async {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let nowStamp = Int(now.timeIntervalSince1970)
        var generator = SeededGenerator(seed: 20_260_101)

        var minutes = [ActivityMinute]()
        var sleep = [SleepSegment]()
        for offset in 0..<days {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            let dayStart = Int(day.timeIntervalSince1970)
            let wake = dayStart + 6 * 3600 + Int.random(in: 20...80, using: &generator) * 60
            let bedtime = dayStart + 22 * 3600 + Int.random(in: 10...70, using: &generator) * 60
            let energy = Double.random(in: 0.6...1.35, using: &generator)

            // The night that ended this morning: alternating light and deep stretches.
            var cursor = dayStart - 3600 + Int.random(in: 0...50, using: &generator) * 60
            var deep = false
            while cursor < wake {
                let length = (deep ? Int.random(in: 35...75, using: &generator) : Int.random(in: 45...110, using: &generator)) * 60
                let end = min(cursor + length, wake)
                if end - cursor >= 300 { sleep.append(SleepSegment(start: cursor, end: end, rawStage: deep ? 7 : 6)) }
                cursor = end + (Int.random(in: 0...9, using: &generator) == 0 ? 600 : 0)
                deep.toggle()
            }

            // Waking hours: bursts of walking around commuting and lunch, heart rate every five minutes.
            var minute = wake
            while minute < min(bedtime, nowStamp) {
                let hour = Double(minute - dayStart) / 3600
                let busy = [8.2, 12.7, 18.1].map { exp(-pow(hour - $0, 2) / 0.9) }.reduce(0, +)
                let walking = Double.random(in: 0...1, using: &generator) < (0.06 + 0.55 * busy) * energy
                var sample = ActivityMinute(timestamp: minute)
                if walking {
                    let steps = Int.random(in: 35...118, using: &generator)
                    sample.steps = steps
                    sample.distance = Int(Double(steps) * 0.72)
                    sample.calories = max(1, steps / 25)
                }
                if (minute / 60) % 5 == 0 {
                    let base = walking ? 98.0 : 66.0
                    sample.heartRate = Int(base + 9 * sin(hour * 1.7) + Double.random(in: -6...8, using: &generator))
                }
                if sample.hasData { minutes.append(sample) }
                minute += 60
            }
            // Sleeping heart rate for the night just generated.
            var night = dayStart - 3600
            while night < min(wake, nowStamp) {
                minutes.append(ActivityMinute(timestamp: night, heartRate: Int.random(in: 51...60, using: &generator),
                                              restingHeartRate: 55))
                night += 600
            }
        }

        try? await store.addMinutes(minutes)
        try? await store.addSleep(sleep)

        let todayStart = Int(today.timeIntervalSince1970)
        let todays = minutes.filter { $0.timestamp >= todayStart }
        let totals = BandTotals(
            steps: todays.compactMap(\.steps).reduce(0, +),
            calories: todays.compactMap(\.calories).reduce(0, +),
            distance: todays.compactMap(\.distance).reduce(0, +))
        try? await store.updateState {
            $0.device = DeviceInfo(hardwareVersion: "Demo", softwareVersion: "1.0.0", model: "Demo Band")
            $0.batteryLevel = 78
            $0.batteryUpdated = now
            $0.lastSync = now
            $0.bandTotals = totals
            $0.bandTotalsUpdated = now
            $0.activityCursor = nowStamp
        }
    }
}

/// A small deterministic generator so the demo looks the same every launch.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        // SplitMix64.
        state &+= 0x9e37_79b9_7f4a_7c15
        var value = state
        value = (value ^ (value >> 30)) &* 0xbf58_476d_1ce4_e5b9
        value = (value ^ (value >> 27)) &* 0x94d0_49bb_1331_11eb
        return value ^ (value >> 31)
    }
}
