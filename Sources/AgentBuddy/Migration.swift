import Foundation

/// Agent Buddy was called HeadShow. On its first launch it takes over what
/// HeadShow kept: its settings, finished jobs and kept agent windows, the
/// token counts' caches, its log, and the ntfy access token. HeadShow's own
/// copies are left where they are.
enum Migration {
    static let oldDomain = "io.github.homoy.headshow"
    private static let flag = "migratedFromHeadShow"

    static func run() {
        // Only the installed app: not `swift run`, the checks or the snapshots.
        guard Bundle.main.bundleIdentifier == "io.github.homoy.agentbuddy" else { return }
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: flag) else { return }
        defaults.set(true, forKey: flag)
        var copied = 0
        if let old = defaults.persistentDomain(forName: oldDomain) {
            for (key, value) in old where defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
                copied += 1
            }
        }
        let files = FileManager.default
        let library = files.homeDirectoryForCurrentUser.appendingPathComponent("Library")
        for (from, to) in [("Application Support/HeadShow", "Application Support/AgentBuddy"), ("Logs/HeadShow", "Logs/AgentBuddy")] {
            let source = library.appendingPathComponent(from)
            let target = library.appendingPathComponent(to)
            guard files.fileExists(atPath: source.path), !files.fileExists(atPath: target.path) else { continue }
            try? files.copyItem(at: source, to: target)
        }
        let logs = library.appendingPathComponent("Logs/AgentBuddy")
        for (old, new) in [("headshow.log", "agentbuddy.log"), ("headshow.old.log", "agentbuddy.old.log")] {
            let source = logs.appendingPathComponent(old)
            let target = logs.appendingPathComponent(new)
            if files.fileExists(atPath: source.path), !files.fileExists(atPath: target.path) {
                try? files.moveItem(at: source, to: target)
            }
        }
        if defaults.bool(forKey: "phone.hasToken"), Keychain.read(account: "ntfy-token") == nil,
           let token = Keychain.read(account: "ntfy-token", service: oldDomain) {
            Keychain.write(token, account: "ntfy-token")
        }
        Diagnostics.log("Agent Buddy took over HeadShow's settings (\(copied) kept)")
    }
}
