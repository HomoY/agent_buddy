import Foundation

/// A session moved into Agent Buddy: the agent kept open in the background, in
/// its own long-running mode, taking one prompt after another, here or on a
/// server through one SSH connection. Claude Code reads its prompts as
/// stream-json on stdin; Codex runs its app-server, spoken to in JSON-RPC.
/// While it's open, Codex counts it as the thread's one writer; closing it
/// (or Agent Buddy quitting) lets go of the thread.
public final class KeptSession: @unchecked Sendable {
    public enum State: Equatable, Sendable {
        /// Starting the agent and resuming the session.
        case opening
        /// Waiting for a prompt.
        case ready
        /// A turn under way.
        case working
        /// Ended: why, when it wasn't let go.
        case closed(String?)
    }

    public let agent: Agent
    public let host: String?
    public let sessionID: String
    /// Told of each change in state, on the main queue.
    public var onChange: (@Sendable (State) -> Void)?

    private let queue = DispatchQueue(label: "io.github.homoy.agentbuddy.kept")
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private var _state: State = .opening
    private var _problem: String?
    private var buffer = Data()
    private var errorTail = ""
    private var letGo = false
    /// Codex: requests awaiting their answer, the turn under way, and its settings.
    private var nextID = 1
    private var answers: [Int: (JSON) -> Void] = [:]
    private var turn: String?
    private let resume: [String: Any]
    private let turnSettings: [String: Any]
    /// How it was last told to work (model, mode, effort, fast): a turn sends what's changed.
    private var applied: PromptSender.Request
    /// On a server: "still here", told the launcher there every so often. Should
    /// it stop hearing that for `quietLimit` (the Mac asleep or offline, the
    /// connection never closed), it ends the agent once no turn is under way.
    private var heartbeat: DispatchSourceTimer?
    public static var heartbeatInterval: TimeInterval = 60
    public static var quietLimit: TimeInterval = 600

    public var state: State {
        queue.sync { _state }
    }

    /// The last turn's problem, if it failed.
    public var problem: String? {
        queue.sync { _problem }
    }

    init(agent: Agent, host: String?, sessionID: String, resume: [String: Any], turnSettings: [String: Any], applied: PromptSender.Request) {
        self.agent = agent
        self.host = host
        self.sessionID = sessionID
        self.resume = resume
        self.turnSettings = turnSettings
        self.applied = applied
    }

    // MARK: - Opening

