import XCTest
@testable import MetricSenseiAnalytics

final class AnalyticsTests: XCTestCase {
    func testVisitorIdIsStable() {
        let a = Analytics.shared
        let first = a.visitorId
        XCTAssertEqual(first.count, 32)
        XCTAssertEqual(a.visitorId, first)
    }

    /// Configuring twice must not throw or hang (the earlier send timer is cancelled, not leaked).
    func testConfigureTwiceIsSafe() {
        let a = Analytics.shared
        a.configure(siteId: "MS-TEST0001", host: "https://analytics.api.dev.metricsensei.com")
        a.configure(siteId: "MS-TEST0002", host: "https://analytics.api.dev.metricsensei.com")
        XCTAssertEqual(a.visitorId.count, 32)
    }
}
