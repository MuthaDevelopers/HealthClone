import BandKit
import CoreBluetooth
import Foundation

/// A band seen while scanning.
struct DiscoveredBand: Identifiable, Equatable {
    let id: UUID
    var name: String
    var rssi: Int
    /// Raw advertisement payloads, searched for the band's own address.
    var advertisedData: [[UInt8]]
    /// True when the name or advertised service marks this as a band this app can talk to.
    var isLikelyBand: Bool
}

enum BluetoothAvailability: Equatable {
    case unknown, poweredOff, unauthorized, unsupported, ready
}

enum BluetoothFailure: LocalizedError, Equatable {
    case unavailable(BluetoothAvailability)
    case bandNotFound
    case connectionFailed(String)
    case serviceMissing
    case timedOut
    case cancelled

    var errorDescription: String? {
        switch self {
        case .unavailable(.poweredOff): return "Bluetooth is switched off. Turn it on in Control Centre."
        case .unavailable(.unauthorized): return "Band Companion is not allowed to use Bluetooth. Allow it in Settings → Privacy & Security → Bluetooth."
        case .unavailable(.unsupported): return "This device has no Bluetooth LE."
        case .unavailable: return "Bluetooth is not ready yet."
        case .bandNotFound: return "The band could not be found. Make sure it is nearby and not connected to another phone."
        case .connectionFailed(let reason): return "Could not connect to the band: \(reason)"
        case .serviceMissing: return "This device does not offer the service this app talks to, so it is probably not a supported band."
        case .timedOut: return "The band did not respond. Bring it closer and make sure it is not connected to another phone."
        case .cancelled: return "Cancelled."
        }
    }
}

/// Wraps `CBCentralManager`: scanning, connecting and handing back a ready transport.
///
/// Everything CoreBluetooth runs on one private serial queue. The `on…` callbacks are invoked on
/// the main queue.
final class BluetoothCentral: NSObject, @unchecked Sendable {
    static let bandService = CBUUID(string: "FE86")
    static let writeCharacteristic = CBUUID(string: "FE01")
    static let notifyCharacteristic = CBUUID(string: "FE02")

    var onAvailability: ((BluetoothAvailability) -> Void)?
    var onDiscovered: (([DiscoveredBand]) -> Void)?
    var onDisconnected: (() -> Void)?

    private let queue = DispatchQueue(label: "dev.bandcompanion.bluetooth")
    private let log: BandLogger

    // Confined to `queue`.
    private var manager: CBCentralManager?
    private var known = [UUID: CBPeripheral]()
    private var found = [UUID: DiscoveredBand]()
    private var wantsScan = false
    private var attempt: Attempt?
    private var attemptCounter = 0
    private var connected: CBPeripheral?
    private var transport: PeripheralTransport?

    private struct Attempt {
        let token: Int
        let peripheral: CBPeripheral?
        let identifier: UUID
        let continuation: CheckedContinuation<PeripheralTransport, Error>
    }

    init(log: BandLogger) {
        self.log = log
        super.init()
    }

    /// Creates the central manager. The first call is what makes iOS ask for Bluetooth permission,
    /// so it is deferred until the app actually needs the radio.
    func activate() {
        queue.async {
            guard self.manager == nil else { return }
            self.manager = CBCentralManager(delegate: self, queue: self.queue)
        }
    }

    // MARK: Scanning

    func startScan() {
        queue.async {
            self.wantsScan = true
            self.found.removeAll()
            self.beginScanIfPossible()
        }
    }

    func stopScan() {
        queue.async {
            self.wantsScan = false
            if self.manager?.state == .poweredOn { self.manager?.stopScan() }
        }
    }

    private func beginScanIfPossible() {
        guard wantsScan, let manager, manager.state == .poweredOn else { return }
        // A band the system is already connected to does not advertise, so ask for those too.
        for peripheral in manager.retrieveConnectedPeripherals(withServices: [BluetoothCentral.bandService]) {
            record(peripheral, name: peripheral.name, rssi: 0, data: [], advertisesService: true)
        }
        manager.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        log.log(.info, "Scanning for bands")
    }

