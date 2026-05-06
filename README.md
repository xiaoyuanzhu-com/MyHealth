# MyHealth

A FOSS iOS app that reads your Apple Health data straight from HealthKit and syncs it to:

- **MyLifeDB**, via the [Connect OAuth 2.1 + PKCE flow](https://my.xiaoyuanzhu.com/docs/internal/api/connect/), uploaded under `/apps/myhealth/apple-health/`.
- **Google Drive**, via the official Google Sign-In SDK + Drive REST API, into a `MyHealth/apple-health/` folder. The app uses the `drive.file` scope, so it can only see and modify files it created itself.

No middleman, no backend, no analytics. The app reads HealthKit on-device, writes JSONL files to your own destinations, and that's it.

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
2. Bundle ID: `org.foss.myhealth.ios` (or change it in Xcode if you want).
3. Copy the **iOS URL scheme** (the reversed client ID, e.g. `com.googleusercontent.apps.123-abc`) and the **client ID** into `MyHealth/Info.plist`, replacing the `REPLACE_WITH_YOUR_GOOGLE_CLIENT_ID` placeholders in two places.

If you skip this step, MyLifeDB sync still works.

### Build

In Xcode: select your iPhone as the run destination, set a signing team in *MyHealth target → Signing & Capabilities*, then ⌘R. The app needs three entitlements (already declared in `MyHealth.entitlements`):

- HealthKit
- HealthKit Health Records (Clinical)
- HealthKit Background Delivery

The free Apple ID profile reauthorises every 7 days; a paid account ($99/yr) lasts a year.

## What gets uploaded

```
<remote root>/
├── manifest.json                 # schema, anchors, batch index
└── syncs/
    └── 20260506T112233Z/         # one folder per sync run
        ├── records.jsonl
        ├── workouts.jsonl
        ├── activity_summaries.jsonl
        ├── ecg.jsonl             # if any
        └── clinical.jsonl        # if any
```

For MyLifeDB the remote root is `/apps/myhealth/apple-health/`, requested with scope `files.write:/apps/myhealth/apple-health`. For Drive it's `MyHealth/apple-health/` under the user's Drive root.

Each row in `*.jsonl` is one HealthKit sample, encoded with the original `myhealth.apple_health.v1` snake_case keys (`_kind`, `type`, `unit`, `value`, `start_date`, `end_date`, `creation_date`, `source_name`, `source_version`, `device`) plus HealthKit-native extras (`uuid`, `metadata`, workout `events`, `route_locations`, ECG `ecg_samples`, etc.). The top-level manifest carries `myhealth.healthkit.v1` and per-`HKSampleType` `HKAnchoredObjectQuery` anchors so the next sync only ships what's new.

## Background sync

MyHealth registers a `BGAppRefreshTask` (`org.foss.myhealth.ios.dailySync`) that runs ~daily when the system has spare capacity (typically while charging on Wi-Fi). It also enables `HKObserverQuery.enableBackgroundDelivery` for every monitored type, so meaningful events (e.g. a finished workout) wake the app sooner.

You can fire the task manually from Xcode for testing:

```
e -l "BGTaskScheduler.shared._simulateLaunchForTaskWithIdentifier:@\"org.foss.myhealth.ios.dailySync\""
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

Three test files cover the auth-critical surfaces:

- `PKCETests.swift` — verifies the S256 challenge for the RFC 7636 reference verifier.
- `HealthSampleTests.swift` — locks down the `myhealth.apple_health.v1` JSONL key set and the date-format/value-stringify conventions.
- `ManifestTests.swift` — round-trips the manifest schema and tests anchor merging.

End-to-end testing (HealthKit reads, real OAuth, Drive uploads) requires running on a physical iPhone — most HealthKit types return no samples in the simulator.

## License

Apache-2.0 — see [LICENSE](LICENSE).
