import Foundation
import HealthKit

/// One entry in the Data-tab list — a single HealthKit permission type with
/// the metadata needed to render a row and its detail page.
///
/// `displayName` and `description` are computed at access time so they
/// re-resolve to the current localization whenever the user switches the
/// in-app language. (Storing them would freeze the strings to whatever
/// language was active when the static catalog was first built.)
struct HealthTypeEntry: Identifiable, Hashable {
    let objectType: HKObjectType
    let icon: String
    let group: HealthTypeGroup

    var id: String { objectType.identifier }
    var displayName: String { HealthTypeCatalog.displayName(for: id) }
    var description: String { HealthTypeCatalog.description(for: id, group: group) }

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
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .activity: return String(localized: "Activity")
        case .heart: return String(localized: "Heart")
        case .bodyMeasurements: return String(localized: "Body Measurements")
        case .sleep: return String(localized: "Sleep")
        case .mobility: return String(localized: "Mobility")
        case .respiratory: return String(localized: "Respiratory")
        case .hearing: return String(localized: "Hearing")
        case .vitals: return String(localized: "Vitals")
        case .nutrition: return String(localized: "Nutrition")
        case .cycleTracking: return String(localized: "Cycle Tracking")
        case .mindfulness: return String(localized: "Mindfulness")
        case .symptoms: return String(localized: "Symptoms")
        case .characteristics: return String(localized: "Characteristics")
        case .other: return String(localized: "Other")
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

    /// Localized display name for a given HK identifier. Re-resolves
    /// `String(localized:)` on every call so language changes take effect
    /// without rebuilding the static catalog.
    static func displayName(for id: String) -> String {
        if let v = nameOverrides[id] { return String(localized: v) }
        return autoName(from: id)
    }

    /// Localized description for a given HK identifier. Falls back to the
    /// group's default description when no per-id override exists.
    static func description(for id: String, group: HealthTypeGroup) -> String {
        if let v = descriptionOverrides[id] { return String(localized: v) }
        return String(localized: defaultDescription(for: group))
    }

    // MARK: - Building the catalog

    private static let entriesByGroup: [HealthTypeGroup: [HealthTypeEntry]] = build()

    private static func build() -> [HealthTypeGroup: [HealthTypeEntry]] {
        var out: [HealthTypeGroup: [HealthTypeEntry]] = [:]
        for (id, group) in groupAssignments {
            guard let type = objectType(for: id) else { continue }
            let entry = HealthTypeEntry(
                objectType: type,
                icon: iconOverrides[id] ?? defaultIcon(for: group),
                group: group
            )
            out[group, default: []].append(entry)
        }
        // Sort each group alphabetically by display name for stable output.
        // Sort key uses whatever language is active on first access; we
        // accept a fixed order rather than re-sorting on every render.
        for k in out.keys {
            out[k]?.sort {
                displayName(for: $0.id)
                    .localizedCaseInsensitiveCompare(displayName(for: $1.id))
                    == .orderedAscending
            }
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
        case .other: return "heart.text.square"
        }
    }

