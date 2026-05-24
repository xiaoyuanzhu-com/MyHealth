import Foundation
import HealthKit

/// One row of preview text shown on a category's detail page. Holds the
/// underlying `HKSample` so `primaryText`/`secondaryText` can be re-rendered
/// in the current app language whenever the view is re-evaluated (e.g.
/// after a language switch). The pretty-printed JSON is cached at load time
/// since its content is language-agnostic.
struct SamplePreviewRow: Identifiable, Hashable {
    let sample: HKSample
    let json: String

    var id: UUID { sample.uuid }
    var startDate: Date { sample.startDate }
    var endDate: Date { sample.endDate }
    var primaryText: String { SamplePreviewFormatter.primary(for: sample) }
    var secondaryText: String? { SamplePreviewFormatter.secondary(for: sample) }

    static func == (lhs: SamplePreviewRow, rhs: SamplePreviewRow) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Loads recent HealthKit samples for a single type, page by page, newest
/// first. Used by `DataTypeDetailView` for an infinite-scroll list.
@MainActor
final class HealthSamplePreviewLoader: ObservableObject {

    @Published private(set) var rows: [SamplePreviewRow] = []
    @Published private(set) var isLoading = false
    @Published private(set) var hasMore = true
    @Published var errorMessage: String?

    private let entry: HealthTypeEntry
    private let store: HKHealthStore
    private var cursor: Date?  // newer-than this date is already loaded

    init(entry: HealthTypeEntry, store: HKHealthStore = HKHealthStore()) {
        self.entry = entry
        self.store = store
    }

    /// Whether this entry supports a sample-based preview at all.
    var canPreview: Bool {
        entry.objectType is HKSampleType
    }

    func loadNextPage(limit: Int = 50) async {
        guard !isLoading, hasMore else { return }
        guard let sampleType = entry.objectType as? HKSampleType else {
            hasMore = false
            return
        }
        isLoading = true
        defer { isLoading = false }

        do {
            let predicate: NSPredicate? = cursor.map {
                HKQuery.predicateForSamples(withStart: nil, end: $0, options: .strictEndDate)
            }
            let samples = try await fetchPage(type: sampleType, predicate: predicate, limit: limit)
            if samples.isEmpty {
                hasMore = false
                return
            }
            let newRows = samples.map { sample in
                SamplePreviewRow(sample: sample, json: SamplePreviewFormatter.encodedJSON(for: sample))
            }
            rows.append(contentsOf: newRows)
            cursor = samples.last?.startDate
            if samples.count < limit { hasMore = false }
        } catch {
            errorMessage = error.localizedDescription
            hasMore = false
        }
    }

    private func fetchPage(
        type: HKSampleType,
        predicate: NSPredicate?,
        limit: Int
    ) async throws -> [HKSample] {
        try await withCheckedThrowingContinuation { cont in
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
            let q = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: limit,
                sortDescriptors: [sort]
            ) { _, samples, error in
                if let error { cont.resume(throwing: error); return }
                cont.resume(returning: samples ?? [])
            }
            store.execute(q)
        }
    }
}

/// Builds the user-facing strings for a `SamplePreviewRow`. Every word the
/// user sees flows through `String(localized:)` so changing the in-app
/// language refreshes the display when the row's view is re-rendered.
enum SamplePreviewFormatter {

    // MARK: - Display

    static func primary(for sample: HKSample) -> String {
        if let q = sample as? HKQuantitySample {
            let unit = SampleEncoder.canonicalUnit(for: q.quantityType)
            if q.quantity.is(compatibleWith: unit) {
                let value = q.quantity.doubleValue(for: unit)
                let label = unitLabel(unit, raw: unit.unitString)
                return label.isEmpty ? formatNumber(value) : "\(formatNumber(value)) \(label)"
            }
            return q.quantity.description
        }
        if let c = sample as? HKCategorySample {
            return categoryDescription(for: c)
        }
        if let w = sample as? HKWorkout {
            let mins = Int(w.duration / 60)
            var parts = ["\(mins) \(String(localized: "min"))"]
            if let kcal = w.totalEnergyBurned?.doubleValue(for: .kilocalorie()) {
                parts.append("\(Int(kcal.rounded())) \(String(localized: "kcal"))")
            }
            return parts.joined(separator: " · ")
        }
        if let e = sample as? HKElectrocardiogram {
            if let avg = e.averageHeartRate?.doubleValue(for: HKUnit.count().unitDivided(by: .minute())) {
                return String(localized: "Avg \(Int(avg.rounded())) bpm")
            }
            return String(localized: "ECG")
        }
        return "—"
    }

    static func secondary(for sample: HKSample) -> String? {
        if let w = sample as? HKWorkout {
            return workoutActivityName(w.workoutActivityType)
        }
        if let e = sample as? HKElectrocardiogram {
            return ecgClassification(e.classification)
        }
        if sample is HKQuantitySample || sample is HKCategorySample {
            return sample.sourceRevision.source.name
        }
        return sample.sampleType.identifier
    }

    // MARK: - JSON

