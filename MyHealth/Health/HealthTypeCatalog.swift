import Foundation
import HealthKit

/// One entry in the Data-tab list — a single HealthKit permission type with
/// the metadata needed to render a row and its detail page.
struct HealthTypeEntry: Identifiable, Hashable {
    let objectType: HKObjectType
    let displayName: String
    let icon: String
    let description: String

    var id: String { objectType.identifier }

    static func == (lhs: HealthTypeEntry, rhs: HealthTypeEntry) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Logical bucket the type belongs to in the Data tab. Order here is the
/// order shown to the user.
enum HealthTypeGroup: String, CaseIterable, Identifiable {
    case activity
    case heart
    case bodyMeasurements
    case sleep
    case mobility
    case respiratory
    case hearing
    case vitals
    case nutrition
    case cycleTracking
    case mindfulness
    case symptoms
    case characteristics
    case clinical
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .activity: return "Activity"
        case .heart: return "Heart"
        case .bodyMeasurements: return "Body Measurements"
        case .sleep: return "Sleep"
        case .mobility: return "Mobility"
        case .respiratory: return "Respiratory"
        case .hearing: return "Hearing"
        case .vitals: return "Vitals"
        case .nutrition: return "Nutrition"
        case .cycleTracking: return "Cycle Tracking"
        case .mindfulness: return "Mindfulness"
        case .symptoms: return "Symptoms"
        case .characteristics: return "Characteristics"
        case .clinical: return "Clinical Records"
        case .other: return "Other"
        }
    }
}

/// Source of truth for the Data tab's type list. Wraps the identifier arrays
/// in `DataTypes.swift` and adds display metadata.
enum HealthTypeCatalog {

    /// Ordered list of (group, entries). Empty groups are filtered out.
    static let groups: [(group: HealthTypeGroup, entries: [HealthTypeEntry])] = {
        var raw: [(HealthTypeGroup, [HealthTypeEntry])] = []
        for group in HealthTypeGroup.allCases {
            let entries = entriesByGroup[group] ?? []
            if !entries.isEmpty { raw.append((group, entries)) }
        }
        return raw
    }()

    /// All entries in flat order (groups concatenated).
    static let all: [HealthTypeEntry] = groups.flatMap { $0.entries }

    /// Lookup an entry by HealthKit identifier.
    static func entry(for identifier: String) -> HealthTypeEntry? {
        all.first { $0.id == identifier }
    }

    // MARK: - Building the catalog

    private static let entriesByGroup: [HealthTypeGroup: [HealthTypeEntry]] = build()

    private static func build() -> [HealthTypeGroup: [HealthTypeEntry]] {
        var out: [HealthTypeGroup: [HealthTypeEntry]] = [:]
        for (id, group) in groupAssignments {
            guard let type = objectType(for: id) else { continue }
            let entry = HealthTypeEntry(
                objectType: type,
                displayName: nameOverrides[id] ?? autoName(from: id),
                icon: iconOverrides[id] ?? defaultIcon(for: group),
                description: descriptionOverrides[id] ?? defaultDescription(for: group)
            )
            out[group, default: []].append(entry)
        }
        // Sort each group alphabetically by display name for stable output.
        for k in out.keys {
            out[k]?.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        }
        return out
    }

    private static func objectType(for identifier: String) -> HKObjectType? {
        if let q = HKQuantityType.quantityType(forIdentifier: HKQuantityTypeIdentifier(rawValue: identifier)) {
            return q
        }
        if let c = HKCategoryType.categoryType(forIdentifier: HKCategoryTypeIdentifier(rawValue: identifier)) {
            return c
        }
        if let ch = HKCharacteristicType.characteristicType(forIdentifier: HKCharacteristicTypeIdentifier(rawValue: identifier)) {
            return ch
        }
        if let cl = HKClinicalType.clinicalType(forIdentifier: HKClinicalTypeIdentifier(rawValue: identifier)) {
            return cl
        }
        if identifier == HKObjectType.workoutType().identifier {
            return HKObjectType.workoutType()
        }
        if identifier == HKSeriesType.workoutRoute().identifier {
            return HKSeriesType.workoutRoute()
        }
        if identifier == HKObjectType.electrocardiogramType().identifier {
            return HKObjectType.electrocardiogramType()
        }
        if identifier == HKObjectType.audiogramSampleType().identifier {
            return HKObjectType.audiogramSampleType()
        }
        return nil
    }

