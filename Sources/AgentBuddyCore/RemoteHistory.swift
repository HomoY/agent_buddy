import Foundation

/// The prompt history of a session on a server: one `python3` run over SSH
/// reads its log there and sends back slimmed lines (the fields the history
/// needs; prompts cut short, answers whole), which `SessionHistoryReader` reads like a local log.
public enum RemoteHistory {
    /// Blocking; `transport` runs `python3 -` on the server (by default `ssh` in
    /// batch mode, which never asks for a password). Without a `path`, the
    /// session's log is looked for there by its id.
    public static func fetch(
        host: String, agent: Agent, path: String?, sessionID: String, transport: [String]? = nil, timeout: TimeInterval = 60
    ) -> Result<SessionHistory, ReadError> {
        let command = transport ?? RemoteTokenSource.ssh(host)
        guard let request = try? JSONSerialization.data(withJSONObject: [
            "agent": agent.rawValue, "path": path ?? "", "session": sessionID,
        ]),
              let program = command.first
        else { return .failure(ReadError("Couldn't prepare the request for \(host)")) }
        let script = Self.script.replacingOccurrences(of: "__REQUEST__", with: request.base64EncodedString())
        guard let result = ProcessRunner.run(
            URL(fileURLWithPath: program), Array(command.dropFirst()), environment: Environment.engineEnvironment(),
            input: Data(script.utf8), timeout: timeout)
        else { return .failure(ReadError("\(host) didn't answer within \(Int(timeout)) s")) }
        guard result.status == 0 else {
            let detail = String(decoding: result.errorOutput, as: UTF8.self)
                .split(whereSeparator: \.isNewline).last.map(String.init)?
                .trimmingCharacters(in: .whitespaces) ?? ""
            switch result.status {
            case 255: return .failure(ReadError("Couldn't connect to \(host)\(detail.isEmpty ? "" : ": \(detail)")"))
            case 127: return .failure(ReadError("python3 isn't installed on \(host)"))
            default: return .failure(ReadError("\(host): \(detail.isEmpty ? "exit \(result.status)" : detail)"))
            }
        }
        var lines = SessionHistoryReader.lines(result.output)
        if let problem = lines.first?["hs_error"].string {
            return .failure(ReadError("\(host): \(problem)"))
        }
        let found = lines.first?["hs_path"].string
        let writer = lines.first?["hs_writer"].string
        if found != nil {
            lines.removeFirst()
        }
        var history: SessionHistory
        switch agent {
        case .claude: history = SessionHistoryReader.claude(lines: lines, sessionID: sessionID)
        case .codex: history = SessionHistoryReader.codex(lines: lines, sessionID: sessionID)
        case .copilot: history = SessionHistoryReader.copilot(lines: lines, sessionID: sessionID, workspace: nil)
        default:
            // Watched on this Mac only, not on servers yet.
            return .failure(ReadError("Agent Buddy reads \(agent.clientName)'s sessions on this Mac only, not on servers yet."))
        }
        history.logPath = found ?? path
        history.openElsewhere = writer
        return .success(history)
    }

    /// What the agent did in one turn of a session on a server: the server sends
    /// back that turn's lines (its prompt's on), slimmed to what the steps need.
    public static func steps(
        host: String, agent: Agent, path: String?, sessionID: String, turn: PromptTurn, cwd: String?,
        transport: [String]? = nil, timeout: TimeInterval = 60
    ) -> Result<[TurnStep], ReadError> {
        let command = transport ?? RemoteTokenSource.ssh(host)
        guard let request = try? JSONSerialization.data(withJSONObject: [
            "agent": agent.rawValue, "path": path ?? "", "session": sessionID,
            "turn": turn.id, "at": turn.askedAt.timeIntervalSince1970,
        ]),
              let program = command.first
        else { return .failure(ReadError("Couldn't prepare the request for \(host)")) }
        let script = Self.script.replacingOccurrences(of: "__REQUEST__", with: request.base64EncodedString())
        guard let result = ProcessRunner.run(
            URL(fileURLWithPath: program), Array(command.dropFirst()), environment: Environment.engineEnvironment(),
            input: Data(script.utf8), timeout: timeout)
        else { return .failure(ReadError("\(host) didn't answer within \(Int(timeout)) s")) }
        guard result.status == 0 else {
            return .failure(ReadError(result.status == 255 ? "Couldn't connect to \(host)" : "\(host): exit \(result.status)"))
        }
        var lines = SessionHistoryReader.lines(result.output)
        if let problem = lines.first?["hs_error"].string {
            return .failure(ReadError("\(host): \(problem)"))
        }
        if lines.first?["hs_path"].string != nil {
            lines.removeFirst()
        }
        return .success(SessionHistoryReader.steps(agent: agent, lines: lines, turn: turn, cwd: cwd))
    }

