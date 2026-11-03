import Foundation
import AgentBuddyCore

/// `AgentBuddyChecks --history FILE [claude|codex|copilot] [--on SERVER]`: the
/// prompt tree of a real session log, with each prompt's tokens, as the history
/// window draws it; with --on, FILE is the path on the server (or the session's id).
func printHistory(_ path: String, agent named: String?, host: String? = nil) {
    let agent = named.flatMap(Agent.init(rawValue:))
        ?? (path.contains("/.codex/") ? .codex : (path.hasSuffix("events.jsonl") ? .copilot : .claude))
    let start = Date()
    let isID = !path.contains("/")
    let session = isID ? path : URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    let read = host.map { RemoteHistory.fetch(host: $0, agent: agent, path: isID ? nil : path, sessionID: session) }
        ?? SessionHistoryReader.read(agent: agent, path: path)
    switch read {
    case .failure(let error):
        print("couldn't read: \(error.message)")
    case .success(let history):
        let seconds = Date().timeIntervalSince(start)
        print("\(agent.clientName) session \(history.sessionID): \(history.turns.count) prompts in \(String(format: "%.2f", seconds)) s")
        print("title: \(history.title ?? "-"); client: \(history.client ?? "-"); folder: \(history.cwd ?? "-")")
        // What sending it a prompt would run: shown, never run.
        if case .success(let plan) = PromptSender.plan(PromptSender.Request(history: history, host: host, prompt: "\u{2026}")) {
            print("a send: \(plan.command) \(plan.arguments.joined(separator: " "))\n  \(plan.permissions); \(plan.asks)")
        }
        if let holder = history.openElsewhere {
            print("open for writing in \(holder)")
        }
        let clock = DateFormatter()
        clock.dateFormat = "MM-dd HH:mm"
        for row in history.rows {
            let indent = String(repeating: "    ", count: row.depth)
            let mark = row.branchStart ? "└─◦ " : (row.current ? "● " : "○ ")
            let text = row.turn.text.replacingOccurrences(of: "\n", with: " ").prefix(60)
            let took = row.turn.duration.map { " \(Int($0))s" } ?? ""
            let tokens = row.turn.usage.isEmpty ? "" : " {\(TokenStatistics.compact(row.turn.tokens.total)) tokens: "
                + row.turn.usage.map { "\($0.model) \(TokenStatistics.compact($0.counts.total))" }.joined(separator: ", ") + "}"
            print("\(indent)\(mark)\(clock.string(from: row.turn.askedAt)) [\(row.turn.outcome.rawValue)\(took)]\(tokens) \(text)")
        }
        let perJob = history.turns.reduce(0) { $0 + $1.tokens.total }
        print("session: \(TokenStatistics.compact(history.sessionTokens.total)) tokens, \(TokenStatistics.compact(perJob)) of them in prompts' turns")
    }
}

// MARK: - Checks

func jsonLine(_ object: [String: Any]) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
}

/// A Claude Code session with a tool call, an interruption, a rewind that
/// edited a prompt away, a compaction, a sub-agent, editor context and junk.
func claudeHistoryFixture() -> [String] {
    var lines: [String] = []
    var clock = Date(timeIntervalSince1970: 1_793_000_000)
    func entry(_ uuid: String, parent: String?, type: String, message: [String: Any]? = nil, extra: [String: Any] = [:]) {
        clock.addTimeInterval(10)
        var object: [String: Any] = [
            "uuid": uuid, "type": type, "timestamp": stamp(clock), "sessionId": "s-1", "cwd": "/Users/me/app",
            "entrypoint": "claude-vscode", "gitBranch": "main", "isSidechain": false,
        ]
        object["parentUuid"] = parent ?? NSNull()
        if let message {
            object["message"] = message
        }
        for (key, value) in extra {
            object[key] = value
        }
        lines.append(jsonLine(object))
    }
    lines.append(jsonLine(["type": "ai-title", "aiTitle": "Fix the login page", "sessionId": "s-1"]))
    entry("p1", parent: nil, type: "user", message: ["role": "user", "content": "Fix the login page"],
          extra: ["permissionMode": "acceptEdits"])
    entry("a1", parent: "p1", type: "assistant", message: ["role": "assistant", "stop_reason": "tool_use",
        "content": [["type": "tool_use", "id": "t1", "name": "Read", "input": [:]]]])
    entry("r1", parent: "a1", type: "user", message: ["role": "user",
        "content": [["type": "tool_result", "tool_use_id": "t1", "content": "file text"]]])
    entry("a2", parent: "r1", type: "assistant", message: ["role": "assistant", "stop_reason": "end_turn",
        "model": "claude-opus-5-5", "id": "msg-2",
        "content": [["type": "text", "text": "The **login** page now validates."]]])
    // A sub-agent's chain is left out.
    entry("x1", parent: nil, type: "user", message: ["role": "user", "content": "Sub-agent task"], extra: ["isSidechain": true])
    // A prompt that was interrupted…
    entry("p2", parent: "a2", type: "user", message: ["role": "user", "content": [["type": "text", "text": "Add a remember-me box"]]])
    entry("a3", parent: "p2", type: "assistant", message: ["role": "assistant", "stop_reason": "tool_use",
        "content": [["type": "text", "text": "Starting on it."], ["type": "tool_use", "id": "t2", "name": "Edit", "input": [:]]]])
    entry("i2", parent: "a3", type: "user", message: ["role": "user", "content": [["type": "text", "text": "[Request interrupted by user]"]]])
    // …then rewound: edited into another prompt after the first answer.
    entry("m1", parent: "a2", type: "user", message: ["role": "user", "content": "<command-name>/model</command-name>"])
    entry("p3", parent: "a2", type: "user", message: ["role": "user",
        "content": [["type": "text", "text": "<ide_opened_file>The user opened Login.swift</ide_opened_file>"],
                    ["type": "text", "text": "Use a toggle instead"]]])
    entry("meta", parent: "p3", type: "user", message: ["role": "user", "content": "Caveat: injected"], extra: ["isMeta": true])
    // Its last message comes a block a line: the answer is both.
    entry("a4", parent: "meta", type: "assistant", message: ["role": "assistant", "model": "claude-opus-5-5", "id": "msg-4",
        "content": [["type": "text", "text": "Done with a toggle.\n\n- It sits under **Remember me**"]]])
    entry("a5", parent: "a4", type: "assistant", message: ["role": "assistant", "stop_reason": "end_turn",
        "model": "claude-opus-5-5", "id": "msg-4", "content": [["type": "text", "text": "Try it in Settings."]]])
    // A compaction keeps the chain going through its summary.
    entry("c1", parent: nil, type: "user", message: ["role": "user", "content": "This session is being continued…"],
          extra: ["isCompactSummary": true, "logicalParentUuid": "a4"])
    entry("p4", parent: "c1", type: "user", message: ["role": "user",
        "content": "<system-reminder>context</system-reminder>Now ship it"], extra: ["permissionMode": "auto"])
    entry("e4", parent: "p4", type: "assistant", message: ["role": "assistant", "model": "<synthetic>",
        "content": [["type": "text", "text": "No response requested."]]])
    lines.append("{\"type\":\"user\",\"broken")
    return lines
}

