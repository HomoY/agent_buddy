import AppKit
import AgentBuddyCore
import AgentBuddyRemoteKit

/// `AgentBuddy --selftest-remote SERVER [--serve SECONDS]`: Agent Buddy's
/// answers to Agent Buddy Remote, against a mock ntfy (`AgentBuddyChecks
/// --mock-ntfy`): the real answering service, with this Mac's newest Claude
/// Code and Codex sessions as its agent windows, asked by a stand-in phone for
/// the windows, their prompts and the statistics. Sending is checked only up to
/// the switch and the plan: no prompt goes to an agent. With --serve it just
/// answers for a while, printing the pairing and window links, for the iPhone
/// simulator to ask it.
@MainActor
enum RemoteSelfTest {
    /// - Parameter allowSend: serving, sending is on (for the simulator's look at the
    ///   message box; nothing there taps Send).
    static func run(server: String, serve: TimeInterval?, allowSend: Bool = false) -> Int32 {
        // Kept in an object: the checks inside the task below count too.
        final class Tally {
            var failures = 0
        }
        let tally = Tally()
        func check(_ ok: Bool, _ what: String) {
            print(ok ? "  ok    \(what)" : "  FAIL  \(what)")
            if !ok {
                tally.failures += 1
            }
        }
        let suite = "io.github.homoy.agentbuddy.selftest.remote"
        UserDefaults().removePersistentDomain(forName: suite)
        guard let defaults = UserDefaults(suiteName: suite) else { return 1 }
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.phoneServer = server
        settings.phoneTopic = "agentbuddy-selftest-" + String(UUID().uuidString.prefix(8)).lowercased()
        settings.phoneEnabled = true
        settings.remoteBrowse = true
        settings.remoteSend = serve != nil && allowSend
        let model = AppModel(settings: settings, notifier: Notifier())

        // The agent windows: this Mac's newest Claude Code and Codex sessions.
        var archive = SessionArchive()
        var keys: [Agent: String] = [:]
        for log in SessionHistoryReader.recentLogs(since: Date().addingTimeInterval(-7 * 86400))
            .filter({ $0.agent != .copilot }).sorted(by: { $0.modified > $1.modified }) where keys[log.agent] == nil {
            guard case .success(let history) = SessionHistoryReader.read(agent: log.agent, path: log.path),
                  !history.turns.isEmpty, !history.isSubagent
            else { continue }
            let job = JobEvent(
                id: "selftest-\(log.agent.rawValue)", agent: log.agent, outcome: .completed, sessionID: history.sessionID,
                title: history.title, project: history.cwd.map { URL(fileURLWithPath: $0).lastPathComponent }, finishedAt: Date(),
                transcriptPath: log.path)
            archive.record(job)
            let key = JobWindow.key(job)
            _ = archive.learn(key, title: history.title, project: nil, path: log.path)
            keys[log.agent] = key
        }
        model.preview(archive: archive)
        let control = RemoteControl(settings: settings, model: model)
        control.start()
        guard let pairing = settings.phonePairing, pairing.key != nil else {
            check(false, "sending on makes a pairing with a key")
            return 1
        }

        if let serve {
            print("pair: \(pairing.link?.absoluteString ?? "-")")
            for (agent, key) in keys {
                print("\(agent.rawValue): agentbuddy://open?window=\(key.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? key)")
            }
            fflush(stdout)
            RunLoop.main.run(until: Date().addingTimeInterval(serve))
            return 0
        }

        print("Agent Buddy Remote asking this Mac (\(keys.count) agent windows)")
        // The phone's side, as Agent Buddy Remote asks.
        let phone = Phone(asker: RemoteAsker(client: NtfyClient(pairing: pairing)))
        final class Done: @unchecked Sendable {
            var done = false
        }
        let finished = Done()
        Task { @MainActor in
            defer { finished.done = true }
            // Listening takes a moment to start.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            do {
                let windows = try await phone.ask(PhoneRequest(op: .windows), timeout: 20).windows ?? []
                check(Set(windows.map(\.key)) == Set(keys.values), "the windows: \(windows.map(\.title))")
                for (agent, key) in keys.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                    // A reminder's tag, as a tapped reminder sends it.
                    let started = Date()
                    let history = try await phone.ask(PhoneRequest(op: .history, window: ReminderTag.window(key)), timeout: 60).history
                    let took = String(format: "%.1f s", Date().timeIntervalSince(started))
                    check(history?.key == key && !(history?.rows.isEmpty ?? true),
                          "\(agent.clientName)'s prompts, by its reminders' tag: \(history?.rows.count ?? 0) prompts in \(took)")
                    check(history?.latest != nil && history?.rows.contains { $0.answer != nil } == true, "with the latest marked, and answers")
                    check(history?.canSend == false && history?.sendNote.contains("turn on") == true, "sending is off until turned on")
                    // A finished prompt's steps, as an opened prompt asks for them.
                    if let turn = history?.rows.last(where: { $0.outcome == "completed" })?.id ?? history?.latest {
                        let asked = Date()
                        let steps = try await phone.ask(PhoneRequest(op: .steps, window: key, turn: turn), timeout: 60).steps ?? []
                        let ran = steps.filter { $0.kind != "said" }.count
                        check(!steps.isEmpty, "a prompt's steps: \(steps.count - ran) said, \(ran) actions, in \(String(format: "%.1f s", Date().timeIntervalSince(asked)))")
                    }
                }
                if let key = keys[.claude] {
                    do {
                        _ = try await phone.ask(PhoneRequest(op: .send, window: key, prompt: "Say hello"), timeout: 20)
                        check(false, "a prompt isn't sent while sending is off")
                    } catch {
                        check(error.localizedDescription.contains("is off"), "a prompt isn't sent while sending is off")
                    }
                    settings.remoteSend = true
                    let history = try await phone.ask(PhoneRequest(op: .history, window: key), timeout: 60).history
                    check(history?.canSend == true && history?.sendNote.hasPrefix("Sends it to Claude Code on your Mac") == true,
                          "turned on, it says how a prompt would go: \(history?.sendNote.prefix(70) ?? "-")…")
                    settings.remoteSend = false
                }
                for period in ["day", "week"] {
                    let stats = try await phone.ask(PhoneRequest(op: .stats, period: period), timeout: 90).stats
                    let total = stats.map { TokenStatistics.compact($0.total.total) } ?? "-"
                    check(stats?.bars.count == (period == "day" ? 24 : 7) && (stats?.total.total ?? 0) > 0,
                          "\(period == "day" ? "today's" : "the week's") tokens: \(total) in \(stats?.bars.count ?? 0) bars, \(stats?.jobs.count ?? 0) jobs")
                }
            } catch {
                check(false, "the requests are answered: \(error.localizedDescription)")
            }
        }
        let deadline = Date().addingTimeInterval(240)
        while !finished.done, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        check(finished.done, "it finished in time")
        print(tally.failures == 0 ? "Remote self-test passed." : "\(tally.failures) remote checks failed.")
        return tally.failures == 0 ? 0 : 1
    }
}

/// A stand-in for Agent Buddy Remote: asks, and turns the Mac's refusal into an error.
private struct Phone {
    struct Refused: LocalizedError {
        var errorDescription: String?
    }

    var asker: RemoteAsker

    func ask(_ request: PhoneRequest, timeout: TimeInterval) async throws -> PhoneReply {
        let reply = try await asker.ask(request, timeout: timeout)
        if let problem = reply.problem {
            throw Refused(errorDescription: problem)
        }
        return reply
    }
}
