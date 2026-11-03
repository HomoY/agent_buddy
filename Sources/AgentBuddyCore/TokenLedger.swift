import Foundation

/// Tokens of one kind or another. `total` adds all four, as each vendor bills them.
public struct TokenCounts: Codable, Equatable, Sendable {
    public var input: Int
    public var output: Int
    public var cacheWrite: Int
    public var cacheRead: Int

    public init(input: Int = 0, output: Int = 0, cacheWrite: Int = 0, cacheRead: Int = 0) {
        self.input = input
        self.output = output
        self.cacheWrite = cacheWrite
        self.cacheRead = cacheRead
    }

    public var total: Int { input + output + cacheWrite + cacheRead }

    public static func + (lhs: TokenCounts, rhs: TokenCounts) -> TokenCounts {
        TokenCounts(
            input: lhs.input + rhs.input, output: lhs.output + rhs.output,
            cacheWrite: lhs.cacheWrite + rhs.cacheWrite, cacheRead: lhs.cacheRead + rhs.cacheRead)
    }

    public static func += (lhs: inout TokenCounts, rhs: TokenCounts) {
        lhs = lhs + rhs
    }
}

/// One counted model call (Claude Code, Codex) or one ended session (Copilot).
public struct TokenEntry: Codable, Equatable, Sendable {
    public var agent: Agent
    public var model: String
    public var at: Date
    public var counts: TokenCounts
    /// The server it was used on; nil for this Mac.
    public var source: String?

    public init(agent: Agent, model: String, at: Date, counts: TokenCounts, source: String? = nil) {
        self.agent = agent
        self.model = model
        self.at = at
        self.counts = counts
        self.source = source
    }
}

/// Token use over the last weeks, read from the agents' own session logs and
/// kept in a cache, so a refresh only reads what was written since the last one.
///
/// - Claude Code: each assistant message's `usage`, once per message and request
///   (one message is written as several lines, and forked sessions copy history).
/// - Codex: each `token_usage_record` (one per model response), once per response;
///   older logs without them fall back to the growth of `total_token_usage`.
/// - Copilot: the per-model totals its `session.shutdown` record carries,
///   counted when the session ends.
public final class TokenLedger: @unchecked Sendable {
    public static let windowDays = 35

    private struct FileRecord: Codable {
        var agent: Agent
        var size: UInt64
        var modified: Date
        /// Claude logs are read on from here; other logs are read again when they change.
        var offset: UInt64
        var entries: [String: TokenEntry]
    }

    private struct Cache: Codable {
        var version: Int
        var files: [String: FileRecord]
    }

    private static let cacheVersion = 1
    private let roots: TranscriptWatcher.Roots
    private let logRoots: AgentLogRoots
    private let cacheURL: URL?
    private let lock = NSLock()
    private var files: [String: FileRecord] = [:]
    /// Bytes read by the last refresh (for the checks).
    public private(set) var lastBytesRead: UInt64 = 0

    public init(roots: TranscriptWatcher.Roots, logRoots: AgentLogRoots = .standard(), cacheURL: URL?) {
        self.roots = roots
        self.logRoots = logRoots
        self.cacheURL = cacheURL
        if let cacheURL, let data = try? Data(contentsOf: cacheURL),
           let cache = try? JSONDecoder().decode(Cache.self, from: data), cache.version == Self.cacheVersion {
            files = cache.files
        }
    }

