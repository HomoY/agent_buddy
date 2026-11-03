import AppKit
import AgentBuddyCore
import IOKit.pwr_mgt

/// `AgentBuddy --selftest-awake`: holds and lets go of "keep the Mac awake" as
/// the setting does, reading macOS's own list of power assertions to check; and
/// walks the lock screen's list through locking, changes and unlocking.
@MainActor
enum AwakeSelfTest {
    static func run() -> Int32 {
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            print(ok ? "  ok    \(what)" : "  FAIL  \(what)")
            if !ok {
                failures += 1
            }
        }
        let now = Date()
        let claude = WorkingSession(agent: .claude, source: nil, sessionID: "s1", name: "Fix it", folder: "/Users/me/head_show",
                                    since: now.addingTimeInterval(-600), lastWork: now)
        let codex = WorkingSession(agent: .codex, source: "gpu", sessionID: "t1", name: "Build", folder: "/home/me/site",
                                   since: now.addingTimeInterval(-60), lastWork: now)

        print("Keeping the Mac awake")
        let keeper = AwakeKeeper()
        keeper.update(working: [claude], enabled: false, display: false)
        check(!keeper.isHolding && mine().isEmpty, "off in Settings: the Mac may sleep")
        keeper.update(working: [claude], enabled: true, display: false)
        var held = mine()
        check(keeper.isHolding, "on, with an agent working: held")
        check(held.contains { $0.type == "PreventUserIdleSystemSleep" && $0.name.contains("Claude Code · head_show") },
              "macOS lists it, naming the agent: \(held.map { "\($0.type): \($0.name)" })")
        check(!held.contains { $0.type == "PreventUserIdleDisplaySleep" }, "the display may still sleep")
        keeper.update(working: [claude, codex], enabled: true, display: true)
        held = mine()
        check(held.contains { $0.type == "PreventUserIdleDisplaySleep" && $0.name.contains("on gpu") }, "with the display on too, and both agents named")
        keeper.update(working: [], enabled: true, display: true)
        check(!keeper.isHolding && mine().isEmpty, "no agent working: let go")

        print("The lock screen's list")
        var posts: [(String, String)] = []
        var removals = 0
        var enabled = true
        let status = LockScreenStatus(post: { _, title, body in posts.append((title, body)) }, remove: { _ in removals += 1 })
        status.enabled = { enabled }
        status.update([claude])
        check(posts.isEmpty, "unlocked: nothing posted")
        status.setLocked(true)
        check(posts.count == 1 && posts.last?.0 == "Claude Code is working" && posts.last?.1.hasPrefix("Claude Code · head_show · since") == true,
              "locked: the agent at work, \(posts.last.map { "\($0.0) / \($0.1)" } ?? "none")")
        check(posts.last?.1.hasSuffix("\n\u{201C}Fix it\u{201D}") == true, "and what it's working on")
        status.update([claude])
        check(posts.count == 1, "the same agents: no new alert")
        status.update([claude, codex])
        check(posts.count == 2 && posts.last?.0 == "2 agents are working" && posts.last?.1.contains("Codex · site · on gpu") == true,
              "another starts: the list changes")
        status.update([codex])
        check(posts.count == 3 && posts.last?.0 == "Codex is working", "one finishes: it leaves the list")
        status.setLocked(false)
        check(removals == 1, "unlocked: the list goes")
        status.setLocked(true)
        check(posts.count == 4, "locked again: it's back")
        status.update([])
        check(removals == 2, "no agent working: it goes")
        enabled = false
        status.update([claude])
        check(posts.count == 4, "off in Settings: nothing on the lock screen")

        print(failures == 0 ? "Awake self-test passed." : "\(failures) awake checks failed.")
        return failures == 0 ? 0 : 1
    }

    /// This process's power assertions, as `pmset -g assertions` lists them.
    private static func mine() -> [(type: String, name: String)] {
        var list: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&list) == kIOReturnSuccess,
              let byProcess = list?.takeRetainedValue() as? [NSNumber: [[String: Any]]]
        else { return [] }
        let me = NSNumber(value: getpid())
        return (byProcess[me] ?? []).map {
            (type: $0[kIOPMAssertionTypeKey] as? String ?? "", name: $0[kIOPMAssertionNameKey] as? String ?? "")
        }
    }
}
