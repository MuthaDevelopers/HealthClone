import BandKit
import Charts
import SwiftUI

/// Steps, sleep and resting heart rate over the last week or month.
struct TrendsView: View {
    @Environment(AppModel.self) private var model
    @State private var span = 7
    @State private var days = [DaySummary]()
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    Picker("Period", selection: $span) {
                        Text("7 days").tag(7)
                        Text("30 days").tag(30)
                    }
                    .pickerStyle(.segmented)

                    if !loaded {
                        ProgressView().padding(.top, 80)
                    } else {
                        stepsCard
                        sleepCard
                        heartCard
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Trends")
            .refreshable { await model.syncNow() }
            .task(id: TrendKey(span: span, version: model.dataVersion)) {
                days = await model.trend(endingOn: Date(), days: span)
                loaded = true
            }
        }
    }

    private struct TrendKey: Equatable {
        var span: Int
        var version: Int
    }

    private func date(_ summary: DaySummary) -> Date {
        Date(timeIntervalSince1970: TimeInterval(summary.dayStart))
    }

    /// Days with any data at all; averages ignore days the band was not worn.
    private var activeDays: [DaySummary] { days.filter { $0.steps > 0 } }

    // MARK: Steps

    private var stepsCard: some View {
        let goal = model.settings.stepGoal
        let average = activeDays.isEmpty ? 0 : activeDays.map(\.steps).reduce(0, +) / activeDays.count
        let reached = days.filter { $0.steps >= goal }.count
        let metres = days.map(\.distance).reduce(0, +)
        let distance = Format.distance(metres: metres, metric: model.settings.useMetricUnits)

        return Card(title: "Steps", systemImage: "figure.walk", tint: .stepsTint) {
            HStack {
                Stat(value: Format.count(average), unit: nil, caption: "Daily average", tint: .stepsTint)
                Stat(value: "\(reached)/\(days.count)", unit: nil, caption: "Goal reached")
                Stat(value: distance.value, unit: distance.unit, caption: "Total distance", tint: .distanceTint)
            }
            Chart {
                ForEach(days, id: \.dayStart) { day in
                    BarMark(x: .value("Day", date(day), unit: .day), y: .value("Steps", day.steps))
                        .foregroundStyle(day.steps >= goal ? Color.stepsTint : Color.stepsTint.opacity(0.45))
                        .cornerRadius(3)
                }
                RuleMark(y: .value("Goal", goal))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .foregroundStyle(.secondary)
            }
            .chartXAxis { dayAxis }
            .chartYAxis { AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) }
            .frame(height: 170)
            .accessibilityLabel("Steps per day")
        }
    }

    // MARK: Sleep

    private struct SleepBar: Identifiable {
        let id: String
        let date: Date
        let stage: String
        let hours: Double
    }

    private var sleepCard: some View {
        let nights = days.compactMap { day in day.sleep.map { (day, $0.night) } }
        let bars = nights.flatMap { day, night in
            [
                SleepBar(id: "\(day.dayStart)-deep", date: date(day), stage: "Deep", hours: Double(night.deepMinutes) / 60),
                SleepBar(id: "\(day.dayStart)-light", date: date(day), stage: "Light", hours: Double(night.lightMinutes + night.otherMinutes) / 60),
            ]
        }
        let averageAsleep = nights.isEmpty ? 0 : nights.map { $0.1.asleepMinutes }.reduce(0, +) / nights.count
        let averageDeep = nights.isEmpty ? 0 : nights.map { $0.1.deepMinutes }.reduce(0, +) / nights.count

        return Card(title: "Sleep", systemImage: "moon.fill", tint: .deepSleepTint) {
            if nights.isEmpty {
                Text("No nights recorded in this period.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                HStack {
                    Stat(value: Format.duration(minutes: averageAsleep), unit: nil, caption: "Average night", tint: .deepSleepTint)
                    Stat(value: Format.duration(minutes: averageDeep), unit: nil, caption: "Average deep")
                    Stat(value: "\(nights.count)", unit: nil, caption: "Nights")
                }
                Chart(bars) { bar in
                    BarMark(x: .value("Day", bar.date, unit: .day), y: .value("Hours", bar.hours))
                        .foregroundStyle(by: .value("Stage", bar.stage))
                        .cornerRadius(2)
                }
                .chartForegroundStyleScale(["Deep": Color.deepSleepTint, "Light": Color.lightSleepTint])
                .chartXScale(domain: periodRange)
                .chartXAxis { dayAxis }
                .chartYAxis { AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) }
                .frame(height: 170)
                .accessibilityLabel("Hours of sleep per night")
            }
        }
    }

    // MARK: Heart rate

    private struct RestingPoint: Identifiable {
        let id: Int
        let date: Date
        let bpm: Int
    }

    private var heartCard: some View {
        // Fall back to the day's lowest reading when the band did not report a resting figure.
        let points = days.compactMap { day -> RestingPoint? in
            guard let bpm = day.restingHeartRate ?? day.heartRateMin else { return nil }
            return RestingPoint(id: day.dayStart, date: date(day), bpm: bpm)
        }
        let low = (points.map(\.bpm).min() ?? 50) - 5
        let high = (points.map(\.bpm).max() ?? 70) + 5

        return Card(title: "Resting heart rate", systemImage: "heart.fill", tint: .heartTint) {
            if points.count < 2 {
                Text("Needs heart rate readings from at least two days.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Chart(points) { point in
                    LineMark(x: .value("Day", point.date, unit: .day), y: .value("Beats per minute", point.bpm))
                        .foregroundStyle(Color.heartTint)
                        .interpolationMethod(.monotone)
                    PointMark(x: .value("Day", point.date, unit: .day), y: .value("Beats per minute", point.bpm))
                        .foregroundStyle(Color.heartTint)
                        .symbolSize(24)
                }
                .chartXScale(domain: periodRange)
                .chartYScale(domain: low...high)
                .chartXAxis { dayAxis }
                .chartYAxis { AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) }
                .frame(height: 140)
                .accessibilityLabel("Resting heart rate per day")
            }
        }
    }

    // MARK: Axes

    /// The whole period, so charts with gaps still line up with the steps chart above them.
    private var periodRange: ClosedRange<Date> {
        let first = days.first.map(date) ?? Date()
        let last = days.last.map { Date(timeIntervalSince1970: TimeInterval($0.dayEnd)) } ?? Date()
        return first...max(first, last)
    }

    @AxisContentBuilder private var dayAxis: some AxisContent {
        if span <= 7 {
            AxisMarks(values: .stride(by: .day)) { _ in
                AxisValueLabel(format: .dateTime.weekday(.narrow), centered: true)
            }
        } else {
            AxisMarks(values: .stride(by: .day, count: 7)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.day().month(.abbreviated))
            }
        }
    }
}
