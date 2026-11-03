import AgentBuddyCore
import SwiftUI

extension Agent {
    var tint: Color {
        switch self {
        case .claude: return Color(red: 0.85, green: 0.47, blue: 0.34)
        case .codex: return Color(red: 0.06, green: 0.64, blue: 0.50)
        case .copilot: return Color(red: 0.47, green: 0.33, blue: 0.86)
        // The rest as their chart colours.
        case .deepseek: return Color(red: 0.89, green: 0.29, blue: 0.28)
        case .gemini: return Color(red: 0.16, green: 0.47, blue: 0.84)
        case .opencode: return Color(red: 0.86, green: 0.58, blue: 0.0)
        case .qwen: return Color(red: 0.84, green: 0.32, blue: 0.51)
        case .cursor: return Color(red: 0.0, green: 0.51, blue: 0.0)
        }
    }

    var symbol: String {
        switch self {
        case .claude: return "asterisk"
        case .codex: return "bubble.left.fill"
        case .copilot: return "chevron.left.forwardslash.chevron.right"
        case .deepseek: return "fish.fill"
        case .gemini: return "sparkle"
        case .opencode: return "terminal.fill"
        case .qwen: return "cube.transparent.fill"
        case .cursor: return "cursorarrow"
        }
    }

    var caption: String {
        switch self {
        case .claude: return "Session and weekly plan limits"
        case .codex: return "Codex limits on your ChatGPT plan"
        case .copilot: return "GitHub Copilot, this month"
        default: return "Jobs and tokens, from its logs"
        }
    }
}

func openNotificationSettings() {
    if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
        NSWorkspace.shared.open(url)
    }
}

/// Where a Focus's allowed apps are chosen.
func openFocusSettings() {
    if let url = URL(string: "x-apple.systempreferences:com.apple.Focus-Settings.extension") {
        NSWorkspace.shared.open(url)
    }
}

func usageColor(_ percent: Double) -> Color {
    switch Severity(percent: percent) {
    case .normal: return .green
    case .warning: return .orange
    case .critical: return .red
    }
}

