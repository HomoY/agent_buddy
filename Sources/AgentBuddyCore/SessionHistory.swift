import Foundation

/// The tokens one model used.
public struct ModelTokens: Identifiable, Equatable, Sendable {
    public var model: String
    public var counts: TokenCounts

    public init(model: String, counts: TokenCounts) {
        self.model = model
        self.counts = counts
    }

    public var id: String { model }

    /// By model, the most used first.
    public static func list(_ byModel: [String: TokenCounts]) -> [ModelTokens] {
        byModel.map { ModelTokens(model: $0.key, counts: $0.value) }
            .filter { $0.counts.total > 0 }
            .sorted { ($0.counts.total, $1.model) > ($1.counts.total, $0.model) }
    }
}

/// One prompt asked in an agent window, and how its turn went.
/// What was selected (in an editor or another app) and sent with a prompt:
/// where it came from ("proof.tex, lines 40–42") and its text.
public struct PromptSelection: Equatable, Sendable {
    public var source: String
    public var text: String

    public init(source: String, text: String) {
        self.source = source
        self.text = text
    }
}

public struct PromptTurn: Identifiable, Equatable, Sendable {
    public enum Outcome: String, Sendable {
        case completed
        case failed
        case limited
        case interrupted
        /// The latest prompt, with no end recorded yet.
        case running
        /// No end recorded, and a later prompt followed.
        case open
    }

    public var id: String
    /// The prompt as typed, without the context editors attach to it.
    public var text: String
    public var askedAt: Date
    /// The prompt this one followed; nil for the first. Prompts after the same
    /// one are branches: Claude Code's rewind ("edit an earlier message").
    public var parent: String?
    /// The agent's last message in the turn, whole, as it wrote it (Markdown).
    public var answer: String?
    public var endedAt: Date?
    public var outcome: Outcome
    /// The tokens the turn used, by model; sub-agents' work included.
    public var usage: [ModelTokens]
    /// Sent on its own with `claude -p`, as Agent Buddy's message box does, not
    /// in the session's own window, which doesn't show it.
    public var separate: Bool
    /// What was selected and sent with it (by Agent Buddy's message box, or an editor).
    public var selections: [PromptSelection]

    public init(
        id: String, text: String, askedAt: Date, parent: String?, answer: String? = nil, endedAt: Date? = nil,
        outcome: Outcome = .open, usage: [ModelTokens] = [], separate: Bool = false, selections: [PromptSelection] = []
    ) {
        self.selections = selections
        self.id = id
        self.text = text
        self.askedAt = askedAt
        self.parent = parent
        self.answer = answer
        self.endedAt = endedAt
        self.outcome = outcome
        self.usage = usage
        self.separate = separate
    }

    public var tokens: TokenCounts {
        usage.reduce(TokenCounts()) { $0 + $1.counts }
    }

    public var duration: TimeInterval? {
        guard let endedAt else { return nil }
        let seconds = endedAt.timeIntervalSince(askedAt)
        return seconds >= 0 ? seconds : nil
    }
}

/// The prompts of one session, with what Agent Buddy needs to find its window.
public struct SessionHistory: Equatable, Sendable {
    public var agent: Agent
    public var sessionID: String
    public var title: String?
    /// The folder the session started in.
    public var cwd: String?
    /// Every folder the session worked in, the first first (the agent may `cd`).
    public var folders: [String] = []
    /// What wrote the session: Claude Code's entrypoint ("cli", "claude-vscode",
    /// "sdk-ts"…), Codex's originator ("codex_vscode", "Codex Desktop"…) or
    /// Copilot's producer ("copilot-agent"…).
    public var client: String?
    public var gitBranch: String?
    /// In the order asked.
    public var turns: [PromptTurn]
    /// Where the log was read: on this Mac, or on the server.
    public var logPath: String?
    /// The tokens of the whole session, by model. Copilot reports only these,
    /// when its session ends, not each job's.
    public var sessionUsage: [ModelTokens] = []
    /// When Copilot reported them.
    public var sessionEndedAt: Date?
    /// A Codex sub-agent's own thread: its work counts in its parent's job.
    public var isSubagent = false
    /// A Codex thread open for writing in another program ("VS Code", "the Codex app"),
    /// which then refuses another writer: Agent Buddy's prompts wait.
    public var openElsewhere: String?
    /// The model the session used last.
    public var model: String?
    /// How Claude Code was let act: its permission mode ("auto", "acceptEdits"…).
    public var permissionMode: String?
    /// How Codex was let act: its sandbox ("workspace-write"…), and its reasoning effort.
    public var sandbox: String?
    public var effort: String?
    /// Newer Codex's permission profile in the session (":workspace"), which a
    /// prompt sent from Agent Buddy keeps: it sets the sandbox up its own way.
    public var permissionProfile: String?
    /// Who approves what Codex asks to do beyond its sandbox in the session:
    /// "on-request" with "auto_review" (Codex's own reviewer) needs no one there.
    public var approvalPolicy: String?
    public var approvalsReviewer: String?

    public var sessionTokens: TokenCounts {
        sessionUsage.reduce(TokenCounts()) { $0 + $1.counts }
    }

