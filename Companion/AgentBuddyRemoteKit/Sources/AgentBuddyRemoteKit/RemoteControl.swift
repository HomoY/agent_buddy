import CryptoKit
import Foundation

// MARK: - Sealing

/// Requests from Agent Buddy Remote and the Mac's replies, sealed with the key
/// the pairing code carries (AES-GCM, 256-bit). The ntfy server, and anyone
/// who knows the topic, see only ciphertext: they can't read a request or
/// reply, and can't forge one. Each is bound to its topic and direction.
public enum Sealed {
    public enum Failure: Error, Equatable {
        case badKey
        case unreadable
    }

    public enum Direction: String, Sendable {
        case request
        case reply
    }

    /// A new key: 32 random bytes, base64url.
    public static func newKey() -> String {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }.base64URLEncoded
    }

    public static func isValid(key: String) -> Bool {
        symmetricKey(key) != nil
    }

    static func symmetricKey(_ text: String) -> SymmetricKey? {
        guard let data = Data(base64URL: text), data.count == 32 else { return nil }
        return SymmetricKey(data: data)
    }

    /// What a sealed message is bound to: its topic and direction.
    static func context(_ pairing: Pairing, _ direction: Direction) -> Data {
        Data("agentbuddy-remote/1|\(pairing.topic)|\(direction.rawValue)".utf8)
    }

    /// `value` as JSON, compressed, then sealed.
    public static func seal<T: Encodable>(_ value: T, pairing: Pairing, _ direction: Direction) throws -> Data {
        guard let key = pairing.key.flatMap(symmetricKey) else { throw Failure.badKey }
        let json = try coder.encoder.encode(value)
        // One byte says how it's packed: 1 compressed, 0 as is.
        var packed = Data([0]) + json
        if let compressed = try? (json as NSData).compressed(using: .zlib) as Data, compressed.count < json.count {
            packed = Data([1]) + compressed
        }
        guard let combined = try AES.GCM.seal(packed, using: key, authenticating: context(pairing, direction)).combined else {
            throw Failure.unreadable
        }
        return combined
    }

    /// Opens what `seal` made with the same key, topic and direction; throws for anything else.
    public static func open<T: Decodable>(_ data: Data, pairing: Pairing, _ direction: Direction, as type: T.Type) throws -> T {
        guard let key = pairing.key.flatMap(symmetricKey) else { throw Failure.badKey }
        let box = try AES.GCM.SealedBox(combined: data)
        let packed = try AES.GCM.open(box, using: key, authenticating: context(pairing, direction))
        guard let flag = packed.first else { throw Failure.unreadable }
        var json = Data(packed.dropFirst())
        if flag == 1 {
            json = try (json as NSData).decompressed(using: .zlib) as Data
        }
        return try coder.decoder.decode(T.self, from: json)
    }

    private static let coder: (encoder: JSONEncoder, decoder: JSONDecoder) = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return (encoder, decoder)
    }()
}

extension Data {
    var base64URLEncoded: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URL text: String) {
        var plain = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while plain.count % 4 != 0 {
            plain += "="
        }
        self.init(base64Encoded: plain)
    }
}

// MARK: - What's asked, and answered

/// A request from Agent Buddy Remote.
public struct PhoneRequest: Codable, Equatable, Sendable {
    public enum Op: String, Codable, Sendable {
        /// Every agent window with finished jobs.
        case windows
        /// One agent window's prompts.
        case history
        /// A prompt for an agent window's agent.
        case send
        /// Token statistics for a period, with its jobs.
        case stats
        /// What the agent did in one prompt's turn, step by step.
        case steps
    }

    public var id: String
    public var sentAt: Date
    public var op: Op
    /// An agent window: its key ("agent|server|session"), or its reminders' tag ("hsw-…").
    public var window: String?
    public var prompt: String?
    /// "day", "week" or "month".
    public var period: String?
    /// A prompt in the window, for its steps: its id.
    public var turn: String?

    public init(
        op: Op, window: String? = nil, prompt: String? = nil, period: String? = nil, turn: String? = nil, sentAt: Date = Date()
    ) {
        id = UUID().uuidString
        self.sentAt = Date(timeIntervalSince1970: sentAt.timeIntervalSince1970.rounded(.down))
        self.op = op
        self.window = window
        self.prompt = prompt
        self.period = period
        self.turn = turn
    }
}

/// The Mac's reply: what was asked for, or why not.
public struct PhoneReply: Codable, Equatable, Sendable {
    /// The request's id.
    public var id: String
    public var sentAt: Date
    public var problem: String?
    public var windows: [PhoneWindow]?
    public var history: PhoneHistory?
    public var sent: PhoneSent?
    public var stats: PhoneStats?
    public var steps: [PhoneStep]?

