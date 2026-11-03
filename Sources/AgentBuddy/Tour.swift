import AppKit
import AgentBuddyCore
import AgentBuddyMarkdown
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import Vision
import WebKit

/// `AgentBuddy --tour <folder>`: the animated pictures that show Agent Buddy in
/// its README, a folder for each of its windows. Drawn from sample data only:
/// no limits, logs, servers or settings of yours, and nothing is saved or sent.
@MainActor
final class Tour: NSObject, NSApplicationDelegate {
    /// One picture of a tour: what it shows, the parts to point at, and what it says.
    struct Shot {
        var image: CGImage
        /// In points.
        var size: CGSize
        /// The parts pointed at, in points from the top left.
        var marks: [CGRect]
        var title: String
        var detail: String
        var seconds: Double = 3
        /// Drawn over the picture before it, dimmed, as a sheet over its window.
        var over = false
        /// A window or a panel of its own: drawn with rounded corners and a shadow
        /// (else it brings its own, as the floating panel and the popover under it do).
        var framed = true
        /// An agent window's frosted glass: the desktop shows through it.
        var frosted = false
    }

    private let root: URL
    private let scratch = "io.github.homoy.agentbuddy.tour"
    private var defaults: UserDefaults!
    private var settings: AppSettings!
    private var model: AppModel!
    private let start = Date().addingTimeInterval(-6 * 3600)
    /// For the windows' Tabs buttons: kept while their windows are.
    private let tabsController = SessionDetailsController()
    private var tabMenus: [WindowTabsMenu] = []
    /// What agent windows show of selections in other apps: Accessibility allowed
    /// (no link to allow it), and an editor that keeps its selection to itself. Set
    /// again for each window (a Settings page looks at the real permission).
    private var access: (trusted: Bool, closedEditor: String?) = (true, nil)

    init(root: URL) {
        self.root = root
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setvbuf(stdout, nil, _IOLBF, 0)
        Task { @MainActor in
            await run()
            defaults?.removePersistentDomain(forName: scratch)
            exit(0)
        }
    }

