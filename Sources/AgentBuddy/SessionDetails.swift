import AppKit
import Combine
import AgentBuddyCore
import AgentBuddyMarkdown
import SwiftUI

/// One agent window's details: the prompts asked there as a tree, and where it runs.
@MainActor
final class SessionDetails: ObservableObject {
    let key: String
    let agent: Agent
    /// The server, for a session that ran on one.
    let host: String?
    let sessionID: String
    @Published private(set) var info: WindowInfo
    @Published private(set) var history: SessionHistory?
    /// A read under way, shown: the first, or one that takes a while (a quick
    /// one isn't, or each would redraw the window twice).
    @Published private(set) var loading = false
    /// A read under way.
    private var busy = false
    @Published private(set) var problem: String?
    /// When the log was last read. Not published: the footer looks at it on a
    /// clock of its own, and a read that found nothing new redraws nothing.
    private(set) var loadedAt: Date?
    /// Each read, as it ends (for the self-test).
    let didRead = PassthroughSubject<Date, Never>()
    @Published private(set) var place: PlaceResult?
    @Published private(set) var jumping = false
    @Published private(set) var jumpProblem: String?
    /// A prompt to show open, from Token usage ▸ By job: let go of once shown.
    @Published var focus: String?
    /// Kept above other windows.
    @Published private(set) var pinned = false
    /// The window, told when it's pinned or let go.
    var onPin: ((Bool) -> Void)?
    @Published private(set) var now = Date()
    private var path: String?
    private var modified: Date?
    /// The log as read last: one that grew is read on from there, not from the start.
    private let reading = SessionLogReading()
    /// The turns shown open, as read last: one at work is read on from there.
    private let stepsReading = StepsReading()
    /// What the last look for where it runs went by.
    private var placeAsked: PlaceFinder.Request?
    private var timer: Timer?
    private var ticks = 0
    /// Asked to read again while a read was under way: it may have missed the news.
    private var again = false

    /// What the agent did in each turn shown open, step by step: read when it's
    /// opened, and again with the history while it runs.
    @Published private(set) var steps: [String: TurnSteps] = [:]
    /// The turns shown open, those being read, and those read after they ended (they won't change).
    private var shownSteps: Set<String> = []
    private var readingSteps: Set<String> = []
    private var settledSteps: Set<String> = []

    struct TurnSteps: Equatable {
        var steps: [TurnStep]
        /// As the window's web view takes them.
        var json: String
    }
    /// Each time the log is read: the archive keeps the window's name and log.
    var onLearned: ((String, SessionHistory) -> Void)?

    /// What you're writing to the agent, and how sending it goes. The text is
    /// watched by the message box alone: typing doesn't redraw the history above it.
    let composing = MessageDraft()
    /// Searching its prompts and answers (⌘F).
    let search = HistorySearch()
    var draft: String {
        get { composing.text }
        set { composing.text = newValue }
    }
    @Published private(set) var starting = false
    @Published private(set) var sending: PromptSender.Started?
    /// A prompt sent into the session kept open here ("Move here"): since when, until its turn ends.
    @Published private(set) var keptSince: Date?
    /// The kept session's phase, followed.
    private var keeping: AnyCancellable?
    @Published private(set) var sent: SendResult?
    /// A prompt just sent from here, shown where it goes until the session's log has it.
    @Published private(set) var pending: PendingPrompt?
    /// Whether the session's agent is at work now, as the watcher sees it.
    var isWorking: () -> Bool = { false }
    /// Whether any of the window shows.
    var isInSight: () -> Bool = { true }
    /// Out of sight, a look was skipped.
    private var missed = false
    private var stopping = false

    /// Prompts sent while one was under way: each goes as the one before ends,
    /// as Claude Code and Codex queue what's typed while they work.
    @Published private(set) var queued: [QueuedPrompt] = []

    struct QueuedPrompt: Identifiable, Equatable {
        let id = UUID()
        /// As it'll be sent: with the selection that went with it, and the box's choices then.
        var request: PromptSender.Request
        /// As typed: shown, and given back to the box.
        var typed: String
        var files: [URL]
        var attached: String?
        /// Codex, kept open here: being added to the answer under way.
        var joining = false

        static func == (a: QueuedPrompt, b: QueuedPrompt) -> Bool {
            a.id == b.id && a.joining == b.joining
        }
    }

    struct PendingPrompt: Equatable {
        var text: String
        var at: Date
        /// The selection that went with it: "main.rs, lines 10–12".
        var attached: String?
    }

    enum SendResult: Equatable {
        case notSent(String)
        case finished(Date)
        case failed(String)
    }

    /// Nil for a key that isn't an agent window's ("agent|server|session").
    init?(key: String, info: WindowInfo) {
        let parts = key.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, let agent = Agent(rawValue: parts[0]), !parts[2].isEmpty else { return nil }
        self.key = key
        self.agent = agent
        host = parts[1].isEmpty ? nil : parts[1]
        sessionID = parts[2]
        self.info = info
        path = info.path
    }

    /// For the snapshot mode: a history given, nothing read.
    init(preview history: SessionHistory, info: WindowInfo, host: String?, place: PlaceResult) {
        key = "\(history.agent.rawValue)|\(host ?? "")|\(history.sessionID)"
        agent = history.agent
        self.host = host
        sessionID = history.sessionID
        self.info = info
        self.history = history
        self.place = place
        loadedAt = Date()
    }

    var title: String {
        Self.title(agent: agent, history: history, info: info)
    }

    var facts: String {
        Self.facts(agent: agent, host: host, history: history, info: info)
    }

    /// The session's name, else its first prompt's first line, else the agent's.
    static func title(agent: Agent, history: SessionHistory?, info: WindowInfo) -> String {
        history?.title ?? info.title
            ?? history?.turns.first.map { String(($0.text.split(separator: "\n").first ?? "").prefix(80)) }
            ?? agent.clientName
    }

    /// "Claude Code · head_show · on gpu · main · 3 finished jobs · 330M tokens".
    static func facts(agent: Agent, host: String?, history: SessionHistory?, info: WindowInfo) -> String {
        var parts = [agent.clientName]
        if let folder = history?.cwd ?? info.project.map({ "/" + $0 }) {
            parts.append(URL(fileURLWithPath: folder).lastPathComponent)
        }
        if let host {
            parts.append("on \(host)")
        }
        if let branch = history?.gitBranch, !branch.isEmpty, branch != "HEAD" {
            parts.append(branch)
        }
        if !info.finished.isEmpty {
            parts.append(info.finished.count == 1 ? "1 finished job" : "\(info.finished.count) finished jobs")
        }
        if let tokens = history?.sessionTokens.total, tokens > 0 {
            let perJob = history?.turns.contains { !$0.usage.isEmpty } ?? false
            parts.append("\(TokenStatistics.compact(tokens)) tokens\(perJob ? "" : " in the session")")
        }
        return parts.joined(separator: " · ")
    }

    /// The prompt asked last.
    var latestID: String? {
        history?.turns.max { $0.askedAt < $1.askedAt }?.id
    }

    /// The prompts whose turn reminded you: each job belongs to the last prompt asked before it finished.
    var remindedTurns: Set<String> {
        Self.remindedTurns(history, finished: info.finished)
    }

    static func remindedTurns(_ history: SessionHistory?, finished: [Date]) -> Set<String> {
        guard let turns = history?.turns.sorted(by: { $0.askedAt < $1.askedAt }), !turns.isEmpty else { return [] }
        var ids = Set<String>()
        for finished in finished {
            if let turn = turns.last(where: { $0.askedAt <= finished.addingTimeInterval(1) }) {
                ids.insert(turn.id)
            }
        }
        return ids
    }

    func update(info: WindowInfo) {
        if info != self.info {
            self.info = info
            path = path ?? info.path
        }
    }

    // MARK: - Loading

