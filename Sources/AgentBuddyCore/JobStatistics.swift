import Foundation

/// One job, a prompt and the agent's work on it, with the tokens each model
/// used. For Copilot, which reports tokens per session, the whole session.
public struct JobTokens: Identifiable, Equatable, Sendable {
    /// The window's key and the prompt's id.
    public var id: String
    public var windowKey: String
    /// Nil for a whole session.
    public var turnID: String?
    public var agent: Agent
    /// The server, for a job on one.
    public var source: String?
    /// The window's name and folder.
    public var title: String?
    public var project: String?
    /// The prompt's first line.
    public var prompt: String
    /// When it ended, or was asked if it's still going.
    public var at: Date
    public var outcome: PromptTurn.Outcome?
    public var usage: [ModelTokens]

    public var tokens: TokenCounts { usage.reduce(TokenCounts()) { $0 + $1.counts } }
    public var wholeSession: Bool { turnID == nil }
}

/// A session's history, for the job list.
public struct UsageSession: Sendable {
    public var key: String
    public var source: String?
    public var history: SessionHistory

    public init(key: String, source: String?, history: SessionHistory) {
        self.key = key
        self.source = source
        self.history = history
    }
}

public enum JobStatistics {
    /// The jobs that ended (or, still going, were asked) between `start` and
    /// `end`, newest first. Codex sub-agents' threads are left out: their tokens
    /// are in the job that started them.
    public static func jobs(_ sessions: [UsageSession], from start: Date, to end: Date) -> [JobTokens] {
        var jobs: [JobTokens] = []
        for session in sessions where !session.history.isSubagent {
            let history = session.history
            let project = history.cwd.map { URL(fileURLWithPath: $0).lastPathComponent }
            let perJob = history.turns.contains { !$0.usage.isEmpty }
            if perJob {
                for turn in history.turns where !turn.usage.isEmpty {
                    let at = turn.endedAt ?? turn.askedAt
                    guard at >= start, at <= end else { continue }
                    jobs.append(JobTokens(
                        id: "\(session.key)#\(turn.id)", windowKey: session.key, turnID: turn.id, agent: history.agent,
                        source: session.source, title: history.title, project: project, prompt: firstLine(turn.text),
                        at: at, outcome: turn.outcome, usage: turn.usage))
                }
            } else if !history.sessionUsage.isEmpty, let at = history.sessionEndedAt, at >= start, at <= end {
                jobs.append(JobTokens(
                    id: "\(session.key)#session", windowKey: session.key, turnID: nil, agent: history.agent,
                    source: session.source, title: history.title, project: project,
                    prompt: history.title ?? history.turns.last.map { firstLine($0.text) } ?? "Whole session",
                    at: at, outcome: nil, usage: history.sessionUsage))
            }
        }
        return jobs.sorted { ($0.at, $0.id) > ($1.at, $1.id) }
    }

    static func firstLine(_ text: String) -> String {
        String((text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text).prefix(200))
    }
}

extension StatsPeriod {
    /// Where the period starts: midnight today, or 6 or 29 days before it, as the totals count.
    public func start(now: Date, calendar: Calendar = .current) -> Date {
        let today = calendar.startOfDay(for: now)
        switch self {
        case .day: return today
        case .week: return calendar.date(byAdding: .day, value: -6, to: today) ?? today
        case .month: return calendar.date(byAdding: .day, value: -29, to: today) ?? today
        }
    }
}

extension SessionHistoryReader {
    /// The session logs on this Mac written to since `since`: Claude Code's
    /// sessions (not its sub-agents' logs), Codex's rollouts and Copilot's sessions.
    public static func recentLogs(since: Date, roots: TranscriptWatcher.Roots = .standard())
        -> [(agent: Agent, path: String, size: UInt64, modified: Date)] {
        let files = FileManager.default
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        var found: [(agent: Agent, path: String, size: UInt64, modified: Date)] = []
        func consider(_ url: URL, _ agent: Agent) {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                  let modified = values.contentModificationDate, modified >= since
            else { return }
            found.append((agent, url.path, UInt64(values.fileSize ?? 0), modified))
        }
        for project in (try? files.contentsOfDirectory(at: roots.claudeProjects, includingPropertiesForKeys: nil)) ?? [] {
            for file in (try? files.contentsOfDirectory(at: project, includingPropertiesForKeys: keys)) ?? []
            where file.pathExtension == "jsonl" {
                consider(file, .claude)
            }
        }
        if let walker = files.enumerator(at: roots.codexSessions, includingPropertiesForKeys: keys) {
            for case let file as URL in walker where file.lastPathComponent.hasPrefix("rollout-") && file.pathExtension == "jsonl" {
                consider(file, .codex)
            }
        }
        for session in (try? files.contentsOfDirectory(at: roots.copilotSessions, includingPropertiesForKeys: nil)) ?? [] {
            consider(session.appendingPathComponent("events.jsonl"), .copilot)
        }
        // The agents watched through their logs alone (OpenCode's sessions are rows of one database).
        for session in AgentLogs.sessions(since: since) {
            let size = (try? files.attributesOfItem(atPath: session.path))?[.size] as? UInt64 ?? 0
            found.append((session.agent, session.path, size, session.modified))
        }
        return found
    }
}
