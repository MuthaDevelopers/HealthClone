import BandKit
import SwiftUI

/// The band itself: connection, battery, the options pushed to it, and removing it.
struct DeviceView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmRemoval = false
    @State private var showDiagnostics = DemoData.requestedScreen == "diagnostics"

    var body: some View {
        NavigationStack {
            Form {
                if case .needsRepair(let message) = model.link {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                        Button("Pair again") { Task { await model.forgetBand(eraseData: false) } }
                    } footer: {
                        Text("Your synced data is kept.")
                    }
                }
                bandSection
                goalSection
                optionsSection
                profileSection
                Section {
                    NavigationLink("Diagnostics") { DiagnosticsView() }
                } footer: {
                    Text("A log of what the app and the band said to each other, for when something does not work.")
                }
                if !model.isDemo {
                    Section {
                        Button("Remove this band", role: .destructive) { confirmRemoval = true }
                    }
                }
            }
            .navigationTitle("Band")
            .navigationDestination(isPresented: $showDiagnostics) { DiagnosticsView() }
            .confirmationDialog("Remove \(model.paired?.name ?? "this band")?", isPresented: $confirmRemoval, titleVisibility: .visible) {
                Button("Remove, keep my data") { Task { await model.forgetBand(eraseData: false) } }
                Button("Remove and erase my data", role: .destructive) { Task { await model.forgetBand(eraseData: true) } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The band is not reset. You can pair it with this phone again at any time.")
            }
        }
    }

    // MARK: Sections

    private var bandSection: some View {
        Section {
            LabeledContent("Name", value: model.paired?.name ?? "–")
            LabeledContent("Status", value: statusText)
            if let level = model.state.batteryLevel {
                LabeledContent("Battery") {
                    Label("\(level)%", systemImage: batterySymbol(level))
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(level <= 15 ? Color.red : Color.secondary)
                }
            }
            if let modelName = model.state.device?.model {
                LabeledContent("Model", value: modelName)
            }
            if let firmware = model.state.device?.softwareVersion {
                LabeledContent("Firmware", value: firmware)
            }
            if let last = model.state.lastSync {
                LabeledContent("Last sync", value: Format.relative(last))
            }
            Button {
                Task { await model.syncNow() }
            } label: {
                HStack {
                    Text("Sync now")
                    if model.isSyncing {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(model.isSyncing || model.isDemo)
        } header: {
            Text("Band")
        } footer: {
            if let note = model.syncNote {
                Text(note)
            }
        }
    }

    private var goalSection: some View {
        Section("Goal") {
            Stepper(value: setting(\.stepGoal), in: 1000...50_000, step: 500) {
                LabeledContent("Daily steps", value: Format.count(model.settings.stepGoal))
            }
        }
    }

    private var optionsSection: some View {
        Section {
            Picker("Worn on", selection: setting(\.wornOnLeftWrist)) {
                Text("Left wrist").tag(true)
                Text("Right wrist").tag(false)
            }
            Toggle("Raise wrist to wake screen", isOn: setting(\.raiseToWake))
            Toggle("Rotate wrist to switch screens", isOn: setting(\.rotateToSwitchScreens))
            Toggle("Continuous heart rate", isOn: setting(\.continuousHeartRate))
            Toggle("24-hour clock", isOn: setting(\.use24HourClock))
            Picker("Date format", selection: setting(\.dateOrder)) {
                Text("Day first").tag(BandSettings.DateOrder.dayFirst)
                Text("Month first").tag(BandSettings.DateOrder.monthFirst)
                Text("Year first").tag(BandSettings.DateOrder.yearFirst)
            }
            Picker("Units", selection: setting(\.useMetricUnits)) {
                Text("Metric").tag(true)
                Text("Imperial").tag(false)
            }
        } header: {
            Text("On the band")
        } footer: {
            if model.settingsIssues.isEmpty {
                Text("Changes are sent to the band the next time it is connected. Continuous heart rate uses more battery.")
            } else {
                Text("The band did not accept: \(model.settingsIssues.joined(separator: ", ")).")
            }
        }
    }

    private var profileSection: some View {
        Section {
            Stepper(value: setting(\.profile.heightCm), in: 100...230) {
                LabeledContent("Height", value: "\(model.settings.profile.heightCm) cm")
            }
            Stepper(value: setting(\.profile.weightKg), in: 30...200) {
                LabeledContent("Weight", value: "\(model.settings.profile.weightKg) kg")
            }
            Picker("Sex", selection: setting(\.profile.sex)) {
                Text("Male").tag(UserProfile.Sex.male)
                Text("Female").tag(UserProfile.Sex.female)
            }
            DatePicker("Date of birth", selection: birthDate, in: ...Date(), displayedComponents: .date)
        } header: {
            Text("About you")
        } footer: {
            Text("The band uses these to estimate distance and energy. They are sent to the band and stored nowhere else.")
        }
    }

    // MARK: Helpers

    private func setting<Value>(_ keyPath: WritableKeyPath<BandSettings, Value>) -> Binding<Value> {
        Binding(
            get: { model.settings[keyPath: keyPath] },
            set: { value in model.updateSettings { $0[keyPath: keyPath] = value } })
    }

    private var birthDate: Binding<Date> {
        Binding(
            get: {
                let profile = model.settings.profile
                let components = DateComponents(year: profile.birthYear, month: profile.birthMonth, day: profile.birthDay)
                return Calendar.current.date(from: components) ?? Date()
            },
            set: { date in
                let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
                model.updateSettings {
                    $0.profile.birthYear = parts.year ?? $0.profile.birthYear
                    $0.profile.birthMonth = parts.month ?? $0.profile.birthMonth
                    $0.profile.birthDay = parts.day ?? $0.profile.birthDay
                }
            })
    }

    private var statusText: String {
        if model.isDemo { return "Demo" }
        if model.isSyncing { return "Syncing…" }
        switch model.link {
        case .idle: return "Not connected"
        case .searching: return "Looking for band…"
        case .securing: return "Connecting…"
        case .ready: return "Connected"
        case .failed: return "Connection failed"
        case .needsRepair: return "Needs pairing again"
        }
    }

    private func batterySymbol(_ level: Int) -> String {
        switch level {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}
