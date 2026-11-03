import Foundation
import AgentBuddyCore

/// The command a prompt is sent with, and how a send's end is read.
func checkPromptSender() {
    print("Sending a prompt to a session")
    let claude = PromptSender.Request(
        agent: .claude, sessionID: "06449078-b67a", host: nil, folder: "/Users/me/app", prompt: "Go on",
        model: "claude-opus-5-5", permissionMode: "auto")
    if case .success(let plan) = PromptSender.plan(claude) {
        check(plan.command == "claude" && plan.folder == "/Users/me/app", "Claude Code, in the session's folder")
        check(plan.arguments == ["-p", "--resume", "06449078-b67a", "--output-format", "json", "--permission-prompts", "none",
                                 "--permission-mode", "auto", "--model", "claude-opus-5-5"],
              "resumed in print mode with its mode and model, nothing left to ask: \(plan.arguments)")
        check(!plan.arguments.contains("Go on"), "the prompt isn't an argument: it goes on stdin")
        check(plan.permissions == "in auto mode" && plan.narrowed == nil, "it says how it may act")
    } else {
        check(false, "a plan for Claude Code")
    }
    var bypass = claude
    bypass.permissionMode = "bypassPermissions"
    if case .success(let plan) = PromptSender.plan(bypass) {
        check(!plan.arguments.contains("--permission-mode") && !plan.arguments.contains("bypassPermissions") && plan.narrowed != nil,
              "a session that skipped permission checks keeps them, sent from here")
    } else {
        check(false, "a plan for a bypassing session")
    }
    let codex = PromptSender.Request(
        agent: .codex, sessionID: "01a176ad-8c88", host: "gpu", folder: "/home/me/site", prompt: "Deploy",
        model: "gpt-6-astra", sandbox: "danger-full-access", effort: "xhigh")
    if case .success(let plan) = PromptSender.plan(codex) {
        check(Array(plan.arguments.prefix(2)) == ["exec", "resume"] && Array(plan.arguments.suffix(2)) == ["01a176ad-8c88", "-"],
              "codex exec resume ID, the prompt from stdin: \(plan.arguments)")
        check(plan.arguments.contains(#"sandbox_mode="workspace-write""#) && !plan.arguments.contains { $0.contains("danger") }
              && plan.narrowed != nil, "full access narrows to the session's folder")
        check(plan.arguments.contains(#"approval_policy="never""#) && plan.arguments.contains("--skip-git-repo-check"),
              "it never asks, and works outside git too")
        check(plan.arguments.contains("gpt-6-astra") && plan.arguments.contains(#"model_reasoning_effort="xhigh""#),
              "the same model and effort")
    } else {
        check(false, "a plan for Codex")
    }
    // A session whose steps beyond the sandbox Codex's own reviewer approves (as in VS Code):
    // still so, sent from here, with its permission profile (on a server whose sandbox can't
    // run commands, that's how any command runs).
    var reviewed = codex
    reviewed.sandbox = "workspace-write"
    reviewed.permissionProfile = ":workspace"
    reviewed.approvalPolicy = "on-request"
    reviewed.approvalsReviewer = "auto_review"
    if case .success(let plan) = PromptSender.plan(reviewed) {
        check(plan.arguments.contains(#"approval_policy="on-request""#) && plan.arguments.contains(#"approvals_reviewer="auto_review""#)
              && !plan.arguments.contains(#"approval_policy="never""#),
              "Codex's reviewer goes on approving for a session it did: \(plan.arguments)")
        check(plan.arguments.contains(#"default_permissions=":workspace""#) && !plan.arguments.contains { $0.hasPrefix("sandbox_mode=") },
              "with the session's permission profile, not the older sandbox setting")
        check(plan.asks.contains("reviewer"), "and says so: \(plan.asks)")
    } else {
        check(false, "a plan for a reviewed Codex session")
    }
    var everything = reviewed
    everything.permissionProfile = ":danger-full-access"
    if case .success(let plan) = PromptSender.plan(everything) {
        check(plan.arguments.contains(#"default_permissions=":workspace""#) && !plan.arguments.contains { $0.contains("danger") }
              && plan.narrowed != nil, "a full-access profile narrows to the session's folder, as full access does")
    } else {
        check(false, "a plan for a full-access Codex session")
    }
    var person = reviewed
    person.approvalsReviewer = "user"
    if case .success(let plan) = PromptSender.plan(person) {
        check(plan.arguments.contains(#"approval_policy="never""#) && !plan.arguments.contains { $0.hasPrefix("approvals_reviewer=") },
              "approvals that go to a person (no one's here to answer): it never asks")
    }
    func refused(_ request: PromptSender.Request) -> Bool {
        if case .failure = PromptSender.plan(request) { return true }
        return false
    }
    var copilot = claude
    copilot.agent = .copilot
    var empty = claude
    empty.prompt = "  \n"
    var option = claude
    option.sessionID = "--dangerously-skip-permissions"
    var nowhere = claude
    nowhere.folder = ""
    check(refused(copilot), "not to Copilot")
    check(refused(empty), "not an empty prompt")
    check(refused(option), "not an id that would read as an option")
    check(refused(nowhere), "not without the session's folder")

    let done = #"{"type":"result","subtype":"success","is_error":false,"result":"Done.","session_id":"s"}"# + "\n{\"hs_exit\":0}"
    check(PromptSender.outcome(log: done, agent: .claude) == .finished, "Claude Code's result: done")
    let limited = #"{"type":"result","subtype":"success","is_error":true,"result":"Claude AI usage limit reached|1761523200"}"#
        + "\n{\"hs_exit\":1}"
    check(PromptSender.outcome(log: limited, agent: .claude) == .failed("Claude AI usage limit reached"), "its error, in words")
    check(PromptSender.outcome(log: "No conversation found with session ID: x\n\n{\"hs_exit\":1}", agent: .claude)
          == .failed("No conversation found with session ID: x"), "an error said in plain words")
    check(PromptSender.outcome(log: #"{"type":"result","is_error":false}"#, agent: .claude) == .running, "running until it exits")
    let codexDone = #"{"type":"thread.started","thread_id":"t"}"# + "\n" + #"{"type":"turn.completed","usage":{}}"# + "\n{\"hs_exit\":0}"
    check(PromptSender.outcome(log: codexDone, agent: .codex) == .finished, "Codex's turn completed")
    let codexFailed = #"{"type":"turn.failed","error":{"message":"You've hit your usage limit."}}"# + "\n{\"hs_exit\":1}"
    check(PromptSender.outcome(log: codexFailed, agent: .codex) == .failed("You've hit your usage limit."), "Codex's failure, in words")
    check(Executables.versionNumbers("codex-cli 0.163.0-alpha.11") == [0, 163, 0]
          && Executables.versionNumbers("2.1.310 (Claude Code)") == [2, 1, 310], "versions read, to pick the newest Codex")
}

/// Waits for a send to end.
func waitForSend(_ started: PromptSender.Started, transport: [String]? = nil, seconds: Double = 20) -> PromptSender.Status? {
    let deadline = Date().addingTimeInterval(seconds)
    var status: PromptSender.Status?
    repeat {
        status = PromptSender.status(started, transport: transport)
        if let status, status != .running {
            return status
        }
        Thread.sleep(forTimeInterval: 0.2)
    } while Date() < deadline
    return status
}

/// A stand-in `claude` that writes down where it ran, its arguments and its
/// stdin; run here, then by the launcher as on a server, with a scratch home.
func checkPromptSenderRuns() {
    print("Sending a prompt to a stand-in agent, here and as on a server (Python, run locally in place of ssh)")
    let manager = FileManager.default
    let scratch = manager.temporaryDirectory.appendingPathComponent("ab-send-\(UUID().uuidString)")
    defer { try? manager.removeItem(at: scratch) }
    let work = scratch.appendingPathComponent("work")
    let logs = scratch.appendingPathComponent("sends")
    let home = scratch.appendingPathComponent("home")
    let bin = home.appendingPathComponent(".local/bin")
    let projects = home.appendingPathComponent(".claude/projects/-work")
    for folder in [work, logs, bin, projects] {
        try? manager.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    try? "{}\n".write(to: projects.appendingPathComponent("s-2.jsonl"), atomically: true, encoding: .utf8)
    let seen = scratch.appendingPathComponent("seen.txt")
    let stub = bin.appendingPathComponent("claude")
    let script = """
    #!/bin/sh
    prompt=$(cat)
    { pwd -P; printf '%s\\n' "$@"; echo ---; printf '%s' "$prompt"; } > '\(seen.path)'
    case "$prompt" in *SLOW*) sleep 30 ;; esac
    case "$prompt" in *FAIL*) echo "No conversation found with session ID: $3" >&2; exit 1 ;; esac
    echo '{"type":"result","subtype":"success","is_error":false,"result":"Done."}'
    """
    try? script.write(to: stub, atomically: true, encoding: .utf8)
    try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)

    func seenRun() -> (folder: String, arguments: [String], prompt: String)? {
        guard let text = try? String(contentsOf: seen, encoding: .utf8), let split = text.range(of: "\n---\n") else { return nil }
        let head = text[..<split.lowerBound].split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        return (head.first ?? "", Array(head.dropFirst()), String(text[split.upperBound...]))
    }
    // realpath(3), as `pwd -P` says it: /private/var/…, where Foundation would say /var/….
    let real = realpath(work.path, nil).map { pointer in defer { free(pointer) }; return String(cString: pointer) } ?? work.path

    // Here.
    let request = PromptSender.Request(
        agent: .claude, sessionID: "s-1", host: nil, folder: work.path, prompt: "Go on\nwith the tests", permissionMode: "auto")
    guard case .success(let plan) = PromptSender.plan(request),
          case .success(let started) = PromptSender.start(request, executable: stub, logs: logs)
    else {
        check(false, "it starts here")
        return
    }
    check(waitForSend(started) == .finished, "it runs to its end here")
    let here = seenRun()
    check(here?.folder == real, "in the session's folder: \(here?.folder ?? "-")")
    check(here?.arguments == plan.arguments, "with the planned arguments")
    check(here?.prompt == "Go on\nwith the tests", "the prompt on stdin, lines kept")
    let left = (try? manager.contentsOfDirectory(atPath: logs.path)) ?? []
    check(left.count == 1 && left.allSatisfy { $0.hasSuffix(".log") }, "the prompt's file goes once it's read; the output stays: \(left)")
    var failing = request
    failing.prompt = "FAIL please"
    if case .success(let fails) = PromptSender.start(failing, executable: stub, logs: logs) {
        check(waitForSend(fails) == .failed("No conversation found with session ID: s-1"), "an agent's error comes back in its words")
    } else {
        check(false, "a failing send starts")
    }
    var slow = request
    slow.prompt = "SLOW work"
    if case .success(let slowly) = PromptSender.start(slow, executable: stub, logs: logs) {
        Thread.sleep(forTimeInterval: 0.5)
        check(PromptSender.status(slowly) == .running, "it says it's still working")
        PromptSender.stop(slowly)
        if case .failed? = waitForSend(slowly, seconds: 5) {
            check(true, "Stop ends it")
        } else {
            check(false, "Stop ends it")
        }
    } else {
        check(false, "a slow send starts")
    }

    // As on a server: the launcher finds the stand-in in ~/.local/bin.
    try? manager.removeItem(at: seen)
    let transport = ["/usr/bin/env", "HOME=\(home.path)", "PATH=/usr/bin:/bin", "python3", "-"]
    let remote = PromptSender.Request(agent: .claude, sessionID: "s-2", host: "test", folder: work.path, prompt: "Ship it")
    let began = Date()
    guard case .success(let there) = PromptSender.start(remote, transport: transport) else {
        check(false, "it starts on the server: \(PromptSender.start(remote, transport: transport))")
        return
    }
    check(Date().timeIntervalSince(began) < 10, "the connection ends at once; the agent works on")
    check(there.log.hasPrefix(home.appendingPathComponent(".cache/agent-buddy/sends").path), "its output in ~/.cache/agent-buddy/sends")
    check(waitForSend(there, transport: transport) == .finished, "it runs to its end there")
    let away = seenRun()
    check(away?.folder == real && away?.prompt == "Ship it", "there too: the session's folder and the prompt on stdin")
    if case .success(let remotePlan) = PromptSender.plan(remote) {
        check(away?.arguments == remotePlan.arguments, "and the planned arguments")
    }
    var gone = remote
    gone.sessionID = "s-404"
    if case .failure(let problem) = PromptSender.start(gone, transport: transport) {
        check(problem.message.contains("isn't on this server"), "a session that isn't there isn't resumed")
    } else {
        check(false, "a session that isn't there isn't resumed")
    }
    var outside = there
    outside.log = home.appendingPathComponent("notes.log").path
    check(PromptSender.status(outside, transport: transport) == .failed("that send isn't Agent Buddy's"), "it reads back only its own logs")
    var slowThere = remote
    slowThere.prompt = "SLOW there"
    if case .success(let slowly) = PromptSender.start(slowThere, transport: transport) {
        Thread.sleep(forTimeInterval: 0.5)
        PromptSender.stop(slowly, transport: transport)
        if case .failed? = waitForSend(slowly, transport: transport, seconds: 5) {
            check(true, "Stop ends it there")
        } else {
            check(false, "Stop ends it there")
        }
    } else {
        check(false, "a slow send starts there")
    }
}

/// What's chosen in the message box, and files sent with a prompt, as each agent takes them.
func checkSendOptions() {
    print("The message box's choices and files")
    let claude = PromptSender.Request(agent: .claude, sessionID: "06449078-b67a", host: nil, folder: "/Users/me/app", prompt: "Go on",
                                      model: "claude-opus-5-5", permissionMode: "acceptEdits")
    var chosen = claude.with(PromptSender.Options(model: "fable", effort: "max", fast: true, mode: "auto"))
    chosen.attachments = ["/Users/me/Desktop/shot.png", "/Users/me/app/plan.pdf"]
    if case .success(let plan) = PromptSender.plan(chosen) {
        let joined = plan.arguments.joined(separator: " ")
        check(joined.contains("--model fable") && joined.contains("--effort max") && joined.contains(#"--settings {"fastMode":true}"#)
              && joined.contains("--permission-mode auto") && !joined.contains("acceptEdits"),
              "Claude Code: the model (an alias), effort, fast mode and mode chosen: \(joined)")
        check(chosen.text.hasPrefix("Go on\n\nAttached files") && chosen.text.contains("- /Users/me/Desktop/shot.png")
              && chosen.text.contains("- /Users/me/app/plan.pdf"), "its files, images too, named after the prompt for it to open")
    } else {
        check(false, "a plan with Claude Code's choices")
    }
    var slow = claude.with(PromptSender.Options(fast: false))
    slow.attachments = []
    if case .success(let plan) = PromptSender.plan(slow) {
        check(plan.arguments.contains(#"{"fastMode":false}"#) && plan.arguments.contains("acceptEdits") && plan.arguments.contains("claude-opus-5-5"),
              "fast mode off, and nothing else chosen: the session's own")
    }
    if case .success(let plan) = PromptSender.plan(claude) {
        check(!plan.arguments.contains("--effort") && !plan.arguments.contains("--settings"), "nothing chosen: nothing new in the command")
    }

    let codex = PromptSender.Request(agent: .codex, sessionID: "01a176ad-8c88", host: "gpu", folder: "/home/me/site", prompt: "Deploy",
                                     model: "gpt-6-astra", effort: "high", permissionProfile: ":workspace")
    var picked = codex.with(PromptSender.Options(model: "gpt-6-sol", effort: "ultra", fast: true, mode: "read-only"))
    picked.attachments = ["/home/me/.cache/agent-buddy/attachments/x/shot.png", "/home/me/.cache/agent-buddy/attachments/x/log.txt"]
    if case .success(let plan) = PromptSender.plan(picked) {
        let joined = plan.arguments.joined(separator: " ")
        check(joined.contains("-m gpt-6-sol") && joined.contains(#"model_reasoning_effort="ultra""#) && joined.contains(#"service_tier="fast""#)
              && joined.contains(#"default_permissions=":read-only""#) && joined.contains(#"approval_policy="never""#),
              "Codex: the model, effort, fast mode and Read only chosen: \(joined)")
        let image = plan.arguments.firstIndex(of: "--image=/home/me/.cache/agent-buddy/attachments/x/shot.png")
        check(image != nil && plan.arguments[(image ?? 0) + 1].hasPrefix("-") && plan.arguments.suffix(2) == ["01a176ad-8c88", "-"],
              "its image given as an image, an option after it (so it takes no more)")
        check(!picked.text.contains("shot.png") && picked.text.contains("- /home/me/.cache/agent-buddy/attachments/x/log.txt"),
              "any other file named after the prompt")
    } else {
        check(false, "a plan with Codex's choices")
    }
    let auto = codex.with(PromptSender.Options(mode: "auto"))
    check(auto.mode == "auto" && auto.permissionProfile == ":workspace", "Auto for Codex: its reviewer decides, in the workspace")
    if case .success(let plan) = PromptSender.plan(auto) {
        check(plan.arguments.contains(#"approvals_reviewer="auto_review""#) && plan.asks.contains("reviewer"), "and says so: \(plan.asks)")
    }
    var legacy = codex
    legacy.permissionProfile = nil
    legacy.sandbox = "workspace-write"
    check(legacy.with(PromptSender.Options(mode: "read-only")).sandbox == "read-only" && legacy.mode == "workspace",
          "an older Codex session's sandbox, read-only when chosen")
    if case .success(let plan) = PromptSender.plan(codex.with(PromptSender.Options(fast: false))) {
        check(plan.arguments.contains(#"service_tier="default""#), "fast mode off: Codex's standard tier, chosen")
    }

    // Names, and files Codex would split.
    check(ClaudeModels.name("claude-opus-5-5") == "Opus 5.5" && ClaudeModels.name("claude-sonnet-4-5-20250929") == "Sonnet 4.5"
          && ClaudeModels.name("opus") == "Opus" && ClaudeModels.name("gpt-6") == "gpt-6", "Claude's models by their names")
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("ab-files-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: scratch) }
    let comma = scratch.appendingPathComponent("a, b.png")
    try? Data([1, 2, 3]).write(to: comma)
    let safe = PromptSender.withoutCommas(comma)
    check(!safe.path.contains(",") && (try? Data(contentsOf: safe)) == Data([1, 2, 3]), "a picture with a comma in its name is copied to one without")
    check(PromptSender.withoutCommas(scratch.appendingPathComponent("plain.png")).lastPathComponent == "plain.png", "others stay as they are")
    check(PromptSender.isImage("/a/b.JPG") && !PromptSender.isImage("/a/b.pdf"), "images known by their names")
}

/// The message box's @ (a folder's files) and / (commands, skills, Codex's prompts), here and through the launcher.
func checkComposerSuggestions() {
    print("The message box's @ and /")
    let manager = FileManager.default
    let scratch = manager.temporaryDirectory.appendingPathComponent("ab-suggest-\(UUID().uuidString)")
    defer { try? manager.removeItem(at: scratch) }
    func write(_ text: String, _ path: String) {
        let url = scratch.appendingPathComponent(path)
        try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
    // A project: git tracks some, ignores some.
    write("print(1)", "work/src/main.py")
    write("x", "work/src/util/strings.py")
    write("# Notes", "work/README.md")
    write("secret", "work/build/out.bin")
    write("build/\n", "work/.gitignore")
    let work = scratch.appendingPathComponent("work").path
    _ = ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/git"), ["-C", work, "init", "-q"], timeout: 10)
    if case .success(let files) = ProjectFiles.list(folder: work, host: nil) {
        check(Set(files) == [".gitignore", "README.md", "src/main.py", "src/util/strings.py"], "@: a git folder's files, its ignores left out: \(files)")
        check(ProjectFiles.matches("main", in: files).first == "src/main.py" && ProjectFiles.matches("util", in: files).first == "src/util/",
              "the best match first, folders too: \(ProjectFiles.matches("util", in: files))")
        check(ProjectFiles.matches("smp", in: files).contains("src/main.py"), "letters in order find a path too")
    } else {
        check(false, "a folder's files are listed")
    }
    write("x", "plain/a.txt")
    write("x", "plain/node_modules/dep/index.js")
    write("x", "plain/.hidden/b.txt")
    if case .success(let files) = ProjectFiles.list(folder: scratch.appendingPathComponent("plain").path, host: nil) {
        check(files == ["a.txt"], "a folder outside git: walked, hidden and dependency folders left out: \(files)")
    }
    check(ProjectFiles.mention("src/main.py") == "@src/main.py" && ProjectFiles.mention("My Notes/a b.md") == "@\"My Notes/a b.md\"",
          "a file named after @, quoted when it has a space")

    // A home with commands, skills, a plugin's, and Codex's prompts and skills.
    write("---\ndescription: Fix the failing test\n---\nFix $ARGUMENTS", "home/.claude/commands/fix.md")
    write("Make a component", "home/.claude/commands/frontend/component.md")
    write("---\nname: my-skill\ndescription: Does a thing\n---\nBody", "home/.claude/skills/synced/bucket/my-skill/SKILL.md")
    write("---\ndescription: Plan a paper\n---\n", "home/.claude/plugins/cache/m/p/1.0/commands/ars-plan.md")
    write("---\nname: deep-research\ndescription: Research deeply\n---\n", "home/.claude/plugins/cache/m/p/1.0/deep-research/SKILL.md")
    write(#"{"version": 2, "plugins": {"p@m": [{"scope": "user", "installPath": "\#(scratch.path)/home/.claude/plugins/cache/m/p/1.0"}]}}"#,
          "home/.claude/plugins/installed_plugins.json")
    write("---\ndescription: The project's own\n---\n", "work/.claude/commands/ship.md")
    write("---\ndescription: Review it\n---\nReview $1 then $2. All: $ARGUMENTS", "home/.codex/prompts/review.md")
    write("---\nname: imagegen\ndescription: Make images\n---\n", "home/.codex/skills/.system/imagegen/SKILL.md")
    let home = scratch.appendingPathComponent("home")
    let claude = AgentCommands.listHere(agent: .claude, folder: work, home: home)
    let names = claude.map(\.name)
    check(["compact", "fix", "frontend:component", "my-skill", "ars-plan", "deep-research", "ship"].allSatisfy(names.contains),
          "/ for Claude Code: its own, yours (nested ones with :), synced skills, a plugin's, the folder's: \(names)")
    check(claude.first { $0.name == "fix" }?.description == "Fix the failing test" && claude.first { $0.name == "frontend:component" }?.description == "Make a component",
          "each with its description, or its first line")
    let codex = AgentCommands.listHere(agent: .codex, folder: work, home: home)
    check(codex.map(\.typed).sorted() == ["$imagegen", "/prompts:review"], "/ for Codex: its prompts, and its skills as $mentions: \(codex.map(\.typed))")
    check(AgentCommands.expand("/prompts:review main.rs lib.rs", with: codex) == "Review main.rs then lib.rs. All: main.rs lib.rs",
          "a Codex prompt is filled in before it's sent: \(AgentCommands.expand("/prompts:review main.rs lib.rs", with: codex) ?? "-")")
    check(AgentCommands.expand("/compact", with: codex) == nil && AgentCommands.expand("Hello", with: codex) == nil, "anything else goes as typed")
    check(AgentCommands.matches("ar", in: claude).first?.name == "ars-plan", "the best match first")

    // The same through the launcher, as on a server.
    let server = ["/usr/bin/env", "HOME=\(home.path)", "python3", "-"]
    if case .success(let files) = ProjectFiles.list(folder: work, host: "gpu", transport: server) {
        check(Set(files) == [".gitignore", "README.md", "src/main.py", "src/util/strings.py", ".claude/commands/ship.md"],
              "on a server: the folder's files, through the launcher: \(files.sorted())")
    } else {
        check(false, "a server's folder's files are listed")
    }
    if case .success(let listed) = AgentCommands.list(agent: .claude, folder: work, host: "gpu", transport: server) {
        check(Set(listed.map(\.name)) == Set(names), "on a server: the same commands: \(listed.map(\.name))")
    } else {
        check(false, "a server's commands are listed")
    }
    if case .success(let listed) = AgentCommands.list(agent: .codex, folder: work, host: "gpu", transport: server) {
        check(listed.map(\.typed).sorted() == ["$imagegen", "/prompts:review"] && listed.first { $0.kind == .prompt }?.body?.contains("$ARGUMENTS") == true,
              "and Codex's, its prompts' text with them")
    }
}
