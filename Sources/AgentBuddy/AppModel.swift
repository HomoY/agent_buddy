import AppKit
import Combine
import AgentBuddyCore
import AgentBuddyRemoteKit

/// What the reminders remember between launches, so nothing reminds twice.
struct ReminderMemory: Codable {
    struct Warned: Codable {
        var level: Double
        var resetsAt: Date?
    }

    struct PendingReset: Codable {
        var resetsAt: Date
        var usedPercent: Double
    }

    var warned: [String: Warned] = [:]
    var pendingSessionReset: PendingReset?
    var lastSessionReminder: Date?
    var lastLimitNotice: [String: Date] = [:]

    private static let key = "reminderMemory"

    static func load() -> ReminderMemory {
        guard let data = UserDefaults.standard.data(forKey: key),
              let memory = try? JSONDecoder().decode(ReminderMemory.self, from: data)
        else { return ReminderMemory() }
        return memory
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    /// Whether this window was already warned at `level` in its current period.
    func hasWarned(_ window: UsageWindow, at level: Double) -> Bool {
        guard let entry = warned[window.id], entry.level >= level else { return false }
        switch (entry.resetsAt, window.resetsAt) {
        case (nil, nil): return true
        case let (before?, now?): return abs(before.timeIntervalSince(now)) < 900
        default: return false
        }
    }
}

/// What Agent Buddy needs to open an agent window's prompts.
struct WindowInfo: Equatable {
    var title: String?
    var project: String?
    var path: String?
    /// When its jobs finished, oldest first.
    var finished: [Date]
}

/// The agent windows kept for their history, in UserDefaults.
enum ArchiveStore {
    private static let key = "sessionArchive"

    static func load() -> SessionArchive {
        guard let data = UserDefaults.standard.data(forKey: key),
              let archive = try? JSONDecoder().decode(SessionArchive.self, from: data)
        else { return SessionArchive() }
        return archive
    }

