import Foundation

/// The Codex limits on a ChatGPT plan, asked of the Codex CLI's own
/// `app-server` with its account/rateLimits/read request. When no Codex can be
/// started, the newest rate-limit snapshot in Codex's session logs stands in.
public enum CodexUsage {
    /// OpenAI's servers answer in about a second; this is for a slow network.
    static let patience: TimeInterval = 20

    public static func read() throws -> AgentReading {
        var problem: Error?
        if let codex = Executables.find("codex") {
            do {
                return try askAppServer(codex)
            } catch {
                problem = error
            }
        }
        if var fallback = latestFromSessionLogs() {
            fallback.notes.append("From your latest Codex session log, because the Codex app-server didn't answer.")
            return fallback
        }
        throw problem ?? ReadError("Codex isn't installed. Install the Codex CLI or the ChatGPT desktop app and sign in.")
    }

    /// The requests, by id: the limits and the account are asked together once the server is ready.
    private enum Ask: Int {
        case hello = 1, limits, account
    }

    static func askAppServer(_ codex: URL) throws -> AgentReading {
        let server = JSONLineProcess(
            executable: codex, arguments: ["app-server", "--listen", "stdio://"],
            environment: Environment.engineEnvironment(), directory: Environment.workDirectory)
        try server.start()
        defer { server.stop() }
        try server.send([
            "id": Ask.hello.rawValue, "method": "initialize",
            "params": ["clientInfo": ["name": "agent_buddy", "title": "Agent Buddy", "version": "1.0.0"]] as [String: Any],
        ])

        var limits: JSON?
        var account: JSON?
        var deadline = Date().addingTimeInterval(patience)
        while limits == nil || account == nil, let message = server.next(until: deadline) {
            // Answers only: the server's own requests and notices carry a method.
            guard message["method"].isNull, let ask = message["id"].int.flatMap(Ask.init(rawValue:)) else { continue }
            let failure = message["error"].isObject ? message["error"]["message"].nonEmptyString ?? "app-server error" : nil
            switch ask {
            case .hello:
                if let failure { throw ReadError("Codex: \(failure)") }
                try server.send(["method": "initialized"])
                try server.send(["id": Ask.limits.rawValue, "method": "account/rateLimits/read"])
                try server.send(["id": Ask.account.rawValue, "method": "account/read", "params": [String: Any]()])
            case .limits:
                if let failure { throw ReadError("Codex: \(failure)") }
                limits = message["result"]
                // The account comes at once; the limits don't wait long for it.
                deadline = min(deadline, Date().addingTimeInterval(0.5))
            case .account:
                // An older Codex without account/read still reports its limits.
                account = failure == nil ? message["result"]["account"] : JSON(nil)
            }
        }
        guard let limits else {
            throw ReadError(server.hasEnded
                ? "Codex stopped before reporting limits. Run codex login to check your sign-in."
                : "Codex didn't report its limits in time")
        }
        return parse(limits: limits, account: account ?? JSON(nil))
    }

    // MARK: - Reading the answer

    /// The first of `names` that `object` has: the app-server says `usedPercent`,
    /// the session logs `used_percent`.
    private static func either(_ object: JSON, _ names: String...) -> JSON {
        names.lazy.map { object[$0] }.first { !$0.isNull } ?? JSON(nil)
    }

    /// One set of limits: Codex's own ("codex"), or one for a particular model.
    private struct Bucket {
        let id: String
        let value: JSON

        var name: String { CodexUsage.either(value, "limitName", "limit_name").nonEmptyString ?? id }
        var plan: String? { CodexUsage.either(value, "planType", "plan_type").nonEmptyString }
    }

    /// Codex's own bucket first, then the others by id.
    private static func buckets(_ limits: JSON) -> [Bucket] {
        var found: [Bucket]
        if let byID = limits["rateLimitsByLimitId"].object {
            found = byID.map { Bucket(id: $0.key, value: $0.value) }
        } else if limits["rateLimits"].isObject {
            found = [Bucket(id: limits["rateLimits"]["limitId"].nonEmptyString ?? "codex", value: limits["rateLimits"])]
        } else {
            found = []
        }
        return found.sorted { ($0.id == "codex" ? 0 : 1, $0.id) < ($1.id == "codex" ? 0 : 1, $1.id) }
    }

