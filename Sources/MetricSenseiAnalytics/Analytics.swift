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
// is busy (5xx, 429, 409 "still working on it"), the batch is kept and the next try waits longer (10 s doubling to
// 5 min). A batch is frozen the first time it is sent: it keeps its batch ID ("b") and its events (each with its
// own "id") on every retry, so the service can count it once even when its answer was lost. The queue is also
// kept in a file in the app's caches folder, so events survive the app being closed (iOS may clear that folder
// when the phone is short of space). Events more than a day old are dropped when sent, because the service dates
// an app event at most 24 hours back.
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
    /// An event older than this when it is sent is dropped: the service dates app events at most 24 hours back
    /// (ms-analytics events.APP_MAX_OFFSET_MS); a little under, for clock drift and the time the request takes.
    static let maxAge: TimeInterval = 86_000
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
    /// later, or after a restart, still names the session it happened in. Those three are taken out when sent;
    /// its `id` (16 hex) is sent, so the service can tell a resent event from a new one.
    private var events: [[String: Any]] = []
    /// The batch being sent or waiting to be tried again: `b` (32 hex), `sid`, `vid` and its `events`. It never
    /// changes once made (only events past `maxAge` fall out), so every try is the same batch to the service.
    private var pending: [String: Any]?
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

    /// For tests: how many events are waiting, the pending batch's included.
    var queuedCount: Int { queue.sync { events.count + ((pending?["events"] as? [[String: Any]])?.count ?? 0) } }

    /// Random lowercase hex, `bytes` * 2 characters long (batch and event IDs).
    static func randomHex(bytes: Int) -> String {
        (0..<bytes).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

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
        e["id"] = Self.randomHex(bytes: 8)
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

    /// Sends the pending batch, or freezes the next one (up to 50 events of one session and visitor, oldest
    /// first) as the pending batch and sends that. Waits while a batch is on its way, and (unless `force`) while a
    /// failed send's backoff runs. Old events are dropped here. The pending batch is saved before it is sent, so a
    /// batch whose answer never came is sent again (the same batch: the service counts it once).
    private func flushLocked(force: Bool) {
        guard !sending, !siteId.isEmpty, force || Date() >= retryAt else { return }
        let now = Date().timeIntervalSince1970
        let fresh: ([String: Any]) -> Bool = { now - (($0["at"] as? Double) ?? now) <= Self.maxAge }
        events = events.filter(fresh)
        if var p = pending {
            let kept = ((p["events"] as? [[String: Any]]) ?? []).filter(fresh)
            p["events"] = kept
            pending = kept.isEmpty ? nil : p
        }
        if pending == nil, let first = events.first {
            let sid = (first["sid"] as? String) ?? session
            let vid = (first["vid"] as? String) ?? visitorId
            var count = 0
            while count < min(events.count, Self.maxBatch),
                  ((events[count]["sid"] as? String) ?? sid) == sid, ((events[count]["vid"] as? String) ?? vid) == vid {
                count += 1
            }
            // Built by subscript, not a literal: these keys are the queue file's, never sent.
            var p = [String: Any]()
            p["b"] = Self.randomHex(bytes: 16)
            p["sid"] = sid
            p["vid"] = vid
            p["events"] = Array(events.prefix(count))
            events.removeFirst(count)
            pending = p
        }
        saveLocked()
        guard let p = pending, let batch = p["events"] as? [[String: Any]], let b = p["b"] as? String,
              let sid = p["sid"] as? String, let vid = p["vid"] as? String
        else { return }
        let ev = batch.map { e -> [String: Any] in
            var x = e
            let at = (x.removeValue(forKey: "at") as? Double) ?? now
            x.removeValue(forKey: "sid")
            x.removeValue(forKey: "vid")
            x["o"] = Int(max(0, (now - at) * 1000))
            return x
        }
        let body: [String: Any] = [
            "v": 1, "site": siteId, "app": appId, "b": b, "sid": sid, "vid": vid, "ev": ev,
            "os": "iOS", "lang": Locale.preferredLanguages.first ?? "", "sv": "1.3.0",
        ]
        guard JSONSerialization.isValidJSONObject(body), let data = try? JSONSerialization.data(withJSONObject: body)
        else {
            reportLocked(step: "flush", name: "encode", message: "A batch of \(batch.count) events could not be encoded")
            pending = nil
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
            self.queue.async { self.finishLocked(code: http?.statusCode, retryAfter: http) }
        }.resume()
    }

    /// Handles the pending batch's answer. No answer (offline), 5xx, 429 or 409 (the service is still handling
    /// this batch from an earlier try): the batch stays pending and the next try waits longer. Any other 4xx: the
    /// batch is dropped and reported. Success (also "duplicate": the service already has it): the batch is done
    /// and the next one goes at once if more are waiting.
    private func finishLocked(code: Int?, retryAfter http: HTTPURLResponse?) {
        sending = false
        let retry = code.map { $0 >= 500 || $0 == 429 || $0 == 409 } ?? true
        if retry {
            backoff = min(max(backoff * 2, 10), Self.maxBackoff)
            // A 429, 409 or 503 may say how long to wait (in seconds); never more than our own longest wait.
            if let s = http?.value(forHTTPHeaderField: "Retry-After"), let wait = TimeInterval(s), wait > backoff {
                backoff = min(wait, Self.maxBackoff)
            }
            retryAt = Date().addingTimeInterval(backoff)
        } else {
            pending = nil
            backoff = 0
            retryAt = .distantPast
        }
        // A refusal is a failure of ours worth knowing about; being offline, "slow down" and "still working" are not.
        if let code, code >= 400, code != 429, code != 409 {
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

    /// Writes the pending batch and the waiting events to the queue file as `{"pending": ..., "events": [...]}`
    /// (removes it when there is nothing). Best effort: a write that fails only means those events aren't kept
    /// across a restart.
    private func saveLocked() {
        guard let url = storeURL else { return }
        if events.isEmpty && pending == nil {
            try? FileManager.default.removeItem(at: url)
            return
        }
        // Built by subscript, not a literal: these keys are the file's, never sent.
        var doc = [String: Any]()
        doc["events"] = events
        if let p = pending { doc["pending"] = p }
        guard JSONSerialization.isValidJSONObject(doc), let data = try? JSONSerialization.data(withJSONObject: doc)
        else {
            // Never leave an older copy behind: it would be sent again on the next start.
            try? FileManager.default.removeItem(at: url)
            return
        }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// Puts what an earlier run saved ahead of this run's events, once per app run (on the first configure()).
    /// Reads both the 1.3 file (`{"pending", "events"}`) and 1.2's plain list of events (no batch or event IDs:
    /// they are queued like new ones).
    private func loadStoreLocked() {
        guard !loadedStore, let url = storeURL else { return }
        loadedStore = true
        guard let data = try? Data(contentsOf: url), let json = try? JSONSerialization.jsonObject(with: data) else {
            return
        }
        let valid: ([String: Any]) -> Bool = { $0["t"] is String && $0["sid"] is String }
        var saved: [[String: Any]] = []
        if let list = json as? [[String: Any]] {
            saved = list
        } else if let doc = json as? [String: Any] {
            saved = (doc["events"] as? [[String: Any]]) ?? []
            if pending == nil, var p = doc["pending"] as? [String: Any], p["b"] is String, p["sid"] is String,
               p["vid"] is String {
                let members = ((p["events"] as? [[String: Any]]) ?? []).filter(valid)
                p["events"] = members
                if !members.isEmpty { pending = p }
            }
        }
        events.insert(contentsOf: saved.filter(valid), at: 0)
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
            "v": 1, "src": "ios", "sv": "1.3.0", "where": step, "name": name, "msg": message, "site": siteId,
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
