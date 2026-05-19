# Day-by-Day Sync Rewrite Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the current "read everything, then upload day-by-day" sync with a true day-by-day-per-type pipeline so memory is bounded (no OOM on first sync) and the user sees per-day + per-type progress within seconds of pressing Sync.

**Architecture:** Drop `HKAnchoredObjectQuery` as the primary read primitive. Each sync run computes a `daysToSync: [DayKey]` from a small persistent cursor (`earliestSyncedDay`, `latestSyncedDay`) using a recent-re-sync window (last 7 days) plus a per-run backfill chunk (30 older days). Walk those days newest-first. For each day, iterate every HealthKit sample type; for each `(day, type)` run a date-predicated `HKSampleQuery`, merge with the remote snapshot (existing `SnapshotMerger`), upload one file, and discard the samples. Only one `(day, type)`'s samples are ever in memory. Pause/abort/resume checkpoint at every `(day, type)` boundary. The persistent cursor advances only on full run success.

**Tech Stack:** Swift 5.9+, SwiftUI, HealthKit, XCTest. Build via `xcodebuild`. iOS 17+.

**Scope decisions (call out for user redirect):**

1. **Anchored queries removed from the primary path.** First sync was OOM'ing because `HKAnchoredObjectQuery` with `anchor=nil` returns the entire history per type, all buffered before any upload. The new path uses `HKSampleQuery` with a per-day date predicate. The `AnchorStore` and the `HKQueryAnchor` state are deleted entirely — the day cursor is now the source of truth. The merge step (existing `SnapshotMerger`, dedup by UUID) keeps remote idempotency intact, so re-reading a day is safe and produces the same file content.
2. **Window policy = recent re-sync + backfill chunk.**
   - `recentReSyncDays = 7` — every run re-syncs the last 7 days to catch backfills (Apple Watch can backfill, users edit Health manually).
   - `backfillChunkDays = 30` — every run extends backfill 30 days older than `earliestSyncedDay` until we hit `HKHealthStore.earliestPermittedSampleDate`.
   - These two segments are unioned (not contiguous) into `daysToSync`, sorted newest-first.
3. **Direction = newest-first.** Today is uploaded within seconds; history fills in behind it. The resume cursor inside a run is `completedDayIndex` (an index into `daysToSync`, not a date watermark), which handles the non-contiguous segment shape correctly.
4. **Pause/abort semantics unchanged.** Pause halts at the next `(day, type)` boundary and persists progress. Abort halts and deletes `sync-run-state.json`. Both keep the persistent cursor untouched (it advances only on full run completion).
5. **One `(day, type)` slot per progress tick.** The UI shows "Syncing 2024-03-15 · Heart Rate (45/142)". The denominator is the full `allAnchoredSampleTypes.count`, even though most types will return zero samples for any given day — the empty-result query is cheap and the stable denominator gives an honest ETA.
6. **Migration: delete stale on-disk state on first launch of the new code.** Old `sync-run-state.json` decodes will fail against the new shape; `SyncRunStore.load` already handles that by returning nil. We also delete `anchors.json` outright because the file is no longer read.
7. **Day timezone = sample's own `HKTimeZone` metadata, falling back to device current** — unchanged from current behavior. `DayBucketer.dayKey(start:timezone:)` keeps its existing shape.
8. **Workouts are one extra "slot" after the type loop.** For each day: 142 type slots + 1 workout slot. The workout slot queries `HKSampleQuery(workoutType, day-predicate)` and, per workout, loads its route and uploads `workout-<uuid>.json`. No merge needed — workout filenames carry the UUID.

**Known limitation (accepted):** Pause/abort granularity is one (day, type) slot. If the user pauses inside the workout slot for a day with N workouts, some workouts may have uploaded and some not; on resume we advance past the workout slot. Missing workouts get caught the next time that day falls in `recentReSyncDays`; for older backfill days, they would not. Workouts are typically 0–2 per day and uploads are fast, so the exposure window is small. A future task can make workouts cancel-aware inside `syncWorkouts` and not advance the slot until the list completes.

---

## File Structure

**Create:**
- `MyHealth/Sync/SyncWindow.swift` — pure logic: `(today, cursor, earliestPermitted, recentReSyncDays, backfillChunkDays) → [DayKey]` newest-first.
- `MyHealth/Sync/SyncCursor.swift` — persistent `earliestSyncedDay` + `latestSyncedDay`, load/save at `Application Support/sync-cursor.json`.
- `Tests/SyncWindowTests.swift`
- `Tests/SyncCursorTests.swift`

**Modify (significant):**
- `MyHealth/Model/SyncRunState.swift` — drop the buckets (no samples in state anymore); replace with `daysToSync: [DayKey]`, `completedDayIndex: Int`, `inProgressTypeIndex: Int`. Delete `DayBucket`, `PersistedQuantitySample`, `PersistedCategorySample` (they are no longer needed; uuids stay on `QuantitySample.uuid` / `CategorySample.uuid` in transient memory only).
- `MyHealth/Health/HealthKitReader.swift` — remove `readBucketed`. Replace with: `readQuantity(type:day:)`, `readCategory(type:day:)`, `readWorkouts(day:deviceInfo:)`, `loadRoute(for:)`. All use `HKSampleQuery` with a day-bounded `NSPredicate`.
- `MyHealth/Sync/SyncCoordinator.swift` — full rewrite of `freshRun` / `runLoop`. New flow: load cursor → compute `daysToSync` → save run state → walk days newest-first → for each day loop types (+ workouts) → checkpoint after each `(day, type)`. On full completion: update cursor, clear run state.
- `MyHealth/UI/SyncTab.swift` — extend status display to show day + type. Update `Progress` consumer code.
- `Tests/SyncRunStateTests.swift` — rewrite for the new (much smaller) state shape.

**Delete:**
- `MyHealth/Sync/AnchorStore.swift` — no longer used.
- The file at runtime path `<Application Support>/anchors.json` — deleted on first launch of new code (one-time migration in App init).

**Untouched:**
- `MyHealth/Sync/SnapshotMerger.swift` — still does `(existing, incoming) → merged` per UUID.
- `MyHealth/Sync/DayBucketer.swift` — `DayKey` struct + `dayKey(start:timezone:)` keep being used.
- `MyHealth/Sync/TypeNaming.swift` — unchanged.
- `MyHealth/Sync/SyncRunStore.swift` — unchanged (just stores a different `SyncRunState` shape).
- `MyHealth/Sync/BackgroundSync.swift` — unchanged. It already calls `coordinator.runOnce(...)` and only inspects `coordinator.status`; the status enum keeps its existing cases.
- `MyHealth/MyLifeDB/MyLifeDBClient.swift`, `MyHealth/GoogleDrive/GoogleDriveClient.swift` — unchanged (already have `getFile` + `putBytes`/`uploadBytes`).