    public init(
        agent: Agent, sessionID: String, title: String? = nil, cwd: String? = nil, client: String? = nil,
        gitBranch: String? = nil, turns: [PromptTurn] = []
    ) {
        self.agent = agent
        self.sessionID = sessionID
        self.title = title
        self.cwd = cwd
        self.client = client
        self.gitBranch = gitBranch
        self.turns = turns
    }

    /// The prompts as a tree, ready to draw.
    public var rows: [HistoryRow] { HistoryRow.layout(turns) }
}

/// One prompt in the drawn tree. The line that leads to the latest prompt runs
/// down the left at depth 0; a branch that was edited away is indented under
/// the prompt it came after, before the line goes on.
public struct HistoryRow: Identifiable, Equatable, Sendable {
    public var turn: PromptTurn
    public var depth: Int
    /// On the line that leads to the latest prompt.
    public var current: Bool
    /// The first prompt of a branch.
    public var branchStart: Bool
    /// Whether this row's own line goes on above and below its dot.
    public var lineAbove: Bool
    public var lineBelow: Bool
    /// The shallower levels whose line passes this row (it goes on below it).
    public var guides: [Int]

    public var id: String { turn.id }

    public static func layout(_ turns: [PromptTurn]) -> [HistoryRow] {
        guard let latest = turns.max(by: { $0.askedAt < $1.askedAt }) else { return [] }
        let byID = Dictionary(turns.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var children: [String: [PromptTurn]] = [:]
        var roots: [PromptTurn] = []
        for turn in turns {
            if let parent = turn.parent, parent != turn.id, byID[parent] != nil {
                children[parent, default: []].append(turn)
            } else {
                roots.append(turn)
            }
        }
        var current = Set<String>()
        var walk: String? = latest.id
        while let id = walk, current.insert(id).inserted {
            walk = byID[id]?.parent
        }
        var rows: [HistoryRow] = []
        var placed = Set<String>()
        func emit(_ start: PromptTurn, depth: Int, guides: [Int], branch: Bool) {
            var node: PromptTurn? = start
            var first = true
            while let turn = node, placed.insert(turn.id).inserted {
                let kids = (children[turn.id] ?? []).sorted { $0.askedAt < $1.askedAt }
                rows.append(HistoryRow(
                    turn: turn, depth: depth, current: current.contains(turn.id), branchStart: branch && first,
                    lineAbove: !first, lineBelow: !kids.isEmpty, guides: guides))
                first = false
                // The line goes on with the child toward the latest prompt (or the
                // newest child); the others hang under this prompt as branches,
                // with this line passing them on its way down.
                let next = kids.first { current.contains($0.id) } ?? kids.last
                for kid in kids where kid.id != next?.id {
                    emit(kid, depth: depth + 1, guides: guides + [depth], branch: true)
                }
                node = next
            }
        }
        // Prompts with no parent found (rare): the current one starts the main
        // line; others hang before it as branches.
        for root in roots.sorted(by: { (current.contains($0.id) ? 1 : 0, $0.askedAt) < (current.contains($1.id) ? 1 : 0, $1.askedAt) }) {
            let main = current.contains(root.id)
            emit(root, depth: main ? 0 : 1, guides: [], branch: !main)
        }
        return rows
    }
}

/// Reads the prompts out of a session log: Claude Code's
/// `~/.claude/projects/<project>/<session>.jsonl`, Codex's rollout files and
/// Copilot's `events.jsonl`. Also reads the slimmed lines a server sends back.
public enum SessionHistoryReader {
    /// Longest prompt kept, in characters.
    static let promptLimit = 4000

    /// A local log; fails for a missing or unreadable file. Sub-agents' logs are
    /// read with it, so their tokens count in the job that started them.
    /// - Parameter reading: the log as read before, to read on from there (Claude Code's).
    public static func read(
        agent: Agent, path: String, roots: TranscriptWatcher.Roots = .standard(), reading: SessionLogReading? = nil
    ) -> Result<SessionHistory, ReadError> {
        // The agents watched through their logs alone: their own readers (OpenCode's "path" names a database's session).
        if !agent.hasLimits {
            return AgentLogs.read(agent: agent, path: path).map(\.history)
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped) else {
            return .failure(ReadError("The session log isn't there anymore."))
        }
        let url = URL(fileURLWithPath: path)
        var history: SessionHistory
        switch agent {
        case .claude:
            let session = url.deletingPathExtension().lastPathComponent
            history = reading?.claude(data, path: path, session: session)
                ?? claude(lines: lines(data) + subagentLines(beside: url, session: session), sessionID: session)
        case .codex:
            let own = lines(data)
            let thread = own.first?["payload"]["id"].nonEmptyString ?? url.deletingPathExtension().lastPathComponent
            let started = Dates.parse(own.first?["timestamp"].string) ?? .distantPast
            history = codex(lines: own + codexSubagentLines(of: thread, since: started, in: roots.codexSessions),
                            sessionID: url.deletingPathExtension().lastPathComponent)
            if history.title == nil {
                history.title = codexThreadName(history.sessionID)
            }
        case .copilot:
            let folder = url.deletingLastPathComponent()
            let workspace = try? String(contentsOf: folder.appendingPathComponent("workspace.yaml"), encoding: .utf8)
            history = copilot(lines: lines(data), sessionID: folder.lastPathComponent, workspace: workspace)
        default:
            return .failure(ReadError("Not one of the agents read here."))
        }
        history.logPath = path
        return .success(history)
    }

