import BandKit
import Foundation

/// Keeps recent log lines for the diagnostics screen and for export.
///
/// The log is the main tool for working out what went wrong when the band does something
/// unexpected, so it records the raw traffic. It never contains the link key.
final class AppLog: BandLogger, @unchecked Sendable {
    struct Entry: Identifiable, Equatable {
        let id: Int
        let date: Date
        let level: LogLevel
        let message: String
    }

    static let shared = AppLog()
    private static let limit = 3000

    private let queue = DispatchQueue(label: "dev.bandcompanion.log")
    private var entries = [Entry]()
    private var counter = 0

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    func log(_ level: LogLevel, _ message: String) {
        let date = Date()
        queue.async {
            self.counter += 1
            self.entries.append(Entry(id: self.counter, date: date, level: level, message: message))
            if self.entries.count > AppLog.limit { self.entries.removeFirst(self.entries.count - AppLog.limit) }
        }
    }

    func snapshot() -> [Entry] {
        queue.sync { entries }
    }

    func clear() {
        queue.async { self.entries.removeAll() }
    }

    static func line(_ entry: Entry) -> String {
        "\(stamp.string(from: entry.date)) \(entry.level.rawValue.uppercased()) \(entry.message)"
    }

    /// Writes the log to a temporary text file and returns its location, for the share sheet.
    func exportFile(header: String) throws -> URL {
        let body = snapshot().map(AppLog.line).joined(separator: "\n")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("band-companion-log.txt")
        try (header + "\n\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
