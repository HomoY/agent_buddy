import Foundation

public enum Agent: String, CaseIterable, Codable, Identifiable, Sendable {
    case claude
    case codex
    case copilot
    /// Watched through their session logs alone: their jobs remind, their
    /// sessions open in agent windows and their tokens count, but they have no
    /// plan limits to show.
    // In this order, their chart colours stay apart (checked for colour-vision separation as a set).
    case deepseek
    case gemini
    case opencode
    case qwen
    case cursor

    public var id: String { rawValue }

    /// The agents whose plan limits are shown (the others are watched for jobs only).
    public static let withLimits: [Agent] = [.claude, .codex, .copilot]
    /// The agents watched through their logs alone.
    public static let logOnly: [Agent] = [.deepseek, .gemini, .opencode, .qwen, .cursor]

    public var hasLimits: Bool { Self.withLimits.contains(self) }

    /// The name on cards, in tooltips and in limit reminders.
    public var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "ChatGPT"
        case .copilot: return "Copilot"
        case .gemini: return "Gemini"
        case .qwen: return "Qwen"
        case .opencode: return "OpenCode"
        case .cursor: return "Cursor"
        case .deepseek: return "DeepSeek"
        }
    }

    /// The coding client whose jobs are watched.
    public var clientName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .copilot: return "Copilot"
        case .gemini: return "Gemini CLI"
        case .qwen: return "Qwen Code"
        case .opencode: return "OpenCode"
        case .cursor: return "Cursor Agent"
        case .deepseek: return "DeepSeek Harness"
        }
    }

    /// The small caption above the percentages in the menu bar.
    public var menuLabel: String {
        switch self {
        case .claude: return "CLAUDE"
        case .codex: return "GPT"
        case .copilot: return "COPILOT"
        case .gemini: return "GEMINI"
        case .qwen: return "QWEN"
        case .opencode: return "OPENCODE"
        case .cursor: return "CURSOR"
        case .deepseek: return "DEEPSEEK"
        }
    }
}

/// Green under 70% used, yellow from 70%, red from 90%.
public enum Severity: Sendable {
    case normal
    case warning
    case critical

    public init(percent: Double) {
        if percent >= 90 {
            self = .critical
        } else if percent >= 70 {
            self = .warning
        } else {
            self = .normal
        }
    }
}

/// One quota window, such as Claude's current session or its week.
public struct UsageWindow: Identifiable, Equatable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case session
        case weekly
        case weeklyModel
        case monthly
        case other
    }

    public var id: String
    public var kind: Kind
    public var title: String
    public var usedPercent: Double
    public var resetsAt: Date?
    public var windowSeconds: Double?
    /// Extra words for the card, such as "404 / 1,500 requests".
    public var detail: String?

    public init(
        id: String, kind: Kind, title: String, usedPercent: Double,
        resetsAt: Date? = nil, windowSeconds: Double? = nil, detail: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.windowSeconds = windowSeconds
        self.detail = detail
    }

    public func hasReset(at now: Date) -> Bool {
        resetsAt.map { $0 <= now } ?? false
    }

    /// The share used now: a window whose reset time has passed starts again from zero.
    public func percent(at now: Date) -> Double {
        hasReset(at: now) ? 0 : min(max(usedPercent, 0), 100)
    }
}

/// What one read of an agent's plan returned.
public struct AgentReading: Equatable, Codable, Sendable {
    public var agent: Agent
    public var windows: [UsageWindow]
    public var plan: String?
    public var account: String?
    /// Short remarks for the card, such as free resets or why no limits show.
    public var notes: [String]
    public var fetchedAt: Date

    public init(
        agent: Agent, windows: [UsageWindow] = [], plan: String? = nil,
        account: String? = nil, notes: [String] = [], fetchedAt: Date = Date()
    ) {
        self.agent = agent
        self.windows = windows
        self.plan = plan
        self.account = account
        self.notes = notes
        self.fetchedAt = fetchedAt
    }

    /// What the menu bar shows: Claude's 5-hour session (on plans with one), its
    /// week, then each model's week; Codex's own bucket; Copilot's premium requests.
    public var menuWindows: [UsageWindow] {
        switch agent {
        case .claude:
            return [windows.first { $0.kind == .session }, windows.first { $0.kind == .weekly }].compactMap { $0 }
                + windows.filter { $0.kind == .weeklyModel }
        case .codex:
            let main = windows.filter { $0.id.hasPrefix("codex.codex.") }
            return main.isEmpty ? Array(windows.prefix(1)) : Array(main.prefix(2))
        default:
            return Array(windows.prefix(1))
        }
    }