---

## Build & Test Commands

- **Full build + test suite:**
  ```
  xcodebuild test -scheme MyHealth -destination 'platform=iOS Simulator,name=iPhone 15'
  ```
- **Single test class:**
  ```
  xcodebuild test -scheme MyHealth -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:MyHealthTests/<ClassName>
  ```

All new tests are pure Swift (no HealthKit, no network) so the simulator does not need permissions granted.

---

## Task 1: SyncWindow — pure window-computation logic

**Files:**
- Create: `MyHealth/Sync/SyncWindow.swift`
- Test: `Tests/SyncWindowTests.swift`

- [ ] **Step 1: Write the failing test**

`Tests/SyncWindowTests.swift`:

```swift
import XCTest
@testable import MyHealth

final class SyncWindowTests: XCTestCase {

    private let tz = "Asia/Shanghai"

    private func key(_ date: String) -> DayBucketer.DayKey {
        DayBucketer.DayKey(date: date, timezone: tz)
    }

    func testFirstRun_noCursor_returnsBackfillChunkEndingToday() {
        // No prior cursor: window is [today - backfillChunkDays … today], newest-first.
        let days = SyncWindow.compute(
            today: key("2026-05-19"),
            cursor: SyncCursor(earliestSyncedDay: nil, latestSyncedDay: nil),
            earliestPermitted: key("2010-01-01"),
            recentReSyncDays: 7,
            backfillChunkDays: 30,
            timezone: tz
        )
        XCTAssertEqual(days.first?.date, "2026-05-19")
        XCTAssertEqual(days.last?.date, "2026-04-19") // 30 days back
        XCTAssertEqual(days.count, 31)               // inclusive both ends
        // All keys use the supplied timezone.
        XCTAssertTrue(days.allSatisfy { $0.timezone == tz })
    }

    func testSubsequentRun_unionsRecentAndBackfillExtension() {
        // Cursor: backfilled down to 2026-04-19, latest synced is yesterday.
        // Today is 2026-05-19, recentReSync = 7, backfillChunk = 30.
        // Expected segments:
        //   recent: 2026-05-19 … 2026-05-12   (8 days)
        //   backfill: 2026-04-18 … 2026-03-20 (30 days, one day older than earliestSyncedDay)
        let days = SyncWindow.compute(
            today: key("2026-05-19"),
            cursor: SyncCursor(earliestSyncedDay: key("2026-04-19"),
                               latestSyncedDay: key("2026-05-18")),
            earliestPermitted: key("2010-01-01"),
            recentReSyncDays: 7,
            backfillChunkDays: 30,
            timezone: tz
        )
        XCTAssertEqual(days.first?.date, "2026-05-19")
        XCTAssertEqual(days.last?.date, "2026-03-20")
        XCTAssertEqual(days.count, 8 + 30)
        // The middle (2026-05-11 down to 2026-04-19, inclusive) is skipped.
        XCTAssertFalse(days.contains { $0.date == "2026-05-11" })
        XCTAssertFalse(days.contains { $0.date == "2026-04-19" })
    }

    func testFullyBackfilled_returnsRecentWindowOnly() {
        // earliestSyncedDay already equals earliestPermitted. No more backfill possible.
        let days = SyncWindow.compute(
            today: key("2026-05-19"),
            cursor: SyncCursor(earliestSyncedDay: key("2010-01-01"),
                               latestSyncedDay: key("2026-05-18")),
            earliestPermitted: key("2010-01-01"),
            recentReSyncDays: 7,
            backfillChunkDays: 30,
            timezone: tz
        )
        XCTAssertEqual(days.first?.date, "2026-05-19")
        XCTAssertEqual(days.last?.date, "2026-05-12")
        XCTAssertEqual(days.count, 8)
    }

    func testBackfillClampedToEarliestPermitted() {
        // Only a few days remain to backfill; chunk would overshoot earliestPermitted.
        let days = SyncWindow.compute(
            today: key("2026-05-19"),
            cursor: SyncCursor(earliestSyncedDay: key("2026-01-03"),
                               latestSyncedDay: key("2026-05-18")),
            earliestPermitted: key("2026-01-01"),
            recentReSyncDays: 7,
            backfillChunkDays: 30,
            timezone: tz
        )
        // Backfill segment becomes [2026-01-02, 2026-01-01] (only 2 days, clamped).
        XCTAssertEqual(days.last?.date, "2026-01-01")
        XCTAssertTrue(days.contains { $0.date == "2026-01-02" })
        XCTAssertFalse(days.contains { $0.date == "2025-12-31" })
    }

    func testNewestFirstOrdering() {
        let days = SyncWindow.compute(
            today: key("2026-05-19"),
            cursor: SyncCursor(earliestSyncedDay: nil, latestSyncedDay: nil),
            earliestPermitted: key("2010-01-01"),
            recentReSyncDays: 7,
            backfillChunkDays: 5,
            timezone: tz
        )
        // Strictly descending by date.
        for i in 1..<days.count {
            XCTAssertGreaterThan(days[i - 1].date, days[i].date,
                                 "Days must be sorted newest-first")
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```
xcodebuild test -scheme MyHealth -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:MyHealthTests/SyncWindowTests
```
Expected: FAIL — `SyncWindow` and `SyncCursor` undefined.

- [ ] **Step 3: Write `SyncWindow.swift`**

`MyHealth/Sync/SyncWindow.swift`:

```swift
import Foundation

/// Decides which days a sync run should cover, given the persistent cursor
/// and the current date. Pure: no I/O, no HealthKit. Output is newest-first.
///
/// Policy = recent re-sync window ∪ backfill chunk.
///   - The recent window covers `[today - recentReSyncDays … today]` (inclusive
///     both ends, i.e. recentReSyncDays + 1 entries) to catch Apple-Watch /
///     manual backfills.
///   - On first run (cursor.earliestSyncedDay == nil), the backfill segment
///     primes history by emitting `backfillChunkDays` days older than today.
///   - On subsequent runs, the backfill segment extends history older than
///     `cursor.earliestSyncedDay` by `backfillChunkDays`, until
///     `earliestPermitted` is reached.
///
/// The two segments are typically NOT contiguous — the middle of already-
/// backfilled history is skipped to keep runs short. Overlap (e.g. first run
/// where the segments meet) is handled by deduping.
enum SyncWindow {

