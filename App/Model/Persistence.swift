import BandKit
import Foundation
import Security

/// The band this phone is paired with.
struct PairedBand: Codable, Equatable {
    var id: UUID
    var name: String
}

/// Holds each band's pairing identity, including the link key, in the keychain.
///
/// Items are readable after the first unlock so a reconnect in the background works, and are
/// marked device-only so the key is never included in a backup or synced to iCloud.
enum KeychainStore {
    private static let service = "dev.bandcompanion.pairing"

    private static func query(_ id: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
        ]
    }

    static func save(_ identity: PairingIdentity, for id: UUID) throws {
        let data = try JSONEncoder().encode(identity)
        SecItemDelete(query(id) as CFDictionary)
        var attributes = query(id)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "The pairing could not be saved to the keychain (\(status))."])
        }
    }

    static func load(for id: UUID) -> PairingIdentity? {
        var request = query(id)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(PairingIdentity.self, from: data)
    }

    static func delete(for id: UUID) {
        SecItemDelete(query(id) as CFDictionary)
    }
}

/// Small non-secret preferences kept in `UserDefaults`.
enum Preferences {
    private static let defaults = UserDefaults.standard
    private static let bandKey = "pairedBand"
    private static let settingsKey = "bandSettings"
    private static let appliedKey = "appliedSettings"

    static var pairedBand: PairedBand? {
        get { decode(PairedBand.self, bandKey) }
        set { encode(newValue, bandKey) }
    }

    static var settings: BandSettings {
        get { decode(BandSettings.self, settingsKey) ?? defaultSettings() }
        set { encode(newValue, settingsKey) }
    }

    /// The settings as last successfully sent to the band, so unchanged ones are not re-sent on
    /// every connection.
    static var appliedSettings: BandSettings? {
        get { decode(BandSettings.self, appliedKey) }
        set { encode(newValue, appliedKey) }
    }

    /// Sensible starting values taken from how the phone itself is set up.
    static func defaultSettings() -> BandSettings {
        let locale = Locale.current
        let hourFormat = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: locale) ?? ""
        let dateFormat = DateFormatter.dateFormat(fromTemplate: "yMd", options: 0, locale: locale) ?? ""
        let order: BandSettings.DateOrder
        if dateFormat.hasPrefix("y") {
            order = .yearFirst
        } else if dateFormat.hasPrefix("M") {
            order = .monthFirst
        } else {
            order = .dayFirst
        }
        let language = locale.language.languageCode?.identifier ?? "en"
        let region = locale.region?.identifier ?? "GB"
        return BandSettings(
            use24HourClock: !hourFormat.contains("a"),
            dateOrder: order,
            useMetricUnits: locale.measurementSystem != .us,
            languageTag: "\(language)-\(region)")
    }

    private static func decode<Value: Decodable>(_ type: Value.Type, _ key: String) -> Value? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func encode<Value: Encodable>(_ value: Value?, _ key: String) {
        if let value, let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
