import Foundation

/// The models and efforts an agent window's message box offers Claude Code:
/// its aliases for the latest of each model, which it resolves itself.
public enum ClaudeModels {
    public static let aliases: Set<String> = ["fable", "opus", "sonnet", "haiku", "best", "opusplan", "fable[1m]", "opus[1m]", "sonnet[1m]"]
    /// The menu's choices, in order.
    public static let choices = ["fable", "opus", "sonnet", "haiku"]
    public static let efforts = ["low", "medium", "high", "xhigh", "max"]

    /// "claude-opus-5-5" → "Opus 5.5"; "opus" → "Opus"; anything else as it is.
    public static func name(_ model: String) -> String {
        if let alias = choices.first(where: { $0 == model }) {
            return alias.prefix(1).uppercased() + alias.dropFirst()
        }
        let parts = model.split(separator: "-")
        guard parts.count >= 3, parts[0] == "claude" else { return model }
        let family = parts[1].prefix(1).uppercased() + parts[1].dropFirst()
        // The version: the numbers after the family, up to a date if there is one.
        let version = parts.dropFirst(2).prefix { $0.count <= 2 && $0.allSatisfy(\.isNumber) }
        return version.isEmpty ? family : "\(family) \(version.joined(separator: "."))"
    }
}

/// A model Codex offers, from its own list (its app-server's `model/list`).
public struct CodexModel: Sendable, Equatable {
    /// What `-m` takes.
    public var id: String
    public var name: String
    public var efforts: [String]
    public var defaultEffort: String?
    /// Whether it has the fast service tier.
    public var fast: Bool
    public var isDefault: Bool

    public init(id: String, name: String, efforts: [String], defaultEffort: String?, fast: Bool, isDefault: Bool) {
        self.id = id
        self.name = name
        self.efforts = efforts
        self.defaultEffort = defaultEffort
        self.fast = fast
        self.isDefault = isDefault
    }
}

public enum CodexModels {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var known: [String: (models: [CodexModel], at: Date)] = [:]

    /// Codex's models, here or on a server, asked of its app-server (it starts
    /// no thread and sends no prompt); remembered an hour. Blocking. `executable`
    /// and `transport` are for the checks.
    public static func list(
        host: String?, executable: URL? = nil, transport: [String]? = nil, environment: [String: String]? = nil
    ) -> Result<[CodexModel], ReadError> {
        let key = host ?? ""
        lock.lock()
        if let remembered = known[key], Date().timeIntervalSince(remembered.at) < 3600, executable == nil, transport == nil {
            lock.unlock()
            return .success(remembered.models)
        }
        lock.unlock()
        let listed: Result<[JSON], ReadError>
        if let host {
            guard let reply = PromptSender.remote(["op": "models"], host: host, transport: transport, timeout: 40) else {
                return .failure(ReadError("\(host) didn't answer"))
            }
            if let problem = reply["hs_error"].nonEmptyString {
                return .failure(ReadError("\(host): \(problem)"))
            }
            listed = .success(reply["models"].array)
        } else {
            guard let program = executable ?? Executables.newest("codex") else {
                return .failure(ReadError("Codex isn't installed on this Mac."))
            }
            listed = askHere(program, environment: environment ?? Environment.engineEnvironment())
        }
        switch listed {
        case .failure(let problem):
            return .failure(problem)
        case .success(let items):
            let models = items.compactMap(model)
            guard !models.isEmpty else { return .failure(ReadError("Codex listed no models.")) }
            if executable == nil, transport == nil {
                lock.lock()
                known[key] = (models, Date())
                lock.unlock()
            }
            return .success(models)
        }
    }

    /// A model from Codex's list.
    static func model(_ item: JSON) -> CodexModel? {
        guard let id = item["model"].nonEmptyString ?? item["id"].nonEmptyString, item["hidden"].bool != true else { return nil }
        let tiers = item["serviceTiers"].array.compactMap { $0["id"].string } + item["additionalSpeedTiers"].array.compactMap(\.string)
        return CodexModel(
            id: id, name: item["displayName"].nonEmptyString ?? id,
            efforts: item["supportedReasoningEfforts"].array.compactMap { $0["reasoningEffort"].string },
            defaultEffort: item["defaultReasoningEffort"].nonEmptyString,
            fast: tiers.contains("fast") || tiers.contains("priority"), isDefault: item["isDefault"].bool == true)
    }

