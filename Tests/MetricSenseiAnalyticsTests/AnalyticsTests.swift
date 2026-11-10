import XCTest
@testable import MetricSenseiAnalytics

final class AnalyticsTests: XCTestCase {
    func testVisitorIdIsStable() {
        let a = Analytics.shared
        let first = a.visitorId
        XCTAssertEqual(first.count, 32)
        XCTAssertEqual(a.visitorId, first)
    }
}
