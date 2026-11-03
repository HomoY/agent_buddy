import Foundation

/// One thing an agent did in a turn, as its terminal shows it after a ●: what it
/// wrote, a tool it ran, or a file it changed.
public struct TurnStep: Equatable, Sendable, Codable {
    public enum Kind: String, Sendable, Codable {
        /// It wrote this (Markdown).
        case said
        /// It ran a tool: `text` names it and what on, "Bash(swift build)".
        case ran
        /// It changed a file: `text` names it, "Update(Sources/main.swift)", and `hunks` show how.
        case changed
    }

    public var kind: Kind
    public var text: String
    /// What came of it, in a line: "Read 120 lines", "1 addition, 1 removal", an error.
    public var outcome: String?
    /// What it printed or returned, shown when you open it.
    public var output: String?
    public var failed: Bool
    public var hunks: [DiffHunk]

    public init(kind: Kind, text: String, outcome: String? = nil, output: String? = nil, failed: Bool = false, hunks: [DiffHunk] = []) {
        self.kind = kind
        self.text = text
        self.outcome = outcome
        self.output = output
        self.failed = failed
        self.hunks = hunks
    }

    /// Lines added and removed.
    public var changes: (added: Int, removed: Int) {
        hunks.reduce((0, 0)) { total, hunk in
            (total.0 + hunk.lines.filter { $0.hasPrefix("+") }.count, total.1 + hunk.lines.filter { $0.hasPrefix("-") }.count)
        }
    }
}

/// Part of a change to a file, as a unified diff has it: lines kept (" "),
/// removed ("-") and added ("+"), from line `oldStart` of the old file and
/// `newStart` of the new (0 when not known).
public struct DiffHunk: Equatable, Sendable, Codable {
    public var oldStart: Int
    public var newStart: Int
    public var lines: [String]

    public init(oldStart: Int, newStart: Int, lines: [String]) {
        self.oldStart = oldStart
        self.newStart = newStart
        self.lines = lines
    }

    /// Most lines kept of one change; the rest are counted, not kept.
    static let lineLimit = 400

    /// A unified diff's hunks ("@@ -6,2 +6,3 @@" and the lines under each), as
    /// Codex logs a file's change; file headers and "\ No newline" notes left out.
    public static func parse(unified diff: String) -> [DiffHunk] {
        var hunks: [DiffHunk] = []
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("@@") {
                func start(_ sign: Character) -> Int {
                    let field = line.split(separator: " ").first { $0.first == sign }
                    return field.flatMap { Int($0.dropFirst().split(separator: ",").first ?? "") } ?? 0
                }
                hunks.append(DiffHunk(oldStart: start("-"), newStart: start("+"), lines: []))
            } else if !hunks.isEmpty, let first = line.first, first == " " || first == "+" || first == "-" {
                hunks[hunks.count - 1].lines.append(String(line))
            } else if !hunks.isEmpty, line.isEmpty {
                // An empty kept line, written without its space.
                hunks[hunks.count - 1].lines.append(" ")
            }
        }
        // A diff's last line break leaves an empty line that isn't one.
        if var last = hunks.last, last.lines.last == " " {
            last.lines.removeLast()
            hunks[hunks.count - 1] = last
        }
        return hunks
    }

    /// Codex's own patch ("*** Update File: path", "@@", "-old", "+new"): each
    /// file's action and lines, with no line numbers.
    public static func parse(patch: String) -> [(action: String, path: String, hunks: [DiffHunk])] {
        var files: [(action: String, path: String, hunks: [DiffHunk])] = []
        for line in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("*** ") {
                for (marker, action) in [("*** Update File: ", "Update"), ("*** Add File: ", "Write"), ("*** Delete File: ", "Delete")]
                where line.hasPrefix(marker) {
                    files.append((action, String(line.dropFirst(marker.count)), [DiffHunk(oldStart: 0, newStart: 0, lines: [])]))
                }
            } else if line.hasPrefix("@@"), !files.isEmpty {
                if !(files[files.count - 1].hunks.last?.lines.isEmpty ?? true) {
                    files[files.count - 1].hunks.append(DiffHunk(oldStart: 0, newStart: 0, lines: []))
                }
            } else if !files.isEmpty, let first = line.first, first == " " || first == "+" || first == "-" {
                let file = files.count - 1
                files[file].hunks[files[file].hunks.count - 1].lines.append(String(line))
            }
        }
        return files.map { ($0.action, $0.path, $0.hunks.filter { !$0.lines.isEmpty }) }
    }

    /// At most `lineLimit` lines in all, and how many were left out.
    static func limited(_ hunks: [DiffHunk]) -> (hunks: [DiffHunk], left: Int) {
        var kept: [DiffHunk] = []
        var room = lineLimit
        var left = 0
        for hunk in hunks {
            if room <= 0 {
                left += hunk.lines.count
                continue
            }
            var part = hunk
            if hunk.lines.count > room {
                part.lines = Array(hunk.lines.prefix(room))
                left += hunk.lines.count - room
            }
            room -= part.lines.count
            kept.append(part)
        }
        return (kept, left)
    }
}