    /// Starts the agent for the session and resumes it; `executable` and
    /// `transport` are for the checks (a stand-in agent; a stand-in for ssh,
    /// which is given the server's command as its last argument).
    public static func open(
        _ request: PromptSender.Request, executable: URL? = nil, transport: [String]? = nil, logs: URL? = nil
    ) -> Result<KeptSession, ReadError> {
        var probe = request
        probe.prompt = "\u{2026}"
        let plan: PromptSender.Plan
        switch PromptSender.plan(probe) {
        case .success(let made): plan = made
        case .failure(let problem): return .failure(problem)
        }
        let arguments: [String]
        // As a send's: never asking a person, or the session's own reviewer deciding.
        var resume: [String: Any] = ["threadId": request.sessionID, "approvalPolicy": request.reviewedByCodex ? "on-request" : "never",
                                     "excludeTurns": true]
        if request.reviewedByCodex {
            resume["approvalsReviewer"] = "auto_review"
        }
        var turnSettings: [String: Any] = [:]
        switch request.agent {
        case .claude:
            // As a send's, but kept reading prompts: stream-json in and out.
            var made = plan.arguments
            if let format = made.firstIndex(of: "--output-format"), format + 1 < made.count {
                made[format + 1] = "stream-json"
            }
            arguments = made + ["--input-format", "stream-json", "--verbose"]
        case .codex:
            arguments = ["app-server"]
            // As a send's settings, given to the app-server with the thread.
            if let sandbox = plan.arguments.first(where: { $0.hasPrefix("sandbox_mode=") }) {
                resume["sandbox"] = sandbox.dropFirst("sandbox_mode=".count).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
            if let profile = plan.arguments.first(where: { $0.hasPrefix("default_permissions=") }) {
                resume["config"] = ["default_permissions": profile.dropFirst("default_permissions=".count).trimmingCharacters(in: CharacterSet(charactersIn: "\""))]
            }
            if let model = plan.arguments.firstIndex(of: "-m").map({ plan.arguments[$0 + 1] }) {
                resume["model"] = model
            }
            if let effort = plan.arguments.first(where: { $0.hasPrefix("model_reasoning_effort=") }) {
                turnSettings["effort"] = effort.dropFirst("model_reasoning_effort=".count).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
            resume["cwd"] = plan.folder
        default:
            return .failure(ReadError("Not for \(request.agent.clientName)."))
        }
        let session = KeptSession(agent: request.agent, host: request.host, sessionID: request.sessionID, resume: resume,
                                  turnSettings: turnSettings, applied: request)
        if let host = request.host {
            let payload: [String: Any] = [
                "op": "keep", "agent": request.agent.rawValue, "session": request.sessionID, "folder": plan.folder,
                "command": plan.command, "arguments": arguments, "quiet": KeptSession.quietLimit,
            ]
            guard let encoded = try? JSONSerialization.data(withJSONObject: payload) else {
                return .failure(ReadError("Couldn't prepare the request for \(host)"))
            }
            let script = PromptSender.launcher.replacingOccurrences(of: "__REQUEST__", with: encoded.base64EncodedString())
            let bootstrap = "exec python3 -c 'import base64;exec(base64.b64decode(\"\(Data(script.utf8).base64EncodedString())\"))'"
            let command = (transport ?? Array(RemoteTokenSource.ssh(host).dropLast())) + [bootstrap]
            guard let program = command.first else { return .failure(ReadError("No way to reach \(host).")) }
            session.process.executableURL = URL(fileURLWithPath: program)
            session.process.arguments = Array(command.dropFirst())
            session.process.environment = Environment.engineEnvironment()
        } else {
            guard let program = executable ?? (plan.command == "codex" ? Executables.newest("codex") : Executables.find(plan.command)) else {
                return .failure(ReadError("Agent Buddy can't find the \(plan.command) command on this Mac."))
            }
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: plan.folder, isDirectory: &isFolder), isFolder.boolValue else {
                return .failure(ReadError("The session's folder isn't there anymore: \(plan.folder)"))
            }
            session.process.executableURL = program
            session.process.arguments = arguments
            session.process.currentDirectoryURL = URL(fileURLWithPath: plan.folder, isDirectory: true)
            var environment = Environment.engineEnvironment()
            // Not inside another agent's session, whatever started Agent Buddy.
            for name in ["CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SSE_PORT", "CODEX_SANDBOX", "CODEX_SANDBOX_NETWORK_DISABLED"] {
                environment[name] = nil
            }
            session.process.environment = environment
        }
        do {
            try session.run()
        } catch {
            return .failure(ReadError("\(plan.command) didn't start: \(error.localizedDescription)"))
        }
        return .success(session)
    }

    private func run() throws {
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        // Empty data is the end of the output: stop listening then, or the
        // handler is called again at once, without end, at full speed.
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            self?.queue.async { self?.received(data) }
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            self?.queue.async { self?.complained(data) }
        }
        process.terminationHandler = { [weak self] ended in
            self?.queue.async { self?.ended(ended.terminationStatus) }
        }
        try process.run()
        queue.async {
            self.begin()
            if self.host != nil {
                self.beat()
            }
        }
    }

    /// "Still here", on the queue, until it closes: the launcher's own line, never passed to the agent.
    private func beat() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.heartbeatInterval, repeating: Self.heartbeatInterval, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in
            try? self?.input.fileHandleForWriting.write(contentsOf: Data(#"{"agent_buddy":"alive"}"#.utf8 + [0x0A]))
        }
        heartbeat = timer
        timer.resume()
    }

