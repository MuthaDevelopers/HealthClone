import BandKit
import SwiftUI
import UIKit

/// What the app and the band said to each other, and a check that today's numbers are consistent.
struct DiagnosticsView: View {
    @Environment(AppModel.self) private var model
    @State private var entries = [AppLog.Entry]()
    @State private var check = CrossCheck()
    @State private var export: ExportFile?
    @State private var exportFailed = false

    private struct ExportFile: Identifiable {
        let id = UUID()
        let url: URL
    }

    var body: some View {
        List {
            Section {
                comparison("Steps", band: check.band?.steps, minutes: check.minuteSteps, unit: "")
                comparison("Energy", band: check.band?.calories, minutes: check.minuteCalories, unit: " kcal")
                comparison("Distance", band: check.band?.distance, minutes: check.minuteDistance, unit: " m")
            } header: {
                Text("Today, checked two ways")
            } footer: {
                Text("The first figure is the band's own total; the second is its minute-by-minute records added up. They should be close. A large gap on the first few syncs is worth reporting, with the log below.")
            }

            Section("Stored today") {
                LabeledContent("Minutes with data", value: "\(check.minuteCount)")
                LabeledContent("Heart rate readings", value: "\(check.heartRateCount)")
                LabeledContent("Sleep segments", value: "\(check.sleepSegments)")
                LabeledContent("Newest record", value: check.newestMinute.map(Format.clock) ?? "–")
                if let address = model.state.device?.reportedAddress {
                    LabeledContent("Address reported by band", value: address)
                }
            }

            Section {
                if entries.isEmpty {
                    Text("Nothing logged yet.").foregroundStyle(.secondary)
                }
                ForEach(entries.suffix(400).reversed()) { entry in
                    Text(AppLog.line(entry))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(color(entry.level))
                        .textSelection(.enabled)
                }
            } header: {
                Text("Log, newest first")
            } footer: {
                Text("The log holds the raw messages exchanged with the band. It includes the band's serial number and your activity figures, but never the pairing key. It is kept in memory only and is gone when the app closes.")
            }
        }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    model.log.clear()
                    entries = []
                } label: {
                    Image(systemName: "trash")
                }
                .accessibilityLabel("Clear log")
                Button {
                    if let url = try? model.log.exportFile(header: model.diagnosticsHeader()) {
                        export = ExportFile(url: url)
                    } else {
                        exportFailed = true
                    }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("Share log")
            }
        }
        .sheet(item: $export) { file in
            ShareSheet(items: [file.url])
        }
        .alert("The log could not be written to a file.", isPresented: $exportFailed) {
            Button("OK", role: .cancel) {}
        }
        .task(id: model.dataVersion) {
            check = await model.crossCheck()
        }
        .task {
            // The log is written from other threads, so it is polled rather than observed.
            while !Task.isCancelled {
                entries = model.log.snapshot()
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
    }

    private func comparison(_ title: String, band: Int?, minutes: Int, unit: String) -> some View {
        LabeledContent(title) {
            Text("\(band.map { Format.count($0) } ?? "–") · \(Format.count(minutes))\(unit)")
                .monospacedDigit()
        }
    }

    private func color(_ level: LogLevel) -> Color {
        switch level {
        case .error: return .red
        case .warning: return .orange
        case .info: return .primary
        case .debug: return .secondary
        }
    }
}

/// The system share sheet.
private struct ShareSheet: UIViewControllerRepresentable {
    var items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
