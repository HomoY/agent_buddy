import Foundation

/// What a log line means for its session.
public enum TrackerAction {
    /// A new turn began (your prompt, a queued one, or a background task's
    /// report): the turn before it is finished, so its reminder goes out now.
    case started(Date)
    /// The agent is working: a pending "finished" reminder is withdrawn when
    /// this comes right after it (a stop hook resumed the same turn).
    case activity(Date)
    /// A turn ended. The watcher waits a moment before reminding.
    case finished(JobEvent)
    /// The turn ended without a result (interrupted): no reminder.
    case cancel
    /// Codex wrote a fresh rate-limit snapshot.
    case usage(AgentReading)
}

/// A session as its tracker knows it so far.
public struct TrackedSession: Equatable, Sendable {
    public var id: String
    /// Its title, or the start of its first prompt.
    public var name: String?
    /// The folder it works in.
    public var folder: String?
    /// What it's working on: the start of the prompt its turn answers.
    public var task: String?
    /// A Codex sub-agent's own thread (its parent's turn is the one working).
    public var isSubagent: Bool

    public init(id: String, name: String?, folder: String?, task: String? = nil, isSubagent: Bool = false) {
        self.id = id
        self.name = name
        self.folder = folder
        self.task = task
        self.isSubagent = isSubagent
    }

    /// A prompt as a short task: one line, editor context and reminders dropped.
    static func task(_ prompt: String?) -> String? {
        guard let prompt else { return nil }
        return TextTools.condensed(SessionHistoryReader.stripContext(prompt), limit: 90)
    }
}

/// Follows one session log, line by line.
public protocol SessionTracker: AnyObject {
    var agent: Agent { get }
    /// Which session it is, as far as read.
    var session: TrackedSession { get }
    /// The file's first line, when reading starts further in (Codex's session_meta).
    func prime(firstLine: JSON)
    func consume(_ line: JSON) -> [TrackerAction]
}

/// Remembers the last few finished turns so one turn reminds once.
struct RecentKeys {
    private var keys: [String] = []

    mutating func insert(_ key: String) -> Bool {
        guard !keys.contains(key) else { return false }
        keys.append(key)
        if keys.count > 64 {
            keys.removeFirst(keys.count - 64)
        }
        return true
    }
}

// MARK: - Claude Code

/// `~/.claude/projects/<project>/<session>.jsonl`. A turn starts at a prompt and
/// ends at an assistant message whose stop_reason is end_turn, or at Claude
/// Code's stop-hook summary.
public final class ClaudeTracker: SessionTracker {
    public let agent = Agent.claude
    let path: String
    let sessionID: String
    var aiTitle: String?
    var customTitle: String?
    var summaryTitle: String?
    var firstPrompt: String?
    var cwd: String?
    var running = false
    var turnStartedAt: Date?
    var lastText: String?
    var finished = RecentKeys()
    var lastFinished: (key: String, at: Date)?

    public init(path: String) {
        self.path = path
        sessionID = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    }

    public func prime(firstLine: JSON) {}

    var currentTask: String?

    public var session: TrackedSession {
        TrackedSession(id: sessionID, name: customTitle ?? aiTitle ?? summaryTitle ?? firstPrompt, folder: cwd, task: currentTask)
    }