    func start() {
        followKept()
        load()
        timer?.invalidate()
        // Each window at its own moment in the five seconds: many open at once
        // don't all look (and redraw) together.
        Self.opened += 1
        let tick = Timer(fire: Date().addingTimeInterval(5 + Double(Self.opened % 10) * 0.5), interval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        tick.tolerance = 0.25
        RunLoop.main.add(tick, forMode: .default)
        timer = tick
    }

    /// Windows opened so far, for their clocks' moments.
    private static var opened = 0

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Reads the history again: the local log at once (on from where it was
    /// last read, unless `whole`), a server's over SSH.
    func load(whole: Bool = false) {
        if whole {
            reading.forget()
            stepsReading.forget()
        }
        guard !busy else {
            again = true
            return
        }
        busy = true
        if history == nil {
            loading = true
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                if let self, self.busy, !self.loading {
                    self.loading = true
                }
            }
        }
        let (agent, host, path, sessionID, reading) = (self.agent, self.host, self.path, self.sessionID, self.reading)
        // The turns shown open and still going, read with it (a log here): what
        // the read brings shows at once, in one redraw.
        let open = host != nil || agent == .copilot ? [] : shownSteps.subtracting(settledSteps).subtracting(readingSteps)
        readingSteps.formUnion(open)
        let stepsReading = self.stepsReading
        Task.detached(priority: .userInitiated) { [weak self] in
            let (result, modified) = Self.read(agent: agent, host: host, path: path, sessionID: sessionID, reading: reading)
            var steps: [(id: String, steps: TurnSteps?, ended: Bool)] = []
            if case .success(let history) = result {
                for id in open {
                    guard let turn = history.turns.first(where: { $0.id == id }) else { continue }
                    let read = Self.turnSteps(agent: agent, host: nil, path: history.logPath ?? path, sessionID: sessionID, turn: turn,
                                              cwd: history.cwd, reading: stepsReading)
                    steps.append((id, read, turn.endedAt != nil))
                }
            }
            await self?.finish(result, modified: modified, steps: steps, asked: open)
        }
    }

    /// Blocking: a session's history, from its log here or over SSH from the
    /// server; with the log's modification time, for one here.
    /// - Parameter reading: the log here as read before, to read on from there.
    nonisolated static func read(
        agent: Agent, host: String?, path: String?, sessionID: String, reading: SessionLogReading? = nil
    ) -> (Result<SessionHistory, ReadError>, Date?) {
        if let host {
            // Without a recorded path, the server looks for the session by its id.
            return (RemoteHistory.fetch(host: host, agent: agent, path: path, sessionID: sessionID), nil)
        }
        guard let file = path ?? SessionHistoryReader.locate(agent: agent, sessionID: sessionID) else {
            return (.failure(ReadError("Agent Buddy can't find this session's log on this Mac.")), nil)
        }
        let modified = (try? FileManager.default.attributesOfItem(atPath: file))?[.modificationDate] as? Date
        var read = SessionHistoryReader.read(agent: agent, path: file, reading: reading)
        // A Codex thread another program has open: Codex refuses a second writer.
        if agent == .codex, case .success(var history) = read {
            history.openElsewhere = CodexWriter.holder(thread: history.sessionID)
            read = .success(history)
        }
        return (read, modified)
    }

    private func finish(
        _ result: Result<SessionHistory, ReadError>, modified: Date?, steps read: [(id: String, steps: TurnSteps?, ended: Bool)] = [],
        asked: Set<String> = []
    ) {
        busy = false
        if loading {
            loading = false
        }
        let now = Date()
        loadedAt = now
        didRead.send(now)
        self.modified = modified ?? self.modified
        switch result {
        case .success(let history):
            // Unchanged, it's left alone: nothing on screen redraws for nothing.
            if self.history != history {
                self.history = history
            }
            readingSteps.subtract(asked)
            for turn in read {
                gotSteps(turn.id, turn.steps, ended: turn.ended)
            }
            if problem != nil {
                problem = nil
            }
            path = path ?? history.logPath
            onLearned?(key, history)
            // Read: connected at once, if Settings asks for it.
            connectIfWanted()
            // The log has the prompt sent from here: it shows as itself now.
            if let pending, Self.recorded(pending, in: history) {
                self.pending = nil
            }
        case .failure(let error):
            readingSteps.subtract(asked)
            if problem != error.message {
                problem = error.message
            }
        }
        // Again only if what it's found by changed (the clock looks every few seconds anyway).
        if placeRequest != placeAsked {
            findPlace()
        }
        // A turn shown open that's still going, not read with it: its steps again.
        for id in shownSteps where !settledSteps.contains(id) && !read.contains(where: { $0.id == id }) {
            readSteps(id)
        }
        if again {
            again = false
            load()
        }
    }

    // MARK: - A turn's steps

    /// A turn shown open: its steps are read, and kept up while it runs.
    func showSteps(_ id: String) {
        shownSteps.insert(id)
        readSteps(id)
    }

    func hideSteps(_ id: String) {
        shownSteps.remove(id)
    }

    private func readSteps(_ id: String) {
        guard agent != .copilot, !readingSteps.contains(id), !settledSteps.contains(id),
              let turn = history?.turns.first(where: { $0.id == id })
        else { return }
        readingSteps.insert(id)
        let ended = turn.endedAt != nil
        let (agent, host, path, sessionID, cwd, reading) = (self.agent, self.host, self.path, self.sessionID, history?.cwd, stepsReading)
        Task.detached(priority: .userInitiated) { [weak self] in
            let read = Self.turnSteps(agent: agent, host: host, path: path, sessionID: sessionID, turn: turn, cwd: cwd, reading: reading)
            await self?.gotSteps(id, read, ended: ended)
        }
    }

    /// Blocking: a turn's steps, from the log here (read on from where it was) or the server's.
    nonisolated private static func turnSteps(
        agent: Agent, host: String?, path: String?, sessionID: String, turn: PromptTurn, cwd: String?, reading: StepsReading
    ) -> TurnSteps? {
        var read: [TurnStep]?
        if let host {
            read = try? RemoteHistory.steps(host: host, agent: agent, path: path, sessionID: sessionID, turn: turn, cwd: cwd).get()
        } else if let path {
            read = SessionHistoryReader.steps(agent: agent, path: path, turn: turn, cwd: cwd, reading: reading)
        }
        let json = read.flatMap { try? JSONEncoder().encode($0) }.flatMap { String(data: $0, encoding: .utf8) }
        return read.flatMap { steps in json.map { TurnSteps(steps: steps, json: $0) } }
    }

    private func gotSteps(_ id: String, _ read: TurnSteps?, ended: Bool) {
        readingSteps.remove(id)
        guard let read else { return }
        if steps[id] != read {
            steps[id] = read
        }
        if ended {
            settledSteps.insert(id)
        }
    }

    /// Looks again for where it runs, and rereads a local log that grew. A
    /// server's log is read when the app sees the session start or stop working
    /// or finish a job (`SessionDetailsController.refresh`), and every 30 seconds
    /// while it works.
    private func tick() {
        let date = Date()
        // What the window shows of the time goes by days (a prompt's time, "since"):
        // told at midnight, not at each look, which would redraw all of it.
        if !Calendar.current.isDate(date, inSameDayAs: now) {
            now = date
        }
        ticks += 1
        if let pending, date.timeIntervalSince(pending.at) > 15 * 60 {
            self.pending = nil
        }
        // A prompt sent from here is followed even out of sight: its end is told
        // (on a server, over SSH, less often while it's out of sight).
        let inSight = isInSight()
        if sending != nil, host == nil || ticks % (inSight ? 2 : 6) == 0 {
            checkSending()
        }
        // A prompt waiting (for a session at work elsewhere, say): sent once it's
        // free, in sight or not.
        if !queued.isEmpty {
            sendNextQueued()
        }
        connectIfWanted(now: date)
        // Out of sight (covered by other windows, or in the Dock), nothing is
        // read or looked for: many windows open cost what the ones in sight do.
        // It catches up as soon as it shows again.
        guard inSight else {
            missed = true
            return
        }
        missed = false
        look()
    }

    /// The window shows again: what it missed. The one in front at once; others
    /// shown with it each in turn, a moment apart, so many windows coming back
    /// together (Agent Buddy brought forward) don't all redraw at once.
    func cameIntoSight(inFront: Bool) {
        guard missed else { return }
        missed = false
        let turn = inFront ? 0 : Self.catchingUp + 1
        Self.catchingUp += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3 * Double(turn)) { [weak self] in
            Self.catchingUp -= 1
            guard let self else { return }
            if self.host != nil, self.sending != nil || self.isWorking() || self.heldElsewhere != nil {
                self.load()
            }
            self.look()
        }
    }

    /// Windows catching up now.
    private static var catchingUp = 0

    /// Where it runs, and the log again if it grew (or a server's, now and then).
    private func look() {
        findPlace()
        if sending != nil {
            // A server's log is read again now and then, to show the reply coming.
            if host != nil, ticks % 3 == 0 {
                load()
            }
        } else if host != nil, ticks % 6 == 0, isWorking() {
            load()
        } else if host != nil, ticks % 4 == 0, heldElsewhere != nil, !busy {
            // Waiting for the program that has the thread open to let go of it.
            load()
        }
        guard host == nil, !busy, let file = path else { return }
        let changed = (try? FileManager.default.attributesOfItem(atPath: file))?[.modificationDate] as? Date
        if let changed, changed != modified {
            load()
        } else if heldElsewhere != nil, ticks % 2 == 0 {
            load()
        }
    }

    private var placeRequest: PlaceFinder.Request {
        PlaceFinder.Request(
            agent: agent, sessionID: history?.sessionID ?? sessionID, host: host, client: history?.client,
            folders: history?.folders ?? [])
    }

    private func findPlace() {
        let request = placeRequest
        placeAsked = request
        Task.detached(priority: .utility) { [weak self] in
            let result = PlaceFinder.find(request)
            await self?.setPlace(result)
        }
    }

    private func setPlace(_ result: PlaceResult) {
        if place != result {
            place = result
        }
    }

    /// Pinned or let go with the other tabs of its window.
    func showPinned(_ value: Bool) {
        pinned = value
    }

    func togglePin() {
        pinned.toggle()
        onPin?(pinned)
    }

    func jump() {
        guard case .found(let place) = place, !jumping else { return }
        jumping = true
        jumpProblem = nil
        Task {
            jumpProblem = await Jumper.go(place)
            jumping = false
        }
    }

