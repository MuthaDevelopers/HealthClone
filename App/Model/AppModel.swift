import BandKit
import Foundation
import Observation
import UIKit

struct CrossCheck: Equatable {
    var band: BandTotals?
    var minuteSteps = 0
    var minuteCalories = 0
    var minuteDistance = 0
    var minuteCount = 0
    var heartRateCount = 0
    var sleepSegments = 0
    var newestMinute: Int?
}

/// The app's single source of truth: which band is paired, the state of the link, and access to
/// the synced data. Views observe it and call its methods; nothing else talks to Bluetooth.
@MainActor
@Observable
final class AppModel {
    enum Link: Equatable {
        /// Not connected and not trying.
        case idle
        /// Waiting for the band to come into range.
        case searching
        /// Connected; running the handshake.
        case securing
        case ready
        case failed(String)
        /// The band no longer accepts this phone's pairing, so it has to be paired again.
        case needsRepair(String)
    }

    enum Pairing: Equatable {
        case scanning
        case working(DiscoveredBand, String)
        case needsAddress(DiscoveredBand, message: String?)
        case failed(String)
    }

    // MARK: Observed state

    private(set) var availability: BluetoothAvailability = .unknown
    private(set) var paired: PairedBand?
    private(set) var link: Link = .idle
    private(set) var pairing: Pairing = .scanning
    private(set) var discovered = [DiscoveredBand]()
    private(set) var progress: SyncProgress?
    private(set) var isSyncing = false
    /// The outcome of the last sync worth telling the user about, if any.
    private(set) var syncNote: String?
    private(set) var state = StoreState()
    private(set) var settings: BandSettings
    /// Settings the band refused the last time they were sent.
    private(set) var settingsIssues = [String]()
    /// Bumped whenever stored data changes so views know to reload.
    private(set) var dataVersion = 0

    let isDemo: Bool
    let log = AppLog.shared

    // MARK: Private

    // None of these drive the interface, so they are kept out of observation.
    @ObservationIgnored private let central: BluetoothCentral
    @ObservationIgnored private let store: HealthStore
    @ObservationIgnored private var session: BandSession?
    @ObservationIgnored private var linkTask: Task<Void, Never>?
    @ObservationIgnored private var pairingTask: Task<Void, Never>?
    @ObservationIgnored private var settingsTask: Task<Void, Never>?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var isActive = true
    @ObservationIgnored private var failedAttempts = 0
    @ObservationIgnored private let calendar = Calendar.current

    init() {
        isDemo = ProcessInfo.processInfo.arguments.contains("-demo")
        central = BluetoothCentral(log: AppLog.shared)
        settings = Preferences.settings

        let base = isDemo
            ? FileManager.default.temporaryDirectory.appendingPathComponent("demo-store")
            : (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory).appendingPathComponent("BandCompanion/store")
        if isDemo { try? FileManager.default.removeItem(at: base) }
        do {
            store = try HealthStore(directory: base)
        } catch {
            // Fall back to somewhere writable so the app still opens; data will not persist.
            AppLog.shared.log(.error, "Could not open the data store at \(base.path): \(error)")
            store = try! HealthStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("fallback-store"))
        }

