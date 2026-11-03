import Foundation

/// Sends a prompt to a session from Agent Buddy. The agent's own command
/// resumes the session and works on it with no window, on this Mac or on the
/// server: `claude -p --resume ID`, or `codex exec resume ID -`. The prompt
/// goes in on stdin. It keeps the session's own permission mode or sandbox,
/// but anything that would ask you for permission is refused, as nobody is
/// there to answer. The reply lands in the session's log like any other turn.
public enum PromptSender {
    public struct Request: Sendable, Equatable {
        public var agent: Agent
        public var sessionID: String
        /// The server, or nil for this Mac.
        public var host: String?
        /// Where it runs: Claude Code finds a session by the folder it began in.
        public var folder: String
        public var prompt: String
        /// The session's last model, kept so the reply comes from the same one.
        public var model: String?
        /// Claude Code's permission mode in the session ("auto", "acceptEdits"…).
        public var permissionMode: String?
        /// Codex's sandbox in the session ("workspace-write"…), and its reasoning effort.
        public var sandbox: String?
        public var effort: String?
        /// Newer Codex's permission profile in the session (":workspace"): kept, in place of the sandbox.
        public var permissionProfile: String?
        /// Codex's approvals in the session: "on-request" with "auto_review" is kept (its own reviewer decides).
        public var approvalPolicy: String?
        public var approvalsReviewer: String?
        /// Fast mode on or off; nil leaves it as the session (or its settings) has it.
        public var fast: Bool?
        /// Files sent with it, as paths where the agent runs. Codex is given
        /// images as images; anything else (for Claude Code, images too) is
        /// named after the prompt, for the agent to open.
        public var attachments: [String] = []

        public init(
            agent: Agent, sessionID: String, host: String?, folder: String, prompt: String, model: String? = nil,
            permissionMode: String? = nil, sandbox: String? = nil, effort: String? = nil, permissionProfile: String? = nil,
            approvalPolicy: String? = nil, approvalsReviewer: String? = nil
        ) {
            self.agent = agent
            self.sessionID = sessionID
            self.host = host
            self.folder = folder
            self.prompt = prompt
            self.model = model
            self.permissionMode = permissionMode
            self.sandbox = sandbox
            self.effort = effort
            self.permissionProfile = permissionProfile
            self.approvalPolicy = approvalPolicy
            self.approvalsReviewer = approvalsReviewer
        }

        /// Codex's own reviewer approves what goes beyond the sandbox, as in the session: no one need be asked.
        var reviewedByCodex: Bool {
            agent == .codex && approvalPolicy == "on-request" && approvalsReviewer == "auto_review"
        }

        /// What the agent is sent: the prompt, then the files it's to open.
        public var text: String {
            let named = attachments.filter { agent != .codex || !PromptSender.isImage($0) }
            guard !named.isEmpty else { return prompt }
            let lines = named.map { "- \($0)" }.joined(separator: "\n")
            return prompt + "\n\n" + (named.count == 1 ? "Attached file (open it to see it):\n" : "Attached files (open them to see them):\n") + lines
        }

        /// Images Codex is given as images.
        var images: [String] {
            agent == .codex ? attachments.filter(PromptSender.isImage) : []
        }

        /// How it may act, as the message box names it: Claude Code's permission
        /// mode; for Codex, "auto" (its reviewer decides steps beyond the
        /// sandbox), "workspace" or "read-only".
        public var mode: String? {
            switch agent {
            case .claude:
                return permissionMode
            case .codex:
                if reviewedByCodex {
                    return "auto"
                }
                return permissionProfile == ":read-only" || (permissionProfile == nil && sandbox == "read-only") ? "read-only" : "workspace"
            default:
                return nil
            }
        }

        /// With what's chosen in the message box.
        public func with(_ options: Options) -> Request {
            var request = self
            request.model = options.model ?? model
            request.effort = options.effort ?? effort
            request.fast = options.fast ?? fast
            guard let mode = options.mode else { return request }
            switch agent {
            case .claude:
                request.permissionMode = mode
            case .codex:
                // Auto is Codex's own: the workspace, with its reviewer deciding a step beyond it.
                let readOnly = mode == "read-only"
                request.approvalPolicy = mode == "auto" ? "on-request" : "never"
                request.approvalsReviewer = mode == "auto" ? "auto_review" : nil
                if let profile = permissionProfile {
                    // A profile of the user's own is kept for Auto; Codex's own become the one asked for.
                    if readOnly || profile.hasPrefix(":") || mode == "workspace" {
                        request.permissionProfile = readOnly ? ":read-only" : ":workspace"
                    }
                } else {
                    request.sandbox = readOnly ? "read-only" : "workspace-write"
                }
            default:
                break
            }
            return request
        }
    }

    /// What's chosen in an agent window's message box for the prompts it sends:
    /// each nil keeps the session's own.
    public struct Options: Sendable, Equatable {
        /// Claude Code's alias ("opus") or a model's full name; Codex's model id.
        public var model: String?
        /// Claude Code's effort ("low" to "max"); Codex's reasoning effort.
        public var effort: String?
        public var fast: Bool?
        /// See `Request.mode`.
        public var mode: String?

        public init(model: String? = nil, effort: String? = nil, fast: Bool? = nil, mode: String? = nil) {
            self.model = model
            self.effort = effort
            self.fast = fast
            self.mode = mode
        }
    }

