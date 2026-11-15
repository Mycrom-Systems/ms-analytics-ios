// Metric Sensei Analytics for iOS: screens, events, sessions and revenue, sent in batches to the client's
// Analytics. Add the app under Data sources > Websites & Apps (iOS app, its bundle ID), turn Analytics on for it,
// then:
//
//     Analytics.shared.configure(siteId: "MS-XXXXXXXX")
//     Analytics.shared.screen("Home")
//     Analytics.shared.track("Purchase", props: ["plan": "pro"], revenue: 49.9, currency: "USD")
//
// No advertising ID, device ID or personal data is read. The visitor ID is random, kept in this app's
// UserDefaults; call reset() when someone signs out if you don't want their next session joined to the last.
//
// Delivery: events wait in a queue (at most 1,000; the oldest go first past that) and are sent every 10 seconds,
// sooner once 20 are waiting, and when the app goes to the background. When the phone is offline, or the service
// is busy (5xx, 429), the batch goes back on the queue and the next try waits longer (10 s doubling to 5 min). The
// queue is also kept in a file in the app's caches folder, so events survive the app being closed. Events more
// than an hour old are dropped when sent, because the service dates an event at most an hour back.
//
// When the SDK itself fails (a batch it can't encode, or one the service refuses), it tells Metric Sensei so the
// problem can be fixed: at most 3 short reports an app run to /v1/errors, holding the SDK's version, the step, the
// error and the iOS version. Never the visitor ID, events or anything about the person. Being offline isn't a
// failure and is never reported.

import Foundation
#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif

/// The SDK. Use `Analytics.shared`; every public method is safe to call from any thread. All state is changed only
/// on the private serial `queue`, which is why the class can be marked `@unchecked Sendable`.
public final class Analytics: @unchecked Sendable {
    public static let shared = Analytics()

    /// The most events kept waiting; past this the oldest are dropped.
    static let maxQueued = 1000
    /// The most events in one batch (the service reads at most 50).
    static let maxBatch = 50
    /// An event older than this when it is sent is dropped: the service dates events at most an hour back.
    static let maxAge: TimeInterval = 3500
    /// The longest wait between tries while the service can't be reached.
    static let maxBackoff: TimeInterval = 300

    private let queue = DispatchQueue(label: "com.metricsensei.analytics")
    private let defaults: UserDefaults
    private let storeURL: URL?
    private let urlSession: URLSession
    private let sessionTimeout: TimeInterval = 30 * 60

    private var siteId = ""
    private var appId = Bundle.main.bundleIdentifier ?? ""
    private var endpoint = URL(string: "https://analytics.api.metricsensei.com/v1/app")!
    private var errorsEndpoint = URL(string: "https://analytics.api.metricsensei.com/v1/errors")!
    private var reportsLeft = 3
    /// Waiting events. Each keeps its own session (`sid`), visitor (`vid`) and clock (`at`) so a batch sent
    /// later, or after a restart, still names the session it happened in. Those three are taken out when sent.
    private var events: [[String: Any]] = []
    private var session = ""
    private var lastActivity = Date.distantPast
    private var screenCount = 0
    private var screenName = ""
    private var timer: DispatchSourceTimer?
    private var configured = false
    private var loadedStore = false
    private var inBackground = false
    /// True while a batch is on its way; only one is sent at a time so events arrive in order.
    private var sending = false
    /// No new try before this (set after a failed send).
    private var retryAt = Date.distantPast
    private var backoff: TimeInterval = 0
    /// Called (on `queue`) once nothing is being sent; used to hold the app open briefly in the background.
    private var idleWaiters: [() -> Void] = []

