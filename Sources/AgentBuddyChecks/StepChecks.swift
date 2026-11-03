import Foundation
import AgentBuddyCore

/// A turn's steps, as the agent windows show them after a ●: read from stand-in
/// Claude Code and Codex logs, here and as a server sends them back.
func checkSteps() {
    print("A turn's steps")
    let hunks = DiffHunk.parse(unified: "@@ -6,2 +6,3 @@\n line six\n-old seven\n+new seven\n+new eight\n@@ -40 +41 @@\n-gone\n")
    check(hunks.count == 2 && hunks[0].oldStart == 6 && hunks[0].newStart == 6 && hunks[0].lines == [" line six", "-old seven", "+new seven", "+new eight"]
          && hunks[1].oldStart == 40 && hunks[1].newStart == 41 && hunks[1].lines == ["-gone"],
          "a unified diff's parts, with their first lines")
    let patch = DiffHunk.parse(patch: "*** Begin Patch\n*** Update File: /app/main.py\n@@ def main():\n-    pass\n+    run()\n*** Add File: /app/new.py\n+print(1)\n*** End Patch")
    check(patch.count == 2 && patch[0].action == "Update" && patch[0].hunks.first?.lines == ["-    pass", "+    run()"]
          && patch[1].action == "Write" && patch[1].path == "/app/new.py", "Codex's own patch, file by file")

    // Claude Code: a prompt, what was said, a command, an edit, an answer; then the next prompt.
    func at(_ second: Int) -> String { "2026-10-27T10:00:\(String(format: "%02d", second)).000Z" }
    let claude = [
        jsonLine(["uuid": "p1", "parentUuid": NSNull(), "type": "user", "timestamp": at(0), "cwd": "/home/me/app",
                  "message": ["role": "user", "content": "Fix the build"]]),
        jsonLine(["uuid": "a1", "parentUuid": "p1", "type": "assistant", "timestamp": at(1),
                  "message": ["role": "assistant", "id": "m1", "model": "claude", "content": [["type": "text", "text": "Let me build it."]]]]),
        jsonLine(["uuid": "a2", "parentUuid": "a1", "type": "assistant", "timestamp": at(2),
                  "message": ["role": "assistant", "id": "m1", "model": "claude",
                              "content": [["type": "tool_use", "id": "t1", "name": "Bash", "input": ["command": "swift build\nswift test"]]]]]),
        jsonLine(["uuid": "r1", "parentUuid": "a2", "type": "user", "timestamp": at(3),
                  "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "t1", "content": "error: x"]]],
                  "toolUseResult": ["stdout": "Compiling\nerror: missing comma", "stderr": "", "interrupted": false]]),
        jsonLine(["uuid": "x1", "parentUuid": "r1", "type": "assistant", "isSidechain": true, "timestamp": at(3),
                  "message": ["role": "assistant", "id": "m9", "model": "claude", "content": [["type": "text", "text": "A sub-agent's words"]]]]),
        jsonLine(["uuid": "a3", "parentUuid": "r1", "type": "assistant", "timestamp": at(4),
                  "message": ["role": "assistant", "id": "m2", "model": "claude",
                              "content": [["type": "tool_use", "id": "t2", "name": "Edit",
                                           "input": ["file_path": "/home/me/app/Sources/main.swift", "old_string": "a b", "new_string": "a, b"]]]]]),
        jsonLine(["uuid": "r2", "parentUuid": "a3", "type": "user", "timestamp": at(5),
                  "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "t2", "content": "ok"]]],
                  "toolUseResult": ["filePath": "/home/me/app/Sources/main.swift", "originalFile": "a b\n",
                                    "structuredPatch": [["oldStart": 12, "oldLines": 1, "newStart": 12, "newLines": 1, "lines": ["-a b", "+a, b"]]]]]),
        jsonLine(["uuid": "a4", "parentUuid": "r2", "type": "assistant", "timestamp": at(6),
                  "message": ["role": "assistant", "id": "m3", "model": "claude", "stop_reason": "end_turn",
                              "content": [["type": "text", "text": "Fixed: a missing comma."]]]]),
        jsonLine(["uuid": "p2", "parentUuid": "a4", "type": "user", "timestamp": at(7), "message": ["role": "user", "content": "Thanks"]]),
        jsonLine(["uuid": "a5", "parentUuid": "p2", "type": "assistant", "timestamp": at(8),
                  "message": ["role": "assistant", "id": "m4", "model": "claude", "content": [["type": "text", "text": "You're welcome."]]]]),
    ]
    let claudeLines = claude.compactMap { JSON.parse($0) }
    let history = SessionHistoryReader.claude(lines: claudeLines, sessionID: "s-1")
    if let first = history.turns.first(where: { $0.id == "p1" }) {
        let steps = SessionHistoryReader.steps(agent: .claude, lines: claudeLines, turn: first, cwd: "/home/me/app")
        check(steps.map(\.kind) == [.said, .ran, .changed, .said], "Claude Code: said, ran, changed, said, as its terminal shows them")
        check(steps.count == 4 && steps[1].text == "Bash(swift build \u{2026})" && steps[1].outcome == nil
              && steps[1].output == "Compiling\nerror: missing comma", "a command by its first line; its output kept for a click")
        check(steps.count == 4 && steps[2].text == "Update(Sources/main.swift)" && steps[2].hunks.first?.oldStart == 12
              && steps[2].hunks.first?.lines == ["-a b", "+a, b"] && steps[2].outcome == "1 addition, 1 removal",
              "an edit by the file, from the session's folder, with its diff from line 12")
        check(!steps.contains { $0.text.contains("sub-agent") } && steps.last?.text == "Fixed: a missing comma.",
              "a sub-agent's words left out; the next prompt's not taken in")
    } else {
        check(false, "a stand-in Claude Code turn")
    }

    // A web search sums up as Claude Code does, not as its raw results.
    let search = [
        jsonLine(["uuid": "q1", "parentUuid": NSNull(), "type": "user", "timestamp": at(0), "message": ["role": "user", "content": "Find the paper"]]),
        jsonLine(["uuid": "q2", "parentUuid": "q1", "type": "assistant", "timestamp": at(1),
                  "message": ["role": "assistant", "id": "m1", "model": "claude",
                              "content": [["type": "tool_use", "id": "w1", "name": "WebSearch", "input": ["query": "quasi-free CCR maps"]]]]]),
        jsonLine(["uuid": "q3", "parentUuid": "q2", "type": "user", "timestamp": at(4),
                  "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "w1",
                                                           "content": "Web search results for query: \"quasi-free CCR maps\"\n\nLinks: [{\"title\": \"…\"}]"]]],
                  "toolUseResult": ["query": "quasi-free CCR maps", "results": [], "durationSeconds": 3.2, "searchCount": 1]]),
    ].compactMap { JSON.parse($0) }
    if let asked = SessionHistoryReader.claude(lines: search, sessionID: "s-2").turns.first {
        let found = SessionHistoryReader.steps(agent: .claude, lines: search, turn: asked, cwd: nil)
        check(found.first?.text == "Web Search(\"quasi-free CCR maps\")" && found.first?.outcome == "Did 1 search in 3s",
              "a web search: \(found.first?.outcome ?? "no outcome")")
    }

    // Codex: a turn as completed items; one as response items (older Codex).
    func stamp(_ second: Int) -> Double { 1_792_000_000_000 + Double(second) * 1000 }
    func event(_ second: Int, _ payload: [String: Any]) -> String {
        jsonLine(["type": "event_msg", "timestamp": "2026-10-19T10:00:\(String(format: "%02d", second)).000Z", "payload": payload])
    }
    func item(_ second: Int, _ item: [String: Any]) -> String {
        event(second, ["type": "item_completed", "turn_id": "t1", "completed_at_ms": stamp(second), "item": item])
    }
    let codex = [
        jsonLine(["type": "session_meta", "payload": ["id": "th-1", "cwd": "/repo"]]),
        event(0, ["type": "task_started", "turn_id": "t1"]),
        item(1, ["type": "UserMessage", "content": [["type": "text", "text": "Run the tests"]]]),
        item(2, ["type": "AgentMessage", "content": [["type": "output_text", "text": "Running them."]]]),
        item(3, ["type": "CommandExecution", "command": ["/bin/zsh", "-lc", "pytest -q"], "aggregated_output": "1 failed", "exit_code": 1, "status": "completed"]),
        item(4, ["type": "FileChange", "status": "completed",
                 "changes": ["/repo/app.py": ["type": "update", "unified_diff": "@@ -3 +3 @@\n-x = 1\n+x = 2\n"],
                             "/repo/new.py": ["type": "add", "content": "print(2)\n"]]]),
        item(5, ["type": "AgentMessage", "content": [["type": "output_text", "text": "Fixed."]]]),
        event(6, ["type": "task_complete", "turn_id": "t1"]),
        event(7, ["type": "user_message", "message": "And the docs"]),
        jsonLine(["type": "response_item", "payload": ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "On it."]]]]),
        jsonLine(["type": "response_item", "payload": ["type": "function_call", "name": "shell", "call_id": "c1",
                                                       "arguments": "{\"command\":[\"bash\",\"-lc\",\"make docs\"]}"]]),
        jsonLine(["type": "response_item", "payload": ["type": "function_call_output", "call_id": "c1",
                                                       "output": "{\"output\":\"built\",\"metadata\":{\"exit_code\":0}}"]]),
        jsonLine(["type": "response_item", "payload": ["type": "custom_tool_call", "name": "apply_patch", "call_id": "c2",
                                                       "input": "*** Begin Patch\n*** Update File: /repo/README.md\n@@\n-old\n+new\n*** End Patch"]]),
    ]
    let codexLines = codex.compactMap { JSON.parse($0) }
    let codexHistory = SessionHistoryReader.codex(lines: codexLines, sessionID: "th-1")
    let codexTurns = codexHistory.turns.sorted { $0.askedAt < $1.askedAt }
    if codexTurns.count == 2 {
        let items = SessionHistoryReader.steps(agent: .codex, lines: codexLines, turn: codexTurns[0], cwd: "/repo")
        check(items.map(\.kind) == [.said, .ran, .changed, .changed, .said], "Codex's items: said, ran, two files changed, said")
        check(items.count == 5 && items[1].text == "Shell(pytest -q)" && items[1].failed && items[1].outcome == "Exit 1"
              && items[1].output == "1 failed", "a command that failed: its exit in a line, its output for a click")
        check(items.count == 5 && items[2].text == "Update(app.py)" && items[2].hunks.first?.newStart == 3
              && items[3].text == "Write(new.py)" && items[3].outcome == "Wrote 1 line",
              "a file's change by its diff, a new file whole")
        let older = SessionHistoryReader.steps(agent: .codex, lines: codexLines, turn: codexTurns[1], cwd: "/repo")
        check(older.map(\.kind) == [.said, .ran, .changed] && older[1].text == "Shell(make docs)" && older[1].output == "built"
              && older[2].text == "Update(README.md)", "older Codex: a message, a call and its output, a patch")
    } else {
        check(false, "two stand-in Codex turns: \(codexTurns.count)")
    }

    // Code mode: a script runs a command and applies a patch; the items that follow
    // give the command's output and the file's line numbers, without doubling either.
    let script = #"const r = await tools.exec_command({cmd:"pytest -q","workdir":"/repo"}); text(r.output);\n"#
        + #"await tools.apply_patch("*** Begin Patch\n*** Update File: /repo/a.py\n@@\n-x = \"1\"\n+x = \"2\"\n*** End Patch");"#
    let coded = [
        item(10, ["type": "UserMessage", "content": [["type": "text", "text": "Fix it"]]]),
        item(11, ["type": "AgentMessage", "content": [["type": "output_text", "text": "Fixing."]]]),
        jsonLine(["type": "response_item", "payload": ["type": "custom_tool_call", "name": "exec", "call_id": "s1", "input": script]]),
        item(12, ["type": "CommandExecution", "command": ["/bin/zsh", "-lc", "pytest -q"], "aggregated_output": "2 passed", "exit_code": 0]),
        item(13, ["type": "FileChange", "status": "completed",
                  "changes": ["/repo/a.py": ["type": "update", "unified_diff": "@@ -3 +3 @@\n-x = \"1\"\n+x = \"2\"\n"]]]),
        jsonLine(["type": "response_item", "payload": ["type": "custom_tool_call_output", "call_id": "s1", "output": [["type": "input_text", "text": "done"]]]]),
    ].compactMap { JSON.parse($0) }
    if let asked = SessionHistoryReader.codex(lines: coded, sessionID: "th-2").turns.first {
        let found = SessionHistoryReader.steps(agent: .codex, lines: coded, turn: asked, cwd: "/repo")
        check(found.map(\.text) == ["Fixing.", "Shell(pytest -q)", "Update(a.py)"] && found[1].output == "2 passed"
              && found[2].hunks.first?.newStart == 3 && found[2].hunks.first?.lines == ["-x = \"1\"", "+x = \"2\""],
              "Codex's code mode: a script's command and patch, each once, with its item's output and line numbers: \(found.map(\.text))")
    } else {
        check(false, "a stand-in code-mode turn")
    }

    // From a server: the script sends back the turn's lines, and they read the same.
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("ab-steps-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: home) }
    let projects = home.appendingPathComponent(".claude/projects/-home-me-app")
    let sessions = home.appendingPathComponent(".codex/sessions/2026/10/19")
    try? FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    let claudeLog = projects.appendingPathComponent("s-1.jsonl")
    let codexLog = sessions.appendingPathComponent("rollout-2026-10-19T10-00-00-th-1.jsonl")
    try? claude.joined(separator: "\n").write(to: claudeLog, atomically: true, encoding: .utf8)
    try? codex.joined(separator: "\n").write(to: codexLog, atomically: true, encoding: .utf8)
    let transport = ["/usr/bin/env", "HOME=\(home.path)", "python3", "-"]
    for (agent, log, turn) in [(Agent.claude, claudeLog, history.turns.first { $0.id == "p1" }), (.codex, codexLog, codexTurns.first)] {
        guard let turn else { continue }
        let cwd = agent == .claude ? "/home/me/app" : "/repo"
        let local = SessionHistoryReader.steps(agent: agent, path: log.path, turn: turn, cwd: cwd)
        let remote = try? RemoteHistory.steps(host: "test", agent: agent, path: log.path, sessionID: "s", turn: turn, cwd: cwd, transport: transport).get()
        check(local != nil && local == remote && !(local ?? []).isEmpty, "\(agent.clientName): a server's turn reads as the same steps")
    }
}

