import AppKit
import AgentBuddyCore
import AgentBuddyRemoteKit
import Combine

/// Answers Agent Buddy Remote on the iPhone: the list of agent windows, one's
/// prompts, the token statistics, and a prompt to send. Requests come sealed
/// with the pairing's key, so only the phone that scanned the pairing code can
/// ask, and the replies go sealed too. Sending prompts has a switch of its own,
/// off unless you turn it on.
@MainActor
final class RemoteControl {
    private let settings: AppSettings
    private weak var model: AppModel?
    private var responder: RemoteResponder?
    private var subscriptions: Set<AnyCancellable> = []
    /// Prompts sent for the phone, watched to their end.
    private var sends: [(started: PromptSender.Started, key: String, title: String)] = []
    private var sendTimer: Timer?
    private var checkingSends = false
    /// For the subscription to the request topic, which stays open.
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 90
        configuration.timeoutIntervalForResource = 7 * 86400
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    init(settings: AppSettings, model: AppModel) {
        self.settings = settings
        self.model = model
    }

    func start() {
        settings.objectWillChange
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] _ in Task { @MainActor in self?.update() } }
            .store(in: &subscriptions)
        // After sleep the connection may be gone without a word: open it again.
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in Task { @MainActor in self?.restart() } }
            .store(in: &subscriptions)
        update()
    }

    /// Listens while sending to the phone is on, with a key, and the phone may ask.
    private func update() {
        let wanted = settings.remoteBrowse ? settings.phonePairing.flatMap { $0.key == nil ? nil : $0 } : nil
        guard wanted != responder?.pairing else { return }
        responder?.stop()
        responder = nil
        guard let pairing = wanted else { return }
        let responder = RemoteResponder(
            client: NtfyClient(pairing: pairing, session: session), log: { line in Diagnostics.log(line) }
        ) { [weak self] request in
            guard let self else { return PhoneReply(problem: "Agent Buddy is quitting.") }
            return await self.answer(request)
        }
        responder.start()
        self.responder = responder
        Diagnostics.log("Agent Buddy Remote: listening for requests")
    }

    private func restart() {
        responder?.stop()
        responder = nil
        update()
    }

    // MARK: - Answers

    func answer(_ request: PhoneRequest) async -> PhoneReply {
        // The reply is one more message on the server.
        model?.phone.noteSent()
        Diagnostics.log("Agent Buddy Remote asked for \(request.op.rawValue)")
        switch request.op {
        case .windows: return PhoneReply(windows: windows())
        case .history: return await history(request.window)
        case .send: return await send(request)
        case .stats: return await stats(request.period)
        case .steps: return await steps(request.window, turn: request.turn)
        }
    }

    private func windows() -> [PhoneWindow] {
        guard let model else { return [] }
        return model.archive.entries.sorted { $0.lastFinished > $1.lastFinished }.prefix(150).map { entry in
            PhoneWindow(
                key: entry.key, agent: entry.agent.rawValue, title: entry.title ?? entry.project ?? entry.agent.clientName,
                project: entry.project, server: entry.source, jobs: entry.jobs.count,
                lastFinished: entry.jobs.isEmpty ? nil : entry.lastFinished, outcome: entry.lastOutcome.rawValue)
        }
    }

    private struct Window {
        var key: String
        var agent: Agent
        var host: String?
        var sessionID: String
    }

    /// A window's key, from its key or from its reminders' tag ("hsw-…").
    private func resolve(_ window: String?) -> String? {
        guard let window, let model else { return nil }
        guard window.hasPrefix("hsw-") else { return window }
        let keys = model.archive.entries.map(\.key) + model.jobWindows.map(\.key)
        return keys.first { ReminderTag.window($0) == window }
    }

    private func parse(_ key: String) -> Window? {
        let parts = key.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, let agent = Agent(rawValue: parts[0]), !parts[2].isEmpty else { return nil }
        return Window(key: key, agent: agent, host: parts[1].isEmpty ? nil : parts[1], sessionID: parts[2])
    }

    /// A window's session, read here or over SSH, as its history window reads it.
    private func load(_ key: String) async -> Result<(Window, SessionHistory, WindowInfo), ReadError> {
        guard let window = parse(key), let model else {
            return .failure(ReadError("Agent Buddy on your Mac doesn't know that agent window."))
        }
        let info = model.windowInfo(key)
        let (agent, host, path, session) = (window.agent, window.host, info.path, window.sessionID)
        let result = await Task.detached(priority: .userInitiated) {
            SessionDetails.read(agent: agent, host: host, path: path, sessionID: session).0
        }.value
        switch result {
        case .success(let history):
            model.learn(key, from: history)
            return .success((window, history, info))
        case .failure(let error):
            return .failure(error)
        }
    }

    private func history(_ window: String?) async -> PhoneReply {
        guard let key = resolve(window) else {
            return PhoneReply(problem: "Agent Buddy on your Mac doesn't know that agent window anymore.")
        }
        switch await load(key) {
        case .failure(let error):
            return PhoneReply(problem: error.message)
        case .success(let (window, history, info)):
            let reminded = SessionDetails.remindedTurns(history, finished: info.finished)
            let rows = history.rows.map { row in
                PhoneHistory.Row(
                    id: row.id, text: row.turn.text, askedAt: row.turn.askedAt, answer: row.turn.answer, endedAt: row.turn.endedAt,
                    outcome: row.turn.outcome.rawValue, tokens: row.turn.usage.map(Self.tokens), depth: row.depth, current: row.current,
                    branchStart: row.branchStart, lineAbove: row.lineAbove, lineBelow: row.lineBelow, guides: row.guides,
                    separate: row.turn.separate, reminded: reminded.contains(row.id))
            }
            let (canSend, note) = sendability(window, history)
            return PhoneReply(history: PhoneHistory(
                key: window.key, agent: window.agent.rawValue, title: SessionDetails.title(agent: window.agent, history: history, info: info),
                facts: SessionDetails.facts(agent: window.agent, host: window.host, history: history, info: info), rows: rows,
                latest: history.turns.max { $0.askedAt < $1.askedAt }?.id, working: isWorking(window.key), canSend: canSend,
                sendNote: note))
        }
    }

    /// What the agent did in one of a window's turns, read as its agent window reads it.
    private func steps(_ window: String?, turn id: String?) async -> PhoneReply {
        guard let key = resolve(window), let id else {
            return PhoneReply(problem: "Agent Buddy on your Mac doesn't know that agent window anymore.")
        }
        switch await load(key) {
        case .failure(let error):
            return PhoneReply(problem: error.message)
        case .success(let (window, history, info)):
            guard let turn = history.turns.first(where: { $0.id == id }) else {
                return PhoneReply(problem: "That prompt isn't in the session anymore.")
            }
            let (agent, host, path, session, cwd) = (window.agent, window.host, history.logPath ?? info.path, window.sessionID, history.cwd)
            let read = await Task.detached(priority: .userInitiated) { () -> Result<[TurnStep], ReadError> in
                if let host {
                    return RemoteHistory.steps(host: host, agent: agent, path: path, sessionID: session, turn: turn, cwd: cwd)
                }
                guard let path, let steps = SessionHistoryReader.steps(agent: agent, path: path, turn: turn, cwd: cwd) else {
                    return .failure(ReadError("The session's log isn't on your Mac anymore."))
                }
                return .success(steps)
            }.value
            switch read {
            case .failure(let error):
                return PhoneReply(problem: error.message)
            case .success(let steps):
                return PhoneReply(steps: steps.map { step in
                    PhoneStep(kind: step.kind.rawValue, text: step.text, outcome: step.outcome, output: step.output, failed: step.failed,
                              hunks: step.hunks.map { PhoneStep.Hunk(oldStart: $0.oldStart, newStart: $0.newStart, lines: $0.lines) })
                })
            }
        }
    }

    private func isWorking(_ key: String) -> Bool {
        model?.working.contains { $0.id == key } ?? false
    }

    /// Whether a prompt can go now, and how it would, or why it can't.
    private func sendability(_ window: Window, _ history: SessionHistory) -> (Bool, String) {
        let client = window.agent.clientName
        guard settings.remoteSend else {
            return (false, "To send prompts from here, turn on “Let it send prompts” under Settings › iPhone › Agent Buddy Remote in Agent Buddy on your Mac.")
        }
        if history.isSubagent {
            return (false, "This is a sub-agent's thread: send to the session that started it.")
        }
        switch PromptSender.plan(PromptSender.Request(history: history, host: window.host, prompt: "…")) {
        case .failure(let problem):
            return (false, problem.message)
        case .success(let plan):
            if SessionKeeper.shared.isKept(window.key) {
                return SessionKeeper.shared.phases[window.key] == .ready
                    ? (true, "Goes into the session kept open on your Mac, in the background, \(plan.permissions); \(plan.asks).")
                    : (false, "\(client) is working on the last prompt in the session kept open on your Mac. You can send when it's done.")
            }
            if let holder = history.openElsewhere {
                return (false, "\(holder) has this thread open\(window.host.map { " on \($0)" } ?? ""), and Codex lets one program at a time write to a thread. \(SessionKeeper.howToFree(holder)) Then send from here.")
            }
            if isWorking(window.key) {
                return (false, "\(client) is working on this session now. You can send when it's done.")
            }
            var note = "Sends it to \(client) \(window.host.map { "on \($0)" } ?? "on your Mac") \(plan.permissions), as if you resumed the session; \(plan.asks)."
            if let narrowed = plan.narrowed {
                note += " " + narrowed
            }
            note += " If the session is still open in its app, that app won't show this exchange."
            return (true, note)
        }
    }

    private func send(_ request: PhoneRequest) async -> PhoneReply {
        guard settings.remoteSend else {
            return PhoneReply(problem: "Sending prompts from Agent Buddy Remote is off. Turn on “Let it send prompts” under Settings › iPhone › Agent Buddy Remote in Agent Buddy on your Mac.")
        }
        let prompt = (request.prompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return PhoneReply(problem: "The prompt is empty.") }
        guard let key = resolve(request.window) else {
            return PhoneReply(problem: "Agent Buddy on your Mac doesn't know that agent window anymore.")
        }
        switch await load(key) {
        case .failure(let error):
            return PhoneReply(problem: error.message)
        case .success(let (window, history, info)):
            let (canSend, note) = sendability(window, history)
            guard canSend else { return PhoneReply(problem: note) }
            let client = window.agent.clientName
            let title = SessionDetails.title(agent: window.agent, history: history, info: info)
            if SessionKeeper.shared.isKept(key) {
                // Into the session kept open on the Mac, as the window's box sends.
                if case .failure(let problem) = SessionKeeper.shared.send(key, prompt) {
                    return PhoneReply(problem: problem.message)
                }
                Diagnostics.log("Agent Buddy Remote sent a prompt into \(key), kept open here")
                model?.notifier.postStatus(
                    id: "remote-sent-\(UUID().uuidString)", title: "Prompt sent from your iPhone",
                    body: "\(client) · \(title): \u{201C}\(prompt.prefix(140))\u{201D}")
                return PhoneReply(sent: PhoneSent(
                    at: Date(), note: "Sent into the session kept open on your Mac. Agent Buddy reminds you when it's done."))
            }
            let sending = PromptSender.Request(history: history, host: window.host, prompt: prompt)
            let result = await Task.detached(priority: .userInitiated) { PromptSender.start(sending) }.value
            switch result {
            case .failure(let problem):
                Diagnostics.log("Agent Buddy Remote's prompt for \(key) wasn't sent: \(problem.message)")
                return PhoneReply(problem: problem.message)
            case .success(let started):
                Diagnostics.log("Agent Buddy Remote sent a prompt to \(key), pid \(started.pid), its output in \(started.log)")
                // Said on the Mac too, so a prompt from the phone is never a surprise.
                model?.notifier.postStatus(
                    id: "remote-sent-\(started.pid)", title: "Prompt sent from your iPhone",
                    body: "\(client) · \(title): \u{201C}\(prompt.prefix(140))\u{201D}")
                watch(started, key: key, title: title)
                let how = (try? PromptSender.plan(sending).get()).map { " " + $0.permissions } ?? ""
                return PhoneReply(sent: PhoneSent(
                    at: Date(),
                    note: "Sent. \(client) is working on it \(window.host.map { "on \($0)" } ?? "on your Mac")\(how). Agent Buddy reminds you when it's done."))
            }
        }
    }

    // MARK: - Sends, to their end

    private func watch(_ started: PromptSender.Started, key: String, title: String) {
        sends.append((started, key, title))
        guard sendTimer == nil else { return }
        sendTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkSends() }
        }
    }

    private func checkSends() {
        guard !sends.isEmpty else {
            sendTimer?.invalidate()
            sendTimer = nil
            return
        }
        guard !checkingSends else { return }
        checkingSends = true
        let pending = sends.map(\.started)
        Task.detached(priority: .utility) { [weak self] in
            var ended: [(PromptSender.Started, PromptSender.Status)] = []
            for started in pending {
                if let status = PromptSender.status(started), status != .running {
                    ended.append((started, status))
                }
            }
            await self?.ended(ended)
        }
    }

    private func ended(_ ended: [(PromptSender.Started, PromptSender.Status)]) {
        checkingSends = false
        for (started, status) in ended {
            guard let index = sends.firstIndex(where: { $0.started == started }) else { continue }
            let send = sends.remove(at: index)
            if case .failed(let why) = status {
                Diagnostics.log("the prompt Agent Buddy Remote sent to \(send.key) ended: \(why)")
                // Finished, the usual reminder comes; stopped, this one does, on the phone too.
                model?.notifier.post(
                    id: "remote-failed-\(started.pid)", title: "The prompt from your iPhone stopped", body: "\(send.title): \(why)",
                    agent: parse(send.key)?.agent)
            } else {
                Diagnostics.log("the prompt Agent Buddy Remote sent to \(send.key) finished")
            }
        }
    }

    // MARK: - Statistics

    private func stats(_ name: String?) async -> PhoneReply {
        guard let model else { return PhoneReply(problem: "Agent Buddy is quitting.") }
        let period = StatsPeriod(rawValue: name ?? "") ?? .day
        if model.tokenEntries == nil, !model.countingTokens {
            model.refreshTokens()
        }
        if model.jobUsage.isEmpty, !model.jobUsage.loading {
            model.jobUsage.refresh(archive: model.archive)
        }
        // The first count can take a while.
        for _ in 0..<60 where model.tokenEntries == nil {
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        guard let entries = model.tokenEntries else {
            return PhoneReply(problem: "Agent Buddy on your Mac is still counting tokens. Try again in a minute.")
        }
        for _ in 0..<40 where model.jobUsage.loading {
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        let now = Date()
        let summary = TokenStatistics.summary(entries, period: period, now: now)
        let jobs = model.jobUsage.jobs(period, now: now).prefix(300).map { job in
            PhoneJob(
                id: job.id, window: job.windowKey, turn: job.turnID, agent: job.agent.rawValue, server: job.source, title: job.title,
                project: job.project, prompt: job.prompt, at: job.at, outcome: job.outcome?.rawValue ?? "completed",
                tokens: job.usage.map(Self.tokens), wholeSession: job.wholeSession)
        }
        return PhoneReply(stats: PhoneStats(
            period: period.rawValue, start: summary.start, end: summary.end, days: summary.days, total: Self.counts("", summary.total),
            byAgent: Dictionary(uniqueKeysWithValues: summary.byAgent.map { ($0.key.rawValue, Self.counts($0.key.rawValue, $0.value)) }),
            bySource: summary.bySource.mapValues { Self.counts("", $0) },
            models: summary.models.map { PhoneStats.Model(agent: $0.agent.rawValue, tokens: Self.counts($0.model, $0.counts)) },
            bars: summary.bars.map { bar in
                PhoneStats.Bar(start: bar.start, byAgent: Dictionary(uniqueKeysWithValues: bar.byAgent.map { ($0.key.rawValue, $0.value) }))
            },
            jobs: Array(jobs), jobsPending: model.jobUsage.loading))
    }

    static func tokens(_ usage: ModelTokens) -> PhoneTokens {
        counts(usage.model, usage.counts)
    }

    static func counts(_ model: String, _ counts: TokenCounts) -> PhoneTokens {
        PhoneTokens(model: model, input: counts.input, output: counts.output, cacheWrite: counts.cacheWrite, cacheRead: counts.cacheRead)
    }
}