    /// The shared instance: the standard UserDefaults, a queue file in the caches folder, the shared URLSession.
    convenience init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        let url = caches?.appendingPathComponent("com.metricsensei.analytics", isDirectory: true)
            .appendingPathComponent("queue.json")
        self.init(defaults: .standard, storeURL: url, urlSession: .shared, observeApp: true)
    }

    /// For tests: a separate UserDefaults, queue file (nil: none) and URLSession; `observeApp` false skips the
    /// app's background/foreground notifications.
    init(defaults: UserDefaults, storeURL: URL?, urlSession: URLSession, observeApp: Bool) {
        self.defaults = defaults
        self.storeURL = storeURL
        self.urlSession = urlSession
        if observeApp { observeAppState() }
    }

    /// Start sending. `host` is for testing environments (e.g. https://analytics.api.dev.metricsensei.com).
    /// Safe to call more than once: the latest site ID and host are used and one send timer runs.
    public func configure(siteId: String, host: String = "https://analytics.api.metricsensei.com") {
        queue.sync {
            self.siteId = siteId
            if let url = URL(string: host + "/v1/app") { self.endpoint = url }
            if let url = URL(string: host + "/v1/errors") { self.errorsEndpoint = url }
            self.configured = true
            self.loadStoreLocked()
            if !self.inBackground { self.startTimerLocked() }
        }
    }

    /// A screen view (counted like a page view, path "/<name>").
    public func screen(_ name: String) {
        queue.async {
            self.touchSession()
            self.screenCount += 1
            self.screenName = "/" + name.replacingOccurrences(of: " ", with: "-")
            var e: [String: Any] = ["t": "pv", "p": self.screenName, "n": self.screenCount]
            if self.screenCount == 2 { e["nb"] = 1 }
            self.push(e)
        }
    }

    /// A named event, with optional properties and revenue. Property values other than strings, true/false and
    /// finite numbers are left out (JSON can't carry NaN or infinity).
    public func track(_ name: String, props: [String: Any] = [:], revenue: Double? = nil, currency: String? = nil) {
        queue.async {
            self.touchSession()
            var pr: [String: Any] = props.filter {
                $0.value is String || $0.value is Bool || $0.value is Int || (($0.value as? Double)?.isFinite ?? false)
            }
            if let r = revenue, r.isFinite { pr["revenue"] = r }
            if let c = currency { pr["currency"] = c }
            self.push(["t": "ev", "nm": name, "pr": pr, "p": self.screenName])
        }
    }

    /// Forget the visitor ID (a new one is made on the next event). Events already queued keep the old one.
    public func reset() {
        queue.async { self.defaults.removeObject(forKey: "msa_visitor"); self.session = "" }
    }

    /// Send what is queued now. The SDK already does this when the app goes to the background.
    public func flush() { queue.async { self.flushLocked(force: true) } }

    // MARK: - internals

    /// This app's random visitor ID (32 hex characters), made and saved on first use.
    var visitorId: String {
        if let v = defaults.string(forKey: "msa_visitor") { return v }
        let v = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        defaults.set(v, forKey: "msa_visitor")
        return v
    }

    /// For tests: how many events are waiting.
    var queuedCount: Int { queue.sync { events.count } }

    /// For tests: runs `body` on the SDK's queue once nothing is being sent.
    func whenIdle(_ body: @escaping () -> Void) {
        queue.async {
            if self.sending { self.idleWaiters.append(body) } else { body() }
        }
    }

    /// Starts a new session after 30 minutes without activity (or the first time), and notes this activity.
    private func touchSession() {
        let now = Date()
        if session.isEmpty || now.timeIntervalSince(lastActivity) > sessionTimeout {
            session = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            screenCount = 0
        }
        lastActivity = now
    }

    /// Queues one event with its session, visitor and time; sends early once 20 are waiting.
    private func push(_ event: [String: Any]) {
        var e = event
        e["sid"] = session
        e["vid"] = visitorId
        e["at"] = Date().timeIntervalSince1970
        events.append(e)
        trimLocked()
        if events.count >= 20 { flushLocked(force: false) }
    }

    /// Drops the oldest events past `maxQueued` (also before configure() is called, so the queue can't grow
    /// without end).
    private func trimLocked() {
        if events.count > Self.maxQueued { events.removeFirst(events.count - Self.maxQueued) }
    }

    /// (Re)starts the 10-second send timer; only one ever runs.
    private func startTimerLocked() {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 10, repeating: 10)
        t.setEventHandler { [weak self] in self?.flushLocked(force: false) }
        t.resume()
        timer = t
    }

    /// Stops the send timer (in the background, so the SDK doesn't wake the app).
    private func stopTimerLocked() {
        timer?.cancel()
        timer = nil
    }

    /// Sends the next batch: up to 50 events of one session and visitor, oldest first. Waits while another batch
    /// is on its way, and (unless `force`) while a failed send's backoff runs. Old events are dropped here.
    private func flushLocked(force: Bool) {
        guard !sending, !siteId.isEmpty, force || Date() >= retryAt else { return }
        let now = Date().timeIntervalSince1970
        events.removeAll { now - (($0["at"] as? Double) ?? now) > Self.maxAge }
        guard let first = events.first else {
            saveLocked()
            return
        }
        let sid = (first["sid"] as? String) ?? session
        let vid = (first["vid"] as? String) ?? visitorId
        var count = 0
        while count < min(events.count, Self.maxBatch),
              ((events[count]["sid"] as? String) ?? sid) == sid, ((events[count]["vid"] as? String) ?? vid) == vid {
            count += 1
        }
        let batch = Array(events.prefix(count))
        events.removeFirst(count)
        // The file no longer holds this batch: if the app is killed before the answer comes, the batch is lost
        // rather than sent twice on the next start (a purchase counted twice is worse than one missed).
        saveLocked()
        let ev = batch.map { e -> [String: Any] in
            var x = e
            let at = (x.removeValue(forKey: "at") as? Double) ?? now
            x.removeValue(forKey: "sid")
            x.removeValue(forKey: "vid")
            x["o"] = Int(max(0, (now - at) * 1000))
            return x
        }
        let body: [String: Any] = [
            "v": 1, "site": siteId, "app": appId, "sid": sid, "vid": vid, "ev": ev,
            "os": "iOS", "lang": Locale.preferredLanguages.first ?? "", "sv": "1.2.0",
        ]
        guard JSONSerialization.isValidJSONObject(body), let data = try? JSONSerialization.data(withJSONObject: body)
        else {
            reportLocked(step: "flush", name: "encode", message: "A batch of \(batch.count) events could not be encoded")
            saveLocked()
            return
        }
        var req = URLRequest(url: endpoint, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        sending = true
        urlSession.dataTask(with: req) { [weak self] _, response, _ in
            guard let self else { return }
            let http = response as? HTTPURLResponse
            self.queue.async { self.finishLocked(batch: batch, code: http?.statusCode, retryAfter: http) }
        }.resume()
    }

    /// Handles a batch's answer. No answer (offline), 5xx or 429: the batch goes back to the front of the queue
    /// and the next try waits longer. Any other 4xx: the batch is dropped and reported. Success: the next batch
    /// goes at once if more are waiting.
    private func finishLocked(batch: [[String: Any]], code: Int?, retryAfter http: HTTPURLResponse?) {
        sending = false
        let retry = code == nil || code! >= 500 || code! == 429
        if retry {
            events.insert(contentsOf: batch, at: 0)
            trimLocked()
            backoff = min(max(backoff * 2, 10), Self.maxBackoff)
            // A 429 or 503 may say how long to wait (in seconds); never more than our own longest wait.
            if let s = http?.value(forHTTPHeaderField: "Retry-After"), let wait = TimeInterval(s), wait > backoff {
                backoff = min(wait, Self.maxBackoff)
            }
            retryAt = Date().addingTimeInterval(backoff)
        } else {
            backoff = 0
            retryAt = .distantPast
        }
        // A refusal is a failure of ours worth knowing about; being offline is not.
        if let code, code >= 400, code != 429 {
            reportLocked(step: "flush", name: "http_\(code)", message: "The service refused a batch with HTTP \(code)")
        }
        saveLocked()
        if !retry, !events.isEmpty { flushLocked(force: inBackground) }
        // Nothing left on its way: tell whoever waits (the background send, tests).
        if !sending {
            let waiting = idleWaiters
            idleWaiters = []
            waiting.forEach { $0() }
        }
    }

    /// Writes the waiting events to the queue file (removes it when there are none). Best effort: a write that
    /// fails only means those events aren't kept across a restart.
    private func saveLocked() {
        guard let url = storeURL else { return }
        if events.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        guard JSONSerialization.isValidJSONObject(events),
              let data = try? JSONSerialization.data(withJSONObject: events)
        else {
            // Never leave an older copy behind: it would be sent again on the next start.
            try? FileManager.default.removeItem(at: url)
            return
        }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// Puts events saved by an earlier run ahead of this run's, once per app run (on the first configure()).
    private func loadStoreLocked() {
        guard !loadedStore, let url = storeURL else { return }
        loadedStore = true
        guard let data = try? Data(contentsOf: url),
              let saved = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return }
        events.insert(contentsOf: saved.filter { $0["t"] is String && $0["sid"] is String }, at: 0)
        trimLocked()
    }

    /// Watches the app going to the background (send now, save the queue, stop the timer) and coming back
    /// (start the timer). Only where UIKit exists; macOS apps keep the timer running.
    private func observeAppState() {
        #if canImport(UIKit) && !os(watchOS)
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) {
            [weak self] _ in self?.enteredBackground()
        }
        center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil) {
            [weak self] _ in
            guard let self else { return }
            self.queue.async {
                self.inBackground = false
                if self.configured { self.startTimerLocked() }
            }
        }
        #endif
    }

    #if canImport(UIKit) && !os(watchOS)
    /// The app went to the background: stop the timer, save the queue and send what is waiting, asking iOS for
    /// a few seconds so the request can finish (performExpiringActivity also works in app extensions; it doesn't
    /// exist on macOS, hence the #if).
    private func enteredBackground() {
        queue.async {
            self.inBackground = true
            self.stopTimerLocked()
            self.saveLocked()
        }
        ProcessInfo.processInfo.performExpiringActivity(withReason: "Metric Sensei Analytics: send queued events") {
            [weak self] expired in
            guard let self, !expired else { return }
            let done = DispatchSemaphore(value: 0)
            self.queue.async {
                self.flushLocked(force: true)
                if self.sending { self.idleWaiters.append { done.signal() } } else { done.signal() }
            }
            _ = done.wait(timeout: .now() + 10)
        }
    }
    #endif

    /// Reports a failure of this SDK itself to the platform's failures dataset (POST /v1/errors, read by
    /// ms_core.failures.client_report): at most 3 an app run, nothing about the person or their events.
    private func reportLocked(step: String, name: String, message: String) {
        guard reportsLeft > 0 else { return }
        reportsLeft -= 1
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let body: [String: Any] = [
            "v": 1, "src": "ios", "sv": "1.2.0", "where": step, "name": name, "msg": message, "site": siteId,
            "os": "iOS \(v.majorVersion).\(v.minorVersion)",
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        var req = URLRequest(url: errorsEndpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        urlSession.dataTask(with: req).resume()
    }
}