    static func save(_ archive: SessionArchive) {
        if let data = try? JSONEncoder().encode(archive) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

enum JobHistory {
    private static let key = "recentJobs"

    static func load() -> [JobEvent] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let jobs = try? JSONDecoder().decode([JobEvent].self, from: data)
        else { return [] }
        return jobs
    }

    static func save(_ jobs: [JobEvent]) {
        if let data = try? JSONEncoder().encode(jobs) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

/// The token ledger, made on first use off the main thread (finding the logs
/// can ask the login shell where they are).
final class LedgerBox: @unchecked Sendable {
    private let lock = NSLock()
    private var ledger: TokenLedger?

    func get() -> TokenLedger {
        lock.lock()
        defer { lock.unlock() }
        if let ledger {
            return ledger
        }
        let made = TokenLedger(roots: .standard(), cacheURL: Environment.workDirectory.appendingPathComponent("token-ledger.json"))
        ledger = made
        return made
    }
}

/// One counter per server, each with its own cache file.
final class RemoteBox: @unchecked Sendable {
    private let lock = NSLock()
    private var sources: [String: RemoteTokenSource] = [:]

    func get(_ host: String) -> RemoteTokenSource {
        lock.lock()
        defer { lock.unlock() }
        if let source = sources[host] {
            return source
        }
        let safe = String(host.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : "_" })
        let source = RemoteTokenSource(
            host: host, cacheURL: Environment.workDirectory.appendingPathComponent("remote-tokens-\(safe).json"))
        sources[host] = source
        return source
    }
}

/// How the last count of a server went.
struct RemoteStatus: Equatable {
    var updated: Date?
    var error: String?
    var counting = false
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var readings: [Agent: AgentReading] = [:]
    @Published private(set) var errors: [Agent: String] = [:]
    @Published private(set) var refreshing: Set<Agent> = []
    @Published private(set) var jobs: [JobEvent] = []
    @Published private(set) var now = Date()
    @Published private(set) var lastRefresh: Date?
    /// OpenAI's resets of everyone's Codex limits, from codex-reset.com.
    @Published private(set) var codexResets: CodexResetForecast?
    @Published private(set) var notificationStatus: NotificationStatus = .unknown
    /// Every counted call of the last weeks; nil until the first count is done.
    @Published private(set) var tokenEntries: [TokenEntry]?
    @Published private(set) var countingTokens = false
    @Published private(set) var tokensCountedAt: Date?
    @Published private(set) var remoteStatus: [String: RemoteStatus] = [:]
    /// Each server's live connection, which brings its finished jobs.
    @Published private(set) var remoteLive: [String: RemoteSessionStream.Status] = [:]
    private var streams: [String: RemoteSessionStream] = [:]
    private let ledger = LedgerBox()
    private let remotes = RemoteBox()
    private var localEntries: [TokenEntry]?
    private var remoteEntries: [String: [TokenEntry]] = [:]
    private var lastRemoteCount: Date?

    let settings: AppSettings
    let notifier: Notifier
    /// Reminders and the status, to the iPhone and Apple Watch.
    let phone: PhoneLink
    /// Redraws the menu bar.
    var onChange: (() -> Void)?
    /// Opens an agent window's history; jumps to where it runs.
    var onShowWindow: ((_ key: String, _ info: WindowInfo, _ focus: String?) -> Void)?
    var onJumpWindow: ((_ key: String, _ info: WindowInfo) -> Void)?
    /// A job finished in an agent window: its key.
    var onJobFinished: ((_ key: String) -> Void)?
    /// Every agent window that finished a job, kept when the list is cleared.
    @Published private(set) var archive = SessionArchive()
    /// Each job's tokens, for Token usage ▸ By job.
    let jobUsage = JobUsageStore()
    /// The agents in the middle of a turn now.
    @Published private(set) var working: [WorkingSession] = []
    private let awake = AwakeKeeper()
    private lazy var lockScreen = LockScreenStatus(notifier: notifier)
    private var workingTimer: Timer?
    /// Whether the Mac is being kept awake now.
    @Published private(set) var keepingAwake = false

    private let watcher = TranscriptWatcher()
    /// Gemini CLI, Qwen Code, OpenCode, Cursor's agent and DeepSeek Harness, through their logs.
    private let logWatcher = AgentLogWatcher()
    private var memory = ReminderMemory.load()
    private var lastAttempt: [Agent: Date] = [:]
    private var codexResetsAsked: Date?
    private var codexResetsBusyUntil: Date?
    private var askingCodexResets = false
    private var refreshTimer: Timer?
    private var clockTimer: Timer?
    private var resetTimer: Timer?
    private var tokenTimer: Timer?
    private var subscriptions: Set<AnyCancellable> = []
    private var wakeObserver: NSObjectProtocol?

    init(settings: AppSettings, notifier: Notifier) {
        self.settings = settings
        self.notifier = notifier
        phone = PhoneLink(settings: settings)
        jobs = JobHistory.load()
        archive = ArchiveStore.load()
        // Jobs listed before the archive existed are kept in it too.
        let known = Set(archive.entries.flatMap { $0.jobs.map(\.id) })
        let missing = jobs.filter { !known.contains($0.id) }
        if !missing.isEmpty {
            for job in missing.reversed() {
                archive.record(job)
            }
            ArchiveStore.save(archive)
        }
    }

    func start() {
        let everyRead = UserDefaults.standard.bool(forKey: "debugWatcher")
        watcher.debugLog = { message in
            if everyRead || !message.hasPrefix("read ") {
                Diagnostics.log(message)
            }
        }
        watcher.onJob = { [weak self] event in
            Task { @MainActor in self?.handle(job: event) }
        }
        watcher.onMissed = { [weak self] event in
            Task { @MainActor in self?.handleMissed(event) }
        }
        watcher.onUsage = { [weak self] reading in
            Task { @MainActor in self?.applyLive(reading) }
        }
        watcher.onWorkingChange = { [weak self] in
            Task { @MainActor in self?.refreshWorking() }
        }
        watcher.start()
        logWatcher.debugLog = watcher.debugLog
        logWatcher.onJob = { [weak self] event in
            Task { @MainActor in self?.handle(job: event) }
        }
        logWatcher.onWorkingChange = { [weak self] in
            Task { @MainActor in self?.refreshWorking() }
        }
        logWatcher.start()
        lockScreen.enabled = { [weak self] in self?.settings.lockScreenStatus ?? false }
        lockScreen.start()
        // A turn's last work ages; a quiet one stops counting after a while.
        workingTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshWorking() }
        }
        workingTimer?.tolerance = 3
        importLogOnce()
        notifier.forward = { [weak self] reminder in self?.phone.send(reminder) }
        phone.makeSnapshot = { [weak self] in self?.remoteSnapshot() }
        phone.start()
        // Agent Buddy Remote shows token totals: count them now and then, not only
        // while the statistics page is open (servers at most every half hour).
        tokenTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.countTokensForPhone() }
        }
        tokenTimer?.tolerance = 60
        countTokensForPhone()
        refreshAll(force: true)
        scheduleRefreshTimer()
        clockTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        clockTimer?.tolerance = 5
        scheduleResetTimer()