    private func record(_ peripheral: CBPeripheral, name: String?, rssi: Int, data: [[UInt8]], advertisesService: Bool) {
        guard let name, !name.isEmpty else { return }
        let lowered = name.lowercased()
        let likely = advertisesService || lowered.contains("band") || lowered.contains("honor") || lowered.contains("huawei")
        known[peripheral.identifier] = peripheral

        var entry = found[peripheral.identifier]
            ?? DiscoveredBand(id: peripheral.identifier, name: name, rssi: rssi, advertisedData: [], isLikelyBand: likely)
        entry.name = name
        if rssi != 0 { entry.rssi = rssi }
        entry.isLikelyBand = entry.isLikelyBand || likely
        for blob in data where !entry.advertisedData.contains(blob) { entry.advertisedData.append(blob) }
        found[peripheral.identifier] = entry

        let list = found.values.sorted { ($0.isLikelyBand ? 1 : 0, $0.rssi) > ($1.isLikelyBand ? 1 : 0, $1.rssi) }
        DispatchQueue.main.async { self.onDiscovered?(list) }
    }

    // MARK: Connecting

    /// Connects, finds the band's characteristics and turns on notifications.
    ///
    /// - Parameter timeout: nil waits indefinitely, which is how a known band is picked up again
    ///   whenever it next comes into range.
    func connect(_ identifier: UUID, timeout: TimeInterval?) async throws -> PeripheralTransport {
        // Cancellation can arrive before the attempt has been set up, so it is recorded as well as
        // acted on. Both blocks run on the same serial queue, which makes the flag safe.
        let cancellation = Cancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    if cancellation.requested {
                        continuation.resume(throwing: BluetoothFailure.cancelled)
                    } else {
                        self.begin(identifier, timeout: timeout, continuation: continuation)
                    }
                }
            }
        } onCancel: {
            queue.async {
                cancellation.requested = true
                self.failAttempt(.cancelled, dropConnection: true)
            }
        }
    }

    private final class Cancellation: @unchecked Sendable {
        var requested = false
    }

    func disconnect() {
        queue.async {
            self.failAttempt(.cancelled, dropConnection: true)
            if let connected = self.connected { self.manager?.cancelPeripheralConnection(connected) }
        }
    }

    private func begin(_ identifier: UUID, timeout: TimeInterval?, continuation: CheckedContinuation<PeripheralTransport, Error>) {
        failAttempt(.cancelled, dropConnection: true)
        guard let manager else {
            continuation.resume(throwing: BluetoothFailure.unavailable(.unknown))
            return
        }
        switch manager.state {
        case .poweredOff: return continuation.resume(throwing: BluetoothFailure.unavailable(.poweredOff))
        case .unauthorized: return continuation.resume(throwing: BluetoothFailure.unavailable(.unauthorized))
        case .unsupported: return continuation.resume(throwing: BluetoothFailure.unavailable(.unsupported))
        default: break
        }

        attemptCounter += 1
        let token = attemptCounter
        if let timeout {
            queue.asyncAfter(deadline: .now() + timeout) {
                if self.attempt?.token == token { self.failAttempt(.timedOut, dropConnection: true) }
            }
        }

        // If the radio is still starting up, the attempt waits for it in centralManagerDidUpdateState.
        attempt = Attempt(token: token, peripheral: nil, identifier: identifier, continuation: continuation)
        if manager.state == .poweredOn { startPendingAttempt() }
    }

    private func startPendingAttempt() {
        guard let manager, let pending = attempt, pending.peripheral == nil else { return }
        guard let peripheral = known[pending.identifier] ?? manager.retrievePeripherals(withIdentifiers: [pending.identifier]).first else {
            failAttempt(.bandNotFound, dropConnection: false)
            return
        }
        known[pending.identifier] = peripheral
        attempt = Attempt(token: pending.token, peripheral: peripheral, identifier: pending.identifier, continuation: pending.continuation)
        if let previous = connected, previous.identifier != peripheral.identifier { manager.cancelPeripheralConnection(previous) }
        peripheral.delegate = self
        log.log(.info, "Connecting to \(peripheral.name ?? "band")")
        manager.connect(peripheral, options: nil)
    }

    private func failAttempt(_ failure: BluetoothFailure, dropConnection: Bool) {
        guard let pending = attempt else { return }
        attempt = nil
        if dropConnection, let peripheral = pending.peripheral { manager?.cancelPeripheralConnection(peripheral) }
        if failure != .cancelled { log.log(.warning, "Connection attempt failed: \(failure)") }
        pending.continuation.resume(throwing: failure)
    }

    private func availability(for state: CBManagerState) -> BluetoothAvailability {
        switch state {
        case .poweredOn: return .ready
        case .poweredOff: return .poweredOff
        case .unauthorized: return .unauthorized
        case .unsupported: return .unsupported
        default: return .unknown
        }
    }
}