    /// Strip HK prefix and split camel case. e.g.
    /// "HKQuantityTypeIdentifierStepCount" -> "Step Count".
    private static func autoName(from identifier: String) -> String {
        var s = identifier
        for prefix in [
            "HKQuantityTypeIdentifier",
            "HKCategoryTypeIdentifier",
            "HKCharacteristicTypeIdentifier",
            "HKClinicalTypeIdentifier",
            "HKDataTypeIdentifier",
        ] {
            if s.hasPrefix(prefix) { s.removeFirst(prefix.count); break }
        }
        // Insert a space before each uppercase letter that follows a lowercase one.
        var out = ""
        var prev: Character = " "
        for ch in s {
            if ch.isUppercase, prev.isLowercase || prev.isNumber {
                out.append(" ")
            }
            out.append(ch)
            prev = ch
        }
        return out.isEmpty ? identifier : out
    }

    private static func defaultIcon(for group: HealthTypeGroup) -> String {
        switch group {
        case .activity: return "figure.walk"
        case .heart: return "heart.fill"
        case .bodyMeasurements: return "figure.arms.open"
        case .sleep: return "bed.double.fill"
        case .mobility: return "figure.walk.motion"
        case .respiratory: return "lungs.fill"
        case .hearing: return "ear.fill"
        case .vitals: return "waveform.path.ecg"
        case .nutrition: return "fork.knife"
        case .cycleTracking: return "calendar"
        case .mindfulness: return "brain.head.profile"
        case .symptoms: return "thermometer"
        case .characteristics: return "person.fill"
        case .clinical: return "cross.case.fill"
        case .other: return "heart.text.square"
        }
    }

    private static func defaultDescription(for group: HealthTypeGroup) -> String {
        switch group {
        case .activity: return "Activity and energy data recorded by Apple Health."
        case .heart: return "Heart-related measurements recorded by Apple Health."
        case .bodyMeasurements: return "Body measurement recorded by Apple Health."
        case .sleep: return "Sleep data recorded by Apple Health."
        case .mobility: return "Walking and mobility data recorded by Apple Health."
        case .respiratory: return "Respiratory measurement recorded by Apple Health."
        case .hearing: return "Audio and hearing data recorded by Apple Health."
        case .vitals: return "Vital sign recorded by Apple Health."
        case .nutrition: return "Dietary intake recorded by Apple Health."
        case .cycleTracking: return "Cycle tracking data recorded by Apple Health."
        case .mindfulness: return "Mindfulness session recorded by Apple Health."
        case .symptoms: return "Symptom logged in Apple Health."
        case .characteristics: return "Profile attribute stored in Apple Health."
        case .clinical: return "Clinical health record imported into Apple Health."
        case .other: return "Data recorded by Apple Health."
        }
    }

    // MARK: - Per-identifier overrides

    private static let nameOverrides: [String: String] = [
        HKObjectType.workoutType().identifier: "Workouts",
        HKSeriesType.workoutRoute().identifier: "Workout Routes",
        HKObjectType.electrocardiogramType().identifier: "ECG",
        HKObjectType.audiogramSampleType().identifier: "Audiogram",
        HKQuantityTypeIdentifier.bodyMassIndex.rawValue: "Body Mass Index",
        HKQuantityTypeIdentifier.vo2Max.rawValue: "VO\u{2082} Max",
        HKQuantityTypeIdentifier.heartRateVariabilitySDNN.rawValue: "Heart Rate Variability",
        HKQuantityTypeIdentifier.forcedExpiratoryVolume1.rawValue: "Forced Expiratory Volume (1s)",
        HKQuantityTypeIdentifier.uvExposure.rawValue: "UV Exposure",
    ]