    static func compute(
        today: DayBucketer.DayKey,
        cursor: SyncCursor,
        earliestPermitted: DayBucketer.DayKey,
        recentReSyncDays: Int,
        backfillChunkDays: Int,
        timezone: String
    ) -> [DayBucketer.DayKey] {
        let recent = recentSegment(today: today,
                                   days: recentReSyncDays,
                                   earliestPermitted: earliestPermitted,
                                   timezone: timezone)
        let backfill = backfillSegment(today: today,
                                       cursor: cursor,
                                       chunk: backfillChunkDays,
                                       earliestPermitted: earliestPermitted,
                                       timezone: timezone)
        // Dedup (segments may overlap on first run) and sort newest-first.
        var seen = Set<String>()
        var out: [DayBucketer.DayKey] = []
        for k in recent + backfill where !seen.contains(k.date) {
            seen.insert(k.date)
            out.append(k)
        }
        out.sort { $0.date > $1.date }
        return out
    }

    // MARK: - private

    /// `[today, today-1, ..., today - days]`, inclusive both ends → `days + 1`
    /// entries. Clamped to earliestPermitted.
    private static func recentSegment(
        today: DayBucketer.DayKey,
        days: Int,
        earliestPermitted: DayBucketer.DayKey,
        timezone: String
    ) -> [DayBucketer.DayKey] {
        var out: [DayBucketer.DayKey] = []
        var cursor = today
        for _ in 0..<(days + 1) {
            out.append(cursor)
            if cursor.date <= earliestPermitted.date { break }
            cursor = previousDay(cursor, timezone: timezone)
        }
        return out
    }

    /// First run (cursor.earliestSyncedDay == nil):
    ///   `[today - 1, today - 2, ..., today - chunk]` — primes history below today.
    /// Subsequent runs:
    ///   `[earliestSyncedDay - 1, ..., earliestSyncedDay - chunk]` — extends backfill.
    /// Fully backfilled (earliestSyncedDay <= earliestPermitted): returns `[]`.
    /// Always clamped to earliestPermitted.
    private static func backfillSegment(
        today: DayBucketer.DayKey,
        cursor: SyncCursor,
        chunk: Int,
        earliestPermitted: DayBucketer.DayKey,
        timezone: String
    ) -> [DayBucketer.DayKey] {
        let startBoundary: DayBucketer.DayKey
        if let earliest = cursor.earliestSyncedDay {
            if earliest.date <= earliestPermitted.date { return [] }
            startBoundary = previousDay(earliest, timezone: timezone)
        } else {
            // First run: backfill starts the day before today.
            startBoundary = previousDay(today, timezone: timezone)
        }
        var out: [DayBucketer.DayKey] = []
        var c = startBoundary
        for _ in 0..<chunk {
            out.append(c)
            if c.date <= earliestPermitted.date { break }
            c = previousDay(c, timezone: timezone)
        }
        return out
    }

    private static func previousDay(_ k: DayBucketer.DayKey, timezone: String) -> DayBucketer.DayKey {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: timezone) ?? .current
        let formatter = DateFormatter()
        formatter.calendar = cal
        formatter.timeZone = cal.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: k.date),
              let prev = cal.date(byAdding: .day, value: -1, to: date)
        else { return k }
        return DayBucketer.DayKey(date: formatter.string(from: prev), timezone: timezone)
    }
}
```

- [ ] **Step 4: Add a placeholder `SyncCursor` so the file compiles**

The full implementation lives in Task 2 — for now, add the minimum needed for `SyncWindow.swift` and its tests to compile, in `MyHealth/Sync/SyncCursor.swift`:

```swift
import Foundation

struct SyncCursor: Codable, Equatable {
    var earliestSyncedDay: DayBucketer.DayKey?
    var latestSyncedDay: DayBucketer.DayKey?
}
```

- [ ] **Step 5: Run tests to verify they pass**

```
xcodebuild test -scheme MyHealth -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:MyHealthTests/SyncWindowTests
```
Expected: 5 tests PASS.

- [ ] **Step 6: Commit**

```bash
git add MyHealth/Sync/SyncWindow.swift MyHealth/Sync/SyncCursor.swift Tests/SyncWindowTests.swift
git commit -m "feat(sync): add SyncWindow pure day-window computation"
```

---

## Task 2: SyncCursor — persistent earliest/latest cursor

**Files:**
- Modify: `MyHealth/Sync/SyncCursor.swift` (fill in load/save)
- Test: `Tests/SyncCursorTests.swift`

- [ ] **Step 1: Write the failing test**

`Tests/SyncCursorTests.swift`:

```swift
import XCTest
@testable import MyHealth

final class SyncCursorTests: XCTestCase {

    private var tmpURL: URL!

