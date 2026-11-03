import Foundation

/// Codex lets one program at a time write to a thread: while a thread is open
/// for writing (in the Codex app, VS Code's Codex panel, a terminal), that
/// program holds a lock (`flock`) on `~/.codex/thread-writer-locks/<thread>.lock`,
/// and `codex exec resume` is refused ("already has an active writer").
public enum CodexWriter {
    /// Who has the thread open for writing on this Mac ("VS Code", "the Codex
    /// app"); nil if nobody does.
    public static func holder(thread: String, home: URL = Environment.home) -> String? {
        let lock = home.appendingPathComponent(".codex/thread-writer-locks/\(thread).lock").path
        guard isHeld(lock) else { return nil }
        // Who: a process with the lock file open.
        let listed = ProcessRunner.run(URL(fileURLWithPath: "/usr/sbin/lsof"), ["-t", "--", lock], timeout: 5)
        let pids = String(decoding: listed?.output ?? Data(), as: UTF8.self).split(whereSeparator: \.isNewline)
        for pid in pids {
            let shown = ProcessRunner.run(URL(fileURLWithPath: "/bin/ps"), ["-o", "args=", "-p", String(pid)], timeout: 5)
            let command = String(decoding: shown?.output ?? Data(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if !command.isEmpty {
                return describe(command)
            }
        }
        return "another program"
    }

    /// The program holding the thread on this Mac: its name, process, and the threads it holds.
    public static func holderProcess(thread: String, home: URL = Environment.home) -> CodexHolder? {
        // Real paths, as lsof gives them (/private/var, not /var).
        let locks = real(home.appendingPathComponent(".codex/thread-writer-locks").path)
        let lock = locks + "/\(thread).lock"
        guard isHeld(lock) else { return nil }
        let listed = ProcessRunner.run(URL(fileURLWithPath: "/usr/sbin/lsof"), ["-t", "--", lock], timeout: 5)
        guard let pid = String(decoding: listed?.output ?? Data(), as: UTF8.self).split(whereSeparator: \.isNewline).first.flatMap({ Int32($0) })
        else { return CodexHolder(name: "another program", pid: 0, threads: []) }
        func ps(_ field: String) -> String {
            let shown = ProcessRunner.run(URL(fileURLWithPath: "/bin/ps"), ["-o", "\(field)=", "-p", String(pid)], timeout: 5)
            return String(decoding: shown?.output ?? Data(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Codex by its program's name; its command line says where it runs.
        let program = URL(fileURLWithPath: ps("comm")).lastPathComponent.lowercased()
        let name = program.hasPrefix("codex") ? describe(ps("args")) : "another program"
        // The other threads it holds: its open lock files.
        let files = ProcessRunner.run(URL(fileURLWithPath: "/usr/sbin/lsof"), ["-a", "-p", String(pid), "-Fn"], timeout: 5)
        let threads = String(decoding: files?.output ?? Data(), as: UTF8.self).split(whereSeparator: \.isNewline)
            .filter { $0.hasPrefix("n") && $0.hasSuffix(".lock") && $0.dropFirst().hasPrefix(locks + "/") }
            .map { String(URL(fileURLWithPath: String($0.dropFirst())).deletingPathExtension().lastPathComponent) }
        return CodexHolder(name: name, pid: pid, threads: threads.sorted())
    }

    static func real(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Stops the Codex holding the thread on this Mac, if it still does (and is
    /// Codex): true once the thread is free.
    public static func stop(thread: String, pid: Int32, home: URL = Environment.home) -> Bool {
        guard let held = holderProcess(thread: thread, home: home) else { return true }
        guard pid > 0, held.pid == pid, held.name != "another program" else { return false }
        kill(pid, SIGTERM)
        for _ in 0..<60 {
            usleep(100_000)
            if holderProcess(thread: thread, home: home) == nil {
                return true
            }
        }
        return false
    }

    /// Whether another process holds the lock: tried without waiting, and let go at once.
    static func isHeld(_ path: String) -> Bool {
        let file = open(path, O_RDONLY)
        guard file >= 0 else { return false }
        defer { close(file) }
        if flock(file, LOCK_EX | LOCK_NB) == 0 {
            flock(file, LOCK_UN)
            return false
        }
        return errno == EWOULDBLOCK
    }

    /// The program, from its command line: "VS Code", "the Codex app"…
    public static func describe(_ command: String) -> String {
        let lowered = command.lowercased()
        guard lowered.contains("codex") else { return "another program" }
        for (mark, name) in [(".vscode", "VS Code"), ("cursor", "Cursor"), ("windsurf", "Windsurf"), ("zed", "Zed"),
                             ("chatgpt.app", "the Codex app"), ("codex.app/", "the Codex app")]
        where lowered.contains(mark) {
            return name
        }
        return "Codex in a terminal"
    }

    /// A send refused because the thread is open elsewhere, in words.
    public static func plain(_ problem: String) -> String {
        guard problem.contains("already has an active writer") else { return problem }
        return "Codex has this thread open elsewhere, and lets one program at a time write to it. Close it there, then send again."
    }
}

/// The program holding a Codex thread: "VS Code", its process, and every
/// thread it holds (stopping it lets go of them all).
public struct CodexHolder: Sendable, Equatable {
    public var name: String
    public var pid: Int32
    public var threads: [String]

    public init(name: String, pid: Int32, threads: [String]) {
        self.name = name
        self.pid = pid
        self.threads = threads
    }
}