    /// Reads what's new and returns every entry of the window, each counted once.
    /// Blocking: call it off the main thread.
    public func refresh(now: Date = Date()) -> [TokenEntry] {
        lock.lock()
        defer { lock.unlock() }
        let cutoff = now.addingTimeInterval(-Double(Self.windowDays) * 86400)
        var present = Set<String>()
        var changed = false
        lastBytesRead = 0
        for (agent, url, size, modified) in candidates(after: cutoff) {
            let path = url.path
            present.insert(path)
            if let record = files[path], record.size == size, record.modified == modified {
                continue
            }
            changed = true
            if agent == .claude, var record = files[path], size > record.offset, modified >= record.modified {
                // Appended to: read only the new lines.
                readClaude(url, from: record.offset, into: &record)
                record.size = size
                record.modified = modified
                files[path] = record
            } else {
                var record = FileRecord(agent: agent, size: size, modified: modified, offset: 0, entries: [:])
                switch agent {
                case .claude: readClaude(url, from: 0, into: &record)
                case .codex: readCodex(url, into: &record)
                case .copilot: readCopilot(url, into: &record)
                default:
                    // Read whole, each reply's tokens by its own key.
                    if case .success(let session) = AgentLogs.read(agent: agent, path: path) {
                        record.entries = session.tokens
                    }
                }
                files[path] = record
            }
        }
        // Forget logs that left the window or were deleted, and entries older than it.
        for path in files.keys where !present.contains(path) {
            files[path] = nil
            changed = true
        }
        var unique: [String: TokenEntry] = [:]
        for path in files.keys {
            guard var record = files[path] else { continue }
            let before = record.entries.count
            record.entries = record.entries.filter { $0.value.at >= cutoff }
            if record.entries.count != before {
                files[path] = record
                changed = true
            }
            for (key, entry) in record.entries {
                unique[key] = entry
            }
        }
        if changed {
            save()
        }
        return Array(unique.values)
    }