        if isDemo {
            paired = PairedBand(id: UUID(), name: "Demo Band")
            link = .ready
        } else {
            paired = Preferences.pairedBand
            central.onAvailability = { [weak self] value in
                MainActor.assumeIsolated { self?.availabilityChanged(value) }
            }
            central.onDiscovered = { [weak self] bands in
                MainActor.assumeIsolated { self?.discovered = bands }
            }
            central.onDisconnected = { [weak self] in
                MainActor.assumeIsolated { self?.linkDropped() }
            }
        }
    }

    /// Called once when the first screen appears.
    func start() async {
        if isDemo {
            await DemoData.fill(store)
        }
        await refreshState()
        connectIfNeeded()
    }

    func sceneBecameActive() {
        isActive = true
        failedAttempts = 0
        if case .failed = link { link = .idle }
        connectIfNeeded()
        if link == .ready, let last = state.lastSync, Date().timeIntervalSince(last) > 5 * 60 {
            Task { await sync() }
        }
    }

    func sceneLeftForeground() {
        isActive = false
    }

    // MARK: Pairing

    func beginPairing() {
        guard !isDemo else { return }
        pairing = .scanning
        discovered = []
        central.activate()
        central.startScan()
    }

    /// Called when the pairing screens go away. After a successful pairing the task is still busy
    /// with the first sync, so it is only cancelled when nothing was paired.
    func endPairing() {
        central.stopScan()
        if paired == nil {
            pairingTask?.cancel()
            central.disconnect()
        }
        pairingTask = nil
    }

    /// Pairs with a band. `addressText` is what the user typed, or nil to let the app work the
    /// address out itself.
    func pair(_ band: DiscoveredBand, addressText: String?) {
        pairingTask?.cancel()
        pairingTask = Task { await runPairing(band, addressText: addressText) }
    }

    private func runPairing(_ band: DiscoveredBand, addressText: String?) async {
        central.stopScan()

        var address: BandAddress?
        var foundInAdvertisement = false
        if let addressText {
            guard let parsed = BandAddress(addressText) else {
                pairing = .needsAddress(band, message: "That is not a complete address. It has twelve characters, 0–9 and A–F, usually shown as six pairs.")
                return
            }
            address = parsed
        } else if let suffix = AddressGuess.nameSuffix(band.name) {
            let candidates = AddressGuess.candidates(suffix: suffix, in: band.advertisedData)
            if candidates.count == 1 {
                address = candidates[0]
                foundInAdvertisement = true
                log.log(.info, "Found a likely address in the band's advertisement")
            }
        }

        pairing = .working(band, "Connecting…")
        do {
            let transport = try await central.connect(band.id, timeout: 25)
            pairing = .working(band, "Pairing… If the band asks you to confirm, accept on its screen.")
            let identity = PairingIdentity.generate(deviceAddress: address)
            let session = BandSession(transport: transport, logger: log)
            // The identity is brand new, so send its key whatever the band says it remembers.
            let opened = try await session.open(identity: identity, nameHint: band.name, bondPolicy: .always)

            var remembered = identity
            remembered.deviceAddress = opened.deviceAddress ?? address
            try KeychainStore.save(remembered, for: band.id)
            let record = PairedBand(id: band.id, name: band.name)
            Preferences.pairedBand = record
            Preferences.appliedSettings = nil
            paired = record
            await adopt(session, opened)
        } catch is CancellationError {
            central.disconnect()
        } catch let error as BandError {
            central.disconnect()
            switch error {
            case .deviceAddressRequired:
                pairing = .needsAddress(band, message: nil)
            case .linkKeyRejected(firstPairing: true):
                // The band now holds a useless key under this attempt's identity. The next attempt
                // generates a fresh identity, so that does no harm.
                pairing = .needsAddress(band, message: foundInAdvertisement
                    ? "The address found automatically did not work. Please enter the one shown on the band."
                    : "The band did not accept that address. Check it against the band's screen and try again.")
            default:
                pairing = .failed(describe(error))
            }
        } catch let failure as BluetoothFailure {
            if failure != .cancelled { pairing = .failed(describe(failure)) }
        } catch {
            central.disconnect()
            pairing = .failed(describe(error))
        }
    }

    /// Removes the pairing from this phone. The band itself keeps working and can be paired again.
    func forgetBand(eraseData: Bool) async {
        linkTask?.cancel()
        linkTask = nil
        eventTask?.cancel()
        if let session { await session.close() }
        session = nil
        central.disconnect()
        if let paired { KeychainStore.delete(for: paired.id) }
        Preferences.pairedBand = nil
        Preferences.appliedSettings = nil
        paired = nil
        link = .idle
        syncNote = nil
        settingsIssues = []
        if eraseData {
            try? await store.eraseAll()
        } else {
            try? await store.updateState { $0.device = nil; $0.batteryLevel = nil; $0.batteryUpdated = nil }
        }
        await refreshState()
    }

    // MARK: Link

    func connectIfNeeded() {
        guard !isDemo, let band = paired, linkTask == nil, session == nil else { return }
        // After a failure the next attempt has to be asked for, by the user or by the retry
        // below; otherwise a band that keeps refusing would be hammered in a loop.
        switch link {
        case .needsRepair, .failed: return
        default: break
        }
        central.activate()
        linkTask = Task { [weak self] in
            await self?.establishLink(band)
            self?.linkTask = nil
        }
    }

    private func establishLink(_ band: PairedBand) async {
        guard let identity = KeychainStore.load(for: band.id) else {
            link = .needsRepair("This phone's pairing details are missing. Remove the band and pair it again.")
            return
        }
        link = .searching
        do {
            let transport = try await central.connect(band.id, timeout: nil)
            link = .securing
            let session = BandSession(transport: transport, logger: log)
            let opened = try await session.open(identity: identity, nameHint: band.name)
            await adopt(session, opened)
        } catch let error as BandError {
            central.disconnect()
            if case .linkKeyRejected = error {
                link = .needsRepair(describe(error))
            } else {
                link = .failed(describe(error))
                retryAfterFailure()
            }
        } catch let failure as BluetoothFailure {
            link = failure == .cancelled ? .idle : .failed(describe(failure))
        } catch {
            central.disconnect()
            link = .failed(describe(error))
        }
    }

    /// A handshake that fails once often works a moment later, so try twice more before leaving
    /// it to the user.
    private func retryAfterFailure() {
        failedAttempts += 1
        guard failedAttempts <= 2, isActive else { return }
        let delay = UInt64(failedAttempts) * 3_000_000_000
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard let self, case .failed = self.link else { return }
            self.link = .idle
            self.connectIfNeeded()
        }
    }

    private func adopt(_ session: BandSession, _ opened: BandSession.OpenResult) async {
        self.session = session
        link = .ready
        failedAttempts = 0
        let device = opened.device
        try? await store.updateState { $0.device = device }
        await refreshState()

        eventTask?.cancel()
        eventTask = Task { [weak self] in
            for await event in session.events {
                if case .batteryLevel(let level) = event { await self?.batteryChanged(level) }
            }
        }

        await pushSettings(force: opened.bond == .created)
        await sync()
    }

    private func batteryChanged(_ level: Int) async {
        let now = Date()
        try? await store.updateState { $0.batteryLevel = level; $0.batteryUpdated = now }
        await refreshState()
    }

    private func linkDropped() {
        let wasEstablished = link == .ready
        let old = session
        session = nil
        eventTask?.cancel()
        if let old { Task { await old.close() } }
        if link == .ready || link == .securing { link = .idle }
        // Only an established link that dropped is picked up again automatically. A failed attempt
        // is handled where it failed.
        guard wasEstablished, isActive, paired != nil else { return }
        // Wait for the band to come back; the pending connection costs nothing while it is away.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            self?.connectIfNeeded()
        }
    }

    private func availabilityChanged(_ value: BluetoothAvailability) {
        availability = value
        if value == .ready {
            if case .failed = link { link = .idle }
            connectIfNeeded()
        }
    }

    // MARK: Sync

    /// Starts a sync, connecting first if necessary. Used by pull-to-refresh and the sync button.
    func syncNow() async {
        guard !isDemo else { return }
        if session == nil {
            failedAttempts = 0
            if case .failed = link { link = .idle }
            connectIfNeeded()   // a sync follows automatically once the link is up
            return
        }
        await sync()
    }

    private func sync() async {
        guard let session, !isSyncing else { return }
        isSyncing = true
        syncNote = nil
        defer {
            isSyncing = false
            progress = nil
        }
        do {
            let engine = SyncEngine(session: session, store: store, logger: log)
            let report = try await engine.run { [weak self] update in
                Task { @MainActor in self?.progress = update }
            }
            syncNote = report.warnings.first
        } catch {
            syncNote = "Sync stopped: \(describe(error))"
            log.log(.error, "Sync failed: \(error)")
        }
        await refreshState()
    }

    // MARK: Settings

    func updateSettings(_ change: (inout BandSettings) -> Void) {
        var updated = settings
        change(&updated)
        guard updated != settings else { return }
        settings = updated
        Preferences.settings = updated

        // Wait for a pause in the edits before talking to the band.
        settingsTask?.cancel()
        settingsTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            await self?.pushSettings(force: false)
        }
    }

    private func pushSettings(force: Bool) async {
        guard let session else { return }
        let wanted = settings
        guard force || Preferences.appliedSettings != wanted else { return }
        let results = await session.apply(wanted)
        let failures = results.filter { $0.error != nil }
        settingsIssues = failures.map(\.step)
        // Refusals are final for this band, so they do not need re-sending; a dropped link does.
        let linkDroppedMidway = results.count < BandCommands.settingsSteps(wanted, now: Date()).count
        if !linkDroppedMidway { Preferences.appliedSettings = wanted }
    }

    // MARK: Data for views

    func dayBounds(_ date: Date) -> (start: Int, end: Int) {
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return (Int(start.timeIntervalSince1970), Int(end.timeIntervalSince1970))
    }

    func summary(for date: Date) async -> DaySummary {
        let (start, end) = dayBounds(date)
        let minutes = (try? await store.minutes(from: start, to: end)) ?? []
        let window = Summaries.sleepWindow(dayStart: start, dayEnd: end)
        let sleep = (try? await store.sleep(from: window.lowerBound, to: window.upperBound)) ?? []

        // The band's own totals are only for the day they were read on.
        var totals: BandTotals?
        if let updated = state.bandTotalsUpdated, (start..<end).contains(Int(updated.timeIntervalSince1970)) {
            totals = state.bandTotals
        }
        return Summaries.day(dayStart: start, dayEnd: end, minutes: minutes, sleep: sleep, bandTotals: totals)
    }

    /// Summaries for `days` consecutive days ending on `date`, oldest first.
    func trend(endingOn date: Date, days: Int) async -> [DaySummary] {
        var result = [DaySummary]()
        for offset in stride(from: days - 1, through: 0, by: -1) {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: date) else { continue }
            result.append(await summary(for: day))
        }
        return result
    }

    /// Today's figures two ways: what the band says, and what its per-minute records add up to.
    /// The two should agree; when they do not, the difference shows where to look.
    func crossCheck() async -> CrossCheck {
        let (start, end) = dayBounds(Date())
        let minutes = (try? await store.minutes(from: start, to: end)) ?? []
        let window = Summaries.sleepWindow(dayStart: start, dayEnd: end)
        let sleep = (try? await store.sleep(from: window.lowerBound, to: window.upperBound)) ?? []
        var bandTotals: BandTotals?
        if let updated = state.bandTotalsUpdated, (start..<end).contains(Int(updated.timeIntervalSince1970)) {
            bandTotals = state.bandTotals
        }
        return CrossCheck(
            band: bandTotals,
            minuteSteps: minutes.compactMap(\.steps).reduce(0, +),
            minuteCalories: minutes.compactMap(\.calories).reduce(0, +),
            minuteDistance: minutes.compactMap(\.distance).reduce(0, +),
            minuteCount: minutes.count,
            heartRateCount: minutes.filter { $0.heartRate != nil }.count,
            sleepSegments: sleep.count,
            newestMinute: minutes.last?.timestamp)
    }

    private func refreshState() async {
        state = await store.state()
        dataVersion += 1
    }

    /// Context added to the top of an exported log.
    func diagnosticsHeader() -> String {
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        var lines = [
            "Band Companion \(version)",
            "iOS \(UIDevice.current.systemVersion)",
            "Band: \(paired?.name ?? "none")",
            "Model: \(state.device?.model ?? "?")  firmware: \(state.device?.softwareVersion ?? "?")",
            "Link: \(link)",
        ]
        if let last = state.lastSync { lines.append("Last sync: \(last)") }
        if let totals = state.bandTotals {
            lines.append("Band totals: \(totals.steps) steps, \(totals.calories) kcal, \(totals.distance) m")
        }
        return lines.joined(separator: "\n")
    }

    private func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
