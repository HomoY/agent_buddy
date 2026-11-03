import Foundation

/// Token counts from a server you reach over SSH, where Claude Code, Codex or
/// Copilot also run (in a VS Code or Zed remote terminal, say). A small Python
/// script runs there and prints only token counts, never conversation text.
/// The counts are kept in a cache of this server's own, so a server that can't
/// be reached still shows what it last reported.
public final class RemoteTokenSource: @unchecked Sendable {
    public let host: String
    private let transport: [String]
    private let cacheURL: URL?
    private let lock = NSLock()
    private var files: [String: RemoteFile] = [:]

    struct RemoteFile: Codable {
        var agent: Agent
        var size: Int
        var modified: Double
        var offset: Int
        var entries: [String: TokenEntry]
    }

    /// `transport` runs `python3 -` on the server, reading the script from stdin;
    /// by default `ssh` in batch mode, which never asks for a password.
    public init(host: String, cacheURL: URL?, transport: [String]? = nil) {
        self.host = host
        self.cacheURL = cacheURL
        self.transport = transport ?? Self.ssh(host)
        if let cacheURL, let data = try? Data(contentsOf: cacheURL),
           let saved = try? JSONDecoder().decode([String: RemoteFile].self, from: data) {
            files = saved
        }
    }

    public static func ssh(_ host: String) -> [String] {
        ["/usr/bin/ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=10",
         "-o", "ServerAliveCountMax=3", host, "exec python3 -"]
    }

    /// What the server last reported, without asking it.
    public func cachedEntries(now: Date = Date()) -> [TokenEntry] {
        lock.lock()
        defer { lock.unlock() }
        return entries(after: Self.cutoff(now))
    }

    /// Asks the server what's new since the last answer. Blocking.
    public func refresh(now: Date = Date(), timeout: TimeInterval = 180) -> Result<[TokenEntry], ReadError> {
        lock.lock()
        defer { lock.unlock() }
        let known = files.mapValues { [$0.size, $0.modified, $0.offset] as [Any] }
        guard let state = try? JSONSerialization.data(withJSONObject: ["days": TokenLedger.windowDays, "files": known] as [String: Any]),
              let program = transport.first
        else { return .failure(ReadError("Couldn't prepare the request for \(host)")) }
        let script = Self.script.replacingOccurrences(of: "__STATE__", with: state.base64EncodedString())
        guard let result = ProcessRunner.run(
            URL(fileURLWithPath: program), Array(transport.dropFirst()), environment: Environment.engineEnvironment(),
            input: Data(script.utf8), timeout: timeout)
        else { return .failure(ReadError("\(host) didn't answer within \(Int(timeout)) s")) }
        if result.status != 0 {
            let detail = String(decoding: result.errorOutput, as: UTF8.self)
                .split(whereSeparator: \.isNewline).last.map(String.init)?
                .trimmingCharacters(in: .whitespaces) ?? ""
            switch result.status {
            case 255:
                return .failure(ReadError("Couldn't connect to \(host)\(detail.isEmpty ? "" : ": \(detail)")"))
            case 127:
                return .failure(ReadError("python3 isn't installed on \(host)"))
            default:
                return .failure(ReadError("\(host): \(detail.isEmpty ? "the counter stopped (exit \(result.status))" : detail)"))
            }
        }
        var present: Set<String>?
        var done = false
        var updates: [(path: String, file: RemoteFile, fresh: Bool)] = []
        for line in result.output.split(separator: 0x0A) {
            guard let value = JSON.parse(Data(line)) else { continue }
            if let path = value["f"].string, let agent = Agent(rawValue: value["a"].string ?? "") {
                var entries: [String: TokenEntry] = [:]
                for item in value["e"].array {
                    let parts = item.array
                    guard parts.count == 7, let key = parts[0].string, let at = parts[2].double else { continue }
                    entries[key] = TokenEntry(
                        agent: agent, model: parts[1].string ?? agent.rawValue, at: Date(timeIntervalSince1970: at),
                        counts: TokenCounts(
                            input: parts[3].int ?? 0, output: parts[4].int ?? 0,
                            cacheWrite: parts[5].int ?? 0, cacheRead: parts[6].int ?? 0),
                        source: host)
                }
                let file = RemoteFile(
                    agent: agent, size: value["s"].int ?? 0, modified: value["m"].double ?? 0,
                    offset: value["o"].int ?? 0, entries: entries)
                updates.append((path, file, value["r"].bool ?? true))
            } else if !value["present"].isNull {
                present = Set(value["present"].array.compactMap(\.string))
            } else if value["done"].bool == true {
                done = true
            }
        }
        guard done else { return .failure(ReadError("The answer from \(host) was cut short")) }
        for update in updates {
            if !update.fresh, var old = files[update.path] {
                old.entries.merge(update.file.entries) { $1 }
                old.size = update.file.size
                old.modified = update.file.modified
                old.offset = update.file.offset
                files[update.path] = old
            } else {
                files[update.path] = update.file
            }
        }
        if let present {
            files = files.filter { present.contains($0.key) }
        }
        let cutoff = Self.cutoff(now)
        for path in Array(files.keys) {
            guard var file = files[path] else { continue }
            file.entries = file.entries.filter { $0.value.at >= cutoff }
            files[path] = file
        }
        if let cacheURL, let data = try? JSONEncoder().encode(files) {
            try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: cacheURL, options: .atomic)
        }
        return .success(entries(after: cutoff))
    }

    private func entries(after cutoff: Date) -> [TokenEntry] {
        var unique: [String: TokenEntry] = [:]
        for file in files.values {
            for (key, entry) in file.entries where entry.at >= cutoff {
                unique[key] = entry
            }
        }
        return Array(unique.values)
    }

    private static func cutoff(_ now: Date) -> Date {
        now.addingTimeInterval(-Double(TokenLedger.windowDays) * 86400)
    }

    /// The counter that runs on the server (Python 3.6 or later, standard library only).
    static let script = #"""