    private func save() {
        guard let cacheURL else { return }
        let cache = Cache(version: Self.cacheVersion, files: files)
        if let data = try? JSONEncoder().encode(cache) {
            try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: cacheURL, options: .atomic)
        }
    }

    // MARK: - Which logs

    private func candidates(after cutoff: Date) -> [(Agent, URL, UInt64, Date)] {
        var found: [(Agent, URL, UInt64, Date)] = []
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        func walk(_ root: URL, _ agent: Agent, _ accept: (URL) -> Bool) {
            guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return }
            for case let url as URL in walker where url.pathExtension == "jsonl" && accept(url) {
                guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                      let modified = values.contentModificationDate, modified >= cutoff
                else { continue }
                found.append((agent, url, UInt64(values.fileSize ?? 0), modified))
            }
        }
        walk(roots.claudeProjects, .claude) { _ in true }
        walk(roots.codexSessions, .codex) { $0.lastPathComponent.hasPrefix("rollout-") }
        walk(roots.copilotSessions, .copilot) { $0.lastPathComponent == "events.jsonl" }
        // The agents watched through their logs alone (OpenCode's sessions are rows of one database).
        for session in AgentLogs.sessions(since: cutoff, roots: logRoots) {
            let size = (try? FileManager.default.attributesOfItem(atPath: session.path))?[.size] as? UInt64 ?? 0
            found.append((session.agent, URL(fileURLWithPath: session.path), size, session.modified))
        }
        return found
    }

    // MARK: - Reading

    /// Whole lines from `offset` on; returns them and where the last whole line ends.
    private func lines(_ url: URL, from offset: UInt64) -> (lines: [Data], end: UInt64) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return ([], offset) }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: offset)) != nil, let data = try? handle.readToEnd(), !data.isEmpty else {
            return ([], offset)
        }
        lastBytesRead += UInt64(data.count)
        guard let lastNewline = data.lastIndex(of: 0x0A) else { return ([], offset) }
        let whole = data[data.startIndex...lastNewline]
        let parts = whole.split(separator: 0x0A, omittingEmptySubsequences: true)
        return (parts.map { Data($0) }, offset + UInt64(whole.count))
    }

    private static let usageMarker = Data("\"usage\"".utf8)
    private static let tokenMarker = Data("token_".utf8)
    private static let turnContextMarker = Data("\"turn_context\"".utf8)
    private static let sessionMetaMarker = Data("\"session_meta\"".utf8)
    private static let shutdownMarker = Data("session.shutdown".utf8)

    private func readClaude(_ url: URL, from offset: UInt64, into record: inout FileRecord) {
        let (lines, end) = lines(url, from: offset)
        for line in lines where line.range(of: Self.usageMarker) != nil {
            if let (key, entry) = Self.claudeEntry(line) {
                record.entries[key] = entry
            }
        }
        record.offset = end
    }

    static func claudeEntry(_ line: Data) -> (String, TokenEntry)? {
        guard let value = JSON.parse(line), value["type"].string == "assistant" else { return nil }
        let message = value["message"]
        let usage = message["usage"]
        guard usage.isObject, let id = message["id"].nonEmptyString, message["model"].string != "<synthetic>",
              let at = Dates.parse(value["timestamp"].string)
        else { return nil }
        let counts = TokenCounts(
            input: usage["input_tokens"].int ?? 0, output: usage["output_tokens"].int ?? 0,
            cacheWrite: usage["cache_creation_input_tokens"].int ?? 0, cacheRead: usage["cache_read_input_tokens"].int ?? 0)
        guard counts.total > 0 else { return nil }
        let key = "claude:\(id):\(value["requestId"].string ?? "")"
        return (key, TokenEntry(agent: .claude, model: message["model"].nonEmptyString ?? "claude", at: at, counts: counts))
    }

    private func readCodex(_ url: URL, into record: inout FileRecord) {
        let (lines, end) = lines(url, from: 0)
        var model = "codex"
        var thread = url.deletingPathExtension().lastPathComponent
        var records: [String: TokenEntry] = [:]
        var fallback: [String: TokenEntry] = [:]
        var previousTotal: TokenCounts?
        for line in lines where line.range(of: Self.tokenMarker) != nil || line.range(of: Self.turnContextMarker) != nil
            || line.range(of: Self.sessionMetaMarker) != nil {
            guard let value = JSON.parse(line) else { continue }
            let payload = value["payload"]
            switch value["type"].string {
            case "session_meta":
                thread = payload["id"].nonEmptyString ?? thread
            case "turn_context":
                model = payload["model"].nonEmptyString ?? model
            case "token_usage_record":
                guard let response = payload["response_id"].nonEmptyString, let at = Dates.parse(value["timestamp"].string),
                      let counts = Self.codexCounts(payload["usage"]), counts.total > 0
                else { continue }
                records["codex:\(response)"] = TokenEntry(agent: .codex, model: model, at: at, counts: counts)
            case "event_msg" where payload["type"].string == "token_count":
                guard let at = Dates.parse(value["timestamp"].string),
                      let total = Self.codexCounts(payload["info"]["total_token_usage"])
                else { continue }
                let before = previousTotal ?? TokenCounts()
                previousTotal = total
                let delta = TokenCounts(
                    input: max(total.input - before.input, 0), output: max(total.output - before.output, 0),
                    cacheWrite: max(total.cacheWrite - before.cacheWrite, 0), cacheRead: max(total.cacheRead - before.cacheRead, 0))
                if delta.total > 0 {
                    fallback["codex:\(thread):\(Int(at.timeIntervalSince1970 * 1000))"] =
                        TokenEntry(agent: .codex, model: model, at: at, counts: delta)
                }
            default:
                break
            }
        }
        // A log with usage records counts those; token_count repeats the same use.
        record.entries = records.isEmpty ? fallback : records
        record.offset = end
    }

    /// OpenAI counts cached input inside input_tokens; split it out.
    static func codexCounts(_ usage: JSON) -> TokenCounts? {
        guard usage.isObject else { return nil }
        let input = usage["input_tokens"].int ?? 0
        let cached = usage["cached_input_tokens"].int ?? 0
        let written = usage["cache_write_input_tokens"].int ?? 0
        return TokenCounts(
            input: max(input - cached - written, 0), output: usage["output_tokens"].int ?? 0,
            cacheWrite: written, cacheRead: cached)
    }

    private func readCopilot(_ url: URL, into record: inout FileRecord) {
        let (lines, end) = lines(url, from: 0)
        let session = url.deletingLastPathComponent().lastPathComponent
        for line in lines where line.range(of: Self.shutdownMarker) != nil {
            guard let value = JSON.parse(line), value["type"].string == "session.shutdown",
                  let at = Dates.parse(value["timestamp"].string),
                  let metrics = value["data"]["modelMetrics"].object
            else { continue }
            // Each shutdown carries the session's totals so far; the last one wins.
            for (model, metric) in metrics {
                let usage = metric["usage"]
                let read = usage["cacheReadTokens"].int ?? 0
                let written = usage["cacheWriteTokens"].int ?? 0
                let counts = TokenCounts(
                    input: max((usage["inputTokens"].int ?? 0) - read - written, 0), output: usage["outputTokens"].int ?? 0,
                    cacheWrite: written, cacheRead: read)
                if counts.total > 0 {
                    record.entries["copilot:\(session):\(model)"] = TokenEntry(agent: .copilot, model: model, at: at, counts: counts)
                }
            }
        }
        record.offset = end
    }
}