struct PopoverView: View {
    enum Page {
        case usage
        case statistics
        case history
        case settings
    }

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @State private var page: Page = .usage
    @SwiftUI.Environment(\.displayTextScale) private var textScale

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if page == .settings {
                SettingsPage(scrolls: true) { page = .usage }
            } else if page == .statistics {
                StatisticsPage()
            } else if page == .history {
                HistoryPage()
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    // While the menu bar shows a number, the finished jobs come first.
                    if !model.jobWindows.isEmpty {
                        JobsSection()
                    }
                    if settings.trackedAgents.isEmpty {
                        Text("No agents are tracked. Turn some on in Settings.")
                            .uiFont(12)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(settings.trackedAgents) { agent in
                        AgentCard(agent: agent)
                    }
                    if model.jobWindows.isEmpty {
                        JobsSection()
                    }
                }
                .padding(12)
            }
            Divider()
            footer
        }
        // Wider with bigger text.
        .frame(width: 350 * min(max(textScale, 1), 1.3))
    }

    private var title: String {
        switch page {
        case .usage: return "Agent Buddy"
        case .statistics: return "Token usage"
        case .history: return "Agent windows"
        case .settings: return "Settings"
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(nsImage: AppSymbol.image(size: 18))
                .foregroundStyle(.secondary)
            Text(title)
                .uiFont(14, weight: .semibold)
            Spacer()
            switch page {
            case .usage:
                Button {
                    settings.showFloatingPanel.toggle()
                } label: {
                    Image(systemName: settings.showFloatingPanel ? "pip.fill" : "pip")
                }
                .buttonStyle(.borderless)
                .help(settings.showFloatingPanel ? "Hide the floating panel" : "Show the floating panel")
                Button {
                    page = .history
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .buttonStyle(.borderless)
                .help("Every agent window with finished jobs, kept after you clear the list")
                Button {
                    page = .statistics
                } label: {
                    Image(systemName: "chart.bar.xaxis")
                }
                .buttonStyle(.borderless)
                .help("Token usage by day, week and month")
                Button {
                    model.refreshAll(manual: true)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh now")
                .disabled(!model.refreshing.isEmpty)
                Button {
                    page = .settings
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .help("Settings")
            case .statistics:
                Button {
                    model.refreshTokens(force: true)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Count again now")
                .disabled(model.countingTokens)
                backButton
            case .history, .settings:
                backButton
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var backButton: some View {
        Button {
            page = .usage
        } label: {
            Image(systemName: "xmark")
        }
        .buttonStyle(.borderless)
        .help("Back")
    }

    private var footer: some View {
        HStack {
            if let last = model.lastRefresh {
                Text("Updated \(Format.ago(last, now: model.now)) · every \(settings.refreshMinutes) min")
            } else {
                Text("Reading your limits…")
            }
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.borderless)
        }
        .uiFont(11)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

struct AgentMark: View {
    let agent: Agent
    var size: CGFloat = 24

    var body: some View {
        ZStack {
            Circle().fill(agent.tint.gradient)
            Image(systemName: agent.symbol)
                .font(.system(size: size * 0.44, weight: .bold))
                .foregroundColor(.white)
        }
        .frame(width: size, height: size)
    }
}

struct AgentCard: View {
    let agent: Agent
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings

    /// Claude's plans without a 5-hour session have only the week (and perhaps a model's).
    private func caption(_ reading: AgentReading?) -> String {
        if agent == .claude, let windows = reading?.windows, !windows.isEmpty, !windows.contains(where: { $0.kind == .session }) {
            return "Weekly plan limits"
        }
        return agent.caption
    }

    var body: some View {
        let reading = model.readings[agent]
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                AgentMark(agent: agent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(agent.displayName).uiFont(13, weight: .semibold)
                    Text(caption(reading)).uiFont(10).foregroundStyle(.secondary)
                }
                Spacer()
                if model.refreshing.contains(agent) {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                }
                if let plan = reading?.plan {
                    Text(plan)
                        .uiFont(10, weight: .medium)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                }
            }
            if let reading {
                ForEach(reading.windows) { window in
                    WindowRow(window: window, now: model.now)
                }
                ForEach(reading.notes, id: \.self) { note in
                    Text(note)
                        .uiFont(10.5)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if agent == .codex, settings.codexResets, let announced = model.codexResets?.announced {
                    CodexResetsView(announced: announced, now: model.now)
                }
            } else if model.errors[agent] == nil {
                Text("Reading…").uiFont(11).foregroundStyle(.secondary)
            }
            if let error = model.errors[agent] {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .uiFont(10.5)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.045)))
    }
}

struct WindowRow: View {
    let window: UsageWindow
    let now: Date

    var body: some View {
        let percent = window.percent(at: now)
        let color = usageColor(percent)
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.title).uiFont(12)
                Spacer()
                Text("\(Int(percent.rounded()))%")
                    .uiFont(12, weight: .semibold, digits: true)
                    .foregroundColor(Severity(percent: percent) == .normal ? .primary : color)
            }
            UsageBar(fraction: percent / 100, color: color)
            let line = Format.resetLine(window, now: now)
            if !line.isEmpty {
                Text(line).uiFont(10).foregroundStyle(.secondary)
            }
        }
    }
}

struct UsageBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            let clamped = min(max(fraction, 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule()
                    .fill(color.gradient)
                    .frame(width: clamped > 0 ? max(geometry.size.width * clamped, 5) : 0)
            }
        }
        .frame(height: 6)
    }
}

/// The finished jobs the menu bar's number counts, folded by agent window
/// (each window one row, with how many of its jobs finished), until cleared.
struct JobsSection: View {
    @EnvironmentObject private var model: AppModel
    @State private var expanded: Set<String> = []
    private static let rowHeight: CGFloat = 30
    private static let rowSpacing: CGFloat = 6
    private static let jobLine: CGFloat = 17
    private static let maxHeight: CGFloat = 236