    private static let iconOverrides: [String: String] = [
        HKObjectType.workoutType().identifier: "figure.run",
        HKSeriesType.workoutRoute().identifier: "map.fill",
        HKObjectType.electrocardiogramType().identifier: "waveform.path.ecg",
        HKObjectType.audiogramSampleType().identifier: "ear.and.waveform",
        HKQuantityTypeIdentifier.stepCount.rawValue: "figure.walk",
        HKQuantityTypeIdentifier.flightsClimbed.rawValue: "figure.stairs",
        HKQuantityTypeIdentifier.distanceCycling.rawValue: "bicycle",
        HKQuantityTypeIdentifier.distanceSwimming.rawValue: "figure.pool.swim",
        HKQuantityTypeIdentifier.heartRate.rawValue: "heart.fill",
        HKQuantityTypeIdentifier.restingHeartRate.rawValue: "heart.text.square.fill",
        HKQuantityTypeIdentifier.bodyMass.rawValue: "scalemass.fill",
        HKQuantityTypeIdentifier.height.rawValue: "ruler.fill",
        HKQuantityTypeIdentifier.bloodPressureSystolic.rawValue: "drop.fill",
        HKQuantityTypeIdentifier.bloodPressureDiastolic.rawValue: "drop.fill",
        HKQuantityTypeIdentifier.bloodGlucose.rawValue: "drop.fill",
        HKQuantityTypeIdentifier.oxygenSaturation.rawValue: "drop.degreesign.fill",
        HKQuantityTypeIdentifier.bodyTemperature.rawValue: "thermometer.medium",
        HKCategoryTypeIdentifier.sleepAnalysis.rawValue: "bed.double.fill",
        HKCategoryTypeIdentifier.mindfulSession.rawValue: "brain.head.profile",
        HKCategoryTypeIdentifier.appleStandHour.rawValue: "figure.stand",
        HKCategoryTypeIdentifier.toothbrushingEvent.rawValue: "mouth.fill",
        HKCategoryTypeIdentifier.handwashingEvent.rawValue: "hands.sparkles.fill",
    ]

    private static let descriptionOverrides: [String: String] = [
        HKQuantityTypeIdentifier.stepCount.rawValue:
            "Steps taken, recorded by Apple Watch or iPhone.",
        HKQuantityTypeIdentifier.heartRate.rawValue:
            "Instantaneous heart rate readings in beats per minute.",
        HKQuantityTypeIdentifier.heartRateVariabilitySDNN.rawValue:
            "SDNN measurement of heart rate variability, in milliseconds.",
        HKQuantityTypeIdentifier.activeEnergyBurned.rawValue:
            "Energy burned by movement, in kilocalories.",
        HKQuantityTypeIdentifier.basalEnergyBurned.rawValue:
            "Resting metabolic energy expenditure, in kilocalories.",
        HKQuantityTypeIdentifier.appleExerciseTime.rawValue:
            "Minutes counted toward your Exercise ring.",
        HKQuantityTypeIdentifier.appleStandTime.rawValue:
            "Minutes spent standing, counted toward your Stand ring.",
        HKQuantityTypeIdentifier.bodyMass.rawValue:
            "Weight measurements, in kilograms.",
        HKQuantityTypeIdentifier.height.rawValue:
            "Height measurements, in meters.",
        HKQuantityTypeIdentifier.vo2Max.rawValue:
            "Cardio fitness — maximum oxygen consumption during exercise.",
        HKObjectType.workoutType().identifier:
            "Recorded workout sessions including duration, energy, and (when available) GPS route.",
        HKObjectType.electrocardiogramType().identifier:
            "Single-lead ECG recordings from Apple Watch.",
        HKCategoryTypeIdentifier.sleepAnalysis.rawValue:
            "Sleep stages and durations recorded automatically or entered manually.",
        HKCategoryTypeIdentifier.mindfulSession.rawValue:
            "Logged mindfulness or breathing sessions.",
    ]

    // MARK: - Group assignments

    /// Maps every identifier we want to surface to a group. The order within
    /// the array doesn't matter — entries are sorted by display name.
    private static let groupAssignments: [(String, HealthTypeGroup)] = activityIDs
        + heartIDs + bodyIDs + sleepIDs + mobilityIDs + respiratoryIDs
        + hearingIDs + vitalsIDs + nutritionIDs + cycleIDs + mindfulnessIDs
        + symptomIDs + characteristicIDs + clinicalIDs + otherIDs