    public func consume(_ line: JSON) -> [TrackerAction] {
        let type = line["type"].string ?? ""
        switch type {
        case "ai-title":
            aiTitle = line["aiTitle"].nonEmptyString ?? aiTitle
            return []
        case "custom-title":
            customTitle = line["customTitle"].nonEmptyString ?? customTitle
            return []
        case "summary":
            summaryTitle = line["summary"].nonEmptyString ?? summaryTitle
            return []
        default:
            break
        }
        if let folder = line["cwd"].nonEmptyString {
            cwd = folder
        }
        guard let at = Dates.parse(line["timestamp"].string), line["isSidechain"].bool != true else { return [] }
        let message = line["message"]
        let role = message["role"].string ?? type

        if role == "assistant" {
            if line["isApiErrorMessage"].bool == true {
                guard running else { return [] }
                running = false
                let error = line["error"].string ?? ""
                let limited = error == "rate_limit" || error == "billing_error"
                var event = makeEvent(limited ? .limited : .failed, at: at, key: "error-\(Int(at.timeIntervalSince1970))")
                event.summary = TextTools.condensed(Self.text(of: message))
                    ?? (limited ? "Claude's usage limit was reached." : "Claude Code stopped with an API error.")
                return [.finished(event)]
            }
            guard message["model"].string != "<synthetic>" else { return [] }
            if let text = Self.text(of: message) {
                lastText = text
            }
            let stop = message["stop_reason"].string
            if stop == "end_turn" || stop == "stop_sequence" {
                let key = message["id"].nonEmptyString ?? "end-\(Int(at.timeIntervalSince1970))"
                running = false
                // Claude Code writes one answer as a line per block (thinking, then
                // text); later lines refresh the pending reminder's words.
                if key == lastFinished?.key {
                    return [.finished(makeEvent(.completed, at: lastFinished?.at ?? at, key: key))]
                }
                guard finished.insert(key) else { return [] }
                lastFinished = (key, at)
                return [.finished(makeEvent(.completed, at: at, key: key))]
            }
            running = true
            return [.activity(at)]
        }

        if role == "user" {
            let content = message["content"]
            if content.array.contains(where: { $0["type"].string == "tool_result" }) {
                running = true
                return [.activity(at)]
            }
            guard line["isMeta"].bool != true, line["isCompactSummary"].bool != true else { return [] }
            let text = Self.text(of: message)
            if let text, text.hasPrefix("<command-name>") || text.hasPrefix("<local-command-") {
                return []
            }
            if let text, text.hasPrefix("[Request interrupted") {
                running = false
                return [.cancel]
            }
            running = true
            turnStartedAt = at
            lastText = nil
            currentTask = TrackedSession.task(text) ?? "(an image)"
            if firstPrompt == nil {
                firstPrompt = TextTools.condensed(text, limit: 80)
            }
            return [.started(at)]
        }

        if type == "system", let subtype = line["subtype"].string,
           subtype == "stop_hook_summary" || subtype == "turn_duration" {
            guard running else { return [] }
            running = false
            return [.finished(makeEvent(.completed, at: at, key: "stop-\(Int(at.timeIntervalSince1970))"))]
        }
        return []
    }

    static func text(of message: JSON) -> String? {
        let content = message["content"]
        if let text = content.string {
            return text
        }
        let parts = content.array.compactMap { $0["type"].string == "text" ? $0["text"].string : nil }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    func makeEvent(_ outcome: JobEvent.Outcome, at: Date, key: String) -> JobEvent {
        JobEvent(
            id: "claude:\(sessionID):\(key)", agent: .claude, outcome: outcome, sessionID: sessionID,
            title: customTitle ?? aiTitle ?? summaryTitle ?? firstPrompt, project: TextTools.project(cwd),
            summary: TextTools.condensed(lastText), startedAt: turnStartedAt, finishedAt: at, transcriptPath: path)
    }
}

// MARK: - Codex

/// `~/.codex/sessions/YYYY/MM/DD/rollout-…-<thread>.jsonl`. A turn runs from
/// task_started to task_complete; turn_aborted means interrupted. Spawned
/// sub-agents' threads are skipped (their parent's turn reminds).
public final class CodexTracker: SessionTracker {
    public let agent = Agent.codex
    let path: String
    let sessionIndex: URL?
    /// Thread names from elsewhere (a server's session_index.jsonl), in place of the file.
    let names: ((String) -> String?)?
    var threadID: String?
    var sawMeta = false
    var isSubagent = false
    var cwd: String?
    var firstPrompt: String?
    var running = false
    var turnStartedAt: Date?
    var lastMessage: String?
    var finished = RecentKeys()

    public init(path: String, sessionIndex: URL?, names: ((String) -> String?)? = nil) {
        self.path = path
        self.sessionIndex = sessionIndex
        self.names = names
        let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        if name.count >= 36 {
            let candidate = String(name.suffix(36))
            if UUID(uuidString: candidate) != nil {
                threadID = candidate
            }
        }
    }

    public func prime(firstLine: JSON) {
        _ = consume(firstLine)
    }

    var currentTask: String?

    public var session: TrackedSession {
        let thread = threadID ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        return TrackedSession(id: thread, name: threadName() ?? firstPrompt, folder: cwd, task: currentTask, isSubagent: isSubagent)
    }