    var body: some View {
        let windows = model.jobWindows
        VStack(alignment: .leading, spacing: 7) {
            header(windows)
            if model.notificationStatus == .denied {
                notificationsOff
            }
            if windows.isEmpty {
                Text("When Claude Code, Codex or Copilot finishes a job, a number appears in the menu bar and the job is listed here, one row per agent window.")
                    .uiFont(11)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                list(windows)
            }
        }
        .padding(.horizontal, windows.isEmpty ? 2 : 10)
        .padding(.vertical, windows.isEmpty ? 0 : 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(windows.isEmpty ? Color.clear : Color.blue.opacity(0.08)))
    }

    private func header(_ windows: [JobWindow]) -> some View {
        HStack(spacing: 6) {
            Text("Finished jobs")
                .uiFont(11, weight: .semibold)
                .foregroundStyle(windows.isEmpty ? .secondary : .primary)
            if let count = MenuBarRenderer.badgeText(windows.count) {
                Text(count)
                    .uiFont(10, weight: .bold, digits: true)
                    .foregroundColor(.white)
                    .padding(.horizontal, 5)
                    .frame(minWidth: 18, minHeight: 18)
                    .background(Capsule().fill(Color.blue))
                    .help("Agent windows with finished jobs")
            }
            Spacer()
            if !windows.isEmpty {
                Button("Clear") { model.clearJobs() }
                    .buttonStyle(.borderless)
                    .uiFont(11)
                    .help("Clear the list and the number in the menu bar")
            }
        }
    }

    private var notificationsOff: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("macOS notifications are off for Agent Buddy, so reminders show as an on-screen card.", systemImage: "bell.slash")
                .uiFont(10.5)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            Button("Turn on notifications…") { openNotificationSettings() }
                .buttonStyle(.borderless)
                .uiFont(10.5)
        }
    }

    /// A list, so each window's row can be swiped away (two fingers, to the left).
    private func list(_ windows: [JobWindow]) -> some View {
        List {
            ForEach(windows) { window in
                row(window)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, Self.rowHeight)
        .frame(height: min(windows.reduce(0) { $0 + height(of: $1) + Self.rowSpacing }, Self.maxHeight))
    }

    private func row(_ window: JobWindow) -> some View {
        JobWindowRow(
            window: window, now: model.now, expanded: expanded.contains(window.key),
            toggle: { toggle(window.key) }, open: { model.showWindow(window.key) }, remove: { remove(window) })
            .frame(height: height(of: window), alignment: .top)
            .listRowInsets(EdgeInsets(top: Self.rowSpacing / 2, leading: 0, bottom: Self.rowSpacing / 2, trailing: 0))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button(role: .destructive) {
                    remove(window)
                } label: {
                    Label("Remove", systemImage: "trash")
                }
            }
            .contextMenu {
                Button("Show the Prompts") { model.showWindow(window.key) }
                Button("Jump to Where It Runs") { model.jumpToWindow(window.key) }
                Divider()
                Button(window.count > 1 ? "Remove these \(window.count) jobs" : "Remove") { remove(window) }
            }
    }

    private func height(of window: JobWindow) -> CGFloat {
        guard expanded.contains(window.key) else { return Self.rowHeight }
        return Self.rowHeight + 4 + CGFloat(min(window.count, 5)) * Self.jobLine
    }

    private func toggle(_ key: String) {
        withAnimation(.easeOut(duration: 0.15)) {
            if expanded.contains(key) {
                expanded.remove(key)
            } else {
                expanded.insert(key)
            }
        }
    }

    private func remove(_ window: JobWindow) {
        withAnimation(.easeOut(duration: 0.2)) {
            expanded.remove(window.key)
            model.removeWindow(window.key)
        }
    }
}