    private func settle(_ seconds: TimeInterval, until done: () -> Bool = { false }) async {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until, !done() {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func run() async {
        guard let defaults = UserDefaults(suiteName: scratch) else { return }
        // The signal shows what's previewed: no server is asked.
        ConnectionMonitor.shared.live = false
        defaults.removePersistentDomain(forName: scratch)
        self.defaults = defaults
        let settings = AppSettings(defaults: defaults)
        settings.remoteHosts = ["gpu-box", "build-server"]
        settings.keepAwake = true
        settings.lockScreenStatus = true
        settings.selectionContext = true
        settings.reminderStyle = .both
        self.settings = settings
        let model = AppModel(settings: settings, notifier: Notifier())
        model.preview(readings: sampleReadings())
        model.preview(jobs: sampleJobs())
        model.preview(codexResets: sampleForecast(announced: false))
        model.preview(tokens: sampleTokens())
        model.preview(working: sampleWorking(), keepingAwake: true)
        model.preview(servers: ["gpu-box": .live, "build-server": .live])
        model.preview(archive: sampleArchive())
        model.jobUsage.preview(sampleUsageSessions())
        self.model = model
        SelectionWatcher.shared.preview(nil)
        SelectionWatcher.shared.preview(trusted: true, closedEditor: nil)

        await usage()
        await agentWindows()
        await tokenUsage()
        await settingsTour()
        writeAll()
        print("Wrote the tour to \(root.path)")
    }

    // MARK: - The parts

    private func usage() async {
        var shots: [Shot] = []
        if let shot = await shot(column(), background: false, title: "Always in sight",
                                 detail: "A small floating panel shows how much of each plan you've used, on every Space and over full-screen apps. Drag it anywhere; click it for the details.") {
            shots.append(shot)
        }
        if let shot = await shot(column { PopoverView() }, background: false, mark: ["Resets in"], title: "Every limit, and when it resets",
                                 detail: "Claude's week and each model's share of it, ChatGPT's Codex limits and Copilot's requests: how much is used, and when each one resets.") {
            shots.append(shot)
        }
        model.preview(codexResets: sampleForecast(announced: true))
        if let shot = await shot(column { PopoverView() }, background: false, mark: ["Resetting Codex rate limits"], title: "Everyone's next Codex reset",
                                 detail: "When OpenAI announces it'll reset everyone's Codex limits early, a countdown shows under ChatGPT (from codex-reset.com).") {
            shots.append(shot)
        }
        model.preview(codexResets: sampleForecast(announced: false))
        if let shot = await shot(column { PopoverView() }, background: false, mark: ["Finished jobs"], title: "Finished jobs, by agent window",
                                 detail: "The blue number counts agent windows with finished jobs. Click one for its prompts and answers.") {
            shots.append(shot)
        }
        write(shots, to: "1-usage/limits.gif")
    }

    /// The floating panel, and what opens under it (the popover, Settings, ...), each with its shadow.
    private func column<Content: View>(hudOpacity: Double = 1, @ViewBuilder _ content: () -> Content = { EmptyView() }) -> some View {
        VStack(alignment: .trailing, spacing: 10) {
            FloatingHUDView()
                .background(RoundedRectangle(cornerRadius: FloatingHUDController.cornerRadius, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor).opacity(0.94)))
                .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
                .opacity(hudOpacity)
            content()
                .background(Color(nsColor: .windowBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(color: .black.opacity(0.3), radius: 18, y: 8)
        }
        .padding(24)
    }

    private func agentWindows() async {
        // Opening one.
        var opening: [Shot] = []
        if let shot = await shot(column { PopoverView() }, background: false, mark: ["Finished jobs"], title: "Open an agent window",
                                 detail: "Click a finished job, its reminder, or a window under Agent windows (the clock at the top).") {
            opening.append(shot)
        }
        if let shot = await shot(HistoryPage().frame(width: 350), title: "Agent windows",
                                 detail: "Every agent window with finished jobs, by day, kept for 90 days.") {
            opening.append(shot)
        }
        let first = details(through: "4")
        if let shot = await windowShot(first, title: "Its prompts and answers",
                                       detail: "Every prompt asked there, how its turn went and its tokens; the latest open, with the agent's whole answer.") {
            opening.append(shot)
        }
        write(opening, to: "2-agent-windows/open.gif")

        // Answers: formulas, code, steps and their changes.
        var answers: [Shot] = []
        if let shot = await windowShot(first, title: "Formulas and tables",
                                       detail: "Answers are drawn from their Markdown: formulas by KaTeX ($…$, $$…$$, \\(…\\), \\[…\\], \\mathds too) and tables.") {
            answers.append(shot)
        }
        if let shot = await windowShot(first, scroll: 430, title: "Code in boxes",
                                       detail: "Code shows in boxes with its language's colours. Select any of it and press ⌘C to copy.") {
            answers.append(shot)
        }
        let fixing = details(through: "5")
        fixing.preview(steps: Self.turnSteps(sampleSteps()), for: "5")
        if let shot = await windowShot(fixing, title: "Every step",
                                       detail: "What the agent did, after a ● each, as its terminal shows it. Actions that went well fold into a line; a failed one shows apart.") {
            answers.append(shot)
        }
        if let shot = await windowShot(fixing, script: "document.querySelectorAll('.step.group > .body > .head, .step.action.failed > .body > .head').forEach(head => head.click())",
                                       title: "Click a line for more", detail: "A folded run opens into each action, and an action into what it printed.") {
            answers.append(shot)
        }
        if let shot = await windowShot(fixing, script: "document.querySelector('details.changes').open = true", scroll: .infinity,
                                       title: "The change summary", detail: "View changes: every file it changed, each change's lines numbered as in the file.") {
            answers.append(shot)
        }
        write(answers, to: "2-agent-windows/answers.gif")

        // Jump to and Open here, their lights; a server's signal; windows as tabs.
        var here: [Shot] = []
        let kept = details(through: "5")
        if let shot = await windowShot(kept, mark: ["Jump to"], title: "Jump to where it runs",
                                       detail: "Straight to its editor window or terminal tab, here or on a server (⌘J). The green light: the session's open there now.") {
            here.append(shot)
        }
        SessionKeeper.shared.preview(.opening, for: kept.key)
        if let shot = await windowShot(kept, title: "Open here",
                                       detail: "Opens the session in Agent Buddy, in the background: what you send goes straight into the running agent.") {
            here.append(shot)
        }
        SessionKeeper.shared.preview(.ready, for: kept.key)
        if let shot = await windowShot(kept, mark: ["Let go"], title: "Open here, on this Mac",
                                       detail: "A green light before it: open in Agent Buddy. Let go gives it back; closing the window does too.") {
            here.append(shot)
        }
        SessionKeeper.shared.preview(nil, for: kept.key)
        let far = details(through: "5", host: "gpu-box")
        ConnectionMonitor.shared.links["gpu-box"] = .live
        ConnectionMonitor.shared.preview(.roundTrip(RoundTrip.Measured(milliseconds: 126, how: "ping")), for: "gpu-box")
        SessionKeeper.shared.preview(.ready, for: far.key)
        if let shot = await windowShot(far, mark: ["126 ms"], title: "On a server: its signal",
                                       detail: "The round trip to the server, every 20 seconds: fewer, warmer bars the slower it is, or Disconnected.") {
            here.append(shot)
        }
        SessionKeeper.shared.preview(nil, for: far.key)
        ConnectionMonitor.shared.links["gpu-box"] = nil
        if let shot = await tabsShot(details(through: "5"), otherSession(), title: "Several windows, as tabs",
                                     detail: "Merge All Agent Windows from the Tabs menu in the title bar, or open new ones as tabs. ⌘⇧] and ⌘⇧[ go between them.") {
            here.append(shot)
        }
        write(here, to: "2-agent-windows/open-and-jump.gif")

        await messageBox()
        await selections()
        await tree()
        await searching()
    }

    private func messageBox() async {
        var shots: [Shot] = []
        let box = details(through: "5")
        // Each window's box starts empty and is typed into once it's up (what's there
        // when it opens is shown selected, as a box taking focus selects its text).
        func windowShot(_ details: SessionDetails, mark: [String] = [], together: Bool = false, then: (() -> Void)? = nil,
                        title: String, detail: String) async -> Shot? {
            if then != nil {
                details.draft = ""
            }
            return await self.windowShot(details, mark: mark, together: together, then: then, title: title, detail: detail)
        }
        let prompt = "Plot both conversion rates by day, with a 95% band"
        if let shot = await windowShot(box, mark: ["Message Claude Code", prompt], then: { box.draft = prompt }, title: "Ask from here",
                                       detail: "The message box sends into the same session, as if you resumed it, on this Mac or on a server.") {
            shots.append(shot)
        }
        box.composing.files = [URL(fileURLWithPath: "/Users/me/Desktop/Checkout funnel.png"),
                               URL(fileURLWithPath: "/Users/me/shop/data/events-export.csv")]
        if let shot = await windowShot(box, mark: ["events-export.csv"], then: { box.draft = prompt }, title: "+ for files and photos",
                                       detail: "Choose them with +, paste a screenshot, or drop them on the box.") {
            shots.append(shot)
        }
        box.composing.options = PromptSender.Options(model: "opus", effort: "xhigh", fast: true, mode: "plan")
        if let shot = await windowShot(box, mark: ["Plan", "Opus", "Extra high", "Fast"], together: true, then: { box.draft = prompt },
                                       title: "Mode, model, effort and fast mode",
                                       detail: "As the agent has them: Auto, Accept edits or Plan; the model; how hard it thinks; fast mode. Each starts as the session has it.") {
            shots.append(shot)
        }
        box.composing.files = []
        box.composing.projectFiles = ["shop/stats.py", "shop/report.py", "shop/events.py", "shop/__init__.py", "scripts/check_ab.py",
                                      "tests/test_ztest.py", "tests/test_report.py", "notes/method.md"]
        box.composing.commands = [
            AgentCommand(name: "compact", description: "Clear the conversation but keep a summary in context", kind: .builtIn),
            AgentCommand(name: "context", description: "Show what's using the context window", kind: .builtIn),
            AgentCommand(name: "review", description: "Review the changes on this branch", kind: .command),
            AgentCommand(name: "release-notes", description: "Write release notes from the commits since the last tag", kind: .command),
            AgentCommand(name: "pdf", description: "Read, fill and make PDF files", kind: .skill),
        ]
        func typed(_ text: String) -> () -> Void {
            {
                box.composing.suggestions.details = box
                box.draft = text
                box.composing.suggestions.update()
            }
        }
        if let shot = await windowShot(box, mark: ["@sta"], then: typed("Compare with @sta"), title: "@ adds a file",
                                       detail: "Type @ and part of a name: the session's files and folders, as in Zed. Return picks one.") {
            shots.append(shot)
        }
        if let shot = await windowShot(box, mark: ["/compact"], then: typed("/"), title: "/ for commands",
                                       detail: "The agent's own commands, your commands and skills, each with what it does.") {
            shots.append(shot)
        }
        box.composing.suggestions.hide()
        if let shot = await windowShot(box, then: { box.draft = prompt }, title: "Or say it",
                                       detail: "The microphone beside the send button dictates into the box, as pressing fn twice does.") {
            shots.append(shot)
        }
        box.draft = ""
        box.showSending(PromptSender.Started(agent: .claude, host: nil, pid: getpid(), log: "/dev/null", at: Date()), text: prompt)
        if let shot = await windowShot(box, mark: ["Sent from here", "Stop"], title: "Its answer shows as it comes",
                                       detail: "Your prompt shows at once; then its steps and answer, and the usual reminder when it's done. Stop ends it.") {
            shots.append(shot)
        }
        box.previewQueued(["Then plot the daily rates too.", "And put the result in the README."])
        if let shot = await windowShot(box, mark: ["Queued"], title: "Send while it works",
                                       detail: "What you send waits its turn above the box and goes when the answer's done (× takes it back). Codex opened here takes it into the answer.") {
            shots.append(shot)
        }
        box.previewQueued([])
        write(shots, to: "2-agent-windows/message-box.gif")
    }

    private func selections() async {
        var shots: [Shot] = []
        let window = details(through: "5")
        let watcher = SelectionWatcher.shared
        watcher.preview(SelectionWatcher.Selection(
            kind: .zed, app: "Zed", file: "/Users/me/shop/shop/stats.py", host: nil, lines: 12...14, title: nil,
            text: "    p_a, p_b = x_a / n_a, x_b / n_b\n    pooled = (x_a + x_b) / (n_a + n_b)\n    se = sqrt(pooled * (1 - pooled) * (1 / n_a + 1 / n_b))",
            id: "tour-zed"))
        if let shot = await windowShot(window, mark: ["Selected in Zed"], title: "Your selection goes with it",
                                       detail: "What you select in Zed shows above the box and goes with your next prompt, as an editor's selection goes to Claude Code. × leaves it out.") {
            shots.append(shot)
        }
        watcher.preview(SelectionWatcher.Selection(
            kind: .copied, app: "VS Code", file: "/Users/me/shop/tests/test_ztest.py", host: nil, lines: nil, title: nil,
            text: "assert round(z, 2) == 2.46", id: "tour-copied"))
        if let shot = await windowShot(window, mark: ["Copied in VS Code"], title: "Or copy it",
                                       detail: "In VS Code or Chrome, select and press ⌘C: it shows until you send it or dismiss it.") {
            shots.append(shot)
        }
        watcher.preview(nil)
        access = (false, nil)
        defer { access = (true, nil) }
        if let shot = await windowShot(window, mark: ["allow Accessibility"], title: "Other apps: allow Accessibility",
                                       detail: "Click the link, then switch Agent Buddy on under System Settings › Privacy & Security › Accessibility. Zed needs no permission.") {
            shots.append(shot)
        }
        access = (true, "VS Code")
        if let shot = await windowShot(window, mark: ["VS Code keeps what you select"], title: "VS Code",
                                       detail: "VS Code shares what's selected only in its screen reader mode. The link switches it on while an agent window is open, after asking.") {
            shots.append(shot)
        }
        if var shot = await alertShot(title: "VS Code asks first", detail: "Switch On, and close VS Code's one question about a screen reader (No stops it sharing). It goes back off when the last agent window closes.") {
            shot.over = true
            shots.append(shot)
        }
        access = (true, nil)
        if var shot = await shot(SettingsPage(tab: .general, suggestedServers: [], done: {}).frame(width: 350),
                                 mark: ["Agent windows show what I select elsewhere", "and in VS Code"],
                                 title: "Settings › General › Selections", detail: "Turn selections on or off, and VS Code's screen reader mode with them.") {
            shot.over = true
            shots.append(shot)
        }
        watcher.preview(nil)
        if let shot = await windowShot(details(through: "5", withSelection: true), expanded: ["5"], focus: "5", mark: ["With your selection"],
                                       title: "Shown with its prompt", detail: "Sent, the prompt shows what went with it: where it came from, and, opened, the text itself.") {
            shots.append(shot)
        }
        write(shots, to: "2-agent-windows/selections.gif")
    }

    private func tree() async {
        var shots: [Shot] = []
        let window = details(through: "5", withSeparate: true)
        if let shot = await windowShot(window, title: "Every prompt, as a tree",
                                       detail: "Prompts on the line you're on now are solid; the rest are faded.") {
            shots.append(shot)
        }
        if let shot = await windowShot(window, mark: ["Edited away"], title: "Rolled back? It's all still there",
                                       detail: "Rewind Claude Code to edit an earlier prompt, and the prompts you left behind hang off the line, marked Edited away.") {
            shots.append(shot)
        }
        let opened = details(through: "5", withSeparate: true)
        if let shot = await windowShot(opened, expanded: ["3"], focus: "3", title: "Open one for what it said",
                                       detail: "Click a prompt for all of it, its answer and its tokens, edited away or not.") {
            shots.append(shot)
        }
        if let shot = await windowShot(details(through: "5", withSeparate: true), mark: ["Sent separately"], title: "Sent separately",
                                       detail: "A prompt sent on its own (as the message box does with claude -p) is marked, so you know the session's window didn't see it.") {
            shots.append(shot)
        }
        write(shots, to: "2-agent-windows/tree.gif")
    }

    private func searching() async {
        var shots: [Shot] = []
        let window = details(through: "5")
        window.search.open()
        window.search.search("pooled", in: window.history?.rows ?? [])
        let found = Set(window.search.matches)
        if let shot = await windowShot(window, expanded: found, mark: ["2 of 2"], title: "Search every prompt and answer",
                                       detail: "⌘F, or the magnifying glass at the foot of the window: how many prompts have the words, the newest open, the words marked.") {
            shots.append(shot)
        }
        if let shot = await windowShot(window, expanded: found, mark: ["1 of 2"], then: { window.search.previous() }, title: "From one to the next",
                                       detail: "Return or ⌘G for the next, ⇧⌘G for the one before: each opens with its whole answer, the words marked in it too.") {
            shots.append(shot)
        }
        window.search.close()
        write(shots, to: "2-agent-windows/search.gif")
    }

    private func tokenUsage() async {
        var shots: [Shot] = []
        for (page, mark, title, detail) in [
            (StatisticsPage(period: .day), ["Today"], "Token usage", "Today, 7 days and 30 days: every agent's input, output and cache tokens, here and on your servers."),
            (StatisticsPage(period: .week, hovered: 5), [String](), "Day by day", "Each agent in its own colour. Point at a day for its numbers."),
            (StatisticsPage(period: .month), [String](), "30 days", "A month at a glance."),
            (StatisticsPage(period: .week, asTable: true), [String](), "As a table", "Every model's tokens, to compare."),
            (StatisticsPage(period: .week, byJob: true), ["By job"], "By job", "Each job of the period with its tokens, newest or most first."),
        ] {
            if let shot = await shot(page.frame(width: 350), mark: mark, title: title, detail: detail) {
                shots.append(shot)
            }
        }
        let open = model.jobUsage.jobs(.week, now: Date()).max { $0.usage.count < $1.usage.count }.map { Set([$0.id]) } ?? []
        if let shot = await shot(StatisticsPage(period: .week, byJob: true, openJobs: open).frame(width: 350), title: "A job, opened",
                                 detail: "Its models' input, output, cache write and cache read, and a link to its prompt.") {
            shots.append(shot)
        }
        write(shots, to: "3-token-usage/tokens.gif")
    }

    private func settingsTour() async {
        let servers = ["gpu-box", "build-server", "dev.example.org"]
        func page(_ tab: SettingsTab) -> some View {
            SettingsPage(tab: tab, suggestedServers: servers, done: {}).frame(width: 350)
        }
        // General, and servers.
        var general: [Shot] = []
        if let shot = await shot(page(.general), mark: ["Agents to track"], title: "Settings › General",
                                 detail: "The agents to track, selections, agent windows connecting as they open, what happens while agents work, and launch at login.") {
            general.append(shot)
        }
        if let shot = await shot(page(.servers), mark: ["gpu-box"], title: "Settings › Servers",
                                 detail: "Agents on your servers, over SSH: their finished jobs remind you, their windows open and Jump finds them, their tokens count.") {
            general.append(shot)
        }
        write(general, to: "4-settings/general-and-servers.gif")

        // While agents work.
        var working: [Shot] = []
        if let shot = await shot(page(.general), mark: ["Keep the Mac awake while an agent is working", "Show working agents on the lock screen"],
                                 title: "While agents work",
                                 detail: "Keep the Mac awake while one works (closing the lid still sleeps it), and list the agents at work on the lock screen.") {
            working.append(shot)
        }
        if let shot = await shot(page(.general), mark: ["Working now, keeping the Mac awake"], title: "Who's working now",
                                 detail: "The agents at work right now, here and on your servers; the Mac sleeps again when they're done.") {
            working.append(shot)
        }
        write(working, to: "4-settings/while-working.gif")

        // Reminders.
        var reminders: [Shot] = []
        if let shot = await shot(page(.reminders), mark: ["An agent finishes a job"], title: "Settings › Reminders",
                                 detail: "Which agents' finished jobs remind you, limit warnings, and how: a notification, a card on screen, or both.") {
            reminders.append(shot)
        }
        let toast = Toast(
            id: "tour", agent: .claude, title: "Claude Code job finished", subtitle: "Checkout test: is the new page better?",
            body: "shop · took 4m 12s\nFixed the pooled rate: all 9 tests pass.")
        if let shot = await shot(ToastView(toast: toast, close: {}, open: {}).padding(20).frame(width: 420), background: false,
                                 title: "A card on screen", detail: "Click it to open the agent window, or Jump straight to where it runs.") {
            reminders.append(shot)
        }
        write(reminders, to: "4-settings/reminders.gif")

        // Appearance: Agent Buddy's own, then agent windows'.
        var appearance: [Shot] = []
        if let shot = await shot(page(.appearance), mark: ["Frosted glass"], title: "Settings › Appearance",
                                 detail: "Light or dark; how see-through the panel and agent windows are; agent windows as frosted glass, or tabs; the text's size and typeface.") {
            appearance.append(shot)
        }
        if let shot = await shot(column { PopoverView() }, dark: true, background: false, title: "Dark",
                                 detail: "All of Agent Buddy, dark, whatever macOS uses (or light, or as macOS is).") {
            appearance.append(shot)
        }
        settings.floatingOpacity = 0.6
        if let shot = await shot(column(hudOpacity: 0.6) { page(.appearance) }, background: false, mark: ["Floating panel"],
                                 title: "See-through", detail: "Less opaque, the floating panel and agent windows let you see what's behind them.") {
            appearance.append(shot)
        }
        settings.floatingOpacity = 1
        defaults.set(1.25, forKey: DisplayStyle.scaleKey)
        defaults.set(MarkdownFont.serif.rawValue, forKey: DisplayStyle.fontKey)
        if let shot = await shot(SettingsPage(tab: .appearance, suggestedServers: servers, done: {}).frame(width: 350 * 1.25),
                                 mark: ["125%"], title: "Text size and typeface",
                                 detail: "The menu bar panel, floating panel, statistics and settings from 85% to 150%, in System, Serif or Mono.") {
            appearance.append(shot)
        }
        defaults.removeObject(forKey: DisplayStyle.scaleKey)
        defaults.removeObject(forKey: DisplayStyle.fontKey)
        write(appearance, to: "4-settings/appearance.gif")

        var windows: [Shot] = []
        if let shot = await windowShot(details(through: "4"), title: "Frosted glass",
                                       detail: "Agent windows let what's behind them show through, blurred; the message box stays solid. Settings › Appearance › Agent windows.") {
            windows.append(shot)
        }
        if let shot = await windowShot(details(through: "4"), dark: true, title: "Agent windows, dark",
                                       detail: "Answers, formulas and code follow Agent Buddy's appearance.") {
            windows.append(shot)
        }
        defaults.set(18.5, forKey: TextStyle.sizeKey)
        defaults.set(MarkdownFont.serif.rawValue, forKey: TextStyle.fontKey)
        if let shot = await windowShot(details(through: "4"), mark: ["Aa"], title: "Their own text size and typeface",
                                       detail: "Prompts, answers and the message box: Aa in the title bar, ⌘+ and ⌘− (or Settings › Appearance › Agent windows).") {
            windows.append(shot)
        }
        defaults.removeObject(forKey: TextStyle.sizeKey)
        defaults.removeObject(forKey: TextStyle.fontKey)
        write(windows, to: "4-settings/appearance-windows.gif")
    }

    // MARK: - Drawing

    /// A view drawn as it shows, with the parts labelled `mark` pointed at.
    private func shot<V: View>(
        _ view: V, dark: Bool = false, background: Bool = true, mark labels: [String] = [], together: Bool = false, title: String, detail: String
    ) async -> Shot? {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        let hosting = NSHostingView(rootView: AnyView(
            view.environmentObject(model).environmentObject(settings).defaultAppStorage(defaults).displayStyled()
                .background(background ? Color(nsColor: .windowBackgroundColor) : Color.clear)))
        hosting.appearance = appearance
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        await settle(0.4)
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return nil }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        window.close()
        guard let image = rep.cgImage else { return nil }
        return Shot(image: image, size: size, marks: Self.ring(Self.find(labels, in: image, size: size), together: together), title: title,
                    detail: detail, framed: background)
    }

    /// An agent window, title bar and all, its answers drawn by WebKit; `script`
    /// run on its pages first (a click), and its history scrolled by `scroll` points.
    /// An agent window as it opens: the pin, Tabs and Aa in its title bar, frosted.
    private func agentWindow(_ details: SessionDetails, expanded: Set<String> = [], dark: Bool = false) -> NSWindow {
        let host = NSHostingController(rootView: AnyView(
            SessionDetailsView(details: details, expanded: expanded).defaultAppStorage(defaults).displayStyled()
                .environment(\.glassPicture, true)))
        host.sizingOptions = []
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = details.agent.clientName
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.tabbingIdentifier = SessionDetailsController.tabbing
        window.tab.title = details.title
        SessionDetailsController.frost(window, true)
        let tabs = WindowTabsMenu(window: window, tabs: WindowTabs(), controller: tabsController)
        tabMenus.append(tabs)
        let pin = NSHostingView(rootView: AnyView(PinButton(details: details)))
        pin.frame = NSRect(x: 0, y: 0, width: 30, height: 28)
        let style = NSHostingView(rootView: AnyView(TextStyleButton().defaultAppStorage(defaults)))
        style.frame = NSRect(x: 0, y: 0, width: 36, height: 28)
        for (view, side) in [(pin as NSView, NSLayoutConstraint.Attribute.left), (style, .right), (tabs.view, .right)] {
            let accessory = NSTitlebarAccessoryViewController()
            accessory.view = view
            accessory.layoutAttribute = side
            window.addTitlebarAccessoryViewController(accessory)
        }
        window.setContentSize(NSSize(width: SessionDetailsController.defaultSize.width, height: 760))
        // Drawn, never seen: clear, and behind every other window.
        window.alphaValue = 0
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderBack(nil)
        return window
    }

    private func windowShot(
        _ details: SessionDetails, expanded: Set<String> = [], focus: String? = nil, dark: Bool = false, script: String? = nil,
        scroll: CGFloat = 0, mark labels: [String] = [], together: Bool = false, then: (() -> Void)? = nil, title: String, detail: String
    ) async -> Shot? {
        details.focus = focus
        SelectionWatcher.shared.preview(trusted: access.trusted, closedEditor: access.closedEditor)
        let window = agentWindow(details, expanded: expanded, dark: dark)
        defer { window.close() }
        return await capture(window, script: script, scroll: scroll, mark: labels, together: together, then: then, title: title, detail: detail)
    }

    /// Two agent windows merged into tabs of one, the first in front.
    private func tabsShot(_ first: SessionDetails, _ second: SessionDetails, mark labels: [String] = [], title: String, detail: String) async -> Shot? {
        SelectionWatcher.shared.preview(trusted: access.trusted, closedEditor: access.closedEditor)
        let one = agentWindow(first)
        let two = agentWindow(second)
        defer {
            two.close()
            one.close()
        }
        one.addTabbedWindow(two, ordered: .above)
        one.tabGroup?.selectedWindow = one
        return await capture(one, mark: labels, title: title, detail: detail)
    }

    private func capture(
        _ window: NSWindow, script: String? = nil, scroll: CGFloat = 0, mark labels: [String] = [], together: Bool = false,
        then: (() -> Void)? = nil, title: String, detail: String
    ) async -> Shot? {
        guard let content = window.contentView else { return nil }
        await settle(0.6)
        await settle(15) { HistorySelfTest.webViews(in: content).allSatisfy { !$0.isLoading } }
        await settle(1.4)
        // What's done once the window's up (typed into its box, as you would).
        if let then {
            then()
            await settle(0.8)
        }
        if let script {
            for page in HistorySelfTest.webViews(in: content) {
                _ = try? await page.evaluateJavaScript(script)
            }
            await settle(1)
        }
        if scroll != 0, let list = HistorySelfTest.scrollViews(in: content).max(by: { $0.frame.height < $1.frame.height }),
           let document = list.documentView {
            let top = list.contentView.bounds.origin.y
            let end = max(0, document.frame.height - list.contentView.bounds.height)
            let y = scroll == .infinity ? end : min(end, top + scroll)
            list.contentView.scroll(to: NSPoint(x: 0, y: y))
            list.reflectScrolledClipView(list.contentView)
            await settle(0.6)
        }
        guard let frame = content.superview ?? Optional(content) else { return nil }
        frame.layoutSubtreeIfNeeded()
        guard let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { return nil }
        frame.cacheDisplay(in: frame.bounds, to: rep)
        // A web view draws apart from the window's views: each page's picture goes on top.
        for page in HistorySelfTest.webViews(in: frame) {
            let visible = page.visibleRect
            guard !visible.isEmpty, let picture = try? await page.takeSnapshot(configuration: nil),
                  let context = NSGraphicsContext(bitmapImageRep: rep)
            else { continue }
            let source = NSRect(x: visible.minX, y: page.bounds.height - visible.maxY, width: visible.width, height: visible.height)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            picture.draw(in: page.convert(visible, to: frame), from: source, operation: .sourceOver, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
        }
        guard let image = rep.cgImage else { return nil }
        var shot = Shot(image: image, size: frame.bounds.size, marks: Self.ring(Self.find(labels, in: image, size: frame.bounds.size), together: together),
                        title: title, detail: detail)
        shot.frosted = true
        return shot
    }

    /// The question Agent Buddy asks before switching VS Code's screen reader mode on.
    private func alertShot(title: String, detail: String) async -> Shot? {
        let alert = NSAlert()
        alert.messageText = "Read what you select in VS Code?"
        alert.informativeText = """
            VS Code tells other apps what you select only in its screen reader mode. Agent Buddy can switch that on \
            while an agent window is open, the way a screen reader does, and back off after.

            Meanwhile VS Code shows \u{201C}Screen Reader Optimized\u{201D} in its status bar and may play accessibility \
            sounds (turn them down with the setting accessibility.signalOptions.volume). It also asks once whether \
            you use a screen reader: close that notice, as No stops it sharing.

            You can turn this off in Agent Buddy's settings.
            """
        alert.addButton(withTitle: "Switch On")
        alert.addButton(withTitle: "Cancel")
        alert.icon = NSImage(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Support/AppIcon.icns"))
        alert.window.appearance = NSAppearance(named: .aqua)
        alert.layout()
        guard let view = alert.window.contentView?.superview ?? alert.window.contentView else { return nil }
        view.layoutSubtreeIfNeeded()
        await settle(0.3)
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let image = rep.cgImage else { return nil }
        return Shot(image: image, size: view.bounds.size, marks: Self.find(["Switch On"], in: image, size: view.bounds.size), title: title,
                    detail: detail)
    }

    /// Where each of `labels` shows in `image` (drawn `size` points big), found by
    /// reading it: in points from the top left. A word on its own wins over one
    /// within a line, and the highest over those below it.
    static func find(_ labels: [String], in image: CGImage, size: CGSize) -> [CGRect] {
        guard !labels.isEmpty else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let lines = (request.results ?? []).compactMap { observation in
            observation.topCandidates(1).first.map { (observation, $0) }
        }
        return labels.compactMap { label in
            let found = lines.compactMap { observation, candidate -> (CGRect, Bool)? in
                guard let range = candidate.string.range(of: label) ?? candidate.string.range(of: label, options: .caseInsensitive) else { return nil }
                let box = (try? candidate.boundingBox(for: range))?.boundingBox ?? observation.boundingBox
                let whole = candidate.string.trimmingCharacters(in: .whitespaces) == label
                return (CGRect(x: box.minX * size.width, y: (1 - box.maxY) * size.height, width: box.width * size.width,
                               height: box.height * size.height), whole)
            }
            return found.sorted { ($0.1 ? 0 : 1, $0.0.minY) < ($1.1 ? 0 : 1, $1.0.minY) }.first?.0
        }
    }

    /// The marks, or one ring around them all.
    static func ring(_ marks: [CGRect], together: Bool) -> [CGRect] {
        guard together, let first = marks.first else { return marks }
        return [marks.dropFirst().reduce(first) { $0.union($1) }]
    }

    // MARK: - Writing

    /// Each GIF's pictures, kept until all are taken: every GIF is then drawn the same size.
    private var pending: [(path: String, shots: [Shot])] = []

    private func write(_ shots: [Shot], to path: String) {
        if !shots.isEmpty {
            pending.append((path, shots))
        }
    }

    /// Two pixels a point, as a Retina screen draws them: shown at half their
    /// size (`width` in the README), they're as sharp as the app itself.
    private let scale: CGFloat = 2

    private func captionText(_ shot: Shot, _ index: Int, of count: Int) -> NSAttributedString {
        let text = NSMutableAttributedString(string: shot.title, attributes: [
            .font: NSFont.systemFont(ofSize: 16 * scale, weight: .semibold), .foregroundColor: NSColor(white: 0.1, alpha: 1),
        ])
        text.append(NSAttributedString(string: "   \(index + 1) / \(count)", attributes: [
            .font: NSFont.systemFont(ofSize: 11.5 * scale, weight: .medium), .foregroundColor: NSColor(white: 0.55, alpha: 1),
        ]))
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacingBefore = 4 * scale
        paragraph.lineSpacing = 1.5 * scale
        text.append(NSAttributedString(string: "\n" + shot.detail, attributes: [
            .font: NSFont.systemFont(ofSize: 12.5 * scale), .foregroundColor: NSColor(white: 0.32, alpha: 1), .paragraphStyle: paragraph,
        ]))
        return text
    }

    /// Every GIF on one canvas, as big as the biggest needs: the caption band on
    /// top, then each picture in the middle of a plain desktop, copied pixel for
    /// pixel (never scaled, and at whole pixels), the parts it's about ringed.
    private func writeAll() {
        let pad: CGFloat = 26 * scale
        let margin: CGFloat = 16 * scale
        let all = pending.flatMap(\.shots)
        let width = (all.map { CGFloat($0.image.width) }.max() ?? 1) + pad * 2
        let below = (all.map { CGFloat($0.image.height) }.max() ?? 1) + pad * 2
        let band = ceil(pending.flatMap { gif in
            gif.shots.enumerated().map { index, shot in
                captionText(shot, index, of: gif.shots.count)
                    .boundingRect(with: NSSize(width: width - margin * 2, height: 2000), options: [.usesLineFragmentOrigin]).height
            }
        }.max() ?? 40) + margin * 2
        for shot in all where abs(CGFloat(shot.image.width) - shot.size.width * scale) > 1 {
            print("  warning: a picture \(shot.image.width) pixels wide for \(shot.size.width) points (\(shot.title))")
        }
        for gif in pending {
            draw(gif.shots, to: gif.path, width: width, below: below, band: band, margin: margin)
        }
        pending = []
    }

    private func draw(_ shots: [Shot], to path: String, width: CGFloat, below: CGFloat, band: CGFloat, margin: CGFloat) {
        let url = root.appendingPathComponent(path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let height = below + band
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, shots.count, nil) else { return }
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let desktop = NSColor(red: 0.42, green: 0.46, blue: 0.68, alpha: 1).cgColor
        var behind: Shot?
        for (index, shot) in shots.enumerated() {
            guard let context = CGContext(data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)
            else { continue }
            context.interpolationQuality = .none
            context.setFillColor(desktop)
            context.fill(CGRect(x: 0, y: 0, width: width, height: below))
            // Where a picture goes: in the middle of the desktop, at whole pixels, its
            // own size (a context's origin is at the bottom left).
            func place(_ shot: Shot) -> CGRect {
                let size = CGSize(width: shot.image.width, height: shot.image.height)
                return CGRect(origin: CGPoint(x: floor((width - size.width) / 2), y: floor((below - size.height) / 2)), size: size)
            }
            func draw(_ shot: Shot, dimmed: Bool = false) {
                let area = place(shot)
                let corners = CGPath(roundedRect: area, cornerWidth: 10 * scale, cornerHeight: 10 * scale, transform: nil)
                context.saveGState()
                if shot.framed {
                    context.setShadow(offset: CGSize(width: 0, height: -6 * scale), blur: 20 * scale, color: NSColor.black.withAlphaComponent(0.38).cgColor)
                    context.addPath(corners)
                    // Under frosted glass, the desktop (the shadow still falls).
                    context.setFillColor(shot.frosted ? desktop : NSColor.windowBackgroundColor.cgColor)
                    context.fillPath()
                    context.setShadow(offset: .zero, blur: 0, color: nil)
                    context.addPath(corners)
                    context.clip()
                }
                context.draw(shot.image, in: area)
                if dimmed {
                    context.setFillColor(NSColor.black.withAlphaComponent(0.36).cgColor)
                    context.fill(area)
                }
                context.restoreGState()
            }
            // A sheet over the window before it, dimmed.
            if shot.over, let behind {
                draw(behind, dimmed: true)
            } else {
                behind = shot
            }
            draw(shot)
            let area = place(shot)
            let pixels = CGSize(width: area.width / max(shot.size.width, 1), height: area.height / max(shot.size.height, 1))
            for (number, mark) in shot.marks.enumerated() {
                let ring = CGRect(x: area.minX + mark.minX * pixels.width, y: area.maxY - mark.maxY * pixels.height,
                                  width: mark.width * pixels.width, height: mark.height * pixels.height)
                    .insetBy(dx: -5 * scale, dy: -4 * scale).integral
                let path = CGPath(roundedRect: ring, cornerWidth: 7 * scale, cornerHeight: 7 * scale, transform: nil)
                context.addPath(path)
                context.setFillColor(NSColor.systemBlue.withAlphaComponent(0.10).cgColor)
                context.fillPath()
                context.addPath(path)
                context.setStrokeColor(NSColor.systemBlue.withAlphaComponent(0.9).cgColor)
                context.setLineWidth(2 * scale)
                context.strokePath()
                if number == 0 {
                    Self.pointer(at: CGPoint(x: min(ring.midX + ring.width * 0.18, ring.maxX - 5 * scale), y: ring.midY - 2 * scale), size: scale, in: context)
                }
            }
            // What it shows, on a band above it.
            context.setFillColor(NSColor.white.cgColor)
            context.fill(CGRect(x: 0, y: below, width: width, height: band))
            context.setFillColor(NSColor(white: 0.84, alpha: 1).cgColor)
            context.fill(CGRect(x: 0, y: below, width: width, height: scale))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            captionText(shot, index, of: shots.count).draw(
                with: NSRect(x: margin, y: below + margin, width: width - margin * 2, height: band - margin * 2), options: [.usesLineFragmentOrigin])
            NSGraphicsContext.restoreGraphicsState()
            guard let frame = context.makeImage() else { continue }
            let seconds = index == shots.count - 1 ? shot.seconds + 1 : shot.seconds
            CGImageDestinationAddImage(destination, frame, [kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: seconds, kCGImagePropertyGIFUnclampedDelayTime: seconds,
            ]] as CFDictionary)
        }
        if CGImageDestinationFinalize(destination) {
            let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0
            print("  \(path): \(shots.count) pictures, \(Int(width)) × \(Int(height)), \(bytes / 1024) KB")
        }
    }

    /// An arrow pointer, its tip at `tip` (a context's coordinates: y up).
    private static func pointer(at tip: CGPoint, size: CGFloat, in context: CGContext) {
        let points: [(CGFloat, CGFloat)] = [(0, 0), (0, -17), (4.2, -13.2), (7, -19.6), (9.6, -18.4), (6.8, -12.2), (12.2, -12.2)]
        let path = CGMutablePath()
        path.addLines(between: points.map { CGPoint(x: tip.x + $0.0 * size * 0.85, y: tip.y + $0.1 * size * 0.85) })
        path.closeSubpath()
        context.setShadow(offset: CGSize(width: 0, height: -size), blur: 3 * size, color: NSColor.black.withAlphaComponent(0.35).cgColor)
        context.addPath(path)
        context.setFillColor(NSColor.black.cgColor)
        context.fillPath()
        context.setShadow(offset: .zero, blur: 0, color: nil)
        context.addPath(path)
        context.setStrokeColor(NSColor.white.cgColor)
        context.setLineWidth(1.4 * size)
        context.strokePath()
    }

    // MARK: - Sample data

    private func at(_ minutes: Double) -> Date {
        start.addingTimeInterval(minutes * 60)
    }

    private func sampleReadings() -> [Agent: AgentReading] {
        let now = Date()
        return [
            .claude: AgentReading(agent: .claude, windows: [
                UsageWindow(id: "claude.weekly", kind: .weekly, title: "Weekly · All models", usedPercent: 38,
                            resetsAt: now.addingTimeInterval(3 * 86400 + 4 * 3600), windowSeconds: 7 * 86400),
                UsageWindow(id: "claude.weekly.fable", kind: .weeklyModel, title: "Weekly · Fable", usedPercent: 22,
                            resetsAt: now.addingTimeInterval(3 * 86400 + 4 * 3600), windowSeconds: 7 * 86400, detail: "Up to 50% of your week"),
            ], plan: "Ultra"),
            .codex: AgentReading(agent: .codex, windows: [
                UsageWindow(id: "codex.codex.primary", kind: .weekly, title: "Weekly limit", usedPercent: 48,
                            resetsAt: now.addingTimeInterval(4 * 86400 + 2 * 3600), windowSeconds: 7 * 86400),
            ], plan: "Pro", notes: ["1 free limit reset available in Codex"]),
            .copilot: AgentReading(agent: .copilot, windows: [
                UsageWindow(id: "copilot.premium_interactions", kind: .monthly, title: "Premium requests", usedPercent: 27,
                            resetsAt: Calendar.current.date(byAdding: .day, value: 9, to: now), detail: "81 / 300 requests"),
            ], plan: "Pro"),
        ]
    }

    private func sampleForecast(announced: Bool) -> CodexResetForecast {
        var forecast = CodexResetForecast(
            lastResetAt: Date().addingTimeInterval(-34 * 3600), chance24h: 53, chance48h: 78, confidence: "medium",
            usualHours: "12 PM - 3 PM")
        if announced {
            forecast.announced = CodexResetForecast.Announcement(
                summary: "Resetting Codex rate limits for everyone this afternoon.", window: "this afternoon",
                start: Date().addingTimeInterval(3600), end: Date().addingTimeInterval(4 * 3600), target: Date().addingTimeInterval(95 * 60))
        }
        return forecast
    }

    private func sampleJobs() -> [JobEvent] {
        let now = Date()
        func job(_ id: String, _ agent: Agent, _ outcome: JobEvent.Outcome, _ session: String, _ title: String, _ project: String,
                 _ ago: Double, _ minutes: Double, server: String? = nil, summary: String? = nil) -> JobEvent {
            JobEvent(id: id, agent: agent, outcome: outcome, sessionID: session, title: title, project: project, summary: summary,
                     startedAt: now.addingTimeInterval(-ago * 60 - minutes * 60), finishedAt: now.addingTimeInterval(-ago * 60), source: server)
        }
        return [
            job("tour-1", .claude, .completed, "tour", "Checkout test: is the new page better?", "shop", 1, 4,
                summary: "Fixed the pooled rate: all 9 tests pass."),
            job("tour-1b", .claude, .completed, "tour", "Checkout test: is the new page better?", "shop", 22, 9),
            job("tour-2", .codex, .completed, "tour-2", "Add dark mode to the dashboard", "dashboard", 9, 12),
            job("tour-3", .claude, .completed, "tour-3", "Move the API to FastAPI", "api", 26, 31, server: "build-server"),
            job("tour-4", .gemini, .completed, "tour-4", "Summarize this week's meeting notes", "notes", 48, 3),
            job("tour-5", .copilot, .failed, "tour-5", "Fix the flaky login test", "mobile", 75, 6),
        ]
    }

    private func sampleArchive() -> SessionArchive {
        var archive = SessionArchive()
        for job in sampleJobs() {
            archive.record(job)
        }
        for (index, (agent, title, project)) in [
            (Agent.deepseek, "Translate the docs into Spanish", "docs"), (.qwen, "Write the release notes for 2.3", "app"),
            (.opencode, "Remove the old feature flags", "web"), (.cursor, "Tidy up the landing page's CSS", "site"),
        ].enumerated() {
            archive.record(JobEvent(id: "old-\(index)", agent: agent, outcome: .completed, sessionID: "old-\(index)", title: title,
                                    project: project, finishedAt: Date().addingTimeInterval(-Double(index + 1) * 86400 - 3600)))
        }
        return archive
    }

    private func sampleWorking() -> [WorkingSession] {
        let now = Date()
        return [
            WorkingSession(agent: .claude, source: nil, sessionID: "tour", name: "Checkout test: is the new page better?", folder: "/Users/me/shop",
                           task: "Plot both conversion rates by day, with a 95% band", since: now.addingTimeInterval(-140),
                           lastWork: now.addingTimeInterval(-3)),
            WorkingSession(agent: .codex, source: "gpu-box", sessionID: "tour-6", name: "Train the recommender", folder: "/home/me/recommender",
                           task: "Resume from the last checkpoint and log the loss", since: now.addingTimeInterval(-1260),
                           lastWork: now.addingTimeInterval(-20)),
        ]
    }

    /// 30 days of tokens: Claude most days, Codex often, Copilot and Gemini now and then.
    private func sampleTokens() -> [TokenEntry] {
        var entries: [TokenEntry] = []
        let day = Calendar.current.startOfDay(for: Date())
        for back in 0..<30 {
            let date = day.addingTimeInterval(-Double(back) * 86400 + 11 * 3600)
            let weekday = Calendar.current.component(.weekday, from: date)
            let busy = weekday == 1 || weekday == 7 ? 0.35 : 1.0
            let wave = 0.6 + 0.4 * sin(Double(back) * 0.9) * sin(Double(back) * 0.31 + 1)
            func counts(_ size: Double, _ cache: Double) -> TokenCounts {
                let scale = size * busy * (0.55 + abs(wave))
                return TokenCounts(input: Int(scale * 1_200), output: Int(scale * 9_000), cacheWrite: Int(scale * 60_000), cacheRead: Int(scale * cache))
            }
            // Through the working day: a little each hour from 9 to 6.
            for hour in 0..<9 {
                let share = (0.4 + 0.6 * abs(sin(Double(hour + back) * 1.3))) / 6
                let at = date.addingTimeInterval(Double(hour - 2) * 3600)
                entries.append(TokenEntry(agent: .claude, model: "claude-fable-5-1", at: at, counts: counts(9 * share, 1_300_000)))
                if hour % 2 == 0 {
                    entries.append(TokenEntry(agent: .claude, model: "claude-opus-5-5", at: at.addingTimeInterval(1200), counts: counts(4 * share, 900_000)))
                }
            }
            entries.append(TokenEntry(agent: .claude, model: "claude-haiku-5-5", at: date.addingTimeInterval(7200), counts: counts(2, 120_000)))
            if back % 3 != 2 {
                entries.append(TokenEntry(agent: .codex, model: "gpt-6.1-sol", at: date.addingTimeInterval(1800), counts: counts(6, 700_000),
                                          source: back % 2 == 0 ? "gpu-box" : nil))
                entries.append(TokenEntry(agent: .claude, model: "claude-fable-5-1", at: date.addingTimeInterval(4200), counts: counts(2, 300_000),
                                          source: back % 3 == 0 ? "build-server" : nil))
            }
            if back % 4 == 0 {
                entries.append(TokenEntry(agent: .copilot, model: "claude-sonnet-5-5", at: date.addingTimeInterval(5400), counts: counts(1.5, 90_000)))
            }
            if back % 5 == 1 {
                entries.append(TokenEntry(agent: .gemini, model: "gemini-3-pro", at: date.addingTimeInterval(9000), counts: counts(2.5, 200_000)))
            }
            if back % 6 == 2 {
                entries.append(TokenEntry(agent: .deepseek, model: "deepseek-v4", at: date.addingTimeInterval(10_800), counts: counts(2, 150_000)))
            }
            if back % 7 == 3 {
                entries.append(TokenEntry(agent: .qwen, model: "qwen3-coder", at: date.addingTimeInterval(12_600), counts: counts(1.5, 90_000)))
            }
        }
        return entries
    }

    private func sampleUsageSessions() -> [UsageSession] {
        let now = Date()
        func turn(_ id: String, _ text: String, _ ago: Double, _ minutes: Double, _ usage: [ModelTokens]) -> PromptTurn {
            PromptTurn(id: id, text: text, askedAt: now.addingTimeInterval(-ago * 3600), parent: nil, answer: "Done.",
                       endedAt: now.addingTimeInterval(-ago * 3600 + minutes * 60), outcome: .completed, usage: usage)
        }
        func tokens(_ model: String, _ size: Int) -> ModelTokens {
            ModelTokens(model: model, counts: TokenCounts(input: size, output: size * 8, cacheWrite: size * 50, cacheRead: size * 900))
        }
        var shop = SessionHistory(agent: .claude, sessionID: "tour", title: "Checkout test: is the new page better?", cwd: "/Users/me/shop", turns: [
            turn("j1", "Add a test for the z-score, and fix the pooled rate in stats.py.", 2, 4,
                 [tokens("claude-fable-5-1", 1_400), tokens("claude-haiku-5-5", 600)]),
            turn("j2", "Is variant B really better? Work out the significance, and give me a script to check it.", 5, 9,
                 [tokens("claude-opus-5-5", 2_100)]),
        ])
        shop.logPath = "/Users/me/.claude/projects/shop/tour.jsonl"
        let api = SessionHistory(agent: .claude, sessionID: "tour-3", title: "Move the API to FastAPI", cwd: "/home/me/api", turns: [
            turn("j3", "Move the API from Flask to FastAPI, keeping every route and its tests.", 26, 31, [tokens("claude-fable-5-1", 3_800)]),
        ])
        let dashboard = SessionHistory(agent: .codex, sessionID: "tour-2", title: "Add dark mode to the dashboard", cwd: "/Users/me/dashboard", turns: [
            turn("j4", "Add dark mode to the dashboard, following the system setting.", 9, 12, [tokens("gpt-6.1-sol", 2_600)]),
        ])
        let notes = SessionHistory(agent: .gemini, sessionID: "tour-4", title: "Summarize this week's meeting notes", cwd: "/Users/me/notes", turns: [
            turn("j5", "Summarize this week's meeting notes into decisions and to-dos.", 48, 3, [tokens("gemini-3-pro", 900)]),
        ])
        return [UsageSession(key: "claude||tour", source: nil, history: shop),
                UsageSession(key: "claude|build-server|tour-3", source: "build-server", history: api),
                UsageSession(key: "codex||tour-2", source: nil, history: dashboard),
                UsageSession(key: "gemini||tour-4", source: nil, history: notes)]
    }

    /// The sample agent window, made up: a shop's checkout A/B test, worked out in
    /// Claude Code over an afternoon; the third prompt was edited away and asked again.
    private func details(through last: String, withSeparate: Bool = false, withSelection: Bool = false, host: String? = nil) -> SessionDetails {
        let usage = [ModelTokens(model: "claude-fable-5-1", counts: TokenCounts(input: 1_120, output: 21_400, cacheWrite: 88_000, cacheRead: 2_640_000))]
        var turns = [
            PromptTurn(id: "1", text: "Set up a small Python package that reads the checkout events export.", askedAt: at(0), parent: nil,
                       answer: "Done: `shop/events.py` loads the CSV export, and `pip install -e .` sets it up.",
                       endedAt: at(14), outcome: .completed, usage: usage),
            PromptTurn(id: "2", text: "Count purchases per variant, and plot them by day.", askedAt: at(20), parent: "1",
                       answer: "`shop/report.py` counts them and draws the plot.", endedAt: at(31), outcome: .completed),
            PromptTurn(id: "3", text: "Switch the plots to Plotly.", askedAt: at(40), parent: "2",
                       answer: "Started on Plotly: `report.py` builds the figures with `plotly.express`.", endedAt: at(46), outcome: .interrupted),
            PromptTurn(id: "3b", text: "Keep Matplotlib, but add a 95% confidence band.", askedAt: at(47), parent: "2",
                       answer: "Each variant's line now has its 95% band.", endedAt: at(58), outcome: .completed),
            PromptTurn(id: "4", text: "Is variant B really better? Work out the significance, and give me a script to check it.", askedAt: at(70),
                       parent: "3b", answer: Self.derivation, endedAt: at(79), outcome: .completed, usage: usage),
            PromptTurn(id: "5", text: "Add a test for the z-score, and fix the pooled rate in stats.py.", askedAt: at(120), parent: "4",
                       answer: "Fixed the pooled rate in `z_test()`: all 9 tests pass.", endedAt: at(124), outcome: .completed, usage: usage),
        ]
        if withSelection, let index = turns.firstIndex(where: { $0.id == "5" }) {
            turns[index].selections = [PromptSelection(source: "stats.py, lines 12\u{2013}14",
                                                       text: "    p_a, p_b = x_a / n_a, x_b / n_b\n    pooled = (x_a + x_b) / (n_a + n_b)\n    se = sqrt(pooled * (1 - pooled) * (1 / n_a + 1 / n_b))")]
        }
        if withSeparate {
            turns.append(PromptTurn(id: "4s", text: "Summarize the result in two lines for the README.", askedAt: at(90), parent: "4",
                                    answer: "Variant B converts 18% better (3.61% against 3.05%), with p = 0.014.", endedAt: at(91),
                                    outcome: .completed, separate: true))
        }
        let keep = turns.prefix { $0.id != last } + turns.filter { $0.id == last } + (withSeparate ? turns.filter { $0.id == "4s" } : [])
        var history = SessionHistory(agent: .claude, sessionID: "tour", title: "Checkout test: is the new page better?", cwd: "/Users/me/shop",
                                     client: "cli", gitBranch: "main", turns: Array(keep))
        history.model = "claude-fable-5-1"
        history.permissionMode = "auto"
        let place = SessionPlace(
            appName: "Zed", appURL: URL(fileURLWithPath: "/Applications/Zed.app"), bundleID: "dev.zed.Zed",
            move: .zed(URL(fileURLWithPath: "/Users/me/shop")), exact: true, detail: host.map { "the shop window on \($0)" } ?? "the shop window")
        let info = WindowInfo(title: history.title, project: "shop", path: nil, finished: [at(14), at(79), at(124)])
        return SessionDetails(preview: history, info: info, host: host, place: .found(place))
    }

    /// A second session, for a window's other tab.
    private func otherSession() -> SessionDetails {
        var history = SessionHistory(agent: .codex, sessionID: "tour-codex", title: "Fix the login page", cwd: "/Users/me/site",
                                     client: "cli", gitBranch: "main", turns: [
                                         PromptTurn(id: "c1", text: "The login page forgets me. Fix it, and add a test.", askedAt: at(100), parent: nil,
                                                    answer: "Fixed: Remember me now keeps you signed in for 30 days, with a test.", endedAt: at(108),
                                                    outcome: .completed),
                                     ])
        history.model = "gpt-6.1-sol"
        let place = SessionPlace(
            appName: "Zed", appURL: URL(fileURLWithPath: "/Applications/Zed.app"), bundleID: "dev.zed.Zed",
            move: .zed(URL(fileURLWithPath: "/Users/me/site")), exact: true, detail: "the site window")
        return SessionDetails(preview: history, info: WindowInfo(title: history.title, project: "site", path: nil, finished: [at(108)]),
                              host: nil, place: .found(place))
    }

    private static let derivation = #"""
    Each variant converts at $\hat p_i = x_i / n_i$: $x_i$ purchases from $n_i$ visitors. If both convert alike, the best guess at their common rate is the pooled

    $$\hat p = \frac{x_A + x_B}{n_A + n_B},$$

    and the two-proportion $z$-test asks how far apart the two rates are, in standard errors:

    $$z = \frac{\hat p_B - \hat p_A}{\sqrt{\hat p\,(1-\hat p)\left(\frac{1}{n_A} + \frac{1}{n_B}\right)}}, \qquad p = 2\,\bigl(1 - \Phi(|z|)\bigr).$$

    | Variant | Visitors | Purchases | Rate |
    | --- | --- | --- | --- |
    | A (old page) | 12,480 | 381 | 3.05% |
    | B (new page) | 12,512 | 452 | 3.61% |

    That's $z = 2.46$ and $p = 0.014$: B is better at the 5% level, by $0.56$ points, about $18\%$ more purchases.

    A script to check it:

    ```python
    from math import sqrt
    from scipy.stats import norm

    def z_test(x_a, n_a, x_b, n_b):
        p_a, p_b = x_a / n_a, x_b / n_b
        pooled = (x_a + x_b) / (n_a + n_b)
        z = (p_b - p_a) / sqrt(pooled * (1 - pooled) * (1 / n_a + 1 / n_b))
        return z, 2 * (1 - norm.cdf(abs(z)))

    z, p = z_test(381, 12_480, 452, 12_512)
    print(f"z = {z:.2f}, p = {p:.3f}")
    ```

    It prints `z = 2.46, p = 0.014`.
    """#

    private func sampleSteps() -> [TurnStep] {
        [
            TurnStep(kind: .said, text: "I'll read `stats.py`, then run the tests."),
            TurnStep(kind: .ran, text: "Read(shop/stats.py)", outcome: "Read 64 lines"),
            TurnStep(kind: .ran, text: "Search(\"pooled\" in shop)", outcome: "Found 2 lines"),
            TurnStep(kind: .ran, text: "Bash(pytest -q)", outcome: "1 failed, 7 passed",
                     output: "FAILED tests/test_stats.py::test_known_example\n    assert round(z, 2) == 2.46\nE   assert 1.77 == 2.46\n1 failed, 7 passed in 0.38s",
                     failed: true),
            TurnStep(kind: .said, text: "`pooled` divides by $n_A$ alone instead of $n_A + n_B$, so $z$ comes out at $1.77$ instead of $2.46$."),
            TurnStep(kind: .changed, text: "Update(shop/stats.py)", outcome: "1 addition, 1 removal", hunks: [
                DiffHunk(oldStart: 12, newStart: 12, lines: [
                    "     p_a, p_b = x_a / n_a, x_b / n_b",
                    "-    pooled = (x_a + x_b) / n_a",
                    "+    pooled = (x_a + x_b) / (n_a + n_b)",
                    "     se = sqrt(pooled * (1 - pooled) * (1 / n_a + 1 / n_b))",
                ]),
            ]),
            TurnStep(kind: .changed, text: "Write(tests/test_ztest.py)", outcome: "8 lines", hunks: [
                DiffHunk(oldStart: 0, newStart: 1, lines: [
                    "+from shop.stats import z_test",
                    "+",
                    "+",
                    "+def test_known_example():",
                    "+    z, p = z_test(381, 12_480, 452, 12_512)",
                    "+    assert round(z, 2) == 2.46",
                    "+    assert round(p, 3) == 0.014",
                    "+",
                ]),
            ]),
            TurnStep(kind: .ran, text: "Bash(pytest -q)", outcome: "9 passed in 0.41s"),
            TurnStep(kind: .ran, text: "Bash(python scripts/check_ab.py)", outcome: "z = 2.46, p = 0.014"),
            TurnStep(kind: .said, text: "Fixed the pooled rate in `z_test()`: the known example now gives $z = 2.46$ and $p = 0.014$, and the new test checks it. All 9 tests pass."),
        ]
    }

    private static func turnSteps(_ steps: [TurnStep]) -> SessionDetails.TurnSteps {
        let json = (try? JSONEncoder().encode(steps)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        return SessionDetails.TurnSteps(steps: steps, json: json)
    }
}
