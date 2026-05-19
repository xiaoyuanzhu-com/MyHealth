import Foundation
import HealthKit

/// Exhaustive catalog of HealthKit sample types MyHealth tries to read.
///
/// We deliberately request *every* supported read permission in one go so the
/// user only sees Apple's permission sheet once. Unauthorised types simply
/// yield no samples — HealthKit does not surface read denials, by design.
enum HealthDataTypes {
    /// All quantity types known on the current OS, generated lazily so that
    /// types added in newer iOS releases are picked up without code changes.
    static var allQuantityTypes: [HKQuantityType] {
        quantityIdentifiers.compactMap { HKQuantityType.quantityType(forIdentifier: $0) }
    }

    static var allCategoryTypes: [HKCategoryType] {
        categoryIdentifiers.compactMap { HKCategoryType.categoryType(forIdentifier: $0) }
    }

    static var allCorrelationTypes: [HKCorrelationType] {
        correlationIdentifiers.compactMap { HKCorrelationType.correlationType(forIdentifier: $0) }
    }

    static var workoutType: HKWorkoutType { HKObjectType.workoutType() }
    static var workoutRouteType: HKSeriesType { HKSeriesType.workoutRoute() }
    static var ecgType: HKElectrocardiogramType { HKObjectType.electrocardiogramType() }
    static var audiogramType: HKSampleType { HKObjectType.audiogramSampleType() }

    static var characteristicTypes: [HKCharacteristicType] {
        characteristicIdentifiers.compactMap { HKCharacteristicType.characteristicType(forIdentifier: $0) }
    }

    /// Clinical Records — gated behind a separate Apple entitlement
    /// (`health-records`). Apps without it will silently see zero samples.
    static var clinicalTypes: [HKClinicalType] {
        clinicalIdentifiers.compactMap { HKClinicalType.clinicalType(forIdentifier: $0) }
    }

    /// Everything we ask `HKHealthStore.requestAuthorization` to read.
    static var allReadTypes: Set<HKObjectType> {
        var s: Set<HKObjectType> = []
        s.formUnion(allQuantityTypes.map { $0 as HKObjectType })
        s.formUnion(allCategoryTypes.map { $0 as HKObjectType })
        // Correlation types (blood pressure, food) cannot be authorized
        // directly — HealthKit requires auth on their underlying quantities,
        // which are already included above. Querying correlations still works.
        s.formUnion(characteristicTypes.map { $0 as HKObjectType })
        s.formUnion(clinicalTypes.map { $0 as HKObjectType })
        s.insert(workoutType)
        s.insert(workoutRouteType)
        s.insert(ecgType)
        s.insert(audiogramType)
        return s
    }

    /// Sample types the sync coordinator iterates per-day with `HKSampleQuery`,
    /// and that `BackgroundSync` registers for HealthKit background delivery.
    /// Excludes characteristic types, ECG, clinical records, audiograms, and
    /// workout routes — none of these are part of the per-day JSON layout.
    /// (Name is historical: the original implementation used
    /// `HKAnchoredObjectQuery`; this set is still used to subscribe to
    /// HealthKit background-delivery notifications.)
    static var allAnchoredSampleTypes: [HKSampleType] {
        var s: [HKSampleType] = []
        s.append(contentsOf: allQuantityTypes.map { $0 as HKSampleType })
        s.append(contentsOf: allCategoryTypes.map { $0 as HKSampleType })
        s.append(workoutType as HKSampleType)
        return s
    }

    // MARK: - Identifier catalogs

