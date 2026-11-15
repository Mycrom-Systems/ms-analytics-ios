// swift-tools-version:5.9
// Metric Sensei Analytics for iOS as a Swift package. The privacy manifest ships as a resource so Xcode adds it to
// every app's privacy report (Apple asks SDKs that use UserDefaults to declare why).
import PackageDescription

let package = Package(
    name: "MetricSenseiAnalytics",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [.library(name: "MetricSenseiAnalytics", targets: ["MetricSenseiAnalytics"])],
    targets: [
        .target(name: "MetricSenseiAnalytics", resources: [.copy("PrivacyInfo.xcprivacy")]),
        .testTarget(name: "MetricSenseiAnalyticsTests", dependencies: ["MetricSenseiAnalytics"]),
    ]
)