/// One agent window: its latest job, how many finished there, and, opened, each of them.
struct JobWindowRow: View {
    let window: JobWindow
    let now: Date
    let expanded: Bool
    let toggle: () -> Void
    /// Opens the window's history.
    var open: (() -> Void)?
    /// Shown as a small × while the pointer is over the row.
    var remove: (() -> Void)?
    @State private var hovering = false

    var body: some View {
        let job = window.latest
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: Self.icon(job.outcome))
                    .foregroundColor(Self.color(job.outcome))
                    .uiFont(13)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(job.title ?? job.project ?? job.agent.clientName)
                            .uiFont(12)
                            .lineLimit(1)
                        if window.count > 1 {
                            Text("\(window.count)")
                                .uiFont(9, weight: .bold, digits: true)
                                .foregroundColor(.white)
                                .padding(.horizontal, 5)
                                .frame(minWidth: 15, minHeight: 15)
                                .background(Capsule().fill(Color.blue))
                        }
                    }
                    Text(facts)
                        .uiFont(10)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if window.count > 1 {
                    Button(action: toggle) {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .uiFont(9, weight: .semibold)
                            .foregroundStyle(.secondary)
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(expanded ? "Hide the jobs" : "List the \(window.count) jobs")
                }
                if hovering, let remove {
                    Button(action: remove) {
                        Image(systemName: "xmark.circle.fill")
                            .uiFont(13)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(window.count > 1 ? "Remove these \(window.count) jobs" : "Remove this job")
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { (open ?? toggle)() }
            if expanded {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(window.jobs.prefix(5)) { item in
                        HStack(spacing: 6) {
                            Image(systemName: Self.icon(item.outcome))
                                .uiFont(9)
                                .foregroundColor(Self.color(item.outcome))
                            Text(Format.ago(item.finishedAt, now: now))
                                .uiFont(10, digits: true)
                                .foregroundStyle(.secondary)
                                .uiWidth(50, alignment: .leading)
                            Text(item.summary ?? item.title ?? "Finished")
                                .uiFont(10)
                                .lineLimit(1)
                        }
                        .frame(height: 15)
                    }
                }
                .padding(.leading, 21)
            }
        }
        .onHover { hovering = $0 }
        .help("Click to see the prompts asked in this window, and jump to where it runs")
    }

    private var facts: String {
        let job = window.latest
        var parts = [job.agent.clientName]
        if job.title != nil, let project = job.project {
            parts.append(project)
        }
        if let source = job.source {
            parts.append("on \(source)")
        }
        if window.count > 1 {
            parts.append("\(window.count) jobs")
        } else if let duration = job.duration {
            parts.append("took \(Format.duration(duration))")
        }
        parts.append(Format.ago(job.finishedAt, now: now))
        return parts.joined(separator: " · ")
    }

    static func icon(_ outcome: JobEvent.Outcome) -> String {
        switch outcome {
        case .completed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.circle.fill"
        case .limited: return "hourglass.circle.fill"
        }
    }

    static func color(_ outcome: JobEvent.Outcome) -> Color {
        switch outcome {
        case .completed: return .green
        case .failed: return .red
        case .limited: return .orange
        }
    }
}

/// A group of settings in a box, titled, with a note under its controls.
struct SettingsGroup<Content: View>: View {
    let title: String
    let note: String?
    let content: Content

    init(_ title: String, note: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.note = note
        self.content = content()
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 7) {
                content
                if let note {
                    Text(note)
                        .uiFont(10.5)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(5)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text(title).uiFont(11.5, weight: .semibold)
        }
    }
}

/// A menu's row in settings: its name, and the menu at the right.
struct SettingsRow<Picker: View>: View {
    let title: String
    let picker: Picker

    init(_ title: String, @ViewBuilder picker: () -> Picker) {
        self.title = title
        self.picker = picker()
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            Spacer(minLength: 8)
            picker
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
        }
    }
}

