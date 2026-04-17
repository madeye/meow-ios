import Foundation
import SwiftData

/// Daily aggregate of upload/download bytes. Keyed by `yyyy-MM-dd` so the
/// Android and iOS stores agree on the same dimension.
@Model
final class DailyTraffic {
    @Attribute(.unique) var date: String
    var txBytes: Int64
    var rxBytes: Int64

    init(date: String, txBytes: Int64 = 0, rxBytes: Int64 = 0) {
        self.date = date
        self.txBytes = txBytes
        self.rxBytes = rxBytes
    }

    static func key(for date: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
