import AppKit
import AgentBuddyCore
import AgentBuddyRemoteKit

/// `AgentBuddy --selftest-phone http://127.0.0.1:PORT`: sends reminders and the
/// status to a mock ntfy server (`AgentBuddyChecks --mock-ntfy`) the way the app
/// does, then reads them back as Agent Buddy Remote would. It keeps its settings
/// in a scratch domain and never shows a notification.
@MainActor
enum PhoneSelfTest {
    static func run(server: String) -> Int32 {
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            print(ok ? "  ok    \(what)" : "  FAIL  \(what)")
            if !ok {
                failures += 1
            }
        }
        let scratch = "io.github.homoy.agentbuddy.selftest-phone"
        guard let defaults = UserDefaults(suiteName: scratch) else { return 1 }
        defaults.removePersistentDomain(forName: scratch)
        defer { defaults.removePersistentDomain(forName: scratch) }

        let settings = AppSettings(defaults: defaults)
        settings.phoneServer = server
        settings.phoneEnabled = true
        check(Pairing.isValid(topic: settings.phoneTopic), "turning it on makes a topic (\(settings.phoneTopic))")
        guard let pairing = settings.phonePairing else { return 1 }
        let client = NtfyClient(pairing: pairing)
        let now = Date()
        let jobs = [
            JobEvent(id: "st-1", agent: .claude, outcome: .completed, sessionID: "st", title: "Selftest: fold the reminders",
                     project: "head_show", summary: "secret last words", startedAt: now.addingTimeInterval(-90), finishedAt: now),
            JobEvent(id: "st-2", agent: .claude, outcome: .completed, sessionID: "st", title: "Selftest: earlier job",
                     project: "head_show", startedAt: now.addingTimeInterval(-600), finishedAt: now.addingTimeInterval(-500)),
            JobEvent(id: "st-3", agent: .codex, outcome: .failed, sessionID: "other", title: "Selftest: another window",
                     project: "site", finishedAt: now.addingTimeInterval(-60), source: "user@server"),
        ]
        let model = AppModel(settings: settings, notifier: Notifier())
        model.preview(jobs: jobs)
        let phone = model.phone
        phone.makeSnapshot = { [weak model] in model?.remoteSnapshot() }
        phone.start()
        let windows = JobWindow.fold(jobs)

        func reminders() -> [NtfyMessage] {
            wait { try await client.messages(topic: pairing.topic, since: "all") } ?? []
        }
        func statuses() -> [NtfyMessage] {
            wait { try await client.messages(topic: pairing.statusTopic, since: "all") } ?? []
        }

        print("A finished window, to the phone")
        phone.send(Notifier.phoneReminder(for: windows[0]))
        spin(5) { phone.reminderDelivery != nil }
        check(phone.reminderDelivery.map { if case .sent = $0 { return true } else { return false } } ?? false,
              "it's sent: \(String(describing: phone.reminderDelivery))")
        let first = reminders().last
        check(first?.title == "Claude Code · 2 jobs finished", "the title counts the window's jobs: \(first?.title ?? "none")")
        check(first?.message.hasPrefix("Selftest: fold the reminders · head_show") == true, "it names the job and folder")
        check(first?.message.contains("took 1m 30s") == true, "and how long it took")
        check(first?.message.contains("secret last words") == false, "not the last words (off unless chosen)")
        check(first?.tags.contains(ReminderTag.window(windows[0].key)) == true && first?.tags.contains("hsn-2") == true,
              "tagged with its window and count")
        check(first.flatMap(RemoteSnapshot.FinishedWindow.init(message:))?.agent == "claude", "Agent Buddy Remote reads it as a Claude window")

        print("Privacy choices")
        settings.phoneIncludeTitles = false
        phone.send(Notifier.phoneReminder(for: windows[1]))
        spin(5) { reminders().count >= 2 }
        let anonymous = reminders().last
        check(anonymous?.message.contains("Selftest") == false && anonymous?.message.contains("user@server") == false,
              "without names: no job, folder or server")
        check(anonymous?.title == "Codex job stopped with an error", "the title still says what happened")
        settings.phoneIncludeSummaries = true
        settings.phoneIncludeTitles = true
        phone.send(Notifier.phoneReminder(for: windows[0]))
        spin(5) { reminders().count >= 3 }
        check(reminders().last?.message.hasSuffix("secret last words") == true, "with last words chosen, they come last")
        settings.phoneIncludeSummaries = false

        print("The status for Agent Buddy Remote")
        // The settings changes above send it again within seconds (on your own server).
        spin(15) {
            guard let text = statuses().last?.message, let status = RemoteSnapshot.decode(Data(text.utf8)) else { return false }
            return status.windows.first?.detail.contains("secret") == false && status.windows.first?.detail.contains("Selftest") == true
        }
        let status = statuses().last.flatMap { RemoteSnapshot.decode(Data($0.message.utf8)) }
        check(status != nil, "a status arrives on \(pairing.statusTopic)")
        check(status?.mac == PhoneLink.macName, "from this Mac (\(PhoneLink.macName))")
        check(status?.windowCount == 2 && status?.windows.first?.headline == "Claude Code · 2 jobs finished", "with the folded windows")
        check(status?.agents.map(\.agent) == settings.trackedAgents.map(\.rawValue), "and each tracked agent")
        check((statuses().last?.message.utf8.count ?? 5000) < 4096, "in one message")

        let sent = statuses().count
        phone.statusChanged()
        spin(8) { false }
        check(statuses().count == sent, "an unchanged status isn't sent again")

        model.preview(jobs: [])
        phone.statusChanged(urgent: true)
        spin(12) { statuses().count > sent }
        let cleared = statuses().last.flatMap { RemoteSnapshot.decode(Data($0.message.utf8)) }
        check(cleared?.windowCount == 0, "clearing the jobs on the Mac clears them on the phone")

        print("When to send")
        settings.phoneTiming = .away
        let away = Presence.isAway()
        let before = reminders().count
        phone.send(Notifier.phoneReminder(for: windows[0]))
        spin(4) { reminders().count > before }
        check((reminders().count > before) == away, away ? "away from the Mac: sent" : "at the Mac: not sent")
        settings.phoneTiming = .always
        settings.phoneEnabled = false
        let off = reminders().count
        phone.send(Notifier.phoneReminder(for: windows[0]))
        spin(3) { reminders().count > off }
        check(reminders().count == off, "turned off: nothing is sent")

        print(failures == 0 ? "All phone self-checks passed." : "\(failures) phone self-checks failed.")
        return failures == 0 ? 0 : 1
    }

    /// Turns the main run loop until `done`, or for `seconds`.
    private static func spin(_ seconds: Double, until done: () -> Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline, !done() {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
    }

    /// The result of async work, waited for with the run loop turning.
    private static func wait<T>(_ body: @escaping @Sendable () async throws -> T) -> T? {
        let result = AsyncResult<T>()
        Task.detached {
            result.value = try? await body()
            result.done = true
        }
        spin(10) { result.done }
        return result.value
    }
}

private final class AsyncResult<T>: @unchecked Sendable {
    var value: T?
    var done = false
}