    /// The session's log on this Mac, found by its id (for a window whose jobs
    /// were cleared before it was opened).
    public static func locate(agent: Agent, sessionID: String, roots: TranscriptWatcher.Roots = .standard()) -> String? {
        let files = FileManager.default
        switch agent {
        case .claude:
            let projects = (try? files.contentsOfDirectory(at: roots.claudeProjects, includingPropertiesForKeys: nil)) ?? []
            for folder in projects {
                let file = folder.appendingPathComponent("\(sessionID).jsonl")
                if files.fileExists(atPath: file.path) {
                    return file.path
                }
            }
        case .codex:
            let walker = files.enumerator(at: roots.codexSessions, includingPropertiesForKeys: nil)
            while let url = walker?.nextObject() as? URL {
                if url.lastPathComponent.hasSuffix("\(sessionID).jsonl") {
                    return url.path
                }
            }
        case .copilot:
            let file = roots.copilotSessions.appendingPathComponent("\(sessionID)/events.jsonl")
            if files.fileExists(atPath: file.path) {
                return file.path
            }
        default:
            return AgentLogs.locate(agent: agent, sessionID: sessionID)
        }
        return nil
    }

    /// The usage lines of Claude Code's sub-agents, logged in
    /// `<project>/<session>/subagents/…`, marked as theirs.
    static func subagentLines(beside log: URL, session: String) -> [JSON] {
        guard let walker = FileManager.default.enumerator(at: subagentFolder(beside: log, session: session), includingPropertiesForKeys: nil)
        else { return [] }
        var found: [JSON] = []
        for case let file as URL in walker where file.pathExtension == "jsonl" {
            guard let data = try? Data(contentsOf: file, options: .alwaysMapped) else { continue }
            found += lines(data).compactMap(subagentLine)
        }
        return found
    }

    static func subagentFolder(beside log: URL, session: String) -> URL {
        log.deletingLastPathComponent().appendingPathComponent(session).appendingPathComponent("subagents")
    }

    /// A sub-agent's answer as its session's history takes it: what its usage is
    /// read from (no more: its history's other lines are its own), marked as the sub-agent's.
    static func subagentLine(_ line: JSON) -> JSON? {
        guard line["type"].string == "assistant" else { return nil }
        var kept: [String: Any] = ["isSidechain": true]
        for key in ["type", "timestamp", "requestId", "uuid", "parentUuid", "logicalParentUuid"] {
            kept[key] = line[key].raw
        }
        let message = line["message"]
        var usage: [String: Any] = [:]
        for key in ["id", "model", "usage"] {
            usage[key] = message[key].raw
        }
        kept["message"] = usage
        return JSON(kept)
    }

    /// The logs of the Codex sub-agents a thread spawned (their first line names
    /// it as parent), each after an `hs.subagent` line.
    static func codexSubagentLines(of thread: String, since: Date, in sessions: URL) -> [JSON] {
        guard !thread.isEmpty else { return [] }
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let walker = FileManager.default.enumerator(at: sessions, includingPropertiesForKeys: keys) else { return [] }
        var found: [JSON] = []
        for case let file as URL in walker where file.lastPathComponent.hasPrefix("rollout-") && file.pathExtension == "jsonl" {
            guard let modified = try? file.resourceValues(forKeys: Set(keys)).contentModificationDate, modified >= since,
                  let handle = try? FileHandle(forReadingFrom: file)
            else { continue }
            let head = (try? handle.read(upToCount: 65_536)) ?? Data()
            try? handle.close()
            let firstLine = head.split(separator: 0x0A, maxSplits: 1).first.map { Data($0) } ?? Data()
            guard let first = JSON.parse(firstLine),
                  first["payload"]["source"]["subagent"]["thread_spawn"]["parent_thread_id"].string == thread,
                  let data = try? Data(contentsOf: file, options: .alwaysMapped)
            else { continue }
            found.append(JSON(["type": "hs.subagent"]))
            found += lines(data)
        }
        return found
    }

    /// Lines that parse; the others (a line still being written) are skipped.
    public static func lines(_ data: Data) -> [JSON] {
        var parsed: [JSON] = []
        eachLine(of: data) { line in
            if let json = autoreleasepool(invoking: { JSON.parse(line) }) {
                parsed.append(json)
            }
        }
        return parsed
    }

    /// Each line of `data` that has something, without its newline. (Found with
    /// memchr: a log can be a hundred megabytes, and Data's own split goes a byte at a time.)
    public static func eachLine(of data: Data, _ body: (Data) -> Void) {
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            guard let base = bytes.baseAddress else { return }
            var start = 0
            while start < bytes.count {
                let stop = memchr(base + start, 0x0A, bytes.count - start).map { base.distance(to: UnsafeRawPointer($0)) } ?? bytes.count
                if stop > start {
                    body(Data(bytes: base + start, count: stop - start))
                }
                start = stop + 1
            }
        }
    }