    public init(
        id: String = "", problem: String? = nil, windows: [PhoneWindow]? = nil, history: PhoneHistory? = nil,
        sent: PhoneSent? = nil, stats: PhoneStats? = nil, steps: [PhoneStep]? = nil
    ) {
        self.id = id
        sentAt = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        self.problem = problem
        self.windows = windows
        self.history = history
        self.sent = sent
        self.stats = stats
        self.steps = steps
    }
}

/// One thing the agent did in a turn, as the Mac's agent windows show it after
/// a ●: what it wrote (`said`), a tool it ran (`ran`), a file it changed
/// (`changed`). Encoded as the answer page draws steps.
public struct PhoneStep: Codable, Equatable, Sendable {
    public var kind: String
    /// What it wrote (Markdown); the tool and what on, "Bash(swift build)"; the file changed.
    public var text: String
    /// What came of it, in a line: "Read 120 lines", "1 addition, 1 removal".
    public var outcome: String?
    /// What it printed, for a tap.
    public var output: String?
    public var failed: Bool
    public var hunks: [Hunk]

    /// Part of a change: lines kept (" "), removed ("-") and added ("+"), from
    /// those lines of the old file and the new (0 when not known).
    public struct Hunk: Codable, Equatable, Sendable {
        public var oldStart: Int
        public var newStart: Int
        public var lines: [String]

        public init(oldStart: Int, newStart: Int, lines: [String]) {
            self.oldStart = oldStart
            self.newStart = newStart
            self.lines = lines
        }
    }

    public init(kind: String, text: String, outcome: String?, output: String?, failed: Bool, hunks: [Hunk]) {
        self.kind = kind
        self.text = text
        self.outcome = outcome
        self.output = output
        self.failed = failed
        self.hunks = hunks
    }
}

/// One agent window, as Agent Buddy's list of them has it.
public struct PhoneWindow: Codable, Equatable, Sendable, Identifiable {
    /// "agent|server|session".
    public var key: String
    /// "claude", "codex" or "copilot".
    public var agent: String
    public var title: String
    public var project: String?
    public var server: String?
    public var jobs: Int
    public var lastFinished: Date?
    /// The last job's: "completed", "failed" or "limited".
    public var outcome: String?

    public var id: String { key }

    public init(
        key: String, agent: String, title: String, project: String?, server: String?, jobs: Int, lastFinished: Date?,
        outcome: String?
    ) {
        self.key = key
        self.agent = agent
        self.title = title
        self.project = project
        self.server = server
        self.jobs = jobs
        self.lastFinished = lastFinished
        self.outcome = outcome
    }
}

/// One model's tokens.
public struct PhoneTokens: Codable, Equatable, Sendable, Identifiable {
    public var model: String
    public var input: Int
    public var output: Int
    public var cacheWrite: Int
    public var cacheRead: Int

    public var id: String { model }
    public var total: Int { input + output + cacheWrite + cacheRead }

    public init(model: String, input: Int, output: Int, cacheWrite: Int, cacheRead: Int) {
        self.model = model
        self.input = input
        self.output = output
        self.cacheWrite = cacheWrite
        self.cacheRead = cacheRead
    }
}

/// An agent window's prompts, laid out as the Mac's history window draws them.
public struct PhoneHistory: Codable, Equatable, Sendable {
    public var key: String
    public var agent: String
    public var title: String
    /// "Claude Code · head_show · on gpu · main · 330M tokens".
    public var facts: String
    /// In the order drawn: the line to the latest prompt down the left, branches indented.
    public var rows: [Row]
    /// The prompt asked last.
    public var latest: String?
    /// The agent is at work in the session now.
    public var working: Bool
    /// Whether a prompt can be sent now, and how it would go, or why it can't.
    public var canSend: Bool
    public var sendNote: String

    public struct Row: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var text: String
        public var askedAt: Date
        /// The agent's last message in the turn, whole.
        public var answer: String?
        public var endedAt: Date?
        /// "completed", "failed", "limited", "interrupted", "running" or "open".
        public var outcome: String
        public var tokens: [PhoneTokens]
        public var depth: Int
        public var current: Bool
        public var branchStart: Bool
        public var lineAbove: Bool
        public var lineBelow: Bool
        public var guides: [Int]
        /// Sent on its own (from Agent Buddy), not in the session's own window.
        public var separate: Bool
        /// Agent Buddy reminded you when it finished.
        public var reminded: Bool