    func revealLog() {
        guard host == nil, let file = path ?? SessionHistoryReader.locate(agent: agent, sessionID: sessionID) else { return }
        // OpenCode's "log" is a session in its database: the database.
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.components(separatedBy: "#")[0])])
    }

    // MARK: - Sending a prompt

    /// The session as it would be resumed with `prompt`.
    /// The session as it would be resumed with `prompt`, as the message box has chosen.
    func sendRequest(_ prompt: String) -> PromptSender.Request? {
        sessionRequest(prompt)?.with(composing.options)
    }

    /// The session as it would be resumed, as it is.
    func sessionRequest(_ prompt: String) -> PromptSender.Request? {
        history.map { PromptSender.Request(history: $0, host: host, prompt: prompt) }
    }

    /// Reads what @ and / offer, here or on the server.
    func loadSuggestions() {
        guard composing.suggestionsRead.map({ Date().timeIntervalSince($0) > 300 }) ?? true else { return }
        composing.suggestionsRead = Date()
        let (agent, host, folder) = (self.agent, self.host, sessionRequest("\u{2026}")?.folder)
        Task.detached(priority: .utility) { [weak self] in
            let files = folder.map { ProjectFiles.list(folder: $0, host: host) }
            let commands = AgentCommands.list(agent: agent, folder: folder, host: host)
            await self?.gotSuggestions(files: try? files?.get(), commands: try? commands.get())
        }
    }

    private func gotSuggestions(files: [String]?, commands: [AgentCommand]?) {
        composing.projectFiles = files ?? composing.projectFiles
        composing.commands = commands ?? composing.commands
        // Typed while they were being read: shown now.
        if composing.suggestions.isShown {
            composing.suggestions.update()
        }
    }

    /// Asks Codex (here, or on the server) which models it has, for the message box's menu.
    func loadModels() {
        guard agent == .codex, composing.codexModels == nil, !composing.askingModels else { return }
        composing.askingModels = true
        let host = self.host
        Task.detached(priority: .utility) { [weak self] in
            let listed = CodexModels.list(host: host)
            await self?.gotModels(listed)
        }
    }

    private func gotModels(_ listed: Result<[CodexModel], ReadError>) {
        composing.askingModels = false
        switch listed {
        case .success(let models): composing.codexModels = models
        case .failure(let problem): composing.modelsProblem = problem.message
        }
    }

    /// How a prompt would be sent, or why none can be.
    var sendPlan: Result<PromptSender.Plan, ReadError>? {
        guard let request = sendRequest("…") else { return nil }
        if history?.isSubagent == true {
            return .failure(ReadError("This is a sub-agent's thread: send to the session that started it."))
        }
        return PromptSender.plan(request)
    }

    var canSend: Bool {
        guard case .success? = sendPlan, free || willQueue else { return false }
        return !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Whether a prompt can go at once: nothing under way from here, and the session free.
    private var free: Bool {
        guard case .success? = sendPlan, !starting, inFlight == nil else { return false }
        if SessionKeeper.shared.isKept(key) {
            // Kept open here: it takes a prompt whenever it's not on one.
            return SessionKeeper.shared.phases[key] == .ready
        }
        return !isWorking() && history?.openElsewhere == nil
    }

    /// Whether what's sent now waits its turn: a prompt is under way (from
    /// here or elsewhere), or others are waiting already.
    var willQueue: Bool {
        guard case .success? = sendPlan else { return false }
        if SessionKeeper.shared.isKept(key) {
            guard let phase = SessionKeeper.shared.phases[key], [.opening, .ready, .working].contains(phase) else { return false }
        } else if history?.openElsewhere != nil {
            return false
        }
        return !free || !queued.isEmpty
    }

    /// Whether what's sent now joins the answer under way: Codex kept open here, at work.
    var joinsTurn: Bool {
        agent == .codex && SessionKeeper.shared.isKept(key) && SessionKeeper.shared.phases[key] == .working && queued.isEmpty
            && (host == nil || composing.files.allSatisfy { PromptSender.isImage($0.path) })
    }

    /// Since when a prompt from here has been under way: sent on its own, or into the session kept open here.
    var inFlight: Date? {
        sending?.at ?? keptSince
    }

    /// A prompt under way, sent from here or typed elsewhere: moving the session
    /// here now would resume it beside that turn, which then answers into a
    /// conversation the kept session can't see.
    var busyForMove: Bool {
        inFlight != nil || isWorking()
    }

    /// Another program with the Codex thread open (not Agent Buddy keeping it).
    var heldElsewhere: String? {
        SessionKeeper.shared.isKept(key) ? nil : history?.openElsewhere
    }

    /// "Move here": the session opened in the background, for the box to send into.
    func moveHere() {
        guard !busyForMove, let request = sendRequest("\u{2026}") else { return }
        SessionKeeper.shared.moveHere(key, request: request)
    }

    /// "Let go", by hand: not connected again by itself until the window opens again.
    func letGo() {
        letGoByHand = true
        SessionKeeper.shared.letGo(key)
    }

    /// Whether this window connects to its session as it opens (Settings).
    var connects: () -> Bool = { false }
    private var letGoByHand = false
    private var lastConnect: Date?
    /// Tries since the last connection that held: a session that can't open isn't tried forever.
    private var failedConnects = 0

    /// Connects the window to its session, as Move here does, if Settings asks
    /// for it: once the window has read the session, while nothing's under way,
    /// never taking a Codex thread another program has open; and again if the
    /// connection drops, at most every 30 seconds.
    func connectIfWanted(now: Date = Date()) {
        guard connects(), !letGoByHand, agent == .claude || agent == .codex, history != nil,
              history?.isSubagent != true, case .success? = sendPlan else { return }
        switch SessionKeeper.shared.phases[key] {
        case .ready?, .working?, .opening?, .waiting?:
            failedConnects = 0
            return
        case .failed?, nil:
            break
        }
        guard !busyForMove, heldElsewhere == nil, failedConnects < 3,
              lastConnect.map({ now.timeIntervalSince($0) >= 30 }) ?? true else { return }
        if SessionKeeper.shared.phases[key] != nil {
            failedConnects += 1
        }
        lastConnect = now
        Diagnostics.log("keep: connecting \(key) as its window opened")
        moveHere()
    }

    /// "Move here from VS Code": the thread taken from the program holding it (after asking), then moved here.
    func takeOver() {
        guard let request = sendRequest("\u{2026}") else { return }
        SessionKeeper.shared.takeOver(key, request: request)
    }

    private func followKept() {
        keeping = SessionKeeper.shared.$phases.map { [key] in $0[key] }.removeDuplicates().sink { [weak self] phase in
            DispatchQueue.main.async { self?.keptPhase(phase) }
        }
    }

    /// The kept session's turn ended (or the session did): how it went, and the log again.
    private func keptPhase(_ phase: SessionKeeper.Phase?) {
        guard keptSince != nil, phase != .working else { return }
        keptSince = nil
        if case .failed(let why)? = phase {
            sent = .failed(why)
        } else if phase == nil {
            sent = .failed("Let go before it finished.")
        } else if let problem = SessionKeeper.shared.problems[key] {
            sent = .failed(stopping ? "Stopped." : CodexWriter.plain(problem))
        } else {
            sent = .finished(Date())
        }
        stopping = false
        load()
        sendNextQueued()
    }

    /// Sends what's typed; `context` (a selection made elsewhere) goes before it,
    /// as an editor's selection does, and `attached` says what it was.
    /// `onSent` runs once the agent has started on it.
    func send(context: String? = nil, attached: String? = nil, onSent: (() -> Void)? = nil) {
        let typed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        // Codex runs its custom prompts only in its terminal: one typed with / is filled in here.
        let asked = agent == .codex ? AgentCommands.expand(typed, with: composing.commands ?? []) ?? typed : typed
        guard canSend, let request = sendRequest(context.map { $0 + "\n\n" + asked } ?? asked) else { return }
        let files = composing.files
        let attached = ([attached] + files.map { Optional($0.lastPathComponent) }).compactMap { $0 }.joined(separator: ", ")
        let shown = attached.isEmpty ? nil : attached
        if willQueue {
            let joining = joinsTurn
            draft = ""
            composing.files = []
            onSent?()
            queued.append(QueuedPrompt(request: request, typed: typed, files: files, attached: shown, joining: joining))
            if joining, let added = queued.last {
                join(added)
            } else {
                Diagnostics.log("queued a prompt for \(key)")
                sendNextQueued()
            }
            return
        }
        dispatch(request, typed: typed, files: files, attached: shown, fromBox: true, onSent: onSent)
    }

    /// Sends it now: into the session kept open here, or on its own.
    private func dispatch(
        _ request: PromptSender.Request, typed: String, files: [URL], attached shown: String?, fromBox: Bool, onSent: (() -> Void)?
    ) {
        // Into a session kept open here, images go with the prompt itself; any
        // other file (and, sent on its own, any file) is named for the agent to
        // open where it runs: copied to the server first, for one there.
        let kept = SessionKeeper.shared.isKept(key)
        let images = kept ? files.filter { PromptSender.isImage($0.path) } : []
        let named = files.filter { !images.contains($0) }
        // Here, Codex is given an image by its path, which a comma would split.
        let paths = named.map { request.agent == .codex && PromptSender.isImage($0.path) ? PromptSender.withoutCommas($0).path : $0.path }
        sent = nil
        stopping = false
        if kept, request.host == nil || named.isEmpty {
            var sending = request
            sending.attachments = paths
            return sendKept(sending, images: images, prompt: typed, attached: shown, fromBox: fromBox, onSent: onSent)
        }
        starting = true
        Task.detached(priority: .userInitiated) { [weak self] in
            var sending = request
            sending.attachments = paths
            if let host = request.host, !named.isEmpty {
                switch RemoteFiles.put(named, host: host) {
                case .success(let copied):
                    sending.attachments = copied
                case .failure(let problem):
                    await self?.didStart(.failure(problem), prompt: typed, attached: nil, fromBox: fromBox, onSent: nil)
                    return
                }
            }
            if kept {
                await self?.sendKept(sending, images: images, prompt: typed, attached: shown, fromBox: fromBox, onSent: onSent)
            } else {
                let result = PromptSender.start(sending)
                await self?.didStart(result, prompt: typed, attached: shown, fromBox: fromBox, onSent: onSent)
            }
        }
    }

    /// Into the session kept open here, as if typed there.
    private func sendKept(
        _ request: PromptSender.Request, images: [URL], prompt: String, attached: String?, fromBox: Bool, onSent: (() -> Void)?
    ) {
        starting = false
        switch SessionKeeper.shared.send(key, request, images: images) {
        case .success:
            keptSince = Date()
            if fromBox {
                draft = ""
                composing.files = []
            }
            onSent?()
            pending = PendingPrompt(text: prompt, at: Date(), attached: attached)
            Diagnostics.log("sent a prompt into \(key), kept open here")
        case .failure(let problem):
            sent = .notSent(problem.message)
            if !fromBox {
                giveBack(prompt)
            }
        }
    }

    private func didStart(
        _ result: Result<PromptSender.Started, ReadError>, prompt: String, attached: String?, fromBox: Bool, onSent: (() -> Void)?
    ) {
        starting = false
        switch result {
        case .success(let started):
            sending = started
            if fromBox {
                draft = ""
                composing.files = []
            }
            onSent?()
            // Shown at once where it goes, as the latest prompt, until the log has it.
            pending = PendingPrompt(text: prompt, at: started.at, attached: attached)
            Diagnostics.log("sent a prompt to \(key), pid \(started.pid), its output in \(started.log)")
        case .failure(let problem):
            sent = .notSent(problem.message)
            Diagnostics.log("couldn't send a prompt to \(key): \(problem.message)")
            if !fromBox {
                giveBack(prompt)
            }
        }
    }

    /// The next prompt waiting, once nothing's under way.
    private func sendNextQueued() {
        guard let next = queued.first, !next.joining, free else { return }
        queued.removeFirst()
        Diagnostics.log("sending the next queued prompt to \(key)")
        dispatch(next.request, typed: next.typed, files: next.files, attached: next.attached, fromBox: false, onSent: nil)
    }

    /// Codex kept open here: added to the answer under way, as typing while
    /// Codex works does; should Codex not take it, it waits its turn instead.
    private func join(_ waiting: QueuedPrompt) {
        let images = waiting.files.filter { PromptSender.isImage($0.path) }
        var request = waiting.request
        request.attachments = waiting.files.filter { !images.contains($0) }.map(\.path)
        let id = waiting.id
        SessionKeeper.shared.steer(key, request, images: images) { [weak self] joined in
            guard let self, let index = self.queued.firstIndex(where: { $0.id == id }) else { return }
            if joined {
                self.queued.remove(at: index)
                Diagnostics.log("added a prompt to the answer under way in \(self.key)")
                self.load()
            } else {
                self.queued[index].joining = false
                self.sendNextQueued()
            }
        }
    }

    /// A queued prompt taken back: its words return to the box, if the box is empty.
    func unqueue(_ id: UUID) {
        guard let index = queued.firstIndex(where: { $0.id == id }), !queued[index].joining else { return }
        let taken = queued.remove(at: index)
        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draft = taken.typed
            composing.files = taken.files
        }
    }

    /// Words that couldn't go, back in the box (before what's being typed).
    private func giveBack(_ words: String) {
        draft = [words, draft].filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: "\n\n")
    }

    /// Stopped: what was waiting goes back in the box, as Claude Code does.
    private func takeBackQueued() {
        let waiting = queued.filter { !$0.joining }
        guard !waiting.isEmpty else { return }
        queued.removeAll { !$0.joining }
        draft = (waiting.map(\.typed) + [draft]).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: "\n\n")
        composing.files += waiting.flatMap(\.files)
    }

    func stopSending() {
        takeBackQueued()
        if keptSince != nil, !stopping {
            stopping = true
            SessionKeeper.shared.interrupt(key)
            return
        }
        guard let started = sending, !stopping else { return }
        stopping = true
        Task.detached(priority: .userInitiated) { PromptSender.stop(started) }
    }

    private func checkSending() {
        guard let started = sending else { return }
        Task.detached(priority: .utility) { [weak self] in
            let status = PromptSender.status(started)
            await self?.sendingIs(status, for: started)
        }
    }

    private func sendingIs(_ status: PromptSender.Status?, for started: PromptSender.Started) {
        guard sending == started, let status, status != .running else { return }
        sending = nil
        switch status {
        case .finished:
            sent = .finished(Date())
            Diagnostics.log("the prompt sent to \(key) finished")
        case .failed(let why):
            sent = .failed(stopping ? "Stopped." : CodexWriter.plain(why))
            Diagnostics.log("the prompt sent to \(key) ended: \(stopping ? "stopped" : why)")
            // Never reached the session: its text goes back in the box.
            if let pending, history.map({ !Self.recorded(pending, in: $0) }) ?? true {
                if draft.isEmpty {
                    draft = pending.text
                }
                self.pending = nil
            }
        case .running:
            break
        }
        load()
        sendNextQueued()
    }

    /// For the self-test's picture: a prompt as if just sent.
    func showPending(_ text: String, attached: String? = nil) {
        pending = PendingPrompt(text: text, at: Date(), attached: attached)
    }

    /// For the tour's pictures: a turn's steps, as if read.
    func preview(steps: TurnSteps, for id: String) {
        self.steps[id] = steps
        settledSteps.insert(id)
    }

    /// For the snapshot's picture: prompts as if sent while one was under way.
    func previewQueued(_ texts: [String]) {
        queued = texts.compactMap { text in sessionRequest(text).map { QueuedPrompt(request: $0, typed: text, files: [], attached: nil) } }
    }

    /// For the probe: a prompt as if sent from here and still under way, its program `started`.
    func showSending(_ started: PromptSender.Started, text: String) {
        sending = started
        pending = PendingPrompt(text: text, at: started.at)
    }

    /// Whether the session's log has the prompt sent from here: the same words,
    /// asked after it went (give or take a server's clock).
    static func recorded(_ pending: PendingPrompt, in history: SessionHistory) -> Bool {
        func words(_ text: String) -> String {
            text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        let sent = words(pending.text)
        return history.turns.contains { turn in
            guard turn.askedAt >= pending.at.addingTimeInterval(-600) else { return false }
            let logged = words(turn.text)
            return logged == sent || logged.hasPrefix(String(sent.prefix(300))) || sent.hasPrefix(String(logged.prefix(300)))
        }
    }
}

