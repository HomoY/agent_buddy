import AppKit
import SwiftUI
import Foundation
import AgentBuddyCore
import AgentBuddyRemoteKit

enum ReminderStyle: String, CaseIterable, Identifiable {
    case notification
    case card
    case both

    var id: String { rawValue }

    var label: String {
        switch self {
        case .notification: return "macOS notification"
        case .card: return "On-screen card"
        case .both: return "Both"
        }
    }
}

/// What the menu bar item shows.
/// Light, dark, or as macOS is.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var symbol: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }

    /// For `NSApp.appearance`: nil follows macOS.
    var appearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

enum MenuBarStyle: String, CaseIterable, Identifiable {
    case icon
    case numbers
    case hidden

    var id: String { rawValue }

    var label: String {
        switch self {
        case .icon: return "App icon"
        case .numbers: return "Usage numbers"
        case .hidden: return "Hidden"
        }
    }
}

/// When reminders also go to the iPhone and Apple Watch.
enum PhoneTiming: String, CaseIterable, Identifiable {
    case always
    case away

    var id: String { rawValue }

    var label: String {
        switch self {
        case .always: return "Always"
        case .away: return "Only when I'm away from this Mac"
        }
    }
}

/// The choices in Settings, kept in UserDefaults (the ntfy access token in the Keychain).
@MainActor
final class AppSettings: ObservableObject {
    /// Where the choices are kept (the phone link keeps its daily count there too).
    let defaults: UserDefaults

    @Published var refreshMinutes: Int { didSet { defaults.set(refreshMinutes, forKey: "refreshMinutes") } }
    @Published var trackClaude: Bool { didSet { defaults.set(trackClaude, forKey: "track.claude") } }
    @Published var trackCodex: Bool { didSet { defaults.set(trackCodex, forKey: "track.codex") } }
    @Published var trackCopilot: Bool { didSet { defaults.set(trackCopilot, forKey: "track.copilot") } }
    @Published var notifyClaudeJobs: Bool { didSet { defaults.set(notifyClaudeJobs, forKey: "notify.jobs.claude") } }
    @Published var notifyCodexJobs: Bool { didSet { defaults.set(notifyCodexJobs, forKey: "notify.jobs.codex") } }
    @Published var notifyCopilotJobs: Bool { didSet { defaults.set(notifyCopilotJobs, forKey: "notify.jobs.copilot") } }
    /// Job reminders for the agents watched through their logs alone, by agent (each on unless turned off).
    @Published var notifyLogJobs: [String: Bool] { didSet { defaults.set(notifyLogJobs, forKey: "notify.jobs.others") } }
    @Published var sessionResetReminder: Bool { didSet { defaults.set(sessionResetReminder, forKey: "notify.sessionReset") } }
    @Published var limitWarnings: Bool { didSet { defaults.set(limitWarnings, forKey: "notify.limits") } }
    @Published var showSummaries: Bool { didSet { defaults.set(showSummaries, forKey: "notify.summaries") } }
    @Published var playSound: Bool { didSet { defaults.set(playSound, forKey: "notify.sound") } }
    @Published var reminderStyle: ReminderStyle { didSet { defaults.set(reminderStyle.rawValue, forKey: "notify.style") } }
    @Published var appearance: AppearanceMode { didSet { defaults.set(appearance.rawValue, forKey: "display.appearance") } }
    /// How opaque the floating panel and the agent windows are, 0.4 to 1.
    @Published var floatingOpacity: Double { didSet { defaults.set(floatingOpacity, forKey: "display.floatingOpacity") } }
    @Published var windowOpacity: Double { didSet { defaults.set(windowOpacity, forKey: "display.windowOpacity") } }
    /// Agent windows opened as tabs of one window.
    @Published var windowTabs: Bool { didSet { defaults.set(windowTabs, forKey: "display.windowTabs") } }
    /// Agent windows as frosted glass: what's behind them shows through, blurred.
    @Published var windowGlass: Bool { didSet { defaults.set(windowGlass, forKey: FrostedGlass.key) } }
    /// Servers whose Claude Code, Codex and Copilot tokens are counted over SSH.
    @Published var remoteHosts: [String] { didSet { defaults.set(remoteHosts, forKey: "remoteHosts") } }

    /// The menu bar item and the floating panel can't both be hidden, or there
    /// would be no way back to Agent Buddy.
    @Published var menuBarStyle: MenuBarStyle {
        didSet {
            defaults.set(menuBarStyle.rawValue, forKey: "menuBarStyle")
            if menuBarStyle == .hidden && !showFloatingPanel {
                showFloatingPanel = true
            }
        }
    }
    @Published var showFloatingPanel: Bool {
        didSet {
            defaults.set(showFloatingPanel, forKey: "floatingPanel")
            if !showFloatingPanel && menuBarStyle == .hidden {
                menuBarStyle = .icon
            }
        }
    }

    // MARK: While agents work

