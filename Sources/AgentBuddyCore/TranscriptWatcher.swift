import CoreServices
import Foundation

/// Watches the agents' session logs with FSEvents and reports finished turns.
/// Only bytes written after a file is first seen can remind; older lines just
/// give the tracker its context (title, folder, whether a turn is running).
public final class TranscriptWatcher {
    public struct Roots {
        public var claudeProjects: URL
        public var codexSessions: URL
        public var codexIndex: URL?
        public var copilotSessions: URL

        public init(claudeProjects: URL, codexSessions: URL, codexIndex: URL?, copilotSessions: URL) {
            self.claudeProjects = Self.canonical(claudeProjects)
            self.codexSessions = Self.canonical(codexSessions)
            self.codexIndex = codexIndex
            self.copilotSessions = Self.canonical(copilotSessions)
        }

        /// The path as FSEvents reports it: symbolic links resolved, `/private`
        /// kept (unlike `resolvingSymlinksInPath`). A missing folder is resolved
        /// through its parent.
        static func canonical(_ url: URL) -> URL {
            if let resolved = realpath(url.path, nil) {
                defer { free(resolved) }
                return URL(fileURLWithPath: String(cString: resolved))
            }
            let parent = url.deletingLastPathComponent()
            guard parent.path != url.path, parent.path != "/" else { return url.standardizedFileURL }
            return canonical(parent).appendingPathComponent(url.lastPathComponent)
        }

        public static func standard() -> Roots {
            Roots(
                claudeProjects: Environment.claudeConfigDir.appendingPathComponent("projects"),
                codexSessions: Environment.codexHome.appendingPathComponent("sessions"),
                codexIndex: Environment.codexHome.appendingPathComponent("session_index.jsonl"),
                copilotSessions: Environment.copilotHome.appendingPathComponent("session-state"))
        }
    }

    public var onJob: ((JobEvent) -> Void)?
    /// A job that finished in the minutes before its log was first read (Agent
    /// Buddy wasn't running, or a server's connection was down): not fresh, but
    /// not to be lost, for whoever remembers which jobs it has seen already.
    public var onMissed: ((JobEvent) -> Void)?
    /// How long before its log was read a job still counts as missed.
    public var missedWithin: TimeInterval = 600
    public var onUsage: ((AgentReading) -> Void)?
    /// A session started or stopped working (a turn began, or ended).
    public var onWorkingChange: (() -> Void)?
    /// What the watcher reads and decides, for diagnosing (`AgentBuddyChecks --watch`).
    public var debugLog: ((String) -> Void)?
    /// How long a finished turn waits for more work before it reminds.
    public var debounce: [Agent: TimeInterval] = [.claude: 3, .codex: 1.5, .copilot: 1.5]
    /// Off only in checks that replay old logs.
    public var requireFreshEvents = true

    private final class WatchedFile {
        let path: String
        let tracker: SessionTracker
        let firstSeen: Date
        var offset: UInt64
        var skipPartialLine: Bool
        var remainder = Data()
        var pending: JobEvent?
        var pendingToken = 0
        /// The server whose lines these are (nil on this Mac), and its clock minus this Mac's.
        var source: String?
        var skew: TimeInterval = 0
        /// When the turn under way began, and the latest work in it (this Mac's clock).
        var workingSince: Date?
        var lastWork: Date?

        init(path: String, tracker: SessionTracker, offset: UInt64, firstSeen: Date) {
            self.path = path
            self.tracker = tracker
            self.offset = offset
            self.firstSeen = firstSeen
            skipPartialLine = offset > 0
        }
    }

    private let queue = DispatchQueue(label: "AgentBuddy.TranscriptWatcher")
    private var fixedRoots: Roots?
    private var roots: Roots?
    private var stream: FSEventStreamRef?
    private var files: [String: WatchedFile] = [:]
    private var emitted: [String] = []
    /// Codex thread names reported by each server.
    private var remoteNames: [String: [String: String]] = [:]
    private let startedAt = Date()
    private let tailBytes: UInt64 = 512 * 1024

