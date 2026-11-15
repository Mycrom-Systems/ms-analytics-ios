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
Analytics.shared.flush() // e.g. when the app goes to the background
```

Privacy: no advertising ID, device ID or personal data is read. The visitor ID is random and kept in the app's
UserDefaults; `reset()` forgets it (e.g. on sign-out). Events are sent in batches every 10 seconds.

If the SDK itself fails (the service refuses a batch), it sends Metric Sensei a short report to `/v1/errors` so we
can fix it: at most 3 an app run, with the SDK version, the step, the error and the OS version. Never the visitor
ID, events or anything about the person; being offline is never reported.

iOS 14+ / macOS 11+. MIT license.