    /// Who has a Codex thread open for writing on the server ("VS Code"), if
    /// anyone; nil too if the server didn't answer. One short SSH run.
    public static func codexWriter(host: String, thread: String, transport: [String]? = nil) -> String? {
        codexHolder(host: host, thread: thread, transport: transport)?.name
    }

    /// The program holding a Codex thread on the server: its name, process, and the threads it holds.
    public static func codexHolder(host: String, thread: String, transport: [String]? = nil) -> CodexHolder? {
        let held = writerCheck(["thread": thread, "do": "holder"], host: host, transport: transport)?["held"]
        guard let held, held.isObject, let name = held["name"].nonEmptyString else { return nil }
        return CodexHolder(name: name, pid: Int32(held["pid"].int ?? 0), threads: held["threads"].array.compactMap(\.string))
    }

    /// Stops the Codex holding the thread on the server, if it still does (and
    /// is Codex): true once the thread is free.
    public static func stopCodex(host: String, thread: String, pid: Int32, transport: [String]? = nil) -> Bool {
        writerCheck(["thread": thread, "do": "stop", "pid": Int(pid)], host: host, transport: transport, timeout: 30)?["stopped"].bool == true
    }

    private static func writerCheck(_ request: [String: Any], host: String, transport: [String]?, timeout: TimeInterval = 20) -> JSON? {
        let command = transport ?? RemoteTokenSource.ssh(host)
        guard let program = command.first, let encoded = try? JSONSerialization.data(withJSONObject: request) else { return nil }
        let script = "import base64, json, os\nhome = os.path.expanduser(\"~\")\nreq = json.loads(base64.b64decode(\"\(encoded.base64EncodedString())\"))\n"
            + writerFunction + """

            if req.get("do") == "stop":
                print(json.dumps({"stopped": codex_stop(req.get("thread", ""), int(req.get("pid") or 0))}))
            else:
                print(json.dumps({"held": codex_holder(req.get("thread", ""))}))

            """
        guard let result = ProcessRunner.run(
            URL(fileURLWithPath: program), Array(command.dropFirst()), environment: Environment.engineEnvironment(),
            input: Data(script.utf8), timeout: timeout),
              result.status == 0
        else { return nil }
        return SessionHistoryReader.lines(result.output).last
    }

    /// Reads only session logs under the agents' own folders, whatever path it's sent.
    public static var script: String {
        template.replacingOccurrences(of: "__CODEX_WRITER__", with: writerFunction)
    }

