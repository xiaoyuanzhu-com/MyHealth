import Foundation

/// Top-level envelope for a per-day file in the new layout.
/// Quantity files have `unit`; category files omit it. The two are encoded as
/// the same outer shape with `unit` being optional.
struct DayFile<Sample: Codable & Equatable>: Codable, Equatable {
    let date: String       // "YYYY-MM-DD"
    let type: String       // full HKQuantity/HKCategory identifier
    let timezone: String   // IANA tz used to define the day boundary
    let unit: String?      // nil for category types
    let samples: [Sample]
}

extension DayFile where Sample == QuantitySample {
    static func quantity(date: String, type: String, timezone: String,
                         unit: String, samples: [QuantitySample]) -> DayFile<QuantitySample> {
        DayFile(date: date, type: type, timezone: timezone, unit: unit, samples: samples)
    }
}

extension DayFile where Sample == CategorySample {
    static func category(date: String, type: String, timezone: String,
                         samples: [CategorySample]) -> DayFile<CategorySample> {
        DayFile(date: date, type: type, timezone: timezone, unit: nil, samples: samples)
    }
}

/// A single quantity-type sample in the new format. `value` is numeric.
struct QuantitySample: Codable, Equatable, Identifiable {
    let start: String          // ISO 8601 UTC with fractional seconds
    let end: String
    let value: Double
    let unit: String
    let type: String
    let source: String
    let device: String?
    let metadata: [String: MetaValue]?
    /// HealthKit UUID — used to dedup during snapshot merge. NOT encoded into
    /// the JSON output (the spec doesn't include it on individual samples).
    /// Marked optional so test fixtures can omit it.
    let uuid: String?

    /// Stable identifier for snapshot-merge dedup. Prefers the HealthKit UUID;
    /// falls back to (start|end|source) only for test fixtures or decoded
    /// samples (where uuid is intentionally absent from JSON). The fallback is
    /// NOT collision-resistant — production code paths must construct samples
    /// with `uuid` populated.
    var id: String { uuid ?? "\(start)|\(end)|\(source)" }

    init(start: String, end: String, value: Double, unit: String, type: String,
         source: String, device: String?, metadata: [String: MetaValue]?,
         uuid: String? = nil) {
        self.start = start; self.end = end; self.value = value; self.unit = unit
        self.type = type; self.source = source; self.device = device
        self.metadata = metadata; self.uuid = uuid
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        start    = try c.decode(String.self, forKey: .start)
        end      = try c.decode(String.self, forKey: .end)
        value    = try c.decode(Double.self, forKey: .value)
        unit     = try c.decode(String.self, forKey: .unit)
        type     = try c.decode(String.self, forKey: .type)
        source   = try c.decode(String.self, forKey: .source)
        device   = try c.decodeIfPresent(String.self, forKey: .device)
        metadata = try c.decodeIfPresent([String: MetaValue].self, forKey: .metadata)
        uuid     = nil   // not present in the JSON wire format
    }

    enum CodingKeys: String, CodingKey {
        case start, end, value, unit, type, source, device, metadata
    }
}

/// A single category-type sample in the new format. `value` is a string enum.
struct CategorySample: Codable, Equatable, Identifiable {
    let start: String
    let end: String
    let value: String
    let type: String
    let source: String
    let device: String?
    let metadata: [String: MetaValue]?
    let uuid: String?

    /// Stable identifier for snapshot-merge dedup. Prefers the HealthKit UUID;
    /// falls back to (start|end|source) only for test fixtures or decoded
    /// samples (where uuid is intentionally absent from JSON). The fallback is
    /// NOT collision-resistant — production code paths must construct samples
    /// with `uuid` populated.
    var id: String { uuid ?? "\(start)|\(end)|\(source)" }

    init(start: String, end: String, value: String, type: String,
         source: String, device: String?, metadata: [String: MetaValue]?,
         uuid: String? = nil) {
        self.start = start; self.end = end; self.value = value
        self.type = type; self.source = source; self.device = device
        self.metadata = metadata; self.uuid = uuid
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        start    = try c.decode(String.self, forKey: .start)
        end      = try c.decode(String.self, forKey: .end)
        value    = try c.decode(String.self, forKey: .value)
        type     = try c.decode(String.self, forKey: .type)
        source   = try c.decode(String.self, forKey: .source)
        device   = try c.decodeIfPresent(String.self, forKey: .device)
        metadata = try c.decodeIfPresent([String: MetaValue].self, forKey: .metadata)
        uuid     = nil   // not present in the JSON wire format
    }

    enum CodingKeys: String, CodingKey {
        case start, end, value, type, source, device, metadata
    }
}

/// One workout event — one file per workout, named `workout-<UUID>.json`.
struct WorkoutFile: Codable, Equatable {
    let uuid: String
    let activity_type: String        // human-readable name: "running", "yoga", "badminton"
    let start: String
    let end: String
    let duration_s: Double
    let source: String
    let device: String?
    let synced_at: String            // when this file was generated (ISO 8601 UTC)
    let device_info: DeviceInfo
    let stats: [String: Stat]        // {"distance": {value, unit}, "energy": {value, unit}}
    let metadata: [String: MetaValue]?
    let route: [RoutePoint]?         // nil → encoded as explicit JSON null (indoor); array → encoded normally

    struct DeviceInfo: Codable, Equatable {
        let name: String
        let model: String
        let systemVersion: String
    }

    struct Stat: Codable, Equatable {
        let value: Double
        let unit: String
        init(value: Double, unit: String) { self.value = value; self.unit = unit }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(uuid, forKey: .uuid)
        try c.encode(activity_type, forKey: .activity_type)
        try c.encode(start, forKey: .start)
        try c.encode(end, forKey: .end)
        try c.encode(duration_s, forKey: .duration_s)
        try c.encode(source, forKey: .source)
        try c.encodeIfPresent(device, forKey: .device)
        try c.encode(synced_at, forKey: .synced_at)
        try c.encode(device_info, forKey: .device_info)
        try c.encode(stats, forKey: .stats)
        try c.encodeIfPresent(metadata, forKey: .metadata)
        // For `route`: encode explicit null when nil, per spec.
        if let route { try c.encode(route, forKey: .route) }
        else { try c.encodeNil(forKey: .route) }
    }

    enum CodingKeys: String, CodingKey {
        case uuid, activity_type, start, end, duration_s, source, device
        case synced_at, device_info, stats, metadata, route
    }
}

struct RoutePoint: Codable, Equatable {
    let t: String              // ISO 8601 UTC
    let lat: Double
    let lon: Double
    let alt: Double
    let h_acc: Double
    let v_acc: Double
    let speed: Double
    let speed_acc: Double
    let course: Double
    let course_acc: Double
}

/// Reusable JSON-primitive wrapper for HealthKit metadata values. Uses the
/// temporary name `MetaValue` to avoid colliding with the legacy
/// `AnyCodableValue` in `HealthSample.swift`; will be renamed back to
/// `AnyCodableValue` in Task 12 once the legacy file is deleted.
enum MetaValue: Codable, Equatable {
    case string(String)
    case int(Int64)
    case double(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let v = try? c.decode(Bool.self) { self = .bool(v); return }
        if let v = try? c.decode(Int64.self) { self = .int(v); return }
        if let v = try? c.decode(Double.self) { self = .double(v); return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "unsupported metadata value")
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
}