    /// Without `roots`, the agents' standard folders are used (read off the main thread).
    public init(roots: Roots? = nil) {
        fixedRoots = roots
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    public func start() {
        queue.async {
            self.startStream()
            self.catchUp()
        }
    }

    /// Opens the logs written in the last `within` seconds, so a turn already
    /// under way when watching starts counts as working before its next line.
    /// Their old turns remind no one: they aren't fresh.
    private func catchUp(within: TimeInterval = WorkingRule.quiet) {
        guard let roots else { return }
        let since = Date().addingTimeInterval(-within)
        for log in SessionHistoryReader.recentLogs(since: since, roots: roots) where files[log.path] == nil {
            process(log.path)
        }
    }

    public func stop() {
        queue.sync {
            guard let stream else { return }
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }

    /// Reads a file's growth now, as an FSEvent would.
    public func poke(_ path: String) {
        queue.async { self.process(path) }
    }

    /// Lines of a session log on a server, streamed by `RemoteSessionStream`. They
    /// go through the same trackers and reminders as this Mac's logs; `skew` is the
    /// server's clock minus this Mac's, and `prime` its first line when the lines
    /// start further in.
    public func feed(source: String, path: String, agent: Agent, lines: [JSON], prime: JSON?, skew: TimeInterval) {
        queue.async { [weak self] in
            guard let self else { return }
            let key = "\(source)\u{1}\(path)"
            let file: WatchedFile
            if let existing = self.files[key] {
                file = existing
            } else {
                let tracker: SessionTracker
                switch agent {
                case .claude: tracker = ClaudeTracker(path: path)
                case .codex:
                    tracker = CodexTracker(path: path, sessionIndex: nil) { [weak self] thread in
                        self?.remoteNames[source]?[thread]
                    }
                case .copilot: tracker = CopilotTracker(path: path)
                default: return  // The others are watched by AgentLogWatcher, on this Mac.
                }
                if let prime {
                    tracker.prime(firstLine: prime)
                }
                file = WatchedFile(path: path, tracker: tracker, offset: 0, firstSeen: Date())
                file.source = source
                self.files[key] = file
                self.debugLog?("open \(agent.rawValue) \(URL(fileURLWithPath: path).lastPathComponent) on \(source)")
            }
            file.skew = skew
            for line in lines {
                for action in file.tracker.consume(line) {
                    self.handle(action, in: file)
                }
            }
        }
    }

    /// Codex thread names a server reported (id, name).
    public func feedNames(source: String, names: [(String, String)]) {
        queue.async {
            for (thread, name) in names {
                self.remoteNames[source, default: [:]][thread] = name
            }
        }
    }

    /// Forgets a server's sessions (it was removed from Settings).
    public func forget(source: String) {
        queue.async {
            self.files = self.files.filter { $0.value.source != source }
            self.remoteNames[source] = nil
        }
    }

    /// Runs `work` on the watcher's queue after everything already queued.
    public func sync(_ work: () -> Void = {}) {
        queue.sync(execute: work)
    }

    private func startStream() {
        let roots = fixedRoots ?? Roots.standard()
        self.roots = roots
        // FSEvents needs a folder that exists; a missing one is watched through its parent.
        var watched: [String] = []
        for root in [roots.claudeProjects, roots.codexSessions, roots.copilotSessions] {
            let candidates = [root, root.deletingLastPathComponent()]
            if let existing = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
               !watched.contains(existing.path) {
                watched.append(existing.path)
            }
        }
        guard !watched.isEmpty else { return }
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, eventPaths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<TranscriptWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as NSArray
            for case let path as String in paths {
                watcher.process(path)
            }
        }
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context, watched as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, flags)
        else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    private func classify(_ path: String) -> Agent? {
        guard path.hasSuffix(".jsonl"), let roots else { return nil }
        func parts(under root: URL) -> [Substring]? {
            let prefix = root.path + "/"
            guard path.hasPrefix(prefix) else { return nil }
            return path.dropFirst(prefix.count).split(separator: "/")
        }
        // A session is <project>/<id>.jsonl; sub-agents' logs sit deeper.
        if let parts = parts(under: roots.claudeProjects) {
            return parts.count == 2 ? .claude : nil
        }
        if let parts = parts(under: roots.codexSessions) {
            return parts.last?.hasPrefix("rollout-") == true ? .codex : nil
        }
        if let parts = parts(under: roots.copilotSessions) {
            return parts.count == 2 && parts[1] == "events.jsonl" ? .copilot : nil
        }
        return nil
    }

    private func process(_ path: String) {
        guard let agent = classify(path) else { return }
        if files[path] == nil {
            guard let opened = open(path, agent) else { return }
            files[path] = opened
        }
        if let file = files[path] {
            read(file)
        }
    }

    private func open(_ path: String, _ agent: Agent) -> WatchedFile? {
        guard let size = Self.size(path) else { return nil }
        let tracker: SessionTracker
        switch agent {
        case .claude: tracker = ClaudeTracker(path: path)
        case .codex: tracker = CodexTracker(path: path, sessionIndex: roots?.codexIndex)
        case .copilot: tracker = CopilotTracker(path: path)
        default: return nil  // The others are watched by AgentLogWatcher.
        }
        let start = size > tailBytes ? size - tailBytes : 0
        if start > 0, agent == .codex, let first = Self.firstLine(path) {
            tracker.prime(firstLine: first)
        }
        debugLog?("open \(agent.rawValue) \(URL(fileURLWithPath: path).lastPathComponent) size \(size) from \(start)")
        return WatchedFile(path: path, tracker: tracker, offset: start, firstSeen: Date())
    }

    private func read(_ file: WatchedFile) {
        guard let size = Self.size(file.path) else {
            files[file.path] = nil
            return
        }
        if size < file.offset {
            // Rewritten from the start.
            file.offset = 0
            file.remainder.removeAll()
            file.skipPartialLine = false
        }
        guard size > file.offset, let reader = FileHandle(forReadingAtPath: file.path) else { return }
        defer { try? reader.close() }
        guard (try? reader.seek(toOffset: file.offset)) != nil,
              let data = try? reader.read(upToCount: Int(size - file.offset)), !data.isEmpty
        else { return }
        file.offset += UInt64(data.count)
        var chunk = file.remainder
        chunk.append(data)
        var lines = chunk.split(separator: 0x0A, omittingEmptySubsequences: false)
        file.remainder = lines.isEmpty ? Data() : Data(lines.removeLast())
        if file.skipPartialLine, !lines.isEmpty {
            lines.removeFirst()
            file.skipPartialLine = false
        }
        var parsed = 0
        var unparsed = 0
        var newest: Date?
        for line in lines where !line.isEmpty {
            guard let value = JSON.parse(Data(line)) else {
                unparsed += 1
                continue
            }
            parsed += 1
            if debugLog != nil, let at = Dates.parse(value["timestamp"].string) {
                newest = max(newest ?? at, at)
            }
            for action in file.tracker.consume(value) {
                handle(action, in: file)
            }
        }
        if let debugLog {
            // How far behind the newest line's own time this read came shows whether
            // an agent writes its lines as they happen or in batches.
            let lag = newest.map { String(format: ", newest line %.1fs old", Date().timeIntervalSince($0)) } ?? ""
            debugLog("read \(URL(fileURLWithPath: file.path).lastPathComponent) +\(data.count) bytes, \(parsed) lines, \(unparsed) unparsed\(lag)")
        }
    }

    private func handle(_ action: TrackerAction, in file: WatchedFile) {
        noteWork(action, in: file)
        switch action {
        case .started(let at):
            // A new turn: the one before it is done, however soon this came.
            guard let pending = file.pending, at >= pending.finishedAt else { return }
            file.pending = nil
            debugLog?("next turn started \(String(format: "%.2f", at.timeIntervalSince(pending.finishedAt)))s after \(pending.id)")
            emit(pending, from: file)
        case .activity(let at):
            guard let pending = file.pending, at > pending.finishedAt else { return }
            file.pending = nil
            let gap = at.timeIntervalSince(pending.finishedAt)
            if gap <= (debounce[pending.agent] ?? 2) + 2 {
                // The agent kept going right away: a stop hook resumed it, or a
                // queued prompt ran. That turn isn't finished after all.
                debugLog?("withdrawn \(pending.id): more work \(String(format: "%.1f", gap))s after it")
            } else {
                // The turn did end; the next work only came much later, and both
                // reached us together. The job is still finished.
                debugLog?("late \(pending.id): next work came \(Int(gap))s after it")
                emit(pending, from: file)
            }
        case .cancel:
            if let pending = file.pending {
                debugLog?("cancelled \(pending.id)")
            }
            file.pending = nil
        case .finished(let event):
            let fresh = isFresh(event.finishedAt, file)
            debugLog?("finished \(event.id) at \(event.finishedAt) fresh \(fresh) (started \(startedAt), first seen \(file.firstSeen))")
            guard fresh else {
                if requireFreshEvents, event.finishedAt.addingTimeInterval(-file.skew) >= Date().addingTimeInterval(-missedWithin) {
                    emit(event, from: file, missed: true)
                }
                return
            }
            if file.pending?.id == event.id {
                file.pending = event
                return
            }
            file.pending = event
            file.pendingToken += 1
            let token = file.pendingToken
            let delay = debounce[event.agent] ?? 2
            queue.asyncAfter(deadline: .now() + delay) { [weak self, weak file] in
                guard let self, let file, file.pendingToken == token, let event = file.pending else { return }
                file.pending = nil
                self.emit(event, from: file)
            }
        case .usage(let reading):
            // A server's Codex may be signed in to another ChatGPT account, so only
            // this Mac's snapshots update the plan limits shown.
            guard file.source == nil, !requireFreshEvents || isFresh(reading.fetchedAt, file) else { return }
            onUsage?(reading)
        }
    }

    /// Keeps track of whether the session is in a turn: from its prompt (or the
    /// first work seen) to the turn's end.
    private func noteWork(_ action: TrackerAction, in file: WatchedFile) {
        let wasWorking = file.workingSince != nil
        switch action {
        case .started(let at):
            let here = at.addingTimeInterval(-file.skew)
            file.workingSince = here
            file.lastWork = here
        case .activity(let at):
            let here = at.addingTimeInterval(-file.skew)
            file.workingSince = file.workingSince ?? here
            file.lastWork = max(file.lastWork ?? here, here)
        case .finished, .cancel:
            file.workingSince = nil
        case .usage:
            return
        }
        if wasWorking != (file.workingSince != nil) {
            onWorkingChange?()
        }
    }

    /// The sessions in a turn now, with when their latest work was, on this
    /// Mac's clock. Called back on the watcher's queue.
    public func workingSessions(_ reply: @escaping ([WorkingSession]) -> Void) {
        queue.async {
            let working = self.files.values.compactMap { file -> WorkingSession? in
                guard let since = file.workingSince else { return nil }
                let session = file.tracker.session
                guard !session.isSubagent else { return nil }
                return WorkingSession(
                    agent: file.tracker.agent, source: file.source, sessionID: session.id, name: session.name,
                    folder: session.folder, task: session.task, since: since, lastWork: file.lastWork ?? since)
            }
            reply(working)
        }
    }

    /// A line is news when it was written after this app started, around when
    /// its file was first seen, and within the last five minutes.
    private func isFresh(_ stamped: Date, _ file: WatchedFile) -> Bool {
        guard requireFreshEvents else { return true }
        // A server's lines carry its clock; compare them by this Mac's.
        let date = stamped.addingTimeInterval(-file.skew)
        return date >= startedAt.addingTimeInterval(-5)
            && date >= file.firstSeen.addingTimeInterval(-120)
            && date >= Date().addingTimeInterval(-300)
    }

    private func emit(_ stamped: JobEvent, from file: WatchedFile, missed: Bool = false) {
        var event = stamped
        if let source = file.source {
            event.source = source
            event.finishedAt = event.finishedAt.addingTimeInterval(-file.skew)
            event.startedAt = event.startedAt?.addingTimeInterval(-file.skew)
        }
        debugLog?("emit \(event.id)\(missed ? " (missed)" : "") (already emitted: \(emitted.contains(event.id)))")
        guard !emitted.contains(event.id) else { return }
        emitted.append(event.id)
        if emitted.count > 256 {
            emitted.removeFirst(emitted.count - 256)
        }
        if missed {
            onMissed?(event)
        } else {
            onJob?(event)
        }
    }

    private static func size(_ path: String) -> UInt64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              (attributes[.type] as? FileAttributeType) == .typeRegular
        else { return nil }
        return (attributes[.size] as? NSNumber)?.uint64Value
    }

    private static func firstLine(_ path: String) -> JSON? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var data = Data()
        while data.count < 4_194_304, let chunk = try? handle.read(upToCount: 65_536), !chunk.isEmpty {
            if let newline = chunk.firstIndex(of: 0x0A) {
                data.append(chunk[chunk.startIndex..<newline])
                return JSON.parse(data)
            }
            data.append(chunk)
        }
        return nil
    }
}
