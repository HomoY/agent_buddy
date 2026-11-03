import Foundation

/// Every agent window Agent Buddy has seen finish a job, kept when the finished-jobs
/// list is cleared, so its prompts can still be opened. Newest first; windows
/// quiet for 90 days are let go, and at most 300 are kept.
public struct SessionArchive: Codable, Equatable, Sendable {
    public struct Job: Codable, Equatable, Sendable {
        public var id: String
        public var finishedAt: Date
        public var outcome: JobEvent.Outcome
    }

    public struct Entry: Codable, Equatable, Sendable, Identifiable {
        /// "agent|server|session", as `JobWindow.key`.
        public var key: String
        public var agent: Agent
        /// The server, for a window on one.
        public var source: String?
        public var sessionID: String
        public var title: String?
        public var project: String?
        public var transcriptPath: String?
        /// Its finished jobs, oldest first (the latest 100).
        public var jobs: [Job]

        public var id: String { key }
        public var lastFinished: Date { jobs.last?.finishedAt ?? .distantPast }
        public var lastOutcome: JobEvent.Outcome { jobs.last?.outcome ?? .completed }
    }

    public static let limit = 300
    public static let keepDays: Double = 90
    static let jobsPerWindow = 100

    public private(set) var entries: [Entry] = []

    public init(entries: [Entry] = []) {
        self.entries = entries
    }

    public func entry(_ key: String) -> Entry? {
        entries.first { $0.key == key }
    }

    /// Adds a finished job to its window (the same job again replaces itself).
    /// Whether the job is on record: seen, reminded of, and perhaps cleared since.
    public func contains(_ job: JobEvent) -> Bool {
        entry(JobWindow.key(job))?.jobs.contains { $0.id == job.id } ?? false
    }

    public mutating func record(_ job: JobEvent) {
        let key = JobWindow.key(job)
        var entry = entry(key) ?? Entry(
            key: key, agent: job.agent, source: job.source, sessionID: job.sessionID, title: nil, project: nil,
            transcriptPath: nil, jobs: [])
        let newest = entry.jobs.isEmpty || job.finishedAt >= entry.lastFinished
        if newest || entry.title == nil {
            entry.title = job.title ?? entry.title
        }
        if newest || entry.project == nil {
            entry.project = job.project ?? entry.project
        }
        entry.transcriptPath = job.transcriptPath ?? entry.transcriptPath
        entry.jobs.removeAll { $0.id == job.id }
        entry.jobs.append(Job(id: job.id, finishedAt: job.finishedAt, outcome: job.outcome))
        entry.jobs.sort { $0.finishedAt < $1.finishedAt }
        if entry.jobs.count > Self.jobsPerWindow {
            entry.jobs.removeFirst(entry.jobs.count - Self.jobsPerWindow)
        }
        entries.removeAll { $0.key == key }
        entries.append(entry)
        entries.sort { $0.lastFinished > $1.lastFinished }
    }

    public mutating func remove(_ key: String) {
        entries.removeAll { $0.key == key }
    }

    /// Fills in what a window's entry lacks, from its session log once read.
    /// Returns whether anything changed.
    @discardableResult
    public mutating func learn(_ key: String, title: String?, project: String?, path: String?) -> Bool {
        guard let index = entries.firstIndex(where: { $0.key == key }) else { return false }
        let before = entries[index]
        entries[index].title = entries[index].title ?? title
        entries[index].project = entries[index].project ?? project
        entries[index].transcriptPath = entries[index].transcriptPath ?? path
        return entries[index] != before
    }

    /// Lets go of windows quiet for `keepDays`, and the oldest past `limit`.
    public mutating func prune(now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-Self.keepDays * 86400)
        entries.removeAll { $0.lastFinished < cutoff }
        if entries.count > Self.limit {
            entries.removeLast(entries.count - Self.limit)
        }
    }

    /// The windows by day: "Today", "Yesterday", then the date.
    public func byDay(now: Date = Date(), calendar: Calendar = .current) -> [(day: Date, entries: [Entry])] {
        var days: [(day: Date, entries: [Entry])] = []
        for entry in entries {
            let day = calendar.startOfDay(for: entry.lastFinished)
            if days.last?.day == day {
                days[days.count - 1].entries.append(entry)
            } else {
                days.append((day, [entry]))
            }
        }
        return days
    }
}

/// Finished jobs read back from Agent Buddy's own log, for the windows that
/// finished before the archive kept them.
public struct LogImport {
    /// Where the log saw a session opened.
    public enum Place: Equatable, Sendable {
        case here
        case server(String)
    }

    /// From lines "… job claude:<session>:<key> completed; …", each at its
    /// line's time; a job on a server has it as its source.
    public private(set) var jobs: [JobEvent] = []
    /// By "agent:session", from "… open claude <file> on <server>" (a server)
    /// and "… open claude <file> size …" (this Mac).
    public private(set) var places: [String: Place] = [:]

    public init(log text: String, timeZone: TimeZone = .current) {
        let clock = DateFormatter()
        clock.locale = Locale(identifier: "en_US_POSIX")
        clock.timeZone = timeZone
        clock.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        for line in text.split(separator: "\n") where line.count > 24 {
            guard let at = clock.date(from: String(line.prefix(23))) else { continue }
            let words = line.dropFirst(24).split(separator: " ").map(String.init)
            if words.first == "open", words.count >= 4, let agent = Agent(rawValue: words[1]),
               let session = Self.sessionID(agent, file: words[2]) {
                if words.count >= 5, words[words.count - 2] == "on" {
                    places["\(agent.rawValue):\(session)"] = .server(words[words.count - 1])
                } else if words[3] == "size" {
                    places["\(agent.rawValue):\(session)"] = .here
                }
            } else if words.first == "job", words.count >= 3 {
                let parts = words[1].split(separator: ":", maxSplits: 2).map(String.init)
                guard parts.count == 3, let agent = Agent(rawValue: parts[0]),
                      let outcome = JobEvent.Outcome(rawValue: words[2].trimmingCharacters(in: CharacterSet(charactersIn: ";")))
                else { continue }
                var source: String?
                if case .server(let host)? = places["\(agent.rawValue):\(parts[1])"] {
                    source = host
                }
                jobs.append(JobEvent(
                    id: words[1], agent: agent, outcome: outcome, sessionID: parts[1], finishedAt: at, source: source))
            }
        }
    }

    public func place(_ agent: Agent, _ session: String) -> Place? {
        places["\(agent.rawValue):\(session)"]
    }

    /// The session a log file is for: Claude Code's file name, Codex's thread at
    /// the end of it. Copilot's files are all "events.jsonl", so nil.
    static func sessionID(_ agent: Agent, file: String) -> String? {
        let name = URL(fileURLWithPath: file).deletingPathExtension().lastPathComponent
        switch agent {
        case .claude: return name.isEmpty ? nil : name
        case .codex: return name.count >= 36 ? String(name.suffix(36)) : nil
        default: return nil
        }
    }
}