    /// Codex lets one program at a time write to a thread, holding a lock (flock)
    /// on `~/.codex/thread-writer-locks/<thread>.lock`: who holds it, from /proc.
    static let writerFunction = #"""
LOCKS = os.path.realpath(os.path.join(home, ".codex", "thread-writer-locks"))

def codex_name(command):
    command = command.lower()
    if "codex" not in command:
        return "another program"
    for mark, name in ((".vscode", "VS Code"), ("cursor", "Cursor"), ("windsurf", "Windsurf"), ("zed", "Zed")):
        if mark in command:
            return name
    return "Codex in a terminal"

def codex_holder(thread):
    # Codex lets one program at a time write to a thread, holding a lock (flock)
    # on its file while it does: that program's name, process and the threads it
    # holds; None if nobody holds it.
    if not thread or "/" in thread:
        return None
    lock = os.path.join(LOCKS, thread + ".lock")
    try:
        fd = os.open(lock, os.O_RDONLY)
    except OSError:
        return None
    try:
        import fcntl
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            fcntl.flock(fd, fcntl.LOCK_UN)
            return None
        except OSError:
            pass
    finally:
        os.close(fd)
    for pid in (os.listdir("/proc") if os.path.isdir("/proc") else []):
        if not pid.isdigit():
            continue
        try:
            links = [os.readlink("/proc/%s/fd/%s" % (pid, n)) for n in os.listdir("/proc/%s/fd" % pid)]
        except OSError:
            continue
        if lock in links:
            try:
                with open("/proc/%s/cmdline" % pid, "rb") as f:
                    command = f.read().replace(b"\0", b" ").decode("utf-8", "replace")
                program = os.path.basename(os.readlink("/proc/%s/exe" % pid)).lower()
            except OSError:
                command, program = "", ""
            threads = sorted(os.path.basename(l)[:-5] for l in links if os.path.dirname(l) == LOCKS and l.endswith(".lock"))
            # Codex by its program's name; its command line says where it runs.
            name = codex_name(command) if program.startswith("codex") else "another program"
            return {"name": name, "pid": int(pid), "threads": threads}
    return {"name": "another program", "pid": 0, "threads": []}

def codex_writer(thread):
    held = codex_holder(thread)
    return held["name"] if held else None

def codex_stop(thread, pid):
    # Stops the program holding the thread, only if it's Codex and still holds it;
    # True once the thread is free.
    held = codex_holder(thread)
    if not held:
        return True
    if not pid or held["pid"] != pid or held["name"] == "another program":
        return False
    import signal, time
    os.kill(pid, signal.SIGTERM)
    for _ in range(60):
        time.sleep(0.1)
        if not codex_holder(thread):
            return True
    return False
"""#

    static let template = #"""
import base64, json, os, sys

req = json.loads(base64.b64decode("__REQUEST__"))
agent = req.get("agent")
home = os.path.expanduser("~")
roots = {
    "claude": os.path.join(home, ".claude", "projects"),
    "codex": os.path.join(home, ".codex", "sessions"),
    "copilot": os.path.join(home, ".copilot", "session-state"),
}
root = os.path.realpath(roots.get(agent, "/nonexistent"))
session = req.get("session", "")
out = sys.stdout

def find_session():
    # By the session's id, for a job whose log path wasn't recorded.
    if not session or "/" in session or session.startswith("."):
        return ""
    if agent == "copilot":
        return os.path.join(root, session, "events.jsonl")
    if agent == "claude":
        try:
            projects = os.listdir(root)
        except OSError:
            return ""
        for project in projects:
            candidate = os.path.join(root, project, session + ".jsonl")
            if os.path.isfile(candidate):
                return candidate
        return ""
    for folder, _, files in os.walk(root):
        for name in files:
            if name.endswith(session + ".jsonl"):
                return os.path.join(folder, name)
    return ""

given = req.get("path", "")
path = os.path.realpath(os.path.expanduser(given)) if given else ""
if not path or not os.path.isfile(path):
    found = find_session()
    path = os.path.realpath(found) if found else ""
if not path.startswith(root + os.sep) or not path.endswith(".jsonl") or not os.path.isfile(path):
    out.write(json.dumps({"hs_error": "that session log isn't there anymore"}) + "\n")
    sys.exit(0)

__CODEX_WRITER__
first = {"hs_path": path}
if agent == "codex" and not req.get("turn"):
    writer = codex_writer(session)
    if writer:
        first["hs_writer"] = writer
out.write(json.dumps(first) + "\n")

LONG = 4000
SHORT = 100000

def cut(value, limit):
    return value[:limit] if isinstance(value, str) else value

def steps_mode():
    # One turn: its prompt's line and the turn's after it, with the tools'
    # calls and results the steps show (outputs cut short, files' contents left out).
    turn = req.get("turn")
    at = float(req.get("at") or 0)
    emitted = [0]

