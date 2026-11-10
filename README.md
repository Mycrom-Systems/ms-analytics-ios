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

iOS 14+ / macOS 11+. MIT license.
