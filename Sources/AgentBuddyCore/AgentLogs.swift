import Foundation
import SQLite3

/// Where the agents watched through their logs alone keep their sessions.
public struct AgentLogRoots: Sendable {
    /// Gemini CLI: `~/.gemini/tmp/<project>/chats/session-….json` (and `.jsonl` in newer versions).
    public var gemini: URL
    /// Qwen Code: `~/.qwen/projects/<project>/chats/<session>.jsonl` (older: `~/.qwen/tmp/<hash>/chats/*.json`).
    public var qwen: URL
    /// OpenCode: its database, `opencode.db`, every session in it.
    public var openCode: URL
    /// Cursor's agent: `~/.cursor/chats/<workspace>/<chat>/store.db`.
    public var cursor: URL
    /// DeepSeek Harness: `~/.dsh/sessions/--<folder>--/<session>/session.vN.jsonl[.zstd]`.
    public var deepseek: URL

    public init(gemini: URL, qwen: URL, openCode: URL, cursor: URL, deepseek: URL) {
        self.gemini = gemini
        self.qwen = qwen
        self.openCode = openCode
        self.cursor = cursor
        self.deepseek = deepseek
    }

    public static func standard() -> AgentLogRoots {
        AgentLogRoots(
            gemini: Environment.geminiHome, qwen: Environment.qwenHome,
            openCode: Environment.openCodeData.appendingPathComponent("opencode.db"),
            cursor: Environment.cursorHome.appendingPathComponent("chats"),
            deepseek: Environment.dshHome.appendingPathComponent("sessions"))
    }

    /// The folders watched for changes.
    public var folders: [URL] {
        [gemini.appendingPathComponent("tmp"), qwen.appendingPathComponent("projects"), qwen.appendingPathComponent("tmp"),
         openCode.deletingLastPathComponent(), cursor, deepseek]
    }
}

/// One session of an agent watched through its log: its prompts (the history)
/// and the tokens of each reply, as the token count keeps them.
public struct AgentLogSession: Sendable {
    public var history: SessionHistory
    /// Each reply's tokens, by a key unique in the session.
    public var tokens: [String: TokenEntry]

    public init(history: SessionHistory, tokens: [String: TokenEntry]) {
        self.history = history
        self.tokens = tokens
    }
}

/// Gemini CLI, Qwen Code, OpenCode, Cursor's agent and DeepSeek Harness: each
/// session read whole into the same shape as the others' (its prompts, each
/// with its answer, when it ended and how, and its tokens by model).
public enum AgentLogs {
    // MARK: - Finding sessions