    // MARK: - Claude Code

    /// Each entry has a `uuid` and its `parentUuid`; a prompt's parent prompt is
    /// the nearest prompt above it on that chain. Rewinding to an earlier message
    /// starts a new chain from there, so its prompt shares a parent with the
    /// prompt it replaced. Sub-agents (`isSidechain`) are left out.
    public static func claude(lines: [JSON], sessionID: String) -> SessionHistory {
        var reading = ClaudeReading(sessionID: sessionID)
        for line in lines {
            reading.add(line)
        }
        return reading.finished()
    }

    /// Claude Code's history (`claude(lines:sessionID:)`), a line at a time: kept,
    /// a log read before is read on from where it was (`SessionLogReading`).
    struct ClaudeReading {
        private var history: SessionHistory
        private var aiTitle: String?
        private var customTitle: String?
        private var summaryTitle: String?
        /// Every main-chain entry's prompt: the prompt whose turn it belongs to.
        private var promptOf: [String: String] = [:]
        private var turns: [String: PromptTurn] = [:]
        private var order: [String] = []
        /// Each message's usage, once (each block's line repeats it): with its
        /// prompt on the main chain, or its time for a sub-agent's.
        private var spent: [String: (owner: String?, at: Date?, model: String, counts: TokenCounts)] = [:]
        /// The message each turn's answer is from: its text blocks come a line each.
        private var answeredBy: [String: String] = [:]

        init(sessionID: String) {
            history = SessionHistory(agent: .claude, sessionID: sessionID)
        }

        mutating func add(_ line: JSON) {
            let type = line["type"].string ?? ""
            switch type {
            case "ai-title": aiTitle = line["aiTitle"].nonEmptyString ?? aiTitle
            case "custom-title": customTitle = line["customTitle"].nonEmptyString ?? customTitle
            case "summary": summaryTitle = line["summary"].nonEmptyString ?? summaryTitle
            default: break
            }
            if type == "assistant", let use = SessionHistoryReader.claudeUsage(line) {
                let parent = line["parentUuid"].nonEmptyString ?? line["logicalParentUuid"].nonEmptyString
                let owner = line["isSidechain"].bool == true ? nil : parent.flatMap { promptOf[$0] }
                spent[use.key] = (owner, Dates.parse(line["timestamp"].string), use.model, use.counts)
            }
            guard line["isSidechain"].bool != true, let uuid = line["uuid"].nonEmptyString else { return }
            if let folder = line["cwd"].nonEmptyString, !history.folders.contains(folder) {
                history.folders.append(folder)
                history.cwd = history.cwd ?? folder
            }
            history.client = history.client ?? line["entrypoint"].nonEmptyString
            history.gitBranch = line["gitBranch"].nonEmptyString ?? history.gitBranch
            history.permissionMode = line["permissionMode"].nonEmptyString ?? history.permissionMode
            let parent = line["parentUuid"].nonEmptyString ?? line["logicalParentUuid"].nonEmptyString
            let inherited = parent.flatMap { promptOf[$0] }
            let at = Dates.parse(line["timestamp"].string)
            let message = line["message"]
            let role = message["role"].string ?? type

            if role == "user", type == "user", let at, let text = SessionHistoryReader.promptText(line) {
                if text.hasPrefix("[Request interrupted") {
                    promptOf[uuid] = inherited
                    if let id = inherited, var turn = turns[id], turn.endedAt == nil {
                        turn.outcome = .interrupted
                        turn.endedAt = at
                        turns[id] = turn
                    }
                    return
                }
                promptOf[uuid] = uuid
                // `claude -p` writes "sdk-cli": a prompt sent apart from the session's own client.
                let separate = line["entrypoint"].string == "sdk-cli" && history.client != "sdk-cli"
                turns[uuid] = PromptTurn(id: uuid, text: text, askedAt: at, parent: inherited, separate: separate,
                                         selections: SessionHistoryReader.selections(in: SessionHistoryReader.rawPrompt(line)))
                order.append(uuid)
                return
            }
            promptOf[uuid] = inherited
            guard let id = inherited, var turn = turns[id], let at else { return }

            if role == "assistant" {
                if line["isApiErrorMessage"].bool == true {
                    let error = line["error"].string ?? ""
                    turn.outcome = error == "rate_limit" || error == "billing_error" ? .limited : .failed
                    turn.endedAt = at
                    turn.answer = SessionHistoryReader.answer(ClaudeTracker.text(of: message)) ?? turn.answer
                } else if message["model"].string != "<synthetic>" {
                    history.model = message["model"].nonEmptyString ?? history.model
                    if let text = SessionHistoryReader.answer(ClaudeTracker.text(of: message)) {
                        // The answer is all of the turn's last message with words.
                        let from = message["id"].nonEmptyString ?? uuid
                        if answeredBy[id] == from, let before = turn.answer, !before.hasSuffix(text) {
                            turn.answer = before + "\n\n" + text
                        } else {
                            turn.answer = text
                        }
                        answeredBy[id] = from
                    }
                    let stop = message["stop_reason"].string
                    if stop == "end_turn" || stop == "stop_sequence" {
                        turn.outcome = .completed
                        turn.endedAt = at
                    }
                }
                turns[id] = turn
            } else if type == "system", let subtype = line["subtype"].string,
                      subtype == "stop_hook_summary" || subtype == "turn_duration", turn.endedAt == nil {
                turn.outcome = .completed
                turn.endedAt = at
                turns[id] = turn
            }
        }