    override func setUp() {
        tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sync-cursor-\(UUID()).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpURL)
    }

    func testLoadReturnsEmptyCursorWhenFileMissing() {
        let cursor = SyncCursor.load(at: tmpURL)
        XCTAssertNil(cursor.earliestSyncedDay)
        XCTAssertNil(cursor.latestSyncedDay)
    }

    func testSaveLoadRoundTrip() throws {
        let original = SyncCursor(
            earliestSyncedDay: DayBucketer.DayKey(date: "2026-04-19", timezone: "Asia/Shanghai"),
            latestSyncedDay:   DayBucketer.DayKey(date: "2026-05-18", timezone: "Asia/Shanghai")
        )
        try SyncCursor.save(original, at: tmpURL)
        let loaded = SyncCursor.load(at: tmpURL)
        XCTAssertEqual(loaded, original)
    }

    func testAdvanceExtendsBothEnds() {
        var cursor = SyncCursor(
            earliestSyncedDay: DayBucketer.DayKey(date: "2026-04-19", timezone: "Asia/Shanghai"),
            latestSyncedDay:   DayBucketer.DayKey(date: "2026-05-18", timezone: "Asia/Shanghai")
        )
        // A run completed covering [2026-05-19 (newest) … 2026-03-20 (oldest)].
        cursor.advance(coveredDays: [
            DayBucketer.DayKey(date: "2026-05-19", timezone: "Asia/Shanghai"),
            DayBucketer.DayKey(date: "2026-05-12", timezone: "Asia/Shanghai"),
            DayBucketer.DayKey(date: "2026-04-18", timezone: "Asia/Shanghai"),
            DayBucketer.DayKey(date: "2026-03-20", timezone: "Asia/Shanghai"),
        ])
        XCTAssertEqual(cursor.latestSyncedDay?.date, "2026-05-19")
        XCTAssertEqual(cursor.earliestSyncedDay?.date, "2026-03-20")
    }

    func testAdvanceFromEmpty() {
        var cursor = SyncCursor(earliestSyncedDay: nil, latestSyncedDay: nil)
        cursor.advance(coveredDays: [
            DayBucketer.DayKey(date: "2026-05-19", timezone: "Asia/Shanghai"),
            DayBucketer.DayKey(date: "2026-04-19", timezone: "Asia/Shanghai"),
        ])
        XCTAssertEqual(cursor.latestSyncedDay?.date, "2026-05-19")
        XCTAssertEqual(cursor.earliestSyncedDay?.date, "2026-04-19")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```
xcodebuild test -scheme MyHealth -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:MyHealthTests/SyncCursorTests
```
Expected: FAIL — missing `SyncCursor.load`, `.save`, `.advance`.

- [ ] **Step 3: Implement SyncCursor**

Replace the placeholder `MyHealth/Sync/SyncCursor.swift` with:

```swift
import Foundation

/// Persistent watermark for day-by-day sync. Stored at
/// `<Application Support>/sync-cursor.json`. Advances only when a full
/// sync run completes.
struct SyncCursor: Codable, Equatable {
    var earliestSyncedDay: DayBucketer.DayKey?
    var latestSyncedDay: DayBucketer.DayKey?

    static let defaultURL: URL = {
        let dir = try! FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return dir.appendingPathComponent("sync-cursor.json")
    }()

    static func load(at url: URL = defaultURL) -> SyncCursor {
        guard let data = try? Data(contentsOf: url),
              let cursor = try? JSONDecoder().decode(SyncCursor.self, from: data)
        else { return SyncCursor(earliestSyncedDay: nil, latestSyncedDay: nil) }
        return cursor
    }

    static func save(_ cursor: SyncCursor, at url: URL = defaultURL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        let data = try encoder.encode(cursor)
        try data.write(to: url, options: .atomic)
    }

    /// Updates the cursor to reflect that every day in `coveredDays` has been
    /// fully synced in the just-completed run. `coveredDays` may be in any
    /// order; `earliestSyncedDay` advances to the oldest and `latestSyncedDay`
    /// to the newest, monotonically (never moves backward).
    mutating func advance(coveredDays: [DayBucketer.DayKey]) {
        guard !coveredDays.isEmpty else { return }
        let dates = coveredDays.map { $0.date }
        let newest = coveredDays[dates.firstIndex(of: dates.max()!)!]
        let oldest = coveredDays[dates.firstIndex(of: dates.min()!)!]
        if latestSyncedDay == nil || newest.date > latestSyncedDay!.date {
            latestSyncedDay = newest
        }
        if earliestSyncedDay == nil || oldest.date < earliestSyncedDay!.date {
            earliestSyncedDay = oldest
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```
xcodebuild test -scheme MyHealth -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:MyHealthTests/SyncCursorTests
```
Expected: 4 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add MyHealth/Sync/SyncCursor.swift Tests/SyncCursorTests.swift
git commit -m "feat(sync): add persistent SyncCursor with advance() semantics"
```

---

## Task 3: SyncRunState — slim down to (daysToSync, indices)

**Files:**
- Modify: `MyHealth/Model/SyncRunState.swift` (replace contents)
- Modify: `Tests/SyncRunStateTests.swift` (rewrite)

- [ ] **Step 1: Replace `SyncRunState.swift`**

```swift
import Foundation

/// Persisted state for an in-progress day-by-day sync. Lives at
/// `Application Support/sync-run-state.json` while a run is active or paused;
/// deleted when the run completes or the user aborts.
///
/// The state is intentionally tiny — no samples are buffered. The day cursor
/// (`completedDayIndex`) and the per-day type cursor (`inProgressTypeIndex`)
/// together pinpoint exactly where to resume. Both indices count "fully
/// uploaded" units, so a fresh run starts at (0, 0) and a run that has
/// uploaded the first day fully and is mid-way through the second day's
/// 45th type checkpoint sits at (1, 45).
struct SyncRunState: Codable, Equatable {
    let runID: String                            // "20260519T120000Z"
    let startedAt: String                        // ISO 8601 UTC
    let daysToSync: [DayBucketer.DayKey]         // newest-first
    var completedDayIndex: Int                   // days < this are fully uploaded
    var inProgressTypeIndex: Int                 // within day [completedDayIndex], types < this are done
}
```

- [ ] **Step 2: Rewrite `Tests/SyncRunStateTests.swift`**

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
        let days = [
            DayBucketer.DayKey(date: "2026-05-19", timezone: "Asia/Shanghai"),
            DayBucketer.DayKey(date: "2026-05-18", timezone: "Asia/Shanghai"),
        ]
        let state = SyncRunState(
            runID: "20260519T120000Z",
            startedAt: "2026-05-19T12:00:00Z",
            daysToSync: days,
            completedDayIndex: 1,
            inProgressTypeIndex: 45
        )
        try SyncRunStore.save(state, at: tmpURL)
        let loaded = try XCTUnwrap(SyncRunStore.load(at: tmpURL))
        XCTAssertEqual(loaded, state)
    }

    func testLoadReturnsNilWhenFileMissing() {
        XCTAssertNil(SyncRunStore.load(at: tmpURL))
    }

    func testClearRemovesFile() throws {
        let state = SyncRunState(
            runID: "x", startedAt: "x",
            daysToSync: [], completedDayIndex: 0, inProgressTypeIndex: 0
        )
        try SyncRunStore.save(state, at: tmpURL)
        XCTAssertNotNil(SyncRunStore.load(at: tmpURL))
        SyncRunStore.clear(at: tmpURL)
        XCTAssertNil(SyncRunStore.load(at: tmpURL))
    }
}
```

- [ ] **Step 3: Build — will fail; `SyncCoordinator` and `HealthKitReader` still reference old types**

```
xcodebuild build -scheme MyHealth -destination 'platform=iOS Simulator,name=iPhone 15'
```
Expected: BUILD FAILED. Errors will mention `DayBucket`, `PersistedQuantitySample`, `PersistedCategorySample`, `buckets`, `completedDayCount`, etc. — all the old shapes. Leave them; Task 4 and Task 5 fix them.

- [ ] **Step 4: Do not commit yet** — the codebase is in a broken state. Continue to Task 4. Commit will be combined with the coordinator rewrite once the build is green again.

---

## Task 4: HealthKitReader — per-day, per-type sample queries

**Files:**
- Replace: `MyHealth/Health/HealthKitReader.swift`

- [ ] **Step 1: Replace the file**

```swift
import Foundation
import HealthKit
import CoreLocation