    /// The sessions written since `since`: each one's agent, its path (for
    /// OpenCode, its database, "#" and the session's id) and when it changed.
    public static func sessions(since: Date, roots: AgentLogRoots = .standard()) -> [(agent: Agent, path: String, modified: Date)] {
        var found: [(Agent, String, Date)] = []
        func walk(_ root: URL, _ agent: Agent, depth: Int, _ accept: (URL) -> Bool) {
            guard let walker = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey], options: [])
            else { return }
            while let url = walker.nextObject() as? URL {
                if walker.level > depth {
                    walker.skipDescendants()
                    continue
                }
                guard accept(url), let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                      values.isRegularFile == true, let modified = values.contentModificationDate, modified >= since
                else { continue }
                found.append((agent, url.path, modified))
            }
        }
        walk(roots.gemini.appendingPathComponent("tmp"), .gemini, depth: 3) { isChat($0) }
        walk(roots.qwen.appendingPathComponent("projects"), .qwen, depth: 3) { $0.pathExtension == "jsonl" && $0.deletingLastPathComponent().lastPathComponent == "chats" }
        walk(roots.qwen.appendingPathComponent("tmp"), .qwen, depth: 3) { isChat($0) }
        walk(roots.cursor, .cursor, depth: 3) { $0.lastPathComponent == "store.db" }
        // Harness: each session's newest log.
        var newest: [String: (version: Int, path: String, modified: Date)] = [:]
        walk(roots.deepseek, .deepseek, depth: 3) { harnessVersion($0) != nil }
        found.removeAll { entry in
            guard entry.0 == .deepseek, let version = harnessVersion(URL(fileURLWithPath: entry.1)) else { return false }
            let folder = (entry.1 as NSString).deletingLastPathComponent
            if let kept = newest[folder], kept.version >= version {
                return true
            }
            newest[folder] = (version, entry.1, entry.2)
            return false
        }
        found.removeAll { entry in
            entry.0 == .deepseek && newest[(entry.1 as NSString).deletingLastPathComponent]?.path != entry.1
        }
        found += openCodeSessions(since: since, database: roots.openCode).map { (.opencode, $0.path, $0.modified) }
        return found.map { (agent: $0.0, path: $0.1, modified: $0.2) }
    }

    static func isChat(_ url: URL) -> Bool {
        url.deletingLastPathComponent().lastPathComponent == "chats" && ["json", "jsonl"].contains(url.pathExtension)
    }

    /// A Harness log's format version: `session.v3.jsonl.zstd` → 3, `session.jsonl` → 0.
    static func harnessVersion(_ url: URL) -> Int? {
        let name = url.lastPathComponent
        guard name.hasPrefix("session."), name.hasSuffix(".jsonl") || name.hasSuffix(".jsonl.zstd") else { return nil }
        let middle = name.dropFirst("session.".count).split(separator: ".").first.map(String.init) ?? ""
        if middle == "jsonl" {
            return 0
        }
        return middle.hasPrefix("v") ? Int(middle.dropFirst()) : nil
    }

    /// A session's log, by its id, in the agent's folders.
    public static func locate(agent: Agent, sessionID: String, roots: AgentLogRoots = .standard()) -> String? {
        if agent == .opencode {
            return FileManager.default.fileExists(atPath: roots.openCode.path) ? "\(roots.openCode.path)#\(sessionID)" : nil
        }
        return sessions(since: .distantPast, roots: roots).first { entry in
            entry.agent == agent && (entry.path.contains(sessionID) || (try? read(agent: agent, path: entry.path).get().history.sessionID) == sessionID)
        }?.path
    }

    // MARK: - Reading

    /// A session, whole.
    public static func read(agent: Agent, path: String) -> Result<AgentLogSession, ReadError> {
        switch agent {
        case .opencode:
            let parts = path.components(separatedBy: "#")
            guard parts.count == 2 else { return .failure(ReadError("That isn't one of OpenCode's sessions.")) }
            return openCode(database: parts[0], session: parts[1])
        case .cursor:
            return cursor(database: path)
        case .deepseek:
            return harnessText(path).map { harness(text: $0, path: path) }
        case .gemini, .qwen:
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
                return .failure(ReadError("The session log isn't there anymore."))
            }
            if path.hasSuffix(".json"), let object = JSON.parse(data) {
                return .success(geminiJSON(object, agent: agent, path: path))
            }
            let lines = SessionHistoryReader.lines(data)
            return .success(agent == .qwen ? qwen(lines: lines, path: path) : geminiJSONL(lines, path: path))
        default:
            return .failure(ReadError("Not one of the agents watched through their logs."))
        }
    }

    // MARK: - One shape for all

    /// What a log says happened, in order: a prompt, a reply (with its model and
    /// tokens; `last` when it asks for nothing more), or the turn's end.
    enum Mark {
        case prompt(id: String, text: String)
        case reply(id: String, text: String, model: String?, counts: TokenCounts?, last: Bool)
        case end(PromptTurn.Outcome)
    }

    /// The turns, from the marks, and each reply's tokens.
    static func assemble(
        _ marks: [(at: Date, mark: Mark)], agent: Agent, sessionID: String, explicitEnds: Bool
    ) -> (turns: [PromptTurn], tokens: [String: TokenEntry]) {
        var turns: [PromptTurn] = []
        var tokens: [String: TokenEntry] = [:]
        var usage: [String: TokenCounts] = [:]
        func close(_ outcome: PromptTurn.Outcome, at: Date) {
            guard var turn = turns.last, turn.endedAt == nil || !explicitEnds else { return }
            turn.endedAt = at
            turn.outcome = outcome
            turns[turns.count - 1] = turn
        }
        func settleUsage() {
            guard var turn = turns.last else { return }
            turn.usage = usage.map { ModelTokens(model: $0.key, counts: $0.value) }.sorted { $0.model < $1.model }
            turns[turns.count - 1] = turn
        }
        for (at, mark) in marks {
            switch mark {
            case .prompt(let id, let text):
                if var last = turns.last, last.endedAt == nil {
                    last.outcome = .open
                    turns[turns.count - 1] = last
                }
                usage = [:]
                turns.append(PromptTurn(id: id, text: text, askedAt: at, parent: turns.last?.id, outcome: .running))
            case .reply(let id, let text, let model, let counts, let last):
                if let counts, counts.input + counts.output + counts.cacheRead + counts.cacheWrite > 0 {
                    let name = model ?? agent.clientName
                    tokens["\(sessionID)/\(id)"] = TokenEntry(agent: agent, model: name, at: at, counts: counts)
                    if !turns.isEmpty {
                        usage[name, default: TokenCounts()] += counts
                        settleUsage()
                    }
                }
                guard var turn = turns.last else { continue }
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    turn.answer = text
                }
                turns[turns.count - 1] = turn
                if last, !explicitEnds {
                    close(.completed, at: at)
                } else if !last, !explicitEnds, turn.endedAt != nil {
                    // More work after what looked like the end: still going.
                    turn.endedAt = nil
                    turn.outcome = .running
                    turns[turns.count - 1] = turn
                }
            case .end(let outcome):
                close(outcome, at: at)
            }
        }
        return (turns, tokens)
    }

    /// The text of a list of parts: `[{text}]`, `[{type: "text", text}]`, or a string.
    static func text(_ value: JSON) -> String {
        if let string = value.string {
            return string
        }
        return value.array.compactMap { part -> String? in
            if let kind = part["type"].string, kind != "text", kind != "output_text" { return nil }
            if part["thought"].bool == true { return nil }
            return part["text"].string
        }.joined(separator: "\n")
    }

    /// Typed words the model is asked: not a slash command (the CLI runs it) or `exit`.
    static func isPrompt(_ typed: String) -> Bool {
        let words = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        return !words.isEmpty && !words.hasPrefix("/") && !["exit", "quit"].contains(words.lowercased())
    }

    static func title(_ turns: [PromptTurn]) -> String? {
        turns.first.flatMap { TextTools.condensed($0.text, limit: 80) }
    }

    // MARK: - Gemini CLI

    /// Gemini CLI's session file before the JSONL change: one object, rewritten as it goes.
    static func geminiJSON(_ object: JSON, agent: Agent, path: String) -> AgentLogSession {
        geminiSession(meta: object, messages: object["messages"].array, agent: agent, path: path)
    }

    /// Newer Gemini CLI's: a metadata line, then messages, later patched (`$patch`) or cut back (`$rewindTo`).
    static func geminiJSONL(_ lines: [JSON], path: String) -> AgentLogSession {
        var meta = JSON([:] as [String: Any])
        var order: [String] = []
        var messages: [String: [String: Any]] = [:]
        func patch(_ change: JSON) {
            guard let id = change["id"].string, var message = messages[id], let fields = change.object else { return }
            for (key, value) in fields where key != "id" {
                if key == "toolCalls", let calls = message["toolCalls"] as? [[String: Any]] {
                    // Results land on the calls already there.
                    var merged = calls
                    for update in value.array {
                        if let index = merged.firstIndex(where: { ($0["id"] as? String) == update["id"].string }), let result = update.object {
                            for (field, value) in result {
                                merged[index][field] = value.raw
                            }
                        }
                    }
                    message["toolCalls"] = merged
                } else {
                    message[key] = value.raw
                }
            }
            messages[id] = message
        }
        for line in lines {
            if let rewind = line["$rewindTo"].string {
                if let index = order.firstIndex(of: rewind) {
                    for id in order[index...] {
                        messages[id] = nil
                    }
                    order.removeSubrange(index...)
                } else {
                    order.removeAll()
                    messages.removeAll()
                }
            } else if !line["$patch"].isNull {
                let change = line["$patch"]
                patch(change)
                change["updates"].array.forEach(patch)
                for removed in change["removeIds"].array.compactMap(\.string) {
                    messages[removed] = nil
                    order.removeAll { $0 == removed }
                }
            } else if let id = line["id"].string, let object = line.object?.compactMapValues(\.raw) {
                if messages[id] == nil {
                    order.append(id)
                }
                messages[id] = object
            } else if line["sessionId"].string != nil {
                meta = line
            }
        }
        return geminiSession(meta: meta, messages: order.compactMap { messages[$0].map(JSON.init) }, agent: .gemini, path: path)
    }

    static func geminiSession(meta: JSON, messages: [JSON], agent: Agent, path: String) -> AgentLogSession {
        let url = URL(fileURLWithPath: path)
        let sessionID = meta["sessionId"].nonEmptyString ?? url.deletingPathExtension().lastPathComponent
        var marks: [(Date, Mark)] = []
        var model: String?
        for message in messages {
            guard let at = Dates.parse(message["timestamp"].string) else { continue }
            let id = message["id"].string ?? "\(marks.count)"
            switch message["type"].string {
            case "user":
                let typed = text(message["content"])
                guard isPrompt(typed) else { continue }
                marks.append((at, .prompt(id: id, text: typed)))
            case "gemini":
                model = message["model"].nonEmptyString ?? model
                let tokens = message["tokens"]
                var counts: TokenCounts?
                if !tokens.isNull {
                    let cached = tokens["cached"].int ?? 0
                    counts = TokenCounts(
                        input: max(0, (tokens["input"].int ?? 0) - cached) + (tokens["tool"].int ?? 0),
                        output: (tokens["output"].int ?? 0) + (tokens["thoughts"].int ?? 0), cacheRead: cached)
                }
                // A reply that called tools is followed by more; one without is the turn's last.
                let calls = message["toolCalls"].array
                let pending = calls.contains { $0["result"].isNull && $0["status"].string != "cancelled" }
                marks.append((at, .reply(id: id, text: text(message["content"]), model: message["model"].nonEmptyString ?? model,
                                         counts: counts, last: calls.isEmpty && !pending)))
            case "error":
                marks.append((at, .end(.failed)))
            default:
                continue
            }
        }
        let (turns, tokens) = assemble(marks, agent: agent, sessionID: sessionID, explicitEnds: false)
        var history = SessionHistory(agent: agent, sessionID: sessionID, title: title(turns), cwd: projectFolder(agent, of: url),
                                     client: agent == .gemini ? "gemini-cli" : "qwen-code", turns: turns)
        history.folders = history.cwd.map { [$0] } ?? []
        history.model = model
        history.logPath = path
        history.isSubagent = meta["kind"].string == "subagent"
        return AgentLogSession(history: history, tokens: tokens)
    }

    /// The project a Gemini session's folder is for, from `projects.json`'s list.
    static func projectFolder(_ agent: Agent, of file: URL) -> String? {
        let project = file.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
        let home = agent == .gemini ? Environment.geminiHome : Environment.qwenHome
        guard let data = try? Data(contentsOf: home.appendingPathComponent("projects.json")),
              let projects = JSON.parse(data)?["projects"].object
        else { return nil }
        return projects.first { $0.value.string == project }?.key
    }

    // MARK: - Qwen Code

    /// Qwen Code's JSONL: records with a type (user, assistant, tool_result,
    /// system), Gemini-style `message` parts and `usageMetadata`, and a
    /// `turn_result` system record when a turn ends.
    static func qwen(lines: [JSON], path: String) -> AgentLogSession {
        let url = URL(fileURLWithPath: path)
        var sessionID = url.deletingPathExtension().lastPathComponent
        var marks: [(Date, Mark)] = []
        var cwd: String?
        var model: String?
        var named: String?
        var subagent = false
        let explicit = lines.contains { $0["subtype"].string == "turn_result" }
        for line in lines {
            guard let at = Dates.parse(line["timestamp"].string) else { continue }
            sessionID = line["sessionId"].nonEmptyString ?? sessionID
            cwd = cwd ?? line["cwd"].nonEmptyString
            if line["isSidechain"].bool == true {
                subagent = true
                continue
            }
            let id = line["uuid"].string ?? "\(marks.count)"
            switch (line["type"].string, line["subtype"].string) {
            case ("user", nil):
                let typed = text(line["message"]["parts"])
                guard isPrompt(typed) else { continue }
                marks.append((at, .prompt(id: id, text: typed)))
            case ("assistant", _):
                model = line["model"].nonEmptyString ?? model
                let usage = line["usageMetadata"]
                var counts: TokenCounts?
                if !usage.isNull {
                    let cached = usage["cachedContentTokenCount"].int ?? 0
                    counts = TokenCounts(
                        input: max(0, (usage["promptTokenCount"].int ?? 0) - cached),
                        output: (usage["candidatesTokenCount"].int ?? 0) + (usage["thoughtsTokenCount"].int ?? 0), cacheRead: cached)
                }
                let parts = line["message"]["parts"].array
                let calls = parts.contains { !$0["functionCall"].isNull }
                marks.append((at, .reply(id: id, text: text(line["message"]["parts"]), model: line["model"].nonEmptyString ?? model,
                                         counts: counts, last: !calls)))
            case ("system", "turn_result"):
                let payload = line["systemPayload"]
                let ended = payload["endedAt"].double.map { Date(timeIntervalSince1970: $0 / 1000) } ?? at
                let outcome: PromptTurn.Outcome
                switch payload["state"].string {
                case "cancelled": outcome = .interrupted
                case "error": outcome = .failed
                default: outcome = .completed
                }
                marks.append((ended, .end(outcome)))
            case ("system", "custom_title"):
                named = line["systemPayload"]["title"].nonEmptyString ?? line["systemPayload"]["customTitle"].nonEmptyString ?? named
            default:
                continue
            }
        }
        let (turns, tokens) = assemble(marks, agent: .qwen, sessionID: sessionID, explicitEnds: explicit)
        var history = SessionHistory(agent: .qwen, sessionID: sessionID, title: named ?? title(turns), cwd: cwd, client: "qwen-code", turns: turns)
        history.folders = cwd.map { [$0] } ?? []
        history.model = model
        history.logPath = path
        history.isSubagent = subagent && turns.isEmpty
        return AgentLogSession(history: history, tokens: tokens)
    }

    // MARK: - OpenCode

    /// OpenCode's sessions changed since a date, from its database.
    static func openCodeSessions(since: Date, database: URL) -> [(path: String, modified: Date)] {
        guard let db = SQLiteReader(path: database.path), db.tables.contains("session") else { return [] }
        let after = Int64(since.timeIntervalSince1970 * 1000)
        return db.rows("SELECT id, time_updated FROM session WHERE time_updated >= ?", [after]).compactMap { row in
            guard let id = row["id"] as? String, let updated = row["time_updated"] as? Int64 else { return nil }
            return ("\(database.path)#\(id)", Date(timeIntervalSince1970: Double(updated) / 1000))
        }
    }

    /// One OpenCode session: its messages, each with its parts (the text) and,
    /// for a reply, its tokens and whether it called tools (more follows) or stopped.
    static func openCode(database: String, session: String) -> Result<AgentLogSession, ReadError> {
        guard let db = SQLiteReader(path: database) else { return .failure(ReadError("OpenCode's database isn't there anymore.")) }
        guard let row = db.rows("SELECT * FROM session WHERE id = ?", [session]).first else {
            return .failure(ReadError("That OpenCode session isn't there anymore."))
        }
        var texts: [String: [String]] = [:]
        for part in db.rows("SELECT message_id, data FROM part WHERE session_id = ? ORDER BY time_created, id", [session]) {
            guard let message = part["message_id"] as? String, let data = (part["data"] as? String).flatMap({ JSON.parse(Data($0.utf8)) }),
                  data["type"].string == "text", data["synthetic"].bool != true, let text = data["text"].string
            else { continue }
            texts[message, default: []].append(text)
        }
        var marks: [(Date, Mark)] = []
        var model: String?
        for message in db.rows("SELECT id, time_created, data FROM message WHERE session_id = ? ORDER BY time_created, id", [session]) {
            guard let id = message["id"] as? String, let created = message["time_created"] as? Int64,
                  let data = (message["data"] as? String).flatMap({ JSON.parse(Data($0.utf8)) })
            else { continue }
            let at = Date(timeIntervalSince1970: Double(created) / 1000)
            let said = (texts[id] ?? []).joined(separator: "\n")
            if data["role"].string == "user" {
                guard !said.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                marks.append((at, .prompt(id: id, text: said)))
                continue
            }
            let name = data["modelID"].nonEmptyString
            model = name ?? model
            let tokens = data["tokens"]
            let counts = tokens.isNull ? nil : TokenCounts(
                input: tokens["input"].int ?? 0, output: (tokens["output"].int ?? 0) + (tokens["reasoning"].int ?? 0),
                cacheWrite: tokens["cache"]["write"].int ?? 0, cacheRead: tokens["cache"]["read"].int ?? 0)
            let completed = data["time"]["completed"].double.map { Date(timeIntervalSince1970: $0 / 1000) }
            let finish = data["finish"].string
            marks.append((completed ?? at, .reply(id: id, text: said, model: name, counts: counts,
                                                  last: completed != nil && finish != "tool-calls" && finish != "unknown")))
            if !data["error"].isNull {
                marks.append((completed ?? at, .end(data["error"]["name"].string == "MessageAbortedError" ? .interrupted : .failed)))
            }
        }
        let (turns, tokens) = assemble(marks, agent: .opencode, sessionID: session, explicitEnds: false)
        let folder = row["directory"] as? String
        var history = SessionHistory(agent: .opencode, sessionID: session, title: (row["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? title(turns),
                                     cwd: folder, client: "opencode", turns: turns)
        history.folders = folder.map { [$0] } ?? []
        history.model = model
        history.logPath = "\(database)#\(session)"
        history.isSubagent = (row["parent_id"] as? String) != nil
        return .success(AgentLogSession(history: history, tokens: tokens))
    }

    // MARK: - Cursor's agent

    /// Cursor's agent keeps each chat in a SQLite store of its own, its layout
    /// unpublished. Read as best it can be: its messages (JSON with a `role`), in
    /// the order written, and its name and model from `meta`. It records no
    /// times or tokens per message: a chat's last change dates its last answer.
    static func cursor(database: String) -> Result<AgentLogSession, ReadError> {
        guard let db = SQLiteReader(path: database) else { return .failure(ReadError("Cursor's chat isn't there anymore.")) }
        let modified = (try? FileManager.default.attributesOfItem(atPath: database))?[.modificationDate] as? Date ?? Date()
        var meta = JSON([:] as [String: Any])
        if db.tables.contains("meta") {
            for row in db.rows("SELECT value FROM meta", []) {
                // Stored as JSON, or as hexadecimal of it.
                var text = (row["value"] as? String) ?? ((row["value"] as? Data).map { String(decoding: $0, as: UTF8.self) } ?? "")
                if !text.hasPrefix("{"), text.count % 2 == 0, text.allSatisfy(\.isHexDigit) {
                    var bytes = Data()
                    var index = text.startIndex
                    while index < text.endIndex {
                        let next = text.index(index, offsetBy: 2)
                        bytes.append(UInt8(text[index..<next], radix: 16) ?? 0)
                        index = next
                    }
                    text = String(decoding: bytes, as: UTF8.self)
                }
                if let parsed = JSON.parse(Data(text.utf8)), parsed.isObject {
                    meta = parsed
                }
            }
        }
        let created = meta["createdAt"].double.map { Date(timeIntervalSince1970: $0 > 1e12 ? $0 / 1000 : $0) } ?? modified
        var said: [(role: String, text: String, id: String)] = []
        if db.tables.contains("blobs") {
            for row in db.rows("SELECT rowid AS position, id, data FROM blobs ORDER BY rowid", []) {
                guard let data = row["data"] as? Data ?? (row["data"] as? String).map({ Data($0.utf8) }),
                      let message = JSON.parse(data), let role = message["role"].string
                else { continue }
                let content = text(message["content"])
                guard role == "user" || role == "assistant", !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                said.append((role, content, (row["id"] as? String) ?? "\(said.count)"))
            }
        }
        var marks: [(Date, Mark)] = []
        for (index, message) in said.enumerated() {
            // No times: the first prompt at the chat's start, the rest by the store's last change.
            let at = index == 0 ? created : modified
            if message.role == "user" {
                marks.append((at, .prompt(id: message.id, text: Self.cursorPrompt(message.text))))
            } else {
                marks.append((at, .reply(id: message.id, text: message.text, model: meta["lastUsedModel"].nonEmptyString, counts: nil,
                                         last: index == said.count - 1 || said[index + 1].role == "user")))
            }
        }
        let chat = URL(fileURLWithPath: database).deletingLastPathComponent().lastPathComponent
        let (turns, tokens) = assemble(marks, agent: .cursor, sessionID: chat, explicitEnds: false)
        var history = SessionHistory(agent: .cursor, sessionID: meta["agentId"].nonEmptyString ?? chat,
                                     title: meta["name"].nonEmptyString ?? title(turns), client: "cursor-agent", turns: turns)
        history.model = meta["lastUsedModel"].nonEmptyString
        history.logPath = database
        return .success(AgentLogSession(history: history, tokens: tokens))
    }

    /// Cursor wraps a typed prompt in `<user_query>`: the words inside.
    static func cursorPrompt(_ text: String) -> String {
        guard let open = text.range(of: "<user_query>"), let close = text.range(of: "</user_query>", range: open.upperBound..<text.endIndex) else {
            return text
        }
        return text[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - DeepSeek Harness

    /// A Harness log's lines: as written, or (its default) out of Zstandard
    /// frames, which only Node (which Harness runs on) undoes here.
    static func harnessText(_ path: String) -> Result<String, ReadError> {
        guard path.hasSuffix(".zstd") else {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return .failure(ReadError("The session log isn't there anymore.")) }
            return .success(String(decoding: data, as: UTF8.self))
        }
        guard let node = Executables.find("node") else {
            return .failure(ReadError("DeepSeek Harness compresses its sessions with Zstandard, which Agent Buddy reads with Node, and Node isn't installed."))
        }
        // Harness writes a frame a batch, one after another, and Node's decoder stops
        // at a frame's end: each is undone in turn, from its magic number (a piece
        // that fails is joined to the next and tried again), a torn last one left out.
        let script = """
        const zlib = require('zlib'), fs = require('fs');
        const data = fs.readFileSync(process.argv[1]);
        const magic = Buffer.from([0x28, 0xb5, 0x2f, 0xfd]);
        const starts = [];
        for (let i = data.indexOf(magic); i !== -1; i = data.indexOf(magic, i + 1)) starts.push(i);
        const out = [];
        let i = 0;
        while (i < starts.length) {
          let next = -1;
          for (let j = i + 1; j <= starts.length; j++) {
            try { out.push(zlib.zstdDecompressSync(data.subarray(starts[i], j < starts.length ? starts[j] : data.length))); next = j; break; } catch (e) {}
          }
          if (next < 0) break;
          i = next;
        }
        process.stdout.write(Buffer.concat(out));
        """
        guard let result = ProcessRunner.run(node, ["-e", script, path], timeout: 20), result.status == 0 else {
            return .failure(ReadError("Node couldn't read that DeepSeek Harness session (Zstandard needs Node 22.15 or later)."))
        }
        return .success(String(decoding: result.output, as: UTF8.self))
    }

    /// A Harness session: a `session` header line, then one event a line,
    /// `{type, seq, time, data}`: `turn/start`, `user/message`,
    /// `assistant/message` (with its `usage`), `tool/call`, `turn/end` (with its reason).
    static func harness(text: String, path: String) -> AgentLogSession {
        let lines = text.split(separator: "\n").compactMap { JSON.parse(Data($0.utf8)) }
        let header = lines.first { $0["type"].string == "session" } ?? JSON([:] as [String: Any])
        let sessionID = header["id"].nonEmptyString ?? URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent
        // A forked session starts with its parent's events, up to its seed's end.
        var events = Array(lines.drop { $0["type"].string == "session" })
        if header["isSeeded"].bool == true, let seed = events.lastIndex(where: { $0["type"].string == "session/end-seed" }) {
            events = Array(events[(seed + 1)...])
        }
        var marks: [(Date, Mark)] = []
        var model: String?
        var named: String?
        for event in events {
            guard let time = event["time"].double else { continue }
            let at = Date(timeIntervalSince1970: time / 1000)
            let data = event["data"]
            let id = "\(event["seq"].int ?? marks.count)"
            switch event["type"].string {
            case "user/message":
                guard data["source"]["kind"].string == "user" else { continue }
                let typed = Self.text(data["content"])
                guard !typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                marks.append((at, .prompt(id: id, text: typed)))
            case "assistant/message":
                let source = data["message"]["source"]
                let name = source["model"].nonEmptyString ?? source["modelId"].nonEmptyString ?? source["route"].nonEmptyString
                model = name ?? model
                let usage = data["usage"]
                var counts: TokenCounts?
                if !usage.isNull {
                    // Its input is what wasn't read from the cache already (total = input + output + cache read).
                    counts = TokenCounts(input: usage["inputTokens"].int ?? 0, output: usage["outputTokens"].int ?? 0,
                                         cacheWrite: usage["cacheWriteTokens"].int ?? 0, cacheRead: usage["cacheReadTokens"].int ?? 0)
                }
                marks.append((at, .reply(id: id, text: Self.text(data["message"]["content"]), model: name ?? model, counts: counts, last: false)))
            case "turn/end":
                let outcome: PromptTurn.Outcome
                switch data["reason"]["kind"].string {
                case "aborted": outcome = .interrupted
                case "error", "blocked": outcome = .failed
                default: outcome = .completed
                }
                marks.append((at, .end(outcome)))
            case "session/title":
                named = data["title"].nonEmptyString ?? data.string ?? named
            default:
                continue
            }
        }
        let (turns, tokens) = assemble(marks, agent: .deepseek, sessionID: sessionID, explicitEnds: true)
        let folder = header["cwd"].nonEmptyString
        var history = SessionHistory(agent: .deepseek, sessionID: sessionID, title: named ?? title(turns), cwd: folder, client: "dsh", turns: turns)
        history.folders = folder.map { [$0] } ?? []
        history.model = model
        history.logPath = path
        history.isSubagent = header["origin"].string == "subagent"
        return AgentLogSession(history: history, tokens: tokens)
    }
}

/// A SQLite database opened to read, while its agent may be writing it.
final class SQLiteReader {
    private var db: OpaquePointer?

    init?(path: String) {
        guard FileManager.default.fileExists(atPath: path),
              sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK
        else {
            sqlite3_close(db)
            return nil
        }
        sqlite3_busy_timeout(db, 2000)
    }

    deinit {
        sqlite3_close(db)
    }

    lazy var tables: Set<String> = Set(rows("SELECT name FROM sqlite_master WHERE type = 'table'", []).compactMap { $0["name"] as? String })

    /// Each row as column → Int64, Double, String, Data (or nil).
    func rows(_ sql: String, _ bindings: [Any]) -> [[String: Any]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in bindings.enumerated() {
            let position = Int32(index + 1)
            switch value {
            case let number as Int64: sqlite3_bind_int64(statement, position, number)
            case let number as Int: sqlite3_bind_int64(statement, position, Int64(number))
            case let text as String: sqlite3_bind_text(statement, position, text, -1, transient)
            default: sqlite3_bind_null(statement, position)
            }
        }
        var rows: [[String: Any]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            var row: [String: Any] = [:]
            for column in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, column))
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER: row[name] = sqlite3_column_int64(statement, column)
                case SQLITE_FLOAT: row[name] = sqlite3_column_double(statement, column)
                case SQLITE_TEXT: row[name] = String(cString: sqlite3_column_text(statement, column))
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(statement, column))
                    row[name] = count > 0 ? Data(bytes: sqlite3_column_blob(statement, column), count: count) : Data()
                default: break
                }
            }
            rows.append(row)
        }
        return rows
    }
}