        settings.$refreshMinutes.dropFirst().removeDuplicates().sink { [weak self] _ in
            Task { @MainActor in self?.scheduleRefreshTimer() }
        }.store(in: &subscriptions)
        // A server ticked or unticked in Settings is watched (or let go) and shows
        // up in the statistics at once.
        settings.$remoteHosts.dropFirst().removeDuplicates().sink { [weak self] _ in
            Task { @MainActor in
                self?.syncStreams()
                self?.publishTokens()
                if self?.tokenEntries != nil {
                    self?.refreshTokens(force: true)
                }
            }
        }.store(in: &subscriptions)
        syncStreams()
        settings.objectWillChange.sink { [weak self] _ in
            // After the change lands: read newly tracked agents, redraw the menu bar.
            Task { @MainActor in
                guard let self else { return }
                for agent in self.settings.trackedAgents where self.readings[agent] == nil {
                    self.refresh(agent)
                }
                self.applyWorking()
                self.onChange?()
            }
        }.store(in: &subscriptions)
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                self?.tick()
                self?.refreshAll(force: true)
            }
        }
    }

    // MARK: - Reading the limits

    func refreshAll(manual: Bool = false, force: Bool = false) {
        for agent in settings.trackedAgents {
            refresh(agent, manual: manual, force: force)
        }
        refreshCodexResets(manual: manual)
    }

    // MARK: - Everyone's Codex resets

    /// Every 10 minutes at most, or a minute after the last when asked by
    /// hand: the site asks for no more than once a minute, and resets come days apart.
    func refreshCodexResets(manual: Bool = false) {
        guard settings.codexResets, settings.isTracked(.codex), !askingCodexResets else { return }
        let now = Date()
        if let until = codexResetsBusyUntil, now < until {
            return
        }
        if let asked = codexResetsAsked, now.timeIntervalSince(asked) < (manual ? 60 : 600) {
            return
        }
        codexResetsAsked = now
        askingCodexResets = true
        Task.detached(priority: .utility) { [weak self] in
            let result = CodexResetSource.fetch()
            await self?.finishCodexResets(result)
        }
    }

    private func finishCodexResets(_ result: Result<CodexResetForecast, CodexResetSource.Failure>) {
        askingCodexResets = false
        switch result {
        case .success(let forecast):
            codexResets = forecast
            noticeCodexReset(forecast)
        case .failure(.busy(let wait)):
            codexResetsBusyUntil = Date().addingTimeInterval(max(wait ?? 900, 60))
            Diagnostics.log("codex-reset.com asked to wait \(Int(wait ?? 900)) s")
        case .failure(.unreadable(let why)):
            Diagnostics.log("codex-reset.com: \(why)")
        }
    }

    /// A reset newer than the last one seen: Codex's limits are read again, and
    /// you're told if you asked. The first look only learns the last reset.
    private func noticeCodexReset(_ forecast: CodexResetForecast) {
        guard let at = forecast.lastResetAt else { return }
        let key = "codexResets.lastSeen"
        let seen = settings.defaults.object(forKey: key) as? Date
        if let seen, at <= seen {
            return
        }
        settings.defaults.set(at, forKey: key)
        guard seen != nil else { return }
        Diagnostics.log("OpenAI reset everyone's Codex limits at \(at)")
        refresh(.codex, force: true)
        // Only fresh news: a reset hours old (the Mac slept) stays quiet.
        guard settings.notifyCodexResets, Date().timeIntervalSince(at) < 3 * 3600 else { return }
        let body = "OpenAI reset everyone's Codex usage limits at \(Format.clock(at, now: Date())). Data: codex-reset.com"
        notifier.post(
            id: "codex-global-reset-\(Int(at.timeIntervalSince1970))", title: "Codex limits reset", body: body, agent: .codex,
            phone: PhoneReminder(title: "Codex limits reset", details: [body], tags: ["arrows_counterclockwise"]))
    }

    func refresh(_ agent: Agent, manual: Bool = false, force: Bool = false) {
        guard !frozen, settings.isTracked(agent), !refreshing.contains(agent) else { return }
        // Claude Code's usage lookup refuses callers that ask too often.
        let spacing: TimeInterval = manual ? 10 : 45
        if !force, let last = lastAttempt[agent], Date().timeIntervalSince(last) < spacing {
            return
        }
        lastAttempt[agent] = Date()
        refreshing.insert(agent)
        Task.detached(priority: .utility) { [weak self] in
            let result: Result<AgentReading, Error>
            do {
                result = .success(try UsageReaders.read(agent))
            } catch {
                result = .failure(error)
            }
            await self?.finish(agent, result)
        }
    }

    /// The popover opened: catch up if the last read is a while ago.
    func popoverOpened() {
        now = Date()
        refreshAll()
        notifier.status { [weak self] status in self?.notificationStatus = status }
    }

    private func finish(_ agent: Agent, _ result: Result<AgentReading, Error>) {
        refreshing.remove(agent)
        lastRefresh = Date()
        switch result {
        case .success(let reading):
            readings[agent] = reading
            errors[agent] = nil
            evaluate(reading)
        case .failure(let error):
            errors[agent] = error.localizedDescription
        }
        phone.statusChanged()
        onChange?()
    }

    /// A rate-limit snapshot Codex just wrote to its session log.
    private func applyLive(_ reading: AgentReading) {
        guard settings.isTracked(reading.agent) else { return }
        var merged = readings[reading.agent] ?? AgentReading(agent: reading.agent, fetchedAt: .distantPast)
        guard reading.fetchedAt > merged.fetchedAt else { return }
        func bucket(_ id: String) -> String { id.split(separator: ".").prefix(2).joined(separator: ".") }
        let buckets = Set(reading.windows.map { bucket($0.id) })
        merged.windows.removeAll { buckets.contains(bucket($0.id)) }
        merged.windows += reading.windows
        merged.windows.sort { ($0.id.hasPrefix("codex.codex.") ? 0 : 1, $0.id) < ($1.id.hasPrefix("codex.codex.") ? 0 : 1, $1.id) }
        merged.plan = reading.plan ?? merged.plan
        merged.fetchedAt = reading.fetchedAt
        readings[reading.agent] = merged
        errors[reading.agent] = nil
        evaluate(merged)
        phone.statusChanged()
        onChange?()
    }

    private func scheduleRefreshTimer() {
        refreshTimer?.invalidate()
        let interval = TimeInterval(max(1, settings.refreshMinutes) * 60)
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshAll() }
        }
        refreshTimer?.tolerance = 10
    }

    // MARK: - Reminders

    private func evaluate(_ reading: AgentReading) {
        let now = Date()
        if settings.limitWarnings {
            for window in reading.windows where !window.hasReset(at: now) {
                let level: Double = window.usedPercent >= 100 ? 100 : (window.usedPercent >= 90 ? 90 : 0)
                guard level > 0, !memory.hasWarned(window, at: level) else { continue }
                memory.warned[window.id] = .init(level: level, resetsAt: window.resetsAt)
                postLimitWarning(reading.agent, window, level: level)
            }
        }
        if reading.agent == .claude, let session = reading.windows.first(where: { $0.kind == .session }) {
            if let pending = memory.pendingSessionReset, pending.resetsAt <= now {
                fireSessionReset(pending, now: now)
            }
            if let resetsAt = session.resetsAt, resetsAt > now, session.usedPercent > 0 {
                memory.pendingSessionReset = .init(resetsAt: resetsAt, usedPercent: session.usedPercent)
                scheduleResetTimer()
            }
        }
        memory.save()
    }

    private func tick() {
        now = Date()
        if let pending = memory.pendingSessionReset, now >= pending.resetsAt.addingTimeInterval(1) {
            fireSessionReset(pending, now: now)
            memory.save()
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                self?.refresh(.claude, force: true)
            }
        }
        onChange?()
    }

    /// A one-shot timer at the session's reset, so the reminder is on time.
    private func scheduleResetTimer() {
        resetTimer?.invalidate()
        guard let resetsAt = memory.pendingSessionReset?.resetsAt else { return }
        let timer = Timer(fire: resetsAt.addingTimeInterval(2), interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        resetTimer = timer
    }

    private func fireSessionReset(_ pending: ReminderMemory.PendingReset, now: Date) {
        memory.pendingSessionReset = nil
        guard memory.lastSessionReminder != pending.resetsAt else { return }
        memory.lastSessionReminder = pending.resetsAt
        // Only a fresh reset is news; one long past (the Mac slept, the app was off) stays quiet.
        guard settings.sessionResetReminder, now.timeIntervalSince(pending.resetsAt) < 30 * 60 else { return }
        var body = "Your 5-hour session limit is fully available again. It was \(Int(pending.usedPercent.rounded()))% used."
        if let week = readings[.claude]?.windows.first(where: { $0.kind == .weekly }),
           week.usedPercent >= 100, let weekReset = week.resetsAt, weekReset > now {
            body += " Your weekly limit is still used up until \(Format.clock(weekReset, now: now))."
        }
        notifier.post(
            id: "claude-session-reset-\(Int(pending.resetsAt.timeIntervalSince1970))",
            title: "Claude session reset", body: body, agent: .claude,
            phone: PhoneReminder(title: "Claude session reset", details: [body], tags: ["arrows_counterclockwise"]))
    }

    private func postLimitWarning(_ agent: Agent, _ window: UsageWindow, level: Double) {
        let now = Date()
        let name = Format.limitName(agent, window)
        let reset = window.resetsAt.map { "Resets in \(Format.countdown(to: $0, from: now)) (\(Format.clock($0, now: now)))." }
            ?? "No reset time reported."
        let id = "limit-\(window.id)-\(Int(level))-\(Int(window.resetsAt?.timeIntervalSince1970 ?? 0))"
        if level >= 100 {
            if let last = memory.lastLimitNotice[agent.rawValue], now.timeIntervalSince(last) < 900 {
                return
            }
            memory.lastLimitNotice[agent.rawValue] = now
            let title = "\(name) used up"
            notifier.post(id: id, title: title, body: reset, agent: agent,
                          phone: PhoneReminder(title: title, details: [reset], tags: ["no_entry"], priority: 4))
        } else {
            let title = "\(name) at \(Int(window.usedPercent.rounded()))%"
            notifier.post(id: id, title: title, body: reset, agent: agent,
                          phone: PhoneReminder(title: title, details: [reset], tags: ["warning"]))
        }
    }

    // MARK: - Finished jobs

    /// A job that finished while Agent Buddy wasn't watching (not running, or
    /// a server out of reach), minutes ago: listed and reminded of as usual,
    /// unless it was seen already (before a restart, say), cleared or not.
    func handleMissed(_ job: JobEvent) {
        guard !archive.contains(job) else { return }
        Diagnostics.log("job \(job.id) finished while Agent Buddy wasn't watching")
        handle(job: job)
    }

    private func handle(job: JobEvent) {
        archive.record(job)
        archive.prune()
        ArchiveStore.save(archive)
        jobs.removeAll { $0.id == job.id }
        jobs.insert(job, at: 0)
        // The menu bar's number counts these until they're cleared.
        if jobs.count > 99 {
            jobs.removeLast(jobs.count - 99)
        }
        JobHistory.save(jobs)
        Diagnostics.log("job \(job.id) \(job.outcome.rawValue); \(jobs.count) in the list")
        onJobFinished?(JobWindow.key(job))
        if settings.notifiesJobs(job.agent), let window = jobWindows.first(where: { $0.key == JobWindow.key(job) }) {
            // One reminder per agent window: a second job in the same window
            // replaces the first one's reminder with "2 jobs finished".
            if job.outcome == .limited {
                let last = memory.lastLimitNotice[job.agent.rawValue]
                if last.map({ Date().timeIntervalSince($0) >= 900 }) ?? true {
                    memory.lastLimitNotice[job.agent.rawValue] = Date()
                    memory.save()
                    notifier.postWindow(window, includeSummary: settings.showSummaries)
                }
            } else {
                notifier.postWindow(window, includeSummary: settings.showSummaries)
            }
        }
        phone.statusChanged()
        // A finished turn moves the numbers; Codex reports its own live.
        if job.agent != .codex {
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                self?.refresh(job.agent)
            }
        }
        onChange?()
    }

    /// Counts the tokens written to the session logs since the last count: this
    /// Mac's first, then each server's (at most every `serverSpacing` seconds unless forced).
    func refreshTokens(force: Bool = false, serverSpacing: TimeInterval = 60) {
        guard !frozen, !countingTokens else { return }
        if !force, let last = tokensCountedAt, Date().timeIntervalSince(last) < 20 {
            return
        }
        countingTokens = true
        let ledger = self.ledger
        let remotes = self.remotes
        let hosts = settings.remoteHosts
        let serversDue = !hosts.isEmpty
            && (force || lastRemoteCount.map { Date().timeIntervalSince($0) >= serverSpacing } ?? true)
        if serversDue {
            lastRemoteCount = Date()
        }
        Task.detached(priority: .utility) { [weak self] in
            let local = ledger.get().refresh()
            await self?.setLocal(local)
            for host in hosts {
                let source = remotes.get(host)
                // What it said last time shows at once; then ask it for what's new.
                await self?.setRemote(host, entries: source.cachedEntries(), status: nil)
                guard serversDue else { continue }
                await self?.markCounting(host)
                switch source.refresh() {
                case .success(let entries):
                    await self?.setRemote(host, entries: entries, status: RemoteStatus(updated: Date(), error: nil))
                case .failure(let error):
                    await self?.setRemote(host, entries: source.cachedEntries(), status: RemoteStatus(updated: nil, error: error.message))
                }
            }
            await self?.finishCounting()
        }
    }

    /// One live connection per server in Settings; its log lines go to the same
    /// watcher as this Mac's, so a job finishing there reminds you too.
    private func syncStreams() {
        let wanted = Set(settings.remoteHosts)
        for (host, stream) in streams where !wanted.contains(host) {
            stream.stop()
            streams[host] = nil
            remoteLive[host] = nil
            watcher.forget(source: host)
        }
        for host in settings.remoteHosts where streams[host] == nil {
            let stream = RemoteSessionStream(host: host)
            let watcher = self.watcher
            stream.onLines = { path, agent, lines, prime, skew in
                watcher.feed(source: host, path: path, agent: agent, lines: lines, prime: prime, skew: skew)
            }
            stream.onNames = { names in
                watcher.feedNames(source: host, names: names)
            }
            stream.onStatus = { [weak self] status in
                Task { @MainActor in
                    guard let self, self.streams[host] != nil else { return }
                    if self.remoteLive[host] != status {
                        Diagnostics.log("server \(host): \(status)")
                    }
                    self.remoteLive[host] = status
                }
            }
            streams[host] = stream
            stream.start()
        }
    }

    /// Disconnects from every server (Agent Buddy is quitting).
    func stopStreams() {
        for stream in streams.values {
            stream.stop()
        }
        streams = [:]
    }

    private func setLocal(_ entries: [TokenEntry]) {
        localEntries = entries
        publishTokens()
    }

    private func markCounting(_ host: String) {
        remoteStatus[host, default: RemoteStatus()].counting = true
    }

    private func setRemote(_ host: String, entries: [TokenEntry], status: RemoteStatus?) {
        remoteEntries[host] = entries
        if var status {
            status.updated = status.updated ?? remoteStatus[host]?.updated
            remoteStatus[host] = status
        }
        publishTokens()
    }

    /// This Mac's entries and those of the servers still in Settings.
    private func publishTokens() {
        guard let localEntries else { return }
        let hosts = Set(settings.remoteHosts)
        tokenEntries = localEntries + remoteEntries.filter { hosts.contains($0.key) }.flatMap(\.value)
        phone.statusChanged()
    }

    private func finishCounting() {
        tokensCountedAt = Date()
        countingTokens = false
    }

    /// Takes one job off the list (and its notification out of Notification Center).
    func removeJob(_ id: String) {
        notifier.removeDelivered([id])
        jobs.removeAll { $0.id == id }
        JobHistory.save(jobs)
        phone.statusChanged(urgent: true)
        onChange?()
    }

    /// Finished jobs folded by agent window; the badge counts these.
    var jobWindows: [JobWindow] {
        JobWindow.fold(jobs)
    }

    /// Takes one agent window's jobs off the list, and its reminder out of Notification Center.
    func removeWindow(_ key: String) {
        notifier.removeDelivered(["window-\(key)"] + jobs.filter { JobWindow.key($0) == key }.map(\.id))
        jobs.removeAll { JobWindow.key($0) == key }
        JobHistory.save(jobs)
        phone.statusChanged(urgent: true)
        onChange?()
    }

    /// Empties the finished-jobs list, which also takes the number off the menu bar.
    func clearJobs() {
        notifier.removeDelivered(jobs.map(\.id) + jobWindows.map { "window-\($0.key)" })
        jobs = []
        JobHistory.save(jobs)
        phone.statusChanged(urgent: true)
        onChange?()
    }

    /// Shows jobs without saving them (snapshots only).
    func preview(jobs: [JobEvent]) {
        self.jobs = jobs
    }

    /// Shows a forecast without asking the site (snapshots only).
    func preview(codexResets forecast: CodexResetForecast) {
        codexResets = forecast
    }

    /// Showing sample data (the tour's pictures): nothing is read or asked, so it stays as shown.
    private(set) var frozen = false

    /// Shows limits without asking the agents (the tour's pictures only).
    func preview(readings: [Agent: AgentReading]) {
        frozen = true
        self.readings = readings
        errors = [:]
        lastRefresh = Date()
    }

    /// Shows token counts without reading any log (the tour's pictures only).
    func preview(tokens: [TokenEntry]) {
        tokenEntries = tokens
        tokensCountedAt = Date()
    }

    /// Shows agents at work, and whether the Mac's kept awake (the tour's pictures only).
    func preview(working: [WorkingSession], keepingAwake: Bool) {
        self.working = working
        self.keepingAwake = keepingAwake
    }

    /// Shows servers as connected or not, without connecting (the tour's pictures only).
    func preview(servers: [String: RemoteSessionStream.Status]) {
        remoteLive = servers
    }

    func sendTestNotification() {
        let job = JobEvent(
            id: "test-\(Date().timeIntervalSince1970)", agent: .claude, outcome: .completed, sessionID: "test",
            title: "Test reminder from Agent Buddy", project: "head_show",
            summary: "This is how a finished job will look.", startedAt: Date().addingTimeInterval(-192), finishedAt: Date())
        notifier.postWindow(JobWindow(key: "test", jobs: [job]), includeSummary: true)
    }

    func updateNotificationStatus(_ status: NotificationStatus) {
        notificationStatus = status
    }

    // MARK: - Agents at work

    /// Asks the watcher who's in a turn; a session quiet a while counts only if
    /// its agent's process is still there (on this Mac).
    func refreshWorking() {
        let others = logWatcher
        watcher.workingSessions { [weak self] watched in
            others.workingSessions { more in self?.refreshWorking(watched + more) }
        }
    }

    /// Who's in a turn, from both watchers; a session quiet a while counts only if
    /// its agent's process is still there (on this Mac).
    private nonisolated func refreshWorking(_ sessions: [WorkingSession]) {
        let now = Date()
        let quiet = sessions.filter { $0.source == nil && now.timeIntervalSince($0.lastWork) >= WorkingRule.quiet }
        var alive = Set<String>()
        if !quiet.isEmpty {
            let table = ProcessTable.snapshot()
            for session in quiet {
                if !table.agentProcesses(session.agent, in: [session.folder].compactMap { $0 }).isEmpty {
                    alive.insert(session.id)
                }
            }
        }
        let working = WorkingRule.working(sessions, now: now) { alive.contains($0.id) }
        Task { @MainActor [weak self] in self?.setWorking(working) }
    }

    private func setWorking(_ working: [WorkingSession]) {
        if working != self.working {
            self.working = working
        }
        applyWorking()
    }

    /// Keeps the Mac awake, and the lock screen's list, as the settings say.
    private func applyWorking() {
        awake.update(working: working, enabled: settings.keepAwake, display: settings.keepDisplayAwake)
        if keepingAwake != awake.isHolding {
            keepingAwake = awake.isHolding
        }
        lockScreen.update(working)
    }

    // MARK: - Agent windows

    /// Shows the prompts asked in an agent window, and where it runs.
    /// - Parameters:
    ///   - focus: a prompt to show open.
    ///   - path: its session log, when the archive doesn't know it.
    func showWindow(_ key: String, focus: String? = nil, path: String? = nil) {
        var info = windowInfo(key)
        info.path = info.path ?? path
        onShowWindow?(key, info, focus)
    }

    /// Goes straight to where the agent window runs.
    func jumpToWindow(_ key: String) {
        onJumpWindow?(key, windowInfo(key))
    }

    /// From the archive, which has every job the list ever showed.
    func windowInfo(_ key: String) -> WindowInfo {
        let entry = archive.entry(key)
        let listed = jobs.filter { JobWindow.key($0) == key }
        let finished = Set((entry?.jobs.map(\.finishedAt) ?? []) + listed.map(\.finishedAt)).sorted()
        return WindowInfo(
            title: entry?.title ?? listed.first?.title, project: entry?.project ?? listed.first?.project,
            path: entry?.transcriptPath ?? listed.lazy.compactMap(\.transcriptPath).first, finished: finished)
    }

    /// What a window's session log says about it, for its entry in the list.
    func learn(_ key: String, from history: SessionHistory) {
        jobUsage.update(key: key, source: archive.entry(key)?.source, history: history)
        let title = history.title ?? history.turns.first.map { String(($0.text.split(separator: "\n").first ?? "").prefix(80)) }
        let project = history.cwd.map { URL(fileURLWithPath: $0).lastPathComponent }
        if archive.learn(key, title: title, project: project, path: history.logPath) {
            ArchiveStore.save(archive)
        }
    }

    /// Once: the windows whose jobs finished before this list kept them, read
    /// back from Agent Buddy's own log, with their session logs and names.
    private func importLogOnce() {
        let flag = "archiveImportedLog.v2"
        guard !UserDefaults.standard.bool(forKey: flag) else { return }
        UserDefaults.standard.set(true, forKey: flag)
        let servers = settings.remoteHosts
        Task.detached(priority: .utility) { [weak self] in
            var text = ""
            for name in ["agentbuddy.old.log", "agentbuddy.log"] {
                text += ((try? String(contentsOf: Diagnostics.folder.appendingPathComponent(name), encoding: .utf8)) ?? "") + "\n"
            }
            let imported = LogImport(log: text)
            let cutoff = Date().addingTimeInterval(-SessionArchive.keepDays * 86400)
            var jobs: [JobEvent] = []
            var read: [String: SessionHistory] = [:]
            for var job in imported.jobs where job.finishedAt > cutoff {
                let local = SessionHistoryReader.locate(agent: job.agent, sessionID: job.sessionID)
                switch imported.place(job.agent, job.sessionID) {
                case .server?:
                    break
                case .here?:
                    // Opened on this Mac; a log since deleted has nothing to show.
                    guard let local else { continue }
                    job.transcriptPath = local
                case nil:
                    if let local {
                        job.transcriptPath = local
                    } else if servers.count == 1 {
                        // Not on this Mac: on the one server Agent Buddy watches.
                        job.source = servers[0]
                    } else {
                        continue
                    }
                }
                let key = JobWindow.key(job)
                if let path = job.transcriptPath, read[key] == nil,
                   case .success(let history) = SessionHistoryReader.read(agent: job.agent, path: path) {
                    read[key] = history
                }
                jobs.append(job)
            }
            await self?.mergeImported(jobs, histories: read, places: imported)
        }
    }

    private func mergeImported(_ jobs: [JobEvent], histories: [String: SessionHistory], places: LogImport) {
        // An earlier import put a session of this Mac whose log was gone on the server: take it back.
        for entry in archive.entries where entry.source != nil && places.place(entry.agent, entry.sessionID) == .here {
            archive.remove(entry.key)
        }
        let known = Set(archive.entries.flatMap { $0.jobs.map(\.id) })
        let missing = jobs.filter { !known.contains($0.id) }
        for job in missing {
            archive.record(job)
        }
        for (key, history) in histories {
            _ = archive.learn(
                key, title: history.title ?? history.turns.first.map { String(($0.text.split(separator: "\n").first ?? "").prefix(80)) },
                project: history.cwd.map { URL(fileURLWithPath: $0).lastPathComponent }, path: history.logPath)
        }
        archive.prune()
        ArchiveStore.save(archive)
        Diagnostics.log("kept \(Set(missing.map(JobWindow.key)).count) agent windows from the log")
    }

    /// Takes a window off the history list (its session log stays where it is).
    func forgetWindow(_ key: String) {
        archive.remove(key)
        ArchiveStore.save(archive)
    }

    /// Shows windows without saving them (snapshots only).
    func preview(archive: SessionArchive) {
        self.archive = archive
    }

    // MARK: - Agent Buddy Remote

    private func countTokensForPhone() {
        guard settings.phonePairing != nil, settings.phoneShareStatus else { return }
        refreshTokens(serverSpacing: 1800)
    }

    /// What Agent Buddy Remote on the iPhone and Apple Watch shows: the limits as
    /// on the cards, the finished jobs by agent window, and the token totals.
    func remoteSnapshot(at now: Date = Date()) -> RemoteSnapshot {
        let agents = settings.trackedAgents.map { agent -> RemoteSnapshot.AgentUsage in
            let reading = readings[agent]
            let main = Set(reading?.menuWindows.map(\.id) ?? [])
            let limits = (reading?.windows ?? []).map { window in
                RemoteSnapshot.Limit(
                    id: window.id, title: window.title, short: Self.shortName(window),
                    percent: window.percent(at: now).rounded(),
                    // To the minute, so a reset time read a second later isn't news.
                    resetsAt: window.resetsAt.map { Date(timeIntervalSince1970: ($0.timeIntervalSince1970 / 60).rounded() * 60) },
                    main: main.contains(window.id))
            }
            // A reader's error can name local paths; only a plain one goes.
            let problem = reading == nil ? errors[agent].map { error in
                error.contains("/") || error.count > 120 ? "Agent Buddy couldn't read these limits." : error
            } : nil
            return RemoteSnapshot.AgentUsage(
                agent: agent.rawValue, name: agent.displayName, plan: reading?.plan, limits: limits, problem: problem)
        }
        let windows = jobWindows
        let finished = windows.prefix(12).map { window -> RemoteSnapshot.FinishedWindow in
            let job = window.latest
            let detail = PushComposer.message(
                identifying: Notifier.identifying(job), details: Notifier.details(job), summary: job.summary,
                includeTitles: settings.phoneIncludeTitles, includeSummaries: settings.phoneIncludeSummaries)
            return RemoteSnapshot.FinishedWindow(
                id: ReminderTag.window(window.key), agent: job.agent.rawValue,
                headline: PushComposer.headline(client: job.agent.clientName, count: window.count, outcome: job.outcome.rawValue),
                detail: String(detail.prefix(160)), count: window.count, outcome: job.outcome.rawValue,
                finishedAt: job.finishedAt)
        }
        let tokens = tokenEntries.map { entries in
            RemoteSnapshot.Tokens(
                today: TokenStatistics.summary(entries, period: .day, now: now).total.total,
                week: TokenStatistics.summary(entries, period: .week, now: now).total.total,
                month: TokenStatistics.summary(entries, period: .month, now: now).total.total)
        }
        // The Mac's name often holds yours: it goes only with names allowed.
        return RemoteSnapshot(
            at: now, mac: settings.phoneIncludeTitles ? PhoneLink.macName : "your Mac", agents: agents,
            windows: Array(finished), windowCount: windows.count, tokens: tokens)
    }

    /// A limit's name on Apple Watch: "5h", "Week", "Opus", "Month".
    static func shortName(_ window: UsageWindow) -> String {
        switch window.kind {
        case .session: return "5h"
        case .weekly: return "Week"
        case .monthly: return window.id == "copilot.premium_interactions" ? "Month" : String(window.title.prefix(5))
        case .weeklyModel:
            return window.title.components(separatedBy: "· ").last.map { String($0.prefix(6)) } ?? "Week"
        case .other:
            return String(window.title.prefix(5))
        }
    }

    // MARK: - The menu bar

    func menuSegments() -> [MenuBarRenderer.Segment] {
        settings.trackedAgents.map { agent in
            guard let reading = readings[agent] else {
                return .init(agent: agent, label: agent.menuLabel, values: [.init(tag: nil, text: errors[agent] == nil ? "…" : "!", severity: nil)])
            }
            return .init(agent: agent, label: agent.menuLabel, values: reading.menuValues(at: now))
        }
    }

    func tooltip() -> String {
        let lines = settings.trackedAgents.map { agent -> String in
            guard let reading = readings[agent] else {
                return "\(agent.displayName): \(errors[agent] ?? "reading…")"
            }
            let parts = reading.windows.map { "\($0.title) \(Int($0.percent(at: now).rounded()))%" }
            return "\(agent.displayName): " + (parts.isEmpty ? "no limits" : parts.joined(separator: ", "))
        }
        var text = lines.isEmpty ? "Agent Buddy" : lines.joined(separator: "\n")
        let windows = jobWindows.count
        if windows > 0 {
            text += "\nFinished jobs in \(windows) agent window\(windows == 1 ? "" : "s"). Click to see them."
        }
        return text
    }
}
