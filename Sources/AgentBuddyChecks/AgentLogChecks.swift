import Foundation
import SQLite3
import AgentBuddyCore

/// The agents watched through their logs alone: a session of each, in its own
/// format (Gemini CLI's JSON and JSONL, Qwen Code's JSONL, OpenCode's and
/// Cursor's SQLite, DeepSeek Harness's JSONL, plain and Zstandard), read into
/// prompts, answers and tokens; then watched, and counted.
func checkAgentLogs() {
    print("Gemini CLI, Qwen Code, OpenCode, Cursor and DeepSeek Harness, from their logs")
    let manager = FileManager.default
    let scratch = manager.temporaryDirectory.appendingPathComponent("ab-agentlogs-\(UUID().uuidString)")
    defer { try? manager.removeItem(at: scratch) }
    let roots = AgentLogRoots(
        gemini: scratch.appendingPathComponent("gemini"), qwen: scratch.appendingPathComponent("qwen"),
        openCode: scratch.appendingPathComponent("opencode/opencode.db"), cursor: scratch.appendingPathComponent("cursor/chats"),
        deepseek: scratch.appendingPathComponent("dsh/sessions"))
    let now = Date()
    func stamp(_ seconds: TimeInterval) -> String {
        ISO8601DateFormatter.string(from: now.addingTimeInterval(seconds), timeZone: TimeZone(secondsFromGMT: 0)!,
                                    formatOptions: [.withInternetDateTime, .withFractionalSeconds])
    }
    func ms(_ seconds: TimeInterval) -> Int64 { Int64((now.addingTimeInterval(seconds).timeIntervalSince1970 * 1000).rounded()) }
    func write(_ lines: [String], _ url: URL) {
        try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
    func sql(_ path: String, _ statements: String) {
        try? manager.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK else { return }
        sqlite3_exec(db, statements, nil, nil, nil)
        sqlite3_close(db)
    }
    func tokens(_ turn: PromptTurn?) -> TokenCounts { turn?.usage.reduce(TokenCounts()) { $0 + $1.counts } ?? TokenCounts() }

    // Gemini CLI, newer: JSONL, a tool call's result and the tokens patched in later, a rewind.
    let geminiFile = roots.gemini.appendingPathComponent("tmp/work/chats/session-2026-10-28T09-00-g1.jsonl")
    write([
        #"{"sessionId":"g-1","projectHash":"h","startTime":"\#(stamp(-60))","kind":"main"}"#,
        #"{"id":"m1","timestamp":"\#(stamp(-60))","type":"user","content":[{"text":"Fix the failing test"}]}"#,
        #"{"id":"m2","timestamp":"\#(stamp(-50))","type":"gemini","content":"","model":"gemini-3-pro","toolCalls":[{"id":"t1","name":"run_shell_command","status":"executing"}]}"#,
        #"{"$patch":{"id":"m2","toolCalls":[{"id":"t1","status":"success","result":[{"text":"1 failed"}]}],"tokens":{"input":1000,"output":40,"cached":200,"thoughts":10,"tool":5,"total":1055}}}"#,
        #"{"id":"m3","timestamp":"\#(stamp(-40))","type":"gemini","content":"A first try.","model":"gemini-3-pro"}"#,
        #"{"$rewindTo":"m3"}"#,
        #"{"id":"m4","timestamp":"\#(stamp(-30))","type":"gemini","content":"Fixed: the date was off by one.","model":"gemini-3-pro","tokens":{"input":1200,"output":60,"cached":1000,"thoughts":0,"tool":0,"total":1260}}"#,
        #"{"id":"m5","timestamp":"\#(stamp(-20))","type":"user","content":[{"text":"/quit"}]}"#,
    ], geminiFile)
    if case .success(let session) = AgentLogs.read(agent: .gemini, path: geminiFile.path) {
        let turn = session.history.turns.first
        check(session.history.turns.count == 1 && turn?.text == "Fix the failing test" && turn?.outcome == .completed
              && turn?.answer == "Fixed: the date was off by one.", "Gemini CLI (JSONL): a prompt, its last answer (a rewound one dropped), a command left out")
        let counts = tokens(turn)
        check(counts.input == 805 + 200 && counts.output == 110 && counts.cacheRead == 1200 && session.tokens.count == 2,
              "its tokens: patched in, cache apart, thinking as output: \(counts)")
        check(session.history.model == "gemini-3-pro" && session.history.sessionID == "g-1", "its model and session")
    } else {
        check(false, "a Gemini CLI JSONL session reads")
    }
    // Gemini CLI, older: one JSON object; the project's folder from projects.json.
    let older = roots.gemini.appendingPathComponent("tmp/work/chats/session-2026-10-28T08-00-g0.json")
    try? #"{"sessionId":"g-0","projectHash":"h","startTime":"\#(stamp(-300))","lastUpdated":"\#(stamp(-200))","kind":"main","messages":[{"id":"a","timestamp":"\#(stamp(-300))","type":"user","content":[{"text":"Hello"}]},{"id":"b","timestamp":"\#(stamp(-290))","type":"gemini","content":"Hi.","model":"gemini-3-flash","tokens":{"input":10,"output":2,"cached":0,"thoughts":0,"tool":0,"total":12}}]}"#
        .write(to: older, atomically: true, encoding: .utf8)
    if case .success(let session) = AgentLogs.read(agent: .gemini, path: older.path) {
        check(session.history.turns.first?.answer == "Hi." && session.history.turns.first?.outcome == .completed, "Gemini CLI (JSON, before 0.4x): read the same")
    } else {
        check(false, "an older Gemini CLI session reads")
    }

    // Qwen Code: JSONL, its turn_result ending the turn.
    let qwenFile = roots.qwen.appendingPathComponent("projects/-work/chats/q-1.jsonl")
    write([
        #"{"uuid":"u1","parentUuid":null,"sessionId":"q-1","timestamp":"\#(stamp(-120))","type":"user","cwd":"/work","version":"0.26.1","message":{"role":"user","parts":[{"text":"Add tests"}]}}"#,
        #"{"uuid":"a1","parentUuid":"u1","sessionId":"q-1","timestamp":"\#(stamp(-110))","type":"assistant","cwd":"/work","model":"qwen3-coder-plus","message":{"role":"model","parts":[{"functionCall":{"name":"run_shell_command","args":{}}}]},"usageMetadata":{"promptTokenCount":500,"candidatesTokenCount":20,"cachedContentTokenCount":100,"thoughtsTokenCount":5,"totalTokenCount":525}}"#,
        #"{"uuid":"r1","parentUuid":"a1","sessionId":"q-1","timestamp":"\#(stamp(-100))","type":"tool_result","cwd":"/work"}"#,
        #"{"uuid":"a2","parentUuid":"r1","sessionId":"q-1","timestamp":"\#(stamp(-90))","type":"assistant","cwd":"/work","model":"qwen3-coder-plus","message":{"role":"model","parts":[{"text":"Tests added."}]},"usageMetadata":{"promptTokenCount":700,"candidatesTokenCount":30,"cachedContentTokenCount":500,"totalTokenCount":730}}"#,
        #"{"uuid":"s1","parentUuid":"a2","sessionId":"q-1","timestamp":"\#(stamp(-89))","type":"system","subtype":"turn_result","cwd":"/work","systemPayload":{"promptId":"p1","state":"completed","startedAt":\#(ms(-120)),"endedAt":\#(ms(-89))}}"#,
        #"{"uuid":"u2","parentUuid":"s1","sessionId":"q-1","timestamp":"\#(stamp(-60))","type":"user","cwd":"/work","message":{"role":"user","parts":[{"text":"Now run them"}]}}"#,
    ], qwenFile)
    if case .success(let session) = AgentLogs.read(agent: .qwen, path: qwenFile.path) {
        let turns = session.history.turns
        check(turns.count == 2 && turns[0].outcome == .completed && turns[0].answer == "Tests added." && turns[1].outcome == .running
              && session.history.cwd == "/work", "Qwen Code: ended by its turn_result, the next under way, its folder")
        let counts = tokens(turns.first)
        check(counts.input == 400 + 200 && counts.output == 55 && counts.cacheRead == 600, "its tokens: \(counts)")
    } else {
        check(false, "a Qwen Code session reads")
    }

    // OpenCode: its database: a session, a prompt and two replies (a tool call, then the answer).
    sql(roots.openCode.path, """
        CREATE TABLE session (id TEXT PRIMARY KEY, project_id TEXT, parent_id TEXT, directory TEXT, title TEXT, time_created INTEGER, time_updated INTEGER);
        CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, time_updated INTEGER, data TEXT);
        CREATE TABLE part (id TEXT PRIMARY KEY, message_id TEXT, session_id TEXT, time_created INTEGER, time_updated INTEGER, data TEXT);
        INSERT INTO session VALUES ('ses_1', 'global', NULL, '/Users/me/site', 'Deploy the site', \(ms(-100)), \(ms(-10)));
        INSERT INTO message VALUES ('msg_1', 'ses_1', \(ms(-100)), \(ms(-100)), '{"role":"user","time":{"created":\(ms(-100))}}');
        INSERT INTO part VALUES ('prt_1', 'msg_1', 'ses_1', \(ms(-100)), \(ms(-100)), '{"type":"text","text":"Deploy it"}');
        INSERT INTO message VALUES ('msg_2', 'ses_1', \(ms(-90)), \(ms(-80)), '{"parentID":"msg_1","role":"assistant","modelID":"deepseek-chat","providerID":"deepseek","tokens":{"input":300,"output":10,"reasoning":0,"cache":{"write":0,"read":50}},"time":{"created":\(ms(-90)),"completed":\(ms(-80))},"finish":"tool-calls"}');
        INSERT INTO message VALUES ('msg_3', 'ses_1', \(ms(-70)), \(ms(-10)), '{"parentID":"msg_1","role":"assistant","modelID":"deepseek-chat","providerID":"deepseek","tokens":{"input":20,"output":30,"reasoning":5,"cache":{"write":0,"read":350}},"time":{"created":\(ms(-70)),"completed":\(ms(-10))},"finish":"stop"}');
        INSERT INTO part VALUES ('prt_2', 'msg_3', 'ses_1', \(ms(-11)), \(ms(-11)), '{"type":"text","text":"Deployed."}');
        """)
    if case .success(let session) = AgentLogs.read(agent: .opencode, path: "\(roots.openCode.path)#ses_1") {
        let turn = session.history.turns.first
        check(session.history.turns.count == 1 && turn?.answer == "Deployed." && turn?.outcome == .completed
              && session.history.title == "Deploy the site" && session.history.cwd == "/Users/me/site",
              "OpenCode: from its database, a turn ended by a reply that stopped (not one that called tools)")
        check(tokens(turn) == TokenCounts(input: 320, output: 45, cacheRead: 400) && session.history.model == "deepseek-chat",
              "its tokens and model: \(tokens(turn))")
    } else {
        check(false, "an OpenCode session reads")
    }

    // Cursor's agent: its chat's store: meta (hexadecimal JSON) and messages as JSON blobs.
    let chat = roots.cursor.appendingPathComponent("abc/chat-1/store.db")
    let meta = Data(#"{"agentId":"chat-1","name":"Fix the login page","createdAt":\#(ms(-500)),"lastUsedModel":"gpt-5"}"#.utf8)
        .map { String(format: "%02x", $0) }.joined()
    sql(chat.path, """
        CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);
        CREATE TABLE blobs (id TEXT PRIMARY KEY, data BLOB);
        INSERT INTO meta VALUES ('0', '\(meta)');
        INSERT INTO blobs VALUES ('b1', CAST('{"role":"user","content":[{"type":"text","text":"<user_query>\\nFix the login page\\n</user_query>"}]}' AS BLOB));
        INSERT INTO blobs VALUES ('b2', CAST('{"role":"assistant","content":[{"type":"text","text":"The form posts twice; fixed."}]}' AS BLOB));
        INSERT INTO blobs VALUES ('b3', CAST('not json' AS BLOB));
        """)
    if case .success(let session) = AgentLogs.read(agent: .cursor, path: chat.path) {
        let turn = session.history.turns.first
        check(turn?.text == "Fix the login page" && turn?.answer == "The form posts twice; fixed." && session.history.title == "Fix the login page"
              && session.history.model == "gpt-5", "Cursor's agent: its chat's messages and name, best as its unpublished store allows")
    } else {
        check(false, "a Cursor chat reads")
    }

    // DeepSeek Harness: a header, then events; a forked session's inherited part left out.
    let harnessFolder = roots.deepseek.appendingPathComponent("--work--/d-1")
    let harnessLines = [
        #"{"type":"session","version":3,"id":"d-1","createdAt":\#(ms(-200)),"cwd":"/work","isSeeded":false,"delegationDepth":0}"#,
        #"{"type":"turn/start","seq":0,"time":\#(ms(-200)),"data":{"turn":1}}"#,
        #"{"type":"user/message","seq":1,"time":\#(ms(-200)),"data":{"id":"x","role":"user","source":{"kind":"user"},"content":[{"type":"text","text":"Summarize this repository"}]}}"#,
        #"{"type":"user/message","seq":2,"time":\#(ms(-199)),"data":{"id":"y","role":"user","source":{"kind":"agents-md"},"content":[{"type":"text","text":"(instructions)"}]}}"#,
        #"{"type":"assistant/message","seq":3,"time":\#(ms(-150)),"data":{"turn":1,"step":1,"message":{"role":"assistant","source":{"kind":"model","model":"deepseek-v4"},"content":[{"type":"text","text":"It's a menu bar app."}]},"stream":[],"usage":{"inputTokens":300,"outputTokens":80,"totalTokens":980,"cacheReadTokens":600}}}"#,
        #"{"type":"turn/end","seq":4,"time":\#(ms(-149)),"data":{"turn":1,"reason":{"kind":"completed"}}}"#,
        #"{"type":"turn/start","seq":5,"time":\#(ms(-100)),"data":{"turn":2}}"#,
        #"{"type":"user/message","seq":6,"time":\#(ms(-100)),"data":{"role":"user","source":{"kind":"user"},"content":[{"type":"text","text":"Stop that"}]}}"#,
        #"{"type":"turn/end","seq":7,"time":\#(ms(-90)),"data":{"turn":2,"reason":{"kind":"aborted","reason":"user"}}}"#,
    ]
    write(harnessLines, harnessFolder.appendingPathComponent("session.v3.jsonl"))
    write(harnessLines, harnessFolder.appendingPathComponent("session.jsonl"))
    if case .success(let session) = AgentLogs.read(agent: .deepseek, path: harnessFolder.appendingPathComponent("session.v3.jsonl").path) {
        let turns = session.history.turns
        check(turns.count == 2 && turns[0].text == "Summarize this repository" && turns[0].answer == "It's a menu bar app."
              && turns[0].outcome == .completed && turns[1].outcome == .interrupted && session.history.cwd == "/work",
              "DeepSeek Harness: turns closed by turn/end (one stopped), injected context isn't a prompt")
        check(tokens(turns.first) == TokenCounts(input: 300, output: 80, cacheRead: 600) && session.history.model == "deepseek-v4",
              "its tokens and model: \(tokens(turns.first))")
    } else {
        check(false, "a DeepSeek Harness session reads")
    }
    let listed = AgentLogs.sessions(since: now.addingTimeInterval(-3600), roots: roots)
    check(listed.filter { $0.agent == .deepseek }.map { URL(fileURLWithPath: $0.path).lastPathComponent } == ["session.v3.jsonl"],
          "each Harness session's newest log is the one read")
    // Its default: Zstandard frames, undone by Node (as Harness itself runs on it).
    if let node = Executables.find("node") {
        let compressed = roots.deepseek.appendingPathComponent("--work--/d-2/session.v3.jsonl.zstd")
        try? manager.createDirectory(at: compressed.deletingLastPathComponent(), withIntermediateDirectories: true)
        let plain = harnessFolder.appendingPathComponent("session.v3.jsonl").path
        _ = ProcessRunner.run(node, ["-e", "const z=require('zlib'),f=require('fs');f.writeFileSync(process.argv[2],z.zstdCompressSync(f.readFileSync(process.argv[1])))",
                                     plain, compressed.path], timeout: 20)
        if case .success(let session) = AgentLogs.read(agent: .deepseek, path: compressed.path) {
            check(session.history.turns.count == 2 && session.history.turns.first?.answer == "It's a menu bar app.",
                  "DeepSeek Harness's Zstandard-compressed log, through Node")
        } else {
            check(false, "a compressed Harness session reads (Node: \(node.path))")
        }
    }

    // Watched: a turn under way works; its end reminds, once.
    let watcher = AgentLogWatcher(roots: roots)
    var jobs: [JobEvent] = []
    watcher.onJob = { jobs.append($0) }
    let live = roots.gemini.appendingPathComponent("tmp/work/chats/session-live.jsonl")
    write([
        #"{"sessionId":"g-live","projectHash":"h","startTime":"\#(stamp(1))","kind":"main"}"#,
        #"{"id":"p","timestamp":"\#(stamp(1))","type":"user","content":[{"text":"Refactor the parser"}]}"#,
        #"{"id":"r","timestamp":"\#(stamp(2))","type":"gemini","content":"","toolCalls":[{"id":"t","name":"read_file","status":"executing"}]}"#,
    ], live)
    watcher.check(live.path, agent: .gemini)
    var working: [WorkingSession] = []
    let asked = DispatchSemaphore(value: 0)
    watcher.workingSessions { working = $0; asked.signal() }
    asked.wait()
    check(jobs.isEmpty && working.map(\.sessionID) == ["g-live"], "a turn under way: working, no reminder yet")
    write([
        #"{"sessionId":"g-live","projectHash":"h","startTime":"\#(stamp(1))","kind":"main"}"#,
        #"{"id":"p","timestamp":"\#(stamp(1))","type":"user","content":[{"text":"Refactor the parser"}]}"#,
        #"{"id":"r","timestamp":"\#(stamp(2))","type":"gemini","content":"","toolCalls":[{"id":"t","name":"read_file","status":"success","result":[]}]}"#,
        #"{"id":"s","timestamp":"\#(stamp(3))","type":"gemini","content":"Done: the parser is split in two.","model":"gemini-3-pro"}"#,
    ], live)
    watcher.check(live.path, agent: .gemini)
    watcher.check(live.path, agent: .gemini)
    check(jobs.count == 1 && jobs.first?.agent == .gemini && jobs.first?.outcome == .completed && jobs.first?.sessionID == "g-live"
          && jobs.first?.summary == "Done: the parser is split in two." && jobs.first?.transcriptPath == live.path,
          "its end reminds, once, with its last words: \(jobs.map(\.id))")
    watcher.workingSessions { working = $0; asked.signal() }
    asked.wait()
    check(working.isEmpty, "and it's working no longer")
    // A turn that ended before watching began reminds no one.
    let quiet = AgentLogWatcher(roots: roots)
    var old: [JobEvent] = []
    quiet.onJob = { old.append($0) }
    quiet.check(geminiFile.path, agent: .gemini)
    check(old.isEmpty, "a turn that ended before watching began reminds no one")

    // Through file-system events, as the app watches: a Qwen session's turn ends.
    let streamed = AgentLogWatcher(roots: roots)
    streamed.debounce = 0.3
    let heard = NSMutableArray()
    streamed.onJob = { event in
        heard.add(event.id)
    }
    streamed.start()
    Thread.sleep(forTimeInterval: 1)
    // Times from now: the turn ends after watching began.
    let later = Date().timeIntervalSince(now)
    write([
        #"{"uuid":"v1","parentUuid":null,"sessionId":"q-live","timestamp":"\#(stamp(later + 1))","type":"user","cwd":"/work","message":{"role":"user","parts":[{"text":"Lint it"}]}}"#,
        #"{"uuid":"v2","parentUuid":"v1","sessionId":"q-live","timestamp":"\#(stamp(later + 2))","type":"assistant","cwd":"/work","message":{"role":"model","parts":[{"text":"Linted."}]}}"#,
        #"{"uuid":"v3","parentUuid":"v2","sessionId":"q-live","timestamp":"\#(stamp(later + 3))","type":"system","subtype":"turn_result","cwd":"/work","systemPayload":{"state":"completed","endedAt":\#(ms(later + 3))}}"#,
    ], roots.qwen.appendingPathComponent("projects/-work/chats/q-live.jsonl"))
    let until = Date().addingTimeInterval(8)
    while Date() < until, !heard.contains("qwen:q-live:v1") {
        Thread.sleep(forTimeInterval: 0.1)
    }
    streamed.stop()
    check((heard as? [String])?.contains("qwen:q-live:v1") == true, "seen through file-system events, as the app watches: \(heard)")

    // Counted: each reply's tokens, by agent, with the others' logs.
    let ledger = TokenLedger(roots: TranscriptWatcher.Roots(
        claudeProjects: scratch.appendingPathComponent("none/claude"), codexSessions: scratch.appendingPathComponent("none/codex"),
        codexIndex: nil, copilotSessions: scratch.appendingPathComponent("none/copilot")), logRoots: roots, cacheURL: nil)
    let entries = ledger.refresh()
    let agents = Set(entries.map(\.agent))
    check(agents.isSuperset(of: [.gemini, .qwen, .opencode, .deepseek]) && entries.contains { $0.agent == .opencode && $0.model == "deepseek-chat" },
          "their tokens count in Token usage, by agent and model: \(agents.map(\.rawValue).sorted())")
}
