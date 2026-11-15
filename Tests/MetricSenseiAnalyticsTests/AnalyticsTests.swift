// Tests for the Analytics SDK. The network is a fake (StubProtocol): each test sets the HTTP status the "service"
// answers (nil = offline) and reads back the JSON bodies the SDK sent to /v1/app and /v1/errors.

import XCTest
@testable import MetricSenseiAnalytics

/// A URLProtocol that answers every request with `StubProtocol.status` (nil: a network error, like being offline)
/// and records each request's path and JSON body.
final class StubProtocol: URLProtocol {
    static let lock = NSLock()
    static var status: Int? = 202
    static var sent: [(path: String, body: [String: Any])] = []

    /// Clears what was recorded and sets the next answer.
    static func reset(status: Int?) {
        lock.lock(); defer { lock.unlock() }
        self.status = status
        sent = []
    }

    /// The bodies sent to one path ("/v1/app" or "/v1/errors").
    static func bodies(_ path: String) -> [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        return sent.filter { $0.path == path }.map { $0.body }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    /// Records the request (its body arrives as a stream inside URLProtocol) and answers it.
    override func startLoading() {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            stream.close()
        }
        let body = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
        StubProtocol.lock.lock()
        StubProtocol.sent.append((request.url?.path ?? "", body))
        let status = StubProtocol.status
        StubProtocol.lock.unlock()
        if let status, let url = request.url,
           let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil) {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data())
            client?.urlProtocolDidFinishLoading(self)
        } else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
        }
    }

    override func stopLoading() {}
}

final class AnalyticsTests: XCTestCase {
    var store: URL!

    override func setUp() {
        super.setUp()
        StubProtocol.reset(status: 202)
        store = FileManager.default.temporaryDirectory
            .appendingPathComponent("msa-test-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("queue.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: store.deletingLastPathComponent())
        super.tearDown()
    }

    /// A fresh SDK with its own UserDefaults, queue file and the fake network.
    func makeSDK(store: URL? = nil) -> Analytics {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let defaults = UserDefaults(suiteName: "msa-test-\(UUID().uuidString)")!
        return Analytics(defaults: defaults, storeURL: store ?? self.store, urlSession: URLSession(configuration: config),
                         observeApp: false)
    }

    /// Flushes and waits until nothing is on its way.
    func flushAndWait(_ a: Analytics) {
        a.flush()
        let done = expectation(description: "idle")
        a.whenIdle { done.fulfill() }
        wait(for: [done], timeout: 5)
    }

    /// Waits (up to 5 s) for something the fake network records on its own time, such as a failure report,
    /// which the SDK sends without waiting for the answer.
    func waitUntil(_ condition: @escaping () -> Bool) {
        let done = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        wait(for: [done], timeout: 5)
    }

