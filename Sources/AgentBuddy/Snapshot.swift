import AppKit
import AgentBuddyCore
import SwiftUI

/// `AgentBuddy --snapshot <folder>`: reads the live limits, then writes the menu bar
/// item, the popover and the settings page as PNGs in light and dark, to check
/// the UI without clicking through it. Nothing is saved or notified.
@MainActor
enum Snapshot {
    static func run(into folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let settings = AppSettings()
        let model = AppModel(settings: settings, notifier: Notifier())
        model.refreshAll(force: true)
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline,
              !model.refreshing.isEmpty || model.readings.count + model.errors.count < settings.trackedAgents.count {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        if model.jobs.isEmpty {
            model.preview(jobs: sampleJobs())
        }
        // codex-reset.com's forecast, asked once above; a sample if it didn't come.
        let asked = Date().addingTimeInterval(15)
        while model.codexResets == nil, Date() < asked {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        if model.codexResets == nil {
            model.preview(codexResets: CodexResetForecast(
                lastResetAt: Date().addingTimeInterval(-34 * 60), chance24h: 53, chance48h: 78, confidence: "medium",
                usualHours: "12 PM - 3 PM"))
        }
        model.refreshTokens(force: true)
        let counted = Date().addingTimeInterval(120)
        while model.tokenEntries == nil || model.countingTokens, Date() < counted {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        for (name, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
            guard let appearance = NSAppearance(named: appearanceName) else { continue }
            let bar = MenuBarRenderer.image(model.menuSegments(), badge: model.jobWindows.count)
            writeMenuBar(bar, appearance: appearance, dark: appearanceName == .darkAqua, to: folder.appendingPathComponent("menubar-\(name).png"))
            writeMenuBar(
                tinted(AppSymbol.image(), dark: appearanceName == .darkAqua), appearance: appearance,
                dark: appearanceName == .darkAqua, to: folder.appendingPathComponent("menubar-icon-\(name).png"))
            let popover = PopoverView().environmentObject(model).environmentObject(settings)
            write(popover, appearance: appearance, to: folder.appendingPathComponent("popover-\(name).png"))
            for (file, page) in [
                ("stats-day", StatisticsPage(period: .day)),
                ("stats-week-hover", StatisticsPage(period: .week, hovered: 5)),
                ("stats-month", StatisticsPage(period: .month)),
                ("stats-table", StatisticsPage(period: .week, asTable: true)),
            ] {
                write(page.environmentObject(model).environmentObject(settings).frame(width: 350), appearance: appearance,
                      to: folder.appendingPathComponent("\(file)-\(name).png"))
            }
            let hud = FloatingHUDView()
                .environmentObject(model)
                .environmentObject(settings)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: FloatingHUDController.cornerRadius))
                .padding(10)
            write(hud, appearance: appearance, to: folder.appendingPathComponent("floating-\(name).png"))
            let toast = Toast(
                id: "sample", agent: .claude, title: "Claude Code job finished", subtitle: "Sample: menu bar app",
                body: "head_show · took 4m 12s\nThe app builds and the checks pass.")
            write(ToastView(toast: toast, close: {}, open: {}).padding(10), appearance: appearance,
                  to: folder.appendingPathComponent("toast-\(name).png"))
        }
        if let light = NSAppearance(named: .aqua) {
            // Each tab of Settings.
            for tab in SettingsTab.allCases where tab != .phone {
                let page = SettingsPage(tab: tab, done: {}).environmentObject(model).environmentObject(settings).frame(width: 350)
                write(page, appearance: light, to: folder.appendingPathComponent("settings-\(tab.rawValue)-light.png"))
            }
            // The General display size and typeface, as Settings › Appearance sets them.
            let larger = SettingsPage(tab: .appearance, done: {}).environmentObject(model).environmentObject(settings).frame(width: 350 * 1.25)
                .environment(\.displayTextScale, 1.25).environment(\.displayTextDesign, .serif)
            write(larger, appearance: light, to: folder.appendingPathComponent("settings-larger-serif-light.png"))
        }
        // Several jobs finished in one agent window fold into one row.
        model.preview(jobs: sampleJobs())
        for (name, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
            guard let appearance = NSAppearance(named: appearanceName) else { continue }
            let popover = PopoverView().environmentObject(model).environmentObject(settings)
            write(popover, appearance: appearance, to: folder.appendingPathComponent("popover-folded-\(name).png"))
        }
        // Codex's card while a reset for everyone is announced.
        if let light = NSAppearance(named: .aqua), let live = model.codexResets {
            var announced = live
            announced.announced = CodexResetForecast.Announcement(
                summary: "Resetting Codex rate limits for everyone this afternoon.", window: "this afternoon",
                start: Date().addingTimeInterval(3600), end: Date().addingTimeInterval(4 * 3600), target: Date().addingTimeInterval(95 * 60))
            model.preview(codexResets: announced)
            let card = AgentCard(agent: .codex).environmentObject(model).environmentObject(settings).frame(width: 326).padding(12)
            write(card, appearance: light, to: folder.appendingPathComponent("codex-announced-light.png"))
            model.preview(codexResets: live)
            // And without one: nothing about everyone's resets.
            let quiet = AgentCard(agent: .codex).environmentObject(model).environmentObject(settings).frame(width: 326).padding(12)
            var none = live
            none.announced = nil
            model.preview(codexResets: none)
            write(quiet, appearance: light, to: folder.appendingPathComponent("codex-quiet-light.png"))
            model.preview(codexResets: live)
        }
        // An agent window's prompts, with a branch that was edited away.
        let (history, historyJobs) = sampleHistory()
        let info = WindowInfo(
            title: history.title, project: "head_show", path: nil, finished: historyJobs.map(\.finishedAt))
        let place = SessionPlace(
            appName: "Zed", appURL: URL(fileURLWithPath: "/Applications/Zed.app"), bundleID: "dev.zed.Zed",
            move: .zed(URL(fileURLWithPath: "/Users/me/head_show")), exact: true, detail: "the head_show window")
        for (name, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
            guard let appearance = NSAppearance(named: appearanceName) else { continue }
            let details = SessionDetails(preview: history, info: info, host: nil, place: .found(place))
            write(SessionDetailsView(details: details, expanded: ["3b"]).frame(width: 540, height: 640), appearance: appearance,
                  to: folder.appendingPathComponent("history-\(name).png"))
        }
        // The message box's bar with choices made and files added: Claude Code, then Codex with its models.
        if let light = NSAppearance(named: .aqua) {
            let chosen = SessionDetails(preview: history, info: info, host: nil, place: .found(place))
            chosen.composing.options = PromptSender.Options(model: "opus", effort: "high", fast: true, mode: "auto")
            chosen.composing.files = [URL(fileURLWithPath: "/Users/me/Desktop/Screenshot 2026-10-27 at 9.41.png"),
                                      URL(fileURLWithPath: "/Users/me/head_show/notes/plan.pdf")]
            write(SessionDetailsView(details: chosen).frame(width: 540, height: 420), appearance: light,
                  to: folder.appendingPathComponent("history-composer-claude-light.png"))
            // As narrow as a window goes, with the longest choices: the bar's controls stay on one line.
            let narrow = SessionDetails(preview: history, info: info, host: nil, place: .found(place))
            narrow.composing.options = PromptSender.Options(model: "opus", effort: "xhigh", fast: true, mode: "acceptEdits")
            write(SessionDetailsView(details: narrow).frame(width: 420, height: 420), appearance: light,
                  to: folder.appendingPathComponent("history-composer-narrow-light.png"))
            // @ typed: the folder's files that match.
            let mentioning = SessionDetails(preview: history, info: info, host: nil, place: .found(place))
            mentioning.composing.projectFiles = ["Sources/AgentBuddy/main.swift", "Sources/AgentBuddy/SessionManager.swift",
                                                 "docs/manual.md", "Makefile", "README.md"]
            mentioning.composing.commands = []
            mentioning.composing.suggestions.details = mentioning
            mentioning.draft = "Explain @ma"
            mentioning.composing.suggestions.update()
            write(SessionDetailsView(details: mentioning).frame(width: 540, height: 520), appearance: light,
                  to: folder.appendingPathComponent("history-mention-light.png"))
            // Made small: the history keeps its room, and a long message wraps in the box.
            for (name, size) in [("smallest", CGSize(width: 360, height: 340)), ("small", CGSize(width: 420, height: 420))] {
                let small = SessionDetails(preview: history, info: info, host: nil, place: .found(place))
                small.draft = "Make the tree show which prompts were edited away, and keep the jump button on the same line as the title when the window is narrow."
                write(SessionDetailsView(details: small).frame(width: size.width, height: size.height), appearance: light,
                      to: folder.appendingPathComponent("history-\(name)-light.png"))
            }
            let crowded = SessionDetails(preview: history, info: info, host: nil, place: .found(place))
            crowded.showSending(PromptSender.Started(agent: .claude, host: nil, pid: getpid(), log: "/dev/null", at: Date()),
                                text: "When I click a reminder, show the tree of what I asked.")
            crowded.previewQueued(["Then add a Jump button beside it.", "And write a test for the tree's order."])
            crowded.search.open()
            crowded.search.search("badge", in: history.rows)
            write(SessionDetailsView(details: crowded).frame(width: 400, height: 460), appearance: light,
                  to: folder.appendingPathComponent("history-small-busy-light.png"))
            // Searched for: the prompts that have the words, open, the words marked.
            let searching = SessionDetails(preview: history, info: info, host: nil, place: .found(place))
            searching.search.open()
            searching.search.search("badge", in: history.rows)
            write(SessionDetailsView(details: searching, expanded: Set(searching.search.matches)).frame(width: 540, height: 640),
                  appearance: light, to: folder.appendingPathComponent("history-search-light.png"))
            // A prompt under way, two more queued behind it, and another being typed.
            let busy = SessionDetails(preview: history, info: info, host: nil, place: .found(place))
            busy.showSending(PromptSender.Started(agent: .claude, host: nil, pid: getpid(), log: "/dev/null", at: Date()),
                             text: "When I click a reminder, show the tree of what I asked.")
            busy.previewQueued(["Then add a Jump button beside it.", "And write a test for the tree's order."])
            busy.draft = "Keep the old window's size"
            write(SessionDetailsView(details: busy).frame(width: 540, height: 460), appearance: light,
                  to: folder.appendingPathComponent("history-queued-light.png"))
            var codex = history
            codex.agent = .codex
            codex.model = "gpt-6-astra"
            codex.effort = "xhigh"
            codex.approvalPolicy = "on-request"
            codex.approvalsReviewer = "auto_review"
            codex.permissionProfile = ":workspace"
            let coding = SessionDetails(preview: codex, info: info, host: "203.0.113.7", place: .found(place))
            coding.composing.codexModels = [
                CodexModel(id: "gpt-6.1-sol", name: "GPT-6.1-Sol", efforts: ["low", "medium", "high", "xhigh", "max", "ultra"],
                           defaultEffort: "low", fast: true, isDefault: true),
                CodexModel(id: "gpt-6-astra", name: "GPT-6-Astra", efforts: ["low", "medium", "high", "xhigh", "max", "ultra"],
                           defaultEffort: "low", fast: true, isDefault: false),
            ]
            write(SessionDetailsView(details: coding).frame(width: 540, height: 420), appearance: light,
                  to: folder.appendingPathComponent("history-composer-codex-light.png"))
            // The signal for a session on a server, open here: measured, then unreachable (as previewed; no server's asked).
            ConnectionMonitor.shared.live = false
            SessionKeeper.shared.preview(.ready, for: coding.key)
            ConnectionMonitor.shared.preview(.roundTrip(RoundTrip.Measured(milliseconds: 126, how: "ping")), for: "203.0.113.7")
            write(SessionDetailsView(details: coding).frame(width: 580, height: 700), appearance: light,
                  to: folder.appendingPathComponent("history-signal-remote-light.png"))
            ConnectionMonitor.shared.links["203.0.113.7"] = .retrying("timeout")
            write(SessionDetailsView(details: coding).frame(width: 580, height: 700), appearance: light,
                  to: folder.appendingPathComponent("history-signal-disconnected-light.png"))
            ConnectionMonitor.shared.links["203.0.113.7"] = nil
            ConnectionMonitor.shared.preview(nil, for: "203.0.113.7")
            SessionKeeper.shared.preview(nil, for: coding.key)
            // A session on this Mac, open here: a green light.
            let keptHere = SessionDetails(preview: history, info: info, host: nil, place: .found(place))
            SessionKeeper.shared.preview(.ready, for: keptHere.key)
            write(SessionDetailsView(details: keptHere).frame(width: 580, height: 700), appearance: light,
                  to: folder.appendingPathComponent("history-signal-local-light.png"))
            SessionKeeper.shared.preview(nil, for: keptHere.key)
            coding.composing.options = PromptSender.Options(effort: "xhigh", fast: true, mode: "read-only")
            write(SessionDetailsView(details: coding).frame(width: 420, height: 420), appearance: light,
                  to: folder.appendingPathComponent("history-composer-codex-narrow-light.png"))
        }
        let closed = SessionDetails(
            preview: history, info: info, host: "203.0.113.7",
            place: .closed("No VS Code, Zed or terminal window is connected to 203.0.113.7."))
        if let light = NSAppearance(named: .aqua) {
            write(SessionDetailsView(details: closed).frame(width: 540, height: 420), appearance: light,
                  to: folder.appendingPathComponent("history-closed-light.png"))
        }
        // Each job's tokens, from the session logs on this Mac.
        model.jobUsage.refresh(archive: SessionArchive())
        let read = Date().addingTimeInterval(120)
        while model.jobUsage.loading, Date() < read {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        if let light = NSAppearance(named: .aqua) {
            write(StatisticsPage(period: .week, byJob: true).environmentObject(model).environmentObject(settings).frame(width: 350),
                  appearance: light, to: folder.appendingPathComponent("stats-jobs-light.png"))
            // The one using the most models, open.
            let open = model.jobUsage.jobs(.week, now: Date()).max { $0.usage.count < $1.usage.count }.map { Set([$0.id]) } ?? []
            write(StatisticsPage(period: .week, byJob: true, openJobs: open).environmentObject(model).environmentObject(settings)
                    .frame(width: 350),
                  appearance: light, to: folder.appendingPathComponent("stats-jobs-open-light.png"))
        }
        // The agent windows kept after the list is cleared.
        var archive = SessionArchive()
        for job in sampleJobs() + historyJobs.map({ job -> JobEvent in
            var job = job
            job.title = "Agent usage menu bar app"
            job.project = "head_show"
            return job
        }) {
            archive.record(job)
        }
        var older = JobEvent(id: "old-1", agent: .copilot, outcome: .completed, sessionID: "c9", title: "Add API tests",
                             project: "api", finishedAt: Date().addingTimeInterval(-3 * 86400))
        archive.record(older)
        older.id = "old-2"
        older.finishedAt = Date().addingTimeInterval(-3 * 86400 + 600)
        archive.record(older)
        model.preview(archive: archive)
        if let light = NSAppearance(named: .aqua) {
            write(HistoryPage().environmentObject(model).environmentObject(settings).frame(width: 350), appearance: light,
                  to: folder.appendingPathComponent("windows-light.png"))
        }
        // The iPhone settings, turned on in a scratch domain so yours stay as they are.
        let scratch = "io.github.homoy.agentbuddy.snapshot"
        if let defaults = UserDefaults(suiteName: scratch), let light = NSAppearance(named: .aqua) {
            defaults.removePersistentDomain(forName: scratch)
            let phoneSettings = AppSettings(defaults: defaults)
            phoneSettings.phoneEnabled = true
            let phoneModel = AppModel(settings: phoneSettings, notifier: Notifier())
            let page = SettingsPage(tab: .phone, phoneSetupOpen: true, done: {})
                .environmentObject(phoneModel).environmentObject(phoneSettings).frame(width: 350)
            write(page, appearance: light, to: folder.appendingPathComponent("settings-phone-light.png"))
            defaults.removePersistentDomain(forName: scratch)
        }
        print("Wrote snapshots to \(folder.path)")
    }

    /// Six prompts in one Claude Code window; the third was edited away and asked again.
    private static func sampleHistory() -> (SessionHistory, [JobEvent]) {
        let start = Date().addingTimeInterval(-3 * 3600)
        func at(_ minutes: Double) -> Date { start.addingTimeInterval(minutes * 60) }
        let turns = [
            PromptTurn(id: "1", text: "Can you help me write a Mac program that shows how much of my agents' plans I use?",
                       askedAt: at(0), parent: nil, answer: "Agent Buddy is built: a menu bar app with the limits and reminders.",
                       endedAt: at(34), outcome: .completed, usage: [
                           ModelTokens(model: "claude-fable-5-1", counts: TokenCounts(input: 1_840, output: 61_200, cacheWrite: 412_000, cacheRead: 8_930_000)),
                           ModelTokens(model: "claude-haiku-4-5", counts: TokenCounts(input: 22_100, output: 3_900, cacheWrite: 41_000, cacheRead: 160_000)),
                       ]),
            PromptTurn(id: "2", text: "Put the current session first and the week second.", askedAt: at(40), parent: "1",
                       answer: "Claude now shows 5h first, then wk.", endedAt: at(43), outcome: .completed),
            PromptTurn(id: "3", text: "Add a red badge with the number of finished jobs.", askedAt: at(50), parent: "2",
                       answer: "Started on a red badge.", endedAt: at(52), outcome: .interrupted),
            PromptTurn(id: "3b", text: "Add a round blue number for finished jobs; clicking it shows them, Clear removes it.",
                       askedAt: at(53), parent: "2", answer: "The blue badge counts finished jobs and clears with Clear.",
                       endedAt: at(74), outcome: .completed, usage: [
                           ModelTokens(model: "claude-fable-5-1", counts: TokenCounts(input: 920, output: 18_400, cacheWrite: 96_000, cacheRead: 3_100_000)),
                       ], selections: [PromptSelection(source: "PopoverView.swift, lines 40\u{2013}44",
                                                       text: "if jobs.isEmpty {\n    Text(\"No finished jobs\")\n} else {\n    JobList(jobs)\n}")]),
            PromptTurn(id: "4", text: "Make it a floating panel I can drag anywhere.", askedAt: at(80), parent: "3b",
                       answer: "The panel floats on every Space and snaps to edges.", endedAt: at(92), outcome: .completed,
                       selections: [PromptSelection(source: "Safari \u{00B7} Floating windows", text: "A panel floats above other windows.")]),
            PromptTurn(id: "5", text: "When I click a reminder, show the tree of what I asked, and a button to jump to where it runs.",
                       askedAt: at(170), parent: "4", outcome: .running),
        ]
        let history = SessionHistory(
            agent: .claude, sessionID: "sample", title: "Agent usage menu bar app", cwd: "/Users/me/head_show",
            client: "sdk-ts", gitBranch: "main", turns: turns)
        let jobs = [
            JobEvent(id: "h1", agent: .claude, outcome: .completed, sessionID: "sample", finishedAt: at(34)),
            JobEvent(id: "h2", agent: .claude, outcome: .completed, sessionID: "sample", finishedAt: at(74)),
            JobEvent(id: "h3", agent: .claude, outcome: .completed, sessionID: "sample", finishedAt: at(92)),
        ]
        return (history, jobs)
    }

    /// Three jobs in one Claude Code window, one on a server, one in Codex.
    private static func sampleJobs() -> [JobEvent] {
        let now = Date()
        return [
            JobEvent(id: "sample-1", agent: .claude, outcome: .completed, sessionID: "s1", title: "Sample: menu bar app",
                     project: "head_show", startedAt: now.addingTimeInterval(-312), finishedAt: now.addingTimeInterval(-60)),
            JobEvent(id: "sample-1b", agent: .claude, outcome: .completed, sessionID: "s1", title: "Sample: fold the reminders",
                     project: "head_show", startedAt: now.addingTimeInterval(-1500), finishedAt: now.addingTimeInterval(-1200)),
            JobEvent(id: "sample-1c", agent: .claude, outcome: .failed, sessionID: "s1", title: "Sample: build the app",
                     project: "head_show", startedAt: now.addingTimeInterval(-2600), finishedAt: now.addingTimeInterval(-2500)),
            JobEvent(id: "sample-3", agent: .claude, outcome: .completed, sessionID: "s3", title: "Sample: lemmas 4-6",
                     project: "paper", startedAt: now.addingTimeInterval(-900), finishedAt: now.addingTimeInterval(-600),
                     source: "user@server"),
            JobEvent(id: "sample-2", agent: .codex, outcome: .completed, sessionID: "s2", title: "Sample: fix the login page",
                     project: "site", startedAt: now.addingTimeInterval(-4000), finishedAt: now.addingTimeInterval(-3700)),
        ]
    }

    private static func write<V: View>(_ view: V, appearance: NSAppearance, to url: URL) {
        // Pictures can't capture a web view: answers are drawn as text here.
        let hosting = NSHostingView(rootView: view.environment(\.plainAnswers, true).background(Color(nsColor: .windowBackgroundColor)))
        hosting.appearance = appearance
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// A template image coloured as the menu bar colours it.
    private static func tinted(_ template: NSImage, dark: Bool) -> NSImage {
        NSImage(size: template.size, flipped: false) { rect in
            template.draw(in: rect)
            (dark ? NSColor.white : NSColor.black).setFill()
            rect.fill(using: .sourceAtop)
            return true
        }
    }

    private static func writeMenuBar(_ image: NSImage, appearance: NSAppearance, dark: Bool, to url: URL) {
        let scale: CGFloat = 3
        let padding: CGFloat = 8
        let size = NSSize(width: (image.size.width + padding * 2) * scale, height: image.size.height * scale)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return }
        rep.size = NSSize(width: image.size.width + padding * 2, height: image.size.height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        (dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.92, alpha: 1)).setFill()
        NSRect(origin: .zero, size: rep.size).fill()
        // The colours resolve here, in the given appearance, as they do in the menu bar.
        appearance.performAsCurrentDrawingAppearance {
            image.draw(at: NSPoint(x: padding, y: 0), from: .zero, operation: .sourceOver, fraction: 1)
        }
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
