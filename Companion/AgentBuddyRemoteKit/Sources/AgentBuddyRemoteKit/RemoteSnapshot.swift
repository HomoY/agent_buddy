import Foundation

/// What Agent Buddy on the Mac publishes for the phone and the watch: plan usage,
/// finished jobs folded by agent window, and token totals. Times are kept to the
/// whole second, as JSON carries them exactly that way.
public struct RemoteSnapshot: Codable, Equatable, Sendable {
    /// `date`, without the fraction of a second.
    public static func second(_ date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }

    /// One limit, such as Claude's current session or its week.
    public struct Limit: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        /// "Current session", "Weekly · All models", "Premium requests".
        public var title: String
        /// "5h", "Week", "Opus", "Month": for Apple Watch.
        public var short: String
        /// Percent used, 0–100.
        public var percent: Double
        public var resetsAt: Date?
        /// Shown in the Mac's menu bar (Claude: the session, then the week).
        public var main: Bool

        public init(id: String, title: String, short: String, percent: Double, resetsAt: Date?, main: Bool) {
            self.id = id
            self.title = title
            self.short = short
            self.percent = percent
            self.resetsAt = resetsAt.map(RemoteSnapshot.second)
            self.main = main
        }

        /// The share used at `now`: a limit whose reset time has passed starts again from zero.
        public func percent(at now: Date) -> Double {
            if let resetsAt, resetsAt <= now {
                return 0
            }
            return min(max(percent, 0), 100)
        }
    }

    public struct AgentUsage: Codable, Equatable, Sendable, Identifiable {
        /// "claude", "codex" or "copilot".
        public var agent: String
        /// "Claude", "ChatGPT", "Copilot".
        public var name: String
        public var plan: String?
        public var limits: [Limit]
        /// Why the Mac couldn't read the limits, if it couldn't.
        public var problem: String?

        public var id: String { agent }

        public init(agent: String, name: String, plan: String?, limits: [Limit], problem: String? = nil) {
            self.agent = agent
            self.name = name
            self.plan = plan
            self.limits = limits
            self.problem = problem
        }

        /// What Apple Watch shows: the menu bar's limits, else the first one.
        public var mainLimits: [Limit] {
            let main = limits.filter(\.main)
            return main.isEmpty ? Array(limits.prefix(1)) : Array(main.prefix(2))
        }
    }

    /// One agent window with finished jobs, as its latest reminder put it.
    public struct FinishedWindow: Codable, Equatable, Sendable, Identifiable {
        /// "hsw-…": the tag every reminder of this window carries.
        public var id: String
        /// "claude", "codex" or "copilot".
        public var agent: String
        /// "Claude Code job finished", "Codex · 3 jobs finished".
        public var headline: String
        /// The reminder's text, with the Mac's privacy choices applied.
        public var detail: String
        public var count: Int
        /// "completed", "failed" or "limited".
        public var outcome: String
        public var finishedAt: Date

        public init(
            id: String, agent: String, headline: String, detail: String, count: Int, outcome: String, finishedAt: Date
        ) {
            self.id = id
            self.agent = agent
            self.headline = headline
            self.detail = detail
            self.count = count
            self.outcome = outcome
            self.finishedAt = RemoteSnapshot.second(finishedAt)
        }
    }

    public struct Tokens: Codable, Equatable, Sendable {
        public var today: Int
        public var week: Int
        public var month: Int

        public init(today: Int, week: Int, month: Int) {
            self.today = today
            self.week = week
            self.month = month
        }
    }

    public var version: Int
    public var at: Date
    /// The Mac's name, as in its Sharing settings.
    public var mac: String
    public var agents: [AgentUsage]
    /// Newest first. May hold fewer than `windowCount`, to fit one message.
    public var windows: [FinishedWindow]
    /// How many agent windows have finished jobs on the Mac.
    public var windowCount: Int
    /// Tokens used on the Mac and its servers: today, the last 7 and 30 days.
    public var tokens: Tokens?

    public init(at: Date, mac: String, agents: [AgentUsage], windows: [FinishedWindow], windowCount: Int? = nil, tokens: Tokens?) {
        version = 1
        self.at = Self.second(at)
        self.mac = mac
        self.agents = agents
        self.windows = windows
        self.windowCount = windowCount ?? windows.count
        self.tokens = tokens
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    public func encoded() -> Data {
        (try? Self.makeEncoder().encode(self)) ?? Data()
    }

    public static func decode(_ data: Data) -> RemoteSnapshot? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let snapshot = try? decoder.decode(RemoteSnapshot.self, from: data), snapshot.version == 1 else { return nil }
        return snapshot
    }

    /// The content without its time, to tell whether anything changed.
    public var signature: Data {
        var copy = self
        copy.at = Date(timeIntervalSince1970: 0)
        return copy.encoded()
    }

    /// Encoded within ntfy's 4,096-byte message limit: the oldest windows go
    /// first, then the remaining ones' text gets shorter.
    public func fitted(limit: Int = 3800) -> Data {
        var copy = self
        var data = copy.encoded()
        while data.count > limit, copy.windows.count > 1 {
            copy.windows.removeLast()
            data = copy.encoded()
        }
        if data.count > limit {
            for index in copy.windows.indices {
                copy.windows[index].detail = String(copy.windows[index].detail.prefix(60))
            }
            data = copy.encoded()
        }
        return data
    }
}