    static let quantityIdentifiers: [HKQuantityTypeIdentifier] = [
        // Body measurements
        .bodyMass, .bodyMassIndex, .bodyFatPercentage, .height,
        .leanBodyMass, .waistCircumference,
        // Activity
        .stepCount, .distanceWalkingRunning, .distanceCycling, .distanceSwimming,
        .distanceWheelchair, .distanceDownhillSnowSports, .pushCount,
        .swimmingStrokeCount, .flightsClimbed, .nikeFuel,
        .activeEnergyBurned, .basalEnergyBurned, .appleExerciseTime,
        .appleStandTime, .appleMoveTime,
        // Vitals
        .heartRate, .restingHeartRate, .walkingHeartRateAverage,
        .heartRateVariabilitySDNN, .heartRateRecoveryOneMinute,
        .oxygenSaturation, .respiratoryRate, .bodyTemperature,
        .basalBodyTemperature, .bloodPressureSystolic, .bloodPressureDiastolic,
        .bloodGlucose, .electrodermalActivity, .forcedExpiratoryVolume1,
        .forcedVitalCapacity, .inhalerUsage, .insulinDelivery,
        .numberOfTimesFallen, .peakExpiratoryFlowRate, .peripheralPerfusionIndex,
        .vo2Max, .uvExposure,
        // Walking/mobility
        .walkingSpeed, .walkingStepLength, .walkingAsymmetryPercentage,
        .walkingDoubleSupportPercentage, .stairAscentSpeed, .stairDescentSpeed,
        .sixMinuteWalkTestDistance, .appleWalkingSteadiness,
        // Running
        .runningGroundContactTime, .runningStrideLength,
        .runningVerticalOscillation, .runningPower, .runningSpeed,
        // Hearing
        .environmentalAudioExposure, .environmentalSoundReduction,
        .headphoneAudioExposure,
        // Cycling
        .cyclingCadence, .cyclingFunctionalThresholdPower, .cyclingPower,
        .cyclingSpeed,
        // Other
        .dietaryEnergyConsumed, .dietaryFatTotal, .dietaryFatSaturated,
        .dietaryFatPolyunsaturated, .dietaryFatMonounsaturated,
        .dietaryCholesterol, .dietarySodium, .dietaryCarbohydrates,
        .dietaryFiber, .dietarySugar, .dietaryProtein,
        .dietaryVitaminA, .dietaryVitaminB6, .dietaryVitaminB12,
        .dietaryVitaminC, .dietaryVitaminD, .dietaryVitaminE,
        .dietaryVitaminK, .dietaryCalcium, .dietaryIron,
        .dietaryThiamin, .dietaryRiboflavin, .dietaryNiacin,
        .dietaryFolate, .dietaryBiotin, .dietaryPantothenicAcid,
        .dietaryPhosphorus, .dietaryIodine, .dietaryMagnesium,
        .dietaryZinc, .dietarySelenium, .dietaryCopper,
        .dietaryManganese, .dietaryChromium, .dietaryMolybdenum,
        .dietaryChloride, .dietaryPotassium, .dietaryCaffeine,
        .dietaryWater, .underwaterDepth, .waterTemperature,
        .timeInDaylight, .physicalEffort,
    ]

    static let categoryIdentifiers: [HKCategoryTypeIdentifier] = [
        .sleepAnalysis, .appleStandHour, .cervicalMucusQuality,
        .menstrualFlow, .ovulationTestResult, .sexualActivity,
        .intermenstrualBleeding, .pregnancy, .lactation,
        .contraceptive, .pregnancyTestResult, .progesteroneTestResult,
        .mindfulSession, .lowHeartRateEvent, .highHeartRateEvent,
        .irregularHeartRhythmEvent, .audioExposureEvent,
        .toothbrushingEvent, .handwashingEvent,
        .abdominalCramps, .acne, .appetiteChanges, .bladderIncontinence,
        .bloating, .breastPain, .chestTightnessOrPain, .chills,
        .constipation, .coughing, .diarrhea, .dizziness,
        .drySkin, .fainting, .fatigue, .fever,
        .generalizedBodyAche, .hairLoss, .headache, .heartburn,
        .hotFlashes, .lossOfSmell, .lossOfTaste, .lowerBackPain,
        .memoryLapse, .moodChanges, .nausea, .nightSweats,
        .pelvicPain, .rapidPoundingOrFlutteringHeartbeat, .runnyNose,
        .shortnessOfBreath, .sinusCongestion, .skippedHeartbeat,
        .sleepChanges, .soreThroat, .vaginalDryness, .vomiting,
        .wheezing,
        .environmentalAudioExposureEvent, .headphoneAudioExposureEvent,
        .appleWalkingSteadinessEvent,
        .lowCardioFitnessEvent, .persistentIntermenstrualBleeding,
        .prolongedMenstrualPeriods, .irregularMenstrualCycles,
        .infrequentMenstrualCycles,
    ]

    static let correlationIdentifiers: [HKCorrelationTypeIdentifier] = [
        .bloodPressure, .food,
    ]

    static let characteristicIdentifiers: [HKCharacteristicTypeIdentifier] = [
        .biologicalSex, .bloodType, .dateOfBirth, .fitzpatrickSkinType,
        .wheelchairUse, .activityMoveMode,
    ]

    static let clinicalIdentifiers: [HKClinicalTypeIdentifier] = [
        .allergyRecord, .conditionRecord, .immunizationRecord,
        .labResultRecord, .medicationRecord, .procedureRecord,
        .vitalSignRecord, .coverageRecord, .clinicalNoteRecord,
    ]
}
