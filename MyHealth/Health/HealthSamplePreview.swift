import Foundation
import HealthKit

/// One row of preview text shown on a category's detail page.
struct SamplePreviewRow: Identifiable, Hashable {
    let id: UUID
    let startDate: Date
    let endDate: Date
    let primaryText: String
    let secondaryText: String?

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
            let newRows = samples.map { format(sample: $0) }
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

    // MARK: - Formatting

    private func format(sample: HKSample) -> SamplePreviewRow {
        let primary: String
        let secondary: String?

        if let q = sample as? HKQuantitySample {
            let unit = SampleEncoder.canonicalUnit(for: q.quantityType)
            let value = q.quantity.doubleValue(for: unit)
            primary = "\(formatNumber(value)) \(unitLabel(unit, raw: unit.unitString))"
            secondary = sample.sourceRevision.source.name
        } else if let c = sample as? HKCategorySample {
            primary = categoryDescription(for: c)
            secondary = sample.sourceRevision.source.name
        } else if let w = sample as? HKWorkout {
            let mins = Int(w.duration / 60)
            let kcal = w.totalEnergyBurned?.doubleValue(for: .kilocalorie())
            var parts = ["\(mins) min"]
            if let kcal { parts.append("\(Int(kcal.rounded())) kcal") }
            primary = parts.joined(separator: " · ")
            secondary = workoutActivityName(w.workoutActivityType)
        } else if let e = sample as? HKElectrocardiogram {
            let avg = e.averageHeartRate?.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
            if let avg {
                primary = "Avg \(Int(avg.rounded())) bpm"
            } else {
                primary = "ECG"
            }
            secondary = ecgClassification(e.classification)
        } else if let cr = sample as? HKClinicalRecord {
            primary = cr.displayName
            secondary = cr.fhirResource?.resourceType.rawValue
        } else {
            primary = "—"
            secondary = sample.sampleType.identifier
        }

        return SamplePreviewRow(
            id: sample.uuid,
            startDate: sample.startDate,
            endDate: sample.endDate,
            primaryText: primary,
            secondaryText: secondary
        )
    }

    private func formatNumber(_ v: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = (v.rounded() == v) ? 0 : 2
        return f.string(from: NSNumber(value: v)) ?? String(v)
    }

    private func unitLabel(_ unit: HKUnit, raw: String) -> String {
        switch raw {
        case "count": return ""
        case "count/min": return "bpm"
        case "kcal": return "kcal"
        case "min": return "min"
        case "m": return "m"
        case "kg": return "kg"
        case "%": return "%"
        case "degC": return "°C"
        case "mmHg": return "mmHg"
        case "ms": return "ms"
        default: return raw
        }
    }

    private func categoryDescription(for sample: HKCategorySample) -> String {
        let id = sample.categoryType.identifier
        let value = sample.value
        if id == HKCategoryTypeIdentifier.sleepAnalysis.rawValue {
            switch value {
            case HKCategoryValueSleepAnalysis.inBed.rawValue: return "In Bed"
            case HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue: return "Asleep"
            case HKCategoryValueSleepAnalysis.awake.rawValue: return "Awake"
            case HKCategoryValueSleepAnalysis.asleepCore.rawValue: return "Core Sleep"
            case HKCategoryValueSleepAnalysis.asleepDeep.rawValue: return "Deep Sleep"
            case HKCategoryValueSleepAnalysis.asleepREM.rawValue: return "REM Sleep"
            default: return "Sleep (\(value))"
            }
        }
        if id == HKCategoryTypeIdentifier.appleStandHour.rawValue {
            return value == HKCategoryValueAppleStandHour.stood.rawValue ? "Stood" : "Idle"
        }
        if id == HKCategoryTypeIdentifier.mindfulSession.rawValue {
            let mins = Int(sample.endDate.timeIntervalSince(sample.startDate) / 60)
            return "\(mins) min mindful session"
        }
        // Symptom-style category samples: severity scale 0..3
        switch value {
        case 0: return "Not present"
        case 1: return "Mild"
        case 2: return "Moderate"
        case 3: return "Severe"
        default: return "Value \(value)"
        }
    }

    private func workoutActivityName(_ t: HKWorkoutActivityType) -> String {
        switch t {
        case .walking: return "Walking"
        case .running: return "Running"
        case .cycling: return "Cycling"
        case .swimming: return "Swimming"
        case .hiking: return "Hiking"
        case .yoga: return "Yoga"
        case .functionalStrengthTraining: return "Functional Strength"
        case .traditionalStrengthTraining: return "Strength Training"
        case .crossTraining: return "Cross Training"
        case .elliptical: return "Elliptical"
        case .rowing: return "Rowing"
        case .stairClimbing: return "Stair Climbing"
        case .highIntensityIntervalTraining: return "HIIT"
        case .dance: return "Dance"
        case .pilates: return "Pilates"
        case .other: return "Other"
        default: return "Workout"
        }
    }

    private func ecgClassification(_ c: HKElectrocardiogram.Classification) -> String {
        switch c {
        case .sinusRhythm: return "Sinus rhythm"
        case .atrialFibrillation: return "Atrial fibrillation"
        case .inconclusiveLowHeartRate: return "Inconclusive — low HR"
        case .inconclusiveHighHeartRate: return "Inconclusive — high HR"
        case .inconclusivePoorReading: return "Inconclusive — poor reading"
        case .inconclusiveOther: return "Inconclusive"
        case .unrecognized: return "Unrecognized"
        case .notSet: return "Not classified"
        @unknown default: return "Unknown"
        }
    }
}
