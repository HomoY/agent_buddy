import AppKit
import AgentBuddyCore

/// `AgentBuddy --working`: the agents in a turn now, as Agent Buddy sees them
/// (this Mac's logs only), and what "keep the Mac awake" would do.
@MainActor
enum WorkingCommand {
    static func run() -> Int32 {
        let watcher = TranscriptWatcher()
        watcher.start()
        RunLoop.main.run(until: Date().addingTimeInterval(4))
        let done = DispatchSemaphore(value: 0)
        final class Box: @unchecked Sendable {
            var sessions: [WorkingSession] = []
        }
        let box = Box()
        watcher.workingSessions { sessions in
            box.sessions = sessions
            done.signal()
        }
        _ = done.wait(timeout: .now() + 10)
        let table = ProcessTable.snapshot()
        let now = Date()
        let working = WorkingRule.working(box.sessions, now: now) { session in
            !table.agentProcesses(session.agent, in: [session.folder].compactMap { $0 }).isEmpty
        }
        print("\(box.sessions.count) session\(box.sessions.count == 1 ? "" : "s") in a turn; working now: \(working.count)")
        for session in box.sessions {
            let counted = working.contains(session)
            print("  \(counted ? "working" : "quiet  ") \(session.label) · since \(Format.clock(session.since, now: now)) · last work \(Int(now.timeIntervalSince(session.lastWork)))s ago")
            if let work = session.work {
                print("          on: \(work.prefix(90))")
            }
        }
        if !working.isEmpty {
            print("Keep awake would hold: Agent Buddy: " + working.map(\.label).joined(separator: ", ") + (working.count == 1 ? " is working" : " are working"))
            print("Lock screen would show: \(LockScreenStatus.title(working))")
            for line in LockScreenStatus.body(working, now: now).split(separator: "\n") {
                print("    \(line)")
            }
        }
        watcher.stop()
        return 0
    }
}