/// Reads HealthKit samples one day-at-a-time, one type-at-a-time. Memory is
/// bounded to a single `(day, type)` slice. No anchored queries — the caller
/// (SyncCoordinator) drives iteration via the day cursor.
struct HealthKitReader {
    let store: HKHealthStore

    init(store: HKHealthStore = HKHealthStore()) {
        self.store = store
    }

    /// Quantity samples for one type, restricted to `day`'s `[00:00, 24:00)`
    /// in the day's own timezone.
    func readQuantity(type: HKQuantityType, day: DayBucketer.DayKey) async throws -> [QuantitySample] {
        let predicate = dayPredicate(day: day)
        let samples: [HKSample] = try await runSampleQuery(type: type, predicate: predicate)
        return samples.compactMap { sample in
            guard let q = sample as? HKQuantitySample else { return nil }
            return SampleEncoder.encode(q)
        }
    }

    /// Category samples for one type for `day`.
    func readCategory(type: HKCategoryType, day: DayBucketer.DayKey) async throws -> [CategorySample] {
        let predicate = dayPredicate(day: day)
        let samples: [HKSample] = try await runSampleQuery(type: type, predicate: predicate)
        return samples.compactMap { sample in
            guard let c = sample as? HKCategorySample else { return nil }
            return SampleEncoder.encode(c)
        }
    }

    /// Workouts whose `startDate` falls in `day`. Caller iterates and calls
    /// `loadRoute(for:)` per workout, so route memory is per-workout-bounded.
    func readWorkouts(day: DayBucketer.DayKey) async throws -> [HKWorkout] {
        let predicate = dayPredicate(day: day)
        let samples: [HKSample] = try await runSampleQuery(
            type: HKObjectType.workoutType(),
            predicate: predicate
        )
        return samples.compactMap { $0 as? HKWorkout }
    }

    /// Locations for a single workout's route. Returns nil if no route was recorded.
    func loadRoute(for workout: HKWorkout) async throws -> [CLLocation]? {
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

    // MARK: - Predicate

    /// `[startOfDay, startOfNextDay)` in the day's own timezone.
    private func dayPredicate(day: DayBucketer.DayKey) -> NSPredicate {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: day.timezone) ?? .current
        let formatter = DateFormatter()
        formatter.calendar = cal
        formatter.timeZone = cal.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        let start = formatter.date(from: day.date) ?? Date()
        let end = cal.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86400)
        return HKQuery.predicateForSamples(withStart: start, end: end, options: [.strictStartDate])
    }

    // MARK: - HKSampleQuery wrapper

    private func runSampleQuery(type: HKSampleType, predicate: NSPredicate) async throws -> [HKSample] {
        try await withCheckedThrowingContinuation { cont in
            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, samples, error in
                if let error {
                    // Authorization not determined / denied: treat as empty (matches
                    // prior behavior of the anchored-query path).
                    if let hk = error as? HKError,
                       hk.code == .errorAuthorizationNotDetermined || hk.code == .errorAuthorizationDenied {
                        cont.resume(returning: [])
                        return
                    }
                    cont.resume(throwing: error)
                    return
                }
                cont.resume(returning: samples ?? [])
            }
            store.execute(query)
        }
    }
}
```

- [ ] **Step 2: Do not commit yet** — `SyncCoordinator` still references `readBucketed` etc. Continue.

---

## Task 5: SyncCoordinator — new day-by-day state machine

**Files:**
- Replace: `MyHealth/Sync/SyncCoordinator.swift`

- [ ] **Step 1: Replace the file**

```swift
import Foundation
import HealthKit
import UIKit

