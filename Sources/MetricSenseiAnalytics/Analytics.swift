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

import Foundation

public final class Analytics {
    public static let shared = Analytics()

    private let queue = DispatchQueue(label: "com.metricsensei.analytics")
    private var siteId = ""
    private var appId = Bundle.main.bundleIdentifier ?? ""
    private var endpoint = URL(string: "https://analytics.api.metricsensei.com/v1/app")!
    private var events: [[String: Any]] = []
    private var session = ""
    private var lastActivity = Date.distantPast
    private var screenCount = 0
    private var screenName = ""
    private var timer: DispatchSourceTimer?
    private let defaults = UserDefaults.standard
    private let sessionTimeout: TimeInterval = 30 * 60

    /// Start sending. `host` is for testing environments (e.g. https://analytics.api.dev.metricsensei.com).
    /// Safe to call more than once: the latest site ID and host are used and one send timer runs.
    public func configure(siteId: String, host: String = "https://analytics.api.metricsensei.com") {
        queue.sync {
            self.siteId = siteId
            if let url = URL(string: host + "/v1/app") { self.endpoint = url }
            // Called again (a new site ID, a test host): stop the earlier timer, or each call would leave one
            // more running for the life of the app.
            self.timer?.cancel()
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + 10, repeating: 10)
            t.setEventHandler { [weak self] in self?.flushLocked() }
            t.resume()
            self.timer = t
        }
    }

    /// A screen view (counted like a page view, path "/<name>").
    public func screen(_ name: String) {
        queue.async {
            self.touchSession()
            self.screenCount += 1
            self.screenName = "/" + name.replacingOccurrences(of: " ", with: "-")
            var e: [String: Any] = ["t": "pv", "p": self.screenName, "n": self.screenCount, "at": Date().timeIntervalSince1970]
            if self.screenCount == 2 { e["nb"] = 1 }
            self.push(e)
        }
    }

    /// A named event, with optional properties and revenue.
    public func track(_ name: String, props: [String: Any] = [:], revenue: Double? = nil, currency: String? = nil) {
        queue.async {
            self.touchSession()
            var pr: [String: Any] = props.filter { $0.value is String || $0.value is Int || $0.value is Double }
            if let r = revenue { pr["revenue"] = r }
            if let c = currency { pr["currency"] = c }
            self.push(["t": "ev", "nm": name, "pr": pr, "p": self.screenName, "at": Date().timeIntervalSince1970])
        }
    }

    /// Forget the visitor ID (a new one is made on the next event).
    public func reset() {
        queue.async { self.defaults.removeObject(forKey: "msa_visitor"); self.session = "" }
    }

    /// Send what is queued now (e.g. when the app goes to the background).
    public func flush() { queue.async { self.flushLocked() } }

    // MARK: - internals

    var visitorId: String {
        if let v = defaults.string(forKey: "msa_visitor") { return v }
        let v = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        defaults.set(v, forKey: "msa_visitor")
        return v
    }

    private func touchSession() {
        let now = Date()
        if session.isEmpty || now.timeIntervalSince(lastActivity) > sessionTimeout {
            session = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            screenCount = 0
        }
        lastActivity = now
    }

    private func push(_ event: [String: Any]) {
        events.append(event)
        if events.count >= 20 { flushLocked() }
    }

    private func flushLocked() {
        guard !events.isEmpty, !siteId.isEmpty else { return }
        let batch = Array(events.prefix(50))
        events.removeFirst(batch.count)
        let now = Date().timeIntervalSince1970
        let ev = batch.map { e -> [String: Any] in
            var x = e
            let at = (x.removeValue(forKey: "at") as? Double) ?? now
            x["o"] = Int(max(0, (now - at) * 1000))
            return x
        }
        let body: [String: Any] = [
            "v": 1, "site": siteId, "app": appId, "sid": session, "vid": visitorId, "ev": ev,
            "os": "iOS", "lang": Locale.preferredLanguages.first ?? "", "sv": "1.0.0",
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        URLSession.shared.dataTask(with: req).resume()
    }
}
