import Foundation

/// Claude's plan limits, as Claude Code's /usage shows them, asked of its own
/// engine with a `get_usage` control request. No model is asked, no hook or
/// MCP server runs, and nothing is saved.
public enum ClaudeUsage {
    /// Model families that can have a week of their own, largest first.
    static let families = ["opus", "sonnet", "haiku", "fable", "mythos"]

    /// The answer usually comes in a fraction of a second; this is for a slow network.
    static let patience: TimeInterval = 20

    public static func read() throws -> AgentReading {
        guard let claude = Executables.find("claude") else {
            throw ReadError("Claude Code (the claude command) isn't installed. Install it and sign in to see your limits.")
        }
        let engine = JSONLineProcess(
            executable: claude,
            arguments: [
                "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                "--settings", #"{"disableAllHooks":true}"#, "--strict-mcp-config", "--no-session-persistence",
            ],
            // Its optional traffic stays on: without it the answer is quicker but
            // can leave out the per-model weeks.
            environment: Environment.engineEnvironment(["CLAUDE_CODE_ENTRYPOINT": "agent-buddy"]),
            directory: Environment.workDirectory)
        try engine.start()
        defer { engine.stop() }

        let asked = "agent-buddy-usage"
        // `skip_behaviors` leaves out its usage tips, which it would work out from your transcripts.
        try engine.send([
            "type": "control_request", "request_id": asked,
            "request": ["subtype": "get_usage", "skip_behaviors": true] as [String: Any],
        ])
        let deadline = Date().addingTimeInterval(patience)
        while let message = engine.next(until: deadline) {
            let answer = message["response"]
            guard message["type"].string == "control_response", (answer["request_id"].string ?? asked) == asked else { continue }
            if answer["subtype"].string == "error" {
                throw ReadError("Claude Code couldn't read usage: \(answer["error"].nonEmptyString ?? "no reason given")")
            }
            return try parse(payload: answer["response"], profile: profile())
        }
        if let complaint = engine.errorPreview {
            throw ReadError("Claude Code couldn't read usage: \(complaint)")
        }
        throw ReadError(engine.hasEnded
            ? "Claude Code stopped without reporting usage. Run claude to check your sign-in."
            : "Claude Code didn't report usage within \(Int(patience)) s")
    }

    /// The signed-in account, from Claude Code's profile.
    static func profile() -> JSON {
        guard let data = try? Data(contentsOf: Environment.claudeProfile), let file = JSON.parse(data) else {
            return JSON(nil)
        }
        return file["oauthAccount"]
    }

    public static func parse(payload: JSON, profile: JSON) throws -> AgentReading {
        guard payload.isObject else {
            throw ReadError("Claude Code returned an empty usage answer")
        }
        var reading = AgentReading(agent: .claude)
        reading.account = profile["emailAddress"].nonEmptyString
        reading.plan = planName(profile: profile, subscription: payload["subscription_type"].string)
        guard payload["rate_limits_available"].bool == true else {
            reading.notes = ["No plan limits for this sign-in (an API key, a cloud platform, or signed out). Run claude to sign in with your Claude plan."]
            return reading
        }
        // Available but missing: Claude Code's own lookup failed, so the last reading stays.
        guard payload["rate_limits"].isObject else {
            throw ReadError("Couldn't read the Claude quota this time; retrying shortly")
        }
        reading.windows = windows(payload["rate_limits"])
        guard !reading.windows.isEmpty else {
            throw ReadError("Claude Code returned usage data this app doesn't recognise")
        }
        if let credits = creditsNote(payload["rate_limits"]["spend"]) {
            reading.notes.append(credits)
        }
        return reading
    }

    /// Usage credits, which cover you past the plan's limits: said when they're
    /// on, or have been used; nothing when they're off and untouched.
    public static func creditsNote(_ spend: JSON) -> String? {
        guard spend.isObject else { return nil }
        let used = spend["used"]
        let minor = used["amount_minor"].double ?? 0
        let money = minor / pow(10, used["exponent"].double ?? 2)
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = used["currency"].nonEmptyString ?? "USD"
        let amount = formatter.string(from: NSNumber(value: money)) ?? String(format: "%.2f", money)
        if spend["enabled"].bool == true {
            return "Usage credits on: \(amount) used, past your plan's limits"
        }
        return minor > 0 ? "Usage credits: \(amount) used" : nil
    }

    /// One limit Claude Code reported: the session, the week, or one model's week.
    private struct Limit {
        enum Span: Hashable { case session, week, model(String) }
        let span: Span
        let percent: Double
        let resetsAt: Date?
        /// "Up to 50% of your week": a model's share of the week.
        var detail: String?