    /// Like Codex's "Prevent sleep while running", for every agent watched.
    @Published var keepAwake: Bool { didSet { defaults.set(keepAwake, forKey: "awake.enabled") } }
    /// The display too, so the lock screen stays readable.
    @Published var keepDisplayAwake: Bool { didSet { defaults.set(keepDisplayAwake, forKey: "awake.display") } }
    /// While the Mac is locked, a notification lists the agents at work.
    @Published var lockScreenStatus: Bool { didSet { defaults.set(lockScreenStatus, forKey: "lock.status") } }

    /// OpenAI's resets of everyone's Codex limits, from codex-reset.com, under Codex's own limits.
    @Published var codexResets: Bool { didSet { defaults.set(codexResets, forKey: "codex.resets") } }
    /// A reminder when one lands.
    @Published var notifyCodexResets: Bool { didSet { defaults.set(notifyCodexResets, forKey: "notify.codexResets") } }

    // MARK: iPhone and Apple Watch, through ntfy

    /// Off until turned on: reminders then go through the server below.
    @Published var phoneEnabled: Bool {
        didSet {
            defaults.set(phoneEnabled, forKey: "phone.enabled")
            if phoneEnabled && !Pairing.isValid(topic: phoneTopic) {
                phoneTopic = Pairing.newTopic()
            }
            if phoneEnabled && !Sealed.isValid(key: phoneKey) {
                phoneKey = Sealed.newKey()
            }
        }
    }
    /// What Agent Buddy Remote seals its requests with, and the Mac its replies;
    /// it leaves the Mac only in the pairing code. Kept with the settings, not in
    /// the Keychain: an app signed only for this Mac would make macOS ask for
    /// your password to read it after each update.
    @Published var phoneKey: String { didSet { defaults.set(phoneKey, forKey: "phone.key") } }
    /// Agent Buddy Remote may open agent windows' prompts and statistics.
    @Published var remoteBrowse: Bool { didSet { defaults.set(remoteBrowse, forKey: "phone.remote") } }
    /// …and send prompts to agents: off unless you turn it on.
    @Published var remoteSend: Bool { didSet { defaults.set(remoteSend, forKey: "phone.remoteSend") } }
    /// Agent windows show what you select in Zed or another app, and send it with your prompt.
    @Published var selectionContext: Bool { didSet { defaults.set(selectionContext, forKey: "selection.context") } }
    /// …and may switch VS Code (and its kin) into screen reader mode, the only way it tells.
    @Published var selectionEditors: Bool { didSet { defaults.set(selectionEditors, forKey: "selection.editors") } }
    /// Agent windows connect to their session as they open (as Move here does), and stay connected.
    @Published var connectOnOpen: Bool { didSet { defaults.set(connectOnOpen, forKey: "keep.onOpen") } }
    @Published var phoneServer: String { didSet { defaults.set(phoneServer, forKey: "phone.server") } }
    /// Made up at random the first time, so nobody can guess it.
    @Published var phoneTopic: String { didSet { defaults.set(phoneTopic, forKey: "phone.topic") } }
    @Published var phoneTiming: PhoneTiming { didSet { defaults.set(phoneTiming.rawValue, forKey: "phone.timing") } }
    /// The job's name, folder and server in the reminder.
    @Published var phoneIncludeTitles: Bool { didSet { defaults.set(phoneIncludeTitles, forKey: "phone.titles") } }
    /// The agent's last words in the reminder.
    @Published var phoneIncludeSummaries: Bool { didSet { defaults.set(phoneIncludeSummaries, forKey: "phone.summaries") } }
    /// Usage and finished jobs for Agent Buddy Remote, on a topic of their own.
    @Published var phoneShareStatus: Bool { didSet { defaults.set(phoneShareStatus, forKey: "phone.status") } }
    /// For a server that limits who may publish; kept in the Keychain.
    @Published var phoneToken: String {
        didSet {
            guard phoneToken != oldValue else { return }
            Keychain.write(phoneToken, account: "ntfy-token")
            defaults.set(!phoneToken.isEmpty, forKey: "phone.hasToken")
        }
    }

    /// Where reminders and the status go, when sending is on.
    var phonePairing: Pairing? {
        guard phoneEnabled, Pairing.isValid(topic: phoneTopic) else { return nil }
        return Pairing(server: phoneServer, topic: phoneTopic, token: phoneToken, key: Sealed.isValid(key: phoneKey) ? phoneKey : nil)
    }

