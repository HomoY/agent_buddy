import Foundation

/// A session in the middle of a turn: an agent at work.
public struct WorkingSession: Identifiable, Equatable, Sendable {
    public var agent: Agent
    /// The server it works on; nil on this Mac.
    public var source: String?
    public var sessionID: String
    public var name: String?
    public var folder: String?
    /// What it's working on: the start of the prompt its turn answers.
    public var task: String?
    /// When the turn began, and the latest work in it.
    public var since: Date
    public var lastWork: Date

    public init(
        agent: Agent, source: String?, sessionID: String, name: String?, folder: String?, task: String? = nil,
        since: Date, lastWork: Date
    ) {
        self.agent = agent
        self.source = source
        self.sessionID = sessionID
        self.name = name
        self.folder = folder
        self.task = task
        self.since = since
        self.lastWork = lastWork
    }

    /// What it's on: the prompt it's answering, else the session's name.
    public var work: String? { task ?? name }

    /// Its agent window's key, as `JobWindow.key`.
    public var id: String { "\(agent.rawValue)|\(source ?? "")|\(sessionID)" }

    /// "Claude Code · head_show · on gpu".
    public var label: String {
        var parts = [agent.clientName]
        if let folder, !folder.isEmpty {
            parts.append(URL(fileURLWithPath: folder).lastPathComponent)
        }
        if let source {
            parts.append("on \(source)")
        }
        return parts.joined(separator: " · ")
    }
}

/// Which sessions in a turn still count as working: a turn that was cut off
/// (the agent quit or crashed mid-turn) never logs its end.
public enum WorkingRule {
    /// Quiet this long, a turn counts as over…
    public static let quiet: TimeInterval = 20 * 60
    /// …unless the agent's process is still running there (a long build or test
    /// writes nothing until it's done), up to this long.
    public static let quietWithProcess: TimeInterval = 3 * 3600

    /// - Parameter alive: whether a session on this Mac still has its agent's process.
    public static func working(
        _ sessions: [WorkingSession], now: Date, alive: (WorkingSession) -> Bool
    ) -> [WorkingSession] {
        sessions.filter { session in
            let quietFor = now.timeIntervalSince(session.lastWork)
            if quietFor < quiet {
                return true
            }
            return session.source == nil && quietFor < quietWithProcess && alive(session)
        }
        .sorted { ($0.since, $0.id) < ($1.since, $1.id) }
    }
}
