import Foundation
import HealthKit
import CoreLocation

/// Converts HealthKit samples to `HealthSample` rows that are byte-compatible
/// with the existing `myhealth.apple_health.v1` JSONL schema produced by the
/// Python CLI. Date formatting matches the XML export's
/// `"yyyy-MM-dd HH:mm:ss xxxx"` shape (e.g. `"2026-05-01 09:00:00 +0000"`).
struct SampleEncoder {

    static let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(identifier: "UTC")
        df.dateFormat = "yyyy-MM-dd HH:mm:ss xxxx"
        return df
    }()

    static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func format(_ d: Date) -> String { dateFormatter.string(from: d) }
    static func iso(_ d: Date) -> String { isoFormatter.string(from: d) }

    // MARK: - Quantity samples (steps, heart rate, distance, …)

    static func encode(_ q: HKQuantitySample) -> HealthSample {
        let unit = canonicalUnit(for: q.quantityType)
        let value = q.quantity.doubleValue(for: unit)
        return HealthSample(
            _kind: .record,
            type: q.quantityType.identifier,
            unit: unit.unitString,
            value: stringify(value),
            start_date: format(q.startDate),
            end_date: format(q.endDate),
            creation_date: format(sourceCreationDate(q)),
            source_name: q.sourceRevision.source.name,
            source_version: q.sourceRevision.version,
            device: deviceString(q.device),
            uuid: q.uuid.uuidString,
            metadata: encodeMetadata(q.metadata)
        )
    }

    static func encode(_ c: HKCategorySample) -> HealthSample {
        return HealthSample(
            _kind: .record,
            type: c.categoryType.identifier,
            unit: nil,
            value: String(c.value),
            start_date: format(c.startDate),
            end_date: format(c.endDate),
            creation_date: format(sourceCreationDate(c)),
            source_name: c.sourceRevision.source.name,
            source_version: c.sourceRevision.version,
            device: deviceString(c.device),
            uuid: c.uuid.uuidString,
            metadata: encodeMetadata(c.metadata)
        )
    }

    // MARK: - Workouts

    static func encode(
        _ w: HKWorkout,
        events: [HKWorkoutEvent]?,
        route: [CLLocation]?
    ) -> HealthSample {
        let kcal = w.totalEnergyBurned?.doubleValue(for: .kilocalorie())
        let meters = w.totalDistance?.doubleValue(for: .meter())
        return HealthSample(
            _kind: .workout,
            type: "HKWorkoutTypeIdentifier",
            unit: nil,
            value: nil,
            start_date: format(w.startDate),
            end_date: format(w.endDate),
            creation_date: format(sourceCreationDate(w)),
            source_name: w.sourceRevision.source.name,
            source_version: w.sourceRevision.version,
            device: deviceString(w.device),
            uuid: w.uuid.uuidString,
            metadata: encodeMetadata(w.metadata),
            workout_activity_type: workoutActivityName(w.workoutActivityType),
            duration: w.duration,
            total_energy_burned: kcal,
            total_distance: meters,
            events: events?.map { ev in
                WorkoutEvent(
                    type: workoutEventName(ev.type),
                    date: format(ev.dateInterval.start),
                    duration: ev.dateInterval.duration,
                    metadata: encodeMetadata(ev.metadata)
                )
            },
            route_locations: route?.map { l in
                RouteLocation(
                    lat: l.coordinate.latitude,
                    lon: l.coordinate.longitude,
                    alt: l.altitude,
                    ts: iso(l.timestamp),
                    h_accuracy: l.horizontalAccuracy,
                    v_accuracy: l.verticalAccuracy,
                    speed: l.speed,
                    course: l.course
                )
            }
        )
    }

    // MARK: - ECG

    static func encode(_ e: HKElectrocardiogram, voltage: [ECGVoltageSample]?) -> HealthSample {
        let avgHR = e.averageHeartRate?.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
        return HealthSample(
            _kind: .ecg,
            type: HKObjectType.electrocardiogramType().identifier,
            unit: "V",
            value: nil,
            start_date: format(e.startDate),
            end_date: format(e.endDate),
            creation_date: format(sourceCreationDate(e)),
            source_name: e.sourceRevision.source.name,
            source_version: e.sourceRevision.version,
            device: deviceString(e.device),
            uuid: e.uuid.uuidString,
            metadata: encodeMetadata(e.metadata),
            ecg_samples: voltage,
            ecg_classification: ecgClassificationName(e.classification),
            ecg_average_heart_rate: avgHR,
            ecg_sampling_frequency: e.samplingFrequency?.doubleValue(for: .hertz())
        )
    }

    // MARK: - Clinical Records

    static func encode(_ c: HKClinicalRecord) -> HealthSample {
        // FHIR JSON body lives inside `metadata` under a private key — but
        // the public surface is the resource itself. We expose its FHIR
        // resource type and identifier; the full JSON can be reconstituted
        // from `c.fhirResource?.data`.
        var meta: [String: AnyCodableValue] = [:]
        if let fhir = c.fhirResource {
            meta["resource_type"] = .string(fhir.resourceType.rawValue)
            meta["identifier"] = .string(fhir.identifier ?? "")
            if let body = String(data: fhir.data, encoding: .utf8) {
                meta["fhir_json"] = .string(body)
            }
            meta["fhir_version"] = .string(fhir.fhirVersion.stringRepresentation)
        }
        meta["display_name"] = .string(c.displayName)
        return HealthSample(
            _kind: .clinical,
            type: c.clinicalType.identifier,
            unit: nil,
            value: nil,
            start_date: format(c.startDate),
            end_date: format(c.endDate),
            creation_date: format(sourceCreationDate(c)),
            source_name: c.sourceRevision.source.name,
            source_version: c.sourceRevision.version,
            device: deviceString(c.device),
            uuid: c.uuid.uuidString,
            metadata: meta
        )
    }

    // MARK: - ActivitySummary

    static func encode(_ a: HKActivitySummary) -> HealthSample {
        var components = a.dateComponents(for: Calendar(identifier: .gregorian))
        components.timeZone = TimeZone(identifier: "UTC")
        let dayString: String
        if let y = components.year, let m = components.month, let d = components.day {
            dayString = String(format: "%04d-%02d-%02d", y, m, d)
        } else {
            dayString = ""
        }
        let active = a.activeEnergyBurned.doubleValue(for: .kilocalorie())
        let move = a.appleMoveTime.doubleValue(for: .minute())
        let exerciseGoal = a.appleExerciseTimeGoal.doubleValue(for: .minute())
        let standGoal = a.appleStandHoursGoal.doubleValue(for: .count())
        var meta: [String: AnyCodableValue] = [
            "active_energy_burned_goal": .double(a.activeEnergyBurnedGoal.doubleValue(for: .kilocalorie())),
            "apple_exercise_time": .double(a.appleExerciseTime.doubleValue(for: .minute())),
            "apple_exercise_time_goal": .double(exerciseGoal),
            "apple_stand_hours": .double(a.appleStandHours.doubleValue(for: .count())),
            "apple_stand_hours_goal": .double(standGoal),
            "apple_move_time": .double(move),
            "apple_move_time_goal": .double(a.appleMoveTimeGoal.doubleValue(for: .minute())),
        ]
        if dayString.isEmpty { meta.removeValue(forKey: "apple_move_time") }
        return HealthSample(
            _kind: .activitySummary,
            type: "HKActivitySummaryTypeIdentifier",
            unit: nil,
            value: stringify(active),
            start_date: dayString,
            end_date: dayString,
            creation_date: nil,
            source_name: nil,
            source_version: nil,
            device: nil,
            uuid: nil,
            metadata: meta,
            date_components: dayString
        )
    }

    // MARK: - Helpers

    private static func sourceCreationDate(_ s: HKObject) -> Date {
        // HealthKit doesn't expose creation date as a property on every type.
        // The stored metadata key `HKMetadataKeyExternalUUID` is sometimes used
        // but the closest universal proxy is `startDate`. We fall back to
        // `startDate` when no other signal exists.
        return (s as? HKSample)?.startDate ?? Date()
    }

    private static func deviceString(_ d: HKDevice?) -> String? {
        guard let d else { return nil }
        var parts: [String] = []
        if let n = d.name { parts.append("name=\(n)") }
        if let m = d.model { parts.append("model=\(m)") }
        if let mfg = d.manufacturer { parts.append("manufacturer=\(mfg)") }
        if let hw = d.hardwareVersion { parts.append("hardware=\(hw)") }
        if let sw = d.softwareVersion { parts.append("software=\(sw)") }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    private static func encodeMetadata(_ md: [String: Any]?) -> [String: AnyCodableValue]? {
        guard let md, !md.isEmpty else { return nil }
        var out: [String: AnyCodableValue] = [:]
        for (k, v) in md {
            switch v {
            case let s as String: out[k] = .string(s)
            case let b as Bool: out[k] = .bool(b)
            case let n as Int: out[k] = .int(Int64(n))
            case let n as Int64: out[k] = .int(n)
            case let n as Double: out[k] = .double(n)
            case let n as NSNumber: out[k] = .double(n.doubleValue)
            case let d as Date: out[k] = .string(format(d))
            case let q as HKQuantity: out[k] = .string(q.description)
            default: out[k] = .string(String(describing: v))
            }
        }
        return out
    }

    /// Format a `Double` the way Apple's XML export does: integers without
    /// trailing `.0`, fractions with no spurious precision.
    static func stringify(_ v: Double) -> String {
        if v.rounded() == v, abs(v) < 1e16 {
            return String(Int64(v))
        }
        return String(v)
    }

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
             HKQuantityTypeIdentifier.sixMinuteWalkTestDistance.rawValue:
            return .meter()

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

        default:
            return .count()
        }
    }

    private static func workoutActivityName(_ t: HKWorkoutActivityType) -> String {
        // Apple Health export uses the raw `HKWorkoutActivityType*` enum name.
        // We can't introspect the Swift enum at runtime, so we keep a small
        // map for common values and fall back to the raw int otherwise.
        switch t {
        case .walking: return "HKWorkoutActivityTypeWalking"
        case .running: return "HKWorkoutActivityTypeRunning"
        case .cycling: return "HKWorkoutActivityTypeCycling"
        case .swimming: return "HKWorkoutActivityTypeSwimming"
        case .hiking: return "HKWorkoutActivityTypeHiking"
        case .yoga: return "HKWorkoutActivityTypeYoga"
        case .functionalStrengthTraining: return "HKWorkoutActivityTypeFunctionalStrengthTraining"
        case .traditionalStrengthTraining: return "HKWorkoutActivityTypeTraditionalStrengthTraining"
        case .crossTraining: return "HKWorkoutActivityTypeCrossTraining"
        case .elliptical: return "HKWorkoutActivityTypeElliptical"
        case .rowing: return "HKWorkoutActivityTypeRowing"
        case .stairClimbing: return "HKWorkoutActivityTypeStairClimbing"
        case .highIntensityIntervalTraining: return "HKWorkoutActivityTypeHighIntensityIntervalTraining"
        case .dance: return "HKWorkoutActivityTypeDance"
        case .pilates: return "HKWorkoutActivityTypePilates"
        case .other: return "HKWorkoutActivityTypeOther"
        default: return "HKWorkoutActivityType\(t.rawValue)"
        }
    }

    private static func workoutEventName(_ t: HKWorkoutEventType) -> String {
        switch t {
        case .pause: return "HKWorkoutEventTypePause"
        case .resume: return "HKWorkoutEventTypeResume"
        case .lap: return "HKWorkoutEventTypeLap"
        case .marker: return "HKWorkoutEventTypeMarker"
        case .motionPaused: return "HKWorkoutEventTypeMotionPaused"
        case .motionResumed: return "HKWorkoutEventTypeMotionResumed"
        case .segment: return "HKWorkoutEventTypeSegment"
        case .pauseOrResumeRequest: return "HKWorkoutEventTypePauseOrResumeRequest"
        @unknown default: return "HKWorkoutEventType\(t.rawValue)"
        }
    }

    private static func ecgClassificationName(_ c: HKElectrocardiogram.Classification) -> String {
        switch c {
        case .notSet: return "notSet"
        case .sinusRhythm: return "sinusRhythm"
        case .atrialFibrillation: return "atrialFibrillation"
        case .inconclusiveLowHeartRate: return "inconclusiveLowHeartRate"
        case .inconclusiveHighHeartRate: return "inconclusiveHighHeartRate"
        case .inconclusivePoorReading: return "inconclusivePoorReading"
        case .inconclusiveOther: return "inconclusiveOther"
        case .unrecognized: return "unrecognized"
        @unknown default: return "unknown"
        }
    }
}