        init?(_ span: Span, _ entry: JSON, percentKey: String) {
            guard let percent = entry[percentKey].double else { return nil }
            self.span = span
            self.percent = percent
            self.resetsAt = Dates.parse(entry["resets_at"].string)
        }
    }

    /// The 5-hour session (on plans that still have one), the week across
    /// models, then each model's own week (on newer plans, its share of the week).
    static func windows(_ rateLimits: JSON) -> [UsageWindow] {
        var limits: [Limit.Span: Limit] = [:]
        func keep(_ limit: Limit?) {
            if let limit { limits[limit.span] = limit }
        }
        // Named fields first...
        keep(Limit(.session, rateLimits["five_hour"], percentKey: "utilization"))
        keep(Limit(.week, rateLimits["seven_day"], percentKey: "utilization"))
        for family in families {
            keep(Limit(.model(family), rateLimits["seven_day_\(family)"], percentKey: "utilization"))
        }
        for model in rateLimits["model_scoped"].array {
            guard let name = model["display_name"].nonEmptyString else { continue }
            keep(Limit(.model(family(of: name) ?? name.lowercased()), model, percentKey: "utilization"))
        }
        // ...then the list newer versions send, which wins where both say the same.
        // A model's share of the week, by its place in the list.
        var shares: [Int: Double] = [:]
        for share in rateLimits["weekly_scoped_shares"].array {
            if let index = share["limit_index"].int, let allowance = share["allowance_percent_of_weekly"].double {
                shares[index] = allowance
            }
        }
        for (index, entry) in rateLimits["limits"].array.enumerated() {
            switch entry["kind"].string {
            case "session":
                keep(Limit(.session, entry, percentKey: "percent"))
            case "weekly_all":
                keep(Limit(.week, entry, percentKey: "percent"))
            case "weekly_scoped":
                let model = entry["scope"]["model"]
                guard let name = model["display_name"].nonEmptyString ?? model["id"].nonEmptyString,
                      var limit = Limit(.model(family(of: name) ?? name.lowercased()), entry, percentKey: "percent")
                else { continue }
                limit.detail = shares[index].map { "Up to \(Int($0.rounded()))% of your week" }
                keep(limit)
            default:
                continue
            }
        }

        let models = limits.keys.compactMap { span -> String? in
            if case .model(let name) = span { return name }
            return nil
        }
        let spans: [Limit.Span] = [.session, .week] + models.sorted(by: familyOrder).map { .model($0) }
        return spans.compactMap { span in
            limits[span].map(window)
        }
    }

    private static func window(_ limit: Limit) -> UsageWindow {
        switch limit.span {
        case .session:
            return UsageWindow(id: "claude.session", kind: .session, title: "Current session",
                               usedPercent: limit.percent, resetsAt: limit.resetsAt, windowSeconds: 5 * 3600)
        case .week:
            return UsageWindow(id: "claude.weekly", kind: .weekly, title: "Weekly · All models",
                               usedPercent: limit.percent, resetsAt: limit.resetsAt, windowSeconds: 7 * 86400)
        case .model(let name):
            return UsageWindow(id: "claude.weekly.\(name)", kind: .weeklyModel, title: "Weekly · \(TextTools.capitalized(name))",
                               usedPercent: limit.percent, resetsAt: limit.resetsAt, windowSeconds: 7 * 86400, detail: limit.detail)
        }
    }

    /// Known families largest first, then any other name alphabetically.
    private static func familyOrder(_ a: String, _ b: String) -> Bool {
        let rank = { (name: String) in families.firstIndex(of: name) ?? families.count }
        return (rank(a), a) < (rank(b), b)
    }

    /// A model id's or name's family: the first of its words that names one.
    static func family(of model: String) -> String? {
        model.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .first(where: { families.contains(String($0)) })
            .map(String.init)
    }

    /// The plan as Claude names it ("Ultra"), else from the profile's organization
    /// and tier, else the answer's subscription.
    public static func planName(profile: JSON, subscription: String?) -> String? {
        if let named = profile["planDisplayName"].nonEmptyString {
            return named
        }
        let tier = (profile["userRateLimitTier"].string ?? profile["organizationRateLimitTier"].string ?? "").lowercased()
        let named = ["claude_pro": "Pro", "claude_team": "Team", "claude_enterprise": "Enterprise"]
        switch profile["organizationType"].string {
        case "claude_max":
            let multiple = ["20x", "5x"].first { tier.contains($0) }
            return multiple.map { "Max \($0)" } ?? "Max"
        case let organization?:
            if let name = named[organization] { return name }
        case nil:
            break
        }
        guard let subscription, !subscription.isEmpty else { return nil }
        return TextTools.capitalized(subscription)
    }
}