// MARK: - The window

/// One window per agent window, raised again when its reminder is clicked again.
@MainActor
final class SessionDetailsController {
    private var windows: [String: (window: NSWindow, details: SessionDetails)] = [:]
    /// How opaque agent windows are (Settings › Appearance).
    var opacity: Double = 1 {
        didSet {
            for open in windows.values {
                open.window.alphaValue = opacity
            }
        }
    }
    private var closing: [NSObjectProtocol] = []
    /// Whether new agent windows open as tabs of the one in front.
    let tabs = WindowTabs()
    /// Whether agent windows connect to their session as they open (Settings › General).
    var connectOnOpen = false
    /// Agent windows as frosted glass (Settings › Appearance).
    var glass = true {
        didSet {
            for open in windows.values {
                Self.frost(open.window, glass)
            }
        }
    }

    /// A new agent window's size: the one you last gave an agent window, else
    /// as narrow as it goes with its boxes' names (Jump to, Open here).
    static let defaultSize = NSSize(width: 530, height: 720)
    static let sizeKey = "agentWindow.size"

    static var lastSize: NSSize? {
        guard let saved = UserDefaults.standard.string(forKey: sizeKey) else { return nil }
        let size = NSSizeFromString(saved)
        guard size.width >= WindowRoom.minimum.width, size.height >= WindowRoom.minimum.height else { return nil }
        return size
    }

    /// Frosted, the window is clear behind the glass, its title bar part of it.
    static func frost(_ window: NSWindow, _ frosted: Bool) {
        window.isOpaque = !frosted
        window.backgroundColor = frosted ? .clear : .windowBackgroundColor
        window.titlebarAppearsTransparent = frosted
        if frosted {
            window.styleMask.insert(.fullSizeContentView)
        } else {
            window.styleMask.remove(.fullSizeContentView)
        }
    }
    /// Each window's Tabs menu, in its title bar.
    private var tabMenus: [String: WindowTabsMenu] = [:]
    /// Each window's coming into sight, watched.
    private var sightWatch: [String: NSObjectProtocol] = [:]
    /// A window's session log was read.
    var onLearned: ((String, SessionHistory) -> Void)?
    /// Whether an agent window's agent is at work now: no prompt is sent then.
    var isWorking: ((String) -> Bool)?