# Agent Buddy's token counter, run on a server over SSH. It reads the agents'
# session logs there and prints only token counts (never conversation text),
# one JSON object per changed log, so Agent Buddy can add them to its statistics.
# STATE holds what Agent Buddy already knows: {"days": 35, "files": {path: [size, mtime, offset]}}.
import base64, calendar, json, os, re, sys, time

STATE = json.loads(base64.b64decode("__STATE__").decode("utf-8"))
NOW = time.time()
CUTOFF = NOW - STATE.get("days", 35) * 86400
KNOWN = STATE.get("files", {})
TS = re.compile(r"(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(\.\d+)?(Z|[+-]\d{2}:?\d{2})?")


def emit(obj):
    sys.stdout.write(json.dumps(obj, separators=(",", ":")) + "\n")


def stamp(text):
    match = TS.match(text or "")
    if not match:
        return None
    parts = [int(match.group(i)) for i in range(1, 7)]
    seconds = calendar.timegm((parts[0], parts[1], parts[2], parts[3], parts[4], parts[5], 0, 0, 0))
    if match.group(7):
        seconds += float(match.group(7))
    zone = match.group(8)
    if zone and zone != "Z":
        sign = 1 if zone[0] == "+" else -1
        seconds -= sign * (int(zone[1:3]) * 3600 + int(zone[-2:]) * 60)
    return seconds


def number(value):
    try:
        return int(value or 0)
    except (TypeError, ValueError):
        return 0


def whole_lines(path, offset):
    with open(path, "rb") as handle:
        handle.seek(offset)
        data = handle.read()
    end = data.rfind(b"\n")
    if end < 0:
        return [], offset
    return data[:end].split(b"\n"), offset + end + 1


def claude(path, offset):
    lines, end = whole_lines(path, offset)
    entries = []
    for line in lines:
        if b'"usage"' not in line:
            continue
        try:
            value = json.loads(line)
        except ValueError:
            continue
        if value.get("type") != "assistant":
            continue
        message = value.get("message") or {}
        usage = message.get("usage")
        if not isinstance(usage, dict) or not message.get("id") or message.get("model") == "<synthetic>":
            continue
        at = stamp(value.get("timestamp"))
        if at is None:
            continue
        counts = [number(usage.get("input_tokens")), number(usage.get("output_tokens")),
                  number(usage.get("cache_creation_input_tokens")), number(usage.get("cache_read_input_tokens"))]
        if sum(counts) > 0:
            key = "claude:%s:%s" % (message["id"], value.get("requestId") or "")
            entries.append([key, message.get("model") or "claude", at] + counts)
    return entries, end


def codex_counts(usage):
    if not isinstance(usage, dict):
        return None
    given, cached, written = number(usage.get("input_tokens")), number(usage.get("cached_input_tokens")), number(usage.get("cache_write_input_tokens"))
    return [max(given - cached - written, 0), number(usage.get("output_tokens")), written, cached]


def codex(path):
    lines, end = whole_lines(path, 0)
    model, thread = "codex", os.path.basename(path)[:-6]
    records, fallback, previous = [], [], None
    for line in lines:
        if b"token_" not in line and b'"turn_context"' not in line and b'"session_meta"' not in line:
            continue
        try:
            value = json.loads(line)
        except ValueError:
            continue
        payload = value.get("payload") or {}
        kind = value.get("type")
        if kind == "session_meta":
            thread = payload.get("id") or thread
        elif kind == "turn_context":
            model = payload.get("model") or model
        elif kind == "token_usage_record":
            counts, at = codex_counts(payload.get("usage")), stamp(value.get("timestamp"))
            if payload.get("response_id") and counts and sum(counts) > 0 and at is not None:
                records.append(["codex:" + payload["response_id"], model, at] + counts)
        elif kind == "event_msg" and payload.get("type") == "token_count":
            total, at = codex_counts((payload.get("info") or {}).get("total_token_usage")), stamp(value.get("timestamp"))
            if total is None or at is None:
                continue
            before = previous or [0, 0, 0, 0]
            previous = total
            delta = [max(a - b, 0) for a, b in zip(total, before)]
            if sum(delta) > 0:
                fallback.append(["codex:%s:%d" % (thread, int(at * 1000)), model, at] + delta)
    # A log with usage records counts those; token_count repeats the same use.
    return (records or fallback), end


