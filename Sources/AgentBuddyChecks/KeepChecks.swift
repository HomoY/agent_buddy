import Foundation
import AgentBuddyCore

/// A session kept open in the background: stand-ins for Claude Code's
/// stream-json mode and Codex's app-server, here and through the server's
/// launcher (a shell in place of ssh).
func checkKeptSessions() {
    print("A session kept open in the background")
    let manager = FileManager.default
    let scratch = manager.temporaryDirectory.appendingPathComponent("ab-keep-\(UUID().uuidString)")
    defer { try? manager.removeItem(at: scratch) }
    let bin = scratch.appendingPathComponent("bin")
    let folder = scratch.appendingPathComponent("work")
    try? manager.createDirectory(at: bin, withIntermediateDirectories: true)
    try? manager.createDirectory(at: folder, withIntermediateDirectories: true)
    let heard = scratch.appendingPathComponent("heard.log")

    // Claude Code reading prompts as stream-json: a result line per prompt.
    let claude = bin.appendingPathComponent("claude")
    try? """
    #!/usr/bin/env python3
    import json, sys
    log = open(sys.argv[0] + ".args", "w"); log.write(" ".join(sys.argv[1:])); log.close()
    told = open(sys.argv[0] + ".told", "a")
    for line in sys.stdin:
        o = json.loads(line)
        if o.get("type") == "control_request":
            told.write(line); told.flush()
            if o["request"]["subtype"] == "interrupt":
                print(json.dumps({"type": "result", "is_error": True, "result": "Interrupted"}), flush=True)
            else:
                print(json.dumps({"type": "control_response", "response": {"subtype": "success", "request_id": o["request_id"]}}), flush=True)
            continue
        told.write(json.dumps({"content": [c["type"] for c in o["message"]["content"]],
                               "media": [c.get("source", {}).get("media_type") for c in o["message"]["content"]]}) + "\\n"); told.flush()
        text = o["message"]["content"][0]["text"]
        print(json.dumps({"type": "system", "subtype": "init"}), flush=True)
        if text == "fail":
            print(json.dumps({"type": "result", "is_error": True, "result": "Boom"}), flush=True)
        elif text != "wait":
            print(json.dumps({"type": "result", "is_error": False, "result": "Done: " + text}), flush=True)
    """.write(to: claude, atomically: true, encoding: .utf8)
    // Codex's app-server: the handshake, a thread "held" elsewhere, and an approval it asks for.
    let codex = bin.appendingPathComponent("codex")
    try? """
    #!/usr/bin/env python3
    import json, sys
    heard = open(\(String(reflecting: heard.path)), "a")
    def send(o): print(json.dumps(o), flush=True)
    for line in sys.stdin:
        o = json.loads(line)
        heard.write(line); heard.flush()
        method, i = o.get("method"), o.get("id")
        if method == "initialize":
            send({"id": i, "result": {"userAgent": "stand-in"}})
        elif method == "model/list":
            send({"id": i, "result": {"data": [
                {"id": "m-1", "model": "gpt-stand-in", "displayName": "GPT Stand-In", "hidden": False, "isDefault": True,
                 "supportedReasoningEfforts": [{"reasoningEffort": "low"}, {"reasoningEffort": "ultra"}], "defaultReasoningEffort": "low",
                 "serviceTiers": [{"id": "priority", "name": "Fast"}], "additionalSpeedTiers": ["fast"]},
                {"id": "m-2", "model": "gpt-slow", "displayName": "GPT Slow", "hidden": False,
                 "supportedReasoningEfforts": [{"reasoningEffort": "medium"}], "defaultReasoningEffort": "medium", "serviceTiers": []},
                {"id": "m-3", "model": "gpt-hidden", "displayName": "Hidden", "hidden": True, "supportedReasoningEfforts": []}],
                "nextCursor": None}})
        elif method == "thread/resume":
            if o["params"]["threadId"] == "held-thread":
                send({"id": i, "error": {"code": -32600, "message": "thread/resume failed: thread held-thread already has an active writer"}})
            else:
                send({"id": i, "result": {"thread": {"id": o["params"]["threadId"]}}})
        elif method == "turn/start":
            send({"id": i, "result": {"turn": {"id": "turn-1", "status": "inProgress"}}})
            send({"method": "turn/started", "params": {"threadId": "t", "turn": {"id": "turn-1"}}})
            if o["params"]["input"][0].get("text") != "wait":
                send({"id": 99, "method": "item/commandExecution/requestApproval", "params": {}})
        elif method == "turn/steer":
            if o["params"].get("expectedTurnId") == "turn-1":
                send({"id": i, "result": {"turnId": "turn-1"}})
            else:
                send({"id": i, "error": {"code": -32600, "message": "no active turn to steer"}})
        elif method == "turn/interrupt":
            send({"id": i, "result": {}})
            send({"method": "turn/completed", "params": {"threadId": "t", "turn": {"id": "turn-1", "status": "interrupted"}}})
        elif i == 99 and method is None:
            send({"method": "turn/completed", "params": {"threadId": "t", "turn": {"id": "turn-1", "status": "completed"}}})
    """.write(to: codex, atomically: true, encoding: .utf8)
    for script in [claude, codex] {
        try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    }

    func waitFor(_ seconds: TimeInterval, _ done: () -> Bool) {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until, !done() {
            Thread.sleep(forTimeInterval: 0.05)
        }
    }
    func request(_ agent: Agent, _ session: String, host: String? = nil) -> PromptSender.Request {
        PromptSender.Request(agent: agent, sessionID: session, host: host, folder: folder.path, prompt: "", model: nil,
                             permissionMode: "auto", sandbox: "workspace-write", effort: "high")
    }

    // Claude Code, here.
    if case .success(let kept) = KeptSession.open(request(.claude, "s-1"), executable: claude) {
        waitFor(5) { kept.state == .ready }
        check(kept.state == .ready, "Claude Code: open, waiting for a prompt")
        let arguments = (try? String(contentsOf: URL(fileURLWithPath: claude.path + ".args"), encoding: .utf8)) ?? ""
        check(arguments.contains("--resume s-1") && arguments.contains("--input-format stream-json")
              && arguments.contains("--output-format stream-json") && arguments.contains("--permission-mode auto"),
              "resumed, reading its prompts as stream-json, with the session's permissions")
        if case .success = kept.send("Hello") {
            waitFor(5) { kept.state == .ready }
            check(kept.state == .ready && kept.problem == nil, "a prompt, its turn, and ready for the next")
        }
        _ = kept.send("fail")
        waitFor(5) { kept.state == .ready && kept.problem != nil }
        check(kept.problem == "Boom", "a turn that failed says why, and the session stays open")
        _ = kept.send("wait")
        check(kept.state == .working && { if case .failure = kept.send("again") { return true } else { return false } }(),
              "one prompt at a time")
        kept.interrupt()
        waitFor(5) { kept.state == .ready }
        check(kept.state == .ready, "a turn stopped, the session open")
        kept.close()
        waitFor(5) { kept.state == .closed(nil) }
        check(kept.state == .closed(nil), "let go: it ends")
        // Its output has ended: nothing may go on reading it.
        let before = cpuSeconds()
        Thread.sleep(forTimeInterval: 1)
        check(cpuSeconds() - before < 0.3, "let go: nothing spins on its ended output (\(cpuSeconds() - before) s of CPU in 1 s)")
    } else {
        check(false, "a stand-in Claude Code opens")
    }

    // Agent Buddy quitting: the input closed at once, and the agent ends with it.
    if case .success(let kept) = KeptSession.open(request(.claude, "s-3"), executable: claude) {
        waitFor(5) { kept.state == .ready }
        kept.closeNow()
        waitFor(5) { kept.state == .closed(nil) }
        check(kept.state == .closed(nil), "quitting: its input closed at once, the agent ends")
    }

    // Codex, here: the app-server's handshake, a turn, and an approval it can't ask anyone for.
    if case .success(let kept) = KeptSession.open(request(.codex, "th-1"), executable: codex) {
        waitFor(5) { kept.state == .ready }
        check(kept.state == .ready, "Codex: its app-server open on the thread")
        _ = kept.send("Run the tests")
        waitFor(5) { kept.state == .ready }
        let said = ((try? String(contentsOf: heard, encoding: .utf8)) ?? "").split(separator: "\n").compactMap { JSON.parse(String($0)) }
        let resume = said.first { $0["method"].string == "thread/resume" }?["params"]
        let started = said.first { $0["method"].string == "turn/start" }?["params"]
        check(resume?["approvalPolicy"].string == "never" && resume?["sandbox"].string == "workspace-write" && resume?["cwd"].string == folder.path,
              "the thread resumed never asking, in the session's sandbox and folder")
        check(started?["input"][0]["text"].string == "Run the tests" && started?["effort"].string == "high", "the prompt, with its effort")
        check(said.contains { $0["id"].int == 99 && !$0["error"].isNull } && kept.state == .ready,
              "an approval Codex asks for is refused, and the turn ends")
        kept.close()
        waitFor(5) { kept.state == .closed(nil) }
        check(kept.state == .closed(nil), "let go: the app-server ends, and Codex's hold on the thread with it")
    } else {
        check(false, "a stand-in Codex opens")
    }
    // Sent while Codex works: added to the turn under way, as typing into Codex then does.
    try? manager.removeItem(at: heard)
    if case .success(let kept) = KeptSession.open(request(.codex, "th-5"), executable: codex) {
        waitFor(5) { kept.state == .ready }
        final class Joined: @unchecked Sendable { var answers: [Bool] = [] }
        let joined = Joined()
        kept.steer(request(.codex, "th-5"), then: { joined.answers.append($0) })
        waitFor(2) { joined.answers.count == 1 }
        _ = kept.send("wait")
        waitFor(5) { kept.state == .working }
        Thread.sleep(forTimeInterval: 0.3)
        var more = request(.codex, "th-5")
        more.prompt = "Also check the tests"
        kept.steer(more, then: { joined.answers.append($0) })
        waitFor(5) { joined.answers.count == 2 }
        let said = ((try? String(contentsOf: heard, encoding: .utf8)) ?? "").split(separator: "\n").compactMap { JSON.parse(String($0)) }
        let steered = said.first { $0["method"].string == "turn/steer" }?["params"]
        check(joined.answers == [false, true] && steered?["expectedTurnId"].string == "turn-1" && steered?["threadId"].string == "th-5"
              && steered?["input"][0]["text"].string == "Also check the tests",
              "Codex at work: a prompt joins the turn under way (none to join when it's idle): \(joined.answers)")
        check(kept.state == .working, "and the turn goes on")
        kept.interrupt()
        waitFor(5) { kept.state == .ready }
        kept.close()
        waitFor(5) { kept.state == .closed(nil) }
    } else {
        check(false, "a stand-in Codex opens for a turn to join")
    }

    // A session Codex's own reviewer approves for, with a permission profile: resumed so.
    var reviewed = request(.codex, "th-2")
    reviewed.permissionProfile = ":workspace"
    reviewed.approvalPolicy = "on-request"
    reviewed.approvalsReviewer = "auto_review"
    try? manager.removeItem(at: heard)
    if case .success(let kept) = KeptSession.open(reviewed, executable: codex) {
        waitFor(5) { kept.state == .ready }
        let said = ((try? String(contentsOf: heard, encoding: .utf8)) ?? "").split(separator: "\n").compactMap { JSON.parse(String($0)) }
        let resume = said.first { $0["method"].string == "thread/resume" }?["params"]
        check(resume?["approvalPolicy"].string == "on-request" && resume?["approvalsReviewer"].string == "auto_review"
              && resume?["config"]["default_permissions"].string == ":workspace" && resume?["sandbox"].isNull == true,
              "a reviewed session: resumed asking Codex's reviewer, with its permission profile")
        kept.close()
        waitFor(5) { kept.state == .closed(nil) }
    } else {
        check(false, "a stand-in Codex opens a reviewed session")
    }
    if case .success(let held) = KeptSession.open(request(.codex, "held-thread"), executable: codex) {
        waitFor(5) { held.state != .opening }
        if case .closed(let why) = held.state {
            check(why?.hasPrefix("Codex has this thread open elsewhere") == true, "a thread open elsewhere: it says so, and closes")
        } else {
            check(false, "a thread open elsewhere isn't taken")
        }
    }

    // The message box's choices, told a kept session as they change, and images with the prompt.
    let picture = scratch.appendingPathComponent("shot.png")
    try? Data([0x89, 0x50, 0x4E, 0x47]).write(to: picture)
    try? manager.removeItem(atPath: claude.path + ".told")
    if case .success(let kept) = KeptSession.open(request(.claude, "s-2"), executable: claude) {
        waitFor(5) { kept.state == .ready }
        var asked = request(.claude, "s-2")
        asked.prompt = "Look at this"
        let chosen = asked.with(PromptSender.Options(model: "opus", effort: "max", fast: true, mode: "plan"))
        _ = kept.send(chosen, images: [picture])
        waitFor(5) { kept.state == .ready }
        _ = kept.send(chosen)
        waitFor(5) { kept.state == .ready }
        let told = ((try? String(contentsOf: URL(fileURLWithPath: claude.path + ".told"), encoding: .utf8)) ?? "")
            .split(separator: "\n").compactMap { JSON.parse(String($0)) }
        let requests = told.filter { !$0["request"].isNull }.map { $0["request"] }
        check(requests.contains { $0["subtype"].string == "set_model" && $0["model"].string == "opus" }
              && requests.contains { $0["subtype"].string == "set_permission_mode" && $0["mode"].string == "plan" }
              && requests.contains { $0["subtype"].string == "apply_flag_settings" && $0["settings"]["fastMode"].bool == true
                  && $0["settings"]["effortLevel"].string == "max" },
              "Claude Code kept open: the model, mode, fast mode and effort chosen are told it first")
        check(requests.count == 3, "and only once: the next prompt, with the same, tells it nothing new (\(requests.count) told)")
        let prompts = told.filter { !$0["content"].isNull }
        check(prompts.first?["content"].array.compactMap(\.string) == ["text", "image"] && prompts.first?["media"][1].string == "image/png",
              "an image goes with the prompt itself")
        kept.close()
        waitFor(5) { kept.state == .closed(nil) }
    } else {
        check(false, "a stand-in Claude Code opens for the choices")
    }
    try? manager.removeItem(at: heard)
    if case .success(let kept) = KeptSession.open(request(.codex, "th-3"), executable: codex) {
        waitFor(5) { kept.state == .ready }
        var asked = request(.codex, "th-3")
        asked.prompt = "Look at this"
        let chosen = asked.with(PromptSender.Options(model: "gpt-stand-in", effort: "ultra", fast: true, mode: "read-only"))
        _ = kept.send(chosen, images: [picture])
        waitFor(5) { kept.state == .ready }
        _ = kept.send(chosen)
        waitFor(5) { kept.state == .ready }
        let said = ((try? String(contentsOf: heard, encoding: .utf8)) ?? "").split(separator: "\n").compactMap { JSON.parse(String($0)) }
        let turns = said.filter { $0["method"].string == "turn/start" }.map { $0["params"] }
        let started = turns.first
        check(turns.count == 2 && turns[1]["effort"].string == "ultra" && turns[1]["serviceTier"].string == "fast" && turns[1]["sandboxPolicy"].isNull,
              "the next turn keeps the choices (not the session's opening effort), its sandbox told only once")
        check(started?["model"].string == "gpt-stand-in" && started?["effort"].string == "ultra" && started?["serviceTier"].string == "fast"
              && started?["approvalPolicy"].string == "never" && started?["sandboxPolicy"]["type"].string == "readOnly",
              "Codex kept open: the turn carries the model, effort, fast mode and mode chosen")
        check(started?["input"][1]["type"].string == "localImage" && started?["input"][1]["path"].string == picture.path,
              "and the image, by its path here")
        kept.close()
        waitFor(5) { kept.state == .closed(nil) }
    } else {
        check(false, "a stand-in Codex opens for the choices")
    }
    let auto = request(.codex, "th-4")
    let toAuto = KeptSession.codexChanges(from: auto, to: auto.with(PromptSender.Options(mode: "auto")))
    check(toAuto["approvalPolicy"] as? String == "on-request" && toAuto["approvalsReviewer"] as? String == "auto_review" && toAuto["sandboxPolicy"] == nil,
          "Auto, for Codex kept open: its reviewer decides, in the same sandbox")
    let slower = KeptSession.codexChanges(from: auto.with(PromptSender.Options(fast: true)), to: auto.with(PromptSender.Options(fast: false)))
    check(slower["serviceTier"] is NSNull, "fast mode off: back to the standard tier")

    // Codex's models, from its app-server: here, and through the launcher.
    if case .success(let models) = CodexModels.list(host: nil, executable: codex) {
        check(models.map(\.id) == ["gpt-stand-in", "gpt-slow"] && models[0].fast && !models[1].fast && models[0].efforts == ["low", "ultra"],
              "Codex's models, its efforts and fast mode, the hidden left out")
    } else {
        check(false, "Codex's models are listed")
    }

    // On a server: the launcher keeps the agent on the connection.
    let home = scratch.appendingPathComponent("home")
    let project = home.appendingPathComponent(".claude/projects/-work")
    try? manager.createDirectory(at: project, withIntermediateDirectories: true)
    try? "{}".write(to: project.appendingPathComponent("s-9.jsonl"), atomically: true, encoding: .utf8)
    let transport = ["/usr/bin/env", "HOME=\(home.path)", "PATH=\(bin.path):/usr/bin:/bin", "/bin/sh", "-c"]
    if case .success(let kept) = KeptSession.open(request(.claude, "s-9", host: "gpu"), transport: transport) {
        waitFor(8) { kept.state == .ready }
        _ = kept.send("Hello from afar")
        waitFor(5) { kept.state == .ready && kept.problem == nil }
        check(kept.state == .ready, "on a server, through the launcher: open, and a prompt's turn")
        kept.close()
        waitFor(5) { kept.state == .closed(nil) }
    } else {
        check(false, "a session on a server opens")
    }
    // A connection gone quiet (the Mac asleep, the connection never closed): the
    // launcher ends the agent there, but never in the middle of a turn.
    KeptSession.quietLimit = 2
    KeptSession.heartbeatInterval = 0.5
    if case .success(let kept) = KeptSession.open(request(.claude, "s-9", host: "gpu"), transport: transport) {
        waitFor(8) { kept.state == .ready }
        Thread.sleep(forTimeInterval: 4)
        check(kept.state == .ready, "on a server, told Agent Buddy's still there: it stays open")
        kept.close()
        waitFor(5) { kept.state == .closed(nil) }
    }
    KeptSession.heartbeatInterval = 3600
    if case .success(let kept) = KeptSession.open(request(.claude, "s-9", host: "gpu"), transport: transport) {
        waitFor(8) { kept.state == .ready }
        _ = kept.send("wait")
        Thread.sleep(forTimeInterval: 4)
        check(kept.state == .working, "gone quiet in the middle of a turn: the turn goes on")
        kept.interrupt()
        waitFor(10) { if case .closed = kept.state { return true } else { return false } }
        if case .closed(let why) = kept.state {
            check(why?.contains("without word from Agent Buddy") == true, "and once it's done, the agent there ends, saying why: \(why ?? "")")
        } else {
            check(false, "a quiet connection's agent ends once its turn is done")
        }
    }
    KeptSession.quietLimit = 600
    KeptSession.heartbeatInterval = 60
    if case .success(let refused) = KeptSession.open(request(.claude, "not-there", host: "gpu"), transport: transport) {
        waitFor(8) { refused.state != .opening }
        check(refused.state == .closed("that session isn't on this server anymore"), "a session the server doesn't have: it says so")
    }
    // The launcher run as the server's: the script on its input.
    let server = ["/usr/bin/env", "HOME=\(home.path)", "PATH=\(bin.path):/usr/bin:/bin", "python3", "-"]
    if case .success(let models) = CodexModels.list(host: "gpu", transport: server) {
        check(models.first?.name == "GPT Stand-In", "a server's Codex models, through the launcher")
    } else {
        check(false, "a server's Codex models are listed")
    }
    let notes = scratch.appendingPathComponent("notes, final.txt")
    try? "Line one".write(to: notes, atomically: true, encoding: .utf8)
    switch RemoteFiles.put([notes, picture], host: "gpu", transport: server) {
    case .success(let paths):
        let kept = home.appendingPathComponent(".cache/agent-buddy/attachments").path
        check(paths.count == 2 && paths.allSatisfy { $0.hasPrefix(kept + "/") } && !paths[0].contains(","),
              "files sent with a prompt are copied to the server, a comma out of their names: \(paths.map { URL(fileURLWithPath: $0).lastPathComponent })")
        check((try? String(contentsOfFile: paths[0], encoding: .utf8)) == "Line one"
              && (try? Data(contentsOf: URL(fileURLWithPath: paths[1]))) == Data([0x89, 0x50, 0x4E, 0x47]), "as they are")
    case .failure(let problem):
        check(false, "files are copied to the server: \(problem.message)")
    }
}

/// This process's CPU time so far, in seconds.
private func cpuSeconds() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    func seconds(_ time: timeval) -> Double { Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000 }
    return seconds(usage.ru_utime) + seconds(usage.ru_stime)
}