    func show(key: String, info: WindowInfo, focus: String? = nil) {
        if let open = windows[key] {
            open.details.update(info: info)
            open.details.focus = focus ?? open.details.focus
            open.details.load()
            present(open.window)
            return
        }
        guard let details = SessionDetails(key: key, info: info) else { return }
        details.focus = focus
        weak var made: NSWindow?
        details.onLearned = { [weak self, weak details] key, history in
            // A tab says which session it is.
            if let details, let tab = made?.tab {
                tab.title = details.title
                tab.toolTip = Self.tabTip(details)
            }
            self?.onLearned?(key, history)
        }
        details.isWorking = { [weak self] in self?.isWorking?(key) ?? false }
        details.connects = { [weak self] in self?.connectOnOpen ?? false }
        let host = NSHostingController(rootView: SessionDetailsView(details: details).displayStyled())
        // The window's sizes are its own (below): SwiftUI needn't work out the
        // history's smallest size each time it changes.
        host.sizingOptions = []
        let window = NSWindow(contentViewController: host)
        made = window
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        // Agent windows can be merged into tabs of one, and only with each other.
        window.tabbingIdentifier = Self.tabbing
        window.tab.title = details.title
        window.tab.toolTip = Self.tabTip(details)
        window.title = [details.agent.clientName, details.host.map { "on \($0)" }].compactMap { $0 }.joined(separator: " ")
        window.setContentSize(Self.lastSize ?? Self.defaultSize)
        window.minSize = WindowRoom.minimum
        window.isReleasedWhenClosed = false
        window.alphaValue = opacity
        Self.frost(window, glass)
        window.collectionBehavior.insert(.moveToActiveSpace)
        // A tab of the agent window in front, if they open as tabs; else each new
        // window a little below and right of the last.
        let front = NSApp.orderedWindows.first { candidate in
            candidate.isVisible && windows.values.contains { $0.window === candidate }
        }
        if tabs.openAsTabs, let front {
            front.addTabbedWindow(window, ordered: .above)
            if front.level == .floating {
                Self.pin(window, true)
                details.showPinned(true)
            }
        } else if let last = windows.values.map(\.window).last {
            window.setFrameTopLeftPoint(NSPoint(x: last.frame.minX + 24, y: last.frame.maxY - 24))
        } else {
            window.center()
        }
        details.onPin = { [weak self, weak window] pinned in
            if let window {
                self?.pinTabs(of: window, pinned)
            }
        }
        // The pin sits in the title bar, after the close, minimize and zoom buttons.
        let pin = NSTitlebarAccessoryViewController()
        let pinView = NSHostingView(rootView: PinButton(details: details))
        pinView.frame = NSRect(x: 0, y: 0, width: 30, height: 28)
        pin.view = pinView
        pin.layoutAttribute = .left
        window.addTitlebarAccessoryViewController(pin)
        // Aa at the title bar's other end: the text's size and typeface.
        let style = NSTitlebarAccessoryViewController()
        let styleView = NSHostingView(rootView: TextStyleButton())
        styleView.frame = NSRect(x: 0, y: 0, width: 36, height: 28)
        style.view = styleView
        style.layoutAttribute = .right
        window.addTitlebarAccessoryViewController(style)
        // Tabs: merge the agent windows into one, or take this one out.
        let tabMenu = WindowTabsMenu(window: window, tabs: tabs, controller: self)
        tabMenus[key] = tabMenu
        let tabsAccessory = NSTitlebarAccessoryViewController()
        tabsAccessory.view = tabMenu.view
        tabsAccessory.layoutAttribute = .right
        window.addTitlebarAccessoryViewController(tabsAccessory)
        windows[key] = (window, details)
        // In sight if any of it shows (the self-test's windows, kept out of the way, count as shown).
        details.isInSight = { [weak self, weak window] in
            guard let window else { return false }
            return self?.offscreen == true || window.occlusionState.contains(.visible) && !window.isMiniaturized
        }
        sightWatch[key] = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak details, weak window] _ in
            MainActor.assumeIsolated {
                if let window, window.occlusionState.contains(.visible) {
                    details?.cameIntoSight(inFront: window.isKeyWindow)
                }
            }
        }
        // Resized while you type: the words wrap to the box. (The text being typed
        // keeps the width it started with, unless told to follow the box.)
        closing.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: window, queue: .main
        ) { [weak window] _ in
            MainActor.assumeIsolated {
                // A box that wraps (the message box), not one that scrolls sideways (search).
                guard let editor = window?.firstResponder as? NSTextView, editor.isFieldEditor,
                      (editor.delegate as? NSTextField)?.cell?.wraps == true, let container = editor.textContainer
                else { return }
                container.widthTracksTextView = true
                container.containerSize = NSSize(width: editor.frame.width, height: container.containerSize.height)
            }
        })
        // Resized by hand: the next agent window opens that size.
        closing.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didEndLiveResizeNotification, object: window, queue: .main
        ) { [weak window] _ in
            MainActor.assumeIsolated {
                if let size = window?.contentView?.frame.size {
                    UserDefaults.standard.set(NSStringFromSize(size), forKey: Self.sizeKey)
                }
            }
        })
        closing.append(NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                if let watch = self?.sightWatch.removeValue(forKey: key) {
                    NotificationCenter.default.removeObserver(watch)
                }
                self?.windows[key]?.details.stop()
                self?.windows[key] = nil
                self?.tabMenus[key] = nil
                SelectionWatcher.shared.release()
                // A session moved here ends with its window (once its turn is done).
                SessionKeeper.shared.windowClosed(key)
            }
        })
        // ⌘F and ⌘G search the agent window in front.
        SearchCommands.shared.searchOf = { [weak self] window in
            self?.windows.values.first { $0.window === window }?.details.search
        }
        // What you select elsewhere shows by its message box while it's open.
        SelectionWatcher.shared.retain()
        SessionKeeper.shared.windowOpened(key)
        details.start()
        present(window)
    }

    /// An agent window's agent and session: ("Claude Code", "Fix the login page on gpu").
    func source(of window: NSWindow) -> (app: String, title: String)? {
        guard let details = windows.values.first(where: { $0.window === window })?.details else { return nil }
        return (details.agent.clientName, details.title + (details.host.map { " on \($0)" } ?? ""))
    }

    /// The session's open window, if any, reads it again: a job finished there,
    /// or it started or stopped working.
    func refresh(_ key: String) {
        windows[key]?.details.load()
    }

    /// Jumps straight to where the window's session runs; shows the details if it can't.
    func jump(key: String, info: WindowInfo) {
        show(key: key, info: info)
        guard let details = windows[key]?.details else { return }
        Task { @MainActor in
            for _ in 0..<40 {
                if case .found = details.place {
                    details.jump()
                    return
                }
                if case .closed = details.place {
                    return
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    static let tabbing = "io.github.homoy.agentbuddy.agent-window"

    /// A tab's tip: the session, its agent, and where it runs.
    static func tabTip(_ details: SessionDetails) -> String {
        details.title + " \u{00B7} " + details.agent.clientName + (details.host.map { " on \($0)" } ?? "")
    }

    /// The agent windows, as they're stacked on screen, front first.
    var agentWindows: [NSWindow] {
        windows.values.map(\.window)
    }

    /// Every agent window as a tab of `window`'s, pinned as it is.
    func mergeAll(into window: NSWindow) {
        for other in agentWindows where other !== window && !(window.tabbedWindows ?? []).contains(other) {
            window.addTabbedWindow(other, ordered: .above)
        }
        window.makeKeyAndOrderFront(nil)
        pinTabs(of: window, window.level == .floating)
    }

    /// A pinned tab pins its whole window (its tabs share it), and letting go lets go of it all.
    func pinTabs(of window: NSWindow, _ pinned: Bool) {
        for tab in window.tabbedWindows ?? [window] {
            Self.pin(tab, pinned)
            windows.values.first { $0.window === tab }?.details.showPinned(pinned)
        }
    }

    /// Pinned, a window floats above other apps' windows, on every Space and
    /// beside full-screen apps; let go, it's an ordinary window again.
    static func pin(_ window: NSWindow, _ pinned: Bool) {
        window.level = pinned ? .floating : .normal
        if pinned {
            window.collectionBehavior.remove(.moveToActiveSpace)
            window.collectionBehavior.formUnion([.canJoinAllSpaces, .fullScreenAuxiliary])
        } else {
            window.collectionBehavior.subtract([.canJoinAllSpaces, .fullScreenAuxiliary])
            window.collectionBehavior.insert(.moveToActiveSpace)
        }
    }

    private func present(_ window: NSWindow) {
        guard !offscreen else {
            window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
            window.orderBack(nil)
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// For the self-test: windows open off screen and don't take focus.
    var offscreen = false

    /// The open window and its details, for the self-test.
    func open(_ key: String) -> (window: NSWindow, details: SessionDetails)? {
        windows[key]
    }
}

/// The message box's text, apart from the window's other state, with the
/// files to send with it and how the prompts sent from here are to go.
@MainActor
final class MessageDraft: ObservableObject {
    @Published var text = ""
    /// Files on this Mac to send with the next prompt.
    @Published var files: [URL] = []
    /// The model, effort, fast mode and mode chosen (each nil: the session's own).
    @Published var options = PromptSender.Options()
    /// Codex's models where the session runs, once asked; why not, if it couldn't be.
    @Published var codexModels: [CodexModel]?
    @Published var modelsProblem: String?
    var askingModels = false
    /// What @ and / offer: the session folder's files, and the agent's commands
    /// (read when first wanted, and again after five minutes).
    @Published var projectFiles: [String]?
    @Published var commands: [AgentCommand]?
    var suggestionsRead: Date?
    /// What @ and / show as you type.
    let suggestions = ComposerSuggestions()
}

// MARK: - Views

struct SessionDetailsView: View {
    @ObservedObject var details: SessionDetails
    @ObservedObject private var search: HistorySearch
    @AppStorage(FrostedGlass.key) private var glass = true
    @State private var expanded: Set<String>
    /// Older prompts whose whole answer you asked for (the latest's always shows whole).
    @State private var whole: Set<String> = []
    /// The latest prompt is open unless you fold it: these are folded by hand.
    @State private var folded: Set<String> = []

    /// - Parameter expanded: prompts shown open at first (the snapshot mode).
    init(details: SessionDetails, expanded: Set<String> = []) {
        self.details = details
        _search = ObservedObject(wrappedValue: details.search)
        _expanded = State(initialValue: expanded)
    }

    var body: some View {
        // Small, the parts around the history give way: it keeps the room.
        GeometryReader { space in
            let room = WindowRoom(short: space.size.height < WindowRoom.shortBelow, narrow: space.size.width < WindowRoom.narrowBelow)
            whole(room)
                .environment(\.windowRoom, room)
        }
        .frame(minWidth: WindowRoom.minimum.width, minHeight: WindowRoom.minimum.height)
        .background {
            if glass {
                GlassBackground()
                    .ignoresSafeArea()
            }
        }
    }

    private func whole(_ room: WindowRoom) -> some View {
        VStack(spacing: 0) {
            header(room)
                .padding(.horizontal, room.narrow ? 12 : 16)
                .padding(.vertical, room.short ? 8 : 14)
            Divider()
            if search.shown {
                HistorySearchBar(search: search, rows: { details.history?.rows ?? [] })
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                Divider()
            }
            content
                // @ and /'s choices, at the foot of the history, just above the message box.
                .overlay(alignment: .bottom) {
                    SuggestionOverlay(suggestions: details.composing.suggestions)
                }
            Divider()
            PromptComposer(details: details)
                .padding(.horizontal, room.narrow ? 10 : 14)
                .padding(.top, room.short ? 6 : 10)
                .padding(.bottom, room.short ? 6 : 9)
            Divider()
            footer(room)
                .padding(.horizontal, room.narrow ? 12 : 16)
                .padding(.vertical, room.short ? 5 : 8)
        }
    }

    private func header(_ room: WindowRoom) -> some View {
        HStack(alignment: room.short ? .center : .top, spacing: room.narrow ? 8 : 12) {
            AgentMark(agent: details.agent)
            VStack(alignment: .leading, spacing: 3) {
                Text(details.title)
                    .uiFont(14, weight: .semibold)
                    .lineLimit(room.short ? 1 : 2)
                    .help(details.title)
                if !room.short {
                    Text(details.facts)
                        .uiFont(11)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .textSelection(.enabled)
            Spacer(minLength: 8)
            SessionControls(details: details)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let history = details.history, !history.turns.isEmpty {
            let rows = history.rows
            let reminded = details.remindedTurns
            let latest = details.latestID
            let found = Set(search.matches)
            let currentMatch = search.shown ? search.currentID : nil
            ScrollViewReader { proxy in
                ScrollView {
                    // Not lazy: a lazy stack guesses the height of rows out of sight from
                    // those in sight, and guesses again at each redraw (the clock's tick),
                    // so the history jumped under what you were reading.
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(rows) { row in
                            let open = isOpen(row.id, latest: latest)
                            PromptRowView(
                                row: row, reminded: reminded.contains(row.id), expanded: open,
                                wholeAnswer: row.id == latest || whole.contains(row.id), now: details.now,
                                steps: details.steps[row.id],
                                shown: { shown in shown ? details.showSteps(row.id) : details.hideSteps(row.id) },
                                toggle: {
                                    if open {
                                        expanded.remove(row.id)
                                        folded.insert(row.id)
                                    } else {
                                        expanded.insert(row.id)
                                        folded.remove(row.id)
                                    }
                                },
                                showWhole: { whole.insert(row.id) },
                                searched: found.contains(row.id) ? search.query : "", currentMatch: row.id == currentMatch,
                                reveal: row.id == currentMatch ? search.moves : 0)
                            .equatable()
                            .id(row.id)
                        }
                        if let pending = details.pending {
                            PendingPromptRow(pending: pending, client: details.agent.clientName, now: details.now, lineAbove: !rows.isEmpty)
                                .id(PendingPromptRow.id)
                        }
                    }
                    .padding(.vertical, 8)
                }
                .onAppear { reveal(rows, proxy) }
                .onChange(of: details.pending) { pending in
                    if pending != nil {
                        withAnimation { proxy.scrollTo(PendingPromptRow.id, anchor: .bottom) }
                    }
                }
                .onChange(of: rows.count) { _ in
                    search.refresh(rows)
                    withAnimation { reveal(rows, proxy) }
                }
                // Found: the prompt opened, its whole answer shown, and scrolled to.
                .onChange(of: search.moves) { _ in
                    guard let id = search.currentID else { return }
                    expanded.insert(id)
                    folded.remove(id)
                    whole.insert(id)
                    withAnimation { proxy.scrollTo(id, anchor: .top) }
                }
                .onChange(of: details.focus) { focus in
                    // Asked for again (a job clicked while the window's open); not when let go of.
                    if focus != nil {
                        withAnimation { reveal(rows, proxy) }
                    }
                }
            }
        } else {
            VStack(spacing: 10) {
                Spacer()
                if details.loading {
                    ProgressView()
                    Text(details.host == nil ? "Reading the session…" : "Asking \(details.host ?? "the server")…")
                        .uiFont(12)
                        .foregroundStyle(.secondary)
                } else if let problem = details.problem {
                    Image(systemName: "exclamationmark.triangle")
                        .uiFont(22)
                        .foregroundStyle(.orange)
                    Text(problem)
                        .uiFont(12)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 30)
                } else {
                    Text("No prompts in this session yet.")
                        .uiFont(12)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// Open: a prompt opened by hand, and the latest unless folded by hand.
    private func isOpen(_ id: String, latest: String?) -> Bool {
        expanded.contains(id) || (id == latest && !folded.contains(id))
    }

    /// Scrolls to the prompt asked for, open; else to the latest, from its top,
    /// its whole answer below. A prompt asked for (a job's) is shown once: what
    /// comes after, such as a prompt landing in the session, doesn't go back to it.
    private func reveal(_ rows: [HistoryRow], _ proxy: ScrollViewProxy) {
        let target: String?
        let anchor: UnitPoint
        if let focus = details.focus, rows.contains(where: { $0.id == focus }) {
            expanded.insert(focus)
            folded.remove(focus)
            (target, anchor) = (focus, .center)
        } else {
            (target, anchor) = (details.latestID ?? rows.last?.id, .top)
        }
        if details.focus != nil {
            DispatchQueue.main.async { details.focus = nil }
        }
        guard let target else { return }
        proxy.scrollTo(target, anchor: anchor)
        // Again once laid out: a window just put on screen may not scroll the first time.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            proxy.scrollTo(target, anchor: anchor)
        }
    }

    private func footer(_ room: WindowRoom) -> some View {
        HStack(spacing: 10) {
            if let history = details.history {
                HStack(spacing: 0) {
                    Text(summary(history))
                        .lineLimit(1)
                    // Narrow: when it was read, left to the tooltip.
                    if details.loadedAt != nil, !room.narrow {
                        // On a clock of its own: the rest of the window isn't redrawn for it.
                        TimelineView(.periodic(from: .now, by: 15)) { context in
                            Text(" · read \(Format.ago(details.loadedAt ?? context.date, now: context.date))")
                        }
                    }
                }
                .uiFont(10.5)
                .foregroundStyle(.secondary)
            }
            if let problem = details.problem, details.history != nil {
                Text(problem)
                    .uiFont(10.5)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .help(problem)
            }
            Spacer()
            if details.loading && details.history != nil {
                ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 14, height: 14)
            }
            Button {
                search.open()
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.borderless)
            .uiFont(11)
            .help("Search this session's prompts and answers (⌘F)")
            if details.host == nil {
                Button("Show Log") { details.revealLog() }
                    .buttonStyle(.borderless)
                    .uiFont(11)
                    .help("Show the session's log file in Finder")
            }
            Button("Refresh") { details.load(whole: true) }
                .buttonStyle(.borderless)
                .uiFont(11)
                .keyboardShortcut("r", modifiers: .command)
                .disabled(details.loading)
        }
    }

    private func summary(_ history: SessionHistory) -> String {
        let prompts = history.turns.count == 1 ? "1 prompt" : "\(history.turns.count) prompts"
        let rows = history.rows
        let edited = rows.filter { $0.branchStart && !$0.turn.separate }.count
        let separate = rows.filter(\.turn.separate).count
        var text = prompts
        if edited > 0 {
            text += " · \(edited) edited away"
        }
        if separate > 0 {
            text += " · \(separate) sent separately"
        }
        return text
    }
}

/// The session's two boxes, the same size, one above the other: Jump to, its
/// app's icon after it, with a green light before it while the session is open
/// in that app; and Open here (Let go once it's open in Agent Buddy), with how
/// well the agent is reached before it: a green light on this Mac, a server's
/// round trip on a server. Short of room, they're on one line, as their icons.
struct SessionControls: View {
    @ObservedObject var details: SessionDetails
    @ObservedObject private var keeper = SessionKeeper.shared
    @SwiftUI.Environment(\.windowRoom) private var room

    var body: some View {
        let phase = keeper.phases[details.key]
        let keeps: Bool = {
            if case .success? = details.sendPlan { return true }
            return false
        }()
        VStack(alignment: .trailing, spacing: 4) {
            if room.short {
                HStack(spacing: 6) {
                    if keeps {
                        keepLight(phase)
                        keepBox(phase)
                    }
                    jumpLight
                    jumpBox
                }
                .fixedSize()
            } else {
                // Two columns: the lights, then the boxes, each as wide as the wider.
                Grid(alignment: .trailing, horizontalSpacing: 6, verticalSpacing: 6) {
                    GridRow {
                        jumpLight
                        jumpBox
                    }
                    if keeps {
                        GridRow {
                            keepLight(phase)
                            keepBox(phase)
                        }
                    }
                }
                .fixedSize()
            }
            notes(phase)
        }
    }

    // MARK: Jump to

    @ViewBuilder
    private var jumpLight: some View {
        if case .found(let place)? = details.place, place.exact {
            StatusLight(color: .green)
                .help("Open in \(place.appName): \(place.detail)")
        } else {
            Color.clear.frame(width: 0, height: 0)
        }
    }

    @ViewBuilder
    private var jumpBox: some View {
        switch details.place {
        case .found(let place)?:
            Button {
                details.jump()
            } label: {
                HStack(spacing: 5) {
                    if !room.narrow {
                        Text("Jump to")
                    }
                    Image(nsImage: NSWorkspace.shared.icon(forFile: place.appURL.path))
                        .resizable()
                        .frame(width: 16, height: 16)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(room.short ? .small : .regular)
            .disabled(details.jumping)
            .keyboardShortcut("j", modifiers: .command)
            .help(place.exact ? "Jump to \(place.detail) in \(place.appName) (⌘J)" : "Bring \(place.appName) forward (⌘J)")
        case .closed(let reason)?:
            box("Jump to", "arrow.up.forward.app") {}
                .disabled(true)
                .help("Its window is closed: \(reason)")
        case nil:
            Button {} label: {
                HStack(spacing: 5) {
                    if !room.narrow {
                        Text("Jump to")
                    }
                    ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 16, height: 16)
                }
                .frame(maxWidth: .infinity)
            }
            .controlSize(room.short ? .small : .regular)
            .disabled(true)
            .help("Finding its window\u{2026}")
        }
    }

    // MARK: Open here

    @ViewBuilder
    private func keepLight(_ phase: SessionKeeper.Phase?) -> some View {
        switch phase {
        case .ready?, .working?:
            if details.host == nil {
                StatusLight(color: .green)
                    .help("Open here, in Agent Buddy, on this Mac")
            } else {
                ConnectionTag(host: details.host)
            }
        case .opening?, .waiting?:
            ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 14, height: 14)
        case .failed(let why)?:
            StatusLight(color: .red)
                .help(why)
        case nil:
            Color.clear.frame(width: 0, height: 0)
        }
    }

    @ViewBuilder
    private func keepBox(_ phase: SessionKeeper.Phase?) -> some View {
        switch phase {
        case .ready?, .working?:
            box("Let go", "arrow.up.to.line") { details.letGo() }
                .help("Open here, in the background. Let go ends it (closing this window does too); the box then sends each prompt on its own again\(details.agent == .codex ? ", and the thread can be opened in another program" : "").")
        case .opening?:
            box("Opening\u{2026}", "arrow.down.to.line") {}
                .disabled(true)
        case .waiting(let holder)?:
            box("Cancel", "xmark") { keeper.letGo(details.key) }
                .help("Stop waiting for \(holder) to let go of the thread")
        case .failed?, nil:
            if let holder = details.heldElsewhere, holder != "another program" {
                box("Open here", "arrow.down.to.line") { details.takeOver() }
                    .help("\(holder) has this thread open. Agent Buddy stops \(holder)'s Codex, which lets go of it, and opens the thread here. It asks first.")
            } else {
                box("Open here", "arrow.down.to.line") { details.moveHere() }
                    .disabled(details.busyForMove)
                    .help(details.busyForMove
                          ? "It's working on a prompt. Open it here once that's done, or Stop it first."
                          : "Keep this session open in Agent Buddy, in the background, until you let go or close this window: what you send from the box goes into it, as if typed there, and nothing opens. "
                          + (details.agent == .codex ? "Codex lets one program at a time write to a thread: while it's here, its other windows can't send to it." : "Its other windows won't show what's sent from here."))
            }
        }
    }

    /// A box: its icon, its name if there's room, as wide as the column.
    private func box(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                if !room.narrow {
                    Text(title)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .controlSize(room.short ? .small : .regular)
    }

    /// Under the boxes: why a jump didn't work, what opening here waits for, why it failed.
    @ViewBuilder
    private func notes(_ phase: SessionKeeper.Phase?) -> some View {
        if let problem = details.jumpProblem {
            note(problem, .orange)
        }
        switch phase {
        case .waiting(let holder)?:
            HStack(spacing: 6) {
                if holder != "another program" {
                    Button("Take It") { details.takeOver() }
                        .controlSize(.small)
                        .help("Agent Buddy stops \(holder)'s Codex, which lets go of the thread, and opens it here. It asks first.")
                }
                note(room.short ? "Waiting for \(holder) to let go" : "Waiting for \(holder) to let go of the thread. \(SessionKeeper.howToFree(holder)) It opens here by itself once it's free.",
                     .secondary)
            }
        case .failed(let why)?:
            if !room.short {
                note(why, .orange)
            }
        default:
            EmptyView()
        }
    }

    private func note(_ words: String, _ color: Color) -> some View {
        Text(words)
            .uiFont(10)
            .foregroundStyle(color)
            .lineLimit(room.short ? 1 : 3)
            .multilineTextAlignment(.trailing)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: room.narrow ? 150 : 230, alignment: .trailing)
            .help(words)
    }
}

/// A small light: green, open; red, it failed.
struct StatusLight: View {
    let color: Color

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .shadow(color: color.opacity(0.6), radius: 2)
            .padding(.horizontal, 2)
    }
}

/// One prompt: when, how its turn went, and the start of what was asked. Click
/// it for the whole prompt, the agent's answer and its tokens.
struct PromptRowView: View {
    let row: HistoryRow
    let reminded: Bool
    let expanded: Bool
    /// The whole answer, or its start with a link to the rest.
    let wholeAnswer: Bool
    let now: Date
    /// What the agent did, step by step, once read.
    let steps: SessionDetails.TurnSteps?
    /// Told when it's shown open, and when no longer.
    let shown: (Bool) -> Void
    let toggle: () -> Void
    let showWhole: () -> Void
    /// Words searched for that it has, marked (empty: none).
    var searched = ""
    /// The match shown now: marked out.
    var currentMatch = false
    /// Each move to it as the match: its answer scrolls to the words (0: never).
    var reveal = 0
    @AppStorage(TextStyle.sizeKey) private var textSize = TextStyle.standardSize
    @AppStorage(TextStyle.fontKey) private var font: MarkdownFont = .system

    static let column: CGFloat = 16
    static let dotY: CGFloat = 15

    var body: some View {
        let turn = row.turn
        HStack(alignment: .top, spacing: 6) {
            HistoryGutter(row: row)
                .frame(width: CGFloat(row.depth + 1) * Self.column + 4)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(Self.when(turn.askedAt, now: now))
                        .uiFont(10.5, digits: true)
                        .foregroundStyle(.secondary)
                    OutcomeBadge(turn: turn)
                    if reminded {
                        Image(systemName: "bell.fill")
                            .uiFont(9)
                            .foregroundStyle(.blue)
                            .help("Agent Buddy reminded you when this finished")
                    }
                    if turn.separate {
                        badge("Sent separately", help: row.current
                            ? "Sent on its own, as Agent Buddy's message box does (claude -p): the session's own window doesn't show it"
                            : "Sent on its own, as Agent Buddy's message box does (claude -p): the session's own window didn't see it, and what was typed there next carried on without it")
                    } else if row.branchStart {
                        badge("Edited away", help: "You went back and asked something else here; this line was left behind")
                    }
                    Spacer(minLength: 0)
                    if !turn.usage.isEmpty {
                        Text("\(TokenStatistics.compact(turn.tokens.total)) tokens")
                            .uiFont(10.5, digits: true)
                            .foregroundStyle(.secondary)
                            .help(turn.usage.map { "\($0.model): \(TokenStatistics.compact($0.counts.total))" }.joined(separator: "\n"))
                    }
                    if expanded || turn.answer != nil || turn.text.count > 120 || !turn.usage.isEmpty {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .uiFont(8.5, weight: .semibold)
                            .foregroundStyle(.tertiary)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture(perform: toggle)
                .help(expanded ? "Click to fold it" : "Click for the whole prompt, the agent's answer and its tokens")
                if expanded {
                    // Open: select any of it to copy it.
                    VStack(alignment: .leading, spacing: 4) {
                        Text(promptText)
                            .font(.system(size: textSize - 0.5, design: TextStyle.design(font)))
                            .fixedSize(horizontal: false, vertical: true)
                        if !turn.selections.isEmpty {
                            PromptSelectionsView(selections: turn.selections, open: true, searched: searched)
                        }
                        let read = steps?.steps.isEmpty == false ? steps : nil
                        if read != nil || turn.answer != nil {
                            // The words in the prompt itself: it shows them; else the answer scrolls to them.
                            let inPrompt = !searched.isEmpty && turn.text.range(of: searched, options: HistorySearch.options) != nil
                            TurnPage(steps: read, answer: turn.answer ?? "", whole: wholeAnswer, showWhole: showWhole,
                                     searched: searched, reveal: inPrompt ? 0 : reveal)
                                .padding(.top, 2)
                        } else if turn.outcome == .running {
                            Text("No answer yet: it's working on it. Nothing shows while it thinks, and at a high effort a hard question can take 5 minutes or more.")
                                .uiFont(11)
                                .foregroundStyle(.secondary)
                        }
                        if !turn.usage.isEmpty {
                            TokenTable(usage: turn.usage)
                                .padding(.top, 4)
                        }
                    }
                    .textSelection(.enabled)
                    .onAppear { shown(true) }
                    .onDisappear { shown(false) }
                } else {
                    Text(promptText)
                        .font(.system(size: textSize - 0.5, design: TextStyle.design(font)))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentShape(Rectangle())
                        .onTapGesture(perform: toggle)
                        .help("Click for the whole prompt, the agent's answer and its tokens")
                    if !turn.selections.isEmpty {
                        PromptSelectionsView(selections: turn.selections, open: false)
                            .contentShape(Rectangle())
                            .onTapGesture(perform: toggle)
                    }
                }
            }
            .padding(.vertical, 6)
            .padding(.trailing, 14)
        }
        .padding(.leading, 10)
        // The match shown now, among those found.
        .background(currentMatch ? Color.accentColor.opacity(0.07) : Color.clear)
        .opacity(row.current ? 1 : 0.6)
    }

    static func when(_ date: Date, now: Date) -> String {
        Calendar.current.isDate(date, inSameDayAs: now) ? Format.clock(date, now: now) : Format.dayAndTime(date)
    }

    /// The prompt, the words searched for marked.
    private var promptText: AttributedString {
        searched.isEmpty ? AttributedString(row.turn.text) : HistorySearch.marked(row.turn.text, searched)
    }

    private func badge(_ words: String, help: String) -> some View {
        Text(words)
            .uiFont(9.5, weight: .medium)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.secondary.opacity(0.15)))
            .help(help)
    }

}

/// A row is redrawn only when what it shows changed (its turn, steps, whether
/// it's open, the day), not each time the window's other parts do. Its actions
/// are the same for the same row.
extension PromptRowView: Equatable {
    static func == (a: PromptRowView, b: PromptRowView) -> Bool {
        a.row == b.row && a.reminded == b.reminded && a.expanded == b.expanded && a.wholeAnswer == b.wholeAnswer
            && a.now == b.now && a.steps == b.steps && a.searched == b.searched && a.currentMatch == b.currentMatch && a.reveal == b.reveal
    }
}

/// A prompt just sent from here: at the end of the line, as the latest, until
/// the session's log has it and it shows as itself.
struct PendingPromptRow: View {
    static let id = "pending-prompt"
    let pending: SessionDetails.PendingPrompt
    let client: String
    let now: Date
    let lineAbove: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Canvas { context, _ in
                let x = PromptRowView.column / 2 + 2
                let dotY = PromptRowView.dotY
                if lineAbove {
                    var path = Path()
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: dotY))
                    context.stroke(path, with: .color(Color.secondary.opacity(0.35)), lineWidth: 1.5)
                }
                context.fill(Path(ellipseIn: CGRect(x: x - 4.5, y: dotY - 4.5, width: 9, height: 9)), with: .color(.accentColor))
            }
            .frame(width: PromptRowView.column + 4)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(PromptRowView.when(pending.at, now: now))
                        .uiFont(10.5, digits: true)
                        .foregroundStyle(.secondary)
                    Label("working", systemImage: "ellipsis.circle")
                        .uiFont(10.5)
                        .foregroundStyle(.blue)
                        .labelStyle(.titleAndIcon)
                    Text("Sent from here")
                        .uiFont(9.5, weight: .medium)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    Spacer(minLength: 0)
                }
                Text(pending.text)
                    .uiFont(12)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if let attached = pending.attached {
                    Label("With your selection: \(attached)", systemImage: "text.cursor")
                        .uiFont(10.5)
                        .foregroundStyle(.secondary)
                }
                Text("No answer yet: \(client) is starting on it.")
                    .uiFont(11)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 6)
            .padding(.trailing, 14)
        }
        .padding(.leading, 10)
    }
}

