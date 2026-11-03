import Foundation

/// A Claude Code log as an agent window last read it, kept to read it again: a
/// log that only grew since is read on from where the last read stopped, not
/// from the start. (A long session's log runs to a hundred megabytes, and an
/// agent at work adds to it every few seconds.) Agents only add to their logs;
/// one replaced, cut short or changed at its start or where the last read
/// stopped is read whole again, and `forget()` has the next read read it whole.
public final class SessionLogReading: @unchecked Sendable {
    private let lock = NSLock()
    private var log: (path: String, progress: LogProgress, reading: SessionHistoryReader.ClaudeReading)?
    /// Each sub-agent's log as far as read, with its lines that count.
    private var subagents: [String: (progress: LogProgress, lines: [JSON])] = [:]

    public init() {}

    /// The next read reads the log whole.
    public func forget() {
        lock.lock()
        defer { lock.unlock() }
        log = nil
        subagents = [:]
    }

    /// The session's history from `data`, its log at `path`: as reading it whole would.
    func claude(_ data: Data, path: String, session: String) -> SessionHistory {
        lock.lock()
        defer { lock.unlock() }
        let known = log?.path == path ? log : nil
        let read = LogProgress.read(data, path: path, after: known?.progress)
        var reading = (read.fromStart ? nil : known?.reading) ?? SessionHistoryReader.ClaudeReading(sessionID: session)
        for line in read.lines {
            reading.add(line)
        }
        log = (path, read.progress, reading)
        // Not kept, but read as when read whole: a last line not ended yet, then the sub-agents' lines.
        if let last = read.last {
            reading.add(last)
        }
        for line in subagentLines(beside: URL(fileURLWithPath: path), session: session) {
            reading.add(line)
        }
        return reading.finished()
    }

    /// As `SessionHistoryReader.subagentLines`, each log read on from where it was.
    private func subagentLines(beside log: URL, session: String) -> [JSON] {
        var found: [JSON] = []
        var read: [String: (progress: LogProgress, lines: [JSON])] = [:]
        let folder = SessionHistoryReader.subagentFolder(beside: log, session: session)
        if let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) {
            for case let file as URL in walker where file.pathExtension == "jsonl" {
                guard let data = try? Data(contentsOf: file, options: .alwaysMapped) else { continue }
                let known = subagents[file.path]
                let added = LogProgress.read(data, path: file.path, after: known?.progress)
                let lines = (added.fromStart ? [] : known?.lines ?? []) + added.lines.compactMap(SessionHistoryReader.subagentLine)
                read[file.path] = (added.progress, lines)
                found += lines
                if let last = added.last.flatMap(SessionHistoryReader.subagentLine) {
                    found.append(last)
                }
            }
        }
        subagents = read
        return found
    }
}

/// The turns an agent window shows open, as last read: one at work is read on
/// from where it was, not from its prompt again (a long turn's lines run to
/// megabytes, and its agent adds to them every few seconds).
public final class StepsReading: @unchecked Sendable {
    private let lock = NSLock()
    private var turns: [String: (path: String, progress: LogProgress, reading: SessionHistoryReader.ClaudeStepsReading)] = [:]

    public init() {}

    /// The next reads read each turn from its prompt again.
    public func forget() {
        lock.lock()
        defer { lock.unlock() }
        turns = [:]
    }

    /// The turn's steps from `data`, its log at `path`, its prompt's line at `from`: as reading it whole would.
    func claude(_ data: Data, path: String, from: Int, turn: String, cwd: String?) -> [TurnStep] {
        lock.lock()
        defer { lock.unlock() }
        let known = turns[turn]?.path == path ? turns[turn] : nil
        let read = LogProgress.read(data, path: path, after: known?.progress, from: from)
        var reading = (read.fromStart ? nil : known?.reading) ?? SessionHistoryReader.ClaudeStepsReading(turn: turn, cwd: cwd)
        for line in read.lines where !reading.ended {
            reading.add(line)
        }
        if turns.count >= 50, known == nil {
            turns = [:]
        }
        turns[turn] = (path, read.progress, reading)
        // A last line not ended yet: read, not kept (it's read again whole next time).
        if let last = read.last, !reading.ended {
            reading.add(last)
        }
        return reading.steps
    }
}

/// How far a log was read: to the end of its last whole line. Its first bytes,
/// and those just before there, tell at the next read that it's the same log, only grown.
struct LogProgress {
    struct File: Equatable {
        var device: Int64
        var inode: UInt64
    }

    var file: File?
    var offset: Int
    var head: Data
    var tail: Data

    /// The lines of `data` (all of the log at `path`) after `progress`, when it's
    /// the same log only grown since, else all of them; apart, a last line not
    /// ended yet (it's read again next time); and how far that is.
    /// Read whole, it's read from `from` (where a turn's prompt is, say).
    static func read(
        _ data: Data, path: String, after progress: LogProgress?, from: Int = 0
    ) -> (lines: [JSON], last: JSON?, progress: LogProgress, fromStart: Bool) {
        var info = stat()
        let file = stat(path, &info) == 0 ? File(device: Int64(info.st_dev), inode: UInt64(info.st_ino)) : nil
        var start = min(max(from, 0), data.count)
        var readOn = false
        if let progress, let file, progress.file == file, progress.offset <= data.count, progress.offset >= progress.tail.count,
           data.subdata(in: 0..<progress.head.count) == progress.head,
           data.subdata(in: progress.offset - progress.tail.count..<progress.offset) == progress.tail {
            start = progress.offset
            readOn = true
        }
        // Just after the last newline (a log's last line is usually ended).
        let end = data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> Int in
            var index = bytes.count
            while index > start, bytes[index - 1] != 0x0A {
                index -= 1
            }
            return index
        }
        let lines = SessionHistoryReader.lines(data[start..<end])
        let last = end < data.count ? JSON.parse(data.subdata(in: end..<data.count)) : nil
        let marks = (head: data.subdata(in: 0..<min(256, end)), tail: data.subdata(in: max(0, end - 256)..<end))
        return (lines, last, LogProgress(file: file, offset: end, head: marks.head, tail: marks.tail), !readOn)
    }
}
