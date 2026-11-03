import Foundation

/// What the message box offers after @, as Zed's does: the session folder's
/// files and folders, here or on the server.
public enum ProjectFiles {
    /// Most paths read from a folder.
    public static let most = 20000
    /// Folders a walk skips (a git repository's own ignores do this there).
    static let skipped: Set<String> = [
        ".git", "node_modules", ".build", "build", "dist", "target", ".venv", "venv", "__pycache__", ".next", ".cache",
        "DerivedData", "Pods",
    ]

    /// Relative paths of the folder's files, here or on the server: what git
    /// tracks and doesn't ignore, else a walk that skips hidden and build
    /// folders. Blocking.
    public static func list(folder: String, host: String?, transport: [String]? = nil) -> Result<[String], ReadError> {
        if let host {
            guard let reply = PromptSender.remote(["op": "files", "folder": folder], host: host, transport: transport, timeout: 40) else {
                return .failure(ReadError("\(host) didn't answer"))
            }
            if let problem = reply["hs_error"].nonEmptyString {
                return .failure(ReadError("\(host): \(problem)"))
            }
            return .success(reply["files"].array.compactMap(\.string))
        }
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder, isDirectory: &isFolder), isFolder.boolValue else {
            return .failure(ReadError("The session's folder isn't there anymore: \(folder)"))
        }
        if let git = ProcessRunner.run(
            URL(fileURLWithPath: "/usr/bin/git"), ["-C", folder, "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
            timeout: 15), git.status == 0 {
            let paths = git.output.split(separator: 0).prefix(most).map { String(decoding: $0, as: UTF8.self) }
            if !paths.isEmpty {
                return .success(paths)
            }
        }
        return .success(walk(folder))
    }

    static func walk(_ folder: String) -> [String] {
        let root = URL(fileURLWithPath: folder, isDirectory: true)
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return [] }
        var paths: [String] = []
        let prefix = root.standardizedFileURL.path + "/"
        while let url = walker.nextObject() as? URL, paths.count < most {
            let path = url.standardizedFileURL.path
            let relative = path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : url.lastPathComponent
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                if skipped.contains(url.lastPathComponent) {
                    walker.skipDescendants()
                } else {
                    // Folders too, as Zed's @ has them (an empty one included).
                    paths.append(relative + "/")
                }
                continue
            }
            paths.append(relative)
        }
        return paths
    }

    /// The files and folders best matching what's typed after @: a name that
    /// starts with it first, then one that has it, then a path that has it,
    /// then one with its letters in order. Folders end in /.
    public static func matches(_ query: String, in paths: [String], limit: Int = 30) -> [String] {
        var folders = Set<String>()
        for path in paths {
            var parent = (path as NSString).deletingLastPathComponent
            while !parent.isEmpty, folders.insert(parent + "/").inserted {
                parent = (parent as NSString).deletingLastPathComponent
            }
        }
        let wanted = query.lowercased()
        var seen = Set<String>()
        let all = (paths + folders.sorted()).filter { seen.insert($0).inserted }
        guard !wanted.isEmpty else {
            // Nothing typed yet: the files nearest the top.
            return Array(all.sorted { ($0.filter { $0 == "/" }.count, $0) < ($1.filter { $0 == "/" }.count, $1) }.prefix(limit))
        }
        var ranked: [(rank: Int, path: String)] = []
        for path in all {
            let lowered = path.lowercased()
            let name = (lowered.hasSuffix("/") ? String(lowered.dropLast()) : lowered).split(separator: "/").last.map(String.init) ?? lowered
            let rank: Int
            if name.hasPrefix(wanted) {
                rank = 0
            } else if name.contains(wanted) {
                rank = 1
            } else if lowered.contains(wanted) {
                rank = 2
            } else if inOrder(wanted, lowered) {
                rank = 3
            } else {
                continue
            }
            ranked.append((rank, path))
        }
        return ranked.sorted { ($0.rank, $0.path.count, $0.path) < ($1.rank, $1.path.count, $1.path) }.prefix(limit).map(\.path)
    }

    /// Whether `letters` appear in `text` in order.
    static func inOrder(_ letters: String, _ text: String) -> Bool {
        var remaining = letters[...]
        for character in text where character == remaining.first {
            remaining = remaining.dropFirst()
            if remaining.isEmpty {
                return true
            }
        }
        return remaining.isEmpty
    }

    /// How a file is named after @: quoted when it has a space.
    public static func mention(_ path: String) -> String {
        path.contains(" ") ? "@\"\(path)\"" : "@\(path)"
    }
}

/// A command the message box offers after /: one of the agent's own, one of
/// yours, a plugin's, a skill, or (Codex) a custom prompt.
public struct AgentCommand: Sendable, Equatable {
    public enum Kind: String, Sendable {
        case builtIn
        case command
        case skill
        case prompt
    }

