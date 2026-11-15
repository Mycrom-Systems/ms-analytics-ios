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
        XCTAssertEqual(body["sv"] as? String, "1.3.0")
        XCTAssertEqual((body["b"] as? String)?.count, 32)
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
            XCTAssertEqual((e["id"] as? String)?.count, 16)
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

    /// A retry is the same batch: same "b", same events with the same "id"s, even when more events were tracked
    /// in between (they go in the next batch).
    func testRetryResendsTheSameFrozenBatch() {
        StubProtocol.reset(status: nil)
        let a = makeSDK()
        a.configure(siteId: "MS-TEST0001", host: "https://example.test")
        a.screen("Home")
        flushAndWait(a)
        let tried = StubProtocol.bodies("/v1/app")
        XCTAssertEqual(tried.count, 1)

        a.screen("Next")
        StubProtocol.reset(status: 202)
        flushAndWait(a)
        let sent = StubProtocol.bodies("/v1/app")
        XCTAssertEqual(sent.count, 2, "the frozen batch, then the new event in a batch of its own")
        XCTAssertEqual(sent[0]["b"] as? String, tried[0]["b"] as? String)
        let ids = { (body: [String: Any]) in ((body["ev"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String } }
        XCTAssertEqual(ids(sent[0]), ids(tried[0]))
        XCTAssertEqual(ids(sent[0]).count, 1)
        XCTAssertNotEqual(sent[1]["b"] as? String, sent[0]["b"] as? String)
        XCTAssertEqual(a.queuedCount, 0)
    }

    /// 409 (the service is still handling an earlier try) keeps the batch and isn't reported; a 202 "duplicate"
    /// answer finishes it.
    func testInProgressIsRetriedAndDuplicateFinishes() {
        StubProtocol.reset(status: 409)
        let a = makeSDK()
        a.configure(siteId: "MS-TEST0001", host: "https://example.test")
        a.screen("Home")
        flushAndWait(a)
        XCTAssertEqual(a.queuedCount, 1)

        StubProtocol.reset(status: 202)
        flushAndWait(a)
        XCTAssertEqual(a.queuedCount, 0)
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertTrue(StubProtocol.bodies("/v1/errors").isEmpty, "409 is not a failure")
    }

    /// A batch whose answer never came is sent again after a restart with the same "b".
    func testPendingBatchSurvivesRestartWithItsId() {
        StubProtocol.reset(status: nil)
        let first = makeSDK()
        first.configure(siteId: "MS-TEST0001", host: "https://example.test")
        first.screen("Home")
        flushAndWait(first)
        let b = StubProtocol.bodies("/v1/app").first?["b"] as? String
        XCTAssertNotNil(b)

        StubProtocol.reset(status: 202)
        let second = makeSDK()
        second.configure(siteId: "MS-TEST0001", host: "https://example.test")
        flushAndWait(second)
        XCTAssertEqual(StubProtocol.bodies("/v1/app").first?["b"] as? String, b)
        XCTAssertEqual(second.queuedCount, 0)
    }

    /// SDK 1.2.0 saved a plain list of events; an upgraded app still sends them (in a new batch).
    func testLoadsAVersion12QueueFile() throws {
        let old: [[String: Any]] = [[
            "t": "pv", "p": "/Old", "n": 1, "sid": String(repeating: "a", count: 32),
            "vid": String(repeating: "b", count: 32), "at": Date().timeIntervalSince1970 - 60,
        ]]
        try FileManager.default.createDirectory(at: store.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: old).write(to: store)
        let a = makeSDK()
        a.configure(siteId: "MS-TEST0001", host: "https://example.test")
        XCTAssertEqual(a.queuedCount, 1)
        flushAndWait(a)
        let body = StubProtocol.bodies("/v1/app").first ?? [:]
        XCTAssertEqual(body["sid"] as? String, String(repeating: "a", count: 32))
        XCTAssertEqual((body["b"] as? String)?.count, 32)
        XCTAssertEqual(((body["ev"] as? [[String: Any]])?.first?["p"]) as? String, "/Old")
    }
}