def copilot(path):
    lines, end = whole_lines(path, 0)
    session = os.path.basename(os.path.dirname(path))
    entries = {}
    for line in lines:
        if b"session.shutdown" not in line:
            continue
        try:
            value = json.loads(line)
        except ValueError:
            continue
        if value.get("type") != "session.shutdown":
            continue
        at = stamp(value.get("timestamp"))
        if at is None:
            continue
        for model, metric in ((value.get("data") or {}).get("modelMetrics") or {}).items():
            usage = (metric or {}).get("usage") or {}
            read, written = number(usage.get("cacheReadTokens")), number(usage.get("cacheWriteTokens"))
            counts = [max(number(usage.get("inputTokens")) - read - written, 0), number(usage.get("outputTokens")), written, read]
            if sum(counts) > 0:
                key = "copilot:%s:%s" % (session, model)
                entries[key] = [key, model, at] + counts
    return list(entries.values()), end


def main():
    home = os.path.expanduser("~")
    roots = [
        ("claude", os.path.join(os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(home, ".claude"), "projects"),
         lambda name: name.endswith(".jsonl")),
        ("codex", os.path.join(os.environ.get("CODEX_HOME") or os.path.join(home, ".codex"), "sessions"),
         lambda name: name.startswith("rollout-") and name.endswith(".jsonl")),
        ("copilot", os.path.join(os.environ.get("COPILOT_HOME") or os.path.join(home, ".copilot"), "session-state"),
         lambda name: name == "events.jsonl"),
    ]
    present = []
    for agent, top, accept in roots:
        if not os.path.isdir(top):
            continue
        for folder, folders, names in os.walk(top):
            folders[:] = [name for name in folders if not name.startswith(".")]
            for name in names:
                if name.startswith(".") or not accept(name):
                    continue
                path = os.path.join(folder, name)
                try:
                    info = os.stat(path)
                except OSError:
                    continue
                if info.st_mtime < CUTOFF:
                    continue
                present.append(path)
                old = KNOWN.get(path)
                if old and old[0] == info.st_size and abs(old[1] - info.st_mtime) < 0.001:
                    continue
                try:
                    if agent == "claude" and old and info.st_size > old[2] and info.st_mtime >= old[1] - 0.001:
                        entries, offset = claude(path, old[2])
                        fresh = False
                    elif agent == "claude":
                        entries, offset = claude(path, 0)
                        fresh = True
                    elif agent == "codex":
                        (entries, offset), fresh = codex(path), True
                    else:
                        (entries, offset), fresh = copilot(path), True
                except (OSError, MemoryError):
                    continue
                emit({"f": path, "a": agent, "s": info.st_size, "m": info.st_mtime, "o": offset, "r": fresh,
                      "e": [entry for entry in entries if entry[2] >= CUTOFF]})
    emit({"present": present})
    emit({"done": True})


main()
"""#
}

/// Servers to suggest: the hosts in ~/.ssh/config, Zed's SSH connections and
/// VS Code's Remote-SSH hosts.
public enum RemoteHosts {
    public static func suggestions() -> [String] {
        var hosts: [String] = []
        let home = Environment.home
        if let text = try? String(contentsOf: home.appendingPathComponent(".ssh/config"), encoding: .utf8) {
            for line in text.split(whereSeparator: \.isNewline) {
                let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" })
                guard words.first?.lowercased() == "host" else { continue }
                for name in words.dropFirst() where !name.contains("*") && !name.contains("?") && !name.hasPrefix("!") {
                    hosts.append(String(name))
                }
            }
        }
        let zed = [".config/zed/settings.json", "Library/Application Support/Zed/settings.json"]
        for path in zed {
            guard let settings = jsonc(home.appendingPathComponent(path)) else { continue }
            for connection in settings["ssh_connections"].array {
                guard let host = connection["host"].nonEmptyString else { continue }
                if let user = connection["username"].nonEmptyString, !hosts.contains(host) {
                    hosts.append("\(user)@\(host)")
                } else {
                    hosts.append(host)
                }
            }
        }
        if let code = jsonc(home.appendingPathComponent("Library/Application Support/Code/User/settings.json")) {
            hosts += (code["remote.SSH.remotePlatform"].object ?? [:]).keys.sorted()
        }
        var seen = Set<String>()
        return hosts.filter { seen.insert($0.lowercased()).inserted }
    }

    /// Settings files with comments and trailing commas (JSON5 reads both).
    private static func jsonc(_ url: URL) -> JSON? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.json5Allowed])
        else { return nil }
        return JSON(object)
    }
}