    /// As it's typed, without the /: "compact", "ars-plan", "prompts:fix".
    public var name: String
    public var description: String
    public var kind: Kind
    /// A Codex prompt's text, filled in here before sending (Codex runs it only in its terminal).
    public var body: String?
    /// What it's typed after: / for a command, $ for a Codex skill (as Codex mentions one).
    public var sign: String

    public init(name: String, description: String, kind: Kind, body: String? = nil, sign: String = "/") {
        self.name = name
        self.description = description
        self.kind = kind
        self.body = body
        self.sign = sign
    }

    /// What goes in the box.
    public var typed: String {
        sign + name
    }
}

public enum AgentCommands {
    /// Claude Code's own that a prompt sent from here can run.
    static let claudeBuiltIns = [
        AgentCommand(name: "compact", description: "Free up context by summarizing the conversation so far", kind: .builtIn),
        AgentCommand(name: "init", description: "Write a CLAUDE.md with what to know about this project", kind: .builtIn),
        AgentCommand(name: "security-review", description: "Review the pending changes for security issues", kind: .builtIn),
    ]

    /// The commands for a session's agent, here or on the server: its own, yours
    /// (in your home and in the session's folder), plugins' and skills. Blocking.
    public static func list(agent: Agent, folder: String?, host: String?, transport: [String]? = nil) -> Result<[AgentCommand], ReadError> {
        if let host {
            guard let reply = PromptSender.remote(["op": "commands", "agent": agent.rawValue, "folder": folder ?? ""],
                                                  host: host, transport: transport, timeout: 40)
            else { return .failure(ReadError("\(host) didn't answer")) }
            if let problem = reply["hs_error"].nonEmptyString {
                return .failure(ReadError("\(host): \(problem)"))
            }
            let listed = reply["commands"].array.compactMap { item -> AgentCommand? in
                guard let name = item["name"].nonEmptyString, let kind = AgentCommand.Kind(rawValue: item["kind"].string ?? "") else { return nil }
                return AgentCommand(name: name, description: item["description"].string ?? "", kind: kind, body: item["body"].string,
                                    sign: item["sign"].nonEmptyString ?? "/")
            }
            return .success(sorted((agent == .claude ? claudeBuiltIns : []) + listed))
        }
        return .success(listHere(agent: agent, folder: folder, home: Environment.home))
    }

    public static func listHere(agent: Agent, folder: String?, home: URL) -> [AgentCommand] {
        var found: [AgentCommand] = []
        switch agent {
        case .claude:
            found = claudeBuiltIns
            let roots = [home.appendingPathComponent(".claude")] + (folder.map { [URL(fileURLWithPath: $0).appendingPathComponent(".claude")] } ?? [])
            for root in roots {
                found += markdown(in: root.appendingPathComponent("commands"), nested: true).map {
                    AgentCommand(name: $0.name, description: $0.description, kind: .command)
                }
                // skills/<name>/SKILL.md, and synced/<bucket>/<name>/SKILL.md.
                found += skills(in: root.appendingPathComponent("skills"), depth: 4)
            }
            // Installed plugins: their commands and skills.
            let index = home.appendingPathComponent(".claude/plugins/installed_plugins.json")
            if let data = try? Data(contentsOf: index), let plugins = JSON.parse(data)?["plugins"].object {
                for installs in plugins.values {
                    for install in installs.array {
                        guard let path = install["installPath"].nonEmptyString else { continue }
                        let plugin = URL(fileURLWithPath: path)
                        found += markdown(in: plugin.appendingPathComponent("commands"), nested: false).map {
                            AgentCommand(name: $0.name, description: $0.description, kind: .command)
                        }
                        found += skills(in: plugin, depth: 3)
                    }
                }
            }
        case .codex:
            found = markdown(in: home.appendingPathComponent(".codex/prompts"), nested: false).map {
                AgentCommand(name: "prompts:\($0.name)", description: $0.description, kind: .prompt, body: $0.body)
            }
            found += skills(in: home.appendingPathComponent(".codex/skills"), depth: 4).map {
                AgentCommand(name: $0.name, description: $0.description, kind: .skill, sign: "$")
            }
        default:
            break
        }
        return sorted(found)
    }

    /// Each name once (the first found: the folder's, yours, then a plugin's), alphabetically.
    static func sorted(_ commands: [AgentCommand]) -> [AgentCommand] {
        var seen = Set<String>()
        return commands.filter { seen.insert($0.name).inserted }.sorted { $0.name < $1.name }
    }

