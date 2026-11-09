import BandKit
import Charts
import SwiftUI

/// The daily dashboard: steps, distance, energy, heart rate and last night's sleep for one day.
struct TodayView: View {
    @Environment(AppModel.self) private var model
    @State private var day = Calendar.current.startOfDay(for: Date())
    @State private var summary: DaySummary?

    private var isToday: Bool { Calendar.current.isDateInToday(day) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    LinkStatusBar()
                    if let summary {
                        StepsCard(summary: summary, goal: model.settings.stepGoal, metric: model.settings.useMetricUnits)
                        HeartRateCard(summary: summary)
                        SleepCard(sleep: summary.sleep)
                    } else {
                        ProgressView().padding(.top, 80)
                    }
                    footer
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(title)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { shift(-1) } label: { Image(systemName: "chevron.left") }
                        .accessibilityLabel("Previous day")
                    Button { shift(1) } label: { Image(systemName: "chevron.right") }
                        .disabled(isToday)
                        .accessibilityLabel("Next day")
                }
            }
            .refreshable { await model.syncNow() }
            .task(id: ReloadKey(day: day, version: model.dataVersion)) {
                summary = await model.summary(for: day)
            }
        }
    }

    private var title: String {
        if isToday { return "Today" }
        if Calendar.current.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))
    }

    private func shift(_ days: Int) {
        guard let moved = Calendar.current.date(byAdding: .day, value: days, to: day), moved <= Date() else { return }
        day = moved
    }

    @ViewBuilder private var footer: some View {
        if let last = model.state.lastSync {
            Text("Synced \(Format.relative(last)). Pull down to sync again.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        } else if !model.isSyncing {
            Text("Nothing synced yet. Keep the band close and pull down to sync.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
    }
}

struct ReloadKey: Equatable {
    var day: Date
    var version: Int
}

// MARK: - Steps

private struct StepsCard: View {
    var summary: DaySummary
    var goal: Int
    var metric: Bool

    private struct Hour: Identifiable {
        let id: Int
        let steps: Int
    }

    var body: some View {
        let distance = Format.distance(metres: summary.distance, metric: metric)
        Card(title: "Activity", systemImage: "figure.walk", tint: .stepsTint) {
            HStack(spacing: 20) {
                ZStack {
                    ProgressRing(progress: goal > 0 ? Double(summary.steps) / Double(goal) : 0)
                    VStack(spacing: 0) {
                        Text(Format.count(summary.steps))
                            .font(.system(.title, design: .rounded).weight(.bold))
                            .monospacedDigit()
                            .minimumScaleFactor(0.6)
                            .lineLimit(1)
                        Text("of \(Format.count(goal))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 22)
                }
                .frame(width: 138, height: 138)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(summary.steps) steps of a goal of \(goal)")

                VStack(alignment: .leading, spacing: 12) {
                    Stat(value: distance.value, unit: distance.unit, caption: "Distance", tint: .distanceTint)
                    Stat(value: Format.count(summary.calories), unit: "kcal", caption: "Active energy", tint: .energyTint)
                    Stat(value: Format.count(summary.activeMinutes), unit: "min", caption: "Moving")
                }
            }

            Chart(summary.hourlySteps.enumerated().map { Hour(id: $0.offset, steps: $0.element) }) { hour in
                // Each bar is centred on the middle of its hour.
                BarMark(x: .value("Hour", Double(hour.id) + 0.5), y: .value("Steps", hour.steps), width: .fixed(7))
                    .foregroundStyle(Color.stepsTint)
                    .cornerRadius(2)
            }
            .chartXScale(domain: 0.0...24.0)
            .chartXAxis {
                AxisMarks(values: [0.0, 6.0, 12.0, 18.0]) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let hour = value.as(Double.self) { Text(hourLabel(Int(hour))) }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3))
            }
            .frame(height: 110)
            .accessibilityLabel("Steps by hour")

            if summary.usesBandTotals {
                Text("Totals are the band's own figures for today.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func hourLabel(_ hour: Int) -> String {
        var components = DateComponents()
        components.hour = hour
        let date = Calendar.current.date(from: components) ?? Date()
        return date.formatted(.dateTime.hour())
    }
}

// MARK: - Heart rate

private struct HeartRateCard: View {
    var summary: DaySummary

    private struct Point: Identifiable {
        let id: Int
        let date: Date
        let bpm: Int
    }

    var body: some View {
        Card(title: "Heart rate", systemImage: "heart.fill", tint: .heartTint) {
            if summary.heartRate.isEmpty {
                Text("No heart rate readings for this day. Continuous heart rate can be switched on under Band.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                HStack {
                    Stat(value: summary.heartRateAverage.map(String.init) ?? "–", unit: "bpm", caption: "Average", tint: .heartTint)
                    Stat(value: range, unit: "bpm", caption: "Range")
                    Stat(value: summary.restingHeartRate.map(String.init) ?? "–", unit: "bpm", caption: "Resting")
                }

                Chart(points) { point in
                    PointMark(x: .value("Time", point.date), y: .value("Beats per minute", point.bpm))
                        .symbolSize(10)
                        .foregroundStyle(Color.heartTint)
                }
                .chartXScale(domain: dayRange)
                .chartYScale(domain: yDomain)
                .chartXAxis {
                    AxisMarks(values: .stride(by: .hour, count: 6)) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.hour())
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .trailing, values: .automatic(desiredCount: 4))
                }
                .frame(height: 130)
                .accessibilityLabel("Heart rate through the day")
            }
        }
    }

    private var points: [Point] {
        summary.heartRate.map { Point(id: $0.timestamp, date: Date(timeIntervalSince1970: TimeInterval($0.timestamp)), bpm: $0.bpm) }
    }

    private var range: String {
        guard let low = summary.heartRateMin, let high = summary.heartRateMax else { return "–" }
        return "\(low)–\(high)"
    }

    private var dayRange: ClosedRange<Date> {
        Date(timeIntervalSince1970: TimeInterval(summary.dayStart))...Date(timeIntervalSince1970: TimeInterval(summary.dayEnd))
    }

    private var yDomain: ClosedRange<Int> {
        let low = (summary.heartRateMin ?? 50), high = (summary.heartRateMax ?? 120)
        return (max(30, low - 10) / 10 * 10)...((high + 19) / 10 * 10)
    }
}

// MARK: - Sleep

private struct SleepCard: View {
    var sleep: SleepSummary?

    private struct Block: Identifiable {
        let id: Int
        let start: Date
        let end: Date
        let stage: String
        let tint: Color
    }

    var body: some View {
        Card(title: "Sleep", systemImage: "moon.fill", tint: .deepSleepTint) {
            if let sleep {
                let night = sleep.night
                HStack(alignment: .firstTextBaseline) {
                    Text(Format.duration(minutes: night.asleepMinutes))
                        .font(.system(.title2, design: .rounded).weight(.bold))
                    Spacer()
                    Text("\(Format.clock(night.start)) – \(Format.clock(night.end))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Chart(blocks(night)) { block in
                    BarMark(xStart: .value("Start", block.start), xEnd: .value("End", block.end), y: .value("Stage", block.stage))
                        .foregroundStyle(block.tint)
                        .cornerRadius(3)
                }
                .chartYScale(domain: ["Light", "Deep"])
                .chartXAxis {
                    AxisMarks(values: .stride(by: .hour, count: 2)) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.hour())
                    }
                }
                .frame(height: 84)
                .accessibilityLabel("Sleep stages through the night")

                HStack {
                    Stat(value: Format.duration(minutes: night.deepMinutes), unit: nil, caption: "Deep", tint: .deepSleepTint)
                    Stat(value: Format.duration(minutes: night.lightMinutes), unit: nil, caption: "Light", tint: .lightSleepTint)
                    Stat(value: Format.duration(minutes: night.awakeMinutes), unit: nil, caption: "Awake")
                }
                if sleep.napMinutes > 0 {
                    Text("Plus \(Format.duration(minutes: sleep.napMinutes)) of daytime sleep.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("No sleep recorded for this night. Sleep appears after the band has been worn overnight and synced.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func blocks(_ night: SleepSession) -> [Block] {
        night.segments.enumerated().map { index, segment in
            let deep = segment.stage == .deep
            return Block(id: index,
                         start: Date(timeIntervalSince1970: TimeInterval(segment.start)),
                         end: Date(timeIntervalSince1970: TimeInterval(segment.end)),
                         stage: deep ? "Deep" : "Light",
                         tint: deep ? .deepSleepTint : .lightSleepTint)
        }
    }
}