    func testVisitorIdIsStable() {
        let a = makeSDK()
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

    /// The batch has the shape POST /v1/app reads (ms-analytics tests/test_app_sdk_contract.py checks the names).
    func testBatchShape() {
        let a = makeSDK()
        a.configure(siteId: "MS-TEST0001", host: "https://example.test")
        a.screen("Home")
        a.screen("Plan Picker")
        a.track("Purchase", props: ["plan": "pro", "member": true, "ok": [1]], revenue: 49.9, currency: "USD")
        flushAndWait(a)
        let batches = StubProtocol.bodies("/v1/app")
        XCTAssertEqual(batches.count, 1)
        let body = batches[0]
        XCTAssertEqual(body["site"] as? String, "MS-TEST0001")
        XCTAssertEqual(body["sv"] as? String, "1.2.0")
        XCTAssertEqual((body["sid"] as? String)?.count, 32)
        XCTAssertEqual(body["vid"] as? String, a.visitorId)
        let ev = body["ev"] as? [[String: Any]] ?? []
        XCTAssertEqual(ev.count, 3)
        XCTAssertEqual(ev[0]["p"] as? String, "/Home")
        XCTAssertEqual(ev[1]["p"] as? String, "/Plan-Picker")
        XCTAssertEqual(ev[1]["nb"] as? Int, 1)
        XCTAssertEqual(ev[2]["nm"] as? String, "Purchase")
        let pr = ev[2]["pr"] as? [String: Any] ?? [:]
        XCTAssertEqual(pr["revenue"] as? Double, 49.9)
        XCTAssertEqual(pr["member"] as? Bool, true)
        XCTAssertNil(pr["ok"], "only strings, true/false and numbers are sent")
        for e in ev {
            XCTAssertNotNil(e["o"])
            XCTAssertNil(e["at"]); XCTAssertNil(e["sid"]); XCTAssertNil(e["vid"])
        }
        XCTAssertEqual(a.queuedCount, 0)
    }

    /// Offline: the batch goes back on the queue, is saved to the file, and is sent once the network is back.
    func testOfflineKeepsEventsAndSendsLater() {
        StubProtocol.reset(status: nil)
        let a = makeSDK()
        a.configure(siteId: "MS-TEST0001", host: "https://example.test")
        a.screen("Home")
        flushAndWait(a)
        XCTAssertEqual(a.queuedCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.path))
        XCTAssertTrue(StubProtocol.bodies("/v1/errors").isEmpty, "being offline is never reported")

        StubProtocol.reset(status: 202)
        flushAndWait(a)
        XCTAssertEqual(StubProtocol.bodies("/v1/app").count, 1)
        XCTAssertEqual(a.queuedCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.path))
    }

    /// 5xx and 429 keep the batch; another 4xx drops it and reports, at most 3 times.
    func testRefusalsAreDroppedAndReportedThreeTimes() {
        StubProtocol.reset(status: 503)
        let a = makeSDK()
        a.configure(siteId: "MS-TEST0001", host: "https://example.test")
        a.screen("Home")
        flushAndWait(a)
        XCTAssertEqual(a.queuedCount, 1)
        waitUntil { StubProtocol.bodies("/v1/errors").count == 1 }

        StubProtocol.reset(status: 404)
        for i in 0..<5 {
            a.screen("S\(i)")
            flushAndWait(a)
        }
        XCTAssertEqual(a.queuedCount, 0)
        // One report was already used by the 503, so two are left for the 404s.
        waitUntil { StubProtocol.bodies("/v1/errors").count >= 2 }
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(StubProtocol.bodies("/v1/errors").count, 2)
        let report = StubProtocol.bodies("/v1/errors").first ?? [:]
        XCTAssertEqual(report["src"] as? String, "ios")
        XCTAssertNil(report["vid"])
    }

    /// A later run picks up what an earlier one saved, and sends it under the session it happened in.
    func testQueueSurvivesRestart() {
        StubProtocol.reset(status: nil)
        let first = makeSDK()
        first.configure(siteId: "MS-TEST0001", host: "https://example.test")
        first.screen("Home")
        flushAndWait(first)
        XCTAssertEqual(first.queuedCount, 1)

        StubProtocol.reset(status: 202)
        let second = makeSDK()
        second.configure(siteId: "MS-TEST0001", host: "https://example.test")
        XCTAssertEqual(second.queuedCount, 1)
        second.screen("Settings")
        flushAndWait(second)
        flushAndWait(second)
        let batches = StubProtocol.bodies("/v1/app")
        XCTAssertEqual(batches.count, 2, "two sessions, two batches")
        XCTAssertNotEqual(batches[0]["sid"] as? String, batches[1]["sid"] as? String)
        XCTAssertEqual(((batches[0]["ev"] as? [[String: Any]])?.first?["p"]) as? String, "/Home")
    }

    /// Before configure() nothing is sent and the queue stops at 1,000 events.
    func testQueueIsCappedBeforeConfigure() {
        let a = makeSDK()
        for i in 0..<(Analytics.maxQueued + 50) { a.track("e\(i)") }
        XCTAssertEqual(a.queuedCount, Analytics.maxQueued)
        XCTAssertTrue(StubProtocol.bodies("/v1/app").isEmpty)
    }
}