        public init(
            id: String, text: String, askedAt: Date, answer: String?, endedAt: Date?, outcome: String, tokens: [PhoneTokens],
            depth: Int, current: Bool, branchStart: Bool, lineAbove: Bool, lineBelow: Bool, guides: [Int], separate: Bool,
            reminded: Bool
        ) {
            self.id = id
            self.text = text
            self.askedAt = askedAt
            self.answer = answer
            self.endedAt = endedAt
            self.outcome = outcome
            self.tokens = tokens
            self.depth = depth
            self.current = current
            self.branchStart = branchStart
            self.lineAbove = lineAbove
            self.lineBelow = lineBelow
            self.guides = guides
            self.separate = separate
            self.reminded = reminded
        }

        public var total: Int { tokens.reduce(0) { $0 + $1.total } }
    }

    public init(
        key: String, agent: String, title: String, facts: String, rows: [Row], latest: String?, working: Bool, canSend: Bool,
        sendNote: String
    ) {
        self.key = key
        self.agent = agent
        self.title = title
        self.facts = facts
        self.rows = rows
        self.latest = latest
        self.working = working
        self.canSend = canSend
        self.sendNote = sendNote
    }
}

/// A prompt the Mac sent on.
public struct PhoneSent: Codable, Equatable, Sendable {
    public var at: Date
    /// "Claude Code is working on it on this Mac, in auto mode."
    public var note: String

    public init(at: Date, note: String) {
        self.at = at
        self.note = note
    }
}

/// Token statistics for a period, as the Mac's Token usage page shows them.
public struct PhoneStats: Codable, Equatable, Sendable {
    /// "day", "week" or "month".
    public var period: String
    public var start: Date
    public var end: Date
    /// Calendar days covered, for a per-day average.
    public var days: Int
    public var total: PhoneTokens
    /// By agent ("claude", "codex", "copilot").
    public var byAgent: [String: PhoneTokens]
    /// By where they were used: "" for the Mac, else the server.
    public var bySource: [String: PhoneTokens]
    /// By model, the most used first.
    public var models: [Model]
    /// Today by the hour, or each day.
    public var bars: [Bar]
    /// Each job of the period, newest first.
    public var jobs: [PhoneJob]
    /// Whether the jobs were still being counted.
    public var jobsPending: Bool

    public struct Model: Codable, Equatable, Sendable, Identifiable {
        public var agent: String
        public var tokens: PhoneTokens
        public var id: String { "\(agent):\(tokens.model)" }

        public init(agent: String, tokens: PhoneTokens) {
            self.agent = agent
            self.tokens = tokens
        }
    }

    public struct Bar: Codable, Equatable, Sendable, Identifiable {
        public var start: Date
        public var byAgent: [String: Int]
        public var id: Date { start }
        public var total: Int { byAgent.values.reduce(0, +) }

        public init(start: Date, byAgent: [String: Int]) {
            self.start = start
            self.byAgent = byAgent
        }
    }

    public init(
        period: String, start: Date, end: Date, days: Int, total: PhoneTokens, byAgent: [String: PhoneTokens],
        bySource: [String: PhoneTokens], models: [Model], bars: [Bar], jobs: [PhoneJob], jobsPending: Bool
    ) {
        self.period = period
        self.start = start
        self.end = end
        self.days = days
        self.total = total
        self.byAgent = byAgent
        self.bySource = bySource
        self.models = models
        self.bars = bars
        self.jobs = jobs
        self.jobsPending = jobsPending
    }
}

/// One job (a prompt and the agent's work on it) and its tokens.
public struct PhoneJob: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    /// Its agent window's key, to open it.
    public var window: String
    /// The prompt's id in that window's history.
    public var turn: String?
    public var agent: String
    public var server: String?
    public var title: String?
    public var project: String?
    public var prompt: String
    public var at: Date
    public var outcome: String
    public var tokens: [PhoneTokens]
    /// Copilot counts tokens per session, not per job.
    public var wholeSession: Bool

    public var total: Int { tokens.reduce(0) { $0 + $1.total } }

    public init(
        id: String, window: String, turn: String?, agent: String, server: String?, title: String?, project: String?,
        prompt: String, at: Date, outcome: String, tokens: [PhoneTokens], wholeSession: Bool
    ) {
        self.id = id
        self.window = window
        self.turn = turn
        self.agent = agent
        self.server = server
        self.title = title
        self.project = project
        self.prompt = prompt
        self.at = at
        self.outcome = outcome
        self.tokens = tokens
        self.wholeSession = wholeSession
    }
}

// MARK: - The two ends

