import Foundation

/// A live view of a server's agent sessions: an SSH connection running a small
/// Python watcher there, which streams a slimmed copy of each new session-log
/// line (the fields that tell a turn finished, text cut short). Agent Buddy feeds
/// the lines to its `TranscriptWatcher`, so a job finishing on the server
/// reminds you like one on this Mac. When the link drops it reconnects, waiting
/// 5, 10, 20, 40, then 60 seconds between tries.
public final class RemoteSessionStream: @unchecked Sendable {
    public enum Status: Equatable, Sendable {
        case connecting
        case live
        case retrying(String)
        case stopped
    }

    public let host: String
    /// Lines of one log: (path on the server, agent, lines, first line if they start further in, clock skew).
    public var onLines: ((String, Agent, [JSON], JSON?, TimeInterval) -> Void)?
    /// Codex thread names: (thread id, name).
    public var onNames: (([(String, String)]) -> Void)?
    public var onStatus: ((Status) -> Void)?

    private let transport: [String]
    private let configuration: String
    private let queue = DispatchQueue(label: "AgentBuddy.RemoteSessionStream")
    private var process: Process?
    private var buffer = Data()
    private var errorText = Data()
    /// Of this connection: 0 when ssh has exited, 1 when its error output has ended.
    private var gone: Set<Int> = []
    private var stopped = true
    private var live = false
    private var failures = 0
    private var skew: TimeInterval = 0
    private var generation = 0

    /// `transport` runs `python3 -u -` on the server with the script on stdin;
    /// by default `ssh` in batch mode, which never asks for a password.
    public init(host: String, transport: [String]? = nil, poll: Double = 1, scan: Double = 10) {
        self.host = host
        self.transport = transport ?? [
            "/usr/bin/ssh", "-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3", host, "exec python3 -u -",
        ]
        let settings: [String: Any] = ["tail": 524_288, "recent": 900, "poll": poll, "scan": scan]
        configuration = ((try? JSONSerialization.data(withJSONObject: settings)) ?? Data("{}".utf8)).base64EncodedString()
    }

    public func start() {
        queue.async {
            guard self.stopped else { return }
            self.stopped = false
            self.failures = 0
            self.connect()
        }
    }

    /// Stops and disconnects, before returning (for when Agent Buddy quits).
    public func stop() {
        queue.sync {
            stopped = true
            generation += 1
            process?.terminate()
            process = nil
            live = false
            onStatus?(.stopped)
        }
    }

    private func connect() {
        guard !stopped, process == nil, let program = transport.first else { return }
        generation += 1
        let current = generation
        onStatus?(.connecting)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: program)
        process.arguments = Array(transport.dropFirst())
        process.environment = Environment.engineEnvironment()
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self?.queue.async { self?.receive(data, generation: current) }
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                self?.queue.async { self?.closed(.errors, generation: current) }
                return
            }
            self?.queue.async {
                guard let self, self.generation == current, self.errorText.count < 8192 else { return }
                self.errorText.append(data)
            }
        }
        process.terminationHandler = { [weak self] _ in
            self?.queue.async { self?.closed(.process, generation: current) }
        }
        buffer = Data()
        errorText = Data()
        gone = []
        live = false
        do {
            try process.run()
        } catch {
            ended(generation: current, reason: "couldn't start ssh: \(error.localizedDescription)")
            return
        }
        self.process = process
        let script = Data(Self.script.replacingOccurrences(of: "__CONFIG__", with: configuration).utf8)
        DispatchQueue.global().async {
            // Python reads the whole script, then runs it once stdin closes.
            try? input.fileHandleForWriting.write(contentsOf: script)
            try? input.fileHandleForWriting.close()
        }
    }

    private func receive(_ data: Data, generation current: Int) {
        guard current == generation else { return }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            if let value = JSON.parse(line) {
                handle(value)
            }
        }
    }

    private func handle(_ value: JSON) {
        if let clock = value["clock"].double {
            skew = clock - Date().timeIntervalSince1970
            if !live {
                live = true
                failures = 0
                onStatus?(.live)
            }
        }
        if let path = value["p"].string, let agent = Agent(rawValue: value["a"].string ?? "") {
            onLines?(path, agent, value["l"].array, value["prime"].isObject ? value["prime"] : nil, skew)
        }
        let names = value["names"].array.compactMap { pair -> (String, String)? in
            let parts = pair.array
            guard parts.count == 2, let thread = parts[0].string, let name = parts[1].string else { return nil }
            return (thread, name)
        }
        if !names.isEmpty {
            onNames?(names)
        }
    }

    private enum Part {
        case process
        case errors
    }

    /// It ended when ssh has exited and said all it had to: why is in its last
    /// words, which can come after the exit (or half a second at most).
    private func closed(_ part: Part, generation current: Int) {
        guard current == generation else { return }
        gone.insert(part == .process ? 0 : 1)
        if gone == [0, 1] {
            ended(generation: current)
        } else if part == .process {
            queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, self.generation == current, self.gone == [0] else { return }
                self.gone = [0, 1]
                self.ended(generation: current)
            }
        }
    }

    private func ended(generation current: Int, reason given: String? = nil) {
        guard current == generation else { return }
        process = nil
        live = false
        guard !stopped else { return }
        failures += 1
        let said = String(decoding: errorText, as: UTF8.self)
            .split(whereSeparator: \.isNewline).last.map(String.init)?
            .trimmingCharacters(in: .whitespaces)
        var reason = given ?? said ?? "the connection closed"
        if reason.contains("python3: not found") || reason.contains("python3: command not found") {
            reason = "python3 isn't installed on \(host)"
        }
        onStatus?(.retrying(reason))
        let delay = min(60, 5 * pow(2, Double(min(failures, 5) - 1)))
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.connect()
        }
    }

    /// The watcher that runs on the server (Python 3.6 or later, standard library only).
    public static let script = #"""