// MARK: - Statistics

public enum StatsPeriod: String, CaseIterable, Identifiable, Sendable {
    case day
    case week
    case month

    public var id: String { rawValue }
}

/// One column of the chart: an hour of today, or a day.
public struct StatsBar: Identifiable, Equatable, Sendable {
    public var start: Date
    public var byAgent: [Agent: Int]

    public var id: Date { start }
    public var total: Int { byAgent.values.reduce(0, +) }
}

public struct ModelUsage: Identifiable, Equatable, Sendable {
    public var agent: Agent
    public var model: String
    public var counts: TokenCounts

    public var id: String { "\(agent.rawValue):\(model)" }
}

public struct StatsSummary: Equatable, Sendable {
    public var period: StatsPeriod
    public var start: Date
    public var end: Date
    public var total: TokenCounts
    public var byAgent: [Agent: TokenCounts]
    /// By where the tokens were used: "" for this Mac, else the server.
    public var bySource: [String: TokenCounts]
    public var models: [ModelUsage]
    public var bars: [StatsBar]
    /// Calendar days the period covers, for a per-day average.
    public var days: Int
}

public enum TokenStatistics {
    /// Today by the hour, or the last 7 or 30 days (today included) by the day.
    public static func summary(
        _ entries: [TokenEntry], period: StatsPeriod, now: Date, calendar: Calendar = .current
    ) -> StatsSummary {
        let today = calendar.startOfDay(for: now)
        let days: Int
        let starts: [Date]
        switch period {
        case .day:
            days = 1
            starts = (0..<24).compactMap { calendar.date(byAdding: .hour, value: $0, to: today) }
        case .week, .month:
            days = period == .week ? 7 : 30
            starts = (0..<days).compactMap { calendar.date(byAdding: .day, value: $0 - (days - 1), to: today) }
        }
        let start = starts.first ?? today
        var bars = starts.map { StatsBar(start: $0, byAgent: [:]) }
        var total = TokenCounts()
        var byAgent: [Agent: TokenCounts] = [:]
        var bySource: [String: TokenCounts] = [:]
        var byModel: [String: ModelUsage] = [:]
        for entry in entries where entry.at >= start && entry.at <= now {
            total += entry.counts
            byAgent[entry.agent, default: TokenCounts()] += entry.counts
            bySource[entry.source ?? "", default: TokenCounts()] += entry.counts
            let key = "\(entry.agent.rawValue):\(entry.model)"
            byModel[key, default: ModelUsage(agent: entry.agent, model: entry.model, counts: TokenCounts())].counts += entry.counts
            // The last bar starting at or before the entry holds it.
            var low = 0
            var high = starts.count - 1
            while low < high {
                let middle = (low + high + 1) / 2
                if starts[middle] <= entry.at { low = middle } else { high = middle - 1 }
            }
            bars[low].byAgent[entry.agent, default: 0] += entry.counts.total
        }
        let models = byModel.values.sorted { $0.counts.total > $1.counts.total }
        return StatsSummary(
            period: period, start: start, end: now, total: total, byAgent: byAgent, bySource: bySource,
            models: models, bars: bars, days: days)
    }

    /// "950", "12.4K", "3.2M", "1.1B".
    public static func compact(_ value: Int) -> String {
        let number = Double(value)
        func trimmed(_ scaled: Double, _ suffix: String) -> String {
            let text = scaled >= 100 ? String(format: "%.0f", scaled) : String(format: "%.1f", scaled)
            return (text.hasSuffix(".0") ? String(text.dropLast(2)) : text) + suffix
        }
        switch number {
        case 1_000_000_000...: return trimmed(number / 1_000_000_000, "B")
        case 1_000_000...: return trimmed(number / 1_000_000, "M")
        case 1_000...: return trimmed(number / 1_000, "K")
        default: return "\(value)"
        }
    }
}