    /// Pretty-prints the sample using the same DTO encoders the sync pipeline
    /// uses. Returns "" for types we don't yet encode (ECG, workout routes,
    /// audiograms) so the UI can show an "unavailable" placeholder.
    static func encodedJSON(for sample: HKSample) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            if let q = sample as? HKQuantitySample {
                guard let dto = SampleEncoder.encode(q) else { return "" }
                return String(data: try encoder.encode(dto), encoding: .utf8) ?? ""
            }
            if let c = sample as? HKCategorySample {
                let dto = SampleEncoder.encode(c)
                return String(data: try encoder.encode(dto), encoding: .utf8) ?? ""
            }
            if let w = sample as? HKWorkout {
                let deviceInfo = WorkoutFile.DeviceInfo(
                    name: w.device?.name ?? "",
                    model: w.device?.model ?? "",
                    systemVersion: w.device?.softwareVersion ?? ""
                )
                let dto = SampleEncoder.encode(w, events: nil, route: nil, deviceInfo: deviceInfo)
                return String(data: try encoder.encode(dto), encoding: .utf8) ?? ""
            }
            return ""
        } catch {
            return "{ \"error\": \"\(error.localizedDescription)\" }"
        }
    }

    // MARK: - Helpers

    private static func formatNumber(_ v: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = (v.rounded() == v) ? 0 : 2
        return f.string(from: NSNumber(value: v)) ?? String(v)
    }

    /// Unit suffix shown after a quantity sample's value. Symbol-only units
    /// (kg, %, °C, ...) stay verbatim since they're universal; word-based
    /// abbreviations (bpm, min, kcal) get localized so non-English readers
    /// can swap them out.
    private static func unitLabel(_ unit: HKUnit, raw: String) -> String {
        switch raw {
        case "count": return ""
        case "count/min": return String(localized: "bpm")
        case "kcal": return String(localized: "kcal")
        case "min": return String(localized: "min")
        case "m": return "m"
        case "kg": return "kg"
        case "%": return "%"
        case "degC": return "°C"
        case "mmHg": return "mmHg"
        case "ms": return "ms"
        default: return raw
        }
    }

    private static func categoryDescription(for sample: HKCategorySample) -> String {
        let id = sample.categoryType.identifier
        let value = sample.value
        if id == HKCategoryTypeIdentifier.sleepAnalysis.rawValue {
            switch value {
            case HKCategoryValueSleepAnalysis.inBed.rawValue:
                return String(localized: "In Bed")
            case HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue:
                return String(localized: "Asleep")
            case HKCategoryValueSleepAnalysis.awake.rawValue:
                return String(localized: "Awake")
            case HKCategoryValueSleepAnalysis.asleepCore.rawValue:
                return String(localized: "Core Sleep")
            case HKCategoryValueSleepAnalysis.asleepDeep.rawValue:
                return String(localized: "Deep Sleep")
            case HKCategoryValueSleepAnalysis.asleepREM.rawValue:
                return String(localized: "REM Sleep")
            default:
                return String(localized: "Sleep (\(value))")
            }
        }
        if id == HKCategoryTypeIdentifier.appleStandHour.rawValue {
            return value == HKCategoryValueAppleStandHour.stood.rawValue
                ? String(localized: "Stood")
                : String(localized: "Idle")
        }
        if id == HKCategoryTypeIdentifier.mindfulSession.rawValue {
            let mins = Int(sample.endDate.timeIntervalSince(sample.startDate) / 60)
            return String(localized: "\(mins) min mindful session")
        }
        // Symptom-style category samples: severity scale 0..3
        switch value {
        case 0: return String(localized: "Not present")
        case 1: return String(localized: "Mild")
        case 2: return String(localized: "Moderate")
        case 3: return String(localized: "Severe")
        default: return String(localized: "Value \(value)")
        }
    }

    private static func workoutActivityName(_ t: HKWorkoutActivityType) -> String {
        switch t {
        case .walking: return String(localized: "Walking")
        case .running: return String(localized: "Running")
        case .cycling: return String(localized: "Cycling")
        case .swimming: return String(localized: "Swimming")
        case .hiking: return String(localized: "Hiking")
        case .yoga: return String(localized: "Yoga")
        case .functionalStrengthTraining: return String(localized: "Functional Strength")
        case .traditionalStrengthTraining: return String(localized: "Strength Training")
        case .crossTraining: return String(localized: "Cross Training")
        case .elliptical: return String(localized: "Elliptical")
        case .rowing: return String(localized: "Rowing")
        case .stairClimbing: return String(localized: "Stair Climbing")
        case .highIntensityIntervalTraining: return String(localized: "HIIT")
        case .dance: return String(localized: "Dance")
        case .pilates: return String(localized: "Pilates")
        case .other: return String(localized: "Other")
        default: return String(localized: "Workout")
        }
    }

    private static func ecgClassification(_ c: HKElectrocardiogram.Classification) -> String {
        switch c {
        case .sinusRhythm: return String(localized: "Sinus rhythm")
        case .atrialFibrillation: return String(localized: "Atrial fibrillation")
        case .inconclusiveLowHeartRate: return String(localized: "Inconclusive — low HR")
        case .inconclusiveHighHeartRate: return String(localized: "Inconclusive — high HR")
        case .inconclusivePoorReading: return String(localized: "Inconclusive — poor reading")
        case .inconclusiveOther: return String(localized: "Inconclusive")
        case .unrecognized: return String(localized: "Unrecognized")
        case .notSet: return String(localized: "Not classified")
        @unknown default: return String(localized: "Unknown")
        }
    }
}
