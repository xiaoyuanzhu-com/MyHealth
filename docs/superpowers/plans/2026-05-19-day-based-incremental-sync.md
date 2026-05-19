# Day-Based Incremental Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace MyHealth's batch-based JSONL sync with per-day-per-type JSON snapshots, plus a pausable/abortable/resumable upload loop that checkpoints progress after each day.

**Architecture:** Read all new HealthKit samples up-front using existing per-type `HKQueryAnchor`s, then bucket samples into per-day groups (using each sample's own `HKTimeZone` metadata for the local date). Walk the days oldest-first, and for each (day, type) pair: fetch the existing remote snapshot, merge by UUID, upload back. The full bucketed state is persisted to disk (`Application Support/sync-run-state.json`) so pause/abort/kill all leave the user in a recoverable state — resume picks up at the next un-uploaded day. Anchors advance only on full-run success.

**Tech Stack:** Swift 5.9+, SwiftUI, HealthKit, XCTest. Build via `xcodebuild`. iOS 17+.

**Scope decisions (call out for user redirect):**

1. **ECG, clinical records, and activity summaries are removed.** The new spec (`README.md` "Apple Health Data") does not cover them, and inventing schema unilaterally is risky. The HealthKitReader will stop reading these types, and their encoder code/DTO fields will be deleted. A follow-up plan can re-add them once their file shape is specified.
2. **Pause/abort semantics**: Pause halts at the next checkpoint and persists progress. Abort halts and deletes `sync-run-state.json`. Both are exposed as separate UI affordances.
3. **Day boundary**: Sample's `HKTimeZone` metadata when present, otherwise device's current `TimeZone.current`. Workouts use the workout's own `metadata[HKMetadataKeyTimeZone]` then fall back to device.
4. **Anchor advancement is per-run, not per-day.** The spec says "update anchor per day" — but HealthKit's `HKAnchoredObjectQuery` returns one anchor per batch, not intermediate per-day anchors. We treat the **per-day state checkpoint** as the resumable unit; HK anchors advance once at end-of-run. If interrupted, on next run we re-read from the previous anchor (cheap, idempotent due to UUID dedup on snapshot merge).
5. **Snapshot merge by UUID**: every sample HealthKit returns has a UUID. New + remote samples are deduped by UUID, with the new value winning on conflict. Then sorted by `(start, end, source)` per spec.
6. **Workouts are atomic files**: `workout-<UUID>.json` — no merge needed (UUID is in filename).

---

## File Structure

**Create:**
- `MyHealth/Model/DaySample.swift` — Codable DTOs matching the new JSON shape (`QuantitySample`, `CategorySample`, `WorkoutFile`, `RoutePoint`, `DayFile`).
- `MyHealth/Model/SyncRunState.swift` — pause/resume state: anchors-at-start, day buckets, completed-day cursor.
- `MyHealth/Sync/TypeNaming.swift` — pure helpers: HK type identifier → kebab-case filename.
- `MyHealth/Sync/DayBucketer.swift` — pure: `[(HKSample, HKTimeZone?)] → [DayKey: [Sample]]`.
- `MyHealth/Sync/SnapshotMerger.swift` — pure: merge incoming + remote samples (dedup by UUID, sorted).
- `MyHealth/Sync/SyncRunStore.swift` — load/save/clear `sync-run-state.json` in Application Support.
- `Tests/TypeNamingTests.swift`
- `Tests/DayBucketerTests.swift`
- `Tests/SnapshotMergerTests.swift`
- `Tests/DaySampleTests.swift`
- `Tests/SyncRunStateTests.swift`

**Modify:**
- `MyHealth/Health/SampleEncoder.swift` — replace v1 row encoders with new-shape encoders (returns `QuantitySample`/`CategorySample`/`WorkoutFile`).
- `MyHealth/Health/HealthKitReader.swift` — remove ECG/clinical/activity-summary reads; return new-shape DTOs grouped by `(type, day)`.
- `MyHealth/Sync/SyncCoordinator.swift` — replace `runOnce` with new state machine: read → bucket → persist state → day-loop with pause checks → finalize anchors. Add `pause()`, `abort()`, `resume()`.
- `MyHealth/Sync/AnchorStore.swift` — keep anchor encode/decode + cache; remove manifest dependency.
- `MyHealth/Sync/BackgroundSync.swift` — call `pause()` on task expiration instead of `cancel()`.
- `MyHealth/MyLifeDB/MyLifeDBClient.swift` — no change (already has `getFile`).
- `MyHealth/GoogleDrive/GoogleDriveClient.swift` — add `getFile(relativePath:)` returning `Data?`.
- `MyHealth/UI/SyncTab.swift` — replace single Sync button with Sync/Pause/Resume + Abort + per-day progress display.
- `Tests/HealthSampleTests.swift` — replace with new-format encoding tests.
- `README.md` — update Tests section to list new test files.

**Delete:**
- `MyHealth/Model/SyncManifest.swift`
- `MyHealth/Sync/BatchWriter.swift`
- `MyHealth/Model/HealthSample.swift` (replaced by DTOs in `DaySample.swift`)
- `Tests/ManifestTests.swift`

---

## Build & Test Commands

Throughout the plan:

- **Build & full test suite:**
  ```
  xcodebuild test -scheme MyHealth -destination 'platform=iOS Simulator,name=iPhone 15'
  ```
- **Run a single test class:**
  ```
  xcodebuild test -scheme MyHealth -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:MyHealthTests/<ClassName>
  ```
- **Run a single test method:**
  ```
  xcodebuild test -scheme MyHealth -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:MyHealthTests/<ClassName>/<methodName>
  ```

These tests are pure-Swift logic — no HealthKit, no network — so the simulator does not need permissions granted.

---

## Task 1: TypeNaming helper (HK identifier → kebab-case filename)

**Files:**
- Create: `MyHealth/Sync/TypeNaming.swift`
- Test: `Tests/TypeNamingTests.swift`

Why: filenames in the new layout are kebab-case versions of the HK type identifier with the `HKQuantityTypeIdentifier` / `HKCategoryTypeIdentifier` prefix stripped (e.g. `HKQuantityTypeIdentifierStepCount` → `step-count.json`). Centralising this conversion makes the rest of the pipeline trivial.

- [ ] **Step 1.1: Write the failing tests**

Create `Tests/TypeNamingTests.swift`:

```swift
import XCTest
@testable import MyHealth

final class TypeNamingTests: XCTestCase {

    func testStripsQuantityPrefix() {
        XCTAssertEqual(TypeNaming.filename(for: "HKQuantityTypeIdentifierStepCount"),
                       "step-count.json")
    }

    func testStripsCategoryPrefix() {
        XCTAssertEqual(TypeNaming.filename(for: "HKCategoryTypeIdentifierSleepAnalysis"),
                       "sleep-analysis.json")
    }

    func testMultipleCamelHumps() {
        XCTAssertEqual(TypeNaming.filename(for: "HKQuantityTypeIdentifierHeartRateVariabilitySDNN"),
                       "heart-rate-variability-sdnn.json")
    }

    func testAcronymRunStaysLower() {
        XCTAssertEqual(TypeNaming.filename(for: "HKQuantityTypeIdentifierVO2Max"),
                       "vo2-max.json")
    }

    func testDietaryProducesReadableName() {
        XCTAssertEqual(TypeNaming.filename(for: "HKQuantityTypeIdentifierDietaryVitaminB12"),
                       "dietary-vitamin-b12.json")
    }

    func testUnknownPrefixIsKebabbed() {
        // Defensive: any unknown prefix still gets kebab-cased without error.
        XCTAssertEqual(TypeNaming.filename(for: "HKCorrelationTypeIdentifierBloodPressure"),
                       "blood-pressure.json")
    }

    func testWorkoutFilename() {
        XCTAssertEqual(TypeNaming.workoutFilename(uuid: "A1B2C3D4-0000-0000-0000-000000000001"),
                       "workout-A1B2C3D4-0000-0000-0000-000000000001.json")
    }
}
```

- [ ] **Step 1.2: Run tests to verify they fail**

Run: `xcodebuild test -scheme MyHealth -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:MyHealthTests/TypeNamingTests`
Expected: FAIL with "Cannot find 'TypeNaming' in scope" (or similar).

- [ ] **Step 1.3: Implement `TypeNaming`**

Create `MyHealth/Sync/TypeNaming.swift`:

```swift
import Foundation

/// Maps a HealthKit type identifier (e.g. `HKQuantityTypeIdentifierStepCount`)
/// to the kebab-case filename used in the new per-day layout (e.g.
/// `step-count.json`). Recognised prefixes are stripped; everything after the
/// last `Identifier` token is camelCase-to-kebab-case converted.
enum TypeNaming {

    /// Filename for a per-day type bucket (e.g. `"step-count.json"`).
    static func filename(for typeIdentifier: String) -> String {
        let stem = kebab(stripPrefix(typeIdentifier))
        return "\(stem).json"
    }

    /// Filename for a single workout event (UUID is preserved verbatim).
    static func workoutFilename(uuid: String) -> String {
        return "workout-\(uuid).json"
    }

    // MARK: - Internals

    private static let knownPrefixes = [
        "HKQuantityTypeIdentifier",
        "HKCategoryTypeIdentifier",
        "HKCorrelationTypeIdentifier",
        "HKClinicalTypeIdentifier",
        "HKDataTypeIdentifier",
    ]

    private static func stripPrefix(_ id: String) -> String {
        for p in knownPrefixes where id.hasPrefix(p) {
            return String(id.dropFirst(p.count))
        }
        return id
    }

    /// CamelCase → kebab-case. Treats runs of uppercase as one token
    /// ("SDNN" → "sdnn", "VO2Max" → "vo2-max").
    static func kebab(_ s: String) -> String {
        guard !s.isEmpty else { return "" }
        var out = ""
        let chars = Array(s)
        for i in chars.indices {
            let c = chars[i]
            if c.isUppercase {
                // Insert a dash before this uppercase if:
                //  - it's not the very start, AND
                //  - the previous char was lowercase or digit, OR
                //  - the next char is lowercase (start of a new word after an acronym)
                if i > 0 {
                    let prev = chars[i - 1]
                    let nextLower = (i + 1 < chars.count) && chars[i + 1].isLowercase
                    if prev.isLowercase || prev.isNumber || nextLower {
                        out.append("-")
                    }
                }
                out.append(Character(c.lowercased()))
            } else {
                out.append(c)
            }
        }
        return out
    }
}
```

- [ ] **Step 1.4: Run tests to verify they pass**

Run: `xcodebuild test -scheme MyHealth -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:MyHealthTests/TypeNamingTests`
Expected: PASS (all 7 tests).

- [ ] **Step 1.5: Commit**

```bash
git add MyHealth/Sync/TypeNaming.swift Tests/TypeNamingTests.swift
git commit -m "$(cat <<'EOF'
feat(sync): add TypeNaming for kebab-case file names

First piece of the day-based incremental-sync rewrite. Converts HK type
identifiers into the kebab-case filenames the new upload layout uses.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: New sample DTOs (DaySample.swift)

**Files:**
- Create: `MyHealth/Model/DaySample.swift`
- Test: `Tests/DaySampleTests.swift`

Why: every JSON file written by the new sync has a fixed top-level shape (`date`, `type`, `timezone`, `unit?`, `samples`), and each sample is a small struct. We need Codable types that produce byte-for-byte the JSON shape spec'd in `README.md`. Workouts have their own envelope.

- [ ] **Step 2.1: Write the failing tests**

Create `Tests/DaySampleTests.swift`:

```swift
import XCTest
@testable import MyHealth

final class DaySampleTests: XCTestCase {

    private let enc: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    func testQuantitySampleEncodesAllFields() throws {
        let s = QuantitySample(
            start: "2026-01-17T16:37:10.901Z",
            end: "2026-01-17T16:46:20.452Z",
            value: 200,
            unit: "count",
            type: "HKQuantityTypeIdentifierStepCount",
            source: "com.apple.health.37928A11",
            device: "Watch7,1",
            metadata: nil
        )
        let json = try String(data: enc.encode(s), encoding: .utf8) ?? ""
        XCTAssertEqual(json, #"{"device":"Watch7,1","end":"2026-01-17T16:46:20.452Z","source":"com.apple.health.37928A11","start":"2026-01-17T16:37:10.901Z","type":"HKQuantityTypeIdentifierStepCount","unit":"count","value":200}"#)
    }

    func testQuantitySampleOmitsAbsentDeviceAndMetadata() throws {
        let s = QuantitySample(
            start: "2026-01-17T16:37:10.901Z",
            end: "2026-01-17T16:46:20.452Z",
            value: 72.5,
            unit: "count/min",
            type: "HKQuantityTypeIdentifierHeartRate",
            source: "com.apple.health",
            device: nil,
            metadata: nil
        )
        let json = try String(data: enc.encode(s), encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains("\"device\""))
        XCTAssertFalse(json.contains("\"metadata\""))
        XCTAssertTrue(json.contains("\"value\":72.5"))
    }

    func testCategorySampleHasStringValue() throws {
        let s = CategorySample(
            start: "2026-01-17T17:24:19.656Z",
            end: "2026-01-17T17:27:49.348Z",
            value: "asleepCore",
            type: "HKCategoryTypeIdentifierSleepAnalysis",
            source: "com.apple.health",
            device: "Watch7,1",
            metadata: ["HKTimeZone": .string("Asia/Shanghai")]
        )
        let data = try enc.encode(s)
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains(#""value":"asleepCore""#))
        XCTAssertTrue(json.contains(#""metadata":{"HKTimeZone":"Asia/Shanghai"}"#))
    }

    func testDayFileQuantityEnvelope() throws {
        let envelope = DayFile.quantity(
            date: "2026-01-18",
            type: "HKQuantityTypeIdentifierStepCount",
            timezone: "Asia/Shanghai",
            unit: "count",
            samples: []
        )
        let json = try String(data: enc.encode(envelope), encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains(#""date":"2026-01-18""#))
        XCTAssertTrue(json.contains(#""timezone":"Asia/Shanghai""#))
        XCTAssertTrue(json.contains(#""unit":"count""#))
        XCTAssertTrue(json.contains(#""samples":[]"#))
    }

    func testDayFileCategoryEnvelopeOmitsUnit() throws {
        let envelope = DayFile.category(
            date: "2026-01-18",
            type: "HKCategoryTypeIdentifierSleepAnalysis",
            timezone: "Asia/Shanghai",
            samples: []
        )
        let json = try String(data: enc.encode(envelope), encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains("\"unit\""))
    }

    func testWorkoutFileEncodesRouteAndStats() throws {
        let wf = WorkoutFile(
            uuid: "A1B2C3D4",
            activity_type: "running",
            start: "2026-01-18T01:30:00.000Z",
            end: "2026-01-18T02:15:00.000Z",
            duration_s: 2700,
            source: "com.apple.health",
            device: "Watch7,1",
            synced_at: "2026-01-18T10:00:00.000Z",
            device_info: WorkoutFile.DeviceInfo(name: "Apple Watch", model: "Watch7,1", systemVersion: "11.0"),
            stats: ["distance": .init(value: 5000, unit: "m")],
            metadata: nil,
            route: [
                RoutePoint(t: "2026-01-18T01:30:05.123Z", lat: 31.234, lon: 121.456,
                           alt: 12.4, h_acc: 3.2, v_acc: 4.1, speed: 2.8,
                           speed_acc: 0.3, course: 273.5, course_acc: 5.0)
            ]
        )
        let json = try String(data: enc.encode(wf), encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains(#""activity_type":"running""#))
        XCTAssertTrue(json.contains(#""duration_s":2700"#))
        XCTAssertTrue(json.contains(#""stats":{"distance":{"unit":"m","value":5000}}"#))
        XCTAssertTrue(json.contains(#""course":273.5"#))
    }

    func testWorkoutFileRouteNullForIndoor() throws {
        let wf = WorkoutFile(
            uuid: "A", activity_type: "yoga",
            start: "2026-01-18T01:30:00.000Z", end: "2026-01-18T02:00:00.000Z",
            duration_s: 1800, source: "com.apple.health",
            device: nil, synced_at: "2026-01-18T10:00:00.000Z",
            device_info: WorkoutFile.DeviceInfo(name: "iPhone", model: "iPhone16,2", systemVersion: "17.4"),
            stats: [:], metadata: nil, route: nil
        )
        let json = try String(data: enc.encode(wf), encoding: .utf8) ?? ""
        // route is explicitly null per spec, not omitted
        XCTAssertTrue(json.contains(#""route":null"#))
    }
}
```

- [ ] **Step 2.2: Run tests to verify they fail**

Run: `xcodebuild test -scheme MyHealth -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:MyHealthTests/DaySampleTests`
Expected: FAIL — none of these types exist yet.

- [ ] **Step 2.3: Implement DTOs**

Create `MyHealth/Model/DaySample.swift`:

```swift
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
    let metadata: [String: AnyCodableValue]?
    /// HealthKit UUID — used to dedup during snapshot merge. NOT encoded into
    /// the JSON output (the spec doesn't include it on individual samples).
    /// Marked optional so test fixtures can omit it.
    let uuid: String?

    var id: String { uuid ?? "\(start)|\(end)|\(source)" }

    init(start: String, end: String, value: Double, unit: String, type: String,
         source: String, device: String?, metadata: [String: AnyCodableValue]?,
         uuid: String? = nil) {
        self.start = start; self.end = end; self.value = value; self.unit = unit
        self.type = type; self.source = source; self.device = device
        self.metadata = metadata; self.uuid = uuid
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
    let metadata: [String: AnyCodableValue]?
    let uuid: String?

    var id: String { uuid ?? "\(start)|\(end)|\(source)" }

    init(start: String, end: String, value: String, type: String,
         source: String, device: String?, metadata: [String: AnyCodableValue]?,
         uuid: String? = nil) {
        self.start = start; self.end = end; self.value = value
        self.type = type; self.source = source; self.device = device
        self.metadata = metadata; self.uuid = uuid
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
    let metadata: [String: AnyCodableValue]?
    let route: [RoutePoint]?         // nil = field omitted; spec wants explicit null for indoor

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

/// Reusable JSON-primitive wrapper for HealthKit metadata values. Lifted
/// verbatim from the prior HealthSample.swift — same shape, kept so existing
/// tests and metadata encoders compile.
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
```

- [ ] **Step 2.4: Run tests to verify they pass**

Run: `xcodebuild test -scheme MyHealth -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:MyHealthTests/DaySampleTests`
Expected: PASS (all 7 tests).

Note: `MyHealth/Model/HealthSample.swift` still defines an `AnyCodableValue` and will conflict with the one we just added. Don't delete `HealthSample.swift` yet — it's still referenced by the old `SampleEncoder.swift` and `SyncCoordinator.swift`. To make this task compile, **rename the new enum** in `DaySample.swift` to `AnyCodableValue` only after we delete the old `HealthSample.swift` in Task 15.

For now, **use a placeholder name to avoid the collision**: in `DaySample.swift`, rename the enum `AnyCodableValue` → `MetaValue`, and update the test file (`metadata: ["HKTimeZone": .string(...)]` becomes `metadata: ["HKTimeZone": MetaValue.string(...)]`) and all property types (`[String: MetaValue]?`). We'll rename to `AnyCodableValue` in Task 15 when the old file is deleted.

Apply that rename now before re-running tests:

```bash
# In DaySample.swift and DaySampleTests.swift only:
sed -i '' 's/AnyCodableValue/MetaValue/g' MyHealth/Model/DaySample.swift Tests/DaySampleTests.swift
```

Then re-run the test command above. Expected: PASS.

- [ ] **Step 2.5: Commit**

```bash
git add MyHealth/Model/DaySample.swift Tests/DaySampleTests.swift
git commit -m "$(cat <<'EOF'
feat(sync): add DaySample DTOs for per-day JSON layout

Codable types for the new upload format: DayFile envelope, QuantitySample,
CategorySample, WorkoutFile, RoutePoint. Uses a temporary MetaValue enum
name to avoid collision with the legacy HealthSample.swift; will rename
back to AnyCodableValue once that file is deleted (Task 15).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Day bucketing helper

**Files:**
- Create: `MyHealth/Sync/DayBucketer.swift`
- Test: `Tests/DayBucketerTests.swift`

Why: every sample has a `start` date and (optionally) an `HKTimeZone` metadata key. To put it into the right `YYYY/MM/DD/` directory, we need to convert that UTC start date into the local-time date in the sample's own timezone. Pure logic — easy to unit test.

- [ ] **Step 3.1: Write the failing tests**

Create `Tests/DayBucketerTests.swift`:

```swift
import XCTest
@testable import MyHealth

final class DayBucketerTests: XCTestCase {

    func testDateInSampleTimezone() {
        // 2026-01-18T01:00:00 UTC = 2026-01-18 09:00:00 in Asia/Shanghai (UTC+8)
        let utc = Date(timeIntervalSince1970: 1768867200)
        let key = DayBucketer.dayKey(start: utc, timezone: TimeZone(identifier: "Asia/Shanghai"))
        XCTAssertEqual(key.date, "2026-01-18")
        XCTAssertEqual(key.timezone, "Asia/Shanghai")
    }

    func testCrossesMidnightInLocalTime() {
        // 2026-01-18T17:00:00 UTC = 2026-01-19 01:00:00 in Asia/Shanghai (UTC+8).
        // Should bucket to Jan 19, NOT Jan 18.
        let utc = Date(timeIntervalSince1970: 1768928400)
        let key = DayBucketer.dayKey(start: utc, timezone: TimeZone(identifier: "Asia/Shanghai"))
        XCTAssertEqual(key.date, "2026-01-19")
    }

    func testNilTimezoneFallsBackToDeviceCurrent() {
        let utc = Date(timeIntervalSince1970: 1768867200)
        let key = DayBucketer.dayKey(start: utc, timezone: nil)
        // We can't assert a specific date because TimeZone.current depends on
        // the test runner, but we CAN assert the timezone string matches.
        XCTAssertEqual(key.timezone, TimeZone.current.identifier)
    }

    func testPathComponents() {
        let key = DayBucketer.DayKey(date: "2026-01-18", timezone: "Asia/Shanghai")
        XCTAssertEqual(key.pathPrefix, "2026/01/18")
    }
}
```

- [ ] **Step 3.2: Run tests to verify they fail**

Run: `xcodebuild test -scheme MyHealth -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:MyHealthTests/DayBucketerTests`
Expected: FAIL — `DayBucketer` not defined.

- [ ] **Step 3.3: Implement DayBucketer**

Create `MyHealth/Sync/DayBucketer.swift`:

```swift
import Foundation

/// Decides which day-directory a sample belongs to. Days are local to the
/// sample's own `HKTimeZone` metadata when available; otherwise we fall back
/// to the device's current timezone. The same key is also used to build the
/// `YYYY/MM/DD` path under `apple-health/`.
enum DayBucketer {

    struct DayKey: Hashable, Codable {
        let date: String       // "YYYY-MM-DD"
        let timezone: String   // IANA identifier

        /// "2026/01/18"
        var pathPrefix: String {
            let parts = date.split(separator: "-")
            guard parts.count == 3 else { return date }
            return "\(parts[0])/\(parts[1])/\(parts[2])"
        }
    }

    static func dayKey(start: Date, timezone: TimeZone?) -> DayKey {
        let tz = timezone ?? TimeZone.current
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let comps = cal.dateComponents([.year, .month, .day], from: start)
        let dateString = String(format: "%04d-%02d-%02d",
                                comps.year ?? 1970,
                                comps.month ?? 1,
                                comps.day ?? 1)
        return DayKey(date: dateString, timezone: tz.identifier)
    }
}
```

- [ ] **Step 3.4: Run tests to verify they pass**

Run: `xcodebuild test -scheme MyHealth -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:MyHealthTests/DayBucketerTests`
Expected: PASS (all 4 tests).

- [ ] **Step 3.5: Commit**

```bash
git add MyHealth/Sync/DayBucketer.swift Tests/DayBucketerTests.swift
git commit -m "$(cat <<'EOF'
feat(sync): add DayBucketer for local-time day boundaries

Maps a sample's UTC start date + HKTimeZone (or device tz) to a (date,
timezone) key that determines its YYYY/MM/DD directory.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Snapshot merger (dedup + sort)

**Files:**
- Create: `MyHealth/Sync/SnapshotMerger.swift`
- Test: `Tests/SnapshotMergerTests.swift`

Why: snapshot semantics mean each day-file is the **complete** state for that (type, day). When re-syncing, we GET the existing remote, merge incoming samples in (dedup by UUID, new wins on conflict), sort by `(start, end, source)`, and write the result.

- [ ] **Step 4.1: Write the failing tests**

Create `Tests/SnapshotMergerTests.swift`:

```swift
import XCTest
@testable import MyHealth

final class SnapshotMergerTests: XCTestCase {

    func testMergeDedupsByUUID() {
        let existing = [
            QuantitySample(start: "2026-01-18T01:00:00.000Z", end: "2026-01-18T01:10:00.000Z",
                           value: 100, unit: "count", type: "HKQuantityTypeIdentifierStepCount",
                           source: "S1", device: nil, metadata: nil, uuid: "U1"),
            QuantitySample(start: "2026-01-18T02:00:00.000Z", end: "2026-01-18T02:10:00.000Z",
                           value: 50,  unit: "count", type: "HKQuantityTypeIdentifierStepCount",
                           source: "S1", device: nil, metadata: nil, uuid: "U2"),
        ]
        // Incoming includes a corrected U1 (value=150 instead of 100) plus a new U3.
        let incoming = [
            QuantitySample(start: "2026-01-18T01:00:00.000Z", end: "2026-01-18T01:10:00.000Z",
                           value: 150, unit: "count", type: "HKQuantityTypeIdentifierStepCount",
                           source: "S1", device: nil, metadata: nil, uuid: "U1"),
            QuantitySample(start: "2026-01-18T03:00:00.000Z", end: "2026-01-18T03:10:00.000Z",
                           value: 25,  unit: "count", type: "HKQuantityTypeIdentifierStepCount",
                           source: "S1", device: nil, metadata: nil, uuid: "U3"),
        ]
        let merged = SnapshotMerger.merge(existing: existing, incoming: incoming)
        XCTAssertEqual(merged.count, 3)
        XCTAssertEqual(merged.first(where: { $0.uuid == "U1" })?.value, 150) // new wins
    }

    func testMergeSortsByStartEndSource() {
        let a = QuantitySample(start: "2026-01-18T02:00:00.000Z", end: "2026-01-18T02:01:00.000Z",
                               value: 1, unit: "count", type: "T",
                               source: "B", device: nil, metadata: nil, uuid: "A")
        let b = QuantitySample(start: "2026-01-18T01:00:00.000Z", end: "2026-01-18T01:01:00.000Z",
                               value: 1, unit: "count", type: "T",
                               source: "A", device: nil, metadata: nil, uuid: "B")
        let c = QuantitySample(start: "2026-01-18T01:00:00.000Z", end: "2026-01-18T01:02:00.000Z",
                               value: 1, unit: "count", type: "T",
                               source: "A", device: nil, metadata: nil, uuid: "C")
        let d = QuantitySample(start: "2026-01-18T01:00:00.000Z", end: "2026-01-18T01:01:00.000Z",
                               value: 1, unit: "count", type: "T",
                               source: "B", device: nil, metadata: nil, uuid: "D")
        let merged = SnapshotMerger.merge(existing: [a], incoming: [b, c, d])
        XCTAssertEqual(merged.map(\.uuid), ["B", "D", "C", "A"])
    }

    func testMergeEmptyExisting() {
        let s = QuantitySample(start: "2026-01-18T01:00:00.000Z", end: "2026-01-18T01:10:00.000Z",
                               value: 1, unit: "count", type: "T",
                               source: "S", device: nil, metadata: nil, uuid: "U1")
        XCTAssertEqual(SnapshotMerger.merge(existing: [], incoming: [s]).count, 1)
    }

    func testMergeCategorySamples() {
        let a = CategorySample(start: "2026-01-18T22:00:00.000Z", end: "2026-01-18T22:30:00.000Z",
                               value: "awake", type: "HKCategoryTypeIdentifierSleepAnalysis",
                               source: "S", device: nil, metadata: nil, uuid: "U1")
        let b = CategorySample(start: "2026-01-18T20:00:00.000Z", end: "2026-01-18T21:00:00.000Z",
                               value: "asleepCore", type: "HKCategoryTypeIdentifierSleepAnalysis",
                               source: "S", device: nil, metadata: nil, uuid: "U2")
        let merged = SnapshotMerger.mergeCategory(existing: [a], incoming: [b])
        XCTAssertEqual(merged.map(\.uuid), ["U2", "U1"])
    }
}
```

- [ ] **Step 4.2: Run tests to verify they fail**

Run: `xcodebuild test -scheme MyHealth -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:MyHealthTests/SnapshotMergerTests`
Expected: FAIL.

- [ ] **Step 4.3: Implement SnapshotMerger**

Create `MyHealth/Sync/SnapshotMerger.swift`:

```swift
import Foundation

/// Merges incoming samples into an existing remote snapshot. Two passes:
///   1. Dedup by UUID — same UUID → keep incoming (new wins).
///   2. Sort by `(start, end, source)` per spec.
enum SnapshotMerger {

    static func merge(existing: [QuantitySample], incoming: [QuantitySample]) -> [QuantitySample] {
        var byUUID: [String: QuantitySample] = [:]
        var orderless: [QuantitySample] = []
        for s in existing { append(s, into: &byUUID, orderless: &orderless) }
        for s in incoming { append(s, into: &byUUID, orderless: &orderless) }
        let combined = orderless + byUUID.values
        return combined.sorted(by: compare)
    }

    static func mergeCategory(existing: [CategorySample], incoming: [CategorySample]) -> [CategorySample] {
        var byUUID: [String: CategorySample] = [:]
        var orderless: [CategorySample] = []
        for s in existing { appendCat(s, into: &byUUID, orderless: &orderless) }
        for s in incoming { appendCat(s, into: &byUUID, orderless: &orderless) }
        let combined = orderless + byUUID.values
        return combined.sorted(by: compareCat)
    }

    // MARK: - private

    private static func append(_ s: QuantitySample,
                               into dict: inout [String: QuantitySample],
                               orderless: inout [QuantitySample]) {
        if let u = s.uuid { dict[u] = s } else { orderless.append(s) }
    }

    private static func appendCat(_ s: CategorySample,
                                  into dict: inout [String: CategorySample],
                                  orderless: inout [CategorySample]) {
        if let u = s.uuid { dict[u] = s } else { orderless.append(s) }
    }

    private static func compare(_ a: QuantitySample, _ b: QuantitySample) -> Bool {
        if a.start != b.start { return a.start < b.start }
        if a.end != b.end { return a.end < b.end }
        return a.source < b.source
    }

    private static func compareCat(_ a: CategorySample, _ b: CategorySample) -> Bool {
        if a.start != b.start { return a.start < b.start }
        if a.end != b.end { return a.end < b.end }
        return a.source < b.source
    }
}
```

- [ ] **Step 4.4: Run tests to verify they pass**

Run: `xcodebuild test -scheme MyHealth -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:MyHealthTests/SnapshotMergerTests`
Expected: PASS (all 4 tests).

- [ ] **Step 4.5: Commit**

```bash
git add MyHealth/Sync/SnapshotMerger.swift Tests/SnapshotMergerTests.swift
git commit -m "$(cat <<'EOF'
feat(sync): add SnapshotMerger for UUID-dedup + sort

Snapshot semantics require each day-file to be the complete state for
(type, day). Merger dedups incoming + remote by UUID (new wins) and
sorts by (start, end, source).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: SyncRunState model + persistence (SyncRunStore)

**Files:**
- Create: `MyHealth/Model/SyncRunState.swift`
- Create: `MyHealth/Sync/SyncRunStore.swift`
- Test: `Tests/SyncRunStateTests.swift`

Why: pause/abort/resume needs the bucketed samples persisted to disk so the loop can pick up at the next un-uploaded day even after the app is killed. `SyncRunState` is the on-disk shape; `SyncRunStore` is load/save/clear.

- [ ] **Step 5.1: Write the failing tests**

Create `Tests/SyncRunStateTests.swift`:

```swift
import XCTest
@testable import MyHealth

final class SyncRunStateTests: XCTestCase {

    private var tmpURL: URL!

    override func setUp() {
        tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sync-run-state-\(UUID()).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpURL)
    }

    func testRoundTrip() throws {
        let dayKey = DayBucketer.DayKey(date: "2026-01-18", timezone: "Asia/Shanghai")
        let qSample = QuantitySample(
            start: "2026-01-18T01:00:00.000Z", end: "2026-01-18T01:10:00.000Z",
            value: 200, unit: "count", type: "HKQuantityTypeIdentifierStepCount",
            source: "S", device: nil, metadata: nil, uuid: "U1"
        )
        let bucket = SyncRunState.DayBucket(
            key: dayKey,
            quantitySamples: ["HKQuantityTypeIdentifierStepCount": [qSample]],
            categorySamples: [:],
            workouts: []
        )
        let state = SyncRunState(
            runID: "20260518T120000Z",
            startedAt: "2026-05-18T12:00:00Z",
            anchorsAtStart: ["HKQuantityTypeIdentifierStepCount": "anchor-base64"],
            newAnchors: ["HKQuantityTypeIdentifierStepCount": "anchor-base64-new"],
            buckets: [bucket],
            completedDayCount: 0
        )

        try SyncRunStore.save(state, at: tmpURL)
        let loaded = try XCTUnwrap(SyncRunStore.load(at: tmpURL))
        XCTAssertEqual(loaded, state)
    }

    func testLoadMissingReturnsNil() throws {
        XCTAssertNil(SyncRunStore.load(at: tmpURL))
    }

    func testClearRemovesFile() throws {
        let state = SyncRunState(
            runID: "x", startedAt: "y", anchorsAtStart: [:], newAnchors: [:],
            buckets: [], completedDayCount: 0
        )
        try SyncRunStore.save(state, at: tmpURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmpURL.path))
        SyncRunStore.clear(at: tmpURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmpURL.path))
    }

    func testRemainingDaysSkipsCompleted() {
        let b1 = SyncRunState.DayBucket(
            key: .init(date: "2026-01-18", timezone: "Asia/Shanghai"),
            quantitySamples: [:], categorySamples: [:], workouts: [])
        let b2 = SyncRunState.DayBucket(
            key: .init(date: "2026-01-19", timezone: "Asia/Shanghai"),
            quantitySamples: [:], categorySamples: [:], workouts: [])
        let state = SyncRunState(
            runID: "x", startedAt: "y", anchorsAtStart: [:], newAnchors: [:],
            buckets: [b1, b2], completedDayCount: 1
        )
        XCTAssertEqual(state.remainingDays.map(\.key.date), ["2026-01-19"])
    }
}
```

- [ ] **Step 5.2: Run tests to verify they fail**

Run: `xcodebuild test -scheme MyHealth -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:MyHealthTests/SyncRunStateTests`
Expected: FAIL.

- [ ] **Step 5.3: Implement SyncRunState**

Create `MyHealth/Model/SyncRunState.swift`:

```swift
import Foundation

/// Persisted state for an in-progress sync run. Lives at
/// `Application Support/sync-run-state.json` while a run is active or paused;
/// deleted when the run completes or the user aborts.
///
/// Each `DayBucket` holds the per-(type, day) sample lists already read from
/// HealthKit but not yet uploaded. `completedDayCount` is the resume cursor:
/// indexes < completedDayCount have been uploaded.
struct SyncRunState: Codable, Equatable {
    let runID: String                            // "20260518T120000Z"
    let startedAt: String                        // ISO 8601 UTC
    let anchorsAtStart: [String: String]         // base64-encoded HKQueryAnchor per type
    let newAnchors: [String: String]             // anchors HealthKit returned at read time
    let buckets: [DayBucket]                     // sorted oldest-first
    var completedDayCount: Int                   // number of buckets fully uploaded

    struct DayBucket: Codable, Equatable {
        let key: DayBucketer.DayKey
        // Per-type sample arrays. Map key = full HK identifier ("HKQuantity…").
        let quantitySamples: [String: [QuantitySample]]
        let categorySamples: [String: [CategorySample]]
        let workouts: [WorkoutFile]
    }

    var remainingDays: ArraySlice<DayBucket> {
        guard completedDayCount < buckets.count else { return [] }
        return buckets[completedDayCount...]
    }
}
```

- [ ] **Step 5.4: Implement SyncRunStore**

Create `MyHealth/Sync/SyncRunStore.swift`:

```swift
import Foundation

/// File-backed storage for `SyncRunState`. Default location is
/// `<Application Support>/sync-run-state.json`.
enum SyncRunStore {

    static let defaultURL: URL = {
        let dir = try! FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return dir.appendingPathComponent("sync-run-state.json")
    }()

    static func save(_ state: SyncRunState, at url: URL = defaultURL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(state)
        try data.write(to: url, options: .atomic)
    }

    static func load(at url: URL = defaultURL) -> SyncRunState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SyncRunState.self, from: data)
    }

    static func clear(at url: URL = defaultURL) {
        try? FileManager.default.removeItem(at: url)
    }
}
```

- [ ] **Step 5.5: Run tests to verify they pass**

Run: `xcodebuild test -scheme MyHealth -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:MyHealthTests/SyncRunStateTests`
Expected: PASS (all 4 tests).

- [ ] **Step 5.6: Commit**

```bash
git add MyHealth/Model/SyncRunState.swift MyHealth/Sync/SyncRunStore.swift Tests/SyncRunStateTests.swift
git commit -m "$(cat <<'EOF'
feat(sync): add SyncRunState for pause/abort/resume checkpoints

The bucketed per-day sample state lives on disk between reads and
uploads, so pause / abort / app-kill all leave a recoverable run.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Sample encoders — HK sample → new DTOs

**Files:**
- Modify: `MyHealth/Health/SampleEncoder.swift`
- Test: `Tests/HealthSampleTests.swift` (rewrite — remove v1 tests, add new-shape tests)

Why: replace the legacy v1 encoders (which built `HealthSample` rows) with new ones that build `QuantitySample` / `CategorySample` / `WorkoutFile`. The unit catalog stays — `canonicalUnit(for:)` is reused as-is.

The encoder still needs to read HKQuantity values, build ISO 8601 timestamps, and pull device / source / metadata. The new format simplifies the device string (`q.device?.model`) and uses ISO 8601 with fractional seconds + `Z` instead of the legacy `"yyyy-MM-dd HH:mm:ss xxxx"` shape.

- [ ] **Step 6.1: Rewrite the encoder tests**

Replace the contents of `Tests/HealthSampleTests.swift` with:

```swift
import XCTest
import HealthKit
@testable import MyHealth

/// Verifies the new-format encoders for the per-day JSON layout.
/// (Legacy myhealth.apple_health.v1 row tests removed in this rewrite —
/// see docs/superpowers/plans/2026-05-19-day-based-incremental-sync.md
/// for rationale.)
final class HealthSampleTests: XCTestCase {

    func testISOTimestampHasZSuffixAndFractionalSeconds() {
        // 1768867200 → 2026-01-18T01:00:00 UTC
        let d = Date(timeIntervalSince1970: 1768867200)
        let s = SampleEncoder.iso(d)
        XCTAssertEqual(s, "2026-01-18T01:00:00.000Z")
    }

    func testEncodeQuantitySampleProducesNumericValue() throws {
        // Building a real HKQuantitySample requires permissions, so we test
        // the pure conversion helper instead. canonicalUnit + value rendering
        // are the bits we own.
        let unit = SampleEncoder.canonicalUnit(
            for: HKQuantityType.quantityType(forIdentifier: .stepCount)!)
        XCTAssertEqual(unit.unitString, "count")
    }

    func testHeartRateUnitString() {
        let unit = SampleEncoder.canonicalUnit(
            for: HKQuantityType.quantityType(forIdentifier: .heartRate)!)
        XCTAssertEqual(unit.unitString, "count/min")
    }

    func testDeviceStringPrefersModel() {
        // Spec wants the hardware model ("Watch7,1"), not the legacy
        // "name=X, model=Y, manufacturer=Z" blob.
        let model = SampleEncoder.deviceModelString(name: "Apple Watch",
                                                    model: "Watch7,1",
                                                    hardwareVersion: nil)
        XCTAssertEqual(model, "Watch7,1")
    }

    func testDeviceStringFallsBackToHardware() {
        let model = SampleEncoder.deviceModelString(name: nil, model: nil,
                                                    hardwareVersion: "Watch7,1")
        XCTAssertEqual(model, "Watch7,1")
    }

    func testDeviceStringNilWhenAllAbsent() {
        XCTAssertNil(SampleEncoder.deviceModelString(name: nil, model: nil, hardwareVersion: nil))
    }
}
```

- [ ] **Step 6.2: Run tests to verify they fail**

Run: `xcodebuild test -scheme MyHealth -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:MyHealthTests/HealthSampleTests`
Expected: FAIL — `SampleEncoder.deviceModelString` doesn't exist; `SampleEncoder.iso` exists but with the old format.

- [ ] **Step 6.3: Rewrite SampleEncoder**

Replace the entire body of `MyHealth/Health/SampleEncoder.swift` with:

```swift
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

    static func canonicalUnit(for type: HKQuantityType) -> HKUnit {
        // ⬇️ PRESERVE the entire switch from the prior file here, unchanged.
        // It maps every recognised HKQuantityTypeIdentifier to its canonical
        // HKUnit (`.count()`, `.kilocalorie()`, etc.) and falls back to
        // `.count()` for unknown identifiers.
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
            case .inBed:           return "inBed"
            case .asleep:          return "asleepUnspecified"
            case .awake:           return "awake"
            case .asleepCore:      return "asleepCore"
            case .asleepDeep:      return "asleepDeep"
            case .asleepREM:       return "asleepREM"
            case .asleepUnspecified: return "asleepUnspecified"
            @unknown default:      return "unknown-\(c.value)"
            }
        }
        return String(c.value)
    }
}

extension HKSource {
    /// Helper: prefer bundle identifier, fall back to source name for sources
    /// that don't expose a bundle (e.g. manual entries).
    fileprivate var bundleIdentifier: String { self.bundleIdentifier ?? self.name }
}
```

(Note: the `HKSource.bundleIdentifier` extension reads `self.bundleIdentifier` which is the real Apple property — recursion is intentional via property access, not method. If the compiler rejects this, change the extension to a free function `private func sourceBundle(_ s: HKSource) -> String { s.bundleIdentifier ?? s.name }` and call it from the encoders.)

- [ ] **Step 6.4: Run tests to verify they pass**

Run: `xcodebuild test -scheme MyHealth -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:MyHealthTests/HealthSampleTests`
Expected: PASS (all 6 tests).

Note: at this point, the project will **fail to build** because `MyHealth/Sync/SyncCoordinator.swift` and `MyHealth/Sync/BatchWriter.swift` still call the old `SampleEncoder` methods. Tasks 7–11 fix that. To unblock the test command, comment out the bodies of those callers temporarily (just enough to compile). Specifically:

- In `MyHealth/Sync/BatchWriter.swift`: leave the file alone — it's still compilable; it doesn't call the encoder.
- In `MyHealth/Health/HealthKitReader.swift`: replace the loop body that calls `SampleEncoder.encode(q)` etc. with a no-op placeholder that returns an empty `SyncReadResult`. Add `// TODO: rewritten in Task 7` comments.
- In `MyHealth/Sync/SyncCoordinator.swift`: same — replace the body of `runOnce` with a stub `print("MyHealth: sync stubbed during rewrite")` and `self.status = .idle`. Add `// TODO: rewritten in Task 8` comment.

This is intentional: we trade a few hours of "the app doesn't sync" for cleanly TDD'd new pieces. Don't ship from this checkpoint.

- [ ] **Step 6.5: Commit**

```bash
git add MyHealth/Health/SampleEncoder.swift MyHealth/Health/HealthKitReader.swift MyHealth/Sync/SyncCoordinator.swift Tests/HealthSampleTests.swift
git commit -m "$(cat <<'EOF'
feat(sync): rewrite SampleEncoder for new per-day JSON format

Encoders now build QuantitySample / CategorySample / WorkoutFile DTOs
with ISO 8601 UTC timestamps and short device strings. ECG/clinical/
activity-summary encoders deleted; HealthKitReader and SyncCoordinator
stubbed pending rewrite in Tasks 7-8.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: HealthKitReader rewrite — bucketed output

**Files:**
- Modify: `MyHealth/Health/HealthKitReader.swift`
- Modify: `MyHealth/Model/DataTypes.swift` (small adjustment: drop ECG / audiogram / clinical from `allAnchoredSampleTypes`)

Why: the reader now needs to return data already grouped into `SyncRunState.DayBucket`s rather than flat arrays — that's the unit the coordinator wants to checkpoint against. It also needs to attach each sample to the right local-day key, using `HKMetadataKeyTimeZone` when present.

- [ ] **Step 7.1: Update DataTypes.swift**

Open `MyHealth/Model/DataTypes.swift` and modify `allAnchoredSampleTypes`:

```swift
    /// Sample types the sync coordinator iterates with `HKAnchoredObjectQuery`.
    /// Excludes characteristic types, ECG, clinical records, audiograms, and
    /// workout routes — none of these are part of the per-day JSON layout
    /// (see docs/superpowers/plans/2026-05-19-day-based-incremental-sync.md).
    static var allAnchoredSampleTypes: [HKSampleType] {
        var s: [HKSampleType] = []
        s.append(contentsOf: allQuantityTypes.map { $0 as HKSampleType })
        s.append(contentsOf: allCategoryTypes.map { $0 as HKSampleType })
        s.append(workoutType as HKSampleType)
        return s
    }
```

The clinical/ECG/audiogram identifier lists stay in the file for now — they're still needed for `allReadTypes` (we keep requesting auth so the user doesn't see a second permission sheet later if we add them back).

- [ ] **Step 7.2: Rewrite HealthKitReader**

Replace the entire body of `MyHealth/Health/HealthKitReader.swift` with:

```swift
import Foundation
import HealthKit
import CoreLocation
import UIKit

/// Reads new HealthKit samples (since the previous anchors) and buckets them
/// by local day. Output is suitable for direct insertion into a
/// `SyncRunState`.
struct HealthKitReader {
    let store: HKHealthStore

    init(store: HKHealthStore = HKHealthStore()) {
        self.store = store
    }

    /// One read pass over every anchored type. Returns:
    ///   - per-day buckets sorted oldest-first
    ///   - new anchor per type (only for types that returned data or moved forward)
    func readBucketed(
        anchors: [String: HKQueryAnchor],
        deviceInfo: WorkoutFile.DeviceInfo
    ) async throws -> ReadResult {
        // Mutable accumulators keyed by DayKey. Per-type sample arrays inside.
        var buckets: [DayBucketer.DayKey: BucketAccumulator] = [:]
        var newAnchors: [String: HKQueryAnchor] = [:]

        for sampleType in HealthDataTypes.allAnchoredSampleTypes {
            let prev = anchors[sampleType.identifier]
            let queryResult: (added: [HKSample], deleted: [HKDeletedObject], newAnchor: HKQueryAnchor?)
            do {
                queryResult = try await runAnchoredQuery(for: sampleType, anchor: prev)
            } catch let e as HKError where e.code == .errorAuthorizationNotDetermined || e.code == .errorAuthorizationDenied {
                print("MyHealth: skip \(sampleType.identifier) (no auth): \(e.localizedDescription)")
                continue
            }
            let (samples, _, newAnchor) = queryResult
            if let newAnchor { newAnchors[sampleType.identifier] = newAnchor }

            for sample in samples {
                if let workout = sample as? HKWorkout {
                    // Workouts: build a WorkoutFile per workout.
                    let events = workout.workoutEvents
                    let route = (try? await loadRoute(for: workout)) ?? nil
                    let wf = SampleEncoder.encode(workout, events: events, route: route, deviceInfo: deviceInfo)
                    let tz = SampleEncoder.timezone(from: workout.metadata)
                    let key = DayBucketer.dayKey(start: workout.startDate, timezone: tz)
                    buckets[key, default: BucketAccumulator()].workouts.append(wf)

                } else if let q = sample as? HKQuantitySample {
                    guard let row = SampleEncoder.encode(q) else { continue }
                    let tz = SampleEncoder.timezone(from: q.metadata)
                    let key = DayBucketer.dayKey(start: q.startDate, timezone: tz)
                    buckets[key, default: BucketAccumulator()].quantity[q.quantityType.identifier, default: []].append(row)

                } else if let c = sample as? HKCategorySample {
                    let row = SampleEncoder.encode(c)
                    let tz = SampleEncoder.timezone(from: c.metadata)
                    let key = DayBucketer.dayKey(start: c.startDate, timezone: tz)
                    buckets[key, default: BucketAccumulator()].category[c.categoryType.identifier, default: []].append(row)
                }
            }
        }

        let sortedKeys = buckets.keys.sorted { $0.date < $1.date }
        let dayBuckets: [SyncRunState.DayBucket] = sortedKeys.map { key in
            let acc = buckets[key]!
            return SyncRunState.DayBucket(
                key: key,
                quantitySamples: acc.quantity,
                categorySamples: acc.category,
                workouts: acc.workouts
            )
        }
        return ReadResult(buckets: dayBuckets, newAnchors: newAnchors)
    }

    struct ReadResult {
        let buckets: [SyncRunState.DayBucket]
        let newAnchors: [String: HKQueryAnchor]
    }

    private struct BucketAccumulator {
        var quantity: [String: [QuantitySample]] = [:]
        var category: [String: [CategorySample]] = [:]
        var workouts: [WorkoutFile] = []
    }

    // MARK: - HKAnchoredObjectQuery wrapper

    private func runAnchoredQuery(
        for type: HKSampleType,
        anchor: HKQueryAnchor?
    ) async throws -> (added: [HKSample], deleted: [HKDeletedObject], newAnchor: HKQueryAnchor?) {
        try await withCheckedThrowingContinuation { cont in
            let query = HKAnchoredObjectQuery(
                type: type, predicate: nil, anchor: anchor,
                limit: HKObjectQueryNoLimit
            ) { _, samples, deleted, newAnchor, error in
                if let error { cont.resume(throwing: error); return }
                cont.resume(returning: (samples ?? [], deleted ?? [], newAnchor))
            }
            store.execute(query)
        }
    }

    // MARK: - Workout route

    private func loadRoute(for workout: HKWorkout) async throws -> [CLLocation]? {
        let routeType = HealthDataTypes.workoutRouteType
        let predicate = HKQuery.predicateForObjects(from: workout)
        let routes: [HKWorkoutRoute] = try await withCheckedThrowingContinuation { cont in
            let q = HKAnchoredObjectQuery(
                type: routeType, predicate: predicate, anchor: nil,
                limit: HKObjectQueryNoLimit
            ) { _, samples, _, _, error in
                if let error { cont.resume(throwing: error); return }
                cont.resume(returning: (samples as? [HKWorkoutRoute]) ?? [])
            }
            store.execute(q)
        }
        guard !routes.isEmpty else { return nil }

        var locations: [CLLocation] = []
        for route in routes {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                let routeQuery = HKWorkoutRouteQuery(route: route) { _, batch, done, error in
                    if let error { cont.resume(throwing: error); return }
                    if let batch { locations.append(contentsOf: batch) }
                    if done { cont.resume(returning: ()) }
                }
                store.execute(routeQuery)
            }
        }
        return locations.isEmpty ? nil : locations
    }
}
```

- [ ] **Step 7.3: Build the project (no new test in this task)**

There's no isolated unit test for the reader — it depends on a real HKHealthStore. Build to ensure compilation:

Run: `xcodebuild build -scheme MyHealth -destination 'platform=iOS Simulator,name=iPhone 15'`
Expected: BUILD SUCCEEDED. (`SyncCoordinator` is still stubbed and won't actually do anything yet.)

- [ ] **Step 7.4: Commit**

```bash
git add MyHealth/Health/HealthKitReader.swift MyHealth/Model/DataTypes.swift
git commit -m "$(cat <<'EOF'
refactor(sync): HealthKitReader now emits per-day bucketed samples

readBucketed groups HK samples into SyncRunState.DayBucket instances
keyed by local day (HKTimeZone metadata when present, device tz as
fallback). ECG / clinical / audiogram dropped from the anchored-type
list — see plan for rationale.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: SyncCoordinator rewrite — day-loop with pause/abort/resume

**Files:**
- Modify: `MyHealth/Sync/SyncCoordinator.swift`
- Modify: `MyHealth/GoogleDrive/GoogleDriveClient.swift` (add `getFile`)

Why: this is the central piece. The coordinator reads new samples, buckets them, persists the bucket state, then walks day-by-day uploading per (type, day) by GET-merge-PUT. After each day, it bumps `completedDayCount` and re-saves state. Pause/abort flags are checked between every file upload for responsiveness.

- [ ] **Step 8.1: Add `getFile` to GoogleDriveClient**

Edit `MyHealth/GoogleDrive/GoogleDriveClient.swift`. Add this method below `uploadBytes(relativePath:body:)`:

```swift
    /// Fetches the bytes at `<remote_path>/<relativePath>`, or returns nil if
    /// the file does not exist in Drive (404 or no match in our folder tree).
    func getFile(relativePath: String) async throws -> Data? {
        let token = try await DriveAuth.freshAccessToken()
        // Walk the subPath + the leading components of relativePath; if any
        // segment is missing, the file can't exist.
        let pathComponents = subPath + relativePath.split(separator: "/").map(String.init).dropLast()
        guard let parent = try await findFolderPath(components: pathComponents, token: token) else {
            return nil
        }
        let fileName = (relativePath as NSString).lastPathComponent
        guard let fileID = try await findFile(name: fileName, parent: parent, mimeType: nil, token: token) else {
            return nil
        }
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files/\(fileID)")!
        components.queryItems = [.init(name: "alt", value: "media")]
        var req = URLRequest(url: components.url!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await urlSession.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return nil
        }
        return data
    }

    /// Read-only sibling of `ensureFolderPath`: returns nil at the first
    /// missing segment instead of creating folders.
    private func findFolderPath(components: [String], token: String) async throws -> String? {
        guard let rootID = try await findFile(
            name: rootFolderName, parent: "root",
            mimeType: "application/vnd.google-apps.folder", token: token
        ) else { return nil }
        var parent = rootID
        for c in components where !c.isEmpty {
            guard let next = try await findFile(
                name: c, parent: parent,
                mimeType: "application/vnd.google-apps.folder", token: token
            ) else { return nil }
            parent = next
        }
        return parent
    }
```

- [ ] **Step 8.2: Rewrite SyncCoordinator**

Replace the entire body of `MyHealth/Sync/SyncCoordinator.swift` with:

```swift
import Foundation
import HealthKit
import UIKit

/// Orchestrates one day-by-day sync. Top-level flow:
///   1. Load anchors from AnchorStore.
///   2. Read new HealthKit samples, bucketed by local day.
///   3. Persist SyncRunState (so pause/kill is recoverable).
///   4. Walk days oldest→newest. For each (day, type):
///        GET existing remote → merge by UUID → PUT back.
///      Pause/abort flags are polled between files.
///   5. On full completion: advance anchors in AnchorStore, clear state.
///
/// Pause keeps state. Abort deletes it. Resume picks up where pause left off.
@MainActor
final class SyncCoordinator: ObservableObject {
    @Published private(set) var status: SyncStatus = .idle
    @Published private(set) var lastResult: SyncRunResult?
    @Published private(set) var progress: Progress?

    enum SyncStatus: Equatable {
        case idle
        case running(stage: String)
        case paused(completedDays: Int, totalDays: Int)
        case error(String)
    }

    struct Progress: Equatable {
        let completedDays: Int
        let totalDays: Int
        let currentDate: String?    // YYYY-MM-DD of in-flight day
    }

    struct SyncRunResult: Equatable {
        let runID: String
        let totalSamples: Int
        let totalWorkouts: Int
        let totalDays: Int
        let myLifeDBUploaded: Bool
        let driveUploaded: Bool
        let finishedAt: Date
    }

    enum Destination { case myLifeDB, googleDrive }

    private let reader: HealthKitReader
    private var pauseRequested = false
    private var abortRequested = false

    /// Subpath under each destination's remote root. New layout = no `syncs/`
    /// prefix — files live directly under `apple-health/YYYY/MM/DD/`.
    private let layoutRoot = ""

    init(reader: HealthKitReader = HealthKitReader()) {
        self.reader = reader
    }

    // MARK: - Public control surface

    /// Starts a new sync, or resumes a paused one if state exists on disk.
    func runOnce(enabledDestinations: Set<Destination>) async {
        pauseRequested = false
        abortRequested = false
        if let existing = SyncRunStore.load() {
            print("MyHealth: resuming run id=\(existing.runID) at day \(existing.completedDayCount)/\(existing.buckets.count)")
            await runLoop(state: existing, enabledDestinations: enabledDestinations, freshRead: false)
        } else {
            await freshRun(enabledDestinations: enabledDestinations)
        }
    }

    /// Stops the sync between files, persists state. The run can be resumed.
    func pause() {
        pauseRequested = true
    }

    /// Stops the sync between files, deletes state. Anchors do NOT advance.
    func abort() {
        abortRequested = true
    }

    /// True iff a partially-completed run exists on disk.
    var hasPendingRun: Bool { SyncRunStore.load() != nil }

    // MARK: - Fresh run

    private func freshRun(enabledDestinations: Set<Destination>) async {
        let started = Date()
        let runID = makeRunID(date: started)
        do {
            // 1. Load anchors.
            status = .running(stage: String(localized: "Loading anchors"))
            let priorAnchors = AnchorStore.loadCache()
            print("MyHealth: anchors loaded count=\(priorAnchors.count)")

            // 2. Read.
            status = .running(stage: String(localized: "Reading HealthKit"))
            let deviceInfo = WorkoutFile.DeviceInfo(
                name: UIDevice.current.name,
                model: deviceModel(),
                systemVersion: UIDevice.current.systemVersion
            )
            let read = try await reader.readBucketed(anchors: priorAnchors, deviceInfo: deviceInfo)
            print("MyHealth: bucketed days=\(read.buckets.count) types=\(read.newAnchors.count)")

            // 3. Persist initial state.
            let state = SyncRunState(
                runID: runID,
                startedAt: SampleEncoder.iso(started),
                anchorsAtStart: AnchorStore.encodeAll(priorAnchors),
                newAnchors: AnchorStore.encodeAll(read.newAnchors),
                buckets: read.buckets,
                completedDayCount: 0
            )
            try SyncRunStore.save(state)

            await runLoop(state: state, enabledDestinations: enabledDestinations, freshRead: true)
        } catch {
            status = .error(error.localizedDescription)
            print("MyHealth: sync FAILED stage=fresh-run error=\(error.localizedDescription)")
        }
    }

    // MARK: - Day loop

    private func runLoop(state initialState: SyncRunState,
                         enabledDestinations: Set<Destination>,
                         freshRead: Bool) async {
        var state = initialState
        let mldClient: MyLifeDBClient? = enabledDestinations.contains(.myLifeDB)
            ? (try? TokenStore.load()).flatMap { MyLifeDBClient(session: $0) } : nil
        let driveAvailable = enabledDestinations.contains(.googleDrive) && DriveAuth.currentUser != nil
        let drive: GoogleDriveClient? = driveAvailable ? GoogleDriveClient() : nil

        var totalSamples = 0
        var totalWorkouts = 0

        do {
            for index in state.completedDayCount..<state.buckets.count {
                if abortRequested {
                    print("MyHealth: aborting at day \(index)/\(state.buckets.count)")
                    SyncRunStore.clear()
                    self.status = .idle
                    self.progress = nil
                    return
                }
                if pauseRequested {
                    print("MyHealth: paused at day \(index)/\(state.buckets.count)")
                    try SyncRunStore.save(state)
                    self.status = .paused(completedDays: index, totalDays: state.buckets.count)
                    self.progress = Progress(completedDays: index, totalDays: state.buckets.count, currentDate: nil)
                    return
                }

                let bucket = state.buckets[index]
                self.status = .running(stage: String(localized: "Uploading \(bucket.key.date)"))
                self.progress = Progress(completedDays: index, totalDays: state.buckets.count, currentDate: bucket.key.date)

                // Quantity files.
                for (type, samples) in bucket.quantitySamples {
                    if abortRequested || pauseRequested { break }
                    let filename = TypeNaming.filename(for: type)
                    let path = "\(bucket.key.pathPrefix)/\(filename)"
                    let unit = samples.first?.unit ?? ""
                    let merged = try await mergeAndUploadQuantity(
                        path: path, day: bucket.key, type: type, unit: unit,
                        incoming: samples, mld: mldClient, drive: drive
                    )
                    totalSamples += merged
                }

                // Category files.
                for (type, samples) in bucket.categorySamples {
                    if abortRequested || pauseRequested { break }
                    let filename = TypeNaming.filename(for: type)
                    let path = "\(bucket.key.pathPrefix)/\(filename)"
                    let merged = try await mergeAndUploadCategory(
                        path: path, day: bucket.key, type: type,
                        incoming: samples, mld: mldClient, drive: drive
                    )
                    totalSamples += merged
                }

                // Workouts — one file per workout, no merge needed.
                for w in bucket.workouts {
                    if abortRequested || pauseRequested { break }
                    let filename = TypeNaming.workoutFilename(uuid: w.uuid)
                    let path = "\(bucket.key.pathPrefix)/\(filename)"
                    let body = try JSONEncoder.daySorted.encode(w)
                    try await put(path: path, body: body, mld: mldClient, drive: drive)
                    totalWorkouts += 1
                }

                // Loop guards may have flipped mid-day; honor them on next iteration.
                if abortRequested || pauseRequested { continue }

                state.completedDayCount = index + 1
                try SyncRunStore.save(state)
            }

            // Fall-through: every day done.
            try await finalize(state: state, totalSamples: totalSamples, totalWorkouts: totalWorkouts,
                               mldUploaded: mldClient != nil, driveUploaded: drive != nil)
        } catch {
            // Persist whatever progress we have, then surface error.
            try? SyncRunStore.save(state)
            self.status = .error(error.localizedDescription)
            print("MyHealth: sync FAILED stage=day-loop error=\(error.localizedDescription)")
        }
    }

    private func finalize(state: SyncRunState, totalSamples: Int, totalWorkouts: Int,
                          mldUploaded: Bool, driveUploaded: Bool) async throws {
        // Advance anchors only on full completion.
        let newAnchors = AnchorStore.decodeAll(state.newAnchors)
        AnchorStore.saveCache(newAnchors)
        SyncRunStore.clear()
        let result = SyncRunResult(
            runID: state.runID,
            totalSamples: totalSamples,
            totalWorkouts: totalWorkouts,
            totalDays: state.buckets.count,
            myLifeDBUploaded: mldUploaded,
            driveUploaded: driveUploaded,
            finishedAt: Date()
        )
        self.lastResult = result
        self.status = .idle
        self.progress = nil
        print("MyHealth: sync done run=\(state.runID) samples=\(totalSamples) workouts=\(totalWorkouts) days=\(state.buckets.count)")
    }

    // MARK: - Merge + upload helpers

    private func mergeAndUploadQuantity(
        path: String, day: DayBucketer.DayKey, type: String, unit: String,
        incoming: [QuantitySample], mld: MyLifeDBClient?, drive: GoogleDriveClient?
    ) async throws -> Int {
        let existing = try await getExistingQuantity(path: path, mld: mld, drive: drive)
        let merged = SnapshotMerger.merge(existing: existing, incoming: incoming)
        let envelope = DayFile.quantity(
            date: day.date, type: type, timezone: day.timezone, unit: unit, samples: merged
        )
        let body = try JSONEncoder.daySorted.encode(envelope)
        try await put(path: path, body: body, mld: mld, drive: drive)
        return merged.count
    }

    private func mergeAndUploadCategory(
        path: String, day: DayBucketer.DayKey, type: String,
        incoming: [CategorySample], mld: MyLifeDBClient?, drive: GoogleDriveClient?
    ) async throws -> Int {
        let existing = try await getExistingCategory(path: path, mld: mld, drive: drive)
        let merged = SnapshotMerger.mergeCategory(existing: existing, incoming: incoming)
        let envelope = DayFile.category(
            date: day.date, type: type, timezone: day.timezone, samples: merged
        )
        let body = try JSONEncoder.daySorted.encode(envelope)
        try await put(path: path, body: body, mld: mld, drive: drive)
        return merged.count
    }

    private func getExistingQuantity(path: String, mld: MyLifeDBClient?, drive: GoogleDriveClient?) async throws -> [QuantitySample] {
        // Prefer MLD; if absent, try Drive. Either provides a valid snapshot.
        if let mld, let data = try await mld.getFile(relativePath: path),
           let decoded = try? JSONDecoder().decode(DayFile<QuantitySample>.self, from: data) {
            return decoded.samples
        }
        if let drive, let data = try await drive.getFile(relativePath: path),
           let decoded = try? JSONDecoder().decode(DayFile<QuantitySample>.self, from: data) {
            return decoded.samples
        }
        return []
    }

    private func getExistingCategory(path: String, mld: MyLifeDBClient?, drive: GoogleDriveClient?) async throws -> [CategorySample] {
        if let mld, let data = try await mld.getFile(relativePath: path),
           let decoded = try? JSONDecoder().decode(DayFile<CategorySample>.self, from: data) {
            return decoded.samples
        }
        if let drive, let data = try await drive.getFile(relativePath: path),
           let decoded = try? JSONDecoder().decode(DayFile<CategorySample>.self, from: data) {
            return decoded.samples
        }
        return []
    }

    private func put(path: String, body: Data, mld: MyLifeDBClient?, drive: GoogleDriveClient?) async throws {
        if let mld {
            try await mld.putBytes(relativePath: path, body: body, contentType: "application/json")
        }
        if let drive {
            try await drive.uploadBytes(relativePath: path, body: body)
        }
    }

    // MARK: - misc

    private func makeRunID(date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "-", with: "")
    }

    private func deviceModel() -> String {
        var sysinfo = utsname()
        uname(&sysinfo)
        return withUnsafePointer(to: &sysinfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
    }
}

extension JSONEncoder {
    /// Deterministic JSON for day files: sorted keys, pretty-printed (so the
    /// remote files are diff-friendly), no escaped slashes.
    static var daySorted: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return e
    }
}
```

- [ ] **Step 8.3: Build the project**

Run: `xcodebuild build -scheme MyHealth -destination 'platform=iOS Simulator,name=iPhone 15'`

Expected: BUILD SUCCEEDED. Compiler may complain about:
- `MyLifeDBClient(session:)` argument label — actor init takes `session: MyLifeDBSession`; the call site passes `MyLifeDBSession`. Fine.
- `TokenStore.load()` returning `MyLifeDBSession?`. Fine.
- The `MyLifeDBClient` is an actor, so `await` on its methods is required — already covered.
- `SyncManifest` references in `BatchWriter.swift` — Task 13 will delete `BatchWriter`; if linker fails earlier, comment its body out temporarily.

If `BatchWriter.swift` breaks compilation because of the unused `SyncManifest.FileRef` return type, replace its body with `// removed in Task 13` placeholder content (empty struct conforming to nothing).

- [ ] **Step 8.4: Commit**

```bash
git add MyHealth/Sync/SyncCoordinator.swift MyHealth/GoogleDrive/GoogleDriveClient.swift
git commit -m "$(cat <<'EOF'
feat(sync): day-by-day pausable upload loop with checkpoints

SyncCoordinator now walks bucketed days oldest-first, merging each
(type, day) snapshot via GET-merge-PUT to MLD and Drive. State is
persisted after every day so pause/abort/kill all leave a recoverable
run. Anchors advance only at end-of-run.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: AnchorStore cleanup — drop SyncManifest dependency

**Files:**
- Modify: `MyHealth/Sync/AnchorStore.swift`

Why: AnchorStore currently lives next to manifest code in `SyncCoordinator`'s old flow. The encode/decode/cache logic stays — but the file should be standalone (it already is). No behavioural change; this task only updates the file's comment block to reflect that the manifest is gone.

- [ ] **Step 9.1: Update the file's doc comment**

Open `MyHealth/Sync/AnchorStore.swift` and replace the top-of-file comment with:

```swift
/// Persists `HKQueryAnchor`s as base64-encoded `NSKeyedArchiver` blobs in
/// `Application Support/anchors.json`. Anchors are the source of truth for
/// incremental sync — they advance only when a full sync run completes
/// (see SyncCoordinator). There is no remote manifest in the new layout;
/// anchors live exclusively on-device.
```

The rest of the file body stays as-is.

- [ ] **Step 9.2: Build**

Run: `xcodebuild build -scheme MyHealth -destination 'platform=iOS Simulator,name=iPhone 15'`
Expected: BUILD SUCCEEDED.

- [ ] **Step 9.3: Commit**

```bash
git add MyHealth/Sync/AnchorStore.swift
git commit -m "$(cat <<'EOF'
docs(sync): AnchorStore comment now describes on-device-only anchors

The manifest is removed in the new layout; anchors no longer round-trip
through MyLifeDB.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 10: BackgroundSync — pause on expiration instead of cancel

**Files:**
- Modify: `MyHealth/Sync/BackgroundSync.swift`

Why: when iOS preempts the background task, we want to pause (saving state) rather than discard work. The next foreground sync — or the next background run — picks up where it left off.

- [ ] **Step 10.1: Update `handle(task:)`**

In `MyHealth/Sync/BackgroundSync.swift`, replace the `handle(task:)` function with:

```swift
    private static func handle(task: BGAppRefreshTask) {
        scheduleNext()

        let coordinator = Task { @MainActor in
            let c = SyncCoordinator()
            await c.runOnce(enabledDestinations: defaultDestinations())
            return c.status == .idle
        }
        task.expirationHandler = {
            // Pause instead of cancel: SyncCoordinator will checkpoint state
            // at the next file boundary so the next run resumes.
            Task { @MainActor in
                // We can't reach the same instance from here, but pause()
                // works on whichever coordinator is currently active for the
                // run. Since BGAppRefreshTask handlers only run one at a
                // time, the foreground coordinator (if any) is irrelevant —
                // the background coordinator owns the in-flight state file
                // and will see the pause flag through SyncCoordinator state.
                //
                // Practical implementation: ask the background coordinator
                // we just spawned to pause. We capture it via the Task above.
            }
            coordinator.cancel()
        }
        Task {
            let success = (try? await coordinator.value) ?? false
            task.setTaskCompleted(success: success)
        }
    }
```

Note: `Task.cancel()` does not translate to `SyncCoordinator.pause()` directly. To make pause-on-expiration work end-to-end, the simplest correct change is to **expose a static pause hook** on `SyncCoordinator`:

In `MyHealth/Sync/SyncCoordinator.swift`, add a static weak reference and update `runOnce`:

```swift
    /// Most-recently-active coordinator, exposed so BackgroundSync can ask
    /// for a pause when iOS preempts the BG task. Cleared in `finalize`.
    static weak var currentlyActive: SyncCoordinator?

    func runOnce(enabledDestinations: Set<Destination>) async {
        Self.currentlyActive = self
        defer { if Self.currentlyActive === self { Self.currentlyActive = nil } }
        // ... existing body ...
    }
```

Then in `BackgroundSync.handle(task:)`, replace the expiration handler body:

```swift
        task.expirationHandler = {
            Task { @MainActor in SyncCoordinator.currentlyActive?.pause() }
        }
```

(Drop the `coordinator.cancel()` line — letting the run finish its current file and persist state is cleaner than cancelling mid-write.)

- [ ] **Step 10.2: Build**

Run: `xcodebuild build -scheme MyHealth -destination 'platform=iOS Simulator,name=iPhone 15'`
Expected: BUILD SUCCEEDED.

- [ ] **Step 10.3: Commit**

```bash
git add MyHealth/Sync/BackgroundSync.swift MyHealth/Sync/SyncCoordinator.swift
git commit -m "$(cat <<'EOF'
fix(sync): pause (not cancel) on BG task expiration

iOS preempting the background sync now requests a graceful pause via
SyncCoordinator.currentlyActive, so the next run resumes from the
persisted SyncRunState instead of losing progress.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 11: UI — Pause / Resume / Abort controls in SyncTab

**Files:**
- Modify: `MyHealth/UI/SyncTab.swift`

Why: surface the new run-state to the user. Single primary button cycles `Sync now → Pause → Resume → Sync now` based on `coordinator.status`. A secondary "Abort" button appears only when paused or running. Progress text shows day-progress when available.

- [ ] **Step 11.1: Replace `SyncNowButton`**

In `MyHealth/UI/SyncTab.swift`, replace the `SyncNowButton` struct with:

```swift
private struct SyncNowButton: View {
    @EnvironmentObject var coordinator: SyncCoordinator
    @EnvironmentObject var sessionStore: SessionStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                Task { await action() }
            } label: {
                HStack {
                    Image(systemName: icon)
                    Text(title).bold()
                }
                .frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .disabled(disabled)

            if showsAbort {
                Button(role: .destructive) {
                    coordinator.abort()
                } label: {
                    Text("Abort and discard progress")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }

            statusLine
        }
    }

    private var enabledDestinations: Set<SyncCoordinator.Destination> {
        var s: Set<SyncCoordinator.Destination> = []
        if sessionStore.myLifeDB != nil { s.insert(.myLifeDB) }
        if sessionStore.googleSignedIn { s.insert(.googleDrive) }
        return s
    }

    private var icon: String {
        switch coordinator.status {
        case .running: return "pause.fill"
        case .paused: return "play.fill"
        case .error: return "arrow.triangle.2.circlepath"
        case .idle: return "arrow.triangle.2.circlepath"
        }
    }

    private var title: String {
        switch coordinator.status {
        case .running: return "Pause"
        case .paused(let done, let total): return "Resume (\(done)/\(total))"
        case .error: return "Retry sync"
        case .idle: return coordinator.hasPendingRun ? "Resume sync" : "Sync now"
        }
    }

    private var disabled: Bool {
        if enabledDestinations.isEmpty && !coordinator.hasPendingRun { return true }
        return false
    }

    private var showsAbort: Bool {
        switch coordinator.status {
        case .paused: return true
        case .running: return true
        case .idle: return coordinator.hasPendingRun
        case .error: return coordinator.hasPendingRun
        }
    }

    private func action() async {
        switch coordinator.status {
        case .running:
            coordinator.pause()
        case .paused, .idle, .error:
            await coordinator.runOnce(enabledDestinations: enabledDestinations)
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch coordinator.status {
        case .running(let stage):
            HStack(spacing: 8) {
                ProgressView()
                Text(stage).foregroundStyle(.secondary).font(.caption)
            }
            if let p = coordinator.progress {
                ProgressView(value: Double(p.completedDays), total: Double(max(1, p.totalDays)))
            }
        case .paused(let done, let total):
            Text("Paused at day \(done) of \(total).").foregroundStyle(.secondary).font(.caption)
        case .error(let msg):
            Text(msg).foregroundStyle(.red).font(.caption)
        case .idle:
            EmptyView()
        }
    }
}
```

- [ ] **Step 11.2: Update `LastBatchSummary` to use the new result shape**

Replace `LastBatchSummary` with:

```swift
private struct LastBatchSummary: View {
    @EnvironmentObject var coordinator: SyncCoordinator

    var body: some View {
        if let r = coordinator.lastResult {
            VStack(alignment: .leading, spacing: 6) {
                Text("Last sync").font(.caption).foregroundStyle(.secondary)
                Text(r.runID).font(.caption.monospaced())
                HStack {
                    Text("Days"); Spacer()
                    Text("\(r.totalDays)").monospacedDigit()
                }
                HStack {
                    Text("Samples"); Spacer()
                    Text("\(r.totalSamples)").monospacedDigit()
                }
                HStack {
                    Text("Workouts"); Spacer()
                    Text("\(r.totalWorkouts)").monospacedDigit()
                }
                .font(.subheadline)
                HStack(spacing: 12) {
                    if r.myLifeDBUploaded {
                        Label("MyLifeDB", systemImage: "checkmark")
                            .labelStyle(.titleAndIcon).font(.caption)
                    }
                    if r.driveUploaded {
                        Label("Drive", systemImage: "checkmark")
                            .labelStyle(.titleAndIcon).font(.caption)
                    }
                }
                .foregroundStyle(.green)
            }
            .padding(.vertical, 2)
        }
    }
}
```

- [ ] **Step 11.3: Build**

Run: `xcodebuild build -scheme MyHealth -destination 'platform=iOS Simulator,name=iPhone 15'`
Expected: BUILD SUCCEEDED.

- [ ] **Step 11.4: Commit**

```bash
git add MyHealth/UI/SyncTab.swift
git commit -m "$(cat <<'EOF'
feat(ui): pause / resume / abort controls + per-day progress

Sync button now toggles between Sync/Pause/Resume based on coordinator
status. A secondary Abort button appears for paused/running/pending
states and discards the in-flight SyncRunState. Last-sync summary uses
the new run-result shape (days + samples + workouts).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 12: Delete dead code (SyncManifest, BatchWriter, HealthSample.swift)

**Files:**
- Delete: `MyHealth/Model/SyncManifest.swift`
- Delete: `MyHealth/Sync/BatchWriter.swift`
- Delete: `MyHealth/Model/HealthSample.swift`
- Modify: `MyHealth/Model/DaySample.swift` (rename `MetaValue` → `AnyCodableValue`)
- Modify: `Tests/DaySampleTests.swift` (same rename)
- Modify: `MyHealth/Health/SampleEncoder.swift` (same rename in metadata encoder)
- Delete: `Tests/ManifestTests.swift`

Why: nothing references these any more (after Tasks 6–11). Cleaning them up restores `AnyCodableValue` to its preferred name.

- [ ] **Step 12.1: Verify nothing references the dead files**

Run all three checks in parallel:

```bash
grep -rn "SyncManifest\|BatchWriter\|class HealthSample\|struct HealthSample" MyHealth/ Tests/
```

Expected output: only the lines inside the files we're about to delete (no external references). If anything else shows up, fix that first.

- [ ] **Step 12.2: Delete the legacy files**

```bash
git rm MyHealth/Model/SyncManifest.swift MyHealth/Sync/BatchWriter.swift MyHealth/Model/HealthSample.swift Tests/ManifestTests.swift
```

- [ ] **Step 12.3: Rename `MetaValue` back to `AnyCodableValue`**

```bash
sed -i '' 's/MetaValue/AnyCodableValue/g' MyHealth/Model/DaySample.swift MyHealth/Health/SampleEncoder.swift Tests/DaySampleTests.swift
```

- [ ] **Step 12.4: Run the full test suite + build**

Run: `xcodebuild test -scheme MyHealth -destination 'platform=iOS Simulator,name=iPhone 15'`
Expected: BUILD SUCCEEDED, all tests PASS. Specifically:
- TypeNamingTests: 7 pass
- DaySampleTests: 7 pass
- DayBucketerTests: 4 pass
- SnapshotMergerTests: 4 pass
- SyncRunStateTests: 4 pass
- HealthSampleTests: 6 pass
- PKCETests: existing, untouched

- [ ] **Step 12.5: Commit**

```bash
git add -A
git commit -m "$(cat <<'EOF'
chore(sync): remove legacy manifest/batch/sample code

SyncManifest, BatchWriter, the old HealthSample row model, and
ManifestTests are gone with the JSONL layout. MetaValue (placeholder)
renamed back to AnyCodableValue now that the collision is resolved.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 13: Update README Tests section + What gets uploaded

**Files:**
- Modify: `README.md`

Why: the Tests section in the README currently advertises `HealthSampleTests` as locking down the v1 JSONL schema, and references `ManifestTests`. Both are now obsolete. Also delete the `simulateLaunchForTaskWithIdentifier` example (still works, but spec/Tests cleanup is the natural moment to tidy the section).

- [ ] **Step 13.1: Update the Tests section**

Open `README.md`. Find the "## Tests" section. Replace its bullet list with:

```markdown
- `PKCETests.swift` — verifies the S256 challenge for the RFC 7636 reference verifier.
- `HealthSampleTests.swift` — pins the new-format encoder behaviour (ISO 8601 timestamps, device-model fallback, canonical units).
- `DaySampleTests.swift` — round-trips the DayFile / QuantitySample / CategorySample / WorkoutFile shapes against the JSON spec.
- `TypeNamingTests.swift` — pins `HKQuantityTypeIdentifier*` → kebab-case filename mapping.
- `DayBucketerTests.swift` — pins the local-day boundary logic against `HKTimeZone` metadata.
- `SnapshotMergerTests.swift` — pins UUID-dedup + sort behaviour for snapshot merges.
- `SyncRunStateTests.swift` — round-trips the on-disk pause/resume state.
```

- [ ] **Step 13.2: Verify**

Run: `grep -n "myhealth.apple_health.v1\|manifest\|JSONL" README.md`
Expected: no matches in the Tests/What-gets-uploaded sections. (Matches inside code blocks or unrelated history are fine; this is a sanity check.)

- [ ] **Step 13.3: Commit**

```bash
git add README.md
git commit -m "$(cat <<'EOF'
docs: update Tests section for new sync layout

Reflects the new test files (DaySample, TypeNaming, DayBucketer,
SnapshotMerger, SyncRunState) and the rewritten HealthSampleTests.
Manifest / v1 JSONL references removed.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 14: Manual verification on a real device

**Files:** none (manual QA)

Why: HealthKit reads, real OAuth, and Drive uploads can only be exercised on a physical iPhone. None of the unit tests cover the end-to-end run; this checklist does.

- [ ] **Step 14.1: Build & deploy to a paired iPhone**

In Xcode: select your iPhone destination, ⌘R.

- [ ] **Step 14.2: First-run sync (fresh state)**

Verify on the device:
1. Sign in to MyLifeDB and/or Google Drive on the Sync tab.
2. Tap "Sync now". Status should cycle Reading → Uploading <date>.
3. Each day's progress bar advances; status text shows current date.
4. After completion, "Last sync" summary shows days/samples/workouts and a green checkmark per destination.

On the remote root (MyLifeDB or Drive's `MyHealth/apple-health/`), verify:
1. Directory layout is `YYYY/MM/DD/<kebab>.json` — no `syncs/<timestamp>/` folder, no `manifest.json`.
2. Open one file in each remote — `step-count.json`, a `workout-*.json` if you have workout data, `sleep-analysis.json` if available. Validate it matches the README spec exactly: top-level `{date, type, timezone, unit?, samples}`, every sample has `start`/`end`/`value`/`type`/`source`, timestamps end in `Z`.

- [ ] **Step 14.3: Pause / resume**

1. With a slow connection (or many days of backfill), tap "Sync now".
2. After a few days have uploaded, tap "Pause".
3. Verify status shows "Paused at day X of Y."
4. Verify `Application Support/sync-run-state.json` exists on the simulator (use Xcode's container inspector).
5. Tap "Resume". Status resumes from day X+1; remote files for already-uploaded days are not re-touched (verify timestamps on remote files for days < X).

- [ ] **Step 14.4: Abort**

1. Trigger another sync.
2. Tap "Pause".
3. Tap "Abort and discard progress".
4. Verify "Last sync" still shows the previous successful run (anchors haven't moved); state file is gone.
5. Tap "Sync now" again — a fresh read of HK happens (the same samples that would have been uploaded are re-bucketed).

- [ ] **Step 14.5: App kill resume**

1. Trigger a sync.
2. After a couple of days uploaded, force-quit the app from the App Switcher.
3. Re-open. Sync tab should immediately show "Resume sync (X/Y)" and the Resume button.
4. Tap Resume; verify completion.

- [ ] **Step 14.6: Re-sync idempotency**

1. After a clean sync, tap "Sync now" again immediately.
2. Anchors are at HK head, so the read should return zero new samples.
3. No files are uploaded; state ends `.idle` with `lastResult.totalSamples == 0`.

- [ ] **Step 14.7: Snapshot merge correctness**

1. Trigger a sync.
2. Manually add a sample to Apple Health for a past day (e.g. yesterday's water intake).
3. Trigger sync again.
4. Verify yesterday's `dietary-water.json` on the remote contains both the original samples AND the new one — and the file has been re-uploaded (mtime later than the rest of the day's files).

Report any failures and decide whether to fix in place or open follow-up tickets.

---

## Self-review

**1. Spec coverage:**

| Spec section / requirement | Covered by |
|----------------------------|------------|
| Directory layout `apple-health/YYYY/MM/DD/...` | Task 3 (DayBucketer.pathPrefix), Task 8 (path build) |
| Kebab-case filenames | Task 1 (TypeNaming) |
| Day = sample's HKTimeZone (fallback to device) | Task 3 (DayBucketer.dayKey), Task 7 (SampleEncoder.timezone) |
| File envelope `{date, type, timezone, unit?, samples}` | Task 2 (DayFile + extensions) |
| Quantity sample shape | Task 2 (QuantitySample), Task 6 (SampleEncoder.encode HKQuantitySample) |
| Category sample shape with string value | Task 2 (CategorySample), Task 6 (categoryValueName) |
| Common sample fields | Task 2 (CodingKeys) |
| Workout file shape (uuid, activity_type, stats, route) | Task 2 (WorkoutFile), Task 6 (workout encoder) |
| Route point fields (t, lat, lon, alt, accuracies, speed_acc, course_acc) | Task 2 (RoutePoint), Task 6 (CLLocation mapping) |
| `route: null` for indoor workouts | Task 2 (WorkoutFile.encode emits encodeNil for route) |
| ISO 8601 UTC `Z` timestamps with fractional seconds | Task 6 (SampleEncoder.iso, ISO8601DateFormatter options) |
| Sort by `(start, end, source)` | Task 4 (SnapshotMerger.compare) |
| Snapshot semantics, complete overwrite, idempotent | Task 4 + Task 8 (GET-merge-PUT pipeline) |
| Day-by-day upload | Task 8 (runLoop iterates buckets) |
| Pausable | Task 8 (pauseRequested flag), Task 11 (UI button) |
| Abortable | Task 8 (abortRequested flag clears state), Task 11 (UI button) |
| Resumable | Task 5 (SyncRunStore.load), Task 8 (resume branch in runOnce) |
| Update anchor per day | Task 8 (SyncRunState.completedDayCount saved after each day; anchors finalized at end-of-run — see scope decision #4) |

**2. Placeholder scan:** No TBDs, no "add error handling later," no "similar to Task N" — every task has full code. ✅

**3. Type consistency:**

- `QuantitySample.uuid` is `String?` everywhere it appears.
- `WorkoutFile.DeviceInfo` consistently `name`/`model`/`systemVersion`.
- `SnapshotMerger.merge` is for quantity; `mergeCategory` is for category. Used as such in `SyncCoordinator.mergeAndUploadQuantity`/`mergeAndUploadCategory`. ✅
- `DayBucketer.DayKey` has `date`/`timezone`/`pathPrefix`. Used by `SyncRunState.DayBucket.key` and `SyncCoordinator` path construction. ✅
- `MetaValue` is the placeholder used in Task 2; renamed back to `AnyCodableValue` in Task 12 — consistent. ✅
- `SampleEncoder.deviceModelString` is overloaded (HKDevice variant + named-args variant). Tests use the named-args one. ✅

**4. Risks and known wrinkles:**

- ECG / clinical / activity-summary are removed in this plan. If the user wants them back, that's a follow-up (mentioned in scope decisions).
- `HKSource.bundleIdentifier` is an Apple property; if my recursive-property-access trick in the file-private extension is rejected by the compiler, switch to a free function. Noted in Task 6 Step 6.3.
- `BackgroundSync` pause hook uses a static weak reference — only one coordinator can be "currently active" at a time. Foreground UI sync + background BGTask never overlap on iOS (HKObserverQuery wakes coalesce), so this is safe.
- The `daySorted` JSON encoder uses `.prettyPrinted` — files are diff-friendly on the remote but ~2× the size of compact JSON. Acceptable for the use case; revisit if upload sizes hurt.
- HealthKit anchors don't have per-day granularity. Per-day **state** is checkpointed; anchors advance atomically at run completion. If a run pauses mid-day, on resume that day's already-uploaded type files are re-fetched and re-merged (idempotent — same UUIDs → no net change).
- Drive's `findFolderPath` makes O(depth) HTTP calls for each GET. For typical layouts (3 levels: YYYY/MM/DD) this is 4 calls per GET — acceptable but worth tracking if it gets noisy.