    /// - Parameter defaults: where the choices are kept; the snapshot mode passes a scratch domain.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            "refreshMinutes": 5,
            "track.claude": true, "track.codex": true, "track.copilot": true,
            "notify.jobs.claude": true, "notify.jobs.codex": true, "notify.jobs.copilot": true,
            "notify.sessionReset": true, "notify.limits": true, "notify.summaries": true, "notify.sound": true,
            "phone.server": "https://ntfy.sh", "phone.titles": true, "phone.summaries": false, "phone.status": true,
            "awake.enabled": false, "awake.display": false, "lock.status": true,
            "codex.resets": true, "notify.codexResets": false,
            "phone.remote": true, "phone.remoteSend": false, "selection.context": true, "selection.editors": false,
            "display.floatingOpacity": 1.0, "display.windowOpacity": 1.0, "display.windowTabs": false, FrostedGlass.key: true,
        ])
        refreshMinutes = max(1, defaults.integer(forKey: "refreshMinutes"))
        trackClaude = defaults.bool(forKey: "track.claude")
        trackCodex = defaults.bool(forKey: "track.codex")
        trackCopilot = defaults.bool(forKey: "track.copilot")
        notifyClaudeJobs = defaults.bool(forKey: "notify.jobs.claude")
        notifyCodexJobs = defaults.bool(forKey: "notify.jobs.codex")
        notifyCopilotJobs = defaults.bool(forKey: "notify.jobs.copilot")
        notifyLogJobs = defaults.dictionary(forKey: "notify.jobs.others") as? [String: Bool] ?? [:]
        sessionResetReminder = defaults.bool(forKey: "notify.sessionReset")
        limitWarnings = defaults.bool(forKey: "notify.limits")
        showSummaries = defaults.bool(forKey: "notify.summaries")
        playSound = defaults.bool(forKey: "notify.sound")
        reminderStyle = ReminderStyle(rawValue: defaults.string(forKey: "notify.style") ?? "") ?? .notification
        remoteHosts = defaults.stringArray(forKey: "remoteHosts") ?? []
        keepAwake = defaults.bool(forKey: "awake.enabled")
        keepDisplayAwake = defaults.bool(forKey: "awake.display")
        lockScreenStatus = defaults.bool(forKey: "lock.status")
        codexResets = defaults.bool(forKey: "codex.resets")
        notifyCodexResets = defaults.bool(forKey: "notify.codexResets")
        phoneEnabled = defaults.bool(forKey: "phone.enabled")
        phoneServer = defaults.string(forKey: "phone.server") ?? "https://ntfy.sh"
        phoneTopic = defaults.string(forKey: "phone.topic") ?? ""
        phoneTiming = PhoneTiming(rawValue: defaults.string(forKey: "phone.timing") ?? "") ?? .always
        phoneIncludeTitles = defaults.bool(forKey: "phone.titles")
        phoneIncludeSummaries = defaults.bool(forKey: "phone.summaries")
        phoneShareStatus = defaults.bool(forKey: "phone.status")
        phoneKey = defaults.string(forKey: "phone.key") ?? ""
        remoteBrowse = defaults.bool(forKey: "phone.remote")
        remoteSend = defaults.bool(forKey: "phone.remoteSend")
        selectionContext = defaults.bool(forKey: "selection.context")
        selectionEditors = defaults.bool(forKey: "selection.editors")
        connectOnOpen = defaults.bool(forKey: "keep.onOpen")
        appearance = AppearanceMode(rawValue: defaults.string(forKey: "display.appearance") ?? "") ?? .system
        floatingOpacity = min(1, max(0.4, defaults.double(forKey: "display.floatingOpacity")))
        windowOpacity = min(1, max(0.4, defaults.double(forKey: "display.windowOpacity")))
        windowTabs = defaults.bool(forKey: "display.windowTabs")
        windowGlass = defaults.bool(forKey: FrostedGlass.key)
        // The Keychain is asked only when a token was saved.
        phoneToken = defaults.bool(forKey: "phone.hasToken") ? (Keychain.read(account: "ntfy-token") ?? "") : ""
        // The earlier "Show usage in" setting, if it was ever changed, carries over.
        let earlier = defaults.string(forKey: "placement")
        menuBarStyle = MenuBarStyle(rawValue: defaults.string(forKey: "menuBarStyle") ?? "")
            ?? (earlier == "menuBar" ? .numbers : (earlier == "floating" ? .hidden : .icon))
        showFloatingPanel = defaults.object(forKey: "floatingPanel") as? Bool ?? (earlier != "menuBar")
        if menuBarStyle == .hidden && !showFloatingPanel {
            menuBarStyle = .icon
        }
        // Sending turned on before there were keys: one now, for the next pairing code.
        if phoneEnabled && !Sealed.isValid(key: phoneKey) {
            phoneKey = Sealed.newKey()
            defaults.set(phoneKey, forKey: "phone.key")
        }
    }

    func isTracked(_ agent: Agent) -> Bool {
        switch agent {
        case .claude: return trackClaude
        case .codex: return trackCodex
        case .copilot: return trackCopilot
        default: return false  // No plan limits to show.
        }
    }

    func notifiesJobs(_ agent: Agent) -> Bool {
        switch agent {
        case .claude: return notifyClaudeJobs
        case .codex: return notifyCodexJobs
        case .copilot: return notifyCopilotJobs
        default: return notifyLogJobs[agent.rawValue] ?? true
        }
    }

    /// Whether an agent's finished jobs remind, to switch in Settings.
    func notifiesJobsBinding(_ agent: Agent) -> Binding<Bool> {
        Binding(
            get: { [unowned self] in self.notifiesJobs(agent) },
            set: { [unowned self] on in
                switch agent {
                case .claude: self.notifyClaudeJobs = on
                case .codex: self.notifyCodexJobs = on
                case .copilot: self.notifyCopilotJobs = on
                default: self.notifyLogJobs[agent.rawValue] = on
                }
            })
    }

    var trackedAgents: [Agent] {
        Agent.allCases.filter(isTracked)
    }
}
