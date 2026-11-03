import Darwin
import Foundation

/// A look at the running processes, to find where an agent session runs: its
/// process, the app above it, and the terminal it's attached to.
public struct ProcessTable {
    public struct Entry: Equatable, Sendable {
        public var pid: Int32
        public var parent: Int32
        /// "/dev/ttys003", or nil without a terminal.
        public var tty: String?
        public var name: String
        /// When it started (seconds since 1970): with its number, which process it is.
        public var started: Double

        public init(pid: Int32, parent: Int32, tty: String?, name: String, started: Double = 0) {
            self.pid = pid
            self.parent = parent
            self.tty = tty
            self.name = name
            self.started = started
        }
    }

    public private(set) var entries: [Int32: Entry] = [:]

    public init(entries: [Int32: Entry]) {
        self.entries = entries
    }

    /// Every process now, or as it was a moment ago: agent windows each look
    /// every few seconds, and share a look.
    public static func recent() -> ProcessTable {
        recently.value(0) { snapshot() }
    }

    private static let recently = Recently<Int, ProcessTable>(lifetime: 3)

    /// Every process now (a few milliseconds).
    public static func snapshot() -> ProcessTable {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return ProcessTable(entries: [:]) }
        let stride = MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 32)
        size = procs.count * stride
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return ProcessTable(entries: [:]) }
        var entries: [Int32: Entry] = [:]
        for var proc in procs.prefix(size / stride) {
            let pid = proc.kp_proc.p_pid
            guard pid > 0 else { continue }
            let device = proc.kp_eproc.e_tdev
            let tty = device == -1 ? nil : terminals.name(device)
            let name = withUnsafeBytes(of: &proc.kp_proc.p_comm) { raw in
                String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
            }
            let started = Double(proc.kp_proc.p_starttime.tv_sec) + Double(proc.kp_proc.p_starttime.tv_usec) / 1e6
            entries[pid] = Entry(pid: pid, parent: proc.kp_eproc.e_ppid, tty: tty, name: name, started: started)
        }
        return ProcessTable(entries: entries)
    }

    /// Terminals' names by device: a device is always the same terminal, and
    /// finding its name looks through /dev (for each process, at each look).
    private static let terminals = TerminalNames()

    private final class TerminalNames: @unchecked Sendable {
        private let lock = NSLock()
        private var names: [dev_t: String] = [:]

        /// "/dev/ttys003".
        func name(_ device: dev_t) -> String? {
            lock.lock()
            defer { lock.unlock() }
            if let known = names[device] {
                return known
            }
            // devname's answer is in a buffer of its own: read under the lock.
            guard let name = devname(device, S_IFCHR) else { return nil }
            let path = "/dev/" + String(cString: name)
            names[device] = path
            return path
        }
    }

    /// The process and those above it, nearest first, up to (not including) launchd.
    public func lineage(of pid: Int32) -> [Int32] {
        var chain: [Int32] = []
        var current = pid
        while current > 1, chain.count < 64, let entry = entries[current], !chain.contains(current) {
            chain.append(current)
            current = entry.parent
        }
        return chain
    }

    // MARK: - Per process (your own processes only)

    /// The executable's path.
    public static func path(of pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    /// The working folder.
    public static func folder(of pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        return path.isEmpty ? nil : path
    }

    /// The arguments, the program first.
    public static func arguments(of pid: Int32) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > 4 else { return [] }
        let count = Int(buffer.withUnsafeBytes { $0.load(as: Int32.self) })
        var index = 4
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        var arguments: [String] = []
        var start = index
        while index < size, arguments.count < count {
            if buffer[index] == 0 {
                arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
                start = index + 1
            }
            index += 1
        }
        return arguments
    }

    /// The outermost `.app` the executable is in: "/Applications/Visual Studio
    /// Code.app" for one of its helpers, "/Applications/ChatGPT.app" for the
    /// Codex inside it.
    public static func appBundle(containing path: String) -> String? {
        guard let range = path.range(of: ".app/") else {
            return path.hasSuffix(".app") ? path : nil
        }
        return String(path[..<range.lowerBound]) + ".app"
    }

    // MARK: - Agents and connections

    /// The agent's processes working in one of `folders` (Claude Code, the
    /// Codex and Copilot CLIs; editors' shared Codex and Copilot servers work
    /// from "/" and aren't matched this way).
    public func agentProcesses(_ agent: Agent, in folders: [String]) -> [Int32] {
        let wanted = Set(folders.map(Self.canonical))
        guard !wanted.isEmpty else { return [] }
        return entries.values.compactMap { entry -> Int32? in
            guard Self.isAgent(agent, entry: entry) else { return nil }
            guard let folder = Self.folder(of: entry.pid), wanted.contains(Self.canonical(folder)) else { return nil }
            return entry.pid
        }
        .sorted()
    }

    static func isAgent(_ agent: Agent, entry: Entry) -> Bool {
        let names: [String]
        /// The npm package's folder, for one run by node.
        let packages: [String]
        switch agent {
        case .claude: (names, packages) = (["claude"], ["/claude-code/"])
        case .codex: (names, packages) = (["codex"], ["@openai/codex"])
        case .copilot: (names, packages) = (["copilot"], ["@github/copilot"])
        case .gemini: (names, packages) = (["gemini"], ["@google/gemini-cli"])
        case .qwen: (names, packages) = (["qwen"], ["@qwen-code/qwen-code"])
        case .opencode: (names, packages) = (["opencode"], ["opencode-ai", "/opencode-darwin"])
        case .cursor: (names, packages) = (["cursor-agent"], ["/cursor-agent/"])
        case .deepseek: (names, packages) = (["dsh"], ["@deepseek-ai/dsh"])
        }
        if names.contains(entry.name) {
            return true
        }
        // Installed through npm: `node …/claude` or `node …/@anthropic-ai/claude-code/cli.js`.
        guard entry.name == "node" else { return false }
        let arguments = nodeArguments(entry).dropFirst().prefix(2)
        return arguments.contains { argument in
            names.contains { URL(fileURLWithPath: argument).lastPathComponent == $0 } || packages.contains { argument.contains($0) }
        }
    }

    /// `ssh` processes connected to `host` ("user@server", an alias, or an
    /// address), except Agent Buddy's own.
    public func sshProcesses(to host: String) -> [Int32] {
        let target = Self.hostKey(host)
        let me = getpid()
        return entries.values.compactMap { entry -> Int32? in
            guard entry.name == "ssh", !lineage(of: entry.pid).contains(me) else { return nil }
            guard let destination = Self.sshDestination(Self.arguments(of: entry.pid)) else { return nil }
            return Self.hostKey(destination) == target ? entry.pid : nil
        }
        .sorted()
    }

    /// The host an ssh command line connects to: its first argument that isn't
    /// an option or an option's value.
    public static func sshDestination(_ arguments: [String]) -> String? {
        let withValue = Set("BbcDEeFIiJLlmOoPpQRSWw".map { "-\($0)" })
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" {
                return index + 1 < arguments.count ? arguments[index + 1] : nil
            }
            if argument.hasPrefix("-") {
                // "-p 22" takes the next argument; "-p22" and flags like "-T" don't.
                if withValue.contains(argument) {
                    index += 1
                }
                index += 1
                continue
            }
            return argument
        }
        return nil
    }

    /// "user@Server:22" and "server" compare alike.
    public static func hostKey(_ host: String) -> String {
        var key = host.lowercased()
        if let at = key.lastIndex(of: "@") {
            key = String(key[key.index(after: at)...])
        }
        if key.hasPrefix("ssh://") {
            key = String(key.dropFirst(6))
        }
        if let colon = key.firstIndex(of: ":"), !key.contains("]") {
            key = String(key[..<colon])
        }
        return key.trimmingCharacters(in: CharacterSet(charactersIn: "[]/"))
    }

    /// A node process's arguments, asked once: they're the same as long as it
    /// runs, and there are many (editors' helpers, MCP servers) to look through.
    private static func nodeArguments(_ entry: Entry) -> [String] {
        let key = "\(entry.pid)@\(entry.started)"
        nodes.lock.lock()
        if let known = nodes.arguments[key] {
            nodes.lock.unlock()
            return known
        }
        nodes.lock.unlock()
        let arguments = Self.arguments(of: entry.pid)
        nodes.lock.lock()
        defer { nodes.lock.unlock() }
        if nodes.arguments.count > 2000 {
            nodes.arguments = [:]
        }
        nodes.arguments[key] = arguments
        return arguments
    }

    private static let nodes = NodeArguments()

    private final class NodeArguments: @unchecked Sendable {
        let lock = NSLock()
        var arguments: [String: [String]] = [:]
    }

    public static func canonical(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
