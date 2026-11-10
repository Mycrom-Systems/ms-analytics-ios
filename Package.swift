// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MetricSenseiAnalytics",
    platforms: [.iOS(.v14), .macOS(.v11)],
    products: [.library(name: "MetricSenseiAnalytics", targets: ["MetricSenseiAnalytics"])],
    targets: [
        .target(name: "MetricSenseiAnalytics"),
        .testTarget(name: "MetricSenseiAnalyticsTests", dependencies: ["MetricSenseiAnalytics"]),
    ]
)
