# Metric Sensei Analytics for iOS

Screens, events, sessions and revenue from an iOS app into Metric Sensei Analytics.

## Install (Swift Package Manager)
In Xcode: File > Add Package Dependencies > `https://github.com/Mycrom-Systems/ms-analytics-ios`.

## Use
1. In Metric Sensei, add the app under the client's Data sources > Websites & Apps (iOS app, with its bundle ID) and
   turn Analytics on for it. Note its site ID (`MS-XXXXXXXX`).
2. In the app:

```swift
import MetricSenseiAnalytics

Analytics.shared.configure(siteId: "MS-XXXXXXXX")
Analytics.shared.screen("Home")
Analytics.shared.track("Purchase", props: ["plan": "pro"], revenue: 49.9, currency: "USD")
```

Delivery: events are sent in batches every 10 seconds, sooner once 20 are waiting, and automatically when the app
goes to the background (`flush()` sends at once if you want to). When the phone is offline or the service is busy,
events wait (up to 1,000, in a file in the app's caches folder so they survive the app closing) and the SDK tries
again, waiting longer each time (up to 5 minutes). Events more than an hour old are dropped.

Privacy: no advertising ID, device ID or personal data is read. The visitor ID is random and kept in the app's
UserDefaults; `reset()` forgets it (e.g. on sign-out). The package includes its privacy manifest
(`PrivacyInfo.xcprivacy`: no tracking; product interaction, purchase history and diagnostics, not linked to the
person; UserDefaults reason CA92.1), which Xcode adds to your app's privacy report.

If the SDK itself fails (the service refuses a batch), it sends Metric Sensei a short report to `/v1/errors` so we
can fix it: at most 3 an app run, with the SDK version, the step, the error and the OS version. Never the visitor
ID, events or anything about the person; being offline is never reported.

iOS 14+ / macOS 11+. MIT license.

## Developing
`swift build && swift test` (on a Mac; the tests use a fake network). The version is the `"sv"` string in
`Analytics.swift` (written twice: batches and failure reports). Raise it with any change; ms-core's
`scripts/publish-packages.py` tags `v<version>` after the next prod release, and ms-analytics'
`tests/test_app_sdk_contract.py` checks every field sent here against what `/v1/app` reads.