    private func begin() {
        switch agent {
        case .claude:
            // It waits for its first prompt; one that can't resume the session ends at once.
            queue.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, self._state == .opening else { return }
                self.set(.ready)
            }
        case .codex:
            request("initialize", ["clientInfo": ["name": "agent-buddy", "title": "Agent Buddy", "version": "1"]]) { [weak self] answer in
                guard let self else { return }
                guard answer["error"].isNull else {
                    return self.fail(answer["error"]["message"].string ?? "Codex didn't start.")
                }
                self.write(["method": "initialized"])
                self.request("thread/resume", self.resume) { answer in
                    guard answer["error"].isNull else {
                        return self.fail(CodexWriter.plain(answer["error"]["message"].string ?? "Codex couldn't open the thread."))
                    }
                    self.set(.ready)
                }
            }
        default:
            break
        }
    }

    // MARK: - Prompts

    /// Sends a prompt into the session; refused unless it's ready.
    /// A prompt, with the settings it was last told.
    public func send(_ prompt: String) -> Result<Void, ReadError> {
        var request = queue.sync { applied }
        request.prompt = prompt
        request.attachments = []
        return send(request)
    }

    /// A prompt as the message box sends it: what's changed in how it's to work
    /// (model, mode, effort, fast) told first, `images` (files on this Mac)
    /// shown with it, and other files named in its text.
    public func send(_ request: PromptSender.Request, images: [URL] = []) -> Result<Void, ReadError> {
        let shown = KeptSession.read(images)
        return queue.sync {
            guard _state == .ready else {
                return .failure(ReadError(_state == .working ? "It's still working on the last prompt." : "The session isn't open here."))
            }
            _problem = nil
            set(.working)
            let was = applied
            applied = request
            switch agent {
            case .claude:
                for change in KeptSession.claudeChanges(from: was, to: request) {
                    write(["type": "control_request", "request_id": UUID().uuidString, "request": change])
                }
                var content: [[String: Any]] = [["type": "text", "text": request.text]]
                content += shown.map { ["type": "image", "source": ["type": "base64", "media_type": $0.type, "data": $0.data.base64EncodedString()]] }
                write(["type": "user", "message": ["role": "user", "content": content]])
            case .codex:
                var params = turnSettings.merging(KeptSession.codexChanges(from: was, to: request)) { _, changed in changed }
                params["threadId"] = sessionID
                params["input"] = codexInput(request.text, shown)
                self.request("turn/start", params) { [weak self] answer in
                    guard let self else { return }
                    if !answer["error"].isNull {
                        self._problem = answer["error"]["message"].string ?? "Codex didn't start the turn."
                        self.set(.ready)
                    } else if let id = answer["result"]["turn"]["id"].nonEmptyString {
                        self.turn = id
                    }
                }
            default:
                break
            }
            return .success(())
        }
    }

    /// Codex: a prompt added to the turn under way (`turn/steer`), as typing
    /// into Codex while it works does. `then(false)` when it can't be (no turn
    /// under way, or one Codex won't add to): it waits for the next turn instead.
    public func steer(_ request: PromptSender.Request, images: [URL] = [], then: @escaping @Sendable (Bool) -> Void) {
        let shown = KeptSession.read(images)
        queue.async { [self] in
            guard agent == .codex, _state == .working, let turn else { return then(false) }
            self.request("turn/steer", ["threadId": sessionID, "expectedTurnId": turn, "input": codexInput(request.text, shown)]) { answer in
                then(answer["error"].isNull)
            }
        }
    }

    private typealias Picture = (type: String, data: Data, path: String)

    private static func read(_ images: [URL]) -> [Picture] {
        images.compactMap { file in
            guard let data = try? Data(contentsOf: file) else { return nil }
            return (KeptSession.mediaType(file.path), data, file.path)
        }
    }

    /// A prompt as Codex takes it: its text, then its pictures (here, the file;
    /// on a server, the picture itself, as it's on this Mac).
    private func codexInput(_ text: String, _ shown: [Picture]) -> [[String: Any]] {
        [["type": "text", "text": text]] + shown.map { host == nil
            ? ["type": "localImage", "path": $0.path]
            : ["type": "image", "url": "data:\($0.type);base64,\($0.data.base64EncodedString())"] }
    }

    /// Stops the turn under way; the session stays open.
    public func interrupt() {
        queue.async { [self] in
            guard _state == .working else { return }
            switch agent {
            case .claude:
                write(["type": "control_request", "request_id": UUID().uuidString, "request": ["subtype": "interrupt"]])
            case .codex:
                if let turn {
                    request("turn/interrupt", ["threadId": sessionID, "turnId": turn]) { _ in }
                }
            default:
                break
            }
        }
    }

    /// As Agent Buddy quits: its input closed at once, before the app ends (the
    /// agent, here or on the server, ends when its input does).
    public func closeNow() {
        queue.sync {
            letGo = true
            heartbeat?.cancel()
            heartbeat = nil
            try? input.fileHandleForWriting.close()
        }
    }

    /// Lets go of the session: the agent ends, and with it Codex's hold on the thread.
    public func close() {
        queue.async { [self] in
            letGo = true
            try? input.fileHandleForWriting.close()
            queue.asyncAfter(deadline: .now() + 3) { [weak self] in
                if self?.process.isRunning == true {
                    self?.process.terminate()
                }
            }
        }
    }

    // MARK: - Talking to it (on the queue)

    /// Claude Code's control requests for what's changed: its model, its
    /// permission mode, and fast mode and effort (as settings).
    public static func claudeChanges(from was: PromptSender.Request, to now: PromptSender.Request) -> [[String: Any]] {
        var changes: [[String: Any]] = []
        if let model = now.model, model != was.model {
            changes.append(["subtype": "set_model", "model": model])
        }
        if let mode = now.permissionMode, mode != was.permissionMode, mode != "bypassPermissions" {
            changes.append(["subtype": "set_permission_mode", "mode": mode])
        }
        var settings: [String: Any] = [:]
        if let fast = now.fast, fast != was.fast {
            settings["fastMode"] = fast
        }
        if let effort = now.effort, effort != was.effort, ClaudeModels.efforts.contains(effort) {
            settings["effortLevel"] = effort
        }
        if !settings.isEmpty {
            changes.append(["subtype": "apply_flag_settings", "settings": settings])
        }
        return changes
    }

    /// Codex's turn settings: what's chosen, told each turn (the opening
    /// settings ride along with every turn, so a choice not told again would
    /// give way to them); its sandbox only when that changes.
    public static func codexChanges(from was: PromptSender.Request, to now: PromptSender.Request) -> [String: Any] {
        var changes: [String: Any] = [:]
        if let model = now.model {
            changes["model"] = model
        }
        if let effort = now.effort {
            changes["effort"] = effort
        }
        if let fast = now.fast {
            // Null: standard speed.
            changes["serviceTier"] = fast ? "fast" : NSNull()
        }
        if let mode = now.mode {
            changes["approvalPolicy"] = mode == "auto" ? "on-request" : "never"
            changes["approvalsReviewer"] = mode == "auto" ? "auto_review" : "user"
            if (mode == "read-only") != (was.mode == "read-only") {
                changes["sandboxPolicy"] = ["type": mode == "read-only" ? "readOnly" : "workspaceWrite"]
            }
        }
        return changes
    }

    static func mediaType(_ path: String) -> String {
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        default: return "image/png"
        }
    }

    private func write(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        // A process gone: the write fails (Agent Buddy ignores SIGPIPE), and its end says why.
        try? input.fileHandleForWriting.write(contentsOf: data + Data("\n".utf8))
    }

    private func request(_ method: String, _ params: [String: Any], then: @escaping (JSON) -> Void) {
        let id = nextID
        nextID += 1
        answers[id] = then
        write(["id": id, "method": method, "params": params])
    }

    private func received(_ data: Data) {
        guard !data.isEmpty else { return }
        buffer += data
        while let end = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<end]
            buffer = buffer[(end + 1)...]
            if let message = JSON.parse(Data(line)) {
                handle(message)
            }
        }
    }

    private func handle(_ message: JSON) {
        // The server's launcher, refusing before the agent started.
        if let refused = message["hs_error"].nonEmptyString {
            return fail(refused)
        }
        switch agent {
        case .claude:
            if message["type"].string == "result" {
                if message["is_error"].bool == true {
                    _problem = message["result"].nonEmptyString ?? message["subtype"].nonEmptyString ?? "Claude Code stopped with an error"
                }
                set(.ready)
            }
        case .codex:
            if let id = message["id"].int, !message["result"].isNull || !message["error"].isNull, message["method"].isNull {
                answers.removeValue(forKey: id)?(message)
                return
            }
            if let id = message["id"].int, let method = message["method"].string {
                // Codex asks something (an approval, say): Agent Buddy has no one to ask.
                write(["id": id, "error": ["code": -32601, "message": "Agent Buddy can't answer \(method) for this session."]])
                return
            }
            switch message["method"].string {
            case "turn/started":
                turn = message["params"]["turn"]["id"].nonEmptyString ?? turn
            case "turn/completed":
                let ended = message["params"]["turn"]
                if ended["status"].string == "failed" {
                    _problem = ended["error"]["message"].nonEmptyString ?? "Codex stopped with an error"
                }
                turn = nil
                set(.ready)
            case "error":
                if message["params"]["willRetry"].bool != true {
                    _problem = message["params"]["error"]["message"].nonEmptyString ?? _problem
                }
            default:
                break
            }
        default:
            break
        }
    }

    private func complained(_ data: Data) {
        errorTail = String((errorTail + String(decoding: data, as: UTF8.self)).suffix(4000))
    }

    private func ended(_ status: Int32) {
        if case .closed = _state { return }
        if letGo {
            return set(.closed(nil))
        }
        let said = errorTail.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty }
        set(.closed(_problem ?? said.map { CodexWriter.plain(String($0.prefix(300))) } ?? "It stopped (exit \(status))."))
    }

    private func fail(_ why: String) {
        _problem = why
        set(.closed(why))
        letGo = true
        try? input.fileHandleForWriting.close()
        if process.isRunning {
            process.terminate()
        }
    }

    private func set(_ state: State) {
        guard state != _state else { return }
        _state = state
        if case .closed = state {
            heartbeat?.cancel()
            heartbeat = nil
        }
        if let onChange {
            DispatchQueue.main.async { onChange(state) }
        }
    }
}
