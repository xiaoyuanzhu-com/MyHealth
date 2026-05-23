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

    private static func defaultDescription(for group: HealthTypeGroup) -> String {
        switch group {
        case .activity: return String(localized: "Activity and energy data recorded by Apple Health.")
        case .heart: return String(localized: "Heart-related measurements recorded by Apple Health.")
        case .bodyMeasurements: return String(localized: "Body measurement recorded by Apple Health.")
        case .sleep: return String(localized: "Sleep data recorded by Apple Health.")
        case .mobility: return String(localized: "Walking and mobility data recorded by Apple Health.")
        case .respiratory: return String(localized: "Respiratory measurement recorded by Apple Health.")
        case .hearing: return String(localized: "Audio and hearing data recorded by Apple Health.")
        case .vitals: return String(localized: "Vital sign recorded by Apple Health.")
        case .nutrition: return String(localized: "Dietary intake recorded by Apple Health.")
        case .cycleTracking: return String(localized: "Cycle tracking data recorded by Apple Health.")
        case .mindfulness: return String(localized: "Mindfulness session recorded by Apple Health.")
        case .symptoms: return String(localized: "Symptom logged in Apple Health.")
        case .characteristics: return String(localized: "Profile attribute stored in Apple Health.")
        case .other: return String(localized: "Data recorded by Apple Health.")
        }
    }

    // MARK: - Per-identifier overrides

    private static let nameOverrides: [String: String] = [
        // Curated overrides — preferred display names that differ from the
        // auto-derived form (or use special characters).
        HKObjectType.workoutType().identifier: String(localized: "Workouts"),
        HKSeriesType.workoutRoute().identifier: String(localized: "Workout Routes"),
        HKObjectType.electrocardiogramType().identifier: String(localized: "ECG"),
        HKObjectType.audiogramSampleType().identifier: String(localized: "Audiogram"),
        HKQuantityTypeIdentifier.bodyMassIndex.rawValue: String(localized: "Body Mass Index"),
        HKQuantityTypeIdentifier.vo2Max.rawValue: String(localized: "VO\u{2082} Max"),
        HKQuantityTypeIdentifier.heartRateVariabilitySDNN.rawValue: String(localized: "Heart Rate Variability"),
        HKQuantityTypeIdentifier.forcedExpiratoryVolume1.rawValue: String(localized: "Forced Expiratory Volume (1s)"),
        HKQuantityTypeIdentifier.uvExposure.rawValue: String(localized: "UV Exposure"),

        // Per-identifier names for the rest of the catalog. The English
        // value matches what autoName() would produce, so the English UX
        // is unchanged; this exposes every identifier to the String Catalog
        // so other languages can be translated without code changes.
        HKQuantityTypeIdentifier.stepCount.rawValue: String(localized: "Step Count"),
        HKQuantityTypeIdentifier.distanceWalkingRunning.rawValue: String(localized: "Distance Walking Running"),
        HKQuantityTypeIdentifier.distanceCycling.rawValue: String(localized: "Distance Cycling"),
        HKQuantityTypeIdentifier.distanceSwimming.rawValue: String(localized: "Distance Swimming"),
        HKQuantityTypeIdentifier.distanceWheelchair.rawValue: String(localized: "Distance Wheelchair"),
        HKQuantityTypeIdentifier.distanceDownhillSnowSports.rawValue: String(localized: "Distance Downhill Snow Sports"),
        HKQuantityTypeIdentifier.pushCount.rawValue: String(localized: "Push Count"),
        HKQuantityTypeIdentifier.swimmingStrokeCount.rawValue: String(localized: "Swimming Stroke Count"),
        HKQuantityTypeIdentifier.flightsClimbed.rawValue: String(localized: "Flights Climbed"),
        HKQuantityTypeIdentifier.nikeFuel.rawValue: String(localized: "Nike Fuel"),
        HKQuantityTypeIdentifier.activeEnergyBurned.rawValue: String(localized: "Active Energy Burned"),
        HKQuantityTypeIdentifier.basalEnergyBurned.rawValue: String(localized: "Basal Energy Burned"),
        HKQuantityTypeIdentifier.appleExerciseTime.rawValue: String(localized: "Apple Exercise Time"),
        HKQuantityTypeIdentifier.appleStandTime.rawValue: String(localized: "Apple Stand Time"),
        HKQuantityTypeIdentifier.appleMoveTime.rawValue: String(localized: "Apple Move Time"),
        HKQuantityTypeIdentifier.physicalEffort.rawValue: String(localized: "Physical Effort"),
        HKCategoryTypeIdentifier.appleStandHour.rawValue: String(localized: "Apple Stand Hour"),
        HKQuantityTypeIdentifier.heartRate.rawValue: String(localized: "Heart Rate"),
        HKQuantityTypeIdentifier.restingHeartRate.rawValue: String(localized: "Resting Heart Rate"),
        HKQuantityTypeIdentifier.walkingHeartRateAverage.rawValue: String(localized: "Walking Heart Rate Average"),
        HKQuantityTypeIdentifier.heartRateRecoveryOneMinute.rawValue: String(localized: "Heart Rate Recovery One Minute"),
        HKCategoryTypeIdentifier.lowHeartRateEvent.rawValue: String(localized: "Low Heart Rate Event"),
        HKCategoryTypeIdentifier.highHeartRateEvent.rawValue: String(localized: "High Heart Rate Event"),
        HKCategoryTypeIdentifier.irregularHeartRhythmEvent.rawValue: String(localized: "Irregular Heart Rhythm Event"),
        HKCategoryTypeIdentifier.lowCardioFitnessEvent.rawValue: String(localized: "Low Cardio Fitness Event"),
        HKQuantityTypeIdentifier.bodyMass.rawValue: String(localized: "Body Mass"),
        HKQuantityTypeIdentifier.bodyFatPercentage.rawValue: String(localized: "Body Fat Percentage"),
        HKQuantityTypeIdentifier.height.rawValue: String(localized: "Height"),
        HKQuantityTypeIdentifier.leanBodyMass.rawValue: String(localized: "Lean Body Mass"),
        HKQuantityTypeIdentifier.waistCircumference.rawValue: String(localized: "Waist Circumference"),
        HKCategoryTypeIdentifier.sleepAnalysis.rawValue: String(localized: "Sleep Analysis"),
        HKCategoryTypeIdentifier.sleepChanges.rawValue: String(localized: "Sleep Changes"),
        HKQuantityTypeIdentifier.walkingSpeed.rawValue: String(localized: "Walking Speed"),
        HKQuantityTypeIdentifier.walkingStepLength.rawValue: String(localized: "Walking Step Length"),
        HKQuantityTypeIdentifier.walkingAsymmetryPercentage.rawValue: String(localized: "Walking Asymmetry Percentage"),
        HKQuantityTypeIdentifier.walkingDoubleSupportPercentage.rawValue: String(localized: "Walking Double Support Percentage"),
        HKQuantityTypeIdentifier.stairAscentSpeed.rawValue: String(localized: "Stair Ascent Speed"),
        HKQuantityTypeIdentifier.stairDescentSpeed.rawValue: String(localized: "Stair Descent Speed"),
        HKQuantityTypeIdentifier.sixMinuteWalkTestDistance.rawValue: String(localized: "Six Minute Walk Test Distance"),
        HKQuantityTypeIdentifier.appleWalkingSteadiness.rawValue: String(localized: "Apple Walking Steadiness"),
        HKQuantityTypeIdentifier.runningGroundContactTime.rawValue: String(localized: "Running Ground Contact Time"),
        HKQuantityTypeIdentifier.runningStrideLength.rawValue: String(localized: "Running Stride Length"),
        HKQuantityTypeIdentifier.runningVerticalOscillation.rawValue: String(localized: "Running Vertical Oscillation"),
        HKQuantityTypeIdentifier.runningPower.rawValue: String(localized: "Running Power"),
        HKQuantityTypeIdentifier.runningSpeed.rawValue: String(localized: "Running Speed"),
        HKQuantityTypeIdentifier.cyclingCadence.rawValue: String(localized: "Cycling Cadence"),
        HKQuantityTypeIdentifier.cyclingFunctionalThresholdPower.rawValue: String(localized: "Cycling Functional Threshold Power"),
        HKQuantityTypeIdentifier.cyclingPower.rawValue: String(localized: "Cycling Power"),
        HKQuantityTypeIdentifier.cyclingSpeed.rawValue: String(localized: "Cycling Speed"),
        HKCategoryTypeIdentifier.appleWalkingSteadinessEvent.rawValue: String(localized: "Apple Walking Steadiness Event"),
        HKQuantityTypeIdentifier.respiratoryRate.rawValue: String(localized: "Respiratory Rate"),
        HKQuantityTypeIdentifier.oxygenSaturation.rawValue: String(localized: "Oxygen Saturation"),
        HKQuantityTypeIdentifier.forcedVitalCapacity.rawValue: String(localized: "Forced Vital Capacity"),
        HKQuantityTypeIdentifier.peakExpiratoryFlowRate.rawValue: String(localized: "Peak Expiratory Flow Rate"),
        HKQuantityTypeIdentifier.inhalerUsage.rawValue: String(localized: "Inhaler Usage"),
        HKQuantityTypeIdentifier.environmentalAudioExposure.rawValue: String(localized: "Environmental Audio Exposure"),
        HKQuantityTypeIdentifier.environmentalSoundReduction.rawValue: String(localized: "Environmental Sound Reduction"),
        HKQuantityTypeIdentifier.headphoneAudioExposure.rawValue: String(localized: "Headphone Audio Exposure"),
        HKCategoryTypeIdentifier.environmentalAudioExposureEvent.rawValue: String(localized: "Environmental Audio Exposure Event"),
        HKCategoryTypeIdentifier.headphoneAudioExposureEvent.rawValue: String(localized: "Headphone Audio Exposure Event"),
        HKQuantityTypeIdentifier.bodyTemperature.rawValue: String(localized: "Body Temperature"),
        HKQuantityTypeIdentifier.basalBodyTemperature.rawValue: String(localized: "Basal Body Temperature"),
        HKQuantityTypeIdentifier.bloodPressureSystolic.rawValue: String(localized: "Blood Pressure Systolic"),
        HKQuantityTypeIdentifier.bloodPressureDiastolic.rawValue: String(localized: "Blood Pressure Diastolic"),
        HKQuantityTypeIdentifier.bloodGlucose.rawValue: String(localized: "Blood Glucose"),
        HKQuantityTypeIdentifier.electrodermalActivity.rawValue: String(localized: "Electrodermal Activity"),
        HKQuantityTypeIdentifier.numberOfTimesFallen.rawValue: String(localized: "Number Of Times Fallen"),
        HKQuantityTypeIdentifier.peripheralPerfusionIndex.rawValue: String(localized: "Peripheral Perfusion Index"),
        HKQuantityTypeIdentifier.underwaterDepth.rawValue: String(localized: "Underwater Depth"),
        HKQuantityTypeIdentifier.waterTemperature.rawValue: String(localized: "Water Temperature"),
        HKQuantityTypeIdentifier.timeInDaylight.rawValue: String(localized: "Time In Daylight"),
        HKQuantityTypeIdentifier.insulinDelivery.rawValue: String(localized: "Insulin Delivery"),
        HKQuantityTypeIdentifier.dietaryEnergyConsumed.rawValue: String(localized: "Dietary Energy Consumed"),
        HKQuantityTypeIdentifier.dietaryFatTotal.rawValue: String(localized: "Dietary Fat Total"),
        HKQuantityTypeIdentifier.dietaryFatSaturated.rawValue: String(localized: "Dietary Fat Saturated"),
        HKQuantityTypeIdentifier.dietaryFatPolyunsaturated.rawValue: String(localized: "Dietary Fat Polyunsaturated"),
        HKQuantityTypeIdentifier.dietaryFatMonounsaturated.rawValue: String(localized: "Dietary Fat Monounsaturated"),
        HKQuantityTypeIdentifier.dietaryCholesterol.rawValue: String(localized: "Dietary Cholesterol"),
        HKQuantityTypeIdentifier.dietarySodium.rawValue: String(localized: "Dietary Sodium"),
        HKQuantityTypeIdentifier.dietaryCarbohydrates.rawValue: String(localized: "Dietary Carbohydrates"),
        HKQuantityTypeIdentifier.dietaryFiber.rawValue: String(localized: "Dietary Fiber"),
        HKQuantityTypeIdentifier.dietarySugar.rawValue: String(localized: "Dietary Sugar"),
        HKQuantityTypeIdentifier.dietaryProtein.rawValue: String(localized: "Dietary Protein"),
        HKQuantityTypeIdentifier.dietaryVitaminA.rawValue: String(localized: "Dietary Vitamin A"),
        HKQuantityTypeIdentifier.dietaryVitaminB6.rawValue: String(localized: "Dietary Vitamin B6"),
        HKQuantityTypeIdentifier.dietaryVitaminB12.rawValue: String(localized: "Dietary Vitamin B12"),
        HKQuantityTypeIdentifier.dietaryVitaminC.rawValue: String(localized: "Dietary Vitamin C"),
        HKQuantityTypeIdentifier.dietaryVitaminD.rawValue: String(localized: "Dietary Vitamin D"),
        HKQuantityTypeIdentifier.dietaryVitaminE.rawValue: String(localized: "Dietary Vitamin E"),
        HKQuantityTypeIdentifier.dietaryVitaminK.rawValue: String(localized: "Dietary Vitamin K"),
        HKQuantityTypeIdentifier.dietaryCalcium.rawValue: String(localized: "Dietary Calcium"),
        HKQuantityTypeIdentifier.dietaryIron.rawValue: String(localized: "Dietary Iron"),
        HKQuantityTypeIdentifier.dietaryThiamin.rawValue: String(localized: "Dietary Thiamin"),
        HKQuantityTypeIdentifier.dietaryRiboflavin.rawValue: String(localized: "Dietary Riboflavin"),
        HKQuantityTypeIdentifier.dietaryNiacin.rawValue: String(localized: "Dietary Niacin"),
        HKQuantityTypeIdentifier.dietaryFolate.rawValue: String(localized: "Dietary Folate"),
        HKQuantityTypeIdentifier.dietaryBiotin.rawValue: String(localized: "Dietary Biotin"),
        HKQuantityTypeIdentifier.dietaryPantothenicAcid.rawValue: String(localized: "Dietary Pantothenic Acid"),
        HKQuantityTypeIdentifier.dietaryPhosphorus.rawValue: String(localized: "Dietary Phosphorus"),
        HKQuantityTypeIdentifier.dietaryIodine.rawValue: String(localized: "Dietary Iodine"),
        HKQuantityTypeIdentifier.dietaryMagnesium.rawValue: String(localized: "Dietary Magnesium"),
        HKQuantityTypeIdentifier.dietaryZinc.rawValue: String(localized: "Dietary Zinc"),
        HKQuantityTypeIdentifier.dietarySelenium.rawValue: String(localized: "Dietary Selenium"),
        HKQuantityTypeIdentifier.dietaryCopper.rawValue: String(localized: "Dietary Copper"),
        HKQuantityTypeIdentifier.dietaryManganese.rawValue: String(localized: "Dietary Manganese"),
        HKQuantityTypeIdentifier.dietaryChromium.rawValue: String(localized: "Dietary Chromium"),
        HKQuantityTypeIdentifier.dietaryMolybdenum.rawValue: String(localized: "Dietary Molybdenum"),
        HKQuantityTypeIdentifier.dietaryChloride.rawValue: String(localized: "Dietary Chloride"),
        HKQuantityTypeIdentifier.dietaryPotassium.rawValue: String(localized: "Dietary Potassium"),
        HKQuantityTypeIdentifier.dietaryCaffeine.rawValue: String(localized: "Dietary Caffeine"),
        HKQuantityTypeIdentifier.dietaryWater.rawValue: String(localized: "Dietary Water"),
        HKCategoryTypeIdentifier.cervicalMucusQuality.rawValue: String(localized: "Cervical Mucus Quality"),
        HKCategoryTypeIdentifier.menstrualFlow.rawValue: String(localized: "Menstrual Flow"),
        HKCategoryTypeIdentifier.ovulationTestResult.rawValue: String(localized: "Ovulation Test Result"),
        HKCategoryTypeIdentifier.sexualActivity.rawValue: String(localized: "Sexual Activity"),
        HKCategoryTypeIdentifier.intermenstrualBleeding.rawValue: String(localized: "Intermenstrual Bleeding"),
        HKCategoryTypeIdentifier.pregnancy.rawValue: String(localized: "Pregnancy"),
        HKCategoryTypeIdentifier.lactation.rawValue: String(localized: "Lactation"),
        HKCategoryTypeIdentifier.contraceptive.rawValue: String(localized: "Contraceptive"),
        HKCategoryTypeIdentifier.pregnancyTestResult.rawValue: String(localized: "Pregnancy Test Result"),
        HKCategoryTypeIdentifier.progesteroneTestResult.rawValue: String(localized: "Progesterone Test Result"),
        HKCategoryTypeIdentifier.persistentIntermenstrualBleeding.rawValue: String(localized: "Persistent Intermenstrual Bleeding"),
        HKCategoryTypeIdentifier.prolongedMenstrualPeriods.rawValue: String(localized: "Prolonged Menstrual Periods"),
        HKCategoryTypeIdentifier.irregularMenstrualCycles.rawValue: String(localized: "Irregular Menstrual Cycles"),
        HKCategoryTypeIdentifier.infrequentMenstrualCycles.rawValue: String(localized: "Infrequent Menstrual Cycles"),
        HKCategoryTypeIdentifier.mindfulSession.rawValue: String(localized: "Mindful Session"),
        HKCategoryTypeIdentifier.toothbrushingEvent.rawValue: String(localized: "Toothbrushing Event"),
        HKCategoryTypeIdentifier.handwashingEvent.rawValue: String(localized: "Handwashing Event"),
        HKCategoryTypeIdentifier.abdominalCramps.rawValue: String(localized: "Abdominal Cramps"),
        HKCategoryTypeIdentifier.acne.rawValue: String(localized: "Acne"),
        HKCategoryTypeIdentifier.appetiteChanges.rawValue: String(localized: "Appetite Changes"),
        HKCategoryTypeIdentifier.bladderIncontinence.rawValue: String(localized: "Bladder Incontinence"),
        HKCategoryTypeIdentifier.bloating.rawValue: String(localized: "Bloating"),
        HKCategoryTypeIdentifier.breastPain.rawValue: String(localized: "Breast Pain"),
        HKCategoryTypeIdentifier.chestTightnessOrPain.rawValue: String(localized: "Chest Tightness Or Pain"),
        HKCategoryTypeIdentifier.chills.rawValue: String(localized: "Chills"),
        HKCategoryTypeIdentifier.constipation.rawValue: String(localized: "Constipation"),
        HKCategoryTypeIdentifier.coughing.rawValue: String(localized: "Coughing"),
        HKCategoryTypeIdentifier.diarrhea.rawValue: String(localized: "Diarrhea"),
        HKCategoryTypeIdentifier.dizziness.rawValue: String(localized: "Dizziness"),
        HKCategoryTypeIdentifier.drySkin.rawValue: String(localized: "Dry Skin"),
        HKCategoryTypeIdentifier.fainting.rawValue: String(localized: "Fainting"),
        HKCategoryTypeIdentifier.fatigue.rawValue: String(localized: "Fatigue"),
        HKCategoryTypeIdentifier.fever.rawValue: String(localized: "Fever"),
        HKCategoryTypeIdentifier.generalizedBodyAche.rawValue: String(localized: "Generalized Body Ache"),
        HKCategoryTypeIdentifier.hairLoss.rawValue: String(localized: "Hair Loss"),
        HKCategoryTypeIdentifier.headache.rawValue: String(localized: "Headache"),
        HKCategoryTypeIdentifier.heartburn.rawValue: String(localized: "Heartburn"),
        HKCategoryTypeIdentifier.hotFlashes.rawValue: String(localized: "Hot Flashes"),
        HKCategoryTypeIdentifier.lossOfSmell.rawValue: String(localized: "Loss Of Smell"),
        HKCategoryTypeIdentifier.lossOfTaste.rawValue: String(localized: "Loss Of Taste"),
        HKCategoryTypeIdentifier.lowerBackPain.rawValue: String(localized: "Lower Back Pain"),
        HKCategoryTypeIdentifier.memoryLapse.rawValue: String(localized: "Memory Lapse"),
        HKCategoryTypeIdentifier.moodChanges.rawValue: String(localized: "Mood Changes"),
        HKCategoryTypeIdentifier.nausea.rawValue: String(localized: "Nausea"),
        HKCategoryTypeIdentifier.nightSweats.rawValue: String(localized: "Night Sweats"),
        HKCategoryTypeIdentifier.pelvicPain.rawValue: String(localized: "Pelvic Pain"),
        HKCategoryTypeIdentifier.rapidPoundingOrFlutteringHeartbeat.rawValue: String(localized: "Rapid Pounding Or Fluttering Heartbeat"),
        HKCategoryTypeIdentifier.runnyNose.rawValue: String(localized: "Runny Nose"),
        HKCategoryTypeIdentifier.shortnessOfBreath.rawValue: String(localized: "Shortness Of Breath"),
        HKCategoryTypeIdentifier.sinusCongestion.rawValue: String(localized: "Sinus Congestion"),
        HKCategoryTypeIdentifier.skippedHeartbeat.rawValue: String(localized: "Skipped Heartbeat"),
        HKCategoryTypeIdentifier.soreThroat.rawValue: String(localized: "Sore Throat"),
        HKCategoryTypeIdentifier.vaginalDryness.rawValue: String(localized: "Vaginal Dryness"),
        HKCategoryTypeIdentifier.vomiting.rawValue: String(localized: "Vomiting"),
        HKCategoryTypeIdentifier.wheezing.rawValue: String(localized: "Wheezing"),
        HKCharacteristicTypeIdentifier.biologicalSex.rawValue: String(localized: "Biological Sex"),
        HKCharacteristicTypeIdentifier.bloodType.rawValue: String(localized: "Blood Type"),
        HKCharacteristicTypeIdentifier.dateOfBirth.rawValue: String(localized: "Date Of Birth"),
        HKCharacteristicTypeIdentifier.fitzpatrickSkinType.rawValue: String(localized: "Fitzpatrick Skin Type"),
        HKCharacteristicTypeIdentifier.wheelchairUse.rawValue: String(localized: "Wheelchair Use"),
        HKCharacteristicTypeIdentifier.activityMoveMode.rawValue: String(localized: "Activity Move Mode"),
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
            String(localized: "Steps taken, recorded by Apple Watch or iPhone."),
        HKQuantityTypeIdentifier.heartRate.rawValue:
            String(localized: "Instantaneous heart rate readings in beats per minute."),
        HKQuantityTypeIdentifier.heartRateVariabilitySDNN.rawValue:
            String(localized: "SDNN measurement of heart rate variability, in milliseconds."),
        HKQuantityTypeIdentifier.activeEnergyBurned.rawValue:
            String(localized: "Energy burned by movement, in kilocalories."),
        HKQuantityTypeIdentifier.basalEnergyBurned.rawValue:
            String(localized: "Resting metabolic energy expenditure, in kilocalories."),
        HKQuantityTypeIdentifier.appleExerciseTime.rawValue:
            String(localized: "Minutes counted toward your Exercise ring."),
        HKQuantityTypeIdentifier.appleStandTime.rawValue:
            String(localized: "Minutes spent standing, counted toward your Stand ring."),
        HKQuantityTypeIdentifier.bodyMass.rawValue:
            String(localized: "Weight measurements, in kilograms."),
        HKQuantityTypeIdentifier.height.rawValue:
            String(localized: "Height measurements, in meters."),
        HKQuantityTypeIdentifier.vo2Max.rawValue:
            String(localized: "Cardio fitness — maximum oxygen consumption during exercise."),
        HKObjectType.workoutType().identifier:
            String(localized: "Recorded workout sessions including duration, energy, and (when available) GPS route."),
        HKObjectType.electrocardiogramType().identifier:
            String(localized: "Single-lead ECG recordings from Apple Watch."),
        HKCategoryTypeIdentifier.sleepAnalysis.rawValue:
            String(localized: "Sleep stages and durations recorded automatically or entered manually."),
        HKCategoryTypeIdentifier.mindfulSession.rawValue:
            String(localized: "Logged mindfulness or breathing sessions."),
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