        /// The history of the lines so far.
        func finished() -> SessionHistory {
            var history = self.history
            var turns = self.turns
            history.title = customTitle ?? aiTitle ?? summaryTitle
            // A sub-agent's tokens go to the prompt asked last before it worked.
            let byTime = order.compactMap { turns[$0] }.sorted { $0.askedAt < $1.askedAt }
            var perTurn: [String: [String: TokenCounts]] = [:]
            var all: [String: TokenCounts] = [:]
            for use in spent.values {
                all[use.model, default: TokenCounts()] += use.counts
                let owner = use.owner ?? use.at.flatMap { at in byTime.last { $0.askedAt <= at }?.id }
                if let owner {
                    perTurn[owner, default: [:]][use.model, default: TokenCounts()] += use.counts
                }
            }
            for (id, byModel) in perTurn {
                turns[id]?.usage = ModelTokens.list(byModel)
            }
            history.sessionUsage = ModelTokens.list(all)
            history.turns = SessionHistoryReader.settle(order.compactMap { turns[$0] })
            return history
        }
    }

    /// A Claude message's usage, keyed as the token count keys it (its id and request).
    static func claudeUsage(_ line: JSON) -> (key: String, model: String, counts: TokenCounts)? {
        let message = line["message"]
        let usage = message["usage"]
        guard usage.isObject, let id = message["id"].nonEmptyString, message["model"].string != "<synthetic>" else { return nil }
        let counts = TokenCounts(
            input: usage["input_tokens"].int ?? 0, output: usage["output_tokens"].int ?? 0,
            cacheWrite: usage["cache_creation_input_tokens"].int ?? 0, cacheRead: usage["cache_read_input_tokens"].int ?? 0)
        guard counts.total > 0 else { return nil }
        return ("\(id):\(line["requestId"].string ?? "")", message["model"].nonEmptyString ?? "claude", counts)
    }