    /// Reads app-server answers and session-log snapshots alike.
    public static func parse(limits: JSON, account: JSON, fetchedAt: Date = Date()) -> AgentReading {
        var reading = AgentReading(agent: .codex, fetchedAt: fetchedAt)
        reading.account = account["email"].nonEmptyString
        let buckets = Self.buckets(limits)
        reading.plan = (buckets.lazy.compactMap(\.plan).first ?? account["planType"].nonEmptyString).map(planName)

        for bucket in buckets {
            // "primary" is the shorter of a bucket's two limits, "secondary" the longer.
            for slot in ["primary", "secondary"] {
                let limit = bucket.value[slot]
                guard let used = either(limit, "usedPercent", "used_percent").double else { continue }
                let minutes = either(limit, "windowDurationMins", "window_minutes").double
                let period = periodName(minutes: minutes, secondary: slot == "secondary")
                reading.windows.append(UsageWindow(
                    id: "codex.\(bucket.id).\(slot)",
                    kind: minutes == 300 ? .session : (minutes == 7 * 1440 ? .weekly : .other),
                    title: bucket.id == "codex" ? "\(period) limit" : "\(bucket.name) · \(period)",
                    usedPercent: used,
                    resetsAt: Dates.epoch(either(limit, "resetsAt", "resets_at").double),
                    windowSeconds: minutes.map { $0 * 60 }))
            }
        }
        let credits = either(either(limits, "rateLimitResetCredits", "rate_limit_reset_credits"), "availableCount", "available_count").int
        if let credits, credits > 0 {
            reading.notes.append("\(credits) free limit reset\(credits == 1 ? "" : "s") available in Codex")
        }
        if reading.windows.isEmpty {
            reading.notes.append("Codex reported no limits for this sign-in.")
        }
        return reading
    }

    /// "5-hour", "Daily", "Weekly", "Monthly", "3-day"; without a length, the
    /// shorter or longer of the bucket's two limits.
    public static func periodName(minutes: Double?, secondary: Bool) -> String {
        guard let minutes, minutes > 0 else { return secondary ? "Long-term" : "Short-term" }
        let hours = minutes / 60
        let days = hours / 24
        switch days {
        case 1: return "Daily"
        case 7: return "Weekly"
        case 28...31: return "Monthly"
        default: break
        }
        if days >= 1, days == days.rounded() {
            return "\(Int(days))-day"
        }
        return "\(Int(hours.rounded()))-hour"
    }

    static func planName(_ plan: String) -> String {
        ["prolite": "Pro Lite", "edu": "Edu"][plan.lowercased()] ?? TextTools.capitalized(plan)
    }

    // MARK: - Codex's session logs

    /// A `token_count` event's `rate_limits`, as Codex writes them into its session logs.
    public static func reading(fromTokenCount rateLimits: JSON, at date: Date) -> AgentReading? {
        guard rateLimits.isObject, let snapshot = rateLimits.raw else { return nil }
        let id = rateLimits["limit_id"].nonEmptyString ?? "codex"
        let parsed = parse(limits: JSON(["rateLimitsByLimitId": [id: snapshot]]), account: JSON(nil), fetchedAt: date)
        guard !parsed.windows.isEmpty else { return nil }
        return AgentReading(agent: .codex, windows: parsed.windows, plan: parsed.plan, fetchedAt: date)
    }

    /// The newest rate-limit snapshot in Codex's recent session logs.
    static func latestFromSessionLogs() -> AgentReading? {
        let marker = Data("\"token_count\"".utf8)
        for file in recentRollouts(limit: 6) {
            guard let tail = Tail.read(file, maxBytes: 1 << 20) else { continue }
            for line in tail.lines.reversed() where line.range(of: marker) != nil {
                guard let event = JSON.parse(line), event["payload"]["type"].string == "token_count",
                      let at = Dates.parse(event["timestamp"].string),
                      let reading = reading(fromTokenCount: event["payload"]["rate_limits"], at: at)
                else { continue }
                return reading
            }
        }
        return nil
    }

    /// The newest `rollout-*.jsonl` files, from the latest days under `sessions/YYYY/MM/DD`.
    static func recentRollouts(limit: Int) -> [URL] {
        let files = FileManager.default
        func latestFirst(_ folder: URL) -> [URL] {
            ((try? files.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
        }
        func modified(_ file: URL) -> Date {
            (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        }
        let days = latestFirst(Environment.codexHome.appendingPathComponent("sessions"))
            .lazy.flatMap(latestFirst).flatMap(latestFirst)
        var found: [URL] = []
        for day in days where found.count < limit {
            found += latestFirst(day)
                .filter { $0.lastPathComponent.hasPrefix("rollout-") && $0.pathExtension == "jsonl" }
                .sorted { modified($0) > modified($1) }
        }
        return Array(found.prefix(limit))
    }
}

/// The end of a file, split into whole lines.
struct Tail {
    var lines: [Data]

    static func read(_ url: URL, maxBytes: UInt64) -> Tail? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > maxBytes ? size - maxBytes : 0
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd() else { return nil }
        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: true).map { Data($0) }
        // Read from the middle of a file, the first line is only its end.
        if start > 0, !lines.isEmpty {
            lines.removeFirst()
        }
        return Tail(lines: lines)
    }
}
