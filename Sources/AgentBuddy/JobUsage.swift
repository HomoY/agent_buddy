import AppKit
import AgentBuddyCore
import SwiftUI

/// Each job's tokens: every session log on this Mac from the last 31 days, and
/// the servers' windows, read once and read again only when they change (a
/// server's at most every 10 minutes).
@MainActor
final class JobUsageStore: ObservableObject {
    private struct Local: Sendable {
        var session: UsageSession
        var size: UInt64
        var modified: Date
    }

    private struct Remote: Sendable {
        var session: UsageSession
        var read: Date
    }

    @Published private(set) var loading = false
    /// Showing sample sessions (the tour's pictures): no log is read.
    private var previewing = false
    @Published private(set) var readAt: Date?
    /// Servers that didn't answer.
    @Published private(set) var problems: [String] = []
    @Published private var local: [String: Local] = [:]
    @Published private var remote: [String: Remote] = [:]

    static let days: Double = 31
    static let serverSpacing: TimeInterval = 600

    func refresh(archive: SessionArchive, force: Bool = false) {
        guard !previewing, !loading else { return }
        loading = true
        let now = Date()
        let since = now.addingTimeInterval(-Self.days * 86400)
        let known = local.mapValues { ($0.size, $0.modified) }
        let spacing = Self.serverSpacing
        let servers = archive.entries
            .filter { $0.source != nil && $0.lastFinished > since }
            .filter { entry in force || (remote[entry.key].map { now.timeIntervalSince($0.read) > spacing } ?? true) }
            .map { (key: $0.key, agent: $0.agent, host: $0.source ?? "", path: $0.transcriptPath, session: $0.sessionID) }
        Task.detached(priority: .utility) { [weak self] in
            let logs = SessionHistoryReader.recentLogs(since: since)
            var fresh: [String: Local] = [:]
            for log in logs {
                if let was = known[log.path], was.0 == log.size, was.1 == log.modified {
                    continue
                }
                if case .success(let history) = SessionHistoryReader.read(agent: log.agent, path: log.path) {
                    let key = "\(log.agent.rawValue)||\(history.sessionID)"
                    fresh[log.path] = Local(session: UsageSession(key: key, source: nil, history: history), size: log.size, modified: log.modified)
                }
            }
            var fetched: [String: Remote] = [:]
            var problems: [String] = []
            for server in servers {
                switch RemoteHistory.fetch(host: server.host, agent: server.agent, path: server.path, sessionID: server.session) {
                case .success(let history):
                    fetched[server.key] = Remote(session: UsageSession(key: server.key, source: server.host, history: history), read: Date())
                case .failure(let error):
                    problems.append(error.message)
                }
            }
            await self?.finish(fresh: fresh, listed: Set(logs.map(\.path)), fetched: fetched, problems: problems)
        }
    }

    private func finish(fresh: [String: Local], listed: Set<String>, fetched: [String: Remote], problems: [String]) {
        var local = self.local.filter { listed.contains($0.key) }
        local.merge(fresh) { _, new in new }
        self.local = local
        remote.merge(fetched) { _, new in new }
        self.problems = Array(Set(problems)).sorted()
        readAt = Date()
        loading = false
    }

    /// A server window's history just read by its window: no need to ask again.
    /// Shows these sessions' jobs without reading any log (the tour's pictures only).
    func preview(_ sessions: [UsageSession]) {
        previewing = true
        local = Dictionary(sessions.map { ($0.key, Local(session: $0, size: 0, modified: Date())) }, uniquingKeysWith: { first, _ in first })
        readAt = Date()
    }

    func update(key: String, source: String?, history: SessionHistory) {
        guard let source else { return }
        remote[key] = Remote(session: UsageSession(key: key, source: source, history: history), read: Date())
    }

    func jobs(_ period: StatsPeriod, now: Date) -> [JobTokens] {
        let sessions = local.values.map(\.session) + remote.values.map(\.session)
        var seen = Set<String>()
        return JobStatistics.jobs(sessions, from: period.start(now: now), to: now).filter { seen.insert($0.id).inserted }
    }

    /// Where a job's session log is, to open its window.
    func logPath(of job: JobTokens) -> String? {
        local.values.first { $0.session.key == job.windowKey }?.session.history.logPath
            ?? remote[job.windowKey]?.session.history.logPath
    }

    var isEmpty: Bool { local.isEmpty && remote.isEmpty }
}

// MARK: - The list