    /// The menu bar's numbers for this agent, in order. Claude's 5-hour session
    /// first ("5h"), on plans that have one, then its week ("wk"), "–" holding
    /// the week's place if it wasn't reported, then each model's week, by its
    /// name ("Fable").
    public func menuValues(at now: Date) -> [MenuValue] {
        func value(_ window: UsageWindow?, tag: String?) -> MenuValue {
            guard let window else { return MenuValue(tag: tag, text: "–", severity: nil) }
            let percent = window.percent(at: now)
            return MenuValue(tag: tag, text: "\(Int(percent.rounded()))%", severity: Severity(percent: percent))
        }
        let shown = menuWindows
        if shown.isEmpty {
            return [MenuValue(tag: nil, text: "–", severity: nil)]
        }
        switch agent {
        case .claude:
            let session = windows.first { $0.kind == .session }
            let models = windows.filter { $0.kind == .weeklyModel }.map { window in
                value(window, tag: window.title.components(separatedBy: " \u{00B7} ").last ?? window.title)
            }
            return (session.map { [value($0, tag: "5h")] } ?? []) + [value(windows.first { $0.kind == .weekly }, tag: "wk")] + models
        default:
            guard shown.count > 1 else { return [value(shown[0], tag: nil)] }
            return shown.map { window in
                value(window, tag: window.kind == .session ? "5h" : (window.kind == .weekly ? "wk" : nil))
            }
        }
    }
}

/// One number in the menu bar, with a small tag naming its window.
public struct MenuValue: Equatable, Sendable {
    public var tag: String?
    public var text: String
    public var severity: Severity?

    public init(tag: String?, text: String, severity: Severity?) {
        self.tag = tag
        self.text = text
        self.severity = severity
    }
}

/// A finished turn of an agent: the "job finished" reminder.
public struct JobEvent: Identifiable, Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable {
        case completed
        case failed
        case limited
    }

    public var id: String
    public var agent: Agent
    public var outcome: Outcome
    public var sessionID: String
    public var title: String?
    public var project: String?
    public var summary: String?
    public var startedAt: Date?
    public var finishedAt: Date
    public var transcriptPath: String?
    /// The server the job ran on; nil for this Mac.
    public var source: String?

    public init(
        id: String, agent: Agent, outcome: Outcome, sessionID: String, title: String? = nil,
        project: String? = nil, summary: String? = nil, startedAt: Date? = nil,
        finishedAt: Date, transcriptPath: String? = nil, source: String? = nil
    ) {
        self.source = source
        self.id = id
        self.agent = agent
        self.outcome = outcome
        self.sessionID = sessionID
        self.title = title
        self.project = project
        self.summary = summary
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.transcriptPath = transcriptPath
    }

    public var duration: TimeInterval? {
        guard let startedAt else { return nil }
        let seconds = finishedAt.timeIntervalSince(startedAt)
        return seconds >= 0 ? seconds : nil
    }
}

/// The finished jobs of one agent window (a session: its terminal, editor tab or
/// app window), newest first. Reminders and the badge count windows, not jobs.
public struct JobWindow: Identifiable, Equatable, Sendable {
    public var key: String
    public var jobs: [JobEvent]

    public init(key: String, jobs: [JobEvent]) {
        self.key = key
        self.jobs = jobs
    }

    public var id: String { key }
    public var latest: JobEvent { jobs[0] }
    public var count: Int { jobs.count }

    public static func key(_ job: JobEvent) -> String {
        "\(job.agent.rawValue)|\(job.source ?? "")|\(job.sessionID)"
    }

    /// Jobs folded by window, the window with the newest job first.
    public static func fold(_ jobs: [JobEvent]) -> [JobWindow] {
        var order: [String] = []
        var groups: [String: [JobEvent]] = [:]
        for job in jobs.sorted(by: { $0.finishedAt > $1.finishedAt }) {
            let key = key(job)
            if groups[key] == nil {
                order.append(key)
            }
            groups[key, default: []].append(job)
        }
        return order.compactMap { key in groups[key].map { JobWindow(key: key, jobs: $0) } }
    }
}

public struct ReadError: LocalizedError, Sendable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

enum TextTools {
    /// One line of plain words: markdown markers dropped, whitespace collapsed,
    /// cut at `limit` characters.
    static func condensed(_ text: String?, limit: Int = 160) -> String? {
        guard var text else { return nil }
        text = text.replacingOccurrences(of: "```", with: " ")
        for marker in ["**", "__", "`"] {
            text = text.replacingOccurrences(of: marker, with: "")
        }
        let words = text.split(whereSeparator: { $0.isWhitespace }).filter { !$0.allSatisfy { $0 == "#" } }
        var line = words.joined(separator: " ")
        guard !line.isEmpty else { return nil }
        if line.count > limit {
            line = String(line.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
        }
        return line
    }

    /// The last path component of a working folder.
    static func project(_ folder: String?) -> String? {
        guard let folder, !folder.isEmpty else { return nil }
        let name = URL(fileURLWithPath: folder).lastPathComponent
        return name.isEmpty || name == "/" ? nil : name
    }

    static func capitalized(_ word: String) -> String {
        word.prefix(1).uppercased() + word.dropFirst()
    }
}