/// What was selected and sent with a prompt: kept with it, apart from its words.
func checkPromptSelections() {
    print("Selections sent with a prompt")
    let block = SelectionContext.block(text: "fn main() {\n    run()\n}", file: "/Users/me/app/src/main.rs", lines: 3...5, app: "Zed", title: nil)
    let fromZed = SessionHistoryReader.selections(in: block + "\n\nWhy does this loop?")
    check(fromZed == [PromptSelection(source: "main.rs, lines 3\u{2013}5", text: "fn main() {\n    run()\n}")],
          "a selection from a file's lines: where from, and its text as selected: \(fromZed)")
    let other = SessionHistoryReader.selections(in: SelectionContext.block(text: "Release notes", file: nil, lines: nil, app: "Safari", title: "What's new"))
    check(other.first?.source == "Safari \u{00B7} What's new" && other.first?.text == "Release notes", "from another app: the app and its window")
    let file = SessionHistoryReader.selections(in: SelectionContext.block(text: "x", file: "/tmp/notes.md", lines: nil, app: "Code", title: nil))
    check(file.first?.source == "notes.md", "from a file, no lines known: the file")
    let two = SessionHistoryReader.selections(in: block + block)
    check(two.count == 2, "two selections, both kept")
    check(SessionHistoryReader.selections(in: "<ide_opened_file>The user opened Login.swift</ide_opened_file>Use a toggle").isEmpty,
          "a file merely open isn't a selection")
    let line = JSON.parse(#"{"type":"user","uuid":"u1","timestamp":"2026-10-30T01:00:00Z","message":{"role":"user","content":[{"type":"text","text":"\#(block.replacingOccurrences(of: "\n", with: "\\n"))"},{"type":"text","text":"Why does this loop?"}]}}"#)
    let read = SessionHistoryReader.claude(lines: line.map { [$0] } ?? [], sessionID: "s")
    check(read.turns.first?.text == "Why does this loop?" && read.turns.first?.selections.first?.source == "main.rs, lines 3\u{2013}5",
          "read from a log: the prompt's words alone, its selection kept beside them")
}

func checkHistory() {
    print("Prompt history")
    let claude = SessionHistoryReader.claude(
        lines: claudeHistoryFixture().compactMap { JSON.parse($0) }, sessionID: "s-1")
    check(claude.title == "Fix the login page" && claude.client == "claude-vscode", "title and client")
    check(claude.cwd == "/Users/me/app" && claude.gitBranch == "main", "folder and branch")
    check(claude.turns.map(\.id) == ["p1", "p2", "p3", "p4"], "four prompts, no tool results, commands, meta or sub-agents: \(claude.turns.map(\.id))")
    check(claude.turns.map(\.parent) == [nil, "p1", "p1", "p3"], "each follows the one it came after, through a compaction")
    check(claude.turns[2].text == "Use a toggle instead", "editor context is dropped")
    check(claude.turns[3].text == "Now ship it", "system reminders are dropped")
    check(claude.turns.map(\.outcome) == [.completed, .interrupted, .completed, .running], "outcomes: \(claude.turns.map(\.outcome.rawValue))")
    check(claude.turns[0].answer == "The **login** page now validates." && claude.turns[0].duration == 30,
          "the answer as written, and how long")
    check(claude.turns[2].answer == "Done with a toggle.\n\n- It sits under **Remember me**\n\nTry it in Settings.",
          "the whole last message, lines kept, its blocks together: \(claude.turns[2].answer ?? "-")")
    check(claude.model == "claude-opus-5-5" && claude.permissionMode == "auto", "the model and permission mode it used last")
    let rows = claude.rows
    check(rows.map(\.id) == ["p1", "p2", "p3", "p4"], "drawn in order, the branch under its prompt")
    check(rows.map(\.depth) == [0, 1, 0, 0], "the edited-away prompt is indented")
    check(rows[1].branchStart && !rows[1].current && rows[1].guides == [0], "it's a branch, off the current line, beside the main line")
    check(rows[0].current && rows[2].current && rows[3].current, "the line to the latest prompt is current")
    check(!rows[0].lineAbove && rows[0].lineBelow && rows[2].lineAbove && !rows[3].lineBelow, "the main line runs from the first to the last")

    // Codex: one line of turns.
    var codexLines = [jsonLine(["type": "session_meta", "payload": ["id": "th-1", "cwd": "/Users/me/site", "originator": "Codex Desktop"]]),
                      jsonLine(["type": "turn_context", "payload": ["cwd": "/Users/me/site", "model": "gpt-6-astra", "effort": "xhigh",
                                                                  "sandbox_policy": ["type": "workspace-write", "network_access": false]]])]
    let long = (1...300).map { "Line \($0) of the plan." }.joined(separator: "\n")
    var at = Date(timeIntervalSince1970: 1_793_100_000)
    func event(_ payload: [String: Any]) {
        at.addTimeInterval(5)
        codexLines.append(jsonLine(["type": "event_msg", "timestamp": stamp(at), "payload": payload]))
    }
    event(["type": "task_started"])
    event(["type": "user_message", "message": "<environment_context>cwd</environment_context>Build the site"])
    event(["type": "agent_message", "message": "Working"])
    event(["type": "task_complete", "last_agent_message": "Built it.", "turn_id": "1"])
    event(["type": "user_message", "message": "Plan the rest"])
    event(["type": "task_complete", "last_agent_message": "\n" + long + "\n"])
    event(["type": "user_message", "message": "Deploy"])
    event(["type": "turn_aborted"])
    event(["type": "user_message", "message": "", "images": ["data"]])
    let codex = SessionHistoryReader.codex(lines: codexLines.compactMap { JSON.parse($0) }, sessionID: "file-id")
    check(codex.sessionID == "th-1" && codex.client == "Codex Desktop" && codex.cwd == "/Users/me/site", "Codex: thread, client and folder")
    check(codex.turns.map(\.text) == ["Build the site", "Plan the rest", "Deploy", "(an image)"], "Codex prompts: \(codex.turns.map(\.text))")
    check(codex.turns.map(\.outcome) == [.completed, .completed, .interrupted, .running], "Codex outcomes")
    check(codex.turns[1].answer == long, "a long answer stays whole, \(long.count) characters")
    check(codex.model == "gpt-6-astra" && codex.effort == "xhigh" && codex.sandbox == "workspace-write", "Codex's model, effort and sandbox")
    check(codex.turns[0].answer == "Built it." && codex.turns[1].parent == codex.turns[0].id, "Codex answers and order")
    // How the session lets Codex act: its permission profile, and who approves; a turn
    // sent with "never" (Agent Buddy's, before) isn't how it asks.
    let asking = [
        jsonLine(["type": "turn_context", "payload": ["approval_policy": "on-request", "approvals_reviewer": "auto_review",
                                                      "active_permission_profile": ["id": ":workspace"]]]),
        jsonLine(["type": "turn_context", "payload": ["approval_policy": "never", "approvals_reviewer": "auto_review"]]),
    ]
    let reviewed = SessionHistoryReader.codex(lines: (codexLines + asking).compactMap { JSON.parse($0) }, sessionID: "file-id")
    check(reviewed.approvalPolicy == "on-request" && reviewed.approvalsReviewer == "auto_review" && reviewed.permissionProfile == ":workspace",
          "Codex's approvals and permission profile, past a turn sent never asking")
    check(codex.approvalPolicy == nil && codex.approvalsReviewer == nil && codex.permissionProfile == nil, "none in an older log")

    // Newer Codex: completed UserMessage and AgentMessage items of a turn.
    var items = [jsonLine(["type": "session_meta", "payload": ["id": "th-2", "cwd": "/home/me/score", "originator": "codex_vscode"]])]
    func item(_ kind: String, _ text: String, turn: String, ms: Double) {
        items.append(jsonLine(["type": "event_msg", "timestamp": "2026-10-19T14:58:13.412Z", "payload": [
            "type": "item_completed", "turn_id": turn, "completed_at_ms": ms,
            "item": ["type": kind, "content": [["type": kind == "UserMessage" ? "text" : "Text", "text": text]]]]]))
    }
    func end(_ type: String, turn: String, ms: Double) {
        items.append(jsonLine(["type": "event_msg", "timestamp": "2026-10-19T14:58:13.412Z",
                               "payload": ["type": type, "turn_id": turn, "completed_at_ms": ms]]))
    }
    item("UserMessage", "Check the clicks", turn: "t1", ms: 1_793_000_000_000)
    item("AgentMessage", "Reading the guide.", turn: "t1", ms: 1_793_000_010_000)
    item("AgentMessage", "The script sends 20 clicks.", turn: "t1", ms: 1_793_000_060_000)
    end("task_complete", turn: "t1", ms: 1_793_000_061_000)
    // The same prompt logged the old way too counts once.
    items.append(jsonLine(["type": "event_msg", "timestamp": "2026-10-19T15:10:00.000Z",
                           "payload": ["type": "user_message", "message": "Slow them down", "turn_id": "t2"]]))
    item("UserMessage", "Slow them down", turn: "t2", ms: 1_793_000_600_500)
    item("SubAgentActivity", "ignored", turn: "t2", ms: 1_793_000_601_000)
    item("UserMessage", "Stop after the bypass", turn: "t2", ms: 1_793_000_650_000)
    item("UserMessage", #"<send_user_message_question_reply>[{"questionItemId":"q1","question":"Click the checkbox?","answer":"Yes, click it"}]</send_user_message_question_reply>"#,
         turn: "t3", ms: 1_793_000_800_000)
    end("turn_aborted", turn: "t2", ms: 1_793_000_700_000)
    let newer = SessionHistoryReader.codex(lines: items.compactMap { JSON.parse($0) }, sessionID: "th-2")
    check(newer.turns.map(\.text).prefix(3) == ["Check the clicks", "Slow them down", "Stop after the bypass"],
          "newer Codex prompts, each once, one sent mid-turn too: \(newer.turns.map(\.text))")
    check(newer.turns.map(\.outcome).prefix(3) == [.completed, .interrupted, .interrupted], "a turn's end is each of its prompts' end")
    check(newer.turns.last?.text == "Answered: Yes, click it\nQuestion: Click the checkbox?", "an answer to Codex's question reads as one")
    check(newer.turns[0].answer == "The script sends 20 clicks." && newer.turns[0].duration == 61, "answers and times from the items")

    // Copilot, with its workspace name.
    var copilotLines: [String] = []
    func copilotEvent(_ type: String, _ data: [String: Any], agent: String? = nil) {
        at.addTimeInterval(5)
        var object: [String: Any] = ["type": type, "timestamp": stamp(at), "data": data, "id": "ev-\(copilotLines.count)"]
        object["agentId"] = agent ?? NSNull()
        copilotLines.append(jsonLine(object))
    }
    copilotEvent("session.start", ["producer": "copilot-agent", "context": ["cwd": "/Users/me/api"]])
    copilotEvent("user.message", ["content": "Add tests"])
    copilotEvent("assistant.message", ["content": "Reading", "toolRequests": [["name": "read"]]])
    copilotEvent("assistant.turn_end", [:])
    copilotEvent("user.message", ["content": "sub-agent prompt"], agent: "sub")
    copilotEvent("assistant.message", ["content": "Tests added.", "toolRequests": []])
    copilotEvent("assistant.turn_end", [:])
    copilotEvent("user.message", ["content": "Run them"])
    copilotEvent("hook.start", ["hookType": "agentStop", "input": ["stopReason": "error"]])
    let copilot = SessionHistoryReader.copilot(
        lines: copilotLines.compactMap { JSON.parse($0) }, sessionID: "cp-1", workspace: "name: 'API tests'\ncwd: /Users/me/api\n")
    check(copilot.title == "API tests" && copilot.client == "copilot-agent" && copilot.folders == ["/Users/me/api"], "Copilot: name, client, folder")
    check(copilot.turns.map(\.text) == ["Add tests", "Run them"], "Copilot prompts skip sub-agents")
    check(copilot.turns.map(\.outcome) == [.completed, .failed], "Copilot outcomes: \(copilot.turns.map(\.outcome.rawValue))")
    check(copilot.turns[0].answer == "Tests added.", "Copilot's last words")
    check(HistoryRow.layout([]).isEmpty, "no prompts, no rows")

    // A prompt sent from Agent Buddy's message box (claude -p) beside a session open in Zed.
    var sent: [String] = []
    var time = Date(timeIntervalSince1970: 1_793_200_000)
    func line(_ uuid: String, parent: String?, type: String, client: String, text: String, stop: String? = nil) {
        time.addTimeInterval(10)
        var message: [String: Any] = ["role": type, "content": type == "user" ? text : [["type": "text", "text": text]] as Any]
        if let stop {
            message["stop_reason"] = stop
        }
        sent.append(jsonLine(["uuid": uuid, "parentUuid": parent ?? NSNull(), "type": type, "timestamp": stamp(time),
                              "cwd": "/Users/me/app", "entrypoint": client, "message": message]))
    }
    line("q1", parent: nil, type: "user", client: "sdk-ts", text: "Start")
    line("b1", parent: "q1", type: "assistant", client: "sdk-ts", text: "Started.", stop: "end_turn")
    line("q2", parent: "b1", type: "user", client: "sdk-cli", text: "Will Zed show this?")
    line("b2", parent: "q2", type: "assistant", client: "sdk-cli", text: "No.", stop: "end_turn")
    line("q3", parent: "b1", type: "user", client: "sdk-ts", text: "Go on in Zed")
    let apart = SessionHistoryReader.claude(lines: sent.compactMap { JSON.parse($0) }, sessionID: "s-9")
    check(apart.client == "sdk-ts" && apart.turns.map(\.separate) == [false, true, false],
          "a prompt sent with claude -p is marked as sent separately: \(apart.turns.map(\.separate))")
    check(apart.rows.first { $0.id == "q2" }?.current == false, "and Zed carrying on from its own copy leaves it beside the line")
}

/// The server's history script, run here with a scratch home: it reads only
/// session logs, and its slimmed lines read the same as the log itself.
func checkRemoteHistory() {
    print("Prompt history from a server (Python, run locally in place of ssh)")
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("hs-remote-history-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: home) }
    let folder = home.appendingPathComponent(".claude/projects/-home-me-app")
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let log = folder.appendingPathComponent("s-1.jsonl")
    try? claudeHistoryFixture().joined(separator: "\n").write(to: log, atomically: true, encoding: .utf8)
    let secret = home.appendingPathComponent("notes.jsonl")
    try? "{\"type\":\"user\"}".write(to: secret, atomically: true, encoding: .utf8)
    let transport = ["/usr/bin/env", "HOME=\(home.path)", "python3", "-"]

    let fetched = RemoteHistory.fetch(host: "test", agent: .claude, path: log.path, sessionID: "s-1", transport: transport)
    let local = SessionHistoryReader.read(agent: .claude, path: log.path)
    if case .success(let remote) = fetched, case .success(let here) = local {
        check(remote.turns == here.turns, "the server's slimmed lines give the same prompts and outcomes")
        check(remote.title == here.title && remote.cwd == here.cwd && remote.client == here.client, "and the same title, folder and client")
        check(remote.model == here.model && remote.permissionMode == here.permissionMode && here.permissionMode == "auto",
              "and the same model and permission mode")
    } else {
        check(false, "the server's history reads: \(fetched)")
    }
    let refused = RemoteHistory.fetch(host: "test", agent: .claude, path: secret.path, sessionID: "x", transport: transport)
    if case .failure(let error) = refused {
        check(error.message.contains("isn't there"), "a file outside the agents' logs isn't read")
    } else {
        check(false, "a file outside the agents' logs isn't read")
    }
    let escape = RemoteHistory.fetch(host: "test", agent: .claude, path: folder.path + "/../../../notes.jsonl", sessionID: "x", transport: transport)
    if case .failure = escape {
        check(true, "nor one reached with ../")
    } else {
        check(false, "nor one reached with ../")
    }
}

func checkWindowFinding() {
    print("Finding where a session runs")
    // Processes and ssh command lines.
    let table = ProcessTable.snapshot()
    let me = table.lineage(of: getpid())
    check(me.first == getpid() && me.contains(getppid()), "this process and its parent are in the table")
    check(ProcessTable.folder(of: getpid()) == FileManager.default.currentDirectoryPath
          || ProcessTable.folder(of: getpid()).map { ProcessTable.canonical($0) == ProcessTable.canonical(FileManager.default.currentDirectoryPath) } == true,
          "a process's working folder")
    check(ProcessTable.arguments(of: getpid()).first?.hasSuffix("AgentBuddyChecks") == true, "a process's arguments")
    check(ProcessTable.sshDestination(["ssh", "-v", "-T", "-D", "64998", "-o", "ConnectTimeout=15", "203.0.113.7"]) == "203.0.113.7",
          "VS Code's ssh: the destination after its options")
    check(ProcessTable.sshDestination(["/usr/bin/ssh", "-p", "2222", "-tt", "me@gpu", "claude"]) == "me@gpu", "an option's value isn't the host")
    check(ProcessTable.sshDestination(["ssh", "-p2222", "gpu"]) == "gpu", "a value joined to its option")
    check(ProcessTable.hostKey("Me@GPU.example.com:22") == "gpu.example.com", "user, case and port don't matter")
    check(SSHHosts.same("dev@203.0.113.7", "203.0.113.7"), "a user@ prefix names the same server")
    check(ProcessTable.appBundle(containing: "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper (Plugin).app/Contents/MacOS/Code Helper (Plugin)")
          == "/Applications/Visual Studio Code.app", "a helper belongs to the app around it")
    check(ProcessTable.appBundle(containing: "/usr/bin/ssh") == nil, "a tool outside any app")
    check(Paths.contains("/a/b", "/a/b/c") && Paths.contains("/a/b", "/a/b") && !Paths.contains("/a/b", "/a/bc"), "folders hold their subfolders only")

    // VS Code's window list.
    let storage = JSON.parse("""
    {"windowsState": {
      "lastActiveWindow": {"folder": "vscode-remote://ssh-remote%2B203.0.113.7/home/me/score", "remoteAuthority": "ssh-remote+203.0.113.7"},
      "openedWindows": [
        {"folder": "file:///Users/me/error"},
        {"folder": "file:///Users/me/my%20app"},
        {"folder": "vscode-remote://ssh-remote%2B203.0.113.7/home/me/score"},
        {"workspaceIdentifier": {"id": "x", "configURIPath": "file:///Users/me/w.code-workspace"}}
      ]}}
    """)!
    let windows = EditorWindows.parse(storage)
    check(windows.windows.count == 3, "three folder windows, each once: \(windows.windows.map(\.uri))")
    check(windows.bestMatch(for: ["/Users/me/error/sub"], host: nil)?.path == "/Users/me/error", "a subfolder finds its window")
    check(windows.bestMatch(for: ["/Users/me/my app"], host: nil)?.uri == "file:///Users/me/my%20app", "spaces in a folder's name")
    check(windows.bestMatch(for: ["/Users/me/other"], host: nil) == nil, "a folder no window has")
    check(windows.bestMatch(for: ["/home/me/score/run"], host: "203.0.113.7")?.host == "203.0.113.7", "a server's window, by host and folder")
    check(windows.bestMatch(for: ["/Users/me/error"], host: "203.0.113.7")?.path == "/home/me/score", "the only window on a server, wherever the terminal moved")
    check(windows.bestMatch(for: ["/home/me/score"], host: "other-host") == nil, "not another server's window")

    // Zed's database: the current session's workspaces with a window.
    let db = FileManager.default.temporaryDirectory.appendingPathComponent("hs-zed-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: db) }
    let sql = """
    CREATE TABLE kv_store(key TEXT PRIMARY KEY, value TEXT);
    CREATE TABLE remote_connections(id INTEGER PRIMARY KEY, kind TEXT, host TEXT, port INTEGER, user TEXT);
    CREATE TABLE workspaces(workspace_id INTEGER PRIMARY KEY, paths TEXT, remote_connection_id INTEGER, session_id TEXT, window_id INTEGER);
    INSERT INTO kv_store VALUES('session_id', 'now');
    INSERT INTO remote_connections VALUES(1, 'ssh', '203.0.113.7', NULL, 'dev');
    INSERT INTO workspaces VALUES(1, '/Users/me/head_show', NULL, 'now', 42);
    INSERT INTO workspaces VALUES(2, '/Users/me/closed', NULL, NULL, NULL);
    INSERT INTO workspaces VALUES(3, '/Users/me/old', NULL, 'before', 7);
    INSERT INTO workspaces VALUES(4, '/home/dev/score', 1, 'now', 43);
    """
    let made = ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/sqlite3"), [db.path], input: Data(sql.utf8))
    check(made?.status == 0, "a scratch Zed database")
    let zed = ZedWindows.read(database: db)
    check(zed.workspaces.map(\.root).sorted() == ["/Users/me/head_show", "/home/dev/score"], "only the open projects of the current session: \(zed.workspaces.map(\.root))")
    check(zed.bestMatch(for: ["/Users/me/head_show/Companion"], host: nil)?.root == "/Users/me/head_show", "a local folder's project")
    let remote = zed.bestMatch(for: ["/home/dev/score"], host: "203.0.113.7")
    check(remote?.user == "dev" && remote?.host == "203.0.113.7", "a server's project, with its user")
    check(zed.bestMatch(for: ["/Users/me/closed"], host: nil) == nil, "a closed project isn't a window")
}

func checkArchive() {
    print("Agent windows kept after clearing")
    let base = Date(timeIntervalSince1970: 1_793_000_000)
    func job(_ id: String, session: String, minutes: Double, agent: Agent = .claude, source: String? = nil, title: String? = nil,
             path: String? = nil, outcome: JobEvent.Outcome = .completed) -> JobEvent {
        JobEvent(id: id, agent: agent, outcome: outcome, sessionID: session, title: title, project: "app",
                 finishedAt: base.addingTimeInterval(minutes * 60), transcriptPath: path, source: source)
    }
    var archive = SessionArchive()
    archive.record(job("a1", session: "s1", minutes: 0, title: "First title", path: "/logs/s1.jsonl"))
    archive.record(job("b1", session: "s2", minutes: 5, source: "gpu", title: "Server job"))
    archive.record(job("a2", session: "s1", minutes: 10, title: nil, outcome: .failed))
    archive.record(job("a2", session: "s1", minutes: 10, title: nil, outcome: .failed))
    check(archive.entries.map(\.sessionID) == ["s1", "s2"], "newest window first")
    let first = archive.entry("claude||s1")
    check(first?.jobs.map(\.id) == ["a1", "a2"], "the same job twice counts once")
    check(first?.title == "First title" && first?.transcriptPath == "/logs/s1.jsonl", "a job without a title keeps the window's, and its log")
    check(first?.lastOutcome == .failed && first?.lastFinished == base.addingTimeInterval(600), "the latest job's outcome and time")
    check(archive.entry("claude|gpu|s2")?.source == "gpu", "a server's window is its own")
    // An older job arriving late doesn't take the newer title.
    archive.record(job("a0", session: "s1", minutes: -30, title: "Old title"))
    check(archive.entry("claude||s1")?.title == "First title" && archive.entry("claude||s1")?.jobs.first?.id == "a0",
          "a late, older job slots in without renaming the window")
    // Keeping: the last 100 jobs of a window, 90 days, 300 windows.
    for index in 0..<120 {
        archive.record(job("many-\(index)", session: "busy", minutes: Double(20 + index)))
    }
    check(archive.entry("claude||busy")?.jobs.count == 100 && archive.entry("claude||busy")?.jobs.first?.id == "many-20",
          "a busy window keeps its latest 100 jobs")
    archive.prune(now: base.addingTimeInterval(80 * 86400))
    check(archive.entries.count == 3, "nothing is let go before 90 days")
    archive.prune(now: base.addingTimeInterval(91 * 86400))
    check(archive.entries.isEmpty, "windows quiet for 90 days are let go")
    var full = SessionArchive()
    for index in 0..<310 {
        full.record(job("w\(index)", session: "w\(index)", minutes: Double(index)))
    }
    full.prune(now: base.addingTimeInterval(86400))
    check(full.entries.count == 300 && full.entries.last?.sessionID == "w10", "at most 300, the oldest go first")
    full.remove("claude||w309")
    check(full.entry("claude||w309") == nil && full.entries.count == 299, "one can be removed")
    // By day, newest day first.
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    var days = SessionArchive()
    days.record(job("d1", session: "x", minutes: 0))
    days.record(job("d2", session: "y", minutes: 60 * 24 + 1))
    days.record(job("d3", session: "z", minutes: 60 * 24 + 5))
    let grouped = days.byDay(now: base.addingTimeInterval(2 * 86400), calendar: calendar)
    check(grouped.map { $0.entries.map(\.sessionID) } == [["z", "y"], ["x"]], "grouped by day, newest first")
    // Saved and read back.
    let data = try? JSONEncoder().encode(archive.entries.isEmpty ? days : archive)
    check(data.flatMap { try? JSONDecoder().decode(SessionArchive.self, from: $0) } == days, "it saves and reads back")
}

func checkLogImport() {
    print("Agent windows read back from Agent Buddy's log")
    let log = """
    2026-10-25 21:25:59.224 Agent Buddy 1.0.0 started, pid 7
    2026-10-25 22:52:09.075 open claude ebdf91b4-4557-4ca7-9803-db9746ca1b7a.jsonl on 203.0.113.7
    2026-10-25 22:52:41.293 emit claude:ebdf91b4-4557-4ca7-9803-db9746ca1b7a:msg_1 (already emitted: false)
    2026-10-25 22:52:41.300 job claude:ebdf91b4-4557-4ca7-9803-db9746ca1b7a:msg_1 completed; 1 in the list
    2026-10-25 23:10:00.000 open claude 0644.jsonl size 100 from 0
    2026-10-25 23:10:05.500 job claude:0644:msg_2 failed; 2 in the list
    2026-10-26 09:00:00.000 open codex rollout-2026-10-26T09-00-00-01a172bf-1653-7390-93d0-63aeccdb0e62.jsonl on gpu
    2026-10-26 09:01:00.000 job codex:01a172bf-1653-7390-93d0-63aeccdb0e62:turn-1 limited; 3 in the list
    2026-10-26 09:02:00.000 job copilot:cp-1:end-5 completed; 4 in the list
    garbage line
    2026-13-45 99:99:99.999 job claude:x:y completed;
    2026-10-26 09:03:00.000 job nonsense
    """
    let utc = TimeZone(identifier: "UTC")!
    let imported = LogImport(log: log, timeZone: utc)
    let jobs = imported.jobs
    check(imported.place(.claude, "0644") == .here, "a session opened on this Mac is known to be here")
    check(imported.place(.claude, "ebdf91b4-4557-4ca7-9803-db9746ca1b7a") == .server("203.0.113.7"), "and one opened on a server, there")
    check(imported.place(.copilot, "cp-1") == nil, "a session never seen opened is unknown")
    check(jobs.map(\.id) == ["claude:ebdf91b4-4557-4ca7-9803-db9746ca1b7a:msg_1", "claude:0644:msg_2",
                             "codex:01a172bf-1653-7390-93d0-63aeccdb0e62:turn-1", "copilot:cp-1:end-5"],
          "four jobs, the junk skipped: \(jobs.map(\.id))")
    check(jobs.map(\.outcome) == [.completed, .failed, .limited, .completed], "with their outcomes")
    check(jobs[0].source == "203.0.113.7" && jobs[1].source == nil, "a session opened on a server is that server's")
    check(jobs[2].source == "gpu" && jobs[2].sessionID == "01a172bf-1653-7390-93d0-63aeccdb0e62", "a Codex thread from its rollout file")
    check(abs(jobs[0].finishedAt.timeIntervalSince1970 - 1_792_968_761.3) < 0.001, "at the line's time")
    var archive = SessionArchive()
    for job in jobs {
        archive.record(job)
    }
    check(archive.entries.count == 4, "each its own window")
    check(archive.learn("claude||0644", title: "Fix it", project: "app", path: "/logs/0644.jsonl"), "a log read fills in the name")
    check(!archive.learn("claude||0644", title: "Other", project: "other", path: "/x"), "and doesn't overwrite it")
    check(archive.entry("claude||0644")?.title == "Fix it", "the first name stays")
}

func checkRemoteLookup() {
    print("Finding a session's log on a server by its id (Python, run locally)")
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("hs-remote-lookup-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: home) }
    let folder = home.appendingPathComponent(".claude/projects/-home-me-app")
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let log = folder.appendingPathComponent("s-9.jsonl")
    try? claudeHistoryFixture().joined(separator: "\n").write(to: log, atomically: true, encoding: .utf8)
    let rollouts = home.appendingPathComponent(".codex/sessions/2026/10/26")
    try? FileManager.default.createDirectory(at: rollouts, withIntermediateDirectories: true)
    let thread = "01a172bf-1653-7390-93d0-63aeccdb0e62"
    let rollout = rollouts.appendingPathComponent("rollout-2026-10-26T09-00-00-\(thread).jsonl")
    let codexLine = #"{"type":"event_msg","timestamp":"2026-10-26T01:00:00Z","payload":{"type":"user_message","message":"Build it"}}"#
    try? (#"{"type":"session_meta","payload":{"id":"\#(thread)","cwd":"/home/me/site","originator":"codex_cli_rs"}}"# + "\n" + codexLine)
        .write(to: rollout, atomically: true, encoding: .utf8)
    let transport = ["/usr/bin/env", "HOME=\(home.path)", "python3", "-"]

    if case .success(let history) = RemoteHistory.fetch(host: "t", agent: .claude, path: nil, sessionID: "s-9", transport: transport) {
        check(history.turns.count == 4, "a Claude session found by its id")
        check(history.logPath.map { $0.hasSuffix("/-home-me-app/s-9.jsonl") } == true, "and where it is, for next time")
    } else {
        check(false, "a Claude session found by its id")
    }
    if case .success(let history) = RemoteHistory.fetch(host: "t", agent: .codex, path: nil, sessionID: thread, transport: transport) {
        check(history.turns.map(\.text) == ["Build it"], "a Codex thread found by its id")
    } else {
        check(false, "a Codex thread found by its id")
    }
    if case .success(let history) = RemoteHistory.fetch(host: "t", agent: .claude, path: "/gone/s-9.jsonl", sessionID: "s-9", transport: transport) {
        check(history.logPath?.hasSuffix("s-9.jsonl") == true, "a log that moved is found again by its id")
    } else {
        check(false, "a log that moved is found again by its id")
    }
    for id in ["../../etc/passwd", "missing"] {
        if case .failure = RemoteHistory.fetch(host: "t", agent: .claude, path: nil, sessionID: id, transport: transport) {
            check(true, "no log for \"\(id)\"")
        } else {
            check(false, "no log for \"\(id)\"")
        }
    }
}


/// `AgentBuddyChecks --job-parity FILE...`: each session log's tokens three
/// ways, on copies laid out as a home folder (sub-agents' logs included): the
/// token count (by file), the history (by prompt), and the server's script run
/// here in place of ssh.
func jobParity(_ paths: [String]) {
    var mismatches = 0
    let files = FileManager.default
    for path in paths {
        let url = URL(fileURLWithPath: path)
        let agent: Agent = path.contains("/.codex/") ? .codex : (path.hasSuffix("events.jsonl") ? .copilot : .claude)
        let home = files.temporaryDirectory.appendingPathComponent("hs-parity-\(UUID().uuidString)")
        defer { try? files.removeItem(at: home) }
        let roots = TranscriptWatcher.Roots(
            claudeProjects: home.appendingPathComponent(".claude/projects"), codexSessions: home.appendingPathComponent(".codex/sessions"),
            codexIndex: nil, copilotSessions: home.appendingPathComponent(".copilot/session-state"))
        let session = url.deletingPathExtension().lastPathComponent
        let folder: URL
        switch agent {
        case .claude: folder = roots.claudeProjects.appendingPathComponent("p")
        case .codex: folder = roots.codexSessions.appendingPathComponent("2026")
        case .copilot: folder = roots.copilotSessions.appendingPathComponent(url.deletingLastPathComponent().lastPathComponent)
        default:
            print("parity is for Claude Code, Codex and Copilot logs")
            return
        }
        try? files.createDirectory(at: folder, withIntermediateDirectories: true)
        let copy = folder.appendingPathComponent(url.lastPathComponent)
        try? files.copyItem(at: url, to: copy)
        var helpers = 0
        if agent == .claude {
            let subagents = url.deletingLastPathComponent().appendingPathComponent(session)
            if files.fileExists(atPath: subagents.path) {
                try? files.copyItem(at: subagents, to: folder.appendingPathComponent(session))
                helpers = (files.enumerator(atPath: folder.appendingPathComponent(session).path)?.allObjects as? [String])?
                    .filter { $0.hasSuffix(".jsonl") }.count ?? 0
            }
        } else if agent == .codex {
            // Its sub-agents: rollouts whose first line names this thread as parent.
            let thread = (try? String(contentsOf: url, encoding: .utf8))?.split(separator: "\n").first
                .flatMap { JSON.parse(String($0)) }?["payload"]["id"].string ?? ""
            let walker = files.enumerator(at: TranscriptWatcher.Roots.standard().codexSessions, includingPropertiesForKeys: nil)
            while let other = walker?.nextObject() as? URL {
                guard other.lastPathComponent.hasPrefix("rollout-"), other != url,
                      let head = try? FileHandle(forReadingFrom: other) else { continue }
                let first = (try? head.read(upToCount: 65_536)).flatMap { $0.split(separator: 0x0A).first }.flatMap { JSON.parse(Data($0)) }
                try? head.close()
                if !thread.isEmpty, first?["payload"]["source"]["subagent"]["thread_spawn"]["parent_thread_id"].string == thread {
                    try? files.copyItem(at: other, to: folder.appendingPathComponent(other.lastPathComponent))
                    helpers += 1
                }
            }
        }
        let counted = TokenLedger(roots: roots, cacheURL: nil).refresh(now: Date()).reduce(0) { $0 + $1.counts.total }
        guard case .success(let local) = SessionHistoryReader.read(agent: agent, path: copy.path, roots: roots) else {
            print("  couldn't read \(url.lastPathComponent)")
            continue
        }
        let transport = ["/usr/bin/env", "HOME=\(home.path)", "python3", "-"]
        let remote = RemoteHistory.fetch(host: "here", agent: agent, path: copy.path, sessionID: local.sessionID, transport: transport)
        let remoteTotal: Int
        var sameTurns = false
        if case .success(let fetched) = remote {
            remoteTotal = fetched.sessionTokens.total
            sameTurns = fetched.turns.map(\.tokens) == local.turns.map(\.tokens)
        } else {
            remoteTotal = -1
        }
        let inTurns = local.turns.reduce(0) { $0 + $1.tokens.total }
        let same = counted == local.sessionTokens.total && remoteTotal == counted && sameTurns
        if !same {
            mismatches += 1
        }
        print("  \(same ? "same" : "DIFFERENT") \(url.lastPathComponent.prefix(40)) (+\(helpers) sub-agent logs): count \(counted), "
              + "history \(local.sessionTokens.total) (\(inTurns) in prompts), server \(remoteTotal)\(sameTurns ? "" : ", prompts differ")")
    }
    print(mismatches == 0 ? "All sessions agree." : "\(mismatches) sessions differ.")
}

func checkJobTokens() {
    print("Tokens by job")
    let base = Date(timeIntervalSince1970: 1_793_000_000)
    func at(_ seconds: Double) -> String { stamp(base.addingTimeInterval(seconds)) }
    func line(_ object: [String: Any]) -> JSON { JSON.parse(jsonLine(object))! }
    func assistant(_ uuid: String, parent: String, id: String, request: String, model: String, input: Int, output: Int,
                   write: Int = 0, read: Int = 0, seconds: Double, side: Bool = false, stop: String = "tool_use") -> JSON {
        line(["type": "assistant", "uuid": uuid, "parentUuid": parent, "isSidechain": side, "timestamp": at(seconds),
              "requestId": request, "message": ["role": "assistant", "id": id, "model": model, "stop_reason": stop,
              "content": [["type": "text", "text": "ok"]],
              "usage": ["input_tokens": input, "output_tokens": output, "cache_creation_input_tokens": write, "cache_read_input_tokens": read]]])
    }
    let claude = SessionHistoryReader.claude(lines: [
        line(["type": "user", "uuid": "p1", "parentUuid": NSNull(), "timestamp": at(0), "message": ["role": "user", "content": "First"]]),
        assistant("a1", parent: "p1", id: "m1", request: "r1", model: "claude-fable-5-1", input: 10, output: 20, write: 30, read: 40, seconds: 5),
        // The same message's next block repeats its usage: counted once.
        assistant("a1b", parent: "a1", id: "m1", request: "r1", model: "claude-fable-5-1", input: 10, output: 20, write: 30, read: 40, seconds: 6, stop: "end_turn"),
        line(["type": "user", "uuid": "p2", "parentUuid": "a1b", "timestamp": at(100), "message": ["role": "user", "content": "Second"]]),
        assistant("a2", parent: "p2", id: "m2", request: "r2", model: "claude-fable-5-1", input: 1, output: 2, seconds: 110),
        // A sub-agent working during the second prompt, on another model.
        assistant("s1", parent: "x", id: "m3", request: "r3", model: "claude-haiku-4-5", input: 100, output: 200, seconds: 120, side: true),
        assistant("a3", parent: "a2", id: "m4", request: "r4", model: "claude-fable-5-1", input: 3, output: 4, seconds: 130, stop: "end_turn"),
    ], sessionID: "s")
    check(claude.turns.map { $0.tokens.total } == [100, 310], "each prompt's tokens, a repeated block counted once: \(claude.turns.map { $0.tokens.total })")
    check(claude.turns[1].usage.map(\.model) == ["claude-haiku-4-5", "claude-fable-5-1"], "by model, the most used first, a sub-agent's included")
    check(claude.turns[0].usage.first?.counts == TokenCounts(input: 10, output: 20, cacheWrite: 30, cacheRead: 40), "each kind kept apart")
    check(claude.sessionTokens.total == 410, "the session's total is the prompts' together")

    // Codex: usage records by turn; a sub-agent's log by time; token_count only without records.
    func event(_ payload: [String: Any], seconds: Double) -> JSON {
        line(["type": "event_msg", "timestamp": at(seconds), "payload": payload])
    }
    func record(_ response: String, turn: String, input: Int, cached: Int, output: Int, seconds: Double) -> JSON {
        line(["type": "token_usage_record", "timestamp": at(seconds), "payload": [
            "response_id": response, "turn_id": turn, "usage": ["input_tokens": input, "cached_input_tokens": cached, "output_tokens": output]]])
    }
    let codexLines: [JSON] = [
        line(["type": "session_meta", "payload": ["id": "th", "cwd": "/w", "originator": "codex_vscode"]]),
        line(["type": "turn_context", "payload": ["model": "gpt-5.5-codex", "cwd": "/w"]]),
        event(["type": "item_completed", "turn_id": "t1", "item": ["type": "UserMessage", "content": [["type": "text", "text": "Build"]]]], seconds: 0),
        record("resp1", turn: "t1", input: 1000, cached: 600, output: 50, seconds: 10),
        record("resp1", turn: "t1", input: 1000, cached: 600, output: 50, seconds: 11),
        event(["type": "token_count", "info": ["total_token_usage": ["input_tokens": 999999]]], seconds: 12),
        event(["type": "task_complete", "turn_id": "t1"], seconds: 20),
        event(["type": "item_completed", "turn_id": "t2", "item": ["type": "UserMessage", "content": [["type": "text", "text": "Test"]]]], seconds: 100),
        record("resp2", turn: "t2", input: 10, cached: 0, output: 5, seconds: 110),
        event(["type": "task_complete", "turn_id": "t2"], seconds: 200),
        line(["type": "hs.subagent"]),
        line(["type": "session_meta", "payload": ["id": "sub", "source": ["subagent": ["thread_spawn": ["parent_thread_id": "th"]]]]]),
        line(["type": "turn_context", "payload": ["model": "gpt-5.5-mini"]]),
        event(["type": "user_message", "message": "sub-agent's instructions"], seconds: 105),
        record("resp3", turn: "subturn", input: 40, cached: 0, output: 2, seconds: 120),
        event(["type": "task_complete", "turn_id": "subturn"], seconds: 125),
    ]
    let codex = SessionHistoryReader.codex(lines: codexLines, sessionID: "th")
    check(codex.turns.map(\.text) == ["Build", "Test"], "a sub-agent's prompts aren't the window's")
    check(codex.turns.map(\.outcome) == [.completed, .completed], "nor do its turns end the window's")
    check(codex.turns[0].tokens == TokenCounts(input: 400, output: 50, cacheWrite: 0, cacheRead: 600), "Codex: cached input counted apart, a response once")
    check(codex.turns[1].usage.map(\.model) == ["gpt-5.5-mini", "gpt-5.5-codex"], "a sub-agent's tokens in the prompt it worked for")
    check(codex.sessionTokens.total == 1050 + 15 + 42, "token_count isn't counted when records exist")
    let countsOnly = SessionHistoryReader.codex(lines: [
        line(["type": "session_meta", "payload": ["id": "old"]]),
        event(["type": "user_message", "message": "Old"], seconds: 0),
        event(["type": "token_count", "info": ["total_token_usage": ["input_tokens": 100, "output_tokens": 10]]], seconds: 5),
        event(["type": "token_count", "info": ["total_token_usage": ["input_tokens": 100, "output_tokens": 10]]], seconds: 6),
        event(["type": "token_count", "info": ["total_token_usage": ["input_tokens": 150, "output_tokens": 30]]], seconds: 7),
    ], sessionID: "old")
    check(countsOnly.turns.first?.tokens.total == 180, "older Codex: token_count's running total, each rise once")

    // Copilot: the session's totals, from its shutdown.
    let copilot = SessionHistoryReader.copilot(lines: [
        line(["type": "user.message", "timestamp": at(0), "data": ["content": "Add tests"], "agentId": NSNull()]),
        line(["type": "session.shutdown", "timestamp": at(500), "data": ["modelMetrics": [
            "gpt-5.5": ["usage": ["inputTokens": 1000, "outputTokens": 100, "cacheReadTokens": 700, "cacheWriteTokens": 100]]]]]),
    ], sessionID: "cp", workspace: nil)
    check(copilot.turns.first?.usage.isEmpty == true && copilot.sessionTokens == TokenCounts(input: 200, output: 100, cacheWrite: 100, cacheRead: 700),
          "Copilot: tokens for the session, not the job")

    // The list: newest first, within the period, sub-agent threads left out, Copilot as a whole session.
    var sub = codex
    sub.isSubagent = true
    sub.sessionID = "sub"
    var copilotSession = copilot
    copilotSession.sessionEndedAt = base.addingTimeInterval(500)
    let jobs = JobStatistics.jobs([
        UsageSession(key: "claude||s", source: nil, history: claude),
        UsageSession(key: "codex|gpu|th", source: "gpu", history: codex),
        UsageSession(key: "codex||sub", source: nil, history: sub),
        UsageSession(key: "copilot||cp", source: nil, history: copilotSession),
    ], from: base.addingTimeInterval(50), to: base.addingTimeInterval(1000))
    check(jobs.map(\.id) == ["copilot||cp#session", "codex|gpu|th#codex-7", "claude||s#p2"],
          "jobs in the period, newest first: \(jobs.map(\.id))")
    check(jobs.first?.wholeSession == true && jobs.first?.tokens.total == 1100, "Copilot's row is its whole session")
    check(jobs[1].source == "gpu" && jobs[1].prompt == "Test" && jobs[1].tokens.total == 57, "a server's job, with its sub-agent's tokens")
    check(StatsPeriod.week.start(now: base) == Calendar.current.date(byAdding: .day, value: -6, to: Calendar.current.startOfDay(for: base)),
          "7 days start where the totals' do")
}
