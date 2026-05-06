import Foundation

/// One row in a JSONL batch file. Field names match `myhealth.apple_health.v1`
/// (the schema the prior Python CLI produced from `export.xml`) so downstream
/// consumers see the same keys regardless of ingestion source.
///
/// HealthKit-native extras (`uuid`, `metadata`, workout/route fields, ECG samples)
/// are added as optional fields — they are absent when not applicable.
struct HealthSample: Codable, Equatable {
    enum Kind: String, Codable {
        case record = "Record"
        case workout = "Workout"
        case activitySummary = "ActivitySummary"
        case clinical = "Clinical"
        case ecg = "ECG"
    }

    // ─── v1 keys (always present where applicable) ───
    let _kind: Kind
    let type: String                  // e.g. "HKQuantityTypeIdentifierStepCount"
    let unit: String?                 // e.g. "count", "kcal", "bpm"
    let value: String?                // stringified to match XML-export behaviour
    let start_date: String            // "yyyy-MM-dd HH:mm:ss xxxx"
    let end_date: String
    let creation_date: String?
    let source_name: String?
    let source_version: String?
    let device: String?

    // ─── HealthKit-native extras ───
    let uuid: String?
    let metadata: [String: AnyCodableValue]?

    // Workout-only
    let workout_activity_type: String?
    let duration: Double?
    let total_energy_burned: Double?
    let total_distance: Double?
    let events: [WorkoutEvent]?
    let route_locations: [RouteLocation]?

    // ECG-only
    let ecg_samples: [ECGVoltageSample]?
    let ecg_classification: String?
    let ecg_average_heart_rate: Double?
    let ecg_sampling_frequency: Double?

    // ActivitySummary-only
    let date_components: String?

    init(
        _kind: Kind,
        type: String,
        unit: String? = nil,
        value: String? = nil,
        start_date: String,
        end_date: String,
        creation_date: String? = nil,
        source_name: String? = nil,
        source_version: String? = nil,
        device: String? = nil,
        uuid: String? = nil,
        metadata: [String: AnyCodableValue]? = nil,
        workout_activity_type: String? = nil,
        duration: Double? = nil,
        total_energy_burned: Double? = nil,
        total_distance: Double? = nil,
        events: [WorkoutEvent]? = nil,
        route_locations: [RouteLocation]? = nil,
        ecg_samples: [ECGVoltageSample]? = nil,
        ecg_classification: String? = nil,
        ecg_average_heart_rate: Double? = nil,
        ecg_sampling_frequency: Double? = nil,
        date_components: String? = nil
    ) {
        self._kind = _kind
        self.type = type
        self.unit = unit
        self.value = value
        self.start_date = start_date
        self.end_date = end_date
        self.creation_date = creation_date
        self.source_name = source_name
        self.source_version = source_version
        self.device = device
        self.uuid = uuid
        self.metadata = metadata
        self.workout_activity_type = workout_activity_type
        self.duration = duration
        self.total_energy_burned = total_energy_burned
        self.total_distance = total_distance
        self.events = events
        self.route_locations = route_locations
        self.ecg_samples = ecg_samples
        self.ecg_classification = ecg_classification
        self.ecg_average_heart_rate = ecg_average_heart_rate
        self.ecg_sampling_frequency = ecg_sampling_frequency
        self.date_components = date_components
    }
}

struct WorkoutEvent: Codable, Equatable {
    let type: String
    let date: String
    let duration: Double?
    let metadata: [String: AnyCodableValue]?
}

struct RouteLocation: Codable, Equatable {
    let lat: Double
    let lon: Double
    let alt: Double
    let ts: String
    let h_accuracy: Double
    let v_accuracy: Double
    let speed: Double
    let course: Double
}

struct ECGVoltageSample: Codable, Equatable {
    let t: Double      // seconds offset from ECG start
    let v: Double      // volts
}

/// Minimal JSON-like wrapper for HealthKit `metadata` values, which can be
/// strings, numbers, booleans, dates, or HKQuantity. We render them as
/// the most natural JSON primitive.
enum AnyCodableValue: Codable, Equatable {
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
