import Foundation

/// Where the agents keep their files, and the environment the engines run in.
/// A menu bar app does not inherit the shell's variables, so the login shell is
/// asked once, off the main thread.
public enum Environment {
    public static let home = FileManager.default.homeDirectoryForCurrentUser

    /// Variables from the user's login shell (`$SHELL -l`), read once.
    public static let loginShell: [String: String] = {
        let names = ["PATH", "CLAUDE_CONFIG_DIR", "CODEX_HOME", "COPILOT_HOME", "GH_CONFIG_DIR"]
        var shell = ProcessInfo.processInfo.environment["SHELL"] ?? ""
        if !["zsh", "bash", "sh", "ksh"].contains(URL(fileURLWithPath: shell).lastPathComponent) {
            shell = "/bin/zsh"
        }
        let script = names.map { "printf '__HS__\($0)=%s\\n' \"$\($0)\"" }.joined(separator: "; ")
        guard let result = ProcessRunner.run(
            URL(fileURLWithPath: shell), ["-l", "-c", script],
            environment: ProcessInfo.processInfo.environment, directory: home, timeout: 5
        ) else { return [:] }
        var values: [String: String] = [:]
        for line in result.text.split(separator: "\n") where line.hasPrefix("__HS__") {
            let pair = line.dropFirst(6)
            guard let equals = pair.firstIndex(of: "=") else { continue }
            let value = String(pair[pair.index(after: equals)...])
            if !value.isEmpty {
                values[String(pair[..<equals])] = value
            }
        }
        return values
    }()

    public static func value(_ name: String) -> String? {
        if let value = ProcessInfo.processInfo.environment[name], !value.isEmpty {
            return value
        }
        return loginShell[name]
    }

    private static func folder(_ variable: String, default relative: String) -> URL {
        if let value = value(variable) {
            return URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
        }
        return home.appendingPathComponent(relative)
    }

    /// `CLAUDE_CONFIG_DIR`, or `~/.claude`.
    public static var claudeConfigDir: URL { folder("CLAUDE_CONFIG_DIR", default: ".claude") }
    /// `CODEX_HOME`, or `~/.codex`.
    public static var codexHome: URL { folder("CODEX_HOME", default: ".codex") }
    /// `COPILOT_HOME`, or `~/.copilot`.
    public static var copilotHome: URL { folder("COPILOT_HOME", default: ".copilot") }
    /// Gemini CLI's `~/.gemini` (`GEMINI_DIR` moves it).
    public static var geminiHome: URL { folder("GEMINI_DIR", default: ".gemini") }
    /// Qwen Code's `~/.qwen` (`QWEN_RUNTIME_DIR` moves it).
    public static var qwenHome: URL { folder("QWEN_RUNTIME_DIR", default: ".qwen") }
    /// OpenCode's data: `$XDG_DATA_HOME/opencode`, or `~/.local/share/opencode`.
    public static var openCodeData: URL {
        if let data = value("XDG_DATA_HOME") {
            return URL(fileURLWithPath: (data as NSString).expandingTildeInPath).appendingPathComponent("opencode")
        }
        return home.appendingPathComponent(".local/share/opencode")
    }
    /// Cursor's `~/.cursor`, where its agent keeps its chats.
    public static var cursorHome: URL { home.appendingPathComponent(".cursor") }
    /// DeepSeek Harness's `DSH_HOME`, or `~/.dsh`.
    public static var dshHome: URL { folder("DSH_HOME", default: ".dsh") }

    /// Claude Code's profile: `$CLAUDE_CONFIG_DIR/.claude.json`, or `~/.claude.json`.
    public static var claudeProfile: URL {
        if let value = value("CLAUDE_CONFIG_DIR") {
            return URL(fileURLWithPath: (value as NSString).expandingTildeInPath).appendingPathComponent(".claude.json")
        }
        return home.appendingPathComponent(".claude.json")
    }

    /// A quiet folder the engines start in, so no project's settings apply.
    public static var workDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? home.appendingPathComponent("Library/Application Support")
        let folder = base.appendingPathComponent("AgentBuddy", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// PATH for the engines this app starts: common install folders, then the login shell's.
    public static let enginePath: String = {
        let home = Environment.home.path
        var folders = [
            "\(home)/.local/bin", "\(home)/.bun/bin", "\(home)/.npm-global/bin",
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        ]
        folders += (loginShell["PATH"] ?? "").split(separator: ":").map(String.init)
        // An npm-installed CLI is a Node script; nvm's newest Node may only be in .zshrc.
        if let node = Executables.newestChildren("\(home)/.nvm/versions/node").first {
            folders.append("\(node)/bin")
        }
        var seen = Set<String>()
        return folders.filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ":")
    }()

    public static func engineEnvironment(_ extra: [String: String] = [:]) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = enginePath
        environment["HOME"] = home.path
        for name in ["CLAUDE_CONFIG_DIR", "CODEX_HOME", "COPILOT_HOME", "GH_CONFIG_DIR"] where environment[name] == nil {
            if let value = loginShell[name] {
                environment[name] = value
            }
        }
        for (key, value) in extra {
            environment[key] = value
        }
        return environment
    }
}

public enum Executables {
    /// The first runnable copy of `name`, in PATH and the folders installers use.
    public static func find(_ name: String) -> URL? {
        candidates(name).first(where: isExecutable).map { URL(fileURLWithPath: $0) }
    }

    static func candidates(_ name: String) -> [String] {
        let home = Environment.home.path
        var list = [
            "\(home)/.local/bin/\(name)", "\(home)/.bun/bin/\(name)", "\(home)/.npm-global/bin/\(name)",
            "/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)",
        ]
        if name == "node" {
            // nvm's, newest first.
            list += newestChildren("\(home)/.nvm/versions/node").map { "\($0)/bin/node" }
        }
        if name == "claude" {
            list.append("\(home)/.claude/local/claude")
            list += newestChildren("\(home)/.local/share/claude/versions")
        }
        list += Environment.enginePath.split(separator: ":").map { "\($0)/\(name)" }
        if name == "claude" {
            // The Claude desktop app's own Claude Code.
            for version in newestChildren("\(home)/Library/Application Support/Claude/claude-code") {
                for build in newestChildren(version) {
                    list.append("\(build)/claude.app/Contents/MacOS/claude")
                }
            }
        }
        if name == "codex" {
            // The Codex that ships inside the ChatGPT and Codex desktop apps.
            for root in ["/Applications", "\(home)/Applications"] {
                for app in ["ChatGPT.app", "Codex.app"] {
                    list.append("\(root)/\(app)/Contents/Resources/codex-cli/bin/codex")
                    list.append("\(root)/\(app)/Contents/Resources/codex")
                }
            }
        }
        return list
    }

    /// A folder's entries, most recently modified first.
    static func newestChildren(_ folder: String) -> [String] {
        let url = URL(fileURLWithPath: folder)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        func modified(_ entry: URL) -> Date {
            (try? entry.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        }
        return entries.sorted { modified($0) > modified($1) }.map(\.path)
    }

    static func isExecutable(_ path: String) -> Bool {
        var isFolder: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isFolder)
            && !isFolder.boolValue
            && FileManager.default.isExecutableFile(atPath: path)
    }
}
