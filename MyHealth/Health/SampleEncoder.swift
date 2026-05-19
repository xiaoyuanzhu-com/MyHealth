import Foundation
import HealthKit
import CoreLocation

/// Builds the new per-day-layout DTOs (`QuantitySample`, `CategorySample`,
/// `WorkoutFile`) from HealthKit's native types. Date formatting is ISO 8601
/// UTC with fractional seconds (`2026-01-18T01:00:00.000Z`).
struct SampleEncoder {

    static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func iso(_ d: Date) -> String { isoFormatter.string(from: d) }

    // MARK: - Quantity

    static func encode(_ q: HKQuantitySample) -> QuantitySample? {
        let unit = canonicalUnit(for: q.quantityType)
        guard q.quantity.is(compatibleWith: unit) else { return nil }
        let value = q.quantity.doubleValue(for: unit)
        return QuantitySample(
            start: iso(q.startDate),
            end: iso(q.endDate),
            value: value,
            unit: unit.unitString,
            type: q.quantityType.identifier,
            source: q.sourceRevision.source.bundleIdentifier,
            device: deviceModelString(q.device),
            metadata: encodeMetadata(q.metadata),
            uuid: q.uuid.uuidString
        )
    }

    static func encode(_ c: HKCategorySample) -> CategorySample {
        return CategorySample(
            start: iso(c.startDate),
            end: iso(c.endDate),
            value: categoryValueName(c),
            type: c.categoryType.identifier,
            source: c.sourceRevision.source.bundleIdentifier,
            device: deviceModelString(c.device),
            metadata: encodeMetadata(c.metadata),
            uuid: c.uuid.uuidString
        )
    }

    // MARK: - Workouts

    static func encode(
        _ w: HKWorkout,
        events: [HKWorkoutEvent]?,
        route: [CLLocation]?,
        deviceInfo: WorkoutFile.DeviceInfo
    ) -> WorkoutFile {
        var stats: [String: WorkoutFile.Stat] = [:]
        if let kcal = w.totalEnergyBurned?.doubleValue(for: .kilocalorie()) {
            stats["energy"] = .init(value: kcal, unit: "kcal")
        }
        if let m = w.totalDistance?.doubleValue(for: .meter()) {
            stats["distance"] = .init(value: m, unit: "m")
        }
        var meta = encodeMetadata(w.metadata) ?? [:]
        if let evs = events, !evs.isEmpty {
            // Encode events into metadata so we don't expand the workout schema
            // beyond what the spec describes. Spec metadata is opaque per type.
            let evArr: [MetaValue] = evs.map { ev in
                .string("\(workoutEventName(ev.type))@\(iso(ev.dateInterval.start))")
            }
            meta["events"] = .string(evArr.map {
                if case .string(let s) = $0 { return s } else { return "" }
            }.joined(separator: ","))
        }
        return WorkoutFile(
            uuid: w.uuid.uuidString,
            activity_type: workoutActivityName(w.workoutActivityType),
            start: iso(w.startDate),
            end: iso(w.endDate),
            duration_s: w.duration,
            source: w.sourceRevision.source.bundleIdentifier,
            device: deviceModelString(w.device),
            synced_at: iso(Date()),
            device_info: deviceInfo,
            stats: stats,
            metadata: meta.isEmpty ? nil : meta,
            route: route?.map { l in
                RoutePoint(
                    t: iso(l.timestamp),
                    lat: l.coordinate.latitude,
                    lon: l.coordinate.longitude,
                    alt: l.altitude,
                    h_acc: l.horizontalAccuracy,
                    v_acc: l.verticalAccuracy,
                    speed: l.speed,
                    speed_acc: l.speedAccuracy,
                    course: l.course,
                    course_acc: l.courseAccuracy
                )
            }
        )
    }

    // MARK: - Device

    /// Spec wants just the hardware model ("Watch7,1") in `device`, falling
    /// back to `hardwareVersion` if model isn't available.
    static func deviceModelString(_ d: HKDevice?) -> String? {
        guard let d else { return nil }
        return deviceModelString(name: d.name, model: d.model, hardwareVersion: d.hardwareVersion)
    }

    static func deviceModelString(name: String?, model: String?, hardwareVersion: String?) -> String? {
        if let model, !model.isEmpty { return model }
        if let hardwareVersion, !hardwareVersion.isEmpty { return hardwareVersion }
        return nil
    }

    // MARK: - Metadata