/// Orchestrates one day-by-day sync. Top-level flow:
///   1. Load persistent SyncCursor.
///   2. Compute daysToSync (newest-first) from cursor + today + window policy.
///   3. Persist SyncRunState (just the day list + cursors — no samples).
///   4. Walk daysToSync, for each day iterate every sample type:
///        HKSampleQuery(type, day-predicate) → merge with remote → PUT.
///      Then workouts → upload one file per workout.
///      Pause/abort flags are polled between every (day, type) boundary.
///   5. On full completion: advance SyncCursor, clear SyncRunState.
///
/// Pause keeps state. Abort deletes it. Resume picks up at the saved
/// (completedDayIndex, inProgressTypeIndex).
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
        let currentDate: String?
        let currentTypeIndex: Int
        let totalTypes: Int
        let currentTypeName: String?
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

    /// Tunables — match the values committed to the design (Q1 = option b).
    private let recentReSyncDays = 7
    private let backfillChunkDays = 30

    static weak var currentlyActive: SyncCoordinator?

    init(reader: HealthKitReader = HealthKitReader()) {
        self.reader = reader
    }

    // MARK: - Public control surface

    func runOnce(enabledDestinations: Set<Destination>) async {
        Self.currentlyActive = self
        defer { if Self.currentlyActive === self { Self.currentlyActive = nil } }
        pauseRequested = false
        abortRequested = false
        if let existing = SyncRunStore.load() {
            print("MyHealth: resuming run id=\(existing.runID) at day \(existing.completedDayIndex)/\(existing.daysToSync.count) typeIndex=\(existing.inProgressTypeIndex)")
            await runLoop(state: existing, enabledDestinations: enabledDestinations)
        } else {
            await freshRun(enabledDestinations: enabledDestinations)
        }
    }

    func pause() { pauseRequested = true }
    func abort() { abortRequested = true }

    var hasPendingRun: Bool { SyncRunStore.load() != nil }

    // MARK: - Fresh run

    private func freshRun(enabledDestinations: Set<Destination>) async {
        let started = Date()
        let runID = makeRunID(date: started)
        do {
            status = .running(stage: String(localized: "Preparing sync"))
            let cursor = SyncCursor.load()
            let tz = TimeZone.current.identifier
            let today = DayBucketer.dayKey(start: started, timezone: TimeZone.current)
            let earliestPermitted = DayBucketer.dayKey(
                start: HKHealthStore().earliestPermittedSampleDate(),
                timezone: TimeZone.current
            )
            let days = SyncWindow.compute(
                today: today,
                cursor: cursor,
                earliestPermitted: earliestPermitted,
                recentReSyncDays: recentReSyncDays,
                backfillChunkDays: backfillChunkDays,
                timezone: tz
            )
            print("MyHealth: window computed days=\(days.count) newest=\(days.first?.date ?? "-") oldest=\(days.last?.date ?? "-")")

            let state = SyncRunState(
                runID: runID,
                startedAt: SampleEncoder.iso(started),
                daysToSync: days,
                completedDayIndex: 0,
                inProgressTypeIndex: 0
            )
            try SyncRunStore.save(state)
            await runLoop(state: state, enabledDestinations: enabledDestinations)
        } catch {
            status = .error(error.localizedDescription)
            print("MyHealth: sync FAILED stage=fresh-run error=\(error.localizedDescription)")
        }
    }

    // MARK: - Day loop

    private func runLoop(state initialState: SyncRunState,
                         enabledDestinations: Set<Destination>) async {
        var state = initialState
        let mldSession: MyLifeDBSession? = enabledDestinations.contains(.myLifeDB)
            ? (try? TokenStore.load()) ?? nil : nil
        let mldClient: MyLifeDBClient? = mldSession.map { MyLifeDBClient(session: $0) }
        let driveAvailable = enabledDestinations.contains(.googleDrive) && DriveAuth.currentUser != nil
        let drive: GoogleDriveClient? = driveAvailable ? GoogleDriveClient() : nil

        let deviceInfo = WorkoutFile.DeviceInfo(
            name: UIDevice.current.name,
            model: deviceModel(),
            systemVersion: UIDevice.current.systemVersion
        )

        // Per-day type sequence (deterministic, stable order).
        let typeSequence = HealthDataTypes.allAnchoredSampleTypes
            .filter { !($0 is HKWorkoutType) }
        let workoutSlotIndex = typeSequence.count  // workouts are the (count)th slot
        let totalSlots = workoutSlotIndex + 1

        var totalSamples = 0
        var totalWorkouts = 0

        do {
            for dayIdx in state.completedDayIndex..<state.daysToSync.count {
                if abortRequested {
                    print("MyHealth: aborting at day \(dayIdx)/\(state.daysToSync.count)")
                    SyncRunStore.clear()
                    self.status = .idle
                    self.progress = nil
                    return
                }
                if pauseRequested {
                    print("MyHealth: paused at day \(dayIdx)/\(state.daysToSync.count) typeIdx=\(state.inProgressTypeIndex)")
                    state.completedDayIndex = dayIdx
                    try SyncRunStore.save(state)
                    self.status = .paused(completedDays: dayIdx, totalDays: state.daysToSync.count)
                    self.progress = Progress(
                        completedDays: dayIdx, totalDays: state.daysToSync.count,
                        currentDate: nil, currentTypeIndex: state.inProgressTypeIndex,
                        totalTypes: totalSlots, currentTypeName: nil
                    )
                    return
                }

                let day = state.daysToSync[dayIdx]
                // Resume mid-day if applicable.
                let startTypeIdx = (dayIdx == state.completedDayIndex) ? state.inProgressTypeIndex : 0

                for typeIdx in startTypeIdx..<totalSlots {
                    if abortRequested {
                        print("MyHealth: aborting mid-day at day \(dayIdx)/\(state.daysToSync.count) typeIdx=\(typeIdx)")
                        SyncRunStore.clear()
                        self.status = .idle
                        self.progress = nil
                        return
                    }
                    if pauseRequested {
                        state.completedDayIndex = dayIdx
                        state.inProgressTypeIndex = typeIdx
                        try SyncRunStore.save(state)
                        self.status = .paused(completedDays: dayIdx, totalDays: state.daysToSync.count)
                        self.progress = Progress(
                            completedDays: dayIdx, totalDays: state.daysToSync.count,
                            currentDate: day.date, currentTypeIndex: typeIdx,
                            totalTypes: totalSlots, currentTypeName: nil
                        )
                        return
                    }

                    if typeIdx == workoutSlotIndex {
                        let displayName = String(localized: "Workouts")
                        self.status = .running(stage: String(localized: "Syncing \(day.date) · \(displayName)"))
                        self.progress = Progress(
                            completedDays: dayIdx, totalDays: state.daysToSync.count,
                            currentDate: day.date, currentTypeIndex: typeIdx,
                            totalTypes: totalSlots, currentTypeName: displayName
                        )
                        let n = try await syncWorkouts(day: day, deviceInfo: deviceInfo, mld: mldClient, drive: drive)
                        totalWorkouts += n
                    } else {
                        let sampleType = typeSequence[typeIdx]
                        let displayName = TypeNaming.displayName(for: sampleType.identifier)
                        self.status = .running(stage: String(localized: "Syncing \(day.date) · \(displayName)"))
                        self.progress = Progress(
                            completedDays: dayIdx, totalDays: state.daysToSync.count,
                            currentDate: day.date, currentTypeIndex: typeIdx,
                            totalTypes: totalSlots, currentTypeName: displayName
                        )
                        if let q = sampleType as? HKQuantityType {
                            let n = try await syncQuantity(day: day, type: q, mld: mldClient, drive: drive)
                            totalSamples += n
                        } else if let c = sampleType as? HKCategoryType {
                            let n = try await syncCategory(day: day, type: c, mld: mldClient, drive: drive)
                            totalSamples += n
                        }
                    }

                    // Checkpoint after every (day, type) slot.
                    state.completedDayIndex = dayIdx
                    state.inProgressTypeIndex = typeIdx + 1
                    try SyncRunStore.save(state)
                }

                // Day complete. Advance day index, reset type index.
                state.completedDayIndex = dayIdx + 1
                state.inProgressTypeIndex = 0
                try SyncRunStore.save(state)
            }

            try await finalize(state: state, totalSamples: totalSamples, totalWorkouts: totalWorkouts,
                               mldUploaded: mldClient != nil, driveUploaded: drive != nil)
        } catch {
            try? SyncRunStore.save(state)
            self.status = .error(error.localizedDescription)
            print("MyHealth: sync FAILED stage=day-loop error=\(error.localizedDescription)")
        }
    }

    private func finalize(state: SyncRunState, totalSamples: Int, totalWorkouts: Int,
                          mldUploaded: Bool, driveUploaded: Bool) async throws {
        var cursor = SyncCursor.load()
        cursor.advance(coveredDays: state.daysToSync)
        try SyncCursor.save(cursor)
        SyncRunStore.clear()
        let result = SyncRunResult(
            runID: state.runID,
            totalSamples: totalSamples,
            totalWorkouts: totalWorkouts,
            totalDays: state.daysToSync.count,
            myLifeDBUploaded: mldUploaded,
            driveUploaded: driveUploaded,
            finishedAt: Date()
        )
        self.lastResult = result
        self.status = .idle
        self.progress = nil
        print("MyHealth: sync done run=\(state.runID) samples=\(totalSamples) workouts=\(totalWorkouts) days=\(state.daysToSync.count)")
    }

    // MARK: - Per-(day, type) slots

    private func syncQuantity(
        day: DayBucketer.DayKey, type: HKQuantityType,
        mld: MyLifeDBClient?, drive: GoogleDriveClient?
    ) async throws -> Int {
        let incoming = try await reader.readQuantity(type: type, day: day)
        if incoming.isEmpty { return 0 }
        let filename = TypeNaming.filename(for: type.identifier)
        let path = "\(day.pathPrefix)/\(filename)"
        let existing = try await getExistingQuantity(path: path, mld: mld, drive: drive)
        let merged = SnapshotMerger.merge(existing: existing, incoming: incoming)
        let unit = merged.first?.unit ?? incoming.first?.unit ?? ""
        let envelope = DayFile.quantity(
            date: day.date, type: type.identifier, timezone: day.timezone,
            unit: unit, samples: merged
        )
        let body = try JSONEncoder.daySorted.encode(envelope)
        try await put(path: path, body: body, mld: mld, drive: drive)
        return merged.count
    }

    private func syncCategory(
        day: DayBucketer.DayKey, type: HKCategoryType,
        mld: MyLifeDBClient?, drive: GoogleDriveClient?
    ) async throws -> Int {
        let incoming = try await reader.readCategory(type: type, day: day)
        if incoming.isEmpty { return 0 }
        let filename = TypeNaming.filename(for: type.identifier)
        let path = "\(day.pathPrefix)/\(filename)"
        let existing = try await getExistingCategory(path: path, mld: mld, drive: drive)
        let merged = SnapshotMerger.mergeCategory(existing: existing, incoming: incoming)
        let envelope = DayFile.category(
            date: day.date, type: type.identifier, timezone: day.timezone,
            samples: merged
        )
        let body = try JSONEncoder.daySorted.encode(envelope)
        try await put(path: path, body: body, mld: mld, drive: drive)
        return merged.count
    }

    private func syncWorkouts(
        day: DayBucketer.DayKey, deviceInfo: WorkoutFile.DeviceInfo,
        mld: MyLifeDBClient?, drive: GoogleDriveClient?
    ) async throws -> Int {
        let workouts = try await reader.readWorkouts(day: day)
        var uploaded = 0
        for w in workouts {
            if abortRequested || pauseRequested { break }
            let route = (try? await reader.loadRoute(for: w)) ?? nil
            let wf = SampleEncoder.encode(w, events: w.workoutEvents, route: route, deviceInfo: deviceInfo)
            let filename = TypeNaming.workoutFilename(uuid: wf.uuid)
            let path = "\(day.pathPrefix)/\(filename)"
            let body = try JSONEncoder.daySorted.encode(wf)
            try await put(path: path, body: body, mld: mld, drive: drive)
            uploaded += 1
        }
        return uploaded
    }

    private func getExistingQuantity(path: String, mld: MyLifeDBClient?, drive: GoogleDriveClient?) async throws -> [QuantitySample] {
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
    static var daySorted: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return e
    }
}
```

- [ ] **Step 2: Add `TypeNaming.displayName(for:)`**

The coordinator calls `TypeNaming.displayName(for: identifier)` for the UI status line. Add it to `MyHealth/Sync/TypeNaming.swift`:

```swift
    /// Human-readable display name for a HealthKit type identifier — uses the
    /// curated catalog if available, otherwise falls back to a title-cased
    /// version of the kebab filename stem. Used by SyncCoordinator's progress
    /// line.
    static func displayName(for typeIdentifier: String) -> String {
        if let entry = HealthTypeCatalog.entry(for: typeIdentifier) {
            return entry.displayName
        }
        // Fallback: kebab → Title Case.
        let stem = kebab(stripPrefix(typeIdentifier))
        return stem.split(separator: "-")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
```

- [ ] **Step 3: Build**

```
xcodebuild build -scheme MyHealth -destination 'platform=iOS Simulator,name=iPhone 15'
```
Expected: BUILD SUCCEEDED, with two remaining errors:
  - `SyncTab.swift` reads `coordinator.progress.completedDays` / `.totalDays` which still compile (same field names), but the paused-text references `(done, total)` which still works. If anything else breaks, note the errors and fix them in Task 6.
  - `AnchorStore` is now unused — the compiler will not error, but there's a dead file. Task 7 removes it.

If the build fails for any reason inside `SyncCoordinator`, re-check the references against the existing `DayFile`, `MyLifeDBClient`, `GoogleDriveClient`, `SampleEncoder.iso(_:)`, `SampleEncoder.encode(_:events:route:deviceInfo:)` signatures. Adapt to whatever already exists; do not edit those files.

- [ ] **Step 4: Do not commit yet** — Task 6 updates the UI and re-runs the full suite. We commit once everything builds and tests pass.

---

## Task 6: SyncTab UI — show day + type in progress

**Files:**
- Modify: `MyHealth/UI/SyncTab.swift`

- [ ] **Step 1: Update `statusLine` and resume text**

Replace the `statusLine` computed property in `SyncTab.swift` (currently around lines 147-165) with:

```swift
    @ViewBuilder
    private var statusLine: some View {
        switch coordinator.status {
        case .running(let stage):
            HStack(spacing: 8) {
                ProgressView()
                Text(stage).foregroundStyle(.secondary).font(.caption)
            }
            if let p = coordinator.progress {
                VStack(alignment: .leading, spacing: 4) {
                    if let date = p.currentDate, let typeName = p.currentTypeName {
                        Text("\(date) · \(typeName) (\(p.currentTypeIndex + 1)/\(p.totalTypes))")
                            .font(.caption2).foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    ProgressView(value: Double(p.completedDays), total: Double(max(1, p.totalDays)))
                    Text("Day \(p.completedDays + 1) of \(p.totalDays)")
                        .font(.caption2).foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        case .paused(let done, let total):
            Text("Paused at day \(done) of \(total).").foregroundStyle(.secondary).font(.caption)
        case .error(let msg):
            Text(msg).foregroundStyle(.red).font(.caption)
        case .idle:
            EmptyView()
        }
    }
```

This shows three lines while running:
- "Syncing 2024-03-15 · Heart Rate" (the `stage` label set by the coordinator)
- "2024-03-15 · Heart Rate (45/142)" (granular)
- progress bar over days + "Day 3 of 730"

If the existing localized strings already cover "Day X of Y" / "Paused at day X of Y", reuse them. Otherwise the literal strings above are acceptable (they'll be picked up at the next i18n pass).

- [ ] **Step 2: Build**

```
xcodebuild build -scheme MyHealth -destination 'platform=iOS Simulator,name=iPhone 15'
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Run the full test suite**

```
xcodebuild test -scheme MyHealth -destination 'platform=iOS Simulator,name=iPhone 15'
```
Expected: all tests PASS, including the previously-existing `DayBucketerTests`, `TypeNamingTests`, `SnapshotMergerTests`, `DaySampleTests`, `HealthSampleTests`, `PKCETests`, plus the rewritten `SyncRunStateTests` and the new `SyncWindowTests`, `SyncCursorTests`.

If any existing test fails because it referenced the old `DayBucket` / `PersistedQuantitySample` types, either delete that test (if its coverage is now meaningless) or rewrite it against the new state shape. Note the change in the commit message.

- [ ] **Step 4: Commit the rewrite as one chunk**

```bash
git add MyHealth/Model/SyncRunState.swift \
        MyHealth/Health/HealthKitReader.swift \
        MyHealth/Sync/SyncCoordinator.swift \
        MyHealth/Sync/TypeNaming.swift \
        MyHealth/UI/SyncTab.swift \
        Tests/SyncRunStateTests.swift
git commit -m "refactor(sync): day-by-day per-type sync, no buffering

Drops HKAnchoredObjectQuery (anchor=nil was OOM-crashing the first sync
by buffering all history in memory). Each sync run now walks days
newest-first; for every (day, type) it runs a date-predicated
HKSampleQuery, merges with the remote snapshot, uploads one file, and
discards the samples. Memory is bounded to one (day, type) slice.

A small persistent SyncCursor (earliestSyncedDay, latestSyncedDay)
drives window selection: re-sync last 7 days every run (catches
backfills) + extend backfill 30 days older per run until
HKHealthStore.earliestPermittedSampleDate is reached.

UI shows 'Syncing 2024-03-15 · Heart Rate (45/142)' so the user sees
both day and type ticking. Pause/abort/resume checkpoint after every
(day, type) boundary."
```

---

## Task 7: Delete AnchorStore + migrate stale on-disk state

**Files:**
- Delete: `MyHealth/Sync/AnchorStore.swift`
- Modify: `MyHealth/MyHealthApp.swift` (one-time migration at launch)

- [ ] **Step 1: Delete AnchorStore.swift**

```bash
git rm MyHealth/Sync/AnchorStore.swift
```

(If Xcode still has a reference, remove it from the project file too — open `MyHealth.xcodeproj` and confirm no `AnchorStore.swift` reference remains, or remove via `xcodeproj` shell.)

- [ ] **Step 2: Add a one-time migration**

Read the current `MyHealth/MyHealthApp.swift` first:

```bash
cat MyHealth/MyHealthApp.swift
```

Find the App init or the first `onAppear`/`task` at the root view (look for where `BackgroundSync.register()` is called — the migration belongs next to it). Add at App-startup time, before any sync runs:

```swift
        // One-time migration: anchors.json is no longer read. Old in-progress
        // sync-run-state.json has a different shape and SyncRunStore.load
        // returns nil for it, but the file lingers — remove it too.
        let appSupport = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false
        )
        if let appSupport {
            for stale in ["anchors.json"] {
                let url = appSupport.appendingPathComponent(stale)
                try? FileManager.default.removeItem(at: url)
            }
            // Stale sync-run-state.json: try to decode against the new shape.
            // If that fails, remove it so we start clean.
            let stateURL = appSupport.appendingPathComponent("sync-run-state.json")
            if let data = try? Data(contentsOf: stateURL),
               (try? JSONDecoder().decode(SyncRunState.self, from: data)) == nil {
                try? FileManager.default.removeItem(at: stateURL)
            }
        }
```

- [ ] **Step 3: Build + run full tests**

```
xcodebuild test -scheme MyHealth -destination 'platform=iOS Simulator,name=iPhone 15'
```
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "chore(sync): drop AnchorStore, add one-time migration of stale state"
```

---

## Task 8: Manual smoke test on a real device

> The unit suite covers pure logic. The HealthKit + network path can only be verified end-to-end. This task is for the human reviewer; an agentic worker should stop here and hand off.

- [ ] **Step 1: Run on device with HealthKit populated**

Build & deploy to a real iPhone with multiple years of HealthKit data.

- [ ] **Step 2: Press Sync Now — verify within seconds:**
  - Status text changes to "Syncing 2026-05-19 · Step Count" (or whichever type comes first in the iteration order).
  - The per-type counter advances visibly: "(1/142)", "(2/142)", ...
  - The day counter is "Day 1 of N" where N matches `recentReSyncDays + 1 + backfillChunkDays` ≈ 38 for the first run.
  - **No OOM crash.** Memory in Xcode's Debug Navigator stays bounded (well under 200 MB).

- [ ] **Step 3: Test pause + resume mid-day**
  - Tap Pause while a day is in progress.
  - Status becomes "Paused at day X of N".
  - Tap Resume — confirm it picks up at the same `(day, type)` it stopped, not from the start of the day.

- [ ] **Step 4: Test abort**
  - Run again, abort mid-way.
  - Confirm `sync-run-state.json` is deleted (the Resume button disappears).
  - Confirm `sync-cursor.json` is unchanged (next Sync Now starts fresh with the same window).

- [ ] **Step 5: Run sync twice in a row**
  - Second run should complete much faster — most days will have already-matching files; merges produce identical content. Confirm cursor extends further into history.

- [ ] **Step 6: Open the remote (MyLifeDB or Drive) and spot-check**
  - A few day files exist under `YYYY/MM/DD/<type>.json`.
  - Workout files under `YYYY/MM/DD/workout-<uuid>.json`.
  - Sample content looks right (sorted by `(start, end, source)`, dedup'd).

---

## Self-Review checklist (run before handing off)

- [ ] Every task contains the full code for the files it touches — no "TBD" or "see existing".
- [ ] All cross-task references match: `SyncCursor.advance(coveredDays:)`, `SyncWindow.compute(today:cursor:earliestPermitted:recentReSyncDays:backfillChunkDays:timezone:)`, `SyncRunState(daysToSync:completedDayIndex:inProgressTypeIndex:)`, `Progress(completedDays:totalDays:currentDate:currentTypeIndex:totalTypes:currentTypeName:)` — used the same way in every task.
- [ ] No code references the deleted `BucketAccumulator`, `PersistedQuantitySample`, `PersistedCategorySample`, `DayBucket`, `readBucketed`, `AnchorStore`, `HKQueryAnchor` (other than the local variable inside `loadRoute` which is intentional — workout-route loading still uses one anchored query as a one-shot fetch; that's separate from sync's incremental state).
- [ ] OOM-proofness invariant holds: at every step inside `runLoop`, the only sample data alive is for one `(day, type)` slot. `SyncRunState` contains no samples.
- [ ] Cursor advances only inside `finalize` (after a fully-clean run). Pause and abort never advance it.