    public func consume(_ line: JSON) -> [TrackerAction] {
        let type = line["type"].string ?? ""
        let payload = line["payload"]
        if type == "session_meta" {
            // The thread's own meta is the file's first line; a fork copies its
            // parent's after it, and those don't change whose thread this is.
            if !sawMeta {
                sawMeta = true
                threadID = payload["id"].nonEmptyString ?? threadID
            }
            if payload["id"].string == threadID {
                cwd = payload["cwd"].nonEmptyString ?? cwd
                let source = payload["source"]
                if source.isObject && !source["subagent"].isNull {
                    isSubagent = true
                }
            }
            return []
        }
        if type == "turn_context" {
            cwd = payload["cwd"].nonEmptyString ?? cwd
            return []
        }
        guard let at = Dates.parse(line["timestamp"].string) else { return [] }
        if type == "response_item" {
            return running ? [.activity(at)] : []
        }
        guard type == "event_msg" else { return [] }
        switch payload["type"].string ?? "" {
        case "task_started":
            running = true
            turnStartedAt = at
            lastMessage = nil
            return [.started(at)]
        case "user_message":
            if firstPrompt == nil {
                firstPrompt = TextTools.condensed(payload["message"].string, limit: 80)
            }
            currentTask = TrackedSession.task(payload["message"].string) ?? currentTask
            return [.started(at)]
        case "agent_message":
            lastMessage = payload["message"].nonEmptyString ?? lastMessage
            return [.activity(at)]
        case "item_completed":
            let item = payload["item"]
            let texts = item["content"].array.compactMap { $0["text"].string }
            if item["type"].string == "UserMessage" {
                if firstPrompt == nil {
                    firstPrompt = TextTools.condensed(texts.first, limit: 80)
                }
                currentTask = TrackedSession.task(texts.joined(separator: " ")) ?? currentTask
            }
            if item["type"].string == "AgentMessage", !texts.isEmpty {
                lastMessage = texts.joined(separator: "\n\n")
            }
            return running ? [.activity(at)] : []
        case "task_complete":
            running = false
            guard !isSubagent else { return [] }
            let turn = payload["turn_id"].nonEmptyString ?? "end-\(Int(at.timeIntervalSince1970))"
            guard finished.insert(turn) else { return [] }
            let error = payload["error"]
            let failed = !(error.isNull || error.string == "")
            var event = makeEvent(failed ? .failed : .completed, at: at, key: turn)
            if let milliseconds = payload["duration_ms"].double, milliseconds > 0 {
                event.startedAt = at.addingTimeInterval(-milliseconds / 1000)
            }
            if let message = payload["last_agent_message"].nonEmptyString {
                event.summary = TextTools.condensed(message)
            }
            return [.finished(event)]
        case "turn_aborted":
            running = false
            return [.cancel]
        case "token_count":
            guard let reading = CodexUsage.reading(fromTokenCount: payload["rate_limits"], at: at) else { return [] }
            return [.usage(reading)]
        default:
            return running ? [.activity(at)] : []
        }
    }

    func makeEvent(_ outcome: JobEvent.Outcome, at: Date, key: String) -> JobEvent {
        let thread = threadID ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        return JobEvent(
            id: "codex:\(thread):\(key)", agent: .codex, outcome: outcome, sessionID: thread,
            title: threadName() ?? firstPrompt, project: TextTools.project(cwd),
            summary: TextTools.condensed(lastMessage), startedAt: turnStartedAt, finishedAt: at, transcriptPath: path)
    }

    /// The name Codex gave the thread, from `session_index.jsonl`.
    func threadName() -> String? {
        if let names, let threadID {
            return names(threadID)
        }
        guard let threadID, let sessionIndex, let tail = Tail.read(sessionIndex, maxBytes: 2_097_152) else { return nil }
        for line in tail.lines.reversed() {
            if let entry = JSON.parse(line), entry["id"].string == threadID, let name = entry["thread_name"].nonEmptyString {
                return name
            }
        }
        return nil
    }
}

// MARK: - Copilot

/// `~/.copilot/session-state/<session>/events.jsonl`, written by the Copilot CLI
/// and by VS Code's Copilot agent host. A request starts at user.message and
/// ends at the agentStop hook record (stopReason end_turn), or, when a Copilot
/// writes none, at the turn_end after an answer that asked for no tools.
public final class CopilotTracker: SessionTracker {
    public let agent = Agent.copilot
    let path: String
    let sessionID: String
    let folder: URL
    var name: String?
    var cwd: String?
    var firstPrompt: String?
    var running = false
    var turnStartedAt: Date?
    var turnKey: String?
    var lastMessage: String?
    var lastAskedForTools = true
    var finished = RecentKeys()

