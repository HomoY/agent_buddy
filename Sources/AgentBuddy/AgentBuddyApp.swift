import AppKit
import Combine
import ServiceManagement
import UserNotifications

@main
enum AgentBuddyMain {
    @MainActor
    static func main() {
        // A pipe to an engine that already quit must not end the app.
        signal(SIGPIPE, SIG_IGN)
        let app = NSApplication.shared
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--snapshot") {
            app.setActivationPolicy(.prohibited)
            let folder = index + 1 < arguments.count ? arguments[index + 1] : NSTemporaryDirectory() + "AgentBuddy-snapshots"
            Snapshot.run(into: URL(fileURLWithPath: folder))
            return
        }
        if arguments.contains("--accessibility-status") {
            // Started with `open`, so macOS judges Agent Buddy, not the terminal.
            print(SelectionWatcher.status().joined(separator: "\n"))
            exit(0)
        }
        if arguments.contains("--selftest-panel") {
            app.setActivationPolicy(.accessory)
            exit(PanelSelfTest.run())
        }
        if let index = arguments.firstIndex(of: "--selftest-history"), index + 1 < arguments.count {
            app.setActivationPolicy(.accessory)
            let image = index + 2 < arguments.count ? URL(fileURLWithPath: arguments[index + 2]) : nil
            exit(HistorySelfTest.run(log: arguments[index + 1], image: image))
        }
        if let index = arguments.firstIndex(of: "--tour"), index + 1 < arguments.count {
            app.setActivationPolicy(.accessory)
            let tour = Tour(root: URL(fileURLWithPath: arguments[index + 1]))
            app.delegate = tour
            withExtendedLifetime(tour) {
                app.run()
            }
            return
        }
        if let index = arguments.firstIndex(of: "--probe-window"), index + 1 < arguments.count {
            app.setActivationPolicy(.accessory)
            let rest = arguments[(index + 1)...].filter { !$0.hasPrefix("--") }
            let seconds = rest.lazy.compactMap(TimeInterval.init).first ?? 15
            let probe = WindowProbe(targets: rest.filter { TimeInterval($0) == nil }, seconds: seconds, wholeApp: arguments.contains("--app"))
            app.delegate = probe
            withExtendedLifetime(probe) {
                app.run()
            }
            return
        }
        if arguments.contains("--working") {
            app.setActivationPolicy(.prohibited)
            exit(WorkingCommand.run())
        }
        if arguments.contains("--selftest-awake") {
            app.setActivationPolicy(.prohibited)
            exit(AwakeSelfTest.run())
        }
        if arguments.contains("--where") {
            app.setActivationPolicy(.prohibited)
            exit(WhereCommand.run(arguments))
        }
        if let index = arguments.firstIndex(of: "--selftest-markdown") {
            app.setActivationPolicy(.accessory)
            let image = index + 1 < arguments.count ? URL(fileURLWithPath: arguments[index + 1]) : nil
            exit(MarkdownSelfTest.run(image: image))
        }
        if let index = arguments.firstIndex(of: "--selftest-remote"), index + 1 < arguments.count {
            // Against a mock: AgentBuddyChecks --mock-ntfy
            app.setActivationPolicy(.prohibited)
            let serve = arguments.firstIndex(of: "--serve").flatMap { $0 + 1 < arguments.count ? TimeInterval(arguments[$0 + 1]) : nil }
            exit(RemoteSelfTest.run(server: arguments[index + 1], serve: serve, allowSend: arguments.contains("--allow-send")))
        }
        if let index = arguments.firstIndex(of: "--selftest-phone"), index + 1 < arguments.count {
            // Against a mock: AgentBuddyChecks --mock-ntfy
            app.setActivationPolicy(.prohibited)
            exit(PhoneSelfTest.run(server: arguments[index + 1]))
        }
        if arguments.contains("--notification-status") {
            // Run from inside the .app: Agent Buddy.app/Contents/MacOS/AgentBuddy --notification-status
            guard Bundle.main.bundleIdentifier != nil else {
                print("unavailable: run the executable inside Agent Buddy.app")
                return
            }
            let done = DispatchSemaphore(value: 0)
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                let status: String
                switch settings.authorizationStatus {
                case .authorized: status = "allowed"
                case .provisional: status = "allowed (quietly)"
                case .denied: status = "denied: turn on in System Settings > Notifications > Agent Buddy"
                case .notDetermined: status = "not decided yet: answer the macOS prompt (or open Agent Buddy once)"
                default: status = "other (\(settings.authorizationStatus.rawValue))"
                }
                let style = settings.alertStyle == .alert ? "alerts (stay until dismissed)" : settings.alertStyle == .banner ? "banners" : "none"
                print("notifications: \(status); style: \(style)")
                func onOff(_ setting: UNNotificationSetting) -> String {
                    setting == .enabled ? "on" : setting == .disabled ? "off" : "n/a"
                }
                let previews: String
                switch settings.showPreviewsSetting {
                case .always: previews = "always"
                case .whenAuthenticated: previews = "when unlocked (the lock screen hides what it says)"
                case .never: previews = "never (the lock screen hides what it says)"
                @unknown default: previews = "other"
                }
                print("lock screen: \(onOff(settings.lockScreenSetting)); Notification Center: \(onOff(settings.notificationCenterSetting)); previews: \(previews)")
                print("A Focus (Work, Do Not Disturb, \u{2026}) silences Agent Buddy unless it's one of the Focus's allowed apps: System Settings > Focus.")
                done.signal()
            }
            done.wait()
            return
        }
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var model: AppModel?
    private var statusItem: StatusItemController?
    private var floating: FloatingHUDController?
    let sessionWindows = SessionDetailsController()
    private var remoteControl: RemoteControl?
    private var layoutWatch: AnyCancellable?
    private var displayWatch: [AnyCancellable] = []
    private var workingWatch: AnyCancellable?
    private var watching: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // One copy at a time, or every reminder would come twice.
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0.processIdentifier != getpid() }) {
            NSApp.terminate(nil)
            return
        }
        // ⌘A, ⌘C, ⌘V and the rest reach text fields through the main menu.
        MainMenu.install()
        // A menu bar app with no windows open can be put in App Nap, which delays
        // its timers; reminders must come when a job finishes. The Mac may still sleep.
        watching = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Watching agent sessions to remind you when a job finishes")
        // Agent Buddy was called HeadShow: take over what it kept, once (before
        // anything is logged, so its log comes along).
        Migration.run()
        Diagnostics.log("Agent Buddy \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "?") started, pid \(getpid())")
        let settings = AppSettings()
        let notifier = Notifier()
        notifier.playSound = { [weak settings] in settings?.playSound ?? true }
        notifier.style = { [weak settings] in settings?.reminderStyle ?? .notification }
        let model = AppModel(settings: settings, notifier: notifier)
        let popover = PopoverController(model: model)
        let statusItem = StatusItemController(model: model, popover: popover)
        let floating = FloatingHUDController(model: model, popover: popover)
        model.onChange = { [weak statusItem] in statusItem?.redraw() }
        floating.onHide = { [weak settings] in settings?.showFloatingPanel = false }
        statusItem.floatingPanelShown = { [weak settings] in settings?.showFloatingPanel ?? false }
        statusItem.setFloatingPanel = { [weak settings] shown in settings?.showFloatingPanel = shown }
        notifier.onOpen = { [weak statusItem, weak floating] in
            // Point the details at whichever is on screen.
            if let floating, floating.isVisible {
                floating.showDetails()
            } else {
                statusItem?.show()
            }
        }
        // A clicked reminder opens its agent window's history; Jump goes straight there.
        model.onShowWindow = { [weak self, weak popover] key, info, focus in
            popover?.close()
            self?.sessionWindows.show(key: key, info: info, focus: focus)
        }
        model.onJumpWindow = { [weak self, weak popover] key, info in
            popover?.close()
            self?.sessionWindows.jump(key: key, info: info)
        }
        sessionWindows.onLearned = { [weak model] key, history in model?.learn(key, from: history) }
        // A window's key and a working session's id are both "agent|server|session".
        sessionWindows.isWorking = { [weak model] key in model?.working.contains { $0.id == key } ?? false }
        // An open agent window reads its session again when a job finishes there, and
        // when it starts or stops working: the window itself watches only a local log.
        model.onJobFinished = { [weak self] key in self?.sessionWindows.refresh(key) }
        workingWatch = model.$working
            .map { Set($0.map(\.id)) }
            .removeDuplicates()
            .scan((Set<String>(), Set<String>())) { ($0.1, $1) }
            .sink { [weak self] before, now in
                for key in before.symmetricDifference(now) {
                    self?.sessionWindows.refresh(key)
                }
            }
        notifier.onOpenWindow = { [weak model] key in model?.showWindow(key) }
        notifier.onJumpWindow = { [weak model] key in model?.jumpToWindow(key) }
        notifier.setUp { [weak model] status in model?.updateNotificationStatus(status) }
        // What you select in Zed and other apps, for agent windows' message boxes.
        SelectionWatcher.shared.enabled = { [weak settings] in settings?.selectionContext ?? false }
        SelectionWatcher.shared.servers = { [weak settings] in settings?.remoteHosts ?? [] }
        SelectionWatcher.shared.editorsAllowed = { [weak settings] in settings?.selectionEditors ?? false }
        SelectionWatcher.shared.allowEditors = { [weak settings] in settings?.selectionEditors = $0 }
        SelectionWatcher.shared.windowSource = { [weak self] window in self?.sessionWindows.source(of: window) }
        // What taking a Codex thread over would stop: its holder's other chats at work.
        SessionKeeper.shared.isWorking = { [weak model] key in model?.working.contains { $0.id == key } ?? false }
        SessionKeeper.shared.titleOf = { [weak model] key in model?.windowInfo(key).title }
        // Agent Buddy Remote's requests: a window's prompts, statistics, a prompt to send.
        let remoteControl = RemoteControl(settings: settings, model: model)
        remoteControl.start()
        self.remoteControl = remoteControl
        self.model = model
        self.statusItem = statusItem
        self.floating = floating
        apply(settings.menuBarStyle, settings.showFloatingPanel)
        // Light, dark or as macOS is; and how see-through the floating panel and agent windows are.
        displayWatch = [
            settings.$appearance.sink { mode in Task { @MainActor in NSApp.appearance = mode.appearance } },
            settings.$floatingOpacity.sink { [weak floating] opacity in Task { @MainActor in floating?.panel.alphaValue = opacity } },
            settings.$windowOpacity.sink { [weak self] opacity in Task { @MainActor in self?.sessionWindows.opacity = opacity } },
            settings.$windowTabs.sink { [weak self] tabs in Task { @MainActor in self?.sessionWindows.tabs.openAsTabs = tabs } },
            settings.$windowGlass.sink { [weak self] glass in Task { @MainActor in self?.sessionWindows.glass = glass } },
            settings.$connectOnOpen.sink { [weak self] connect in Task { @MainActor in self?.sessionWindows.connectOnOpen = connect } },
            // The agent windows' signal: Agent Buddy's own connection to each server.
            model.$remoteLive.sink { links in Task { @MainActor in ConnectionMonitor.shared.links = links } },
        ]
        // Chosen in an agent window's Tabs menu: kept in Settings.
        sessionWindows.tabs.onChange = { [weak settings] tabs in settings?.windowTabs = tabs }
        // @Published sends the new value before it's stored; use the values it sends.
        layoutWatch = settings.$menuBarStyle.combineLatest(settings.$showFloatingPanel)
            .dropFirst()
            .sink { [weak self] style, floatingPanel in
                Task { @MainActor in self?.apply(style, floatingPanel) }
            }
        model.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.stopStreams()
    }

    /// The menu bar item (app icon, numbers or hidden) and the floating panel.
    private func apply(_ style: MenuBarStyle, _ floatingPanel: Bool) {
        statusItem?.style = style
        floating?.setVisible(floatingPanel)
    }
}

/// "Launch at login", through the system's login items.
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Nil when it worked, else why not.
    @discardableResult
    static func set(_ enabled: Bool) -> String? {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