/// Agent Buddy Remote's end: seals a request, posts it, and waits for the
/// Mac's sealed reply to it.
public struct RemoteAsker: Sendable {
    public enum Failure: LocalizedError, Equatable {
        case notPaired
        case noAnswer

        public var errorDescription: String? {
            switch self {
            case .notPaired:
                return "Pair again to open jobs and statistics here: scan the code under “Set up iPhone and Apple Watch” in Agent Buddy’s Settings on your Mac."
            case .noAnswer:
                return "Your Mac didn't answer. It may be asleep, or Agent Buddy isn't running."
            }
        }
    }

    public var client: NtfyClient

    public init(client: NtfyClient) {
        self.client = client
    }

    public func ask(_ request: PhoneRequest, timeout: TimeInterval = 60) async throws -> PhoneReply {
        let pairing = client.pairing
        guard pairing.key != nil else { throw Failure.notPaired }
        try await client.publishSealed(Sealed.seal(request, pairing: pairing, .request), topic: pairing.commandTopic)
        let client = self.client
        // From just before it was asked: a reply that came before the stream opened counts too.
        let since = String(Int(request.sentAt.timeIntervalSince1970) - 2)
        return try await withThrowingTaskGroup(of: PhoneReply?.self) { group in
            group.addTask {
                while !Task.isCancelled {
                    do {
                        for try await message in client.stream(topic: pairing.replyTopic, since: since) {
                            guard let bytes = try? await client.sealedBytes(message),
                                  let reply = try? Sealed.open(bytes, pairing: pairing, .reply, as: PhoneReply.self),
                                  reply.id == request.id
                            else { continue }
                            return reply
                        }
                    } catch {
                        // The connection dropped: open it again shortly.
                    }
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                }
                return nil
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            let first = try await group.next() ?? nil
            group.cancelAll()
            guard let reply = first else { throw Failure.noAnswer }
            return reply
        }
    }
}

/// The Mac's end: listens on the request topic, opens each request with the
/// key, drops stale and repeated ones, and posts the handler's sealed reply.
public final class RemoteResponder: @unchecked Sendable {
    public typealias Handler = @Sendable (PhoneRequest) async -> PhoneReply

    private let client: NtfyClient
    private let handler: Handler
    private let log: @Sendable (String) -> Void
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var seen: [String: Date] = [:]
    /// A request older than this (or this far ahead, by a wrong clock) is dropped.
    public static let freshFor: TimeInterval = 300

    public init(client: NtfyClient, log: @escaping @Sendable (String) -> Void = { _ in }, handler: @escaping Handler) {
        self.client = client
        self.handler = handler
        self.log = log
    }

    public var pairing: Pairing { client.pairing }

    public func start() {
        lock.lock()
        defer { lock.unlock() }
        guard task == nil else { return }
        task = Task { [weak self] in await self?.run() }
    }

    public func stop() {
        lock.lock()
        task?.cancel()
        task = nil
        lock.unlock()
    }

    private func run() async {
        // Requests sent in the last two minutes, then each new one.
        var since = "2m"
        var wait: UInt64 = 2
        while !Task.isCancelled {
            do {
                for try await message in client.stream(topic: client.pairing.commandTopic, since: since) {
                    since = message.id
                    wait = 2
                    Task { [weak self] in await self?.handle(message) }
                }
            } catch {
                if !Task.isCancelled {
                    log("Agent Buddy Remote: listening stopped (\(error.localizedDescription)); again in \(wait) s")
                }
            }
            try? await Task.sleep(nanoseconds: wait * 1_000_000_000)
            wait = min(wait * 2, 60)
        }
    }

    private func handle(_ message: NtfyMessage) async {
        let pairing = client.pairing
        guard let bytes = try? await client.sealedBytes(message) else { return }
        guard let request = try? Sealed.open(bytes, pairing: pairing, .request, as: PhoneRequest.self) else {
            log("Agent Buddy Remote: a request that isn't sealed with this pairing's key was ignored")
            return
        }
        guard abs(request.sentAt.timeIntervalSinceNow) < Self.freshFor, firstTime(request.id) else { return }
        var reply = await handler(request)
        reply.id = request.id
        reply.sentAt = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        do {
            try await client.publishSealed(Sealed.seal(reply, pairing: pairing, .reply), topic: pairing.replyTopic)
        } catch {
            log("Agent Buddy Remote: couldn't reply (\(error.localizedDescription))")
        }
    }

    /// Whether this request is new; each is answered once.
    private func firstTime(_ id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        seen = seen.filter { now.timeIntervalSince($0.value) < Self.freshFor * 2 }
        guard seen[id] == nil else { return false }
        seen[id] = now
        return true
    }
}