# Agent Buddy's session watcher, run on a server over SSH. It follows the agents'
# session logs there and streams a slimmed copy of each new line (only the
# fields Agent Buddy reads to tell a turn finished, with text cut short), so
# Agent Buddy can remind you when a job finishes on the server. It stops when
# Agent Buddy disconnects.
import base64, json, os, sys, time

CONFIG = json.loads(base64.b64decode("__CONFIG__").decode("utf-8"))
TAIL = CONFIG.get("tail", 524288)
RECENT = CONFIG.get("recent", 900)
POLL = CONFIG.get("poll", 1.0)
SCAN = CONFIG.get("scan", 10.0)
TEXT = 400
HOME = os.path.expanduser("~")
CLAUDE = os.path.join(os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(HOME, ".claude"), "projects")
CODEX_HOME = os.environ.get("CODEX_HOME") or os.path.join(HOME, ".codex")
CODEX = os.path.join(CODEX_HOME, "sessions")
INDEX = os.path.join(CODEX_HOME, "session_index.jsonl")
COPILOT = os.path.join(os.environ.get("COPILOT_HOME") or os.path.join(HOME, ".copilot"), "session-state")


def send(obj):
    sys.stdout.write(json.dumps(obj, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def cut(value):
    return value[:TEXT] if isinstance(value, str) else value


def pick(source, keys):
    return dict((key, source[key]) for key in keys if key in source)


CLAUDE_TYPES = ("user", "assistant", "system", "ai-title", "custom-title", "summary")


def slim_claude(value):
    if value.get("type") not in CLAUDE_TYPES:
        return None
    small = pick(value, ("type", "subtype", "timestamp", "sessionId", "cwd", "isSidechain", "isMeta",
                         "isCompactSummary", "isApiErrorMessage", "error", "aiTitle", "customTitle", "summary"))
    message = value.get("message")
    if isinstance(message, dict):
        out = pick(message, ("role", "model", "id", "stop_reason"))
        content = message.get("content")
        if isinstance(content, str):
            out["content"] = cut(content)
        elif isinstance(content, list):
            blocks = []
            for block in content:
                if isinstance(block, dict):
                    if block.get("type") == "text":
                        blocks.append({"type": "text", "text": cut(block.get("text"))})
                    else:
                        blocks.append({"type": block.get("type")})
            out["content"] = blocks
        small["message"] = out
    return small


def slim_codex(value):
    kind = value.get("type")
    payload = value.get("payload") or {}
    if kind == "session_meta":
        return {"type": kind, "timestamp": value.get("timestamp"), "payload": pick(payload, ("id", "cwd", "source", "originator"))}
    if kind == "turn_context":
        return {"type": kind, "timestamp": value.get("timestamp"), "payload": pick(payload, ("cwd", "model"))}
    if kind == "response_item":
        return {"type": kind, "timestamp": value.get("timestamp"), "payload": {"type": payload.get("type")}}
    if kind != "event_msg":
        return None
    out = pick(payload, ("type", "turn_id", "duration_ms", "reason", "phase", "channel", "rate_limits"))
    for key in ("message", "last_agent_message"):
        if isinstance(payload.get(key), str):
            out[key] = cut(payload[key])
    if "error" in payload:
        error = payload["error"]
        out["error"] = {"message": cut(error.get("message"))} if isinstance(error, dict) else cut(error)
    item = payload.get("item")
    if isinstance(item, dict):
        out["item"] = {"type": item.get("type"), "phase": item.get("phase"),
                       "content": [{"type": part.get("type"), "text": cut(part.get("text"))}
                                   for part in item.get("content") or [] if isinstance(part, dict)]}
    return {"type": kind, "timestamp": value.get("timestamp"), "payload": out}


def slim_copilot(value):
    small = pick(value, ("type", "id", "timestamp", "agentId"))
    data = value.get("data")
    if isinstance(data, dict):
        out = pick(data, ("hookType",))
        if isinstance(data.get("input"), dict):
            out["input"] = pick(data["input"], ("stopReason",))
        if isinstance(data.get("content"), str):
            out["content"] = cut(data["content"])
        if isinstance(data.get("toolRequests"), list):
            out["toolRequests"] = [{} for _ in data["toolRequests"]]
        if isinstance(data.get("context"), dict):
            out["context"] = pick(data["context"], ("cwd",))
        small["data"] = out
    return small


SLIM = {"claude": slim_claude, "codex": slim_codex, "copilot": slim_copilot}
# Where sessions live, and how many folders below the root their logs sit.
TOPS = ((CLAUDE, "claude", 1), (CODEX, "codex", 3), (COPILOT, "copilot", 1))


def accept(agent, name):
    if agent == "claude":
        return name.endswith(".jsonl")
    if agent == "codex":
        return name.startswith("rollout-") and name.endswith(".jsonl")
    return name == "events.jsonl"


def recent_logs(now):
    found = []
    for top, agent, depth in TOPS:
        if not os.path.isdir(top):
            continue
        for folder, folders, names in os.walk(top):
            level = folder[len(top):].count(os.sep)
            folders[:] = [] if level >= depth else [name for name in folders if not name.startswith(".")]
            if level != depth:
                continue
            for name in names:
                if not accept(agent, name):
                    continue
                path = os.path.join(folder, name)
                try:
                    if os.stat(path).st_mtime >= now - RECENT:
                        found.append((path, agent))
                except OSError:
                    pass
    return found


def read_new(path, state):
    try:
        size = os.path.getsize(path)
    except OSError:
        return None
    if size < state["offset"]:
        state["offset"], state["skip"] = 0, False
    if size == state["offset"]:
        return []
    with open(path, "rb") as handle:
        handle.seek(state["offset"])
        data = handle.read(size - state["offset"])
    end = data.rfind(b"\n")
    if end < 0:
        return []
    state["offset"] += end + 1
    lines = data[:end].split(b"\n")
    if state.pop("skip", False) and lines:
        lines = lines[1:]
    slim, out = SLIM[state["agent"]], []
    for line in lines:
        try:
            value = json.loads(line)
        except ValueError:
            continue
        if isinstance(value, dict):
            small = slim(value)
            if small is not None:
                out.append(small)
    return out


def first_line(path):
    try:
        with open(path, "rb") as handle:
            return json.loads(handle.readline(4194304))
    except (OSError, ValueError):
        return None


def new_names(state):
    try:
        size = os.path.getsize(INDEX)
    except OSError:
        return []
    if size < state["offset"]:
        state["offset"] = 0
    if size == state["offset"]:
        return []
    with open(INDEX, "rb") as handle:
        handle.seek(state["offset"])
        data = handle.read(size - state["offset"])
    end = data.rfind(b"\n")
    if end < 0:
        return []
    state["offset"] += end + 1
    names = []
    for line in data[:end].split(b"\n"):
        try:
            value = json.loads(line)
        except ValueError:
            continue
        if isinstance(value, dict) and value.get("id") and value.get("thread_name"):
            names.append([value["id"], cut(value["thread_name"])])
    return names


def slim_file(agent, path):
    # For Agent Buddy's checks: the slimmed copy of a whole log, then stop.
    state = {"agent": agent, "offset": 0, "skip": False}
    for line in read_new(path, state) or []:
        send(line)


def main():
    if CONFIG.get("slim"):
        slim_file(CONFIG["slim"][0], CONFIG["slim"][1])
        return
    watched, index, last_scan = {}, {"offset": 0}, 0.0
    send({"hello": 1, "clock": time.time()})
    while True:
        now = time.time()
        if now - last_scan >= SCAN:
            last_scan = now
            for path, agent in recent_logs(now):
                if path in watched:
                    continue
                try:
                    size = os.path.getsize(path)
                except OSError:
                    continue
                start = max(0, size - TAIL)
                state = {"agent": agent, "offset": start, "skip": start > 0}
                watched[path] = state
                prime = None
                if agent == "codex" and start > 0:
                    first = first_line(path)
                    prime = slim_codex(first) if isinstance(first, dict) else None
                send({"p": path, "a": agent, "l": read_new(path, state) or [], "prime": prime})
            for path in list(watched):
                try:
                    quiet = os.stat(path).st_mtime < now - 2 * RECENT
                except OSError:
                    quiet = True
                if quiet:
                    del watched[path]
            names = new_names(index)
            if names:
                send({"names": names})
            send({"clock": time.time()})
            if os.getppid() == 1:
                return
        for path, state in list(watched.items()):
            lines = read_new(path, state)
            if lines:
                send({"p": path, "a": state["agent"], "l": lines})
        time.sleep(POLL)


try:
    main()
except (BrokenPipeError, KeyboardInterrupt):
    pass
"""#
}
