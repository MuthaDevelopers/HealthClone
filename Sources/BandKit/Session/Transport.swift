import Foundation

/// The byte pipe to the band. On the phone this is two Bluetooth LE characteristics; in tests it is
/// a simulated band.
public protocol BandTransport: AnyObject, Sendable {
    /// Most bytes a single write may carry on this connection.
    var maximumWriteLength: Int { get }

    /// Sends one write to the band.
    func write(_ bytes: [UInt8]) async throws

    /// Everything the band sends, in arrival order. The stream ends when the connection drops.
    var notifications: AsyncStream<[UInt8]> { get }
}

public enum LogLevel: String, Sendable, Codable {
    case debug, info, warning, error
}

/// Receives a running commentary of the link, including raw traffic, for the in-app diagnostics.
public protocol BandLogger: Sendable {
    func log(_ level: LogLevel, _ message: String)
}

/// Discards everything.
public struct SilentLogger: BandLogger {
    public init() {}
    public func log(_ level: LogLevel, _ message: String) {}
}

public enum BandError: Error, Equatable, Sendable {
    /// The connection dropped, or was never open.
    case disconnected
    /// The band did not answer a command in time.
    case timeout(service: UInt8, command: UInt8)
    /// The band answered with an error code instead of the expected data.
    case rejected(service: UInt8, command: UInt8, code: Int)
    /// A reply arrived but did not contain what the protocol says it should.
    case malformedReply(service: UInt8, command: UInt8, detail: String)
    /// The band speaks a protocol revision this app does not.
    case unsupportedProtocol(version: Int)
    /// The band wants a newer pairing scheme than the one the Honor Band 4 uses.
    case unsupportedSecurity(scheme: Int)
    /// The band failed to prove it knows the shared handshake secret.
    case authenticationFailed
    /// First-time pairing needs the band's Bluetooth address and none was supplied.
    case deviceAddressRequired
    /// The band did not accept, or could not use, the link key it was sent. On a first pairing
    /// this almost always means the Bluetooth address entered was wrong.
    case linkKeyRejected(firstPairing: Bool)
    /// A reply could not be decrypted with the stored link key.
    case decryptionFailed
    /// A command that needs an encrypted link was attempted before pairing finished.
    case notPaired
}

extension BandError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .disconnected:
            return "The band disconnected."
        case .timeout(let service, let command):
            return "The band did not answer (command \(Bytes.hex([service]))/\(Bytes.hex([command])))."
        case .rejected(let service, let command, let code):
            return "The band refused command \(Bytes.hex([service]))/\(Bytes.hex([command])) with code \(code)."
        case .malformedReply(let service, let command, let detail):
            return "Unexpected reply to \(Bytes.hex([service]))/\(Bytes.hex([command])): \(detail)."
        case .unsupportedProtocol(let version):
            return "This band uses link protocol version \(version), which this app does not support."
        case .unsupportedSecurity(let scheme):
            return "This band asks for pairing scheme \(scheme), which this app does not support."
        case .authenticationFailed:
            return "The band did not pass the handshake check."
        case .deviceAddressRequired:
            return "The band's Bluetooth address is needed to pair for the first time."
        case .linkKeyRejected(let firstPairing):
            return firstPairing
                ? "Pairing did not take. Check the Bluetooth address against the one shown on the band and try again."
                : "The band no longer accepts this phone's pairing. Remove the band in the app and pair again."
        case .decryptionFailed:
            return "A reply from the band could not be decrypted."
        case .notPaired:
            return "The band is not paired yet."
        }
    }
}

/// What this phone needs to remember about one band between launches.
///
/// `linkKey` is the secret the two sides encrypt with, so it belongs in the keychain.
public struct PairingIdentity: Equatable, Sendable, Codable {
    /// A made-up address this phone presents to the band as its own. iOS does not reveal the
    /// phone's real one, and the band only uses it as a label to recognise a returning phone.
    public var clientAddress: String
    public var linkKey: [UInt8]
    /// The band's Bluetooth address, needed once, for the first pairing.
    public var deviceAddress: BandAddress?

    public init(clientAddress: String, linkKey: [UInt8], deviceAddress: BandAddress? = nil) {
        self.clientAddress = clientAddress
        self.linkKey = linkKey
        self.deviceAddress = deviceAddress
    }

    /// A fresh identity with a random link key and client address.
    public static func generate(random: RandomSource = SystemRandomSource(), deviceAddress: BandAddress? = nil) -> PairingIdentity {
        let tail = random.bytes(3).map { Bytes.hex([$0]) }.joined(separator: ":")
        return PairingIdentity(clientAddress: "FF:FF:FF:" + tail, linkKey: random.bytes(16), deviceAddress: deviceAddress)
    }

    /// The six-character label derived from the client address that the band stores for this phone.
    public var clientSerial: String {
        String(clientAddress.replacingOccurrences(of: ":", with: "").suffix(6))
    }
}

/// Events the band raises on its own, outside any request.
public enum BandEvent: Equatable, Sendable {
    case batteryLevel(Int)
    /// Something arrived that nothing was waiting for and that this app does not interpret.
    case unhandled(service: UInt8, command: UInt8)
}