    def emit(o):
        out.write(json.dumps(o, separators=(",", ":")) + "\n")
        emitted[0] += 1

    def trim(v, limit=LONG):
        if isinstance(v, str):
            return v[:limit]
        if isinstance(v, list):
            return [trim(x, limit) for x in v[:2000]]
        if isinstance(v, dict):
            return {k: trim(x, SHORT if k == "text" else 60000 if k in ("unified_diff", "content", "input") else limit)
                    for k, x in v.items() if k not in ("originalFile", "base64", "encrypted_content", "signature")}
        return v

    def patch(hunks):
        kept, room = [], 400
        for h in hunks if isinstance(hunks, list) else []:
            if not isinstance(h, dict) or room <= 0:
                continue
            lines = [x for x in (h.get("lines") or []) if isinstance(x, str)][:room]
            room -= len(lines)
            hunk = {k: h.get(k) for k in ("oldStart", "newStart")}
            hunk["lines"] = [x[:LONG] for x in lines]
            kept.append(hunk)
        return kept

    def claude_line(o):
        keep = {k: o[k] for k in ("type", "uuid", "parentUuid", "logicalParentUuid", "isSidechain", "isMeta",
                                  "isCompactSummary", "timestamp") if k in o}
        m = o.get("message")
        if isinstance(m, dict):
            slim = {k: m[k] for k in ("role", "model", "id") if k in m}
            c = m.get("content")
            if isinstance(c, str):
                slim["content"] = c[:LONG]
            elif isinstance(c, list):
                parts = []
                for p in c:
                    if not isinstance(p, dict):
                        continue
                    kind = p.get("type")
                    if kind == "text":
                        parts.append({"type": "text", "text": cut(p.get("text", ""), SHORT)})
                    elif kind == "tool_use":
                        parts.append({"type": kind, "id": p.get("id"), "name": p.get("name"), "input": trim(p.get("input"), 20000)})
                    elif kind == "tool_result":
                        rc = p.get("content")
                        rc = [{"type": "text", "text": cut(x.get("text", ""), LONG)} for x in rc
                              if isinstance(x, dict) and x.get("type") == "text"] if isinstance(rc, list) else cut(rc, LONG)
                        parts.append({"type": kind, "tool_use_id": p.get("tool_use_id"), "is_error": p.get("is_error"), "content": rc})
                    else:
                        parts.append({"type": kind})
                slim["content"] = parts
            keep["message"] = slim
        r = o.get("toolUseResult")
        if isinstance(r, dict):
            res = {k: r[k] for k in ("interrupted", "type", "filePath", "numFiles", "numLines", "bytes", "code", "codeText") if k in r}
            for k in ("stdout", "stderr"):
                if isinstance(r.get(k), str):
                    res[k] = r[k][:LONG]
            if r.get("type") == "create" and isinstance(r.get("content"), str):
                res["content"] = r["content"][:60000]
            if isinstance(r.get("file"), dict):
                res["file"] = {"numLines": r["file"].get("numLines")}
            if "structuredPatch" in r:
                res["structuredPatch"] = patch(r.get("structuredPatch"))
            keep["toolUseResult"] = res
        return keep

    def claude_prompt(o):
        # A prompt you typed, roughly as the history tells one.
        if o.get("type") != "user" or o.get("isMeta") or o.get("isCompactSummary"):
            return False
        m = o.get("message") if isinstance(o.get("message"), dict) else {}
        c = m.get("content")
        if isinstance(c, list):
            if any(isinstance(p, dict) and p.get("type") == "tool_result" for p in c):
                return False
            c = "\n".join(p.get("text", "") for p in c if isinstance(p, dict) and p.get("type") == "text")
        if not isinstance(c, str):
            return False
        c = c.strip()
        markers = ("[Request interrupted", "<command-name>", "<command-message>", "<local-command-", "<bash-input>",
                   "<bash-stdout>", "<bash-stderr>", "<user-memory-input>")
        return bool(c) and not c.startswith(markers)

