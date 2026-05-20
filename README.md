# MyHealth

A FOSS iOS app that reads your Apple Health data straight from HealthKit and syncs it to:

- **MyLifeDB**, via the [Connect OAuth 2.1 + PKCE flow](https://my.xiaoyuanzhu.com/docs/internal/api/connect/), uploaded under `/apps/apple-health/`.
- **Google Drive**, via the official Google Sign-In SDK + Drive REST API, into an `apple-health/` folder. The app uses the `drive.file` scope, so it can only see and modify files it created itself.

No middleman, no backend, no analytics. The app reads HealthKit on-device, writes per-day JSON files to your own destinations, and that's it.

## Build & install

MyHealth has no App Store presence. You build it from source on your own Mac and sign it with your own Apple ID.

### Prerequisites

- macOS with Xcode 15.0+
- An iPhone running iOS 17 or later
- Free or paid Apple Developer account (free works for personal sideload)

### Open the project

```sh
open MyHealth.xcodeproj
```

### Configure Google Sign-In (optional)

If you want Google Drive sync:

1. Go to [Google Cloud Console](https://console.cloud.google.com/apis/credentials), create an iOS OAuth client.
2. Bundle ID: `com.xiaoyuanzhu.MyHealth` (or change it in Xcode if you want).
3. Copy the **iOS URL scheme** (the reversed client ID, e.g. `com.googleusercontent.apps.123-abc`) and the **client ID** into `MyHealth/Info.plist`, replacing the `REPLACE_WITH_YOUR_GOOGLE_CLIENT_ID` placeholders in two places.

If you skip this step, MyLifeDB sync still works.

### Build

In Xcode: select your iPhone as the run destination, set a signing team in *MyHealth target → Signing & Capabilities*, then ⌘R. The app needs three entitlements (already declared in `MyHealth.entitlements`):

- HealthKit
- HealthKit Health Records (Clinical)
- HealthKit Background Delivery

The free Apple ID profile reauthorises every 7 days; a paid account ($99/yr) lasts a year.

## Apple Health Data

Synced from iOS HealthKit via the MyLifeDB app.

For MyLifeDB the remote root is `/apps/apple-health/`, requested via the `read_file write_file` scopes against the Connect server's flat allowlist. For Drive it's `apple-health/` under the user's Drive root.

### Directory Layout

```
apple-health/
└── YYYY/
    └── MM/
        └── DD/
            ├── step-count.json
            ├── heart-rate.json
            ├── sleep-analysis.json
            ├── workout-<UUID>.json
            └── ...
```

One file per HealthKit type per day. File names are kebab-case versions of the
HealthKit type identifier with the `HKQuantityTypeIdentifier` / `HKCategoryTypeIdentifier`
prefix stripped (e.g., `HKQuantityTypeIdentifierStepCount` → `step-count.json`).

Days are determined by the sample's own timezone (from `HKTimeZone` metadata),
not UTC. A file at `2026/01/18/` contains samples whose local date is January 18.

### File Format

Every JSON file has the same top-level shape:

```json
{
  "date": "2026-01-18",
  "type": "HKQuantityTypeIdentifierStepCount",
  "timezone": "Asia/Shanghai",
  "unit": "count",
  "samples": [ ... ]
}
```

| Field      | Type     | Description |
|------------|----------|-------------|
| `date`     | string   | `YYYY-MM-DD` local date this file covers |
| `type`     | string   | Full HealthKit type identifier |
| `timezone` | string   | IANA timezone used for day boundary |
| `unit`     | string?  | Unit of measurement (quantity types only, absent for category types) |
| `samples`  | array    | All samples for this type on this day, sorted by `(start, end, source)` |

#### Quantity samples (step-count, heart-rate, etc.)

```json
{
  "start": "2026-01-17T16:37:10.901Z",
  "end": "2026-01-17T16:46:20.452Z",
  "value": 200,
  "unit": "count",
  "type": "HKQuantityTypeIdentifierStepCount",
  "source": "com.apple.health.37928A11-...",
  "device": "Watch7,1"
}
```

#### Category samples (sleep-analysis, etc.)

```json
{
  "start": "2026-01-17T17:24:19.656Z",
  "end": "2026-01-17T17:27:49.348Z",
  "value": "asleepCore",
  "type": "HKCategoryTypeIdentifierSleepAnalysis",
  "source": "com.apple.health.37928A11-...",
  "device": "Watch7,1",
  "metadata": {
    "HKTimeZone": "Asia/Shanghai"
  }
}
```

#### Common fields in every sample

| Field      | Type    | Description |
|------------|---------|-------------|
| `start`    | string  | ISO 8601 timestamp (UTC) — when measurement began |
| `end`      | string  | ISO 8601 timestamp (UTC) — when measurement ended |
| `value`    | number or string | Numeric for quantity types, string enum for category types |
| `type`     | string  | Full HealthKit type identifier |
| `source`   | string  | Bundle ID of the recording app |
| `device`   | string? | Hardware model (e.g., `Watch7,1`, `iPhone16,2`) |
| `metadata` | object? | Optional HealthKit metadata (varies by type) |

### Workout Files

Workouts are stored separately as one file per workout event:
`workout-<UUID>.json` (e.g., `workout-A1B2C3D4-...json`).

The day directory is based on the workout's start date (device local time).

```json
{
  "uuid": "A1B2C3D4-...",
  "activity_type": "running",
  "start": "2026-01-18T01:30:00.000Z",
  "end": "2026-01-18T02:15:00.000Z",
  "duration_s": 2700,
  "source": "com.apple.health",
  "device": "Watch7,1",
  "synced_at": "2026-01-18T10:00:00.000Z",
  "device_info": { "name": "Apple Watch", "model": "Watch7,1", "systemVersion": "11.0" },
  "stats": {
    "distance": { "value": 5000, "unit": "m" },
    "energy": { "value": 435, "unit": "kcal" }
  },
  "metadata": { ... },
  "route": [ ... ]
}
```

| Field           | Type     | Description |
|-----------------|----------|-------------|
| `uuid`          | string   | HealthKit workout UUID |
| `activity_type` | string   | e.g., `running`, `cycling`, `swimming`, `badminton`, `yoga` |
| `start` / `end` | string   | ISO 8601 UTC timestamps |
| `duration_s`    | number   | Duration in seconds |
| `source`        | string   | Bundle ID of the recording app |
| `device`        | string?  | Hardware model |
| `synced_at`     | string   | When this file was generated |
| `device_info`   | object   | Name, model, OS version of the syncing device |
| `stats`         | object   | Workout statistics — keys vary by activity type, each has `value` + `unit` |
| `metadata`      | object?  | Optional HealthKit metadata |
| `route`         | array?   | GPS track — `null` for indoor workouts |

#### Route points

Each point in the `route` array:

```json
{ "t": "2026-01-18T01:30:05.123Z", "lat": 31.234, "lon": 121.456, "alt": 12.4,
  "h_acc": 3.2, "v_acc": 4.1, "speed": 2.8, "speed_acc": 0.3, "course": 273.5, "course_acc": 5.0 }
```

| Field       | Type   | Description |
|-------------|--------|-------------|
| `t`         | string | ISO 8601 UTC timestamp |
| `lat`/`lon` | number | WGS 84 coordinates |
| `alt`       | number | Altitude in metres |
| `h_acc`     | number | Horizontal accuracy (metres) |
| `v_acc`     | number | Vertical accuracy (metres) |
| `speed`     | number | Speed in m/s (negative = invalid) |
| `speed_acc` | number | Speed accuracy (m/s) |
| `course`    | number | Degrees clockwise from north (negative = invalid) |
| `course_acc`| number | Course accuracy (degrees) |

### Timestamps

All `start` and `end` timestamps are **UTC** (ISO 8601 with fractional seconds
and `Z` suffix). The top-level `timezone` field tells you the local timezone for
interpreting the date boundary. To get local time: convert the UTC timestamp to
the file's `timezone`.

### Sync Behavior

Each file is a **complete snapshot** of that type+day. Re-syncing overwrites the
file with the latest data — it is always a superset of any previous version.
Files are deterministic: same data produces the same file content.

### Known Types

Common quantity types: `step-count`, `heart-rate`, `active-energy-burned`,
`basal-energy-burned`, `resting-heart-rate`, `oxygen-saturation`,
`heart-rate-variability-sdnn`, `respiratory-rate`, `walking-speed`,
`walking-step-length`, `distance-walking-running`, `flights-climbed`,
`apple-exercise-time`, `apple-stand-time`, `apple-sleeping-wrist-temperature`.

Category types: `sleep-analysis`.

The exact set depends on which types the user has enabled and which have data.

## Background sync

MyHealth registers a `BGAppRefreshTask` (`com.xiaoyuanzhu.MyHealth.dailySync`) that runs ~daily when the system has spare capacity (typically while charging on Wi-Fi). It also enables `HKObserverQuery.enableBackgroundDelivery` for every monitored type, so meaningful events (e.g. a finished workout) wake the app sooner.

You can fire the task manually from Xcode for testing:

```
e -l "BGTaskScheduler.shared._simulateLaunchForTaskWithIdentifier:@\"com.xiaoyuanzhu.MyHealth.dailySync\""
```

## Privacy

- All syncing happens directly between your phone and the destinations you authorize. There is no MyHealth server.
- Tokens are stored in the iOS Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`).
- *Settings → Sign out* on the MyLifeDB row hits `/connect/revoke` and clears Keychain. On the Drive row it signs out of Google.
- You can also revoke MyHealth at any time from MyLifeDB *Settings → Connected Apps*, or from your [Google Account → Third-party apps](https://myaccount.google.com/permissions).

## Tests

```sh
xcodebuild test \
  -scheme MyHealth \
  -destination 'platform=iOS Simulator,name=iPhone 15'
```

- `PKCETests.swift` — verifies the S256 challenge for the RFC 7636 reference verifier.
- `HealthSampleTests.swift` — pins the new-format encoder behaviour (ISO 8601 timestamps, device-model fallback, canonical units).
- `DaySampleTests.swift` — round-trips the `DayFile` / `QuantitySample` / `CategorySample` / `WorkoutFile` shapes against the JSON spec.
- `TypeNamingTests.swift` — pins `HKQuantityTypeIdentifier*` → kebab-case filename mapping.
- `DayBucketerTests.swift` — pins the local-day boundary logic against `HKTimeZone` metadata.
- `SnapshotMergerTests.swift` — pins UUID-dedup + sort behaviour for snapshot merges.
- `SyncRunStateTests.swift` — round-trips the on-disk pause/resume state and verifies uuid stays out of the published wire format.

End-to-end testing (HealthKit reads, real OAuth, Drive uploads) requires running on a physical iPhone — most HealthKit types return no samples in the simulator.

## License

Apache-2.0 — see [LICENSE](LICENSE).
