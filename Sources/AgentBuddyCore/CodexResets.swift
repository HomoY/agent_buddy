import Foundation

/// OpenAI now and then resets everyone's Codex limits early, outside each
/// account's own 5-hour and weekly windows. codex-reset.com, a community
/// tracker (not OpenAI's), records each reset and works out the chance of the
/// next from their history. Its data is free on one condition: where it's
/// shown, credit "Data: codex-reset.com" with a link to the site.
public struct CodexResetForecast: Equatable, Sendable {
    /// The last confirmed reset for everyone.
    public var lastResetAt: Date?
    /// The chance (%) of another within 24 and 48 hours.
    public var chance24h: Int
    public var chance48h: Int
    /// How sure the forecast is: "low", "medium" or "high".
    public var confidence: String?
    /// The hours resets have usually come, in this Mac's time zone ("12 PM - 3 PM").
    public var usualHours: String?
    /// A reset OpenAI has said is coming, while that's open.
    public var announced: Announcement?
    public var updatedAt: Date?

    public struct Announcement: Equatable, Sendable {
        public var summary: String
        public var url: URL?
        /// When, as the site words it ("tonight", "3 PM - 5 PM PT"…).
        public var window: String?
        public var start: Date?
        public var end: Date?
        public var target: Date?

        public init(summary: String, url: URL? = nil, window: String? = nil, start: Date? = nil, end: Date? = nil, target: Date? = nil) {
            self.summary = summary
            self.url = url
            self.window = window
            self.start = start
            self.end = end
            self.target = target
        }
    }

    public init(
        lastResetAt: Date?, chance24h: Int, chance48h: Int, confidence: String? = nil, usualHours: String? = nil,
        announced: Announcement? = nil, updatedAt: Date? = nil
    ) {
        self.lastResetAt = lastResetAt
        self.chance24h = chance24h
        self.chance48h = chance48h
        self.confidence = confidence
        self.usualHours = usualHours
        self.announced = announced
        self.updatedAt = updatedAt
    }

    /// `GET /api/forecast`. Only its documented fields are read: the rest may change.
    public static func parse(_ json: JSON) -> CodexResetForecast? {
        let chances = json["probabilities"]
        guard let day = chances["rounded_24h"].int, let twoDays = chances["rounded_48h"].int else { return nil }
        var forecast = CodexResetForecast(
            lastResetAt: Dates.parse(json["last_reset_at"].string), chance24h: min(max(day, 0), 100),
            chance48h: min(max(twoDays, 0), 100), confidence: json["confidence"].nonEmptyString,
            usualHours: json["time_window"]["label"].nonEmptyString, updatedAt: Dates.parse(json["updated_at"].string))
        // The canonical Alert: an active Watch is a reset said to be coming.
        let alert = json["latest_alert"]
        if alert["kind"].string == "watch", alert["state"].string == "active", let summary = alert["summary"].nonEmptyString {
            let window = alert["window"]
            forecast.announced = Announcement(
                summary: summary, url: alert["url"].nonEmptyString.flatMap(URL.init(string:)),
                window: window["label"].nonEmptyString, start: Dates.parse(window["start_at"].string),
                end: Dates.parse(window["end_at"].string), target: Dates.parse(window["target_at"].string))
        }
        return forecast
    }
}

public enum CodexResetSource {
    public static let site = URL(string: "https://codex-reset.com/")!
    /// The site asks readers to name themselves, and to poll once a minute at most.
    static let userAgent = "AgentBuddy/1.0 (macOS menu bar app for agent usage; reads the forecast at most every 10 minutes)"

    public enum Failure: Error, Equatable {
        /// Asked to come back later (HTTP 429), after this long when it said.
        case busy(retryAfter: TimeInterval?)
        case unreadable(String)
    }

    /// Blocking: the forecast, with its hours in `timeZone`.
    public static func fetch(timeZone: TimeZone = .current, timeout: TimeInterval = 15) -> Result<CodexResetForecast, Failure> {
        var components = URLComponents(url: site.appendingPathComponent("api/forecast"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "tz", value: timeZone.identifier)]
        guard let url = components?.url else { return .failure(.unreadable("no address")) }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        final class Outcome: @unchecked Sendable {
            var data: Data?
            var response: HTTPURLResponse?
            var error: Error?
        }
        let outcome = Outcome()
        let done = DispatchSemaphore(value: 0)
        URLSession(configuration: .ephemeral).dataTask(with: request) { data, response, error in
            outcome.data = data
            outcome.response = response as? HTTPURLResponse
            outcome.error = error
            done.signal()
        }.resume()
        done.wait()
        if let error = outcome.error {
            return .failure(.unreadable(error.localizedDescription))
        }
        guard let response = outcome.response else { return .failure(.unreadable("no answer")) }
        if response.statusCode == 429 || response.statusCode == 503 {
            let wait = (response.value(forHTTPHeaderField: "Retry-After")).flatMap(TimeInterval.init)
            return .failure(.busy(retryAfter: wait))
        }
        guard (200..<300).contains(response.statusCode) else { return .failure(.unreadable("HTTP \(response.statusCode)")) }
        guard let data = outcome.data, let json = JSON.parse(data), let forecast = CodexResetForecast.parse(json) else {
            return .failure(.unreadable("an answer Agent Buddy doesn't understand"))
        }
        return .success(forecast)
    }
}
