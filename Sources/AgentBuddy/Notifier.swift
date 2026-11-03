import AppKit
import AgentBuddyCore
import AgentBuddyRemoteKit
import UserNotifications

enum NotificationStatus {
    case unknown
    case allowed
    case denied
    case notAsked
    case unavailable
}

/// The reminders: "job finished", the Claude session reset and limit warnings,
/// as macOS notifications and/or Agent Buddy's own on-screen card.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    var playSound: () -> Bool = { true }
    var style: () -> ReminderStyle = { .notification }
    /// A reminder was clicked that isn't an agent window's (or Agent Buddy's own card).
    var onOpen: (() -> Void)?
    /// An agent window's reminder was clicked: its key ("agent|server|session").
    var onOpenWindow: ((String) -> Void)?
    /// Its Jump button was pressed.
    var onJumpWindow: ((String) -> Void)?
    private let toasts = ToastController()

    override init() {
        super.init()
        toasts.onClick = { [weak self] id in self?.opened(id, jump: false) }
    }

    /// Opens what a reminder is about: an agent window's history, else the details.
    func opened(_ id: String, jump: Bool) {
        if id.hasPrefix("window-"), id != "window-test" {
            let key = String(id.dropFirst("window-".count))
            (jump ? onJumpWindow : onOpenWindow)?(key)
        } else {
            onOpen?()
        }
    }

    nonisolated static let jobCategory = "job"
    nonisolated static let jumpAction = "jump"

    /// Notifications need an app bundle; `swift run Agent Buddy` has none.
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    func setUp(_ completion: @escaping (NotificationStatus) -> Void) {
        guard let center else {
            completion(.unavailable)
            return
        }
        center.delegate = self
        // "Jump to Window" under an agent window's reminder.
        center.setNotificationCategories([UNNotificationCategory(
            identifier: Self.jobCategory,
            actions: [UNNotificationAction(identifier: Self.jumpAction, title: "Jump to Window", options: [.foreground])],
            intentIdentifiers: [])])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in
            Task { @MainActor in self.status(completion) }
        }
    }

    func status(_ completion: @escaping (NotificationStatus) -> Void) {
        guard let center else {
            completion(.unavailable)
            return
        }
        center.getNotificationSettings { settings in
            let status: NotificationStatus
            switch settings.authorizationStatus {
            case .authorized, .provisional: status = .allowed
            case .denied: status = .denied
            case .notDetermined: status = .notAsked
            default: status = .allowed
            }
            Task { @MainActor in completion(status) }
        }
    }

    /// Also sends each reminder to the iPhone and Apple Watch, when set.
    var forward: ((PhoneReminder) -> Void)?

    /// Shows a reminder the chosen way. When macOS notifications are off, the
    /// on-screen card shows it instead, so a reminder is never lost. A reminder
    /// with the same `id` replaces the one before it; `thread` stacks reminders
    /// of one agent window together in Notification Center. `phone` is how it
    /// reads on the iPhone (by default, the title and body).
    func post(
        id: String, title: String, subtitle: String? = nil, body: String, agent: Agent? = nil, thread: String? = nil,
        phone: PhoneReminder? = nil
    ) {
        forward?(phone ?? PhoneReminder(title: title, details: [subtitle, body].compactMap { $0 }, tags: ["bell"]))
        status { [weak self] status in
            guard let self else { return }
            let style = self.style()
            let system = status == .allowed && style != .card
            let card = style != .notification || status != .allowed
            if system {
                self.postSystem(id: id, title: title, subtitle: subtitle, body: body, thread: thread)
            }
            if card {
                self.toasts.show(Toast(id: id, agent: agent, title: title, subtitle: subtitle, body: body))
                if !system && self.playSound() {
                    NSSound(named: "Glass")?.play()
                }
            }
        }
    }

    /// A quiet status for the lock screen: a macOS notification only (no card,
    /// no sound, not to the iPhone), replacing the one with the same id. A Focus
    /// that doesn't allow Agent Buddy still silences it; macOS doesn't tell us.
    func postStatus(id: String, title: String, body: String) {
        status { [weak self] status in
            guard let self, let center = self.center else { return }
            guard status == .allowed else {
                Diagnostics.log("notification \(id) not shown: notifications are off for Agent Buddy")
                return
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.threadIdentifier = id
            center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { error in
                if let error {
                    Diagnostics.log("notification \(id) failed: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Takes cleared jobs' notifications out of Notification Center.
    func removeDelivered(_ ids: [String]) {
        guard let center, !ids.isEmpty else { return }
        center.removeDeliveredNotifications(withIdentifiers: ids)
    }

    private func postSystem(id: String, title: String, subtitle: String?, body: String, thread: String?) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        if let subtitle, !subtitle.isEmpty {
            content.subtitle = subtitle
        }
        content.body = body
        if let thread {
            content.threadIdentifier = thread
        }
        if id.hasPrefix("window-") {
            content.categoryIdentifier = Self.jobCategory
        }
        if playSound() {
            content.sound = .default
        }
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { error in
            if let error {
                NSLog("Agent Buddy couldn't post a notification: %@", error.localizedDescription)
            }
        }
    }

    /// One reminder per agent window: "Claude Code job finished", or "Claude Code ·
    /// 3 jobs finished" once more finish there, with the latest job's name and,
    /// if wanted, its last words. Each new job replaces the window's reminder.
    func postWindow(_ window: JobWindow, includeSummary: Bool) {
        let job = window.latest
        let title = PushComposer.headline(client: job.agent.clientName, count: window.count, outcome: job.outcome.rawValue)
        var facts: [String] = []
        if job.title != nil, let project = job.project {
            facts.append(project)
        }
        if let source = job.source {
            facts.append("on \(source)")
        }
        facts += Self.details(job)
        var body = facts.joined(separator: " · ")
        if includeSummary, let summary = job.summary {
            body += body.isEmpty ? summary : "\n\(summary)"
        }
        if body.isEmpty {
            body = job.outcome == .completed ? "Your job is done." : "Open the agent to see what happened."
        }
        post(id: "window-\(window.key)", title: title, subtitle: job.title ?? job.project, body: body,
             agent: job.agent, thread: window.key, phone: Self.phoneReminder(for: window))
    }

    /// An agent window's reminder as it goes to the iPhone: tagged with the
    /// window, so Agent Buddy Remote folds its reminders into one row.
    static func phoneReminder(for window: JobWindow) -> PhoneReminder {
        let job = window.latest
        return PhoneReminder(
            title: PushComposer.headline(client: job.agent.clientName, count: window.count, outcome: job.outcome.rawValue),
            identifying: identifying(job), details: details(job), summary: job.summary,
            tags: ReminderTag.forWindow(key: window.key, agent: job.agent.rawValue, count: window.count, outcome: job.outcome.rawValue),
            priority: job.outcome == .limited ? 4 : 3)
    }

    /// The job's name, its folder and its server: what says which job it was.
    static func identifying(_ job: JobEvent) -> [String] {
        var parts: [String] = []
        if let name = job.title ?? job.project {
            parts.append(name)
        }
        if job.title != nil, let project = job.project {
            parts.append(project)
        }
        if let source = job.source {
            parts.append("on \(source)")
        }
        return parts
    }

    /// What's safe to say anywhere: how long it took.
    static func details(_ job: JobEvent) -> [String] {
        job.duration.map { ["took \(Format.duration($0))"] } ?? []
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let id = response.notification.request.identifier
        let jump = response.actionIdentifier == Self.jumpAction
        Task { @MainActor in self.opened(id, jump: jump) }
        completionHandler()
    }
}