/// The tree's lines: the line each level runs on, a dot for the prompt, and a
/// bend where an edited-away branch leaves the line above it.
struct HistoryGutter: View {
    let row: HistoryRow

    var body: some View {
        Canvas { context, size in
            let line = GraphicsContext.Shading.color(Color.secondary.opacity(0.35))
            func x(_ level: Int) -> CGFloat { CGFloat(level) * PromptRowView.column + PromptRowView.column / 2 + 2 }
            let dotY = PromptRowView.dotY
            for level in row.guides {
                var path = Path()
                path.move(to: CGPoint(x: x(level), y: 0))
                path.addLine(to: CGPoint(x: x(level), y: size.height))
                context.stroke(path, with: line, lineWidth: 1.5)
            }
            let me = x(row.depth)
            if row.lineAbove {
                var path = Path()
                path.move(to: CGPoint(x: me, y: 0))
                path.addLine(to: CGPoint(x: me, y: dotY))
                context.stroke(path, with: line, lineWidth: 1.5)
            }
            if row.lineBelow {
                var path = Path()
                path.move(to: CGPoint(x: me, y: dotY))
                path.addLine(to: CGPoint(x: me, y: size.height))
                context.stroke(path, with: line, lineWidth: 1.5)
            }
            if row.branchStart, row.depth > 0 {
                var path = Path()
                let from = x(row.depth - 1)
                path.move(to: CGPoint(x: from, y: max(0, dotY - 12)))
                path.addQuadCurve(to: CGPoint(x: me, y: dotY), control: CGPoint(x: from, y: dotY))
                context.stroke(path, with: line, lineWidth: 1.5)
            }
            let dot = Path(ellipseIn: CGRect(x: me - 4.5, y: dotY - 4.5, width: 9, height: 9))
            if row.current {
                context.fill(dot, with: .color(.accentColor))
            } else {
                context.fill(dot, with: .color(Color(nsColor: .windowBackgroundColor)))
                context.stroke(dot, with: line, lineWidth: 1.5)
            }
        }
    }
}

