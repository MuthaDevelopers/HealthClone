import BandKit
import CoreBluetooth
import Foundation

/// The band's write and notify characteristics presented to BandKit as a byte pipe.
///
/// CoreBluetooth objects are only touched on the central's queue. `BluetoothCentral` owns the
/// peripheral's delegate and forwards the relevant callbacks here.
final class PeripheralTransport: BandTransport, @unchecked Sendable {
    let notifications: AsyncStream<[UInt8]>

    private let peripheral: CBPeripheral
    private let characteristic: CBCharacteristic
    private let writeType: CBCharacteristicWriteType
    private let queue: DispatchQueue
    private let sink: AsyncStream<[UInt8]>.Continuation

    // Confined to `queue`.
    private var queued = [(data: Data, continuation: CheckedContinuation<Void, Error>)]()
    private var awaitingAcknowledgement: CheckedContinuation<Void, Error>?
    private var closed = false

    init(peripheral: CBPeripheral, characteristic: CBCharacteristic, queue: DispatchQueue) {
        self.peripheral = peripheral
        self.characteristic = characteristic
        self.queue = queue
        // The band expects unacknowledged writes; fall back to acknowledged ones only if that is
        // all the characteristic offers.
        writeType = characteristic.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        (notifications, sink) = AsyncStream<[UInt8]>.makeStream()
    }

    var maximumWriteLength: Int {
        queue.sync { peripheral.maximumWriteValueLength(for: writeType) }
    }

    func write(_ bytes: [UInt8]) async throws {
        let data = Data(bytes)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                guard !self.closed else {
                    continuation.resume(throwing: BandError.disconnected)
                    return
                }
                if self.writeType == .withResponse {
                    self.awaitingAcknowledgement = continuation
                    self.peripheral.writeValue(data, for: self.characteristic, type: .withResponse)
                } else if self.queued.isEmpty && self.peripheral.canSendWriteWithoutResponse {
                    self.peripheral.writeValue(data, for: self.characteristic, type: .withoutResponse)
                    continuation.resume()
                } else {
                    // The system's send buffer is full; wait until it says there is room again.
                    self.queued.append((data, continuation))
                    self.queue.asyncAfter(deadline: .now() + 1.5) { self.flush(force: true) }
                }
            }
        }
    }

    // MARK: Called by BluetoothCentral on its queue

    func didReceive(_ data: Data) {
        sink.yield([UInt8](data))
    }

    func didAcknowledgeWrite(error: Error?) {
        guard let continuation = awaitingAcknowledgement else { return }
        awaitingAcknowledgement = nil
        if error == nil {
            continuation.resume()
        } else {
            continuation.resume(throwing: BandError.disconnected)
        }
    }

    /// Sends queued writes while the system has room. `force` is the safety net for the rare case
    /// where the "ready" callback never arrives.
    func flush(force: Bool = false) {
        while !closed, !queued.isEmpty, force || peripheral.canSendWriteWithoutResponse {
            let next = queued.removeFirst()
            peripheral.writeValue(next.data, for: characteristic, type: .withoutResponse)
            next.continuation.resume()
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        sink.finish()
        awaitingAcknowledgement?.resume(throwing: BandError.disconnected)
        awaitingAcknowledgement = nil
        for pending in queued { pending.continuation.resume(throwing: BandError.disconnected) }
        queued.removeAll()
    }
}