extension SessionHistoryReader {
    /// Most steps kept of a turn: the latest.
    static let stepLimit = 600

    /// What the agent did in one turn, step by step, from the session's lines:
    /// the turn's prompt line and those after it (all of the log, or what a
    /// server sent back). Copilot's turns have none.
    public static func steps(agent: Agent, lines: [JSON], turn: PromptTurn, cwd: String?) -> [TurnStep] {
        let steps: [TurnStep]
        switch agent {
        case .claude: steps = claudeSteps(lines, turn: turn.id, cwd: cwd)
        case .codex: steps = codexSteps(lines, turn: turn, cwd: cwd)
        default: steps = []  // Copilot's, and the agents watched through their logs alone: their answer shows.
        }
        return limited(steps)
    }

    /// The latest `stepLimit` steps, after a line saying how many earlier ones aren't shown.
    static func limited(_ steps: [TurnStep]) -> [TurnStep] {
        guard steps.count > stepLimit else { return steps }
        let left = steps.count - stepLimit
        return [TurnStep(kind: .said, text: "*\(left) earlier steps aren't shown.*")] + steps.suffix(stepLimit)
    }

    /// The local log, read from the turn's prompt on. Nil if the log is gone.
    /// - Parameter reading: the turn as read before, to read on from there (Claude Code's).
    public static func steps(agent: Agent, path: String, turn: PromptTurn, cwd: String?, reading: StepsReading? = nil) -> [TurnStep]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped) else { return nil }
        var from = data.startIndex
        if agent == .claude {
            // The prompt's line on: a long log's earlier turns aren't parsed. Where
            // it starts is kept: a turn at work is read again and again.
            let mark = Data("\"uuid\":\"\(turn.id)\"".utf8)
            let key = path + "|" + turn.id
            if let known = promptLines.offset(key), known < data.count, known == 0 || data[known - 1] == 0x0A,
               data.range(of: mark, in: known..<(data[known...].firstIndex(of: 0x0A) ?? data.count)) != nil {
                from = known
            } else if let found = data.range(of: mark) {
                from = data[..<found.lowerBound].lastIndex(of: 0x0A).map { $0 + 1 } ?? data.startIndex
                promptLines.remember(from, for: key)
            }
            if let reading {
                return limited(reading.claude(data, path: path, from: from, turn: turn.id, cwd: cwd))
            }
        }
        return steps(agent: agent, lines: lines(data[from...]), turn: turn, cwd: cwd)
    }

    /// Where turns' prompt lines start in their logs, once found (logs only grow;
    /// one that isn't the prompt's line anymore is looked for again).
    private static let promptLines = PromptLines()

    private final class PromptLines: @unchecked Sendable {
        private let lock = NSLock()
        private var offsets: [String: Int] = [:]

        func offset(_ key: String) -> Int? {
            lock.lock()
            defer { lock.unlock() }
            return offsets[key]
        }

        func remember(_ offset: Int, for key: String) {
            lock.lock()
            defer { lock.unlock() }
            if offsets.count >= 500 {
                offsets.removeAll()
            }
            offsets[key] = offset
        }
    }

    // MARK: - Claude Code

    /// The turn's lines are those whose parent chain leads to its prompt, up to
    /// the next prompt on that chain; a sub-agent's (`isSidechain`) are left out.
    static func claudeSteps(_ lines: [JSON], turn: String, cwd: String?) -> [TurnStep] {
        var reading = ClaudeStepsReading(turn: turn, cwd: cwd)
        for line in lines where !reading.ended {
            reading.add(line)
        }
        return reading.steps
    }

    /// A Claude Code turn's steps (`claudeSteps`), a line at a time: kept, a
    /// turn at work is read on from where it was (`StepsReading`).
    struct ClaudeStepsReading {
        let turn: String
        let cwd: String?
        /// The turn's prompt line was read: the lines after it are its steps.
        private var started = false
        /// The next prompt on its chain came: the turn is over.
        private(set) var ended = false
        private(set) var steps: [TurnStep] = []
        private var owner: [String: String]
        /// A tool call's step and tool, by the call's id.
        private var calls: [String: (index: Int, name: String)] = [:]
        /// The message each text step is from: its text blocks come a line each.
        private var textOf: [Int: String] = [:]

        init(turn: String, cwd: String?) {
            self.turn = turn
            self.cwd = cwd
            owner = [turn: turn]
        }

        mutating func add(_ line: JSON) {
            guard started else {
                started = line["uuid"].string == turn
                return
            }
            guard !ended, line["isSidechain"].bool != true, let uuid = line["uuid"].nonEmptyString else { return }
            let parent = line["parentUuid"].nonEmptyString ?? line["logicalParentUuid"].nonEmptyString
            let own = parent.flatMap { owner[$0] }
            let type = line["type"].string
            let message = line["message"]
            if type == "user", (message["role"].string ?? "user") == "user", let text = SessionHistoryReader.promptText(line),
               !text.hasPrefix("[Request interrupted") {
                // The next prompt: on this turn's chain, the turn is over.
                if own == turn {
                    ended = true
                    return
                }
                owner[uuid] = uuid
                return
            }
            owner[uuid] = own
            guard own == turn else { return }
            if type == "assistant", message["model"].string != "<synthetic>" {
                for block in message["content"].array {
                    switch block["type"].string {
                    case "text":
                        guard let text = SessionHistoryReader.answer(block["text"].string) else { continue }
                        let from = message["id"].nonEmptyString ?? uuid
                        if let last = steps.indices.last, textOf[last] == from {
                            steps[last].text += "\n\n" + text
                        } else {
                            steps.append(TurnStep(kind: .said, text: text))
                            textOf[steps.count - 1] = from
                        }
                    case "tool_use":
                        let name = block["name"].string ?? "Tool"
                        steps.append(SessionHistoryReader.claudeCall(name, block["input"], cwd: cwd))
                        if let id = block["id"].nonEmptyString {
                            calls[id] = (steps.count - 1, name)
                        }
                    default:
                        continue
                    }
                }
            } else if type == "user" {
                for block in message["content"].array where block["type"].string == "tool_result" {
                    guard let id = block["tool_use_id"].nonEmptyString, let call = calls[id] else { continue }
                    SessionHistoryReader.claudeResult(&steps[call.index], name: call.name, block: block, result: line["toolUseResult"])
                }
            }
        }
    }

    /// "Bash(swift build)", "Read(Sources/main.swift)", "Update(README.md)": as
    /// Claude Code's terminal names a tool call.
    static func claudeCall(_ name: String, _ input: JSON, cwd: String?) -> TurnStep {
        func file(_ key: String = "file_path") -> String {
            shortPath(input[key].string ?? input["path"].string ?? "", cwd: cwd)
        }
        func quoted(_ key: String) -> String {
            "\"\(oneLine(input[key].string ?? ""))\""
        }
        switch name {
        case "Bash":
            return TurnStep(kind: .ran, text: "Bash(\(oneLine(input["command"].string ?? "")))")
        case "Read":
            return TurnStep(kind: .ran, text: "Read(\(file()))")
        case "Edit", "MultiEdit":
            // Until its result says where: the strings swapped.
            var lines: [String] = []
            let edits = name == "Edit" ? [input] : input["edits"].array
            for edit in edits {
                lines += (edit["old_string"].string ?? "").split(separator: "\n", omittingEmptySubsequences: false).map { "-" + $0 }
                lines += (edit["new_string"].string ?? "").split(separator: "\n", omittingEmptySubsequences: false).map { "+" + $0 }
            }
            return TurnStep(kind: .changed, text: "Update(\(file()))", hunks: DiffHunk.limited([DiffHunk(oldStart: 0, newStart: 0, lines: lines)]).hunks)
        case "Write":
            return TurnStep(kind: .changed, text: "Write(\(file()))")
        case "NotebookEdit":
            return TurnStep(kind: .changed, text: "Update(\(file("notebook_path")))")
        case "Grep":
            let place = input["path"].string.map { ", path: \"\(shortPath($0, cwd: cwd))\"" } ?? ""
            return TurnStep(kind: .ran, text: "Search(pattern: \(quoted("pattern"))\(place))")
        case "Glob":
            return TurnStep(kind: .ran, text: "Search(pattern: \(quoted("pattern")))")
        case "WebFetch":
            return TurnStep(kind: .ran, text: "Fetch(\(oneLine(input["url"].string ?? "")))")
        case "WebSearch":
            return TurnStep(kind: .ran, text: "Web Search(\(quoted("query")))")
        case "Task", "Agent":
            return TurnStep(kind: .ran, text: "\(name)(\(oneLine(input["description"].string ?? input["prompt"].string ?? "")))")
        case "TodoWrite":
            let todos = input["todos"].array.map { todo in
                (todo["status"].string == "completed" ? "\u{2612} " : "\u{2610} ") + (todo["content"].string ?? "")
            }
            return TurnStep(kind: .ran, text: "Update Todos", output: todos.isEmpty ? nil : todos.joined(separator: "\n"))
        default:
            // "mcp__server__tool": the tool.
            let parts = name.components(separatedBy: "__")
            let shown = name.hasPrefix("mcp__") && parts.count >= 3 ? parts[2...].joined(separator: "__") : name
            let first = input.object?.sorted { $0.key < $1.key }.lazy.compactMap { $0.value.string }.first
            return TurnStep(kind: .ran, text: first.map { "\(shown)(\(oneLine($0)))" } ?? shown)
        }
    }

    /// What a tool call came to, from its result: a command's output, the lines
    /// read, a file's change as its diff.
    static func claudeResult(_ step: inout TurnStep, name: String, block: JSON, result: JSON) {
        let content = block["content"].string ?? block["content"].array.compactMap { $0["text"].string }.joined(separator: "\n")
        if block["is_error"].bool == true {
            step.failed = true
            step.outcome = firstLine(content.isEmpty ? "Error" : content)
            step.output = content.isEmpty ? nil : clip(content, lines: 40)
            return
        }
        switch name {
        case "Bash":
            let output = [result["stdout"].string, result["stderr"].string]
                .compactMap { $0?.trimmingCharacters(in: .newlines) }.filter { !$0.isEmpty }.joined(separator: "\n")
            let shown = output.isEmpty ? content.trimmingCharacters(in: .newlines) : output
            step.output = shown.isEmpty ? nil : clip(shown, lines: 40)
            if result["interrupted"].bool == true {
                step.failed = true
                step.outcome = "Interrupted"
            }
        case "Read":
            if let count = result["file"]["numLines"].int {
                step.outcome = "Read \(count) line\(count == 1 ? "" : "s")"
            } else if result["type"].string == "image" {
                step.outcome = "Read an image"
            }
        case "Edit", "MultiEdit", "Write", "NotebookEdit":
            var hunks = result["structuredPatch"].array.map { hunk in
                DiffHunk(oldStart: hunk["oldStart"].int ?? 0, newStart: hunk["newStart"].int ?? 0, lines: hunk["lines"].array.compactMap(\.string))
            }
            let created = result["type"].string == "create"
            if hunks.isEmpty, created, let text = result["content"].string {
                var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { "+" + $0 }
                if lines.last == "+" {
                    lines.removeLast()
                }
                hunks = [DiffHunk(oldStart: 0, newStart: 1, lines: lines)]
            }
            if !hunks.isEmpty {
                let total = hunks.reduce(0) { $0 + $1.lines.count }
                step.hunks = DiffHunk.limited(hunks).hunks
                let added = hunks.reduce(0) { $0 + $1.lines.filter { $0.hasPrefix("+") }.count }
                let removed = hunks.reduce(0) { $0 + $1.lines.filter { $0.hasPrefix("-") }.count }
                step.outcome = (created ? "Wrote \(plural(added, "line"))" : "\(plural(added, "addition")), \(plural(removed, "removal"))")
                    + (total > DiffHunk.lineLimit ? " (\(total - DiffHunk.lineLimit) lines not shown)" : "")
            }
        case "Grep", "Glob":
            if let files = result["numFiles"].int {
                step.outcome = "Found \(plural(files, "file"))"
            } else if let lines = result["numLines"].int {
                step.outcome = "Found \(plural(lines, "line"))"
            }
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            step.output = trimmed.isEmpty ? nil : clip(trimmed, lines: 40)
        case "WebFetch":
            if let bytes = result["bytes"].int {
                step.outcome = "Received \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))"
                    + (result["codeText"].string.map { " (\(result["code"].int.map(String.init) ?? "") \($0))" } ?? "")
            }
        case "WebSearch":
            // As Claude Code sums it up, not the results.
            let searches = result["searchCount"].int ?? 1
            step.outcome = "Did \(searches == 1 ? "1 search" : "\(searches) searches")"
                + (result["durationSeconds"].double.map { " in \(max(Int($0.rounded()), 1))s" } ?? "")
        case "TodoWrite":
            break
        default:
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            step.output = trimmed.isEmpty ? nil : clip(trimmed, lines: 40)
        }
    }

    // MARK: - Codex

    /// The turn runs from its prompt (the user message with its words, asked at
    /// its time) to the next. Newer Codex logs each step as a completed item (an
    /// AgentMessage, a CommandExecution, a FileChange…); older Codex as response
    /// items, a call and its output apart. A turn's items are read if it has any.
    static func codexSteps(_ lines: [JSON], turn prompt: PromptTurn, cwd: String?) -> [TurnStep] {
        func time(_ line: JSON) -> Date? {
            line["payload"]["completed_at_ms"].double.map { Date(timeIntervalSince1970: $0 / 1000) } ?? Dates.parse(line["timestamp"].string)
        }
        func isPrompt(_ line: JSON) -> Bool {
            let payload = line["payload"]
            return line["type"].string == "event_msg"
                && (payload["type"].string == "user_message"
                    || (payload["type"].string == "item_completed" && payload["item"]["type"].string == "UserMessage"))
        }
        /// The prompt as the history keeps it.
        func words(_ line: JSON) -> String {
            let payload = line["payload"]
            let raw = payload["message"].string ?? payload["item"]["content"].array.compactMap { $0["text"].string }.joined(separator: "\n")
            return String(stripContext(answerText(raw) ?? raw).trimmingCharacters(in: .whitespacesAndNewlines).prefix(promptLimit))
        }
        /// This turn's prompt (logged one way or the other): its words, near its time.
        /// A forked thread copies its parent's prompts, all at once.
        func isThis(_ line: JSON) -> Bool {
            abs((time(line) ?? .distantPast).timeIntervalSince(prompt.askedAt)) < 2 && words(line) == prompt.text
        }
        let near = lines.indices.filter { isPrompt(lines[$0]) && abs((time(lines[$0]) ?? .distantPast).timeIntervalSince(prompt.askedAt)) < 2 }
        guard let start = near.first(where: { isThis(lines[$0]) }) ?? near.first else { return [] }
        var end = lines.count
        for index in (start + 1)..<lines.count where isPrompt(lines[index]) && !isThis(lines[index]) {
            end = index
            break
        }
        let turn = lines[(start + 1)..<end]
        return codexTurnSteps(Array(turn), cwd: cwd)
    }

    /// One pass over a turn's lines, in order. Newer Codex logs each step as a
    /// completed item (an AgentMessage, a CommandExecution, a FileChange…); calls
    /// come as response items, and in code mode a script's calls only there
    /// (`tools.exec_command`, `tools.apply_patch`). A call's step takes its item
    /// when one follows: a command its output, a patch the file's line numbers.
    static func codexTurnSteps(_ turn: [JSON], cwd: String?) -> [TurnStep] {
        func item(_ line: JSON) -> JSON? {
            line["type"].string == "event_msg" && line["payload"]["type"].string == "item_completed" ? line["payload"]["item"] : nil
        }
        let itemMessages = turn.contains { item($0)?["type"].string == "AgentMessage" }
        let itemSearches = turn.contains { item($0)?["type"].string == "WebSearch" }
        var steps: [TurnStep] = []
        /// A call's steps, for its output; steps waiting for their item, by command and by file.
        var calls: [String: [Int]] = [:]
        var commands: [String: [Int]] = [:]
        var patches: [String: [Int]] = [:]
        func waiting(_ table: inout [String: [Int]], _ key: String) -> Int? {
            guard let index = table[key]?.first else { return nil }
            table[key]?.removeFirst()
            return index
        }
        for line in turn {
            let payload = line["payload"]
            if let item = item(line) {
                switch item["type"].string {
                case "AgentMessage":
                    let text = item["content"].array.compactMap { $0["text"].string }.joined(separator: "\n\n")
                    if let text = answer(text) {
                        steps.append(TurnStep(kind: .said, text: text))
                    }
                case "CommandExecution":
                    let command = codexCommand(item["command"])
                    let output = (item["aggregated_output"].nonEmptyString ?? [item["stdout"].string, item["stderr"].string]
                        .compactMap { $0 }.joined(separator: "\n")).trimmingCharacters(in: .newlines)
                    let code = item["exit_code"].int
                    let failed = (code ?? 0) != 0 || item["status"].string == "failed"
                    let index = waiting(&commands, command) ?? {
                        steps.append(TurnStep(kind: .ran, text: "Shell(\(oneLine(command)))"))
                        return steps.count - 1
                    }()
                    steps[index].output = output.isEmpty ? steps[index].output : clip(output, lines: 40)
                    steps[index].failed = failed
                    steps[index].outcome = failed ? code.map { "Exit \($0)" } ?? "Failed" : nil
                case "FileChange":
                    let failed = ["failed", "declined"].contains(item["status"].string ?? "")
                    for (path, change) in (item["changes"].object ?? [:]).sorted(by: { $0.key < $1.key }) {
                        let action = ["add": "Write", "delete": "Delete"][change["type"].string ?? ""] ?? "Update"
                        var hunks = DiffHunk.parse(unified: change["unified_diff"].string ?? "")
                        if hunks.isEmpty, action == "Write", let content = change["content"].string {
                            // A new file comes whole.
                            var lines = content.split(separator: "\n", omittingEmptySubsequences: false).map { "+" + $0 }
                            if lines.last == "+" {
                                lines.removeLast()
                            }
                            hunks = [DiffHunk(oldStart: 0, newStart: 1, lines: lines)]
                        }
                        let step = changeStep(action, path: path, hunks: hunks, failed: failed, cwd: cwd)
                        if let index = waiting(&patches, path) {
                            steps[index] = step
                        } else {
                            steps.append(step)
                        }
                    }
                case "McpToolCall":
                    let arguments = item["arguments"]
                    let what = arguments["title"].string ?? arguments.object?.sorted { $0.key < $1.key }.lazy.compactMap { $0.value.string }.first
                    let result = item["result"]["content"].array.compactMap { $0["text"].string }.joined(separator: "\n")
                    let failed = item["result"]["isError"].bool == true || item["status"].string == "failed"
                    steps.append(TurnStep(kind: .ran, text: (item["tool"].string ?? "tool") + (what.map { "(\(oneLine($0)))" } ?? ""),
                                          outcome: failed ? firstLine(result.isEmpty ? "Failed" : result) : nil,
                                          output: result.isEmpty ? nil : clip(result, lines: 40), failed: failed))
                case "WebSearch":
                    steps.append(TurnStep(kind: .ran, text: "Web Search(\"\(oneLine(item["query"].string ?? ""))\")"))
                default:
                    continue
                }
                continue
            }
            guard line["type"].string == "response_item" else { continue }
            switch payload["type"].string {
            case "message" where payload["role"].string == "assistant" && !itemMessages:
                let text = payload["content"].array.compactMap { $0["text"].string }.joined(separator: "\n\n")
                if let text = answer(text) {
                    steps.append(TurnStep(kind: .said, text: text))
                }
            case "function_call", "custom_tool_call", "local_shell_call":
                let name = payload["name"].string ?? "shell"
                let input = payload["arguments"].string.flatMap { JSON.parse($0) } ?? payload["action"]
                let raw = payload["input"].string ?? ""
                var made: [Int] = []
                func patch(_ text: String) {
                    for file in DiffHunk.parse(patch: text) {
                        steps.append(changeStep(file.action, path: file.path, hunks: file.hunks, failed: false, cwd: cwd))
                        patches[file.path, default: []].append(steps.count - 1)
                        made.append(steps.count - 1)
                    }
                }
                func command(_ text: String) {
                    steps.append(TurnStep(kind: .ran, text: "Shell(\(oneLine(text)))"))
                    commands[text, default: []].append(steps.count - 1)
                    made.append(steps.count - 1)
                }
                if name == "apply_patch" {
                    patch(raw.isEmpty ? (input["input"].string ?? "") : raw)
                } else if ["shell", "exec_command", "shell_command", "container.exec"].contains(name) || payload["type"].string == "local_shell_call" {
                    command(codexCommand(input["command"].isNull ? input["cmd"] : input["command"]))
                } else if name == "exec" {
                    // Code mode: a script; its commands, patches and searches.
                    let script = CodexScript(raw)
                    script.commands.forEach(command)
                    script.patches.forEach(patch)
                    if !itemSearches {
                        for search in script.searches {
                            steps.append(TurnStep(kind: .ran, text: search))
                            made.append(steps.count - 1)
                        }
                    }
                } else {
                    let what = input["title"].string ?? input["query"].string ?? input["task_name"].string
                    steps.append(TurnStep(kind: .ran, text: name + (what.map { "(\(oneLine($0)))" } ?? "")))
                    made.append(steps.count - 1)
                }
                if let id = payload["call_id"].nonEmptyString {
                    calls[id] = made
                }
            case "function_call_output", "custom_tool_call_output":
                // A call with one step: what it printed is that step's.
                guard let id = payload["call_id"].nonEmptyString, let made = calls[id], made.count == 1 else { continue }
                let index = made[0]
                let output = payload["output"]
                var text = output.string ?? output.array.compactMap { $0["text"].string }.joined(separator: "\n")
                var code: Int?
                if let parsed = JSON.parse(text), parsed.isObject {
                    // {"output": "…", "metadata": {"exit_code": 0}}
                    code = parsed["metadata"]["exit_code"].int
                    text = parsed["output"].string ?? text
                }
                text = text.trimmingCharacters(in: .newlines)
                if steps[index].output == nil, !text.isEmpty {
                    steps[index].output = clip(text, lines: 40)
                }
                if let code, code != 0 {
                    steps[index].failed = true
                    steps[index].outcome = "Exit \(code)"
                }
            case "web_search_call" where !itemSearches:
                let query = payload["action"]["query"].string ?? ""
                steps.append(TurnStep(kind: .ran, text: "Web Search(\"\(oneLine(query))\")"))
            default:
                continue
            }
        }
        return steps
    }

    /// ["/bin/zsh", "-lc", "cat main.tex"]: what the shell runs.
    static func codexCommand(_ command: JSON) -> String {
        if let text = command.string {
            return text
        }
        let parts = command.array.compactMap(\.string)
        if parts.count >= 3, ["-lc", "-c"].contains(parts[parts.count - 2]) {
            return parts[parts.count - 1]
        }
        return parts.joined(separator: " ")
    }

    static func changeStep(_ action: String, path: String, hunks: [DiffHunk], failed: Bool, cwd: String?) -> TurnStep {
        let total = hunks.reduce(0) { $0 + $1.lines.count }
        var step = TurnStep(kind: .changed, text: "\(action)(\(shortPath(path, cwd: cwd)))", failed: failed, hunks: DiffHunk.limited(hunks).hunks)
        let added = hunks.reduce(0) { $0 + $1.lines.filter { $0.hasPrefix("+") }.count }
        let removed = hunks.reduce(0) { $0 + $1.lines.filter { $0.hasPrefix("-") }.count }
        step.outcome = action == "Delete" ? "Deleted" : action == "Write" ? "Wrote \(plural(added, "line"))"
            : "\(plural(added, "addition")), \(plural(removed, "removal"))"
        if total > DiffHunk.lineLimit {
            step.outcome! += " (\(total - DiffHunk.lineLimit) lines not shown)"
        }
        return step
    }

    // MARK: - Wording

    /// A path under the session's folder, from there.
    static func shortPath(_ path: String, cwd: String?) -> String {
        guard let cwd, !cwd.isEmpty else { return path }
        let folder = cwd.hasSuffix("/") ? cwd : cwd + "/"
        return path.hasPrefix(folder) ? String(path.dropFirst(folder.count)) : path
    }

    /// The first line, at most 160 characters.
    static func oneLine(_ text: String) -> String {
        let first = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n", omittingEmptySubsequences: false).first ?? ""
        let more = text.trimmingCharacters(in: .whitespacesAndNewlines).contains("\n")
        return first.count > 160 ? String(first.prefix(160)) + "\u{2026}" : String(first) + (more ? " \u{2026}" : "")
    }

    /// The first line with words, at most 120 characters: an error in a line.
    static func firstLine(_ text: String) -> String {
        let line = text.split(separator: "\n").lazy.map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        return line.count > 120 ? String(line.prefix(120)) + "\u{2026}" : line
    }

    /// At most `lines` lines and 4,000 characters, and how many lines were left out.
    static func clip(_ text: String, lines: Int) -> String {
        let all = text.split(separator: "\n", omittingEmptySubsequences: false)
        var kept = all.prefix(lines).joined(separator: "\n")
        if kept.count > 4000 {
            kept = String(kept.prefix(4000)) + "\u{2026}"
        }
        return all.count > lines ? kept + "\n\u{2026} +\(all.count - lines) lines" : kept
    }

    static func plural(_ count: Int, _ word: String) -> String {
        "\(count) \(word)\(count == 1 ? "" : "s")"
    }
}