    private static let activityIDs: [(String, HealthTypeGroup)] = [
        HKQuantityTypeIdentifier.stepCount,
        .distanceWalkingRunning, .distanceCycling, .distanceSwimming,
        .distanceWheelchair, .distanceDownhillSnowSports, .pushCount,
        .swimmingStrokeCount, .flightsClimbed, .nikeFuel,
        .activeEnergyBurned, .basalEnergyBurned, .appleExerciseTime,
        .appleStandTime, .appleMoveTime, .physicalEffort,
    ].map { ($0.rawValue, .activity) }
        + [(HKObjectType.workoutType().identifier, HealthTypeGroup.activity)]
        + [(HKSeriesType.workoutRoute().identifier, HealthTypeGroup.activity)]
        + [(HKCategoryTypeIdentifier.appleStandHour.rawValue, HealthTypeGroup.activity)]

    private static let heartIDs: [(String, HealthTypeGroup)] = [
        HKQuantityTypeIdentifier.heartRate,
        .restingHeartRate, .walkingHeartRateAverage,
        .heartRateVariabilitySDNN, .heartRateRecoveryOneMinute,
        .vo2Max,
    ].map { ($0.rawValue, .heart) }
        + [
            HKCategoryTypeIdentifier.lowHeartRateEvent,
            .highHeartRateEvent, .irregularHeartRhythmEvent,
            .lowCardioFitnessEvent,
        ].map { ($0.rawValue, .heart) }
        + [(HKObjectType.electrocardiogramType().identifier, HealthTypeGroup.heart)]

    private static let bodyIDs: [(String, HealthTypeGroup)] = [
        HKQuantityTypeIdentifier.bodyMass, .bodyMassIndex, .bodyFatPercentage,
        .height, .leanBodyMass, .waistCircumference,
    ].map { ($0.rawValue, .bodyMeasurements) }

    private static let sleepIDs: [(String, HealthTypeGroup)] = [
        HKCategoryTypeIdentifier.sleepAnalysis,
        .sleepChanges,
    ].map { ($0.rawValue, .sleep) }

    private static let mobilityIDs: [(String, HealthTypeGroup)] = [
        HKQuantityTypeIdentifier.walkingSpeed, .walkingStepLength,
        .walkingAsymmetryPercentage, .walkingDoubleSupportPercentage,
        .stairAscentSpeed, .stairDescentSpeed,
        .sixMinuteWalkTestDistance, .appleWalkingSteadiness,
        .runningGroundContactTime, .runningStrideLength,
        .runningVerticalOscillation, .runningPower, .runningSpeed,
        .cyclingCadence, .cyclingFunctionalThresholdPower,
        .cyclingPower, .cyclingSpeed,
    ].map { ($0.rawValue, .mobility) }
        + [(HKCategoryTypeIdentifier.appleWalkingSteadinessEvent.rawValue, HealthTypeGroup.mobility)]

    private static let respiratoryIDs: [(String, HealthTypeGroup)] = [
        HKQuantityTypeIdentifier.respiratoryRate,
        .oxygenSaturation, .forcedExpiratoryVolume1,
        .forcedVitalCapacity, .peakExpiratoryFlowRate,
        .inhalerUsage,
    ].map { ($0.rawValue, .respiratory) }

    private static let hearingIDs: [(String, HealthTypeGroup)] = [
        HKQuantityTypeIdentifier.environmentalAudioExposure,
        .environmentalSoundReduction,
        .headphoneAudioExposure,
    ].map { ($0.rawValue, .hearing) }
        + [
            HKCategoryTypeIdentifier.audioExposureEvent,
            .environmentalAudioExposureEvent,
            .headphoneAudioExposureEvent,
        ].map { ($0.rawValue, .hearing) }
        + [(HKObjectType.audiogramSampleType().identifier, HealthTypeGroup.hearing)]