/// A Codex thread open for writing in another program: Agent Buddy says who,
/// here and on a server, and Codex's refusal reads in words.
func checkCodexWriter() {
    print("A Codex thread open elsewhere")
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("ab-writer-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: home) }
    let locks = home.appendingPathComponent(".codex/thread-writer-locks")
    let sessions = home.appendingPathComponent(".codex/sessions/2026/10/27")
    try? FileManager.default.createDirectory(at: locks, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    let thread = "01a17b77-0000-7000-8000-000000000001"
    let log = sessions.appendingPathComponent("rollout-2026-10-27T11-46-10-\(thread).jsonl")
    try? [jsonLine(["type": "session_meta", "payload": ["id": thread, "cwd": "/repo"]]),
          jsonLine(["type": "event_msg", "timestamp": "2026-10-27T03:46:10.000Z", "payload": ["type": "user_message", "message": "Hi"]])]
        .joined(separator: "\n").write(to: log, atomically: true, encoding: .utf8)
    let lock = locks.appendingPathComponent("\(thread).lock").path
    check(CodexWriter.holder(thread: thread, home: home) == nil, "no lock file: nobody has it open")

    // A stand-in Codex holds the thread's lock, as Codex does while it's open: a
    // program named codex…, for only Codex is ever stopped to take a thread.
    let source = home.appendingPathComponent("stand-in.c")
    let program = home.appendingPathComponent("codex-stand-in")
    try? """
    #include <fcntl.h>
    #include <stdio.h>
    #include <sys/file.h>
    #include <unistd.h>
    int main(int argc, char **argv) {
        int fd = open(argv[1], O_RDONLY | O_CREAT, 0644);
        flock(fd, LOCK_EX);
        printf("locked\\n");
        fflush(stdout);
        sleep(60);
        return 0;
    }
    """.write(to: source, atomically: true, encoding: .utf8)
    _ = ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/cc"), ["-o", program.path, source.path], timeout: 60)
    let holder = Process()
    holder.executableURL = program
    holder.arguments = [lock]
    let pipe = Pipe()
    holder.standardOutput = pipe
    guard (try? holder.run()) != nil else {
        check(false, "a stand-in Codex runs")
        return
    }
    defer { holder.terminate() }
    _ = pipe.fileHandleForReading.availableData
    check(CodexWriter.holder(thread: thread, home: home) == "Codex in a terminal", "held: who has it, in words")
    let transport = ["/usr/bin/env", "HOME=\(home.path)", "python3", "-"]
    if case .success(let history) = RemoteHistory.fetch(host: "test", agent: .codex, path: log.path, sessionID: thread, transport: transport) {
        // On a Mac there's no /proc to say who: "another program".
        check(history.openElsewhere != nil, "a server says so with the history: \(history.openElsewhere ?? "nobody")")
    } else {
        check(false, "the stand-in server reads the thread")
    }
    check(RemoteHistory.codexWriter(host: "test", thread: thread, transport: transport) != nil, "and the short check of the server alone says so too")
    // Taking it over: only the Codex that holds it is stopped.
    if let held = CodexWriter.holderProcess(thread: thread, home: home) {
        check(held.name == "Codex in a terminal" && held.pid == holder.processIdentifier && held.threads == [thread],
              "who holds it: its process, and the threads it holds")
        check(!CodexWriter.stop(thread: thread, pid: held.pid + 1, home: home) && holder.isRunning,
              "a process that doesn't hold it isn't stopped")
        check(CodexWriter.stop(thread: thread, pid: held.pid, home: home) && CodexWriter.holderProcess(thread: thread, home: home) == nil,
              "stopping the Codex that holds it frees the thread")
    } else {
        check(false, "the holder's process is found")
    }
    holder.terminate()
    holder.waitUntilExit()
    // A holder that isn't Codex is never stopped.
    let other = Process()
    other.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    other.arguments = ["python3", "-c", "import fcntl, os, sys, time\nfd = os.open(sys.argv[1], os.O_RDONLY | os.O_CREAT)\nfcntl.flock(fd, fcntl.LOCK_EX)\nprint('locked', flush=True)\ntime.sleep(60)", lock]
    let otherPipe = Pipe()
    other.standardOutput = otherPipe
    if (try? other.run()) != nil {
        _ = otherPipe.fileHandleForReading.availableData
        let held = CodexWriter.holderProcess(thread: thread, home: home)
        check(held?.name == "another program" && !CodexWriter.stop(thread: thread, pid: held?.pid ?? 0, home: home) && other.isRunning,
              "a lock held by something that isn't Codex: never stopped")
        other.terminate()
        other.waitUntilExit()
    }
    check(CodexWriter.holder(thread: thread, home: home) == nil && RemoteHistory.codexWriter(host: "test", thread: thread, transport: transport) == nil,
          "let go: nobody has it open")
    check(CodexWriter.describe("/home/me/.vscode-server/extensions/openai.chatgpt-26/bin/codex app-server") == "VS Code"
          && CodexWriter.describe("/Applications/ChatGPT.app/Contents/Resources/codex-cli/codex app-server") == "the Codex app"
          && CodexWriter.describe("codex resume 01a1") == "Codex in a terminal", "the program, from its command line")
    check(CodexWriter.plain("Error: thread/resume: thread/resume failed: thread x already has an active writer (code -32600)").hasPrefix("Codex has this thread open elsewhere"),
          "Codex's refusal, in words")
}