    static let imageTypes: Set<String> = ["png", "jpg", "jpeg", "gif", "webp"]

    /// A file to name to Codex: a comma would split its path in two, so one
    /// with a comma is copied to a name without first.
    public static func withoutCommas(_ file: URL) -> URL {
        guard file.path.contains(",") else { return file }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("agent-buddy-files-\(UUID().uuidString)")
        let copy = folder.appendingPathComponent(file.lastPathComponent.replacingOccurrences(of: ",", with: "_"))
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil,
              (try? FileManager.default.copyItem(at: file, to: copy)) != nil
        else { return file }
        return copy
    }

    /// An image an agent can be shown, by its name.
    public static func isImage(_ path: String) -> Bool {
        imageTypes.contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }

    /// What runs: the command, its arguments (the prompt isn't one) and where.
    public struct Plan: Sendable, Equatable {
        public var command: String
        public var arguments: [String]
        public var folder: String
        /// How it may act, to follow "sends it to Claude Code": "in auto mode", "in its workspace-write sandbox".
        public var permissions: String
        /// Why it may do less than in the session, when the session's own setting
        /// let it act without any checks.
        public var narrowed: String?
        /// What becomes of anything it would ask, to end the sentence: refused (no one's
        /// there to answer), or decided by Codex's own reviewer, as in the session.
        public var asks = "anything that would ask you is refused"
    }

    /// A send under way: the process, and the file its output goes to (on the server, for one there).
    public struct Started: Sendable, Equatable {
        public var agent: Agent
        public var host: String?
        public var pid: Int32
        public var log: String
        public var at: Date

        public init(agent: Agent, host: String?, pid: Int32, log: String, at: Date) {
            self.agent = agent
            self.host = host
            self.pid = pid
            self.log = log
            self.at = at
        }
    }

    public enum Status: Sendable, Equatable {
        case running
        case finished
        case failed(String)
    }

    // MARK: - The command