/// Settings' tabs.
enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case reminders
    case appearance
    case phone
    case servers

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .reminders: return "Reminders"
        case .appearance: return "Appearance"
        case .phone: return "iPhone"
        case .servers: return "Servers"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .reminders: return "bell"
        case .appearance: return "textformat.size"
        case .phone: return "iphone"
        case .servers: return "server.rack"
        }
    }

    var help: String {
        switch self {
        case .general: return "Agents to track, selections, while agents work, and startup"
        case .reminders: return "Which reminders come, and how"
        case .appearance: return "Light or dark, transparency, the menu bar and floating panel, and text sizes"
        case .phone: return "Reminders on your iPhone and Apple Watch, and Agent Buddy Remote"
        case .servers: return "Agents on your servers, over SSH"
        }
    }
}

struct SettingsPage: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var model: AppModel
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginError: String?
    @State private var suggestedHosts: [String] = []
    @ObservedObject private var selections = SelectionWatcher.shared
    @State private var newHost = ""
    @State private var tab: SettingsTab
    /// The snapshot mode draws the iPhone set-up steps open.
    var phoneSetupOpen = false
    /// Scrolled within the popover's height; the snapshot draws a tab whole.
    var scrolls = false
    let done: () -> Void

    /// The servers suggested, for the tour's pictures (not those from your SSH, Zed and VS Code).
    var suggestedServers: [String]?

    init(tab: SettingsTab = .general, phoneSetupOpen: Bool = false, scrolls: Bool = false, suggestedServers: [String]? = nil,
         done: @escaping () -> Void) {
        _tab = State(initialValue: tab)
        self.phoneSetupOpen = phoneSetupOpen
        self.scrolls = scrolls
        self.suggestedServers = suggestedServers
        _suggestedHosts = State(initialValue: suggestedServers ?? [])
        self.done = done
    }

    /// The servers counted, then the ones suggested from SSH, Zed and VS Code.
    private var hostChoices: [String] {
        settings.remoteHosts + suggestedHosts.filter { !settings.remoteHosts.contains($0) }
    }

    private func counted(_ host: String) -> Binding<Bool> {
        Binding(
            get: { settings.remoteHosts.contains(host) },
            set: { on in
                if on {
                    if !settings.remoteHosts.contains(host) {
                        settings.remoteHosts.append(host)
                    }
                } else {
                    settings.remoteHosts.removeAll { $0 == host }
                }
            })
    }

    /// Whether Agent Buddy is connected to the server, and how its last token count went.
    @ViewBuilder
    private func serverState(_ host: String) -> some View {
        switch model.remoteLive[host] {
        case .live:
            Label("Watching", systemImage: "dot.radiowaves.left.and.right")
                .uiFont(10.5)
                .foregroundStyle(.green)
                .help(model.remoteStatus[host]?.error ?? "Connected: finished jobs on \(host) remind you")
        case .retrying(let reason):
            Label("Reconnecting", systemImage: "exclamationmark.triangle.fill")
                .uiFont(10.5)
                .foregroundStyle(.orange)
                .help(reason)
        case .connecting:
            ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 14, height: 14)
        default:
            EmptyView()
        }
    }

    /// The reminders "All reminders" turns on and off (not how they're given):
    /// OpenAI's resets only while they can come.
    private var reminders: [Binding<Bool>] {
        var all = Agent.allCases.map(settings.notifiesJobsBinding) + [$settings.sessionResetReminder]
        if settings.trackCodex && settings.codexResets {
            all.append($settings.notifyCodexResets)
        }
        return all + [$settings.limitWarnings]
    }

    private func addHost() {
        let host = newHost.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty, !host.contains(" ") else { return }
        if !settings.remoteHosts.contains(host) {
            settings.remoteHosts.append(host)
        }
        newHost = ""
    }

    var body: some View {
        VStack(spacing: 0) {
            tabs
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 6)
            Divider()
            if scrolls {
                ScrollView {
                    page
                }
                .frame(height: 520)
            } else {
                page
            }
            Divider()
            HStack {
                Spacer()
                Button("Done", action: done).keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .toggleStyle(.checkbox)
        .uiFont(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The tabs, as a Mac app's settings window has them: a symbol over a name.
    private var tabs: some View {
        HStack(spacing: 2) {
            ForEach(SettingsTab.allCases) { each in
                Button {
                    tab = each
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: each.symbol)
                            .uiFont(15)
                            .frame(height: 18)
                        Text(each.title)
                            .uiFont(10.5, weight: tab == each ? .semibold : .regular)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .foregroundStyle(tab == each ? Color.accentColor : Color.secondary)
                    .background(RoundedRectangle(cornerRadius: 7).fill(tab == each ? Color.accentColor.opacity(0.13) : Color.clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(each.help)
            }
        }
    }

    private var page: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch tab {
            case .general: general
            case .reminders: reminderGroups
            case .appearance: appearance
            case .phone:
                PhoneSection(phone: model.phone, setupOpen: phoneSetupOpen)
            case .servers: servers
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - General

    @ViewBuilder
    private var general: some View {
        group("Agents to track") {
            Toggle("Claude", isOn: $settings.trackClaude)
            Toggle("ChatGPT (Codex limits)", isOn: $settings.trackCodex)
            Toggle("OpenAI's next reset of everyone's Codex limits", isOn: $settings.codexResets)
                .disabled(!settings.trackCodex)
                .padding(.leading, 18)
                .help("Shown under Codex's limits only while one is announced, from codex-reset.com, a community tracker")
            Toggle("Copilot", isOn: $settings.trackCopilot)
        }
        group("Selections") {
            Toggle("Agent windows show what I select elsewhere", isOn: $settings.selectionContext)
                .help("While an agent window is open, text you select elsewhere shows by its message box and goes with your next prompt. Zed's needs no permission; other apps' need Accessibility.")
            Toggle("\u{2026}and in VS Code, via its screen reader mode", isOn: $settings.selectionEditors)
                .disabled(!settings.selectionContext)
                .padding(.leading, 18)
                .help("VS Code (and Cursor, Windsurf, VSCodium) tells other apps what you select only in its screen reader mode. While an agent window is open, Agent Buddy switches it on as a screen reader would; VS Code then shows \u{201C}Screen Reader Optimized\u{201D} and may play accessibility sounds.")
            if settings.selectionContext {
                accessibility
                    .padding(.leading, 18)
            }
        }
        group("Agent windows", note: "As Open here does: the agent stays open in the background, here or on its server, and reconnects if the connection drops; each window keeps its agent running while it's open. Closing the window, or Let go, disconnects it. A Codex thread open in another program is left to it.") {
            Toggle("Connect to the session when its window opens", isOn: $settings.connectOnOpen)
                .help("Opening an agent window moves its Claude Code or Codex session here, so what you send goes straight into the running agent")
        }
        group("While agents work") {
            WhileWorkingSettings()
        }
        group("Startup") {
            row("Refresh limits every") {
                Picker("Refresh every", selection: $settings.refreshMinutes) {
                    ForEach([1, 2, 5, 10, 15], id: \.self) { minutes in
                        Text("\(minutes) min").tag(minutes)
                    }
                }
            }
            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { enabled in
                    loginError = LoginItem.set(enabled)
                    launchAtLogin = LoginItem.isEnabled
                }
            if let loginError {
                Text(loginError).uiFont(10.5).foregroundStyle(.orange)
            }
        }
    }

    /// Whether other apps' selections can be read, and the way to allow it.
    private var accessibility: some View {
        HStack(spacing: 6) {
            if selections.trusted {
                Label("Accessibility allowed: apps other than Zed too", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Text("Apps other than Zed need Accessibility.")
                    .foregroundStyle(.secondary)
                Button("Allow\u{2026}") { selections.askForAccess() }
                    .controlSize(.small)
                    .help("macOS asks about Agent Buddy: switch it on under Privacy & Security \u{203A} Accessibility. An entry left from an earlier build is cleared first.")
            }
        }
        .uiFont(10.5)
        .task {
            // Turns to "allowed" as soon as it's switched on in System Settings.
            while !Task.isCancelled {
                selections.checkTrust()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    // MARK: - Reminders

    @ViewBuilder
    private var reminderGroups: some View {
        group("Notify me when") {
            // One click: every reminder on, or, all on, all off. A dash while some are.
            Toggle("All reminders", sources: reminders, isOn: \.self)
                .help("Turns every reminder below on, or all of them off when they're all on")
            Group {
                Text("An agent finishes a job")
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                          alignment: .leading, spacing: 5) {
                    ForEach(Agent.allCases) { agent in
                        Toggle(agent.clientName, isOn: settings.notifiesJobsBinding(agent))
                    }
                }
                .padding(.leading, 18)
                Toggle("Claude's 5-hour session resets (on plans that have one)", isOn: $settings.sessionResetReminder)
                Toggle("OpenAI resets everyone's Codex limits", isOn: $settings.notifyCodexResets)
                    .disabled(!settings.trackCodex || !settings.codexResets)
                Toggle("A limit passes 90% or runs out", isOn: $settings.limitWarnings)
            }
            .padding(.leading, 18)
        }
        group("How reminders come", note: "When macOS notifications are off, the on-screen card is used.") {
            row("Remind with") {
                Picker("Remind with", selection: $settings.reminderStyle) {
                    ForEach(ReminderStyle.allCases) { style in
                        Text(style.label).tag(style)
                    }
                }
            }
            Toggle("Include the agent's last words", isOn: $settings.showSummaries)
            Toggle("Play a sound", isOn: $settings.playSound)
            HStack(spacing: 8) {
                Button("Send a test reminder") { model.sendTestNotification() }
                Text(statusText).uiFont(10.5).foregroundStyle(.secondary)
            }
            if model.notificationStatus == .denied {
                Button("Open Notification Settings\u{2026}") { openNotificationSettings() }
            }
        }
    }

    // MARK: - Appearance

    @ViewBuilder
    private var appearance: some View {
        group("Light and dark") {
            Picker("Appearance", selection: $settings.appearance) {
                ForEach(AppearanceMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .help("Light or dark for Agent Buddy's windows and panels, or as macOS is")
        }
        group("Transparency", note: "Less opaque lets you see what's behind, such as an agent window pinned over your editor.") {
            opacityRow("Floating panel", $settings.floatingOpacity)
            opacityRow("Agent windows", $settings.windowOpacity)
        }
        group("Agent windows: glass and tabs", note: "Or merge the open ones from any agent window's Tabs menu, in its title bar. Drag a tab out for a window of its own.") {
            Toggle("Frosted glass", isOn: $settings.windowGlass)
                .help("What's behind an agent window shows through it, blurred; the message box stays solid. Transparency, above, still applies.")
            Toggle("Open agent windows as tabs of one window", isOn: $settings.windowTabs)
        }
        group("Menu bar and floating panel",
              note: "Drag the floating panel anywhere. Right-click it, or the menu bar icon, to hide or show it. Both can't be hidden at once.") {
            row("Menu bar shows") {
                Picker("Menu bar shows", selection: $settings.menuBarStyle) {
                    ForEach(MenuBarStyle.allCases) { style in
                        Text(style.label).tag(style)
                    }
                }
            }
            Toggle("Show the floating panel", isOn: $settings.showFloatingPanel)
        }
        TextSettings()
    }

    // MARK: - Servers

    private var servers: some View {
        group("Servers", note: "Agent Buddy connects with your SSH key, never asks for a password, and brings back only what it needs, not your conversations.") {
            Text("For Claude Code and Codex in remote terminals (VS Code, Zed, ssh): their finished jobs remind you, and their tokens count.")
                .uiFont(10.5)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(hostChoices, id: \.self) { host in
                HStack(spacing: 6) {
                    Toggle(host, isOn: counted(host))
                    Spacer()
                    if settings.remoteHosts.contains(host) {
                        serverState(host)
                    }
                }
            }
            HStack(spacing: 6) {
                TextField("user@server", text: $newHost)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addHost)
                Button("Add", action: addHost)
                    .disabled(newHost.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .onAppear { suggestedHosts = suggestedServers ?? RemoteHosts.suggestions() }
    }

    // MARK: - Parts

    /// A window's opacity: a slider, and how much it is.
    private func opacityRow(_ title: String, _ value: Binding<Double>) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .uiWidth(100, alignment: .leading)
            Slider(value: value, in: 0.4...1, step: 0.05)
                .controlSize(.small)
            Text("\(Int((value.wrappedValue * 100).rounded()))%")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .uiWidth(36, alignment: .trailing)
        }
    }

    private func group<Content: View>(_ title: String, note: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        SettingsGroup(title, note: note, content: content)
    }

    private func row<Picker: View>(_ title: String, @ViewBuilder picker: () -> Picker) -> some View {
        SettingsRow(title, picker: picker)
    }

    private var statusText: String {
        switch model.notificationStatus {
        case .allowed: return "Notifications are on"
        case .denied: return "Notifications are off"
        case .notAsked: return "Not allowed yet"
        case .unavailable: return "Needs the .app build"
        case .unknown: return ""
        }
    }

}

/// Settings ▸ General ▸ While agents work: keeping the Mac awake, the lock screen's list,
/// and who's working now.
struct WhileWorkingSettings: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Keep the Mac awake while an agent is working", isOn: $settings.keepAwake)
            Toggle("Keep the display on too", isOn: $settings.keepDisplayAwake)
                .disabled(!settings.keepAwake)
                .padding(.leading, 18)
            note("Like Codex's \u{201C}Prevent sleep while running\u{201D}, for every agent here and on your servers. Closing the lid still sleeps the Mac.")
            Toggle("Show working agents on the lock screen", isOn: $settings.lockScreenStatus)
            note("A quiet notification lists them while the Mac is locked. It needs Agent Buddy\u{2019}s notifications on, with Show previews: Always; a Focus hides it unless Agent Buddy is among its allowed apps.")
            if settings.lockScreenStatus {
                if model.notificationStatus != .allowed && model.notificationStatus != .unknown {
                    Label("Notifications are off for Agent Buddy, so nothing can show on the lock screen.",
                          systemImage: "exclamationmark.triangle.fill")
                        .uiFont(10.5)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 14) {
                    Button(model.notificationStatus == .allowed ? "Notification settings\u{2026}" : "Turn on notifications\u{2026}") {
                        openNotificationSettings()
                    }
                    Button("Focus settings\u{2026}") { openFocusSettings() }
                }
                .buttonStyle(.link)
                .uiFont(10.5)
            }
            working
        }
    }

    @ViewBuilder
    private var working: some View {
        if model.working.isEmpty {
            Label("No agent is working right now.", systemImage: "moon.zzz")
                .uiFont(10.5)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Label(model.keepingAwake ? "Working now, keeping the Mac awake:" : "Working now:",
                      systemImage: model.keepingAwake ? "cup.and.saucer.fill" : "hammer.fill")
                    .uiFont(10.5, weight: .medium)
                ForEach(model.working) { session in
                    VStack(alignment: .leading, spacing: 0) {
                        Text("\(session.label) \u{00B7} since \(Format.clock(session.since, now: model.now))")
                            .lineLimit(1)
                        if let work = session.work {
                            Text("\u{201C}\(work)\u{201D}")
                                .lineLimit(1)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .uiFont(10.5)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 20)
                }
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .uiFont(10.5)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