    static func encodeMetadata(_ md: [String: Any]?) -> [String: MetaValue]? {
        guard let md, !md.isEmpty else { return nil }
        var out: [String: MetaValue] = [:]
        for (k, v) in md {
            switch v {
            case let s as String: out[k] = .string(s)
            case let b as Bool: out[k] = .bool(b)
            case let n as Int: out[k] = .int(Int64(n))
            case let n as Int64: out[k] = .int(n)
            case let n as Double: out[k] = .double(n)
            case let n as NSNumber: out[k] = .double(n.doubleValue)
            case let d as Date: out[k] = .string(iso(d))
            case let q as HKQuantity: out[k] = .string(q.description)
            case let tz as TimeZone: out[k] = .string(tz.identifier)
            default: out[k] = .string(String(describing: v))
            }
        }
        return out
    }

    /// Pulls a sample's recorded timezone from its metadata if present.
    static func timezone(from md: [String: Any]?) -> TimeZone? {
        guard let md else { return nil }
        if let tz = md[HKMetadataKeyTimeZone] as? String {
            return TimeZone(identifier: tz)
        }
        if let tz = md[HKMetadataKeyTimeZone] as? TimeZone { return tz }
        return nil
    }

    // MARK: - Canonical units (verbatim from prior implementation)

    /// Best-effort canonical unit per quantity type, matching Apple Health
    /// export conventions ("count", "kcal", "bpm", "m", ...).
    static func canonicalUnit(for type: HKQuantityType) -> HKUnit {
        let id = type.identifier
        switch id {
        case HKQuantityTypeIdentifier.stepCount.rawValue,
             HKQuantityTypeIdentifier.flightsClimbed.rawValue,
             HKQuantityTypeIdentifier.pushCount.rawValue,
             HKQuantityTypeIdentifier.swimmingStrokeCount.rawValue,
             HKQuantityTypeIdentifier.numberOfTimesFallen.rawValue,
             HKQuantityTypeIdentifier.inhalerUsage.rawValue,
             HKQuantityTypeIdentifier.nikeFuel.rawValue:
            return .count()

        case HKQuantityTypeIdentifier.heartRate.rawValue,
             HKQuantityTypeIdentifier.restingHeartRate.rawValue,
             HKQuantityTypeIdentifier.walkingHeartRateAverage.rawValue,
             HKQuantityTypeIdentifier.respiratoryRate.rawValue,
             HKQuantityTypeIdentifier.cyclingCadence.rawValue,
             HKQuantityTypeIdentifier.heartRateRecoveryOneMinute.rawValue:
            return HKUnit.count().unitDivided(by: .minute())

        case HKQuantityTypeIdentifier.heartRateVariabilitySDNN.rawValue:
            return HKUnit.secondUnit(with: .milli)

        case HKQuantityTypeIdentifier.activeEnergyBurned.rawValue,
             HKQuantityTypeIdentifier.basalEnergyBurned.rawValue,
             HKQuantityTypeIdentifier.dietaryEnergyConsumed.rawValue:
            return .kilocalorie()

        case HKQuantityTypeIdentifier.appleExerciseTime.rawValue,
             HKQuantityTypeIdentifier.appleStandTime.rawValue,
             HKQuantityTypeIdentifier.appleMoveTime.rawValue,
             HKQuantityTypeIdentifier.timeInDaylight.rawValue:
            return .minute()

        case HKQuantityTypeIdentifier.distanceWalkingRunning.rawValue,
             HKQuantityTypeIdentifier.distanceCycling.rawValue,
             HKQuantityTypeIdentifier.distanceSwimming.rawValue,
             HKQuantityTypeIdentifier.distanceWheelchair.rawValue,
             HKQuantityTypeIdentifier.distanceDownhillSnowSports.rawValue,
             HKQuantityTypeIdentifier.height.rawValue,
             HKQuantityTypeIdentifier.runningStrideLength.rawValue,
             HKQuantityTypeIdentifier.walkingStepLength.rawValue,
             HKQuantityTypeIdentifier.underwaterDepth.rawValue,
             HKQuantityTypeIdentifier.waistCircumference.rawValue,
             HKQuantityTypeIdentifier.sixMinuteWalkTestDistance.rawValue:
            return .meter()

        case HKQuantityTypeIdentifier.runningVerticalOscillation.rawValue:
            return .meterUnit(with: .centi)

        case HKQuantityTypeIdentifier.runningGroundContactTime.rawValue:
            return .secondUnit(with: .milli)

        case HKQuantityTypeIdentifier.bodyMass.rawValue,
             HKQuantityTypeIdentifier.leanBodyMass.rawValue:
            return .gramUnit(with: .kilo)

        case HKQuantityTypeIdentifier.bodyFatPercentage.rawValue,
             HKQuantityTypeIdentifier.oxygenSaturation.rawValue,
             HKQuantityTypeIdentifier.walkingAsymmetryPercentage.rawValue,
             HKQuantityTypeIdentifier.walkingDoubleSupportPercentage.rawValue,
             HKQuantityTypeIdentifier.appleWalkingSteadiness.rawValue,
             HKQuantityTypeIdentifier.peripheralPerfusionIndex.rawValue:
            return .percent()

        case HKQuantityTypeIdentifier.bodyTemperature.rawValue,
             HKQuantityTypeIdentifier.basalBodyTemperature.rawValue,
             HKQuantityTypeIdentifier.waterTemperature.rawValue:
            return .degreeCelsius()

        case HKQuantityTypeIdentifier.bloodPressureSystolic.rawValue,
             HKQuantityTypeIdentifier.bloodPressureDiastolic.rawValue:
            return HKUnit.millimeterOfMercury()

        case HKQuantityTypeIdentifier.environmentalAudioExposure.rawValue,
             HKQuantityTypeIdentifier.headphoneAudioExposure.rawValue,
             HKQuantityTypeIdentifier.environmentalSoundReduction.rawValue:
            return HKUnit.decibelAWeightedSoundPressureLevel()

        case HKQuantityTypeIdentifier.uvExposure.rawValue:
            return .count()

        case HKQuantityTypeIdentifier.dietaryWater.rawValue:
            return .literUnit(with: .milli)

        case HKQuantityTypeIdentifier.forcedExpiratoryVolume1.rawValue,
             HKQuantityTypeIdentifier.forcedVitalCapacity.rawValue:
            return .liter()

        case HKQuantityTypeIdentifier.peakExpiratoryFlowRate.rawValue:
            return HKUnit.liter().unitDivided(by: .minute())

        case HKQuantityTypeIdentifier.electrodermalActivity.rawValue:
            return .siemen()

        case HKQuantityTypeIdentifier.insulinDelivery.rawValue:
            return .internationalUnit()

        case HKQuantityTypeIdentifier.physicalEffort.rawValue:
            return HKUnit.kilocalorie()
                .unitDivided(by: HKUnit.hour().unitMultiplied(by: .gramUnit(with: .kilo)))

        case HKQuantityTypeIdentifier.bloodGlucose.rawValue:
            return HKUnit.gramUnit(with: .milli).unitDivided(by: .literUnit(with: .deci))

        case HKQuantityTypeIdentifier.vo2Max.rawValue:
            return HKUnit.literUnit(with: .milli)
                .unitDivided(by: HKUnit.gramUnit(with: .kilo).unitMultiplied(by: .minute()))

        case HKQuantityTypeIdentifier.runningSpeed.rawValue,
             HKQuantityTypeIdentifier.walkingSpeed.rawValue,
             HKQuantityTypeIdentifier.cyclingSpeed.rawValue,
             HKQuantityTypeIdentifier.stairAscentSpeed.rawValue,
             HKQuantityTypeIdentifier.stairDescentSpeed.rawValue:
            return HKUnit.meter().unitDivided(by: .second())

        case HKQuantityTypeIdentifier.runningPower.rawValue,
             HKQuantityTypeIdentifier.cyclingPower.rawValue,
             HKQuantityTypeIdentifier.cyclingFunctionalThresholdPower.rawValue:
            return .watt()

        case HKQuantityTypeIdentifier.dietaryFatTotal.rawValue,
             HKQuantityTypeIdentifier.dietaryFatSaturated.rawValue,
             HKQuantityTypeIdentifier.dietaryFatPolyunsaturated.rawValue,
             HKQuantityTypeIdentifier.dietaryFatMonounsaturated.rawValue,
             HKQuantityTypeIdentifier.dietaryCholesterol.rawValue,
             HKQuantityTypeIdentifier.dietarySodium.rawValue,
             HKQuantityTypeIdentifier.dietaryCarbohydrates.rawValue,
             HKQuantityTypeIdentifier.dietaryFiber.rawValue,
             HKQuantityTypeIdentifier.dietarySugar.rawValue,
             HKQuantityTypeIdentifier.dietaryProtein.rawValue,
             HKQuantityTypeIdentifier.dietaryVitaminA.rawValue,
             HKQuantityTypeIdentifier.dietaryVitaminB6.rawValue,
             HKQuantityTypeIdentifier.dietaryVitaminB12.rawValue,
             HKQuantityTypeIdentifier.dietaryVitaminC.rawValue,
             HKQuantityTypeIdentifier.dietaryVitaminD.rawValue,
             HKQuantityTypeIdentifier.dietaryVitaminE.rawValue,
             HKQuantityTypeIdentifier.dietaryVitaminK.rawValue,
             HKQuantityTypeIdentifier.dietaryCalcium.rawValue,
             HKQuantityTypeIdentifier.dietaryIron.rawValue,
             HKQuantityTypeIdentifier.dietaryThiamin.rawValue,
             HKQuantityTypeIdentifier.dietaryRiboflavin.rawValue,
             HKQuantityTypeIdentifier.dietaryNiacin.rawValue,
             HKQuantityTypeIdentifier.dietaryFolate.rawValue,
             HKQuantityTypeIdentifier.dietaryBiotin.rawValue,
             HKQuantityTypeIdentifier.dietaryPantothenicAcid.rawValue,
             HKQuantityTypeIdentifier.dietaryPhosphorus.rawValue,
             HKQuantityTypeIdentifier.dietaryIodine.rawValue,
             HKQuantityTypeIdentifier.dietaryMagnesium.rawValue,
             HKQuantityTypeIdentifier.dietaryZinc.rawValue,
             HKQuantityTypeIdentifier.dietarySelenium.rawValue,
             HKQuantityTypeIdentifier.dietaryCopper.rawValue,
             HKQuantityTypeIdentifier.dietaryManganese.rawValue,
             HKQuantityTypeIdentifier.dietaryChromium.rawValue,
             HKQuantityTypeIdentifier.dietaryMolybdenum.rawValue,
             HKQuantityTypeIdentifier.dietaryChloride.rawValue,
             HKQuantityTypeIdentifier.dietaryPotassium.rawValue,
             HKQuantityTypeIdentifier.dietaryCaffeine.rawValue:
            return .gram()

        default:
            return .count()
        }
    }