/// A Codex code-mode script (the "exec" tool): JavaScript that calls Codex's
/// tools. Read for the commands it runs (`tools.exec_command({cmd: "…"})`), the
/// patches it applies ("*** Begin Patch" … "*** End Patch", in whatever string
/// holds them) and the web pages it searches or opens (`tools.web__run`).
struct CodexScript {
    var commands: [String] = []
    var patches: [String] = []
    /// "Web Search(\"…\")", "Fetch(https://…)".
    var searches: [String] = []

    init(_ script: String) {
        var rest = script[...]
        while let call = rest.range(of: "exec_command(") {
            let after = rest[call.upperBound...]
            if let key = after.prefix(600).range(of: "cmd"), let command = Self.string(after: key.upperBound, in: after) {
                commands.append(command)
            }
            rest = after
        }
        rest = script[...]
        while let begin = rest.range(of: "*** Begin Patch"), let end = rest[begin.upperBound...].range(of: "*** End Patch") {
            patches.append(Self.unescaped(rest[begin.lowerBound..<end.upperBound]))
            rest = rest[end.upperBound...]
        }
        rest = script[...]
        while let call = rest.range(of: "web__run(") {
            let after = rest[call.upperBound...]
            let near = after.prefix(800)
            if let key = near.range(of: "q\":") ?? near.range(of: "q:"), let query = Self.string(after: key.upperBound, in: after, keyEnded: true) {
                searches.append("Web Search(\"\(SessionHistoryReader.oneLine(query))\")")
            } else if let key = near.range(of: "ref_id\":") ?? near.range(of: "ref_id:"),
                      let page = Self.string(after: key.upperBound, in: after, keyEnded: true) {
                searches.append("Fetch(\(SessionHistoryReader.oneLine(page)))")
            }
            rest = after
        }
    }