/// How a turn went, in a few words.
struct OutcomeBadge: View {
    let turn: PromptTurn

    var body: some View {
        if turn.outcome == .running {
            // How long so far, a minute at a time: while it thinks, nothing else shows.
            TimelineView(.periodic(from: .now, by: 30)) { context in
                badge("ellipsis.circle", .blue, Self.working(since: turn.askedAt, now: context.date))
            }
        } else if let (symbol, color, words) = describe {
            badge(symbol, color, words)
        }
    }

    private func badge(_ symbol: String, _ color: Color, _ words: String) -> some View {
        Label(words, systemImage: symbol)
            .uiFont(10.5)
            .foregroundStyle(color)
            .labelStyle(.titleAndIcon)
    }

    /// "working for 4 min"; just "working" under a minute, or for a turn left
    /// unfinished long ago.
    static func working(since: Date, now: Date) -> String {
        let minutes = Int(now.timeIntervalSince(since) / 60)
        guard minutes >= 1, minutes < 12 * 60 else { return "working" }
        return minutes < 60 ? "working for \(minutes) min" : "working for \(minutes / 60)h \(String(format: "%02d", minutes % 60))m"
    }

    private var describe: (String, Color, String)? {
        // A turn under a second long was replayed into the log, not timed.
        let took = turn.duration.flatMap { $0 >= 1 ? " in \(Format.duration($0))" : nil } ?? ""
        switch turn.outcome {
        case .completed: return ("checkmark.circle.fill", .green, "done\(took)")
        case .failed: return ("exclamationmark.circle.fill", .red, "stopped with an error")
        case .limited: return ("hourglass.circle.fill", .orange, "hit a usage limit")
        case .interrupted: return ("stop.circle", .secondary, "interrupted")
        case .running: return ("ellipsis.circle", .blue, "working")
        case .open: return nil
        }
    }
}