/// Token usage ▸ By job: each job of the period with its tokens; click one for
/// each model's input, output and cache, and a link to its prompt.
struct JobsTokenList: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var store: JobUsageStore
    let period: StatsPeriod
    @State private var sort: Sort = .newest
    @State private var expanded: Set<String>

    /// - Parameter expanded: jobs shown open at first (the snapshot mode).
    init(store: JobUsageStore, period: StatsPeriod, expanded: Set<String> = []) {
        self.store = store
        self.period = period
        _expanded = State(initialValue: expanded)
    }

    enum Sort: String, CaseIterable, Identifiable {
        case newest = "Newest"
        case tokens = "Most tokens"
        var id: String { rawValue }
    }

    private static let rowHeight: CGFloat = 40
    private static let maxHeight: CGFloat = 420

    var body: some View {
        let all = store.jobs(period, now: model.now)
        let jobs = sort == .newest ? all : all.sorted { $0.tokens.total > $1.tokens.total }
        let total = jobs.reduce(0) { $0 + $1.tokens.total }
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(jobs.isEmpty ? "No jobs" : "\(jobs.count) job\(jobs.count == 1 ? "" : "s") · \(TokenStatistics.compact(total)) tokens")
                    .uiFont(12, weight: .semibold)
                if store.loading {
                    ProgressView().controlSize(.small).scaleEffect(0.55).frame(width: 12, height: 12)
                }
                Spacer()
                Picker("Sort", selection: $sort) {
                    ForEach(Sort.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .uiFont(11)
            }
            if jobs.isEmpty {
                Text(store.loading && store.isEmpty ? "Reading your session logs…" : "No job used tokens in this period.")
                    .uiFont(12)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(jobs) { job in
                            JobTokensRow(
                                job: job, now: model.now, expanded: expanded.contains(job.id),
                                toggle: {
                                    if expanded.contains(job.id) {
                                        expanded.remove(job.id)
                                    } else {
                                        expanded.insert(job.id)
                                    }
                                },
                                open: { model.showWindow(job.windowKey, focus: job.turnID, path: store.logPath(of: job)) })
                        }
                    }
                }
                .frame(height: min(CGFloat(jobs.count) * (Self.rowHeight + 2) + CGFloat(expanded.count) * 90, Self.maxHeight))
            }
            ForEach(store.problems, id: \.self) { problem in
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .uiFont(10)
                    .foregroundStyle(.orange)
            }
            Text("A job is one prompt and the agent's work on it, sub-agents included, counted as the totals are. Copilot reports tokens per session, so its rows are whole sessions.")
                .uiFont(10)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { store.refresh(archive: model.archive) }
    }
}

struct JobTokensRow: View {
    let job: JobTokens
    let now: Date
    let expanded: Bool
    let toggle: () -> Void
    let open: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                AgentMark(agent: job.agent, size: 16)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 1) {
                    Text(job.prompt)
                        .uiFont(12)
                        .lineLimit(1)
                    Text(facts)
                        .uiFont(10)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(TokenStatistics.compact(job.tokens.total))
                        .uiFont(12, weight: .semibold, digits: true)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .uiFont(8, weight: .semibold)
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: toggle)
            .help(expanded ? "Click to fold it" : "Click for each model's tokens")
            if expanded {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(job.usage) { usage in
                        TokenUseLines(usage: usage)
                    }
                    .textSelection(.enabled)
                    Button(job.wholeSession ? "Show the session's prompts" : "Show this prompt") { open() }
                        .buttonStyle(.link)
                        .uiFont(10.5)
                }
                .padding(.leading, 24)
                .padding(.bottom, 4)
            }
        }
        .padding(.vertical, 4)
    }

    private var facts: String {
        var parts: [String] = []
        if let place = job.project ?? job.title {
            parts.append(place)
        }
        if let source = job.source {
            parts.append("on \(source)")
        }
        parts.append(Calendar.current.isDate(job.at, inSameDayAs: now) ? Format.clock(job.at, now: now) : Format.dayAndTime(job.at))
        if job.wholeSession {
            parts.append("whole session")
        } else {
            parts.append(job.usage.map(\.model).joined(separator: ", "))
        }
        return parts.joined(separator: " · ")
    }
}

/// A model's tokens in two lines: its name and total, then each kind.
struct TokenUseLines: View {
    let usage: ModelTokens

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text(usage.model)
                    .uiFont(10.5, weight: .medium)
                    .lineLimit(1)
                Spacer()
                Text(TokenStatistics.compact(usage.counts.total))
                    .uiFont(10.5, weight: .medium, digits: true)
            }
            Text("in \(TokenStatistics.compact(usage.counts.input)) · out \(TokenStatistics.compact(usage.counts.output)) · cache write \(TokenStatistics.compact(usage.counts.cacheWrite)) · cache read \(TokenStatistics.compact(usage.counts.cacheRead))")
                .uiFont(10, digits: true)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A prompt's tokens as a table: each model's input, output, cache and total.
struct TokenTable: View {
    let usage: [ModelTokens]

    var body: some View {
        Grid(alignment: .trailing, horizontalSpacing: 12, verticalSpacing: 2) {
            GridRow {
                Text("Model").gridColumnAlignment(.leading)
                Text("Input")
                Text("Output")
                Text("Cache write")
                Text("Cache read")
                Text("Total")
            }
            .uiFont(9.5)
            .foregroundStyle(.secondary)
            ForEach(usage) { use in
                GridRow {
                    Text(use.model).lineLimit(1).gridColumnAlignment(.leading)
                    Text(TokenStatistics.compact(use.counts.input))
                    Text(TokenStatistics.compact(use.counts.output))
                    Text(TokenStatistics.compact(use.counts.cacheWrite))
                    Text(TokenStatistics.compact(use.counts.cacheRead))
                    Text(TokenStatistics.compact(use.counts.total)).fontWeight(.semibold)
                }
                .uiFont(10.5, digits: true)
            }
        }
    }
}