    private static func defaultDescription(for group: HealthTypeGroup) -> String.LocalizationValue {
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
        case .other: return "Data recorded by Apple Health."
        }
    }

    // MARK: - Per-identifier overrides

    private static let nameOverrides: [String: String.LocalizationValue] = [
        // Curated overrides — preferred display names that differ from the
        // auto-derived form (or use special characters).
        HKObjectType.workoutType().identifier: "Workouts",
        HKSeriesType.workoutRoute().identifier: "Workout Routes",
        HKObjectType.electrocardiogramType().identifier: "ECG",
        HKObjectType.audiogramSampleType().identifier: "Audiogram",
        HKQuantityTypeIdentifier.bodyMassIndex.rawValue: "Body Mass Index",
        HKQuantityTypeIdentifier.vo2Max.rawValue: "VO\u{2082} Max",
        HKQuantityTypeIdentifier.heartRateVariabilitySDNN.rawValue: "Heart Rate Variability",
        HKQuantityTypeIdentifier.forcedExpiratoryVolume1.rawValue: "Forced Expiratory Volume (1s)",
        HKQuantityTypeIdentifier.uvExposure.rawValue: "UV Exposure",

        // Per-identifier names for the rest of the catalog. The English
        // value matches what autoName() would produce, so the English UX
        // is unchanged; this exposes every identifier to the String Catalog
        // so other languages can be translated without code changes.
        HKQuantityTypeIdentifier.stepCount.rawValue: "Step Count",
        HKQuantityTypeIdentifier.distanceWalkingRunning.rawValue: "Distance Walking Running",
        HKQuantityTypeIdentifier.distanceCycling.rawValue: "Distance Cycling",
        HKQuantityTypeIdentifier.distanceSwimming.rawValue: "Distance Swimming",
        HKQuantityTypeIdentifier.distanceWheelchair.rawValue: "Distance Wheelchair",
        HKQuantityTypeIdentifier.distanceDownhillSnowSports.rawValue: "Distance Downhill Snow Sports",
        HKQuantityTypeIdentifier.pushCount.rawValue: "Push Count",
        HKQuantityTypeIdentifier.swimmingStrokeCount.rawValue: "Swimming Stroke Count",
        HKQuantityTypeIdentifier.flightsClimbed.rawValue: "Flights Climbed",
        HKQuantityTypeIdentifier.nikeFuel.rawValue: "Nike Fuel",
        HKQuantityTypeIdentifier.activeEnergyBurned.rawValue: "Active Energy Burned",
        HKQuantityTypeIdentifier.basalEnergyBurned.rawValue: "Basal Energy Burned",
        HKQuantityTypeIdentifier.appleExerciseTime.rawValue: "Apple Exercise Time",
        HKQuantityTypeIdentifier.appleStandTime.rawValue: "Apple Stand Time",
        HKQuantityTypeIdentifier.appleMoveTime.rawValue: "Apple Move Time",
        HKQuantityTypeIdentifier.physicalEffort.rawValue: "Physical Effort",
        HKCategoryTypeIdentifier.appleStandHour.rawValue: "Apple Stand Hour",
        HKQuantityTypeIdentifier.heartRate.rawValue: "Heart Rate",
        HKQuantityTypeIdentifier.restingHeartRate.rawValue: "Resting Heart Rate",
        HKQuantityTypeIdentifier.walkingHeartRateAverage.rawValue: "Walking Heart Rate Average",
        HKQuantityTypeIdentifier.heartRateRecoveryOneMinute.rawValue: "Heart Rate Recovery One Minute",
        HKCategoryTypeIdentifier.lowHeartRateEvent.rawValue: "Low Heart Rate Event",
        HKCategoryTypeIdentifier.highHeartRateEvent.rawValue: "High Heart Rate Event",
        HKCategoryTypeIdentifier.irregularHeartRhythmEvent.rawValue: "Irregular Heart Rhythm Event",
        HKCategoryTypeIdentifier.lowCardioFitnessEvent.rawValue: "Low Cardio Fitness Event",
        HKQuantityTypeIdentifier.bodyMass.rawValue: "Body Mass",
        HKQuantityTypeIdentifier.bodyFatPercentage.rawValue: "Body Fat Percentage",
        HKQuantityTypeIdentifier.height.rawValue: "Height",
        HKQuantityTypeIdentifier.leanBodyMass.rawValue: "Lean Body Mass",
        HKQuantityTypeIdentifier.waistCircumference.rawValue: "Waist Circumference",
        HKCategoryTypeIdentifier.sleepAnalysis.rawValue: "Sleep Analysis",
        HKCategoryTypeIdentifier.sleepChanges.rawValue: "Sleep Changes",
        HKQuantityTypeIdentifier.walkingSpeed.rawValue: "Walking Speed",
        HKQuantityTypeIdentifier.walkingStepLength.rawValue: "Walking Step Length",
        HKQuantityTypeIdentifier.walkingAsymmetryPercentage.rawValue: "Walking Asymmetry Percentage",
        HKQuantityTypeIdentifier.walkingDoubleSupportPercentage.rawValue: "Walking Double Support Percentage",
        HKQuantityTypeIdentifier.stairAscentSpeed.rawValue: "Stair Ascent Speed",
        HKQuantityTypeIdentifier.stairDescentSpeed.rawValue: "Stair Descent Speed",
        HKQuantityTypeIdentifier.sixMinuteWalkTestDistance.rawValue: "Six Minute Walk Test Distance",
        HKQuantityTypeIdentifier.appleWalkingSteadiness.rawValue: "Apple Walking Steadiness",
        HKQuantityTypeIdentifier.runningGroundContactTime.rawValue: "Running Ground Contact Time",
        HKQuantityTypeIdentifier.runningStrideLength.rawValue: "Running Stride Length",
        HKQuantityTypeIdentifier.runningVerticalOscillation.rawValue: "Running Vertical Oscillation",
        HKQuantityTypeIdentifier.runningPower.rawValue: "Running Power",
        HKQuantityTypeIdentifier.runningSpeed.rawValue: "Running Speed",
        HKQuantityTypeIdentifier.cyclingCadence.rawValue: "Cycling Cadence",
        HKQuantityTypeIdentifier.cyclingFunctionalThresholdPower.rawValue: "Cycling Functional Threshold Power",
        HKQuantityTypeIdentifier.cyclingPower.rawValue: "Cycling Power",
        HKQuantityTypeIdentifier.cyclingSpeed.rawValue: "Cycling Speed",
        HKCategoryTypeIdentifier.appleWalkingSteadinessEvent.rawValue: "Apple Walking Steadiness Event",
        HKQuantityTypeIdentifier.respiratoryRate.rawValue: "Respiratory Rate",
        HKQuantityTypeIdentifier.oxygenSaturation.rawValue: "Oxygen Saturation",
        HKQuantityTypeIdentifier.forcedVitalCapacity.rawValue: "Forced Vital Capacity",
        HKQuantityTypeIdentifier.peakExpiratoryFlowRate.rawValue: "Peak Expiratory Flow Rate",
        HKQuantityTypeIdentifier.inhalerUsage.rawValue: "Inhaler Usage",
        HKQuantityTypeIdentifier.environmentalAudioExposure.rawValue: "Environmental Audio Exposure",
        HKQuantityTypeIdentifier.environmentalSoundReduction.rawValue: "Environmental Sound Reduction",
        HKQuantityTypeIdentifier.headphoneAudioExposure.rawValue: "Headphone Audio Exposure",
        HKCategoryTypeIdentifier.environmentalAudioExposureEvent.rawValue: "Environmental Audio Exposure Event",
        HKCategoryTypeIdentifier.headphoneAudioExposureEvent.rawValue: "Headphone Audio Exposure Event",
        HKQuantityTypeIdentifier.bodyTemperature.rawValue: "Body Temperature",
        HKQuantityTypeIdentifier.basalBodyTemperature.rawValue: "Basal Body Temperature",
        HKQuantityTypeIdentifier.bloodPressureSystolic.rawValue: "Blood Pressure Systolic",
        HKQuantityTypeIdentifier.bloodPressureDiastolic.rawValue: "Blood Pressure Diastolic",
        HKQuantityTypeIdentifier.bloodGlucose.rawValue: "Blood Glucose",
        HKQuantityTypeIdentifier.electrodermalActivity.rawValue: "Electrodermal Activity",
        HKQuantityTypeIdentifier.numberOfTimesFallen.rawValue: "Number Of Times Fallen",
        HKQuantityTypeIdentifier.peripheralPerfusionIndex.rawValue: "Peripheral Perfusion Index",
        HKQuantityTypeIdentifier.underwaterDepth.rawValue: "Underwater Depth",
        HKQuantityTypeIdentifier.waterTemperature.rawValue: "Water Temperature",
        HKQuantityTypeIdentifier.timeInDaylight.rawValue: "Time In Daylight",
        HKQuantityTypeIdentifier.insulinDelivery.rawValue: "Insulin Delivery",
        HKQuantityTypeIdentifier.dietaryEnergyConsumed.rawValue: "Dietary Energy Consumed",
        HKQuantityTypeIdentifier.dietaryFatTotal.rawValue: "Dietary Fat Total",
        HKQuantityTypeIdentifier.dietaryFatSaturated.rawValue: "Dietary Fat Saturated",
        HKQuantityTypeIdentifier.dietaryFatPolyunsaturated.rawValue: "Dietary Fat Polyunsaturated",
        HKQuantityTypeIdentifier.dietaryFatMonounsaturated.rawValue: "Dietary Fat Monounsaturated",
        HKQuantityTypeIdentifier.dietaryCholesterol.rawValue: "Dietary Cholesterol",
        HKQuantityTypeIdentifier.dietarySodium.rawValue: "Dietary Sodium",
        HKQuantityTypeIdentifier.dietaryCarbohydrates.rawValue: "Dietary Carbohydrates",
        HKQuantityTypeIdentifier.dietaryFiber.rawValue: "Dietary Fiber",
        HKQuantityTypeIdentifier.dietarySugar.rawValue: "Dietary Sugar",
        HKQuantityTypeIdentifier.dietaryProtein.rawValue: "Dietary Protein",
        HKQuantityTypeIdentifier.dietaryVitaminA.rawValue: "Dietary Vitamin A",
        HKQuantityTypeIdentifier.dietaryVitaminB6.rawValue: "Dietary Vitamin B6",
        HKQuantityTypeIdentifier.dietaryVitaminB12.rawValue: "Dietary Vitamin B12",
        HKQuantityTypeIdentifier.dietaryVitaminC.rawValue: "Dietary Vitamin C",
        HKQuantityTypeIdentifier.dietaryVitaminD.rawValue: "Dietary Vitamin D",
        HKQuantityTypeIdentifier.dietaryVitaminE.rawValue: "Dietary Vitamin E",
        HKQuantityTypeIdentifier.dietaryVitaminK.rawValue: "Dietary Vitamin K",
        HKQuantityTypeIdentifier.dietaryCalcium.rawValue: "Dietary Calcium",
        HKQuantityTypeIdentifier.dietaryIron.rawValue: "Dietary Iron",
        HKQuantityTypeIdentifier.dietaryThiamin.rawValue: "Dietary Thiamin",
        HKQuantityTypeIdentifier.dietaryRiboflavin.rawValue: "Dietary Riboflavin",
        HKQuantityTypeIdentifier.dietaryNiacin.rawValue: "Dietary Niacin",
        HKQuantityTypeIdentifier.dietaryFolate.rawValue: "Dietary Folate",
        HKQuantityTypeIdentifier.dietaryBiotin.rawValue: "Dietary Biotin",
        HKQuantityTypeIdentifier.dietaryPantothenicAcid.rawValue: "Dietary Pantothenic Acid",
        HKQuantityTypeIdentifier.dietaryPhosphorus.rawValue: "Dietary Phosphorus",
        HKQuantityTypeIdentifier.dietaryIodine.rawValue: "Dietary Iodine",
        HKQuantityTypeIdentifier.dietaryMagnesium.rawValue: "Dietary Magnesium",
        HKQuantityTypeIdentifier.dietaryZinc.rawValue: "Dietary Zinc",
        HKQuantityTypeIdentifier.dietarySelenium.rawValue: "Dietary Selenium",
        HKQuantityTypeIdentifier.dietaryCopper.rawValue: "Dietary Copper",
        HKQuantityTypeIdentifier.dietaryManganese.rawValue: "Dietary Manganese",
        HKQuantityTypeIdentifier.dietaryChromium.rawValue: "Dietary Chromium",
        HKQuantityTypeIdentifier.dietaryMolybdenum.rawValue: "Dietary Molybdenum",
        HKQuantityTypeIdentifier.dietaryChloride.rawValue: "Dietary Chloride",
        HKQuantityTypeIdentifier.dietaryPotassium.rawValue: "Dietary Potassium",
        HKQuantityTypeIdentifier.dietaryCaffeine.rawValue: "Dietary Caffeine",
        HKQuantityTypeIdentifier.dietaryWater.rawValue: "Dietary Water",
        HKCategoryTypeIdentifier.cervicalMucusQuality.rawValue: "Cervical Mucus Quality",
        HKCategoryTypeIdentifier.menstrualFlow.rawValue: "Menstrual Flow",
        HKCategoryTypeIdentifier.ovulationTestResult.rawValue: "Ovulation Test Result",
        HKCategoryTypeIdentifier.sexualActivity.rawValue: "Sexual Activity",
        HKCategoryTypeIdentifier.intermenstrualBleeding.rawValue: "Intermenstrual Bleeding",
        HKCategoryTypeIdentifier.pregnancy.rawValue: "Pregnancy",
        HKCategoryTypeIdentifier.lactation.rawValue: "Lactation",
        HKCategoryTypeIdentifier.contraceptive.rawValue: "Contraceptive",
        HKCategoryTypeIdentifier.pregnancyTestResult.rawValue: "Pregnancy Test Result",
        HKCategoryTypeIdentifier.progesteroneTestResult.rawValue: "Progesterone Test Result",
        HKCategoryTypeIdentifier.persistentIntermenstrualBleeding.rawValue: "Persistent Intermenstrual Bleeding",
        HKCategoryTypeIdentifier.prolongedMenstrualPeriods.rawValue: "Prolonged Menstrual Periods",
        HKCategoryTypeIdentifier.irregularMenstrualCycles.rawValue: "Irregular Menstrual Cycles",
        HKCategoryTypeIdentifier.infrequentMenstrualCycles.rawValue: "Infrequent Menstrual Cycles",
        HKCategoryTypeIdentifier.mindfulSession.rawValue: "Mindful Session",
        HKCategoryTypeIdentifier.toothbrushingEvent.rawValue: "Toothbrushing Event",
        HKCategoryTypeIdentifier.handwashingEvent.rawValue: "Handwashing Event",
        HKCategoryTypeIdentifier.abdominalCramps.rawValue: "Abdominal Cramps",
        HKCategoryTypeIdentifier.acne.rawValue: "Acne",
        HKCategoryTypeIdentifier.appetiteChanges.rawValue: "Appetite Changes",
        HKCategoryTypeIdentifier.bladderIncontinence.rawValue: "Bladder Incontinence",
        HKCategoryTypeIdentifier.bloating.rawValue: "Bloating",
        HKCategoryTypeIdentifier.breastPain.rawValue: "Breast Pain",
        HKCategoryTypeIdentifier.chestTightnessOrPain.rawValue: "Chest Tightness Or Pain",
        HKCategoryTypeIdentifier.chills.rawValue: "Chills",
        HKCategoryTypeIdentifier.constipation.rawValue: "Constipation",
        HKCategoryTypeIdentifier.coughing.rawValue: "Coughing",
        HKCategoryTypeIdentifier.diarrhea.rawValue: "Diarrhea",
        HKCategoryTypeIdentifier.dizziness.rawValue: "Dizziness",
        HKCategoryTypeIdentifier.drySkin.rawValue: "Dry Skin",
        HKCategoryTypeIdentifier.fainting.rawValue: "Fainting",
        HKCategoryTypeIdentifier.fatigue.rawValue: "Fatigue",
        HKCategoryTypeIdentifier.fever.rawValue: "Fever",
        HKCategoryTypeIdentifier.generalizedBodyAche.rawValue: "Generalized Body Ache",
        HKCategoryTypeIdentifier.hairLoss.rawValue: "Hair Loss",
        HKCategoryTypeIdentifier.headache.rawValue: "Headache",
        HKCategoryTypeIdentifier.heartburn.rawValue: "Heartburn",
        HKCategoryTypeIdentifier.hotFlashes.rawValue: "Hot Flashes",
        HKCategoryTypeIdentifier.lossOfSmell.rawValue: "Loss Of Smell",
        HKCategoryTypeIdentifier.lossOfTaste.rawValue: "Loss Of Taste",
        HKCategoryTypeIdentifier.lowerBackPain.rawValue: "Lower Back Pain",
        HKCategoryTypeIdentifier.memoryLapse.rawValue: "Memory Lapse",
        HKCategoryTypeIdentifier.moodChanges.rawValue: "Mood Changes",
        HKCategoryTypeIdentifier.nausea.rawValue: "Nausea",
        HKCategoryTypeIdentifier.nightSweats.rawValue: "Night Sweats",
        HKCategoryTypeIdentifier.pelvicPain.rawValue: "Pelvic Pain",
        HKCategoryTypeIdentifier.rapidPoundingOrFlutteringHeartbeat.rawValue: "Rapid Pounding Or Fluttering Heartbeat",
        HKCategoryTypeIdentifier.runnyNose.rawValue: "Runny Nose",
        HKCategoryTypeIdentifier.shortnessOfBreath.rawValue: "Shortness Of Breath",
        HKCategoryTypeIdentifier.sinusCongestion.rawValue: "Sinus Congestion",
        HKCategoryTypeIdentifier.skippedHeartbeat.rawValue: "Skipped Heartbeat",
        HKCategoryTypeIdentifier.soreThroat.rawValue: "Sore Throat",
        HKCategoryTypeIdentifier.vaginalDryness.rawValue: "Vaginal Dryness",
        HKCategoryTypeIdentifier.vomiting.rawValue: "Vomiting",
        HKCategoryTypeIdentifier.wheezing.rawValue: "Wheezing",
        HKCharacteristicTypeIdentifier.biologicalSex.rawValue: "Biological Sex",
        HKCharacteristicTypeIdentifier.bloodType.rawValue: "Blood Type",
        HKCharacteristicTypeIdentifier.dateOfBirth.rawValue: "Date Of Birth",
        HKCharacteristicTypeIdentifier.fitzpatrickSkinType.rawValue: "Fitzpatrick Skin Type",
        HKCharacteristicTypeIdentifier.wheelchairUse.rawValue: "Wheelchair Use",
        HKCharacteristicTypeIdentifier.activityMoveMode.rawValue: "Activity Move Mode",
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

    private static let descriptionOverrides: [String: String.LocalizationValue] = [
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
        + symptomIDs + characteristicIDs + otherIDs

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
            HKCategoryTypeIdentifier.environmentalAudioExposureEvent,
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

    private static let otherIDs: [(String, HealthTypeGroup)] = []
}