/// The pin in an agent window's title bar: pinned, the window stays above other windows.
struct PinButton: View {
    @ObservedObject var details: SessionDetails

    var body: some View {
        Button {
            details.togglePin()
        } label: {
            Image(systemName: details.pinned ? "pin.fill" : "pin")
                .uiFont(11.5, weight: .medium)
                .rotationEffect(.degrees(details.pinned ? 0 : 45))
                .foregroundStyle(details.pinned ? Color.accentColor : Color.secondary)
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .frame(width: 30, height: 28)
        .help(details.pinned ? "Unpin: let other windows cover this one again" : "Pin: keep this window above other windows, on every Space")
    }
}

/// Whether new agent windows open as tabs of the one in front (Settings ›
/// Appearance, or a window's Tabs menu).
@MainActor
final class WindowTabs: ObservableObject {
    @Published var openAsTabs = false
    /// Told when a window's Tabs menu changes it, for Settings to keep.
    var onChange: ((Bool) -> Void)?
}

/// The Tabs menu in an agent window's title bar: every agent window merged
/// into tabs of this one, this tab moved to a window of its own, and whether
/// new ones open as tabs. Built as it opens, so it offers only what can be done.
@MainActor
final class WindowTabsMenu: NSObject {
    let view: NSView
    private let button: NSButton
    private weak var window: NSWindow?
    private let tabs: WindowTabs
    private weak var controller: SessionDetailsController?

    init(window: NSWindow, tabs: WindowTabs, controller: SessionDetailsController) {
        self.window = window
        self.tabs = tabs
        self.controller = controller
        button = NSButton(image: NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: "Tabs") ?? NSImage(),
                          target: nil, action: nil)
        view = NSView(frame: NSRect(x: 0, y: 0, width: 30, height: 28))
        super.init()
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        button.frame = NSRect(x: 2, y: 3, width: 26, height: 22)
        button.target = self
        button.action = #selector(open)
        button.toolTip = "Tabs: merge the agent windows into tabs of one window"
        button.setAccessibilityLabel("Tabs")
        view.addSubview(button)
    }

    @objc private func open() {
        guard let window else { return }
        let menu = NSMenu()
        let others = (controller?.agentWindows.count ?? 1) - (window.tabbedWindows?.count ?? 1)
        let merge = menu.addItem(withTitle: "Merge All Agent Windows", action: others > 0 ? #selector(mergeAll) : nil, keyEquivalent: "")
        merge.target = self
        let tabCount = window.tabbedWindows?.count ?? 1
        let separate = menu.addItem(withTitle: "Move Tab to New Window", action: tabCount > 1 ? #selector(separate) : nil, keyEquivalent: "")
        separate.target = self
        menu.addItem(.separator())
        let always = menu.addItem(withTitle: "Open New Agent Windows as Tabs", action: #selector(toggleOpenAsTabs), keyEquivalent: "")
        always.target = self
        always.state = tabs.openAsTabs ? .on : .off
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY + 4), in: button)
    }

    @objc private func mergeAll() {
        guard let window else { return }
        controller?.mergeAll(into: window)
    }

    @objc private func separate() {
        window?.moveTabToNewWindow(nil)
    }

    @objc private func toggleOpenAsTabs() {
        tabs.openAsTabs.toggle()
        tabs.onChange?(tabs.openAsTabs)
    }
}

/// How much room an agent window has. Short or narrow, the parts around the
/// history give it room: the header in a line, buttons as their icons, and the
/// message box's explanations left out (its warnings stay).
struct WindowRoom: Equatable {
    var short = false
    var narrow = false

    static let shortBelow: CGFloat = 600
    static let narrowBelow: CGFloat = 520
    /// As small as an agent window goes, the history still in sight.
    static let minimum = NSSize(width: 360, height: 340)
}

private struct WindowRoomKey: EnvironmentKey {
    static let defaultValue = WindowRoom()
}

extension EnvironmentValues {
    var windowRoom: WindowRoom {
        get { self[WindowRoomKey.self] }
        set { self[WindowRoomKey.self] = newValue }
    }
}

/// A label's style, picked as the room allows.
struct AnyLabelStyle: LabelStyle {
    let iconAlone: Bool

    static let iconOnly = AnyLabelStyle(iconAlone: true)
    static let titleAndIcon = AnyLabelStyle(iconAlone: false)

    func makeBody(configuration: Configuration) -> some View {
        if iconAlone {
            configuration.icon
        } else {
            HStack(spacing: 4) {
                configuration.icon
                configuration.title
            }
        }
    }
}
