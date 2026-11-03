import CoreServices
import Foundation

/// Watches the agents read through their logs alone (Gemini CLI, Qwen Code,
/// OpenCode, Cursor's agent, DeepSeek Harness): a session is read whole when it
/// changes, and its turns compared with the last read. A turn that has just
/// ended reminds; one under way counts as working.
public final class AgentLogWatcher {
    public var onJob: ((JobEvent) -> Void)?
    /// A session started or stopped working.
    public var onWorkingChange: (() -> Void)?
    public var debugLog: ((String) -> Void)?
    /// How long a session's changes settle before it's read again.
    public var debounce: TimeInterval = 1.5
    /// Off only in checks: a turn that ended before watching began reminds too.
    public var requireFreshEvents = true

    private struct Known {
        var agent: Agent
        var history: SessionHistory
        /// The session's latest work (its log's last change).
        var lastWork: Date
    }

    private let roots: AgentLogRoots
    private let queue = DispatchQueue(label: "AgentBuddy.AgentLogWatcher")
    private var stream: FSEventStreamRef?
    private var watching: [String] = []
    private var known: [String: Known] = [:]
    private var pending: [String: Int] = [:]
    private var emitted = Set<String>()
    private var openCodeCheckedAt: Date
    private var timer: DispatchSourceTimer?
    private let startedAt = Date()

    public init(roots: AgentLogRoots = .standard()) {
        self.roots = roots
        openCodeCheckedAt = Date()
    }

    deinit {
        stopStream()
    }

    public func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.watchFolders()
            self.catchUp()
            // An agent installed later makes its folder later: looked for each minute.
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 60, repeating: 60, leeway: .seconds(10))
            timer.setEventHandler { [weak self] in self?.watchFolders() }
            timer.resume()
            self.timer = timer
        }
    }

    public func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
            stopStream()
        }
    }

    /// The sessions with a turn under way, and when their logs last changed.
    public func workingSessions(_ reply: @escaping ([WorkingSession]) -> Void) {
        queue.async {
            reply(self.known.values.compactMap { session -> WorkingSession? in
                guard !session.history.isSubagent, let turn = session.history.turns.last, turn.outcome == .running else { return nil }
                return WorkingSession(
                    agent: session.agent, source: nil, sessionID: session.history.sessionID, name: session.history.title,
                    folder: session.history.cwd, task: TextTools.condensed(turn.text, limit: 80), since: turn.askedAt,
                    lastWork: max(session.lastWork, turn.askedAt))
            })
        }
    }

    /// Reads a session now (for the checks), as a change to it would.
    public func check(_ path: String, agent: Agent, modified: Date = Date()) {
        queue.sync { process(agent, path, modified: modified) }
    }

    // MARK: - Watching

    /// The logs written lately: their turns under way count as working; their
    /// ended turns remind no one (they ended before watching began).
    private func catchUp() {
        for session in AgentLogs.sessions(since: Date().addingTimeInterval(-WorkingRule.quiet), roots: roots) {
            process(session.agent, session.path, modified: session.modified)
        }
    }

    private func watchFolders() {
        let present = roots.folders.map(TranscriptWatcher.Roots.canonical).map(\.path).filter { FileManager.default.fileExists(atPath: $0) }
        guard present != watching else { return }
        stopStream()
        watching = present
        guard !present.isEmpty else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<AgentLogWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            watcher.changed(Array(list.prefix(count)))
        }
        guard let stream = FSEventStreamCreate(
            nil, callback, &context, present as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer))
        else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
        debugLog?("agent logs: watching \(present.count) folders")
    }

    private func stopStream() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    /// Which session each changed file is (OpenCode's: the sessions its database changed).
    private func changed(_ paths: [String]) {
        var openCode = false
        for path in paths {
            let url = URL(fileURLWithPath: path)
            let gemini = TranscriptWatcher.Roots.canonical(roots.gemini).path
            let qwen = TranscriptWatcher.Roots.canonical(roots.qwen).path
            if url.lastPathComponent.hasPrefix(roots.openCode.lastPathComponent) {
                openCode = true
            } else if path.hasPrefix(gemini + "/"), AgentLogs.isChat(url) {
                schedule(.gemini, path)
            } else if path.hasPrefix(qwen + "/"), AgentLogs.isChat(url) {
                schedule(.qwen, path)
            } else if url.lastPathComponent.hasPrefix("store.db") {
                schedule(.cursor, url.deletingLastPathComponent().appendingPathComponent("store.db").path)
            } else if AgentLogs.harnessVersion(url) != nil {
                schedule(.deepseek, path)
            }
        }
        if openCode {
            let since = openCodeCheckedAt.addingTimeInterval(-2)
            openCodeCheckedAt = Date()
            for session in AgentLogs.openCodeSessions(since: since, database: roots.openCode) {
                schedule(.opencode, session.path)
            }
        }
    }

    private func schedule(_ agent: Agent, _ path: String) {
        let token = (pending[path] ?? 0) + 1
        pending[path] = token
        queue.asyncAfter(deadline: .now() + debounce) { [weak self] in
            guard let self, self.pending[path] == token else { return }
            self.pending[path] = nil
            self.process(agent, path, modified: Date())
        }
    }

    // MARK: - Reading

    private func process(_ agent: Agent, _ path: String, modified: Date) {
        guard case .success(let session) = AgentLogs.read(agent: agent, path: path) else { return }
        let history = session.history
        let before = known[path]
        known[path] = Known(agent: agent, history: history, lastWork: modified)
        let wasWorking = before?.history.turns.last?.outcome == .running
        let isWorking = history.turns.last?.outcome == .running
        if wasWorking != isWorking {
            onWorkingChange?()
        }
        guard !history.isSubagent else { return }
        let ended = Dictionary(before?.history.turns.map { ($0.id, $0.endedAt != nil) } ?? [], uniquingKeysWith: { first, _ in first })
        for turn in history.turns {
            guard let endedAt = turn.endedAt, ended[turn.id] != true else { continue }
            let outcome: JobEvent.Outcome
            switch turn.outcome {
            case .completed: outcome = .completed
            case .failed: outcome = .failed
            case .limited: outcome = .limited
            default: continue  // Stopped by you, or not ended: no reminder.
            }
            // Only what ended since watching began, lately.
            if requireFreshEvents, endedAt < startedAt.addingTimeInterval(-2) || Date().timeIntervalSince(endedAt) > 300 {
                continue
            }
            let id = "\(agent.rawValue):\(history.sessionID):\(turn.id)"
            guard emitted.insert(id).inserted else { continue }
            debugLog?("agent logs: \(agent.rawValue) \(history.sessionID) finished a job")
            onJob?(JobEvent(
                id: id, agent: agent, outcome: outcome, sessionID: history.sessionID, title: history.title,
                project: history.cwd.map { URL(fileURLWithPath: $0).lastPathComponent }, summary: turn.answer.flatMap { TextTools.condensed($0, limit: 220) },
                startedAt: turn.askedAt, finishedAt: endedAt, transcriptPath: path))
        }
    }
}