    def seconds(o):
        p = o.get("payload") if isinstance(o.get("payload"), dict) else {}
        if isinstance(p.get("completed_at_ms"), (int, float)):
            return p["completed_at_ms"] / 1000
        stamp = o.get("timestamp")
        if not isinstance(stamp, str) or len(stamp) < 19:
            return None
        import calendar, time
        try:
            whole = calendar.timegm(time.strptime(stamp[:19], "%Y-%m-%dT%H:%M:%S"))
        except ValueError:
            return None
        fraction = stamp[19:].rstrip("Z").split("+")[0]
        return whole + (float(fraction) if fraction.startswith(".") and fraction[1:].isdigit() else 0)

    def codex_prompt(o):
        p = o.get("payload") if isinstance(o.get("payload"), dict) else {}
        item = p.get("item") if isinstance(p.get("item"), dict) else {}
        return o.get("type") == "event_msg" and (p.get("type") == "user_message"
                                                 or (p.get("type") == "item_completed" and item.get("type") == "UserMessage"))

    with open(path, encoding="utf-8", errors="replace") as f:
        if agent == "claude":
            owner, started = {turn: turn}, False
            for line in f:
                try:
                    o = json.loads(line)
                except ValueError:
                    continue
                if not isinstance(o, dict):
                    continue
                if not started:
                    if o.get("uuid") == turn:
                        started = True
                        emit(claude_line(o))
                    continue
                uuid = o.get("uuid")
                if o.get("isSidechain") or not uuid:
                    continue
                own = owner.get(o.get("parentUuid") or o.get("logicalParentUuid"))
                if claude_prompt(o):
                    if own == turn:
                        break
                    owner[uuid] = uuid
                    continue
                owner[uuid] = own
                if own == turn:
                    emit(claude_line(o))
                if emitted[0] > 8000:
                    break
        elif agent == "codex":
            # From the first prompt near its time to the first prompt well after:
            # the reader picks the turn's prompt among them by its words.
            started = False
            for line in f:
                try:
                    o = json.loads(line)
                except ValueError:
                    continue
                if not isinstance(o, dict):
                    continue
                when = seconds(o)
                if not started:
                    if not (codex_prompt(o) and when is not None and abs(when - at) < 2):
                        continue
                    started = True
                elif codex_prompt(o) and when is not None and when - at > 2:
                    break
                t = o.get("type")
                p = o.get("payload") if isinstance(o.get("payload"), dict) else {}
                if t == "event_msg" and p.get("type") in ("user_message", "agent_message", "item_completed"):
                    emit({"type": t, "timestamp": o.get("timestamp"), "payload": trim(p)})
                elif t == "response_item" and p.get("type") not in ("reasoning", "additional_tools"):
                    emit({"type": t, "timestamp": o.get("timestamp"), "payload": trim(p)})
                if emitted[0] > 8000:
                    break

if req.get("turn"):
    steps_mode()
    sys.exit(0)

def claude(o):
    keep = {}
    for k in ("type", "uuid", "parentUuid", "logicalParentUuid", "isSidechain", "isMeta", "isCompactSummary",
              "isApiErrorMessage", "error", "timestamp", "cwd", "entrypoint", "gitBranch", "aiTitle",
              "customTitle", "summary", "subtype", "requestId", "permissionMode"):
        if k in o:
            keep[k] = o[k]
    m = o.get("message")
    if isinstance(m, dict):
        slim = {k: m[k] for k in ("role", "model", "stop_reason", "id") if k in m}
        usage = m.get("usage")
        if isinstance(usage, dict):
            slim["usage"] = {k: usage[k] for k in ("input_tokens", "output_tokens", "cache_creation_input_tokens",
                                                     "cache_read_input_tokens") if isinstance(usage.get(k), int)}
        # A sub-agent's words aren't shown; only its tokens count.
        limit = 0 if o.get("isSidechain") else LONG if m.get("role") == "user" else SHORT
        c = m.get("content")
        if isinstance(c, str):
            slim["content"] = cut(c, limit)
        elif isinstance(c, list):
            parts = []
            for p in c:
                if isinstance(p, dict):
                    if p.get("type") == "text":
                        parts.append({"type": "text", "text": cut(p.get("text", ""), limit)})
                    else:
                        parts.append({"type": p.get("type")})
            slim["content"] = parts
        keep["message"] = slim
    return keep

def codex(o):
    t = o.get("type")
    p = o.get("payload") if isinstance(o.get("payload"), dict) else {}
    if t == "session_meta":
        git = p.get("git") if isinstance(p.get("git"), dict) else {}
        return {"type": t, "payload": {"id": p.get("id"), "cwd": p.get("cwd"), "originator": p.get("originator"),
                                       "git": {"branch": git.get("branch")}}}
    if t == "turn_context":
        sandbox = p.get("sandbox_policy")
        sandbox = sandbox.get("type") if isinstance(sandbox, dict) else sandbox
        profile = p.get("active_permission_profile")
        profile = profile.get("id") if isinstance(profile, dict) else None
        return {"type": t, "payload": {"cwd": p.get("cwd"), "model": p.get("model"), "effort": p.get("effort"),
                                       "sandbox_policy": {"type": sandbox}, "active_permission_profile": {"id": profile},
                                       "approval_policy": p.get("approval_policy") if isinstance(p.get("approval_policy"), str) else None,
                                       "approvals_reviewer": p.get("approvals_reviewer") if isinstance(p.get("approvals_reviewer"), str) else None}}
    if t == "token_usage_record":
        return {"type": t, "timestamp": o.get("timestamp"),
                "payload": {"response_id": p.get("response_id"), "turn_id": p.get("turn_id"), "usage": p.get("usage")}}
    if t != "event_msg":
        return None
    kind = p.get("type")
    if kind == "user_message":
        slim = {"type": kind, "message": cut(p.get("message", ""), LONG),
                "images": [1] * len(p.get("images") or []), "local_images": [1] * len(p.get("local_images") or [])}
    elif kind == "agent_message":
        slim = {"type": kind, "message": cut(p.get("message", ""), SHORT)}
    elif kind == "task_complete":
        slim = {"type": kind, "last_agent_message": cut(p.get("last_agent_message"), SHORT), "error": p.get("error")}
    elif kind in ("turn_aborted", "task_started"):
        slim = {"type": kind}
    elif kind == "token_count":
        info = p.get("info") if isinstance(p.get("info"), dict) else {}
        if not isinstance(info.get("total_token_usage"), dict):
            return None
        slim = {"type": kind, "info": {"total_token_usage": info.get("total_token_usage")}}
    elif kind == "item_completed":
        item = p.get("item") if isinstance(p.get("item"), dict) else {}
        if item.get("type") not in ("UserMessage", "AgentMessage"):
            return None
        limit = LONG if item.get("type") == "UserMessage" else SHORT
        parts = []
        for c in item.get("content") or []:
            if isinstance(c, dict):
                parts.append({"type": c.get("type"), "text": cut(c.get("text"), limit)} if "text" in c else {"type": c.get("type")})
        slim = {"type": kind, "item": {"type": item.get("type"), "content": parts}}
    else:
        return None
    for k in ("turn_id", "completed_at_ms"):
        if k in p:
            slim[k] = p[k]
    return {"type": t, "timestamp": o.get("timestamp"), "payload": slim}

def copilot(o):
    t = o.get("type")
    d = o.get("data") if isinstance(o.get("data"), dict) else {}
    if t == "session.start":
        ctx = d.get("context") if isinstance(d.get("context"), dict) else {}
        slim = {"context": {"cwd": ctx.get("cwd")}, "producer": d.get("producer")}
    elif t == "user.message":
        slim = {"content": cut(d.get("content", ""), LONG)}
    elif t == "assistant.message":
        slim = {"content": cut(d.get("content", ""), SHORT), "toolRequests": [1] * len(d.get("toolRequests") or [])}
    elif t == "hook.start":
        inp = d.get("input") if isinstance(d.get("input"), dict) else {}
        slim = {"hookType": d.get("hookType"), "input": {"stopReason": inp.get("stopReason")}}
    elif t in ("assistant.turn_end", "abort"):
        slim = {}
    elif t == "session.shutdown":
        metrics = d.get("modelMetrics") if isinstance(d.get("modelMetrics"), dict) else {}
        slim = {"modelMetrics": {name: {"usage": (m or {}).get("usage")} for name, m in metrics.items() if isinstance(m, dict)}}
    else:
        return None
    return {"type": t, "timestamp": o.get("timestamp"), "id": o.get("id"), "agentId": o.get("agentId"), "data": slim}

if agent == "copilot":
    name = cwd = None
    try:
        with open(os.path.join(os.path.dirname(path), "workspace.yaml"), encoding="utf-8", errors="replace") as f:
            for line in f:
                if line[:1].isspace() or ":" not in line:
                    continue
                key, value = line.split(":", 1)
                value = value.strip()
                if len(value) >= 2 and value[0] == value[-1] and value[0] in "'\"":
                    value = value[1:-1]
                if key.strip() == "name" and value:
                    name = value
                elif key.strip() == "cwd" and value:
                    cwd = value
    except OSError:
        pass
    out.write(json.dumps({"type": "hs.workspace", "data": {"name": name, "cwd": cwd}}) + "\n")

slimmer = {"claude": claude, "codex": codex, "copilot": copilot}[agent]

def stream(file, keep=None, mark=None):
    with open(file, encoding="utf-8", errors="replace") as f:
        for line in f:
            try:
                o = json.loads(line)
            except ValueError:
                continue
            if not isinstance(o, dict) or (keep and not keep(o)):
                continue
            if mark:
                o.update(mark)
            slim = slimmer(o)
            if slim is not None:
                out.write(json.dumps(slim, separators=(",", ":")) + "\n")

stream(path)
# Sub-agents' logs, so their tokens count in the job that started them.
if agent == "claude":
    folder = os.path.join(os.path.dirname(path), os.path.splitext(os.path.basename(path))[0], "subagents")
    for top, _, files in os.walk(folder):
        for name in files:
            if name.endswith(".jsonl"):
                stream(os.path.join(top, name), keep=lambda o: o.get("type") == "assistant", mark={"isSidechain": True})
elif agent == "codex":
    thread = None
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            first = json.loads(f.readline())
        thread = (first.get("payload") or {}).get("id")
    except (OSError, ValueError):
        pass
    since = os.path.getmtime(path) - 40 * 86400
    for top, _, files in os.walk(root):
        for name in files:
            child = os.path.join(top, name)
            if not thread or not name.startswith("rollout-") or not name.endswith(".jsonl") or child == path:
                continue
            try:
                if os.path.getmtime(child) < since:
                    continue
                with open(child, encoding="utf-8", errors="replace") as f:
                    meta = json.loads(f.readline())
            except (OSError, ValueError):
                continue
            source = (meta.get("payload") or {}).get("source")
            spawn = source.get("subagent", {}).get("thread_spawn", {}) if isinstance(source, dict) and isinstance(source.get("subagent"), dict) else {}
            if isinstance(spawn, dict) and spawn.get("parent_thread_id") == thread:
                out.write(json.dumps({"type": "hs.subagent"}) + "\n")
                stream(child, keep=lambda o: o.get("type") in ("turn_context", "token_usage_record", "event_msg"))
"""#
}
