import BandKit
import SwiftUI

extension Color {
    static let stepsTint = Color.accentColor
    static let heartTint = Color(red: 0.90, green: 0.26, blue: 0.36)
    static let energyTint = Color(red: 0.95, green: 0.55, blue: 0.16)
    static let distanceTint = Color(red: 0.24, green: 0.55, blue: 0.93)
    static let deepSleepTint = Color(red: 0.31, green: 0.27, blue: 0.72)
    static let lightSleepTint = Color(red: 0.55, green: 0.62, blue: 0.95)
}

/// The rounded panel every block of the dashboard sits in.
struct Card<Content: View>: View {
    var title: String?
    var systemImage: String?
    var tint: Color = .accentColor
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Label {
                    Text(title).font(.subheadline.weight(.semibold))
                } icon: {
                    if let systemImage { Image(systemName: systemImage) }
                }
                .foregroundStyle(tint)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

/// A circular progress ring that stays full once the goal is passed.
struct ProgressRing: View {
    var progress: Double
    var tint: Color = .stepsTint
    var lineWidth: CGFloat = 16

    var body: some View {
        ZStack {
            Circle().stroke(tint.opacity(0.18), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(max(progress, 0), 1))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.5), value: progress)
        }
    }
}

/// A headline number with its unit and a caption underneath.
struct Stat: View {
    var value: String
    var unit: String?
    var caption: String
    var tint: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.title2.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(tint)
                if let unit {
                    Text(unit).font(.footnote).foregroundStyle(.secondary)
                }
            }
            Text(caption).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

enum Format {
    static func count(_ value: Int) -> String {
        value.formatted(.number)
    }

    /// Distance in the user's units, with the unit separate so it can be styled.
    static func distance(metres: Int, metric: Bool) -> (value: String, unit: String) {
        if metric {
            return ((Double(metres) / 1000).formatted(.number.precision(.fractionLength(2))), "km")
        }
        return ((Double(metres) / 1609.344).formatted(.number.precision(.fractionLength(2))), "mi")
    }

    /// "7 h 05 min" style duration from minutes.
    static func duration(minutes: Int) -> String {
        let hours = minutes / 60, rest = minutes % 60
        if hours == 0 { return "\(rest) min" }
        return "\(hours) h \(rest < 10 ? "0" : "")\(rest) min"
    }

    static func clock(_ timestamp: Int) -> String {
        Date(timeIntervalSince1970: TimeInterval(timestamp)).formatted(date: .omitted, time: .shortened)
    }

    static func relative(_ date: Date) -> String {
        let seconds = Date().timeIntervalSince(date)
        if seconds < 60 { return "just now" }
        return date.formatted(.relative(presentation: .named))
    }
}

/// One line that says what the link to the band is doing, shown only when it is worth saying.
struct LinkStatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let banner {
            HStack(spacing: 10) {
                if banner.busy {
                    ProgressView()
                } else {
                    Image(systemName: banner.symbol).foregroundStyle(banner.tint)
                }
                Text(banner.text)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if banner.retry {
                    Button("Retry") { Task { await model.syncNow() } }
                        .font(.footnote.weight(.semibold))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private struct Banner {
        var text: String
        var symbol = "info.circle"
        var tint = Color.secondary
        var busy = false
        var retry = false
    }

    private var banner: Banner? {
        if model.isDemo { return Banner(text: "Demo data. Nothing here came from a band.", symbol: "sparkles") }
        if model.availability == .poweredOff {
            return Banner(text: "Bluetooth is off. Turn it on to sync.", symbol: "antenna.radiowaves.left.and.right.slash", tint: .orange)
        }
        if model.availability == .unauthorized {
            return Banner(text: "Bluetooth access is switched off for this app in Settings.", symbol: "lock", tint: .orange)
        }
        if model.isSyncing {
            return Banner(text: syncText, busy: true)
        }
        switch model.link {
        case .searching: return Banner(text: "Looking for your band…", busy: true)
        case .securing: return Banner(text: "Connecting…", busy: true)
        case .failed(let message): return Banner(text: message, symbol: "exclamationmark.triangle", tint: .orange, retry: true)
        case .needsRepair(let message): return Banner(text: message, symbol: "exclamationmark.triangle", tint: .red)
        case .idle, .ready:
            if let note = model.syncNote {
                return Banner(text: note, symbol: "exclamationmark.circle", tint: .orange, retry: model.link == .ready)
            }
            return nil
        }
    }

    private var syncText: String {
        guard let progress = model.progress else { return "Syncing…" }
        switch progress.phase {
        case .preparing: return "Syncing…"
        case .sleep: return "Reading sleep \(progress.completed + 1) of \(max(progress.total, 1))…"
        case .activity: return "Reading activity \(progress.completed + 1) of \(max(progress.total, 1))…"
        case .totals, .finished: return "Finishing…"
        }
    }
}