    /// The `.md` files in a folder (and its folders, named with ":", if nested).
    static func markdown(in folder: URL, nested: Bool) -> [(name: String, description: String, body: String)] {
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            return []
        }
        var found: [(String, String, String)] = []
        let prefix = folder.standardizedFileURL.path + "/"
        while let url = walker.nextObject() as? URL, found.count < 500 {
            guard url.pathExtension == "md" else { continue }
            let relative = url.standardizedFileURL.path.dropFirst(prefix.count)
            guard nested || !relative.contains("/") else { continue }
            let (meta, body) = frontMatter(url)
            let name = String(relative.dropLast(3)).replacingOccurrences(of: "/", with: ":")
            found.append((name, meta["description"] ?? firstLine(body), body))
        }
        return found
    }

    /// Skills: a folder with a SKILL.md, named by its `name:`; `depth`, how deep the SKILL.md may be.
    static func skills(in folder: URL, depth: Int) -> [AgentCommand] {
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil, options: []) else { return [] }
        var found: [AgentCommand] = []
        while let url = walker.nextObject() as? URL, found.count < 500 {
            if walker.level > depth {
                walker.skipDescendants()
                continue
            }
            guard url.lastPathComponent == "SKILL.md" else { continue }
            let (meta, body) = frontMatter(url)
            let name = meta["name"] ?? url.deletingLastPathComponent().lastPathComponent
            found.append(AgentCommand(name: name, description: meta["description"] ?? firstLine(body), kind: .skill))
        }
        return found
    }

    /// A Markdown file's front matter (`key: value` between --- lines) and the rest.
    static func frontMatter(_ file: URL) -> ([String: String], String) {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return ([:], "") }
        defer { try? handle.close() }
        let text = String(decoding: (try? handle.read(upToCount: 64 * 1024)) ?? Data(), as: UTF8.self)
        guard text.hasPrefix("---"), let end = text.range(of: "\n---", range: text.index(text.startIndex, offsetBy: 3)..<text.endIndex) else {
            return ([:], text)
        }
        var meta: [String: String] = [:]
        for line in text[text.index(text.startIndex, offsetBy: 3)..<end.lowerBound].split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if !key.isEmpty, !value.isEmpty, !key.contains(" ") {
                meta[key] = value
            }
        }
        let rest = text[end.upperBound...].drop { $0 != "\n" }
        return (meta, String(rest).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func firstLine(_ text: String) -> String {
        let line = text.split(separator: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        return String(line.trimmingCharacters(in: CharacterSet(charactersIn: "# ").union(.whitespaces)).prefix(120))
    }

    /// The commands best matching what's typed after /: names that start with it first.
    public static func matches(_ query: String, in commands: [AgentCommand], limit: Int = 50) -> [AgentCommand] {
        let wanted = query.lowercased()
        let order: [AgentCommand.Kind] = [.builtIn, .command, .prompt, .skill]
        guard !wanted.isEmpty else {
            // Nothing typed yet: the agent's own first, then yours, then prompts and skills.
            return Array(commands.sorted { (order.firstIndex(of: $0.kind) ?? 9, $0.name) < (order.firstIndex(of: $1.kind) ?? 9, $1.name) }.prefix(limit))
        }
        let starting = commands.filter { $0.name.lowercased().hasPrefix(wanted) || $0.name.lowercased().split(separator: ":").last?.hasPrefix(wanted) == true }
        let having = commands.filter { !starting.contains($0) && ($0.name.lowercased().contains(wanted) || $0.description.lowercased().contains(wanted)) }
        return Array((starting + having).prefix(limit))
    }

    /// A Codex prompt run from here: "/prompts:name what to do" becomes the
    /// prompt's text with what follows put in ($ARGUMENTS, $1…$9). Codex runs
    /// its prompts in its terminal only; nil when the text isn't one.
    public static func expand(_ text: String, with commands: [AgentCommand]) -> String? {
        guard text.hasPrefix("/") else { return nil }
        let typed = text.dropFirst()
        let name = typed.prefix { !$0.isWhitespace }
        guard let command = commands.first(where: { $0.kind == .prompt && ($0.name == name || $0.name == "prompts:\(name)") }),
              let body = command.body
        else { return nil }
        let arguments = typed.dropFirst(name.count).trimmingCharacters(in: .whitespacesAndNewlines)
        var expanded = body.replacingOccurrences(of: "$ARGUMENTS", with: arguments)
        let words = arguments.split(whereSeparator: \.isWhitespace).map(String.init)
        for index in (1...9).reversed() {
            expanded = expanded.replacingOccurrences(of: "$\(index)", with: index <= words.count ? words[index - 1] : "")
        }
        // Text after the command that the prompt doesn't take goes after it.
        if !arguments.isEmpty, !body.contains("$ARGUMENTS"), !(1...9).contains(where: { body.contains("$\($0)") }) {
            expanded += "\n\n" + arguments
        }
        return expanded
    }
}
