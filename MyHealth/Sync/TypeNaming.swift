/// Maps a HealthKit type identifier (e.g. `HKQuantityTypeIdentifierStepCount`)
/// to the kebab-case filename used in the new per-day layout (e.g.
/// `step-count.json`). Recognised prefixes are stripped; everything after the
/// last `Identifier` token is camelCase-to-kebab-case converted.
enum TypeNaming {

    /// Filename for a per-day type bucket (e.g. `"step-count.json"`).
    static func filename(for typeIdentifier: String) -> String {
        let stem = kebab(stripPrefix(typeIdentifier))
        return "\(stem).json"
    }

    /// Filename for a single workout event (UUID is preserved verbatim).
    static func workoutFilename(uuid: String) -> String {
        return "workout-\(uuid).json"
    }

    /// Human-readable display name for a HealthKit type identifier — uses the
    /// curated catalog if available, otherwise falls back to a title-cased
    /// version of the kebab filename stem. Used by SyncCoordinator's progress
    /// line.
    static func displayName(for typeIdentifier: String) -> String {
        if let entry = HealthTypeCatalog.entry(for: typeIdentifier) {
            return entry.displayName
        }
        let stem = kebab(stripPrefix(typeIdentifier))
        return stem.split(separator: "-")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    // MARK: - Internals

    private static let knownPrefixes = [
        "HKQuantityTypeIdentifier",
        "HKCategoryTypeIdentifier",
        "HKCorrelationTypeIdentifier",
        "HKClinicalTypeIdentifier",
        "HKDataTypeIdentifier",
    ]

    private static func stripPrefix(_ id: String) -> String {
        for p in knownPrefixes where id.hasPrefix(p) {
            return String(id.dropFirst(p.count))
        }
        return id
    }

    /// CamelCase → kebab-case. Treats runs of uppercase as one token
    /// ("SDNN" → "sdnn", "VO2Max" → "vo2-max").
    private static func kebab(_ s: String) -> String {
        guard !s.isEmpty else { return "" }
        var out = ""
        let chars = Array(s)
        for i in chars.indices {
            let c = chars[i]
            if c.isUppercase {
                // Insert a dash before this uppercase if:
                //  - it's not the very start, AND
                //  - the previous char was lowercase or digit, OR
                //  - the next char is lowercase (start of a new word after an acronym)
                if i > 0 {
                    let prev = chars[i - 1]
                    let nextLower = (i + 1 < chars.count) && chars[i + 1].isLowercase
                    if prev.isLowercase || prev.isNumber || nextLower {
                        out.append("-")
                    }
                }
                out.append(Character(c.lowercased()))
            } else {
                out.append(c)
            }
        }
        return out
    }
}
