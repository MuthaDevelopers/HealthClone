import BandKit
import SwiftUI

/// First-run flow: find the band, pair with it, and ask for its address only if that is needed.
struct PairingView: View {
    @Environment(AppModel.self) private var model
    @State private var showOtherDevices = false
    @State private var address = ""

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .scanning:
                    scanning
                case .working(let band, let message):
                    working(band, message)
                case .needsAddress(let band, let message):
                    addressEntry(band, message)
                case .failed(let message):
                    failed(message)
                }
            }
            .navigationTitle("Set up your band")
            .background(Color(.systemGroupedBackground))
        }
        .onAppear { model.beginPairing() }
        .onDisappear { model.endPairing() }
    }

    /// In demo mode the real pairing state never changes, so the screens are shown directly.
    private var step: AppModel.Pairing {
        guard model.isDemo else { return model.pairing }
        return DemoData.requestedScreen == "address" ? .needsAddress(DemoData.discovered[0], message: nil) : .scanning
    }

    private var bands: [DiscoveredBand] {
        let all = model.isDemo ? DemoData.discovered : model.discovered
        return showOtherDevices ? all : all.filter(\.isLikelyBand)
    }

    // MARK: Scanning

    @ViewBuilder private var scanning: some View {
        switch model.availability {
        case .poweredOff where !model.isDemo:
            ContentUnavailableView("Bluetooth is off", systemImage: "antenna.radiowaves.left.and.right.slash",
                                   description: Text("Turn Bluetooth on in Control Centre to find your band."))
        case .unauthorized where !model.isDemo:
            ContentUnavailableView {
                Label("Bluetooth access needed", systemImage: "lock")
            } description: {
                Text("Allow Band Companion to use Bluetooth in Settings.")
            } actions: {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
            }
        case .unsupported where !model.isDemo:
            ContentUnavailableView("No Bluetooth here", systemImage: "xmark.circle",
                                   description: Text("This device cannot talk to a band. The simulator has no Bluetooth; launch with the -demo argument to look around."))
        default:
            List {
                Section {
                    if bands.isEmpty {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Looking for bands…").foregroundStyle(.secondary)
                        }
                    }
                    ForEach(bands) { band in
                        Button {
                            address = ""
                            model.pair(band, addressText: nil)
                        } label: {
                            HStack {
                                Image(systemName: band.isLikelyBand ? "applewatch.side.right" : "dot.radiowaves.left.and.right")
                                    .foregroundStyle(band.isLikelyBand ? Color.accentColor : .secondary)
                                    .frame(width: 28)
                                Text(band.name).foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: "cellularbars", variableValue: signal(band.rssi))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Nearby")
                } footer: {
                    Text("Wake the band and keep it close. If it is still connected to another phone, disconnect it there first, or it will not show up.")
                }

                Section {
                    Toggle("Show other Bluetooth devices", isOn: $showOtherDevices)
                } footer: {
                    Text("Turn this on if your band is not listed under its usual name.")
                }
            }
        }
    }

    /// Maps signal strength to a 0…1 fill for the bars symbol.
    private func signal(_ rssi: Int) -> Double {
        guard rssi != 0 else { return 1 }
        return min(max((Double(rssi) + 95) / 45, 0.1), 1)
    }

    // MARK: Working

    private func working(_ band: DiscoveredBand, _ message: String) -> some View {
        VStack(spacing: 20) {
            Spacer()
            ProgressView().controlSize(.large)
            Text(band.name).font(.headline)
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)
            Spacer()
            Button("Cancel") {
                model.endPairing()
                model.beginPairing()
            }
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Address

    private func addressEntry(_ band: DiscoveredBand, _ message: String?) -> some View {
        let parsed = BandAddress(address)
        let mismatch = parsed.map { !AddressGuess.matches($0, name: band.name) } ?? false

        return Form {
            if let message {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
            }
            Section {
                TextField("AA:BB:CC:DD:EE:FF", text: $address)
                    .font(.system(.title3, design: .monospaced))
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .keyboardType(.asciiCapable)
                    .submitLabel(.done)
                if mismatch, let suffix = AddressGuess.nameSuffix(band.name) {
                    Label("The band's name suggests an address ending in \(suffix). Please double-check.", systemImage: "questionmark.circle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Bluetooth address of \(band.name)")
            } footer: {
                Text("iPhones do not tell apps a band's Bluetooth address, and the band needs it once, to pair. On the band, open More, then System or About, and look for the line labelled MAC. Type the twelve characters shown there; the colons are optional.")
            }
            Section {
                Button("Pair") { model.pair(band, addressText: address) }
                    .frame(maxWidth: .infinity)
                    .disabled(parsed == nil)
                Button("Choose a different band", role: .cancel) { model.beginPairing() }
                    .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: Failure

    private func failed(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Pairing did not finish", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Try again") { model.beginPairing() }
                .buttonStyle(.borderedProminent)
        }
    }
}
