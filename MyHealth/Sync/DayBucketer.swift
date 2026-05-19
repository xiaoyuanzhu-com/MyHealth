import Foundation

/// Decides which day-directory a sample belongs to. Days are local to the
/// sample's own `HKTimeZone` metadata when available; otherwise we fall back
/// to the device's current timezone. The same key is also used to build the
/// `YYYY/MM/DD` path under `apple-health/`.
enum DayBucketer {

    struct DayKey: Hashable, Codable {
        let date: String       // "YYYY-MM-DD"
        let timezone: String   // IANA identifier

        /// "2026/01/18"
        var pathPrefix: String {
            let parts = date.split(separator: "-")
            guard parts.count == 3 else { return date }
            return "\(parts[0])/\(parts[1])/\(parts[2])"
        }
    }

    static func dayKey(start: Date, timezone: TimeZone?) -> DayKey {
        let tz = timezone ?? TimeZone.current
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let comps = cal.dateComponents([.year, .month, .day], from: start)
        let dateString = String(format: "%04d-%02d-%02d",
                                comps.year ?? 1970,
                                comps.month ?? 1,
                                comps.day ?? 1)
        return DayKey(date: dateString, timezone: tz.identifier)
    }
}