    private static let vitalsIDs: [(String, HealthTypeGroup)] = [
        HKQuantityTypeIdentifier.bodyTemperature,
        .basalBodyTemperature,
        .bloodPressureSystolic, .bloodPressureDiastolic,
        .bloodGlucose, .electrodermalActivity,
        .numberOfTimesFallen, .peripheralPerfusionIndex,
        .uvExposure, .underwaterDepth, .waterTemperature,
        .timeInDaylight, .insulinDelivery,
    ].map { ($0.rawValue, .vitals) }

    private static let nutritionIDs: [(String, HealthTypeGroup)] = [
        HKQuantityTypeIdentifier.dietaryEnergyConsumed, .dietaryFatTotal,
        .dietaryFatSaturated, .dietaryFatPolyunsaturated,
        .dietaryFatMonounsaturated, .dietaryCholesterol, .dietarySodium,
        .dietaryCarbohydrates, .dietaryFiber, .dietarySugar,
        .dietaryProtein, .dietaryVitaminA, .dietaryVitaminB6,
        .dietaryVitaminB12, .dietaryVitaminC, .dietaryVitaminD,
        .dietaryVitaminE, .dietaryVitaminK, .dietaryCalcium,
        .dietaryIron, .dietaryThiamin, .dietaryRiboflavin,
        .dietaryNiacin, .dietaryFolate, .dietaryBiotin,
        .dietaryPantothenicAcid, .dietaryPhosphorus, .dietaryIodine,
        .dietaryMagnesium, .dietaryZinc, .dietarySelenium,
        .dietaryCopper, .dietaryManganese, .dietaryChromium,
        .dietaryMolybdenum, .dietaryChloride, .dietaryPotassium,
        .dietaryCaffeine, .dietaryWater,
    ].map { ($0.rawValue, .nutrition) }

    private static let cycleIDs: [(String, HealthTypeGroup)] = [
        HKCategoryTypeIdentifier.cervicalMucusQuality,
        .menstrualFlow, .ovulationTestResult, .sexualActivity,
        .intermenstrualBleeding, .pregnancy, .lactation,
        .contraceptive, .pregnancyTestResult, .progesteroneTestResult,
        .persistentIntermenstrualBleeding,
        .prolongedMenstrualPeriods, .irregularMenstrualCycles,
        .infrequentMenstrualCycles,
    ].map { ($0.rawValue, .cycleTracking) }

    private static let mindfulnessIDs: [(String, HealthTypeGroup)] = [
        HKCategoryTypeIdentifier.mindfulSession,
        .toothbrushingEvent, .handwashingEvent,
    ].map { ($0.rawValue, .mindfulness) }

    private static let symptomIDs: [(String, HealthTypeGroup)] = [
        HKCategoryTypeIdentifier.abdominalCramps, .acne, .appetiteChanges,
        .bladderIncontinence, .bloating, .breastPain,
        .chestTightnessOrPain, .chills, .constipation, .coughing,
        .diarrhea, .dizziness, .drySkin, .fainting,
        .fatigue, .fever, .generalizedBodyAche, .hairLoss,
        .headache, .heartburn, .hotFlashes, .lossOfSmell,
        .lossOfTaste, .lowerBackPain, .memoryLapse, .moodChanges,
        .nausea, .nightSweats, .pelvicPain,
        .rapidPoundingOrFlutteringHeartbeat, .runnyNose,
        .shortnessOfBreath, .sinusCongestion, .skippedHeartbeat,
        .soreThroat, .vaginalDryness, .vomiting, .wheezing,
    ].map { ($0.rawValue, .symptoms) }

    private static let characteristicIDs: [(String, HealthTypeGroup)] = [
        HKCharacteristicTypeIdentifier.biologicalSex, .bloodType,
        .dateOfBirth, .fitzpatrickSkinType, .wheelchairUse,
        .activityMoveMode,
    ].map { ($0.rawValue, .characteristics) }

    private static let clinicalIDs: [(String, HealthTypeGroup)] = [
        HKClinicalTypeIdentifier.allergyRecord, .conditionRecord,
        .immunizationRecord, .labResultRecord, .medicationRecord,
        .procedureRecord, .vitalSignRecord, .coverageRecord,
        .clinicalNoteRecord,
    ].map { ($0.rawValue, .clinical) }

    private static let otherIDs: [(String, HealthTypeGroup)] = []
}