    public init(path: String) {
        self.path = path
        folder = URL(fileURLWithPath: path).deletingLastPathComponent()
        sessionID = folder.lastPathComponent
        loadWorkspace()
    }

    public func prime(firstLine: JSON) {
        _ = consume(firstLine)
    }

    var currentTask: String?

    public var session: TrackedSession {
        TrackedSession(id: sessionID, name: TextTools.condensed(name, limit: 80) ?? firstPrompt, folder: cwd, task: currentTask)
    }

    public func consume(_ line: JSON) -> [TrackerAction] {
        guard let at = Dates.parse(line["timestamp"].string) else { return [] }
        let type = line["type"].string ?? ""
        let data = line["data"]
        let main = line["agentId"].isNull
        switch type {
        case "session.start":
            cwd = cwd ?? data["context"]["cwd"].nonEmptyString
            return []
        case "user.message":
            guard main else { return [] }
            running = true
            turnStartedAt = at
            turnKey = line["id"].nonEmptyString ?? "turn-\(Int(at.timeIntervalSince1970))"
            lastMessage = nil
            lastAskedForTools = true
            currentTask = TrackedSession.task(data["content"].string) ?? currentTask
            if firstPrompt == nil {
                firstPrompt = TextTools.condensed(data["content"].string, limit: 80)
            }
            return [.started(at)]
        case "assistant.message", "assistant.turn_start", "tool.execution_start":
            guard main else { return running ? [.activity(at)] : [] }
            if !running {
                // Work without a new prompt: a background shell finished and
                // woke the agent. It is a new job that will finish on its own.
                running = true
                turnStartedAt = at
                turnKey = "resume-\(Int(at.timeIntervalSince1970 * 1000))"
                lastMessage = nil
                lastAskedForTools = true
            }
            if type == "assistant.message" {
                lastMessage = data["content"].nonEmptyString ?? lastMessage
                lastAskedForTools = !data["toolRequests"].array.isEmpty
            }
            return [.activity(at)]
        case "tool.execution_complete", "permission.requested", "permission.completed", "session.compaction_start":
            return running ? [.activity(at)] : []
        case "assistant.turn_end":
            guard main, running, !lastAskedForTools, lastMessage != nil else { return [] }
            return finish(.completed, at: at)
        case "hook.start":
            guard main, data["hookType"].string == "agentStop" else {
                return running ? [.activity(at)] : []
            }
            guard running else { return [] }
            switch data["input"]["stopReason"].string {
            case "end_turn": return finish(.completed, at: at)
            case "error": return finish(.failed, at: at)
            default:
                running = false
                return [.cancel]
            }
        case "abort":
            running = false
            return [.cancel]
        case "session.shutdown":
            running = false
            return []
        default:
            return []
        }
    }

    func finish(_ outcome: JobEvent.Outcome, at: Date) -> [TrackerAction] {
        running = false
        let key = turnKey ?? "end-\(Int(at.timeIntervalSince1970))"
        guard finished.insert(key) else { return [] }
        loadWorkspace()
        let event = JobEvent(
            id: "copilot:\(sessionID):\(key)", agent: .copilot, outcome: outcome, sessionID: sessionID,
            title: TextTools.condensed(name, limit: 80) ?? firstPrompt, project: TextTools.project(cwd),
            summary: TextTools.condensed(lastMessage), startedAt: turnStartedAt, finishedAt: at, transcriptPath: path)
        return [.finished(event)]
    }

    /// The session's name and folder from its `workspace.yaml`.
    func loadWorkspace() {
        guard let text = try? String(contentsOf: folder.appendingPathComponent("workspace.yaml"), encoding: .utf8) else { return }
        for line in text.split(separator: "\n") where !(line.first?.isWhitespace ?? true) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let quote = value.first, quote == "'" || quote == "\"", value.last == quote {
                value = String(value.dropFirst().dropLast())
                if quote == "'" {
                    value = value.replacingOccurrences(of: "''", with: "'")
                }
            }
            guard !value.isEmpty else { continue }
            if key == "cwd" {
                cwd = value
            } else if key == "name" {
                name = value
            }
        }
    }
}