    /// A prompt typed by you, or nil for tool results, commands, meta lines,
    /// compaction summaries and the context editors attach.
    static func promptText(_ line: JSON) -> String? {
        guard line["isMeta"].bool != true, line["isCompactSummary"].bool != true else { return nil }
        let content = line["message"]["content"]
        var parts: [String] = []
        var images = 0
        if let text = content.string {
            parts = [text]
        } else {
            for part in content.array {
                switch part["type"].string {
                case "tool_result": return nil
                case "text": parts.append(part["text"].string ?? "")
                case "image": images += 1
                default: break
                }
            }
        }
        let joined = parts.joined(separator: "\n")
        for marker in ["<command-name>", "<command-message>", "<local-command-", "<bash-input>", "<bash-stdout>", "<bash-stderr>", "<user-memory-input>"]
        where joined.hasPrefix(marker) {
            return nil
        }
        var text = stripContext(joined).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            guard images > 0 else { return nil }
            text = images == 1 ? "(an image)" : "(\(images) images)"
        }
        return String(text.prefix(promptLimit))
    }

    /// A prompt's words as written, the context around them too.
    static func rawPrompt(_ line: JSON) -> String {
        let content = line["message"]["content"]
        if let text = content.string {
            return text
        }
        return content.array.filter { $0["type"].string == "text" }.compactMap { $0["text"].string }.joined(separator: "\n")
    }

    /// The selections sent with a prompt: each `<ide_selection>` block, as
    /// editors (and Agent Buddy's message box) write them: "The user selected
    /// the lines 3 to 4 from /tmp/main.rs:" then the text.
    public static func selections(in text: String) -> [PromptSelection] {
        guard text.contains("<ide_selection>") else { return [] }
        var found: [PromptSelection] = []
        var rest = text[...]
        while let open = rest.range(of: "<ide_selection>"), let close = rest.range(of: "</ide_selection>", range: open.upperBound..<rest.endIndex) {
            var inner = String(rest[open.upperBound..<close.lowerBound])
            rest = rest[close.upperBound...]
            let aside = "This may or may not be related to the current task."
            if inner.hasSuffix(aside) {
                inner = String(inner.dropLast(aside.count))
            }
            var source = "Selection"
            let lead = "The user selected "
            if inner.hasPrefix(lead), let colon = inner.range(of: ":\n") {
                source = selectionSource(String(inner[inner.index(inner.startIndex, offsetBy: lead.count)..<colon.lowerBound]))
                inner = String(inner[colon.upperBound...])
            }
            let body = inner.trimmingCharacters(in: .newlines)
            if !body.trimmingCharacters(in: .whitespaces).isEmpty {
                found.append(PromptSelection(source: source, text: body))
            }
        }
        return found
    }

    /// "the lines 3 to 4 from /tmp/main.rs" as "main.rs, lines 3–4"; "the
    /// following text in Safari (Release notes)" as "Safari · Release notes".
    static func selectionSource(_ said: String) -> String {
        let name = { (path: Substring) in (String(path) as NSString).lastPathComponent }
        if said.hasPrefix("the lines "), let from = said.range(of: " from ") {
            let span = said[said.index(said.startIndex, offsetBy: "the lines ".count)..<from.lowerBound].replacingOccurrences(of: " to ", with: "\u{2013}")
            return name(said[from.upperBound...]) + ", lines " + span
        }
        if said.hasPrefix("the following text from ") {
            return name(said.dropFirst("the following text from ".count))
        }
        if said.hasPrefix("the following text in ") {
            var app = String(said.dropFirst("the following text in ".count))
            if app.hasSuffix(")"), let open = app.range(of: " (", options: .backwards) {
                app = app[..<open.lowerBound] + " \u{00B7} " + app[open.upperBound...].dropLast()
            }
            return app
        }
        return said
    }

    /// Drops the blocks editors and Claude Code add around a prompt.
    static func stripContext(_ text: String) -> String {
        var result = text
        for tag in ["system-reminder", "ide_opened_file", "ide_selection", "ide_diagnostics", "environment_context"] {
            while let open = result.range(of: "<\(tag)>"),
                  let close = result.range(of: "</\(tag)>", range: open.upperBound..<result.endIndex) {
                result.removeSubrange(open.lowerBound..<close.upperBound)
            }
        }
        return result
    }

    static let answerLimit = 100_000

    /// An answer as written: only trimmed, and cut at 100,000 characters.
    static func answer(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text.count > answerLimit ? String(text.prefix(answerLimit)) + "…" : text
    }

    /// The latest prompt with no end is still running; an earlier one is open.
    static func settle(_ turns: [PromptTurn]) -> [PromptTurn] {
        guard let latest = turns.indices.max(by: { turns[$0].askedAt < turns[$1].askedAt }) else { return turns }
        var settled = turns
        for index in settled.indices where settled[index].endedAt == nil && settled[index].outcome == .open {
            settled[index].outcome = index == latest ? .running : .open
        }
        return settled
    }

    // MARK: - Codex

    /// A turn starts at a prompt and ends at `task_complete` (or
    /// `turn_aborted`), one after another, so the tree is a single line. Newer
    /// Codex logs the prompt and answers as completed `UserMessage` and
    /// `AgentMessage` items of a turn; older Codex as `user_message` and
    /// `agent_message` events. Both are read, and a message logged both ways counts once.
    public static func codex(lines: [JSON], sessionID: String) -> SessionHistory {
        var history = SessionHistory(agent: .codex, sessionID: sessionID)
        var turns: [PromptTurn] = []
        /// Each turn's latest prompt, and all of its prompts (one sent mid-turn adds one).
        var byTurn: [String: Int] = [:]
        var inTurn: [String: [Int]] = [:]
        var sawMeta = false
        /// Usage records by response, else token_count's running total, with the prompt then.
        var model = "codex"
        var records: [String: (owner: Int?, model: String, counts: TokenCounts)] = [:]
        var fallback: [(owner: Int?, model: String, counts: TokenCounts)] = []
        var previousTotal: TokenCounts?
        /// After an `hs.subagent` line: a sub-agent's log, whose tokens go to the
        /// prompt asked last before they were used, and nothing else counts.
        var inSubagent = false
        func latest(before at: Date?) -> Int? {
            guard let at else { return turns.isEmpty ? nil : turns.count - 1 }
            return turns.lastIndex { $0.askedAt <= at }
        }
        func delta(_ total: TokenCounts) -> TokenCounts {
            let before = previousTotal ?? TokenCounts()
            previousTotal = total
            return TokenCounts(
                input: max(total.input - before.input, 0), output: max(total.output - before.output, 0),
                cacheWrite: max(total.cacheWrite - before.cacheWrite, 0), cacheRead: max(total.cacheRead - before.cacheRead, 0))
        }

        func prompt(_ raw: String, images: Int, at: Date, turn: String?, line: Int) {
            var text = stripContext(answerText(raw) ?? raw).trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty {
                guard images > 0 else { return }
                text = images == 1 ? "(an image)" : "(\(images) images)"
            }
            text = String(text.prefix(promptLimit))
            if let last = turns.last, last.text == text,
               abs(last.askedAt.timeIntervalSince(at)) < 5 || turn.map({ byTurn[$0] == turns.count - 1 }) == true {
                return
            }
            turns.append(PromptTurn(id: "codex-\(line)", text: text, askedAt: at, parent: turns.last?.id, selections: selections(in: raw)))
            if let turn {
                byTurn[turn] = turns.count - 1
                inTurn[turn, default: []].append(turns.count - 1)
            }
        }
        /// A turn's end is every one of its prompts' end.
        func end(_ turn: String?, _ outcome: PromptTurn.Outcome, at: Date) -> Int? {
            guard let target = target(turn), turns[target].endedAt == nil else { return nil }
            for index in (turn.flatMap { inTurn[$0] } ?? [target]) where turns[index].endedAt == nil {
                turns[index].outcome = outcome
                turns[index].endedAt = at
            }
            return target
        }
        /// The prompt a turn's answer or end belongs to.
        func target(_ turn: String?) -> Int? {
            if let turn, let index = byTurn[turn] {
                return index
            }
            return turns.isEmpty ? nil : turns.count - 1
        }

        for (index, line) in lines.enumerated() {
            let type = line["type"].string ?? ""
            let payload = line["payload"]
            if type == "hs.subagent" {
                inSubagent = true
                previousTotal = nil
                continue
            }
            if inSubagent {
                let at = Dates.parse(line["timestamp"].string)
                if type == "turn_context" {
                    model = payload["model"].nonEmptyString ?? model
                } else if type == "token_usage_record", let response = payload["response_id"].nonEmptyString,
                          let counts = TokenLedger.codexCounts(payload["usage"]), counts.total > 0 {
                    records[response] = (latest(before: at), model, counts)
                } else if type == "event_msg", payload["type"].string == "token_count",
                          let total = TokenLedger.codexCounts(payload["info"]["total_token_usage"]) {
                    let used = delta(total)
                    if used.total > 0 {
                        fallback.append((latest(before: at), model, used))
                    }
                }
                continue
            }
            if type == "session_meta" {
                if !sawMeta {
                    sawMeta = true
                    history.sessionID = payload["id"].nonEmptyString ?? history.sessionID
                    history.client = payload["originator"].nonEmptyString
                    history.isSubagent = payload["source"].isObject && !payload["source"]["subagent"].isNull
                    history.gitBranch = payload["git"]["branch"].nonEmptyString
                    if let folder = payload["cwd"].nonEmptyString {
                        history.cwd = folder
                        history.folders = [folder]
                    }
                }
                continue
            }
            if type == "turn_context" {
                model = payload["model"].nonEmptyString ?? model
                history.model = payload["model"].nonEmptyString ?? history.model
                history.effort = payload["effort"].nonEmptyString ?? history.effort
                history.sandbox = payload["sandbox_policy"]["type"].nonEmptyString ?? payload["sandbox_policy"].nonEmptyString
                    ?? history.sandbox
                history.permissionProfile = payload["active_permission_profile"]["id"].nonEmptyString ?? history.permissionProfile
                // A turn sent with "never" (as Agent Buddy once did) isn't how the session asks.
                if let policy = payload["approval_policy"].nonEmptyString, policy != "never" {
                    history.approvalPolicy = policy
                }
                history.approvalsReviewer = payload["approvals_reviewer"].nonEmptyString ?? history.approvalsReviewer
                if let folder = payload["cwd"].nonEmptyString, !history.folders.contains(folder) {
                    history.folders.append(folder)
                    history.cwd = history.cwd ?? folder
                }
                continue
            }
            if type == "token_usage_record" {
                if let response = payload["response_id"].nonEmptyString, let counts = TokenLedger.codexCounts(payload["usage"]),
                   counts.total > 0 {
                    records[response] = (target(payload["turn_id"].nonEmptyString), model, counts)
                }
                continue
            }
            guard type == "event_msg", let stamped = Dates.parse(line["timestamp"].string) else { continue }
            let at = payload["completed_at_ms"].double.map { Date(timeIntervalSince1970: $0 / 1000) } ?? stamped
            let turn = payload["turn_id"].nonEmptyString
            switch payload["type"].string ?? "" {
            case "user_message":
                prompt(payload["message"].string ?? "",
                       images: payload["images"].array.count + payload["local_images"].array.count,
                       at: at, turn: turn, line: index)
            case "item_completed":
                let item = payload["item"]
                let parts = item["content"].array
                let texts = parts.compactMap { $0["text"].string }
                switch item["type"].string {
                case "UserMessage":
                    let images = parts.filter { ($0["type"].string ?? "").lowercased().contains("image") }.count
                    prompt(texts.joined(separator: "\n"), images: images, at: at, turn: turn, line: index)
                case "AgentMessage":
                    if let target = target(turn), let text = answer(texts.joined(separator: "\n\n")) {
                        turns[target].answer = text
                    }
                default:
                    continue
                }
            case "agent_message":
                guard let target = target(turn), let text = answer(payload["message"].string) else { continue }
                turns[target].answer = text
            case "task_complete":
                let error = payload["error"]
                guard let target = end(turn, error.isNull || error.string == "" ? .completed : .failed, at: at) else { continue }
                if let text = answer(payload["last_agent_message"].string) {
                    turns[target].answer = text
                }
            case "turn_aborted":
                _ = end(turn, .interrupted, at: at)
            case "token_count":
                guard let total = TokenLedger.codexCounts(payload["info"]["total_token_usage"]) else { continue }
                let used = delta(total)
                if used.total > 0 {
                    fallback.append((target(turn), model, used))
                }
            default:
                continue
            }
        }
        // A log with usage records counts those; token_count repeats the same use.
        let uses = records.isEmpty ? fallback : Array(records.values)
        var perTurn: [Int: [String: TokenCounts]] = [:]
        var all: [String: TokenCounts] = [:]
        for use in uses {
            all[use.model, default: TokenCounts()] += use.counts
            if let owner = use.owner {
                perTurn[owner, default: [:]][use.model, default: TokenCounts()] += use.counts
            }
        }
        for (index, byModel) in perTurn where turns.indices.contains(index) {
            turns[index].usage = ModelTokens.list(byModel)
        }
        history.sessionUsage = ModelTokens.list(all)
        history.turns = settle(turns)
        return history
    }

    /// Your answer to a question Codex asked, as Codex logs it
    /// (`<send_user_message_question_reply>[{"question": …, "answer": …}]`), in words.
    static func answerText(_ raw: String) -> String? {
        let tag = "<send_user_message_question_reply>"
        guard raw.hasPrefix(tag) else { return nil }
        var body = raw.dropFirst(tag.count)
        if let close = body.range(of: "</send_user_message_question_reply>") {
            body = body[..<close.lowerBound]
        }
        guard let replies = JSON.parse(String(body))?.array, !replies.isEmpty else { return nil }
        let lines = replies.compactMap { reply -> String? in
            guard let answer = reply["answer"].nonEmptyString else { return nil }
            return reply["question"].nonEmptyString.map { "Answered: \(answer)\nQuestion: \($0)" } ?? "Answered: \(answer)"
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// The thread's name from `~/.codex/session_index.jsonl`.
    static func codexThreadName(_ id: String) -> String? {
        let index = Environment.home.appendingPathComponent(".codex/session_index.jsonl")
        guard let tail = Tail.read(index, maxBytes: 2_097_152) else { return nil }
        for line in tail.lines.reversed() {
            if let entry = JSON.parse(line), entry["id"].string == id, let name = entry["thread_name"].nonEmptyString {
                return name
            }
        }
        return nil
    }

    // MARK: - Copilot

    /// A request starts at `user.message` and ends at the agentStop hook record,
    /// or at a turn end after an answer that asked for no tools.
    /// - Parameter workspace: the session's `workspace.yaml` (its name and folder).
    public static func copilot(lines: [JSON], sessionID: String, workspace: String?) -> SessionHistory {
        var history = SessionHistory(agent: .copilot, sessionID: sessionID)
        var turns: [PromptTurn] = []
        var askedForTools = true
        func end(_ outcome: PromptTurn.Outcome, _ at: Date) {
            guard !turns.isEmpty, turns[turns.count - 1].endedAt == nil else { return }
            turns[turns.count - 1].outcome = outcome
            turns[turns.count - 1].endedAt = at
        }
        for line in lines {
            let type = line["type"].string ?? ""
            let data = line["data"]
            if type == "hs.workspace" {
                history.title = data["name"].nonEmptyString ?? history.title
                history.cwd = data["cwd"].nonEmptyString ?? history.cwd
                continue
            }
            guard let at = Dates.parse(line["timestamp"].string) else { continue }
            let main = line["agentId"].isNull
            switch type {
            case "session.start":
                history.cwd = history.cwd ?? data["context"]["cwd"].nonEmptyString
                history.client = data["producer"].nonEmptyString
            case "user.message":
                guard main else { continue }
                let raw = data["content"].string ?? ""
                let text = stripContext(raw).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                turns.append(PromptTurn(
                    id: line["id"].nonEmptyString ?? "copilot-\(turns.count)", text: String(text.prefix(promptLimit)),
                    askedAt: at, parent: turns.last?.id, selections: selections(in: raw)))
                askedForTools = true
            case "assistant.message":
                guard main, !turns.isEmpty else { continue }
                if let text = answer(data["content"].string) {
                    turns[turns.count - 1].answer = text
                }
                askedForTools = !data["toolRequests"].array.isEmpty
            case "assistant.turn_end":
                if main, !askedForTools, !turns.isEmpty, turns[turns.count - 1].answer != nil {
                    end(.completed, at)
                }
            case "hook.start":
                guard main, data["hookType"].string == "agentStop" else { continue }
                switch data["input"]["stopReason"].string {
                case "end_turn": end(.completed, at)
                case "error": end(.failed, at)
                default: end(.interrupted, at)
                }
            case "abort":
                end(.interrupted, at)
            case "session.shutdown":
                // The session's totals so far; the last report wins.
                guard let metrics = data["modelMetrics"].object else { continue }
                var byModel: [String: TokenCounts] = [:]
                for (name, metric) in metrics {
                    let usage = metric["usage"]
                    let read = usage["cacheReadTokens"].int ?? 0
                    let written = usage["cacheWriteTokens"].int ?? 0
                    byModel[name] = TokenCounts(
                        input: max((usage["inputTokens"].int ?? 0) - read - written, 0), output: usage["outputTokens"].int ?? 0,
                        cacheWrite: written, cacheRead: read)
                }
                history.sessionUsage = ModelTokens.list(byModel)
                history.sessionEndedAt = at
            default:
                continue
            }
        }
        if let workspace {
            for line in workspace.split(separator: "\n") where !(line.first?.isWhitespace ?? true) {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let key = line[..<colon].trimmingCharacters(in: .whitespaces)
                var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if value.count >= 2, let quote = value.first, quote == "'" || quote == "\"", value.last == quote {
                    value = String(value.dropFirst().dropLast())
                }
                guard !value.isEmpty else { continue }
                if key == "name" {
                    history.title = value
                } else if key == "cwd" {
                    history.cwd = value
                }
            }
        }
        history.folders = history.cwd.map { [$0] } ?? []
        history.turns = settle(turns)
        return history
    }
}