    /// Codex's app-server on this Mac: started, asked, and stopped.
    private static func askHere(_ program: URL, environment: [String: String]) -> Result<[JSON], ReadError> {
        let process = Process()
        process.executableURL = program
        process.arguments = ["app-server"]
        process.environment = environment
        process.currentDirectoryURL = Environment.home
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let guarded = NSLock()
        var pending = Data()
        var answers: [Int: JSON] = [:]
        let arrived = DispatchSemaphore(value: 0)
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guarded.lock()
            pending.append(data)
            while let end = pending.firstIndex(of: 0x0A) {
                let line = pending[pending.startIndex..<end]
                pending.removeSubrange(pending.startIndex...end)
                if let answer = JSON.parse(Data(line)), let id = answer["id"].int {
                    answers[id] = answer
                }
            }
            guarded.unlock()
            if data.isEmpty {
                handle.readabilityHandler = nil
            }
            arrived.signal()
        }
        do {
            try process.run()
        } catch {
            return .failure(ReadError("Codex didn't start: \(error.localizedDescription)"))
        }
        defer {
            output.fileHandleForReading.readabilityHandler = nil
            if process.isRunning {
                process.terminate()
            }
        }
        func send(_ message: [String: Any]) {
            guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
            try? input.fileHandleForWriting.write(contentsOf: data + Data([0x0A]))
        }
        func answer(_ id: Int) -> JSON? {
            let until = Date().addingTimeInterval(20)
            while Date() < until {
                guarded.lock()
                let found = answers[id]
                guarded.unlock()
                if let found {
                    return found
                }
                guard process.isRunning || arrived.wait(timeout: .now()) == .success else { return nil }
                _ = arrived.wait(timeout: .now() + 0.5)
            }
            return nil
        }
        send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "agent-buddy", "title": "Agent Buddy", "version": "1"]]])
        guard let started = answer(1), started["error"].isNull else {
            return .failure(ReadError("Codex didn't start."))
        }
        send(["method": "initialized"])
        var models: [JSON] = []
        var cursor: String?
        for page in 0..<5 {
            send(["id": 2 + page, "method": "model/list", "params": cursor.map { ["cursor": $0] } ?? [String: Any]()])
            guard let listed = answer(2 + page), listed["error"].isNull else { break }
            models += listed["result"]["data"].array
            cursor = listed["result"]["nextCursor"].nonEmptyString
            if cursor == nil {
                break
            }
        }
        return models.isEmpty ? .failure(ReadError("Codex listed no models.")) : .success(models)
    }
}

/// Files sent with a prompt to a session on a server: copied there first, as
/// the agent reads them where it runs.
public enum RemoteFiles {
    /// Most a prompt's files may weigh, together.
    public static let limit = 30 * 1024 * 1024

    /// The files' paths on the server, under `~/.cache/agent-buddy/attachments`. Blocking.
    public static func put(_ files: [URL], host: String, transport: [String]? = nil) -> Result<[String], ReadError> {
        var items: [[String: String]] = []
        var total = 0
        for file in files {
            guard let data = try? Data(contentsOf: file) else {
                return .failure(ReadError("Agent Buddy can't read \(file.lastPathComponent)."))
            }
            total += data.count
            guard total <= limit else {
                return .failure(ReadError("The files are too big to send together (at most \(limit / 1024 / 1024) MB)."))
            }
            items.append(["name": file.lastPathComponent, "data": data.base64EncodedString()])
        }
        guard let reply = PromptSender.remote(["op": "put", "files": items], host: host, transport: transport, timeout: 120) else {
            return .failure(ReadError("\(host) didn't answer, so nothing was sent."))
        }
        if let problem = reply["hs_error"].nonEmptyString {
            return .failure(ReadError("\(host): \(problem)"))
        }
        let paths = reply["paths"].array.compactMap(\.string)
        guard paths.count == files.count else { return .failure(ReadError("\(host) didn't keep the files.")) }
        return .success(paths)
    }
}