extension BluetoothCentral: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state = availability(for: central.state)
        log.log(.info, "Bluetooth state: \(state)")
        DispatchQueue.main.async { self.onAvailability?(state) }

        switch central.state {
        case .poweredOn:
            beginScanIfPossible()
            startPendingAttempt()
        case .poweredOff, .unauthorized, .unsupported:
            failAttempt(.unavailable(state), dropConnection: false)
            transport?.close()
            transport = nil
            connected = nil
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name
        var data = [[UInt8]]()
        if let manufacturer = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data { data.append([UInt8](manufacturer)) }
        if let service = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] {
            data.append(contentsOf: service.values.map { [UInt8]($0) })
        }
        let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        record(peripheral, name: name, rssi: RSSI.intValue, data: data,
               advertisesService: services.contains(BluetoothCentral.bandService))
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard attempt?.peripheral?.identifier == peripheral.identifier else { return }
        connected = peripheral
        peripheral.discoverServices([BluetoothCentral.bandService])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard attempt?.peripheral?.identifier == peripheral.identifier else { return }
        failAttempt(.connectionFailed(error?.localizedDescription ?? "unknown error"), dropConnection: false)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        log.log(.info, "Band disconnected\(error.map { ": \($0.localizedDescription)" } ?? "")")
        if attempt?.peripheral?.identifier == peripheral.identifier {
            failAttempt(.connectionFailed(error?.localizedDescription ?? "the band closed the connection"), dropConnection: false)
        }
        guard connected?.identifier == peripheral.identifier else { return }
        connected = nil
        transport?.close()
        transport = nil
        DispatchQueue.main.async { self.onDisconnected?() }
    }
}

extension BluetoothCentral: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard attempt?.peripheral?.identifier == peripheral.identifier else { return }
        guard let service = peripheral.services?.first(where: { $0.uuid == BluetoothCentral.bandService }) else {
            failAttempt(.serviceMissing, dropConnection: true)
            return
        }
        peripheral.discoverCharacteristics([BluetoothCentral.writeCharacteristic, BluetoothCentral.notifyCharacteristic], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard attempt?.peripheral?.identifier == peripheral.identifier else { return }
        let characteristics = service.characteristics ?? []
        guard characteristics.contains(where: { $0.uuid == BluetoothCentral.writeCharacteristic }),
              let notify = characteristics.first(where: { $0.uuid == BluetoothCentral.notifyCharacteristic }) else {
            failAttempt(.serviceMissing, dropConnection: true)
            return
        }
        peripheral.setNotifyValue(true, for: notify)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard let pending = attempt, pending.peripheral?.identifier == peripheral.identifier,
              characteristic.uuid == BluetoothCentral.notifyCharacteristic else { return }
        if let error {
            failAttempt(.connectionFailed(error.localizedDescription), dropConnection: true)
            return
        }
        guard let write = characteristic.service?.characteristics?.first(where: { $0.uuid == BluetoothCentral.writeCharacteristic }) else {
            failAttempt(.serviceMissing, dropConnection: true)
            return
        }
        let ready = PeripheralTransport(peripheral: peripheral, characteristic: write, queue: queue)
        transport = ready
        attempt = nil
        log.log(.info, "Connected; largest write \(peripheral.maximumWriteValueLength(for: .withoutResponse)) bytes")
        pending.continuation.resume(returning: ready)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == BluetoothCentral.notifyCharacteristic, let value = characteristic.value else { return }
        transport?.didReceive(value)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        transport?.didAcknowledgeWrite(error: error)
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        transport?.flush()
    }
}
