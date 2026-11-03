import AppKit
import AgentBuddyCore
import UserNotifications

/// Keeps the Mac from sleeping while an agent is working, as Codex's "Prevent
/// sleep while running" does for Codex: for every agent Agent Buddy watches, on
/// this Mac and on your servers. The lid closing still sleeps the Mac.
@MainActor
final class AwakeKeeper {
    private var activity: NSObjectProtocol?
    private var options: ProcessInfo.ActivityOptions = []
    private var reason = ""

    var isHolding: Bool { activity != nil }

    func update(working: [WorkingSession], enabled: Bool, display: Bool) {
        guard enabled, !working.isEmpty else {
            release()
            return
        }
        // `pmset -g assertions` shows this, so it names who's working.
        let reason = "Agent Buddy: " + working.map(\.label).joined(separator: ", ")
            + (working.count == 1 ? " is working" : " are working")
        let options: ProcessInfo.ActivityOptions = display ? [.idleSystemSleepDisabled, .idleDisplaySleepDisabled] : [.idleSystemSleepDisabled]
        guard activity == nil || reason != self.reason || options != self.options else { return }
        release()
        activity = ProcessInfo.processInfo.beginActivity(options: options, reason: reason)
        self.options = options
        self.reason = reason
        Diagnostics.log("keeping the Mac awake\(display ? " with its display on" : ""): \(reason)")
    }

    func release() {
        guard let activity else { return }
        ProcessInfo.processInfo.endActivity(activity)
        self.activity = nil
        Diagnostics.log("letting the Mac sleep again")
    }
}

/// While the Mac is locked, a notification lists the agents at work, so the
/// lock screen shows them. It changes as agents start and stop, and goes when
/// the Mac is unlocked.
@MainActor
final class LockScreenStatus {
    static let id = "agents-working"

    private let post: (_ id: String, _ title: String, _ body: String) -> Void
    private let remove: (_ ids: [String]) -> Void
    private var locked = false
    private var working: [WorkingSession] = []
    private var shown: [String] = []
    private var observers: [NSObjectProtocol] = []
    var enabled: () -> Bool = { true }

    init(notifier: Notifier) {
        post = { [weak notifier] id, title, body in
            Diagnostics.log("lock screen: \(title)")
            notifier?.postStatus(id: id, title: title, body: body)
        }
        remove = { [weak notifier] ids in
            Diagnostics.log("lock screen: cleared")
            notifier?.removeDelivered(ids)
        }
    }

    /// For the self-test: what it posts and removes, without notifications.
    init(post: @escaping (String, String, String) -> Void, remove: @escaping ([String]) -> Void) {
        self.post = post
        self.remove = remove
    }

    func start() {
        let center = DistributedNotificationCenter.default()
        for (name, value) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            observers.append(center.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    Diagnostics.log(value ? "screen locked" : "screen unlocked")
                    self?.setLocked(value)
                }
            })
        }
    }

    func update(_ working: [WorkingSession]) {
        self.working = working
        refresh()
    }

    /// For the self-test.
    func setLocked(_ value: Bool) {
        locked = value
        refresh()
    }

    private func refresh() {
        let ids = working.map(\.id)
        if locked && enabled() && !working.isEmpty {
            // The same agents still at work: leave it as it is, rather than alert again.
            guard ids != shown else { return }
            shown = ids
            post(Self.id, Self.title(working), Self.body(working, now: Date()))
        } else if !shown.isEmpty {
            shown = []
            remove([Self.id])
        }
    }

    static func title(_ working: [WorkingSession]) -> String {
        working.count == 1 ? "\(working[0].agent.clientName) is working" : "\(working.count) agents are working"
    }

    /// Per agent: who and where, since when, then what it's working on.
    static func body(_ working: [WorkingSession], now: Date) -> String {
        working.map { session in
            let line = "\(session.label) · since \(Format.clock(session.since, now: now))"
            return session.work.map { "\(line)\n\u{201C}\($0)\u{201D}" } ?? line
        }
        .joined(separator: "\n")
    }
}