    private static func workoutActivityName(_ t: HKWorkoutActivityType) -> String {
        switch t {
        case .walking: return "walking"
        case .running: return "running"
        case .cycling: return "cycling"
        case .swimming: return "swimming"
        case .hiking: return "hiking"
        case .yoga: return "yoga"
        case .functionalStrengthTraining: return "strength-training"
        case .traditionalStrengthTraining: return "strength-training"
        case .crossTraining: return "cross-training"
        case .elliptical: return "elliptical"
        case .rowing: return "rowing"
        case .stairClimbing: return "stair-climbing"
        case .highIntensityIntervalTraining: return "hiit"
        case .dance: return "dance"
        case .pilates: return "pilates"
        case .badminton: return "badminton"
        case .other: return "other"
        default: return "type-\(t.rawValue)"
        }
    }

    private static func workoutEventName(_ t: HKWorkoutEventType) -> String {
        switch t {
        case .pause: return "pause"
        case .resume: return "resume"
        case .lap: return "lap"
        case .marker: return "marker"
        case .motionPaused: return "motion-paused"
        case .motionResumed: return "motion-resumed"
        case .segment: return "segment"
        case .pauseOrResumeRequest: return "pause-or-resume-request"
        @unknown default: return "unknown"
        }
    }

    private static func categoryValueName(_ c: HKCategorySample) -> String {
        // Sleep analysis is the only category type we explicitly name today;
        // for everything else, we fall back to the raw integer-as-string.
        if c.categoryType.identifier == HKCategoryTypeIdentifier.sleepAnalysis.rawValue,
           let v = HKCategoryValueSleepAnalysis(rawValue: c.value) {
            switch v {
            case .inBed:             return "inBed"
            case .asleep:            return "asleepUnspecified"
            case .awake:             return "awake"
            case .asleepCore:        return "asleepCore"
            case .asleepDeep:        return "asleepDeep"
            case .asleepREM:         return "asleepREM"
            case .asleepUnspecified: return "asleepUnspecified"
            @unknown default:        return "unknown-\(c.value)"
            }
        }
        return String(c.value)
    }
}