    /// The string after a key (`cmd: "…"`, `"cmd": '…'`, ``cmd: `…` ``), decoded;
    /// `keyEnded` when the colon was matched with the key.
    static func string(after index: Substring.Index, in text: Substring, keyEnded: Bool = false) -> String? {
        var at = index
        func skip(_ characters: String) {
            while at < text.endIndex, characters.contains(text[at]) {
                at = text.index(after: at)
            }
        }
        if !keyEnded {
            if at < text.endIndex, text[at] == "\"" {
                at = text.index(after: at)
            }
            skip(" ")
            guard at < text.endIndex, text[at] == ":" else { return nil }
            at = text.index(after: at)
        }
        skip(" ")
        guard at < text.endIndex, "\"'`".contains(text[at]) else { return nil }
        let quote = text[at]
        at = text.index(after: at)
        let start = at
        var escaped = false
        while at < text.endIndex {
            let character = text[at]
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == quote {
                return unescaped(text[start..<at])
            }
            at = text.index(after: at)
        }
        return nil
    }

    /// A script string's escapes, decoded: \n, \t, \", \u00e9, \u{1F600}…
    static func unescaped(_ text: Substring) -> String {
        var out = ""
        var scalars = text.unicodeScalars.makeIterator()
        while let scalar = scalars.next() {
            guard scalar == "\\", let next = scalars.next() else {
                out.unicodeScalars.append(scalar)
                continue
            }
            switch next {
            case "n": out += "\n"
            case "t": out += "\t"
            case "r": out += "\r"
            case "u", "x":
                var digits = ""
                var braced = false
                let count = next == "x" ? 2 : 4
                while let digit = scalars.next() {
                    if digit == "{", digits.isEmpty, next == "u" {
                        braced = true
                        continue
                    }
                    if braced && digit == "}" {
                        break
                    }
                    digits.unicodeScalars.append(digit)
                    if !braced && digits.count == count {
                        break
                    }
                }
                if let value = UInt32(digits, radix: 16), let decoded = Unicode.Scalar(value) {
                    out.unicodeScalars.append(decoded)
                }
            default:
                // \" \' \` \\ \/ \$: the character itself.
                out.unicodeScalars.append(next)
            }
        }
        return out
    }
}