    public static func plan(_ request: Request) -> Result<Plan, ReadError> {
        guard request.agent == .claude || request.agent == .codex else {
            return .failure(ReadError("Agent Buddy can send prompts to Claude Code and Codex sessions, not \(request.agent.clientName)'s yet."))
        }
        // An id is never read as an option: it starts with a letter or digit.
        guard let first = request.sessionID.unicodeScalars.first, CharacterSet.alphanumerics.contains(first),
              request.sessionID.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0) })
        else { return .failure(ReadError("This session's id can't be resumed.")) }
        guard !request.folder.isEmpty else {
            return .failure(ReadError("Agent Buddy doesn't know which folder this session works in."))
        }
        guard !request.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(ReadError("Type a prompt first."))
        }
        switch request.agent {
        case .claude: return .success(claudePlan(request))
        case .codex: return .success(codexPlan(request))
        default: return .failure(ReadError("Not for \(request.agent.clientName)."))
        }
    }

    static func claudePlan(_ request: Request) -> Plan {
        var arguments = ["-p", "--resume", request.sessionID, "--output-format", "json", "--permission-prompts", "none"]
        let words: [String: String] = [
            "auto": "in auto mode", "acceptEdits": "accepting edits", "plan": "in plan mode", "dontAsk": "in don't-ask mode",
        ]
        var permissions = "with its usual permissions"
        var narrowed: String?
        if let mode = request.permissionMode, let said = words[mode] {
            arguments += ["--permission-mode", mode]
            permissions = said
        } else if request.permissionMode == "bypassPermissions" {
            narrowed = "In the session it skipped permission checks; sent from here, it keeps them."
        }
        if let model = request.model, model.hasPrefix("claude-") || ClaudeModels.aliases.contains(model), !model.contains(" ") {
            arguments += ["--model", model]
        }
        if let effort = request.effort, ClaudeModels.efforts.contains(effort) {
            arguments += ["--effort", effort]
        }
        if let fast = request.fast {
            arguments += ["--settings", fast ? #"{"fastMode":true}"# : #"{"fastMode":false}"#]
        }
        return Plan(command: "claude", arguments: arguments, folder: request.folder, permissions: permissions, narrowed: narrowed)
    }

    static func codexPlan(_ request: Request) -> Plan {
        // Never asking a person (no one's there), but, as in the session, letting
        // Codex's own reviewer approve a step beyond the sandbox: on a server whose
        // sandbox can't run commands, that's how any command runs.
        let approvals = request.reviewedByCodex
            ? ["-c", #"approval_policy="on-request""#, "-c", #"approvals_reviewer="auto_review""#]
            : ["-c", #"approval_policy="never""#]
        // An image each (a comma would split one: the window gives paths without).
        let images = request.images.filter { !$0.contains(",") }.map { "--image=\($0)" }
        var arguments = ["exec", "resume"] + images + ["--json", "--skip-git-repo-check"] + approvals
        var permissions = "in Codex's usual sandbox"
        var narrowed: String?
        if let profile = request.permissionProfile,
           profile.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || ":-_.".unicodeScalars.contains($0) }) {
            // The session's own permission profile: newer Codex sets its sandbox up
            // from it (forcing the older sandbox_mode instead can fail, as on a
            // server whose kernel won't let the sandbox make its own network).
            // Full access (":danger-full-access") narrows to the folder, as a sandbox's does.
            let kept = profile.hasPrefix(":danger") ? ":workspace" : profile
            arguments += ["-c", "default_permissions=\"\(kept)\""]
            switch kept {
            case ":workspace": permissions = "with workspace permissions"
            case ":read-only": permissions = "read-only"
            default: permissions = "with the session's permissions (\(kept))"
            }
            if kept != profile, profile.hasPrefix(":danger") {
                narrowed = "In the session it had full access; sent from here, it writes only in its folder."
            }
        } else {
            switch request.sandbox {
            case "read-only", "workspace-write":
                arguments += ["-c", "sandbox_mode=\"\(request.sandbox ?? "")\""]
                permissions = "in its \(request.sandbox ?? "") sandbox"
            case "danger-full-access":
                arguments += ["-c", #"sandbox_mode="workspace-write""#]
                permissions = "in a workspace-write sandbox"
                narrowed = "In the session it had full access; sent from here, it writes only in its folder."
            default:
                break
            }
        }
        if let model = request.model, !model.isEmpty, !model.contains(" "), !model.hasPrefix("-") {
            arguments += ["-m", model]
        }
        if let effort = request.effort, !effort.isEmpty, effort.allSatisfy({ $0.isLetter && $0.isLowercase }) {
            arguments += ["-c", "model_reasoning_effort=\"\(effort)\""]
        }
        if let fast = request.fast {
            // "default" is Codex's word for standard speed, chosen.
            arguments += ["-c", fast ? #"service_tier="fast""# : #"service_tier="default""#]
        }
        // The prompt is read from stdin.
        arguments += [request.sessionID, "-"]
        var plan = Plan(command: "codex", arguments: arguments, folder: request.folder, permissions: permissions, narrowed: narrowed)
        if request.reviewedByCodex {
            plan.asks = "Codex's own reviewer decides anything beyond them"
        }
        return plan
    }

    // MARK: - Starting, watching, stopping

    /// Starts the agent and returns at once; it goes on with Agent Buddy closed,
    /// and on a server after the SSH connection ends. `executable`, `transport`
    /// and `logs` are for the checks.
    public static func start(
        _ request: Request, executable: URL? = nil, transport: [String]? = nil, logs: URL? = nil
    ) -> Result<Started, ReadError> {
        let plan: Plan
        switch self.plan(request) {
        case .success(let made): plan = made
        case .failure(let problem): return .failure(problem)
        }
        if let host = request.host {
            return startThere(plan, request: request, host: host, transport: transport)
        }
        return startHere(plan, request: request, executable: executable, logs: logs ?? folder)
    }

    /// Nil when it can't tell (the server didn't answer).
    public static func status(_ started: Started, transport: [String]? = nil) -> Status? {
        guard let host = started.host else {
            func tail() -> String {
                Tail.read(URL(fileURLWithPath: started.log), maxBytes: 65_536)?.lines
                    .map { String(decoding: $0, as: UTF8.self) }.joined(separator: "\n") ?? ""
            }
            let status = outcome(log: tail(), agent: started.agent)
            // Gone without an exit line: Agent Buddy quit while it ran, say.
            if status == .running, !Running.contains(started.pid), kill(started.pid, 0) != 0 {
                let last = tail()
                let ended = outcome(log: last, agent: started.agent)
                return ended == .running ? outcome(log: last + "\n{\"hs_exit\":-1}", agent: started.agent) : ended
            }
            return status
        }
        guard let reply = remote(["op": "status", "pid": Int(started.pid), "log": started.log], host: host, transport: transport, timeout: 30)
        else { return nil }
        if let problem = reply["hs_error"].nonEmptyString {
            return .failed(problem)
        }
        let tail = reply["tail"].string ?? ""
        let status = outcome(log: tail, agent: started.agent)
        if status == .running, reply["alive"].bool == false {
            return outcome(log: tail + "\n{\"hs_exit\":-1}", agent: started.agent)
        }
        return status
    }

    /// Stops it: the agent ends its turn there.
    public static func stop(_ started: Started, transport: [String]? = nil) {
        guard let host = started.host else {
            if !Running.terminate(started.pid) {
                kill(started.pid, SIGTERM)
            }
            return
        }
        _ = remote(["op": "stop", "pid": Int(started.pid), "log": started.log], host: host, transport: transport, timeout: 30)
    }

    /// How a send ended, from its output: `.running` until the exit line.
    public static func outcome(log: String, agent: Agent) -> Status {
        // Under way until the exit line is written: its output isn't read through before then.
        guard log.contains("\"hs_exit\"") else { return .running }
        let lines = log.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        let objects = lines.compactMap { line in line.hasPrefix("{") ? JSON.parse(line) : nil }
        guard let exit = objects.last(where: { $0["hs_exit"].int != nil })?["hs_exit"].int else { return .running }
        switch agent {
        case .claude:
            if let result = objects.last(where: { $0["type"].string == "result" }) {
                guard result["is_error"].bool == true else { return .finished }
                var said = result["result"].nonEmptyString ?? result["subtype"].nonEmptyString ?? "Claude Code stopped with an error"
                // "Claude AI usage limit reached|1761523200": the words, not the time.
                if let bar = said.lastIndex(of: "|"), said[said.index(after: bar)...].allSatisfy(\.isNumber) {
                    said = String(said[..<bar])
                }
                return .failed(said)
            }
        case .codex:
            if let failed = objects.last(where: { $0["type"].string == "turn.failed" }) {
                return .failed(failed["error"]["message"].nonEmptyString ?? "Codex stopped with an error")
            }
            if objects.contains(where: { $0["type"].string == "turn.completed" }) {
                return .finished
            }
            if let error = objects.last(where: { $0["type"].string == "error" }), let message = error["message"].nonEmptyString {
                return .failed(message)
            }
        default:
            break
        }
        if exit == 0 {
            return .finished
        }
        // In plain words, like "No conversation found with session ID: …".
        if let said = lines.last(where: { !$0.isEmpty && !$0.hasPrefix("{") }) {
            return .failed(String(said.prefix(300)))
        }
        return .failed(exit == -1 ? "It stopped before it finished." : "It stopped (exit \(exit)).")
    }

    // MARK: - On this Mac

    /// The processes started here, kept so they're reaped and can be stopped.
    enum Running {
        private static let lock = NSLock()
        nonisolated(unsafe) private static var processes: [Int32: Process] = [:]

        static func add(_ process: Process) {
            lock.lock()
            processes[process.processIdentifier] = process
            lock.unlock()
        }

        static func remove(_ pid: Int32) {
            lock.lock()
            processes[pid] = nil
            lock.unlock()
        }

        static func contains(_ pid: Int32) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return processes[pid] != nil
        }

        static func terminate(_ pid: Int32) -> Bool {
            lock.lock()
            let process = processes[pid]
            lock.unlock()
            guard let process, process.isRunning else { return false }
            process.terminate()
            return true
        }
    }

    /// Where the sends' prompts and output go on this Mac.
    public static var folder: URL {
        let folder = Environment.workDirectory.appendingPathComponent("sends", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return folder
    }

    static func startHere(_ plan: Plan, request: Request, executable: URL?, logs base: URL) -> Result<Started, ReadError> {
        guard let program = executable ?? (plan.command == "codex" ? Executables.newest("codex") : Executables.find(plan.command)) else {
            return .failure(ReadError("Agent Buddy can't find the \(plan.command) command on this Mac."))
        }
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: plan.folder, isDirectory: &isFolder), isFolder.boolValue else {
            return .failure(ReadError("The session's folder isn't there anymore: \(plan.folder)"))
        }
        let manager = FileManager.default
        tidy(base)
        let name = fileName(request)
        let promptFile = base.appendingPathComponent(name + ".prompt")
        let logFile = base.appendingPathComponent(name + ".log")
        guard manager.createFile(atPath: promptFile.path, contents: Data(request.text.utf8), attributes: [.posixPermissions: 0o600]),
              manager.createFile(atPath: logFile.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              let input = try? FileHandle(forReadingFrom: promptFile),
              let output = try? FileHandle(forWritingTo: logFile)
        else { return .failure(ReadError("Agent Buddy couldn't write the prompt down to send it.")) }
        defer {
            try? input.close()
            try? output.close()
            try? manager.removeItem(at: promptFile)
        }
        let process = Process()
        process.executableURL = program
        process.arguments = plan.arguments
        process.currentDirectoryURL = URL(fileURLWithPath: plan.folder, isDirectory: true)
        var environment = Environment.engineEnvironment()
        // Not inside another agent's session, whatever started Agent Buddy.
        for name in ["CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SSE_PORT", "CODEX_SANDBOX", "CODEX_SANDBOX_NETWORK_DISABLED"] {
            environment[name] = nil
        }
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        process.terminationHandler = { finished in
            let code = finished.terminationReason == .uncaughtSignal ? 128 + finished.terminationStatus : finished.terminationStatus
            if let handle = try? FileHandle(forWritingTo: logFile) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data("\n{\"hs_exit\":\(code)}\n".utf8))
                try? handle.close()
            }
            Running.remove(finished.processIdentifier)
        }
        do {
            try process.run()
        } catch {
            return .failure(ReadError("\(plan.command) didn't start: \(error.localizedDescription)"))
        }
        Running.add(process)
        return .success(Started(agent: request.agent, host: nil, pid: process.processIdentifier, log: logFile.path, at: Date()))
    }

    static func fileName(_ request: Request) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let random = String(UUID().uuidString.prefix(6)).lowercased()
        return "\(formatter.string(from: Date()))-\(request.agent.rawValue)-\(request.sessionID.prefix(8))-\(random)"
    }

    /// Sends older than a week go.
    static func tidy(_ folder: URL) {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let old = Date().addingTimeInterval(-7 * 86_400)
        for file in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? [] {
            if let modified = try? file.resourceValues(forKeys: Set(keys)).contentModificationDate, modified < old {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    // MARK: - On a server

    static func startThere(_ plan: Plan, request: Request, host: String, transport: [String]?) -> Result<Started, ReadError> {
        let payload: [String: Any] = [
            "op": "start", "agent": request.agent.rawValue, "session": request.sessionID, "folder": plan.folder,
            "command": plan.command, "arguments": plan.arguments, "prompt": request.text,
        ]
        guard let reply = remote(payload, host: host, transport: transport, timeout: 45) else {
            return .failure(ReadError("\(host) didn't answer, so nothing was sent."))
        }
        if let problem = reply["hs_error"].nonEmptyString {
            return .failure(ReadError("\(host): \(problem)"))
        }
        guard let pid = reply["hs_started"].int, let log = reply["log"].nonEmptyString else {
            return .failure(ReadError("\(host) gave an answer Agent Buddy doesn't understand."))
        }
        return .success(Started(agent: request.agent, host: host, pid: Int32(pid), log: log, at: Date()))
    }

    /// One run of the launcher on the server: its one line of reply.
    static func remote(_ payload: [String: Any], host: String, transport: [String]?, timeout: TimeInterval) -> JSON? {
        let command = transport ?? RemoteTokenSource.ssh(host)
        guard let program = command.first,
              let request = try? JSONSerialization.data(withJSONObject: payload)
        else { return nil }
        let script = launcher.replacingOccurrences(of: "__REQUEST__", with: request.base64EncodedString())
        guard let result = ProcessRunner.run(
            URL(fileURLWithPath: program), Array(command.dropFirst()), environment: Environment.engineEnvironment(),
            input: Data(script.utf8), timeout: timeout)
        else { return nil }
        if result.status != 0 {
            let detail = String(decoding: result.errorOutput, as: UTF8.self)
                .split(whereSeparator: \.isNewline).last.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
            switch result.status {
            case 255: return JSON(["hs_error": "couldn't connect\(detail.isEmpty ? "" : ": \(detail)")"])
            case 127: return JSON(["hs_error": "python3 isn't installed there"])
            default: return JSON(["hs_error": detail.isEmpty ? "exit \(result.status)" : detail])
            }
        }
        return SessionHistoryReader.lines(result.output).last
    }

    /// Runs on the server with `python3 -`. It starts only `claude` or `codex`,
    /// only on one of the agent's own sessions, and reads back only the logs it
    /// wrote. The agent runs under a supervisor that leaves the SSH session, so
    /// the work goes on when the connection ends.
    public static let launcher = #"""
import base64, glob, json, os, signal, subprocess, sys, time

req = json.loads(base64.b64decode("__REQUEST__"))
home = os.path.expanduser("~")
base = os.path.join(home, ".cache", "agent-buddy", "sends")
out = sys.stdout

def reply(o):
    out.write(json.dumps(o) + "\n")
    out.flush()

def ours(log):
    real = os.path.realpath(log or "")
    return os.path.dirname(real) == os.path.realpath(base) and real.endswith(".log")

def folders():
    found = os.environ.get("PATH", "").split(os.pathsep)
    found += [os.path.join(home, p) for p in (".local/bin", ".claude/local", ".npm-global/bin", ".bun/bin", ".volta/bin", "bin")]
    found += ["/usr/local/bin", "/opt/homebrew/bin"]
    # An npm-installed CLI is a Node script; nvm's Node may only be in .bashrc.
    found += sorted(glob.glob(os.path.join(home, ".nvm", "versions", "node", "*", "bin")), reverse=True)
    return [f for f in found if f]

def find(name):
    for folder in folders():
        path = os.path.join(folder, name)
        if os.path.isfile(path) and os.access(path, os.X_OK):
            return path
    return None

def session_log(agent, session):
    if not session or not (session[0].isalnum()) or "/" in session:
        return None
    if agent == "claude":
        for path in glob.glob(os.path.join(home, ".claude", "projects", "*", session + ".jsonl")):
            return path
    elif agent == "codex":
        for top, _, files in os.walk(os.path.join(home, ".codex", "sessions")):
            for name in files:
                if name.startswith("rollout-") and name.endswith(session + ".jsonl"):
                    return os.path.join(top, name)
    return None

def keep(program, arguments, quiet):
    # The agent on this connection, through this script: Agent Buddy says it's
    # still there every minute. Should that stop for `quiet` seconds (the Mac
    # asleep or offline, the connection never closed), the agent is ended once
    # no turn is under way, so no copy of it lingers here.
    import fcntl, select
    child = subprocess.Popen([program] + arguments, stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    agent_out = child.stdout.fileno()
    fcntl.fcntl(1, fcntl.F_SETFL, fcntl.fcntl(1, fcntl.F_GETFL) | os.O_NONBLOCK)
    alive = b'{"agent_buddy":"alive"}'
    heard = time.time()
    busy = False
    listening = True
    incoming = b""
    head = b""
    outgoing = bytearray()
    ending = None

    def starts(line):
        try:
            o = json.loads(line)
        except ValueError:
            return False
        return isinstance(o, dict) and (o.get("type") == "user" or o.get("method") == "turn/start")

    def note(line):
        nonlocal busy
        line = line.replace(b" ", b"")
        if b'"type":"result"' in line or b'"method":"turn/completed"' in line:
            busy = False
        elif b'"method":"turn/started"' in line:
            busy = True

    def send_on(wait):
        until = time.time() + wait
        while outgoing:
            try:
                del outgoing[:os.write(1, outgoing)]
            except BlockingIOError:
                if time.time() >= until or not select.select([], [1], [], max(0, until - time.time()))[1]:
                    return
            except OSError:
                outgoing.clear()

    while True:
        ready = select.select([agent_out] + ([0] if listening else []), [1] if outgoing else [], [], min(5.0, quiet))
        if ready[1]:
            send_on(0)
        if 0 in ready[0]:
            data = os.read(0, 1 << 16)
            if not data:
                # Let go, or the connection closed: the agent's input ends, as without this script.
                listening = False
                child.stdin.close()
            else:
                heard = time.time()
                incoming += data
                if b"\n" in data:
                    *lines, incoming = incoming.split(b"\n")
                    for line in lines:
                        if line.strip() == alive:
                            continue
                        if starts(line):
                            busy = True
                        try:
                            child.stdin.write(line + b"\n")
                            child.stdin.flush()
                        except OSError:
                            pass
        if agent_out in ready[0]:
            data = os.read(agent_out, 1 << 16)
            if not data:
                break
            if len(outgoing) < (64 << 20):
                outgoing += data
            pieces = data.split(b"\n")
            for index, piece in enumerate(pieces):
                if len(head) < 512:
                    head += piece[:512 - len(head)]
                if index < len(pieces) - 1:
                    note(head)
                    head = b""
        if listening and not busy and time.time() - heard > quiet:
            minutes = max(1, int(round(quiet / 60)))
            outgoing += (json.dumps({"hs_error": "It ended after %d minute%s without word from Agent Buddy (the Mac asleep or offline)."
                                     % (minutes, "" if minutes == 1 else "s")}) + "\n").encode()
            listening = False
            child.stdin.close()
            child.terminate()
            ending = time.time()
        if ending and time.time() - ending > 10 and child.poll() is None:
            child.kill()
    send_on(5)
    code = child.wait()
    sys.exit(code if code >= 0 else 128 - code)

op = req.get("op")
if op == "start":
    agent, session, command = req.get("agent"), req.get("session", ""), req.get("command")
    folder = req.get("folder", "")
    if (agent, command) not in (("claude", "claude"), ("codex", "codex")):
        reply({"hs_error": "it can only start Claude Code or Codex"})
        sys.exit(0)
    if not session_log(agent, session):
        reply({"hs_error": "that session isn't on this server anymore"})
        sys.exit(0)
    if not os.path.isdir(folder):
        reply({"hs_error": "the session's folder isn't there anymore: " + folder})
        sys.exit(0)
    program = find(command)
    if not program:
        reply({"hs_error": command + " isn't installed here (looked in PATH, ~/.local/bin, ~/.npm-global/bin and nvm)"})
        sys.exit(0)
    os.makedirs(base, mode=0o700, exist_ok=True)
    for old in glob.glob(os.path.join(base, "*")):
        try:
            if time.time() - os.path.getmtime(old) > 7 * 86400:
                os.remove(old)
        except OSError:
            pass
    name = time.strftime("%Y%m%d-%H%M%S") + "-" + agent + "-" + session[:8] + "-" + os.urandom(3).hex()
    prompt_path = os.path.join(base, name + ".prompt")
    log_path = os.path.join(base, name + ".log")
    with os.fdopen(os.open(prompt_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w", encoding="utf-8") as f:
        f.write(req.get("prompt", ""))
    os.close(os.open(log_path, os.O_WRONLY | os.O_CREAT, 0o600))
    env = dict(os.environ)
    for key in ("CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SSE_PORT"):
        env.pop(key, None)
    env["PATH"] = os.pathsep.join([os.path.dirname(program)] + folders())
    pid = os.fork()
    if pid == 0:
        # The supervisor: its own session, away from SSH's, its output to the log.
        code = 127
        try:
            os.setsid()
            quiet = os.open(os.devnull, os.O_RDWR)
            for fd in (0, 1, 2):
                os.dup2(quiet, fd)
            with open(log_path, "ab", buffering=0) as log:
                try:
                    with open(prompt_path, "rb") as prompt:
                        os.remove(prompt_path)
                        child = subprocess.Popen([program] + [str(a) for a in req.get("arguments", [])], cwd=folder,
                                                 stdin=prompt, stdout=log, stderr=subprocess.STDOUT, env=env)
                    code = child.wait()
                    if code < 0:
                        code = 128 - code
                except OSError as error:
                    log.write((command + " didn't start: " + str(error) + "\n").encode())
                log.write(("\n" + json.dumps({"hs_exit": code}) + "\n").encode())
        finally:
            os._exit(0)
    reply({"hs_started": pid, "log": log_path})
elif op == "keep":
    # A session kept open: the agent in its long-running mode, on this SSH
    # connection, so it ends when the connection does (or goes quiet).
    agent, session, command = req.get("agent"), req.get("session", ""), req.get("command")
    folder = req.get("folder", "")
    arguments = [str(a) for a in req.get("arguments", [])]
    long_running = (command == "claude" and "--input-format" in arguments) or (command == "codex" and arguments[:1] == ["app-server"])
    if (agent, command) not in (("claude", "claude"), ("codex", "codex")) or not long_running:
        reply({"hs_error": "it can only keep Claude Code or Codex open"})
        sys.exit(0)
    if not session_log(agent, session):
        reply({"hs_error": "that session isn't on this server anymore"})
        sys.exit(0)
    if not os.path.isdir(folder):
        reply({"hs_error": "the session's folder isn't there anymore: " + folder})
        sys.exit(0)
    program = find(command)
    if not program:
        reply({"hs_error": command + " isn't installed here (looked in PATH, ~/.local/bin, ~/.npm-global/bin and nvm)"})
        sys.exit(0)
    for key in ("CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SSE_PORT"):
        os.environ.pop(key, None)
    os.environ["PATH"] = os.pathsep.join([os.path.dirname(program)] + folders())
    os.chdir(folder)
    out.flush()
    keep(program, arguments, float(req.get("quiet") or 600))
elif op == "put":
    # Files sent with a prompt: kept a week, readable only by you.
    store = os.path.join(home, ".cache", "agent-buddy", "attachments")
    os.makedirs(store, mode=0o700, exist_ok=True)
    for old in glob.glob(os.path.join(store, "*")):
        try:
            if time.time() - os.path.getmtime(old) > 7 * 86400:
                for name in os.listdir(old):
                    os.remove(os.path.join(old, name))
                os.rmdir(old)
        except OSError:
            pass
    folder = os.path.join(store, time.strftime("%Y%m%d-%H%M%S") + "-" + os.urandom(3).hex())
    os.makedirs(folder, mode=0o700)
    paths = []
    for item in req.get("files", []):
        name = os.path.basename(str(item.get("name", ""))).replace(",", "_") or "file"
        if name.startswith("."):
            name = "_" + name
        path = os.path.join(folder, name)
        with os.fdopen(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "wb") as f:
            f.write(base64.b64decode(item.get("data", "")))
        paths.append(path)
    reply({"paths": paths})
elif op == "files":
    # The session folder's files, for the message box's @: what git tracks and doesn't ignore, else a walk.
    folder = req.get("folder", "")
    if not os.path.isdir(folder):
        reply({"hs_error": "the session's folder isn't there anymore: " + folder})
        sys.exit(0)
    files = []
    try:
        listed = subprocess.run(["git", "-C", folder, "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
                                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=15)
        if listed.returncode == 0:
            files = [p for p in listed.stdout.decode("utf-8", "replace").split("\0") if p][:20000]
    except (OSError, subprocess.TimeoutExpired):
        pass
    if not files:
        skipped = {".git", "node_modules", ".build", "build", "dist", "target", ".venv", "venv", "__pycache__", ".next", ".cache",
                   "DerivedData", "Pods"}
        for top, dirs, names in os.walk(folder):
            dirs[:] = sorted(d for d in dirs if d not in skipped and not d.startswith("."))
            here = os.path.relpath(top, folder)
            # Folders too, as Zed's @ has them (an empty one included).
            files += [(name if here == "." else os.path.join(here, name)) + "/" for name in dirs]
            for name in sorted(names):
                if not name.startswith("."):
                    files.append(name if here == "." else os.path.join(here, name))
            if len(files) >= 20000:
                break
    reply({"files": files[:20000]})
elif op == "commands":
    # The message box's /: the agent's commands, plugins' and skills, in your home and the session's folder.
    agent, folder = req.get("agent"), req.get("folder", "")
    def front(path):
        try:
            with open(path, encoding="utf-8", errors="replace") as f:
                text = f.read(65536)
        except OSError:
            return {}, ""
        meta = {}
        if text.startswith("---"):
            end = text.find("\n---", 3)
            if end > 0:
                for line in text[3:end].splitlines():
                    key, colon, value = line.partition(":")
                    key, value = key.strip(), value.strip().strip("\"'")
                    if colon and key and value and " " not in key:
                        meta[key] = value
                text = text[end + 4:].split("\n", 1)[1] if "\n" in text[end + 4:] else ""
        return meta, text.strip()
    def first_line(text):
        for line in text.splitlines():
            if line.strip():
                return line.strip("# ").strip()[:120]
        return ""
    def markdown(top, nested):
        found = []
        for here, dirs, names in os.walk(top):
            dirs[:] = sorted(d for d in dirs if not d.startswith(".")) if nested else []
            for name in sorted(names):
                if name.endswith(".md") and len(found) < 500:
                    meta, body = front(os.path.join(here, name))
                    rel = os.path.relpath(os.path.join(here, name), top)[:-3].replace(os.sep, ":")
                    found.append((rel, meta.get("description") or first_line(body), body))
        return found
    def skills(top, depth):
        found = []
        base = top.rstrip(os.sep).count(os.sep)
        for here, dirs, names in os.walk(top):
            if here.count(os.sep) - base >= depth:
                dirs[:] = []
            if "SKILL.md" in names and len(found) < 500:
                meta, body = front(os.path.join(here, "SKILL.md"))
                found.append((meta.get("name") or os.path.basename(here), meta.get("description") or first_line(body)))
        return found
    commands = []
    if agent == "claude":
        for root in [os.path.join(home, ".claude")] + ([os.path.join(folder, ".claude")] if folder else []):
            commands += [{"name": n, "description": d, "kind": "command"} for n, d, _ in markdown(os.path.join(root, "commands"), True)]
            commands += [{"name": n, "description": d, "kind": "skill"} for n, d in skills(os.path.join(root, "skills"), 3)]
        try:
            with open(os.path.join(home, ".claude", "plugins", "installed_plugins.json")) as f:
                plugins = json.load(f).get("plugins") or {}
        except (OSError, ValueError):
            plugins = {}
        for installs in plugins.values():
            for install in installs if isinstance(installs, list) else []:
                path = install.get("installPath") if isinstance(install, dict) else None
                if path:
                    commands += [{"name": n, "description": d, "kind": "command"} for n, d, _ in markdown(os.path.join(path, "commands"), False)]
                    commands += [{"name": n, "description": d, "kind": "skill"} for n, d in skills(path, 2)]
    elif agent == "codex":
        commands += [{"name": "prompts:" + n, "description": d, "kind": "prompt", "body": b}
                     for n, d, b in markdown(os.path.join(home, ".codex", "prompts"), False)]
        commands += [{"name": n, "description": d, "kind": "skill", "sign": "$"} for n, d in skills(os.path.join(home, ".codex", "skills"), 3)]
    reply({"commands": commands})
elif op == "models":
    # Codex's models, as its app-server lists them (the first page, and a few more).
    import select
    program = find("codex")
    if not program:
        reply({"hs_error": "codex isn't installed here"})
        sys.exit(0)
    env = dict(os.environ)
    env["PATH"] = os.pathsep.join([os.path.dirname(program)] + folders())
    p = subprocess.Popen([program, "app-server"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                         env=env, cwd=home)
    pending = [b""]
    def ask(i, method, params):
        p.stdin.write((json.dumps({"id": i, "method": method, "params": params}) + "\n").encode())
        p.stdin.flush()
        until = time.time() + 20
        while time.time() < until:
            while b"\n" in pending[0]:
                line, pending[0] = pending[0].split(b"\n", 1)
                try:
                    o = json.loads(line)
                except ValueError:
                    continue
                if o.get("id") == i:
                    return o
            ready, _, _ = select.select([p.stdout], [], [], 0.5)
            if ready:
                chunk = os.read(p.stdout.fileno(), 65536)
                if not chunk:
                    break
                pending[0] += chunk
        return None
    try:
        started = ask(1, "initialize", {"clientInfo": {"name": "agent-buddy", "title": "Agent Buddy", "version": "1"}})
        if not started or "result" not in started:
            reply({"hs_error": "codex didn't start"})
            sys.exit(0)
        p.stdin.write(b'{"method":"initialized"}\n')
        p.stdin.flush()
        models, cursor = [], None
        for page in range(5):
            listed = ask(2 + page, "model/list", {"cursor": cursor} if cursor else {})
            if not listed or "result" not in listed:
                break
            models += listed["result"].get("data") or []
            cursor = listed["result"].get("nextCursor")
            if not cursor:
                break
        reply({"models": models} if models else {"hs_error": "codex listed no models"})
    finally:
        p.kill()
elif op in ("status", "stop"):
    log = req.get("log", "")
    if not ours(log):
        reply({"hs_error": "that send isn't Agent Buddy's"})
        sys.exit(0)
    pid = int(req.get("pid") or 0)
    if op == "stop":
        try:
            os.killpg(pid, signal.SIGTERM)
        except (OSError, ValueError):
            pass
        reply({"stopped": True})
        sys.exit(0)
    alive = False
    try:
        os.kill(pid, 0)
        alive = True
    except (OSError, ValueError):
        pass
    tail = ""
    try:
        with open(log, "rb") as f:
            f.seek(0, 2)
            f.seek(max(0, f.tell() - 65536))
            tail = f.read().decode("utf-8", "replace")
    except OSError:
        pass
    reply({"alive": alive, "tail": tail})
else:
    reply({"hs_error": "unknown request"})
"""#
}

extension PromptSender.Request {
    /// The session as it would be resumed with `prompt`: in the folder it began
    /// in (Claude Code keeps sessions by folder; Codex goes on in its last one),
    /// with its model and how it was let act.
    public init(history: SessionHistory, host: String?, prompt: String) {
        let folder = history.agent == .claude ? history.cwd : history.folders.last ?? history.cwd
        self.init(
            agent: history.agent, sessionID: history.sessionID, host: host, folder: folder ?? "", prompt: prompt,
            model: history.model, permissionMode: history.permissionMode, sandbox: history.sandbox, effort: history.effort,
            permissionProfile: history.permissionProfile, approvalPolicy: history.approvalPolicy, approvalsReviewer: history.approvalsReviewer)
    }
}

extension Executables {
    private static let newestLock = NSLock()
    nonisolated(unsafe) private static var newestFound: [String: (url: URL, at: Date)] = [:]

    /// The newest version of `name` among the copies installed (by its
    /// `--version`): the Codex inside the ChatGPT app is often newer than one
    /// installed by hand, and resumes what the app wrote. Kept ten minutes.
    public static func newest(_ name: String) -> URL? {
        newestLock.lock()
        if let kept = newestFound[name], Date().timeIntervalSince(kept.at) < 600 {
            newestLock.unlock()
            return kept.url
        }
        newestLock.unlock()
        var seen = Set<String>()
        var best: (version: [Int], url: URL)?
        for path in candidates(name) where isExecutable(path) {
            let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            guard seen.insert(real).inserted, seen.count <= 8 else { continue }
            guard let result = ProcessRunner.run(URL(fileURLWithPath: path), ["--version"], timeout: 5), result.status == 0 else { continue }
            let version = versionNumbers(result.text)
            if best == nil || best!.version.lexicographicallyPrecedes(version) {
                best = (version, URL(fileURLWithPath: path))
            }
        }
        guard let found = best?.url ?? find(name) else { return nil }
        newestLock.lock()
        newestFound[name] = (found, Date())
        newestLock.unlock()
        return found
    }

    /// "codex-cli 0.163.0-alpha.11" → [0, 163, 0].
    public static func versionNumbers(_ text: String) -> [Int] {
        guard let range = text.range(of: #"\d+(\.\d+)+"#, options: .regularExpression) else { return [] }
        return text[range].split(separator: ".").compactMap { Int($0) }
    }
}
