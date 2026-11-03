import AgentBuddyCore
import Foundation

/// Who's working, as the watcher tells it from the lines it reads.
func checkWorking() {
    print("Agents at work")
    let watcher = TranscriptWatcher(roots: TranscriptWatcher.Roots(
        claudeProjects: URL(fileURLWithPath: "/nonexistent/claude"), codexSessions: URL(fileURLWithPath: "/nonexistent/codex"),
        codexIndex: nil, copilotSessions: URL(fileURLWithPath: "/nonexistent/copilot")))
    final class Count: @unchecked Sendable {
        var value = 0
    }
    let changes = Count()
    watcher.onWorkingChange = { changes.value += 1 }
    func working() -> [WorkingSession] {
        let done = DispatchSemaphore(value: 0)
        final class Box: @unchecked Sendable {
            var sessions: [WorkingSession] = []
        }
        let box = Box()
        watcher.workingSessions { sessions in
            box.sessions = sessions
            done.signal()
        }
        _ = done.wait(timeout: .now() + 5)
        return box.sessions
    }
    let now = Date()
    func at(_ seconds: Double) -> String { stamp(now.addingTimeInterval(seconds)) }
    func line(_ object: [String: Any]) -> JSON { JSON.parse(jsonLine(object))! }
    let path = "/home/me/.claude/projects/-home-me-app/sess-1.jsonl"
    // A server 30 s ahead of this Mac.
    func feed(_ lines: [JSON]) {
        watcher.feed(source: "gpu", path: path, agent: .claude, lines: lines, prime: nil, skew: 30)
    }
    feed([line(["type": "user", "uuid": "p1", "parentUuid": NSNull(), "timestamp": at(-90), "cwd": "/home/me/app",
                "message": ["role": "user", "content": "Build it"]])])
    var now1 = working()
    check(now1.count == 1 && now1.first?.id == "claude|gpu|sess-1", "a prompt: working, as its window: \(now1.map(\.id))")
    check(now1.first?.label == "Claude Code · app · on gpu", "named by agent, folder and server")
    check(now1.first?.task == "Build it" && now1.first?.work == "Build it", "and what it's working on: its prompt")
    check(abs((now1.first?.since.timeIntervalSince(now) ?? 0) + 120) < 1, "on this Mac's clock (the server's 30 s ahead)")
    feed([line(["type": "assistant", "uuid": "a1", "parentUuid": "p1", "timestamp": at(-40),
                "message": ["role": "assistant", "stop_reason": "tool_use", "content": [["type": "tool_use", "id": "t"]]]])])
    now1 = working()
    check(abs((now1.first?.lastWork.timeIntervalSince(now) ?? 0) + 70) < 1, "each piece of work moves its last work on")
    feed([line(["type": "assistant", "uuid": "a2", "parentUuid": "a1", "timestamp": at(-10),
                "message": ["role": "assistant", "stop_reason": "end_turn", "content": [["type": "text", "text": "Done."]]]])])
    check(working().isEmpty, "the turn ends: no longer working")
    check(changes.value == 2, "told when it started and when it stopped: \(changes.value)")
    feed([line(["type": "user", "uuid": "p2", "parentUuid": "a2", "timestamp": at(0), "message": ["role": "user",
                "content": [["type": "text", "text": "<ide_opened_file>Login.swift</ide_opened_file>"], ["type": "text", "text": "Add the remember-me box"]]]])])
    check(working().count == 1, "the next prompt: working again")
    check(working().first?.task == "Add the remember-me box", "on the new prompt, without the editor's context")
    feed([line(["type": "user", "uuid": "i2", "parentUuid": "p2", "timestamp": at(1),
                "message": ["role": "user", "content": [["type": "text", "text": "[Request interrupted by user]"]]]])])
    check(working().isEmpty, "interrupted: not working")
    // A Codex sub-agent's own thread isn't a window of its own.
    watcher.feed(source: "gpu", path: "/home/me/.codex/sessions/2026/10/26/rollout-x-sub.jsonl", agent: .codex, lines: [
        line(["type": "session_meta", "payload": ["id": "sub", "source": ["subagent": ["thread_spawn": ["parent_thread_id": "p"]]]]]),
        line(["type": "event_msg", "timestamp": at(0), "payload": ["type": "task_started"]]),
    ], prime: nil, skew: 0)
    check(working().isEmpty, "a Codex sub-agent's thread counts in its parent's turn")

    // Quiet turns: over after 20 minutes, or 3 hours while the agent's process runs on this Mac.
    func session(_ id: String, source: String?, quiet: TimeInterval) -> WorkingSession {
        WorkingSession(agent: .claude, source: source, sessionID: id, name: nil, folder: "/w", since: now.addingTimeInterval(-quiet - 60),
                       lastWork: now.addingTimeInterval(-quiet))
    }
    let sessions = [
        session("busy", source: nil, quiet: 30),
        session("long-build", source: nil, quiet: 3600),
        session("crashed", source: nil, quiet: 3600),
        session("server-quiet", source: "gpu", quiet: 3600),
        session("server-busy", source: "gpu", quiet: 60),
        session("forgotten", source: nil, quiet: 4 * 3600),
    ]
    let kept = WorkingRule.working(sessions, now: now) { $0.sessionID == "long-build" || $0.sessionID == "forgotten" }
    check(Set(kept.map(\.sessionID)) == ["busy", "long-build", "server-busy"],
          "quiet 20 minutes: over, unless its process still runs (up to 3 hours): \(kept.map(\.sessionID))")
}
