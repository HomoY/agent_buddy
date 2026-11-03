import Foundation
import AgentBuddyCore

/// An agent window reads its session's log on from where it last stopped: the
/// history it gets is the same as reading the log whole, as it grows (a line at
/// a time or cut mid-line), with its sub-agents' logs, and when it's replaced or
/// rewritten. And the quick way timestamps are read gives the formatter's dates.
func checkLogReading() {
    print("Reading a log on from where it was")
    let manager = FileManager.default
    let scratch = manager.temporaryDirectory.appendingPathComponent("ab-reading-\(UUID().uuidString)")
    defer { try? manager.removeItem(at: scratch) }
    let session = "5f0c2a8e-1d3b-4c55-9e1a-7b2f00c0ffee"
    let log = scratch.appendingPathComponent("-work/\(session).jsonl")
    let subagent = scratch.appendingPathComponent("-work/\(session)/subagents/agent-1.jsonl")
    try? manager.createDirectory(at: subagent.deletingLastPathComponent(), withIntermediateDirectories: true)

    let start = Date(timeIntervalSince1970: 1_790_000_000)
    func stamp(_ seconds: Int) -> String {
        ISO8601DateFormatter.string(from: start.addingTimeInterval(TimeInterval(seconds) + 0.123), timeZone: TimeZone(secondsFromGMT: 0)!,
                                    formatOptions: [.withInternetDateTime, .withFractionalSeconds])
    }
    var lines: [String] = []
    var parent = "null"
    for turn in 0..<6 {
        let prompt = "p\(turn)"
        lines.append(#"{"type":"user","uuid":"\#(prompt)","parentUuid":\#(parent),"timestamp":"\#(stamp(turn * 100))","cwd":"/work","message":{"role":"user","content":"Question \#(turn)"}}"#)
        let answer = "a\(turn)"
        lines.append(#"{"type":"assistant","uuid":"\#(answer)","parentUuid":"\#(prompt)","timestamp":"\#(stamp(turn * 100 + 30))","requestId":"r\#(turn)","message":{"id":"m\#(turn)","role":"assistant","model":"claude-opus-5-5","stop_reason":"end_turn","content":[{"type":"text","text":"Answer \#(turn)"}],"usage":{"input_tokens":\#(10 + turn),"output_tokens":\#(5 + turn)}}}"#)
        parent = "\"\(answer)\""
    }
    lines.append(#"{"type":"ai-title","aiTitle":"Six questions"}"#)
    let whole = Data((lines.joined(separator: "\n") + "\n").utf8)
    let helper = Data((#"{"type":"assistant","uuid":"s1","timestamp":"\#(stamp(250))","requestId":"rs","message":{"id":"ms","model":"claude-haiku-5-5","content":[{"type":"text","text":"Found it"}],"usage":{"input_tokens":7,"output_tokens":3}}}"# + "\n").utf8)

    let reading = SessionLogReading()
    func same(_ what: String) {
        let full = SessionHistoryReader.read(agent: .claude, path: log.path)
        let read = SessionHistoryReader.read(agent: .claude, path: log.path, reading: reading)
        guard case .success(let a) = full, case .success(let b) = read else {
            check(false, what + ": both read")
            return
        }
        check(a == b, what + " (\(b.turns.count) prompts)")
    }
    // Grown in pieces, some cut mid-line; the sub-agent's log comes along halfway.
    var written = 0
    for cut in [whole.count / 5, whole.count / 3, whole.count / 2, whole.count * 3 / 4, whole.count - 3, whole.count] {
        if written == 0 {
            manager.createFile(atPath: log.path, contents: whole.subdata(in: 0..<cut))
        } else {
            let handle = try? FileHandle(forWritingTo: log)
            handle?.seekToEndOfFile()
            handle?.write(whole.subdata(in: written..<cut))
            try? handle?.close()
        }
        written = cut
        if cut >= whole.count / 2, !manager.fileExists(atPath: subagent.path) {
            manager.createFile(atPath: subagent.path, contents: helper.subdata(in: 0..<helper.count / 2))
        } else if cut == whole.count {
            try? helper.write(to: subagent)
        }
        same("the same history with \(cut) of \(whole.count) bytes written")
    }
    if case .success(let history) = SessionHistoryReader.read(agent: .claude, path: log.path, reading: reading) {
        check(history.turns.count == 6 && history.title == "Six questions", "all six prompts and the title")
        check(history.sessionTokens.total == (10...15).reduce(0, +) + (5...10).reduce(0, +) + 10, "with the sub-agent's tokens")
    }
    // Replaced by another file; rewritten in place, as long as before.
    try? manager.removeItem(at: log)
    manager.createFile(atPath: log.path, contents: whole.subdata(in: 0..<whole.count / 2))
    same("a log replaced by another file is read from its start")
    _ = SessionHistoryReader.read(agent: .claude, path: log.path, reading: reading)
    func rewrite(_ from: String, _ to: String) {
        let handle = try? FileHandle(forWritingTo: log)
        try? handle?.write(contentsOf: Data(String(decoding: whole, as: UTF8.self).replacingOccurrences(of: from, with: to).utf8))
        try? handle?.close()
    }
    rewrite("Question 0", "Question Z")
    same("a log rewritten in place from its start is read from its start")
    rewrite("Question 1", "Question X")
    reading.forget()
    same("told to forget it (Refresh), it reads a log changed anywhere whole again")

    print("Timestamps read the quick way")
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    let dayFormatter = DateFormatter()
    dayFormatter.locale = Locale(identifier: "en_US_POSIX")
    dayFormatter.timeZone = TimeZone(identifier: "UTC")
    dayFormatter.dateFormat = "yyyy-MM-dd"
    /// As timestamps were read before: the formatter, with the fraction added; else a bare day.
    func slow(_ text: String) -> Date? {
        var text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        var fraction = 0.0
        if let tee = text.firstIndex(of: "T"), let dot = text[tee...].firstIndex(of: ".") {
            var end = text.index(after: dot)
            while end < text.endIndex, text[end].isASCII, text[end].isNumber {
                end = text.index(after: end)
            }
            fraction = Double("0" + String(text[dot..<end])) ?? 0
            text.removeSubrange(dot..<end)
        }
        if let date = formatter.date(from: text) {
            return date.addingTimeInterval(fraction)
        }
        return text.count == 10 ? dayFormatter.date(from: text) : nil
    }
    var generator = SystemRandomNumberGenerator()
    var differ = 0
    var samples: [String] = [
        "2024-02-29T23:59:59.999999Z", "2023-02-28T00:00:00Z", "2000-02-29T12:00:00+14:00", "1999-12-31T23:59:59-12:00",
        "2026-10-28T09:41:05.1+05:30", "2026-10-28T09:41:05.000000001Z", "1970-01-01T00:00:00Z", "2100-12-31T23:59:59.5Z",
        "2023-02-29T10:00:00Z", "2026-13-01T10:00:00Z", "2026-10-28T24:00:00Z", "2026-10-28T09:41:05z", "2026-10-28T09:41:05",
        "2026-10-28 09:41:05Z", " 2026-10-28T09:41:05Z ", "2026-10-28T09:41:05.Z", "2026-10-28T09:41:05+0530", "2026-10-28",
    ]
    for _ in 0..<3000 {
        let seconds = Double.random(in: 0..<4_200_000_000, using: &generator).rounded(.down)
        let offset = [0, 3600, -3600, 19800, -34200, 50400][Int.random(in: 0..<6, using: &generator)]
        let digits = Int.random(in: 0...9, using: &generator)
        var text = ISO8601DateFormatter.string(
            from: Date(timeIntervalSince1970: seconds), timeZone: TimeZone(secondsFromGMT: offset)!, formatOptions: [.withInternetDateTime])
        if digits > 0, let tee = text.firstIndex(of: "T") {
            let insert = text.index(tee, offsetBy: 9)
            text.insert(contentsOf: "." + String((0..<digits).map { _ in "0123456789".randomElement(using: &generator)! }), at: insert)
        }
        samples.append(text)
    }
    for text in samples where Dates.parse(text) != slow(text) {
        differ += 1
        if differ <= 3 {
            print("        \(text): \(String(describing: Dates.parse(text))) vs \(String(describing: slow(text)))")
        }
    }
    check(differ == 0, "the same dates as the formatter for \(samples.count) timestamps (\(differ) differ)")
}

/// `AgentBuddyChecks --reading-parity LOG...`: each Claude Code log, copied and
/// grown in uneven pieces with its sub-agents' logs, read on from where it was
/// after each piece and compared with reading it whole. Nothing of them is shown.
func readingParity(_ paths: [String]) -> Int32 {
    let manager = FileManager.default
    var failures = 0
    for path in paths {
        let source = URL(fileURLWithPath: path)
        let session = source.deletingPathExtension().lastPathComponent
        guard let whole = try? Data(contentsOf: source) else { continue }
        let scratch = manager.temporaryDirectory.appendingPathComponent("ab-parity-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: scratch) }
        let log = scratch.appendingPathComponent(source.lastPathComponent)
        let sources = SessionHistoryReaderPaths.subagentFiles(beside: source, session: session)
        let copies = sources.map { scratch.appendingPathComponent(session).appendingPathComponent("subagents").appendingPathComponent($0.lastPathComponent) }
        let helpers = sources.map { (try? Data(contentsOf: $0)) ?? Data() }
        try? manager.createDirectory(at: scratch.appendingPathComponent(session).appendingPathComponent("subagents"), withIntermediateDirectories: true)
        let reading = SessionLogReading()
        let stepsReading = StepsReading()
        var stepsDiffer = 0
        var generator = SystemRandomNumberGenerator()
        var cuts = (0..<11).map { _ in Int.random(in: 0...whole.count, using: &generator) } + [whole.count]
        cuts.sort()
        var differ = 0
        var reads = 0
        var spent = (incremental: 0.0, whole: 0.0)
        for (step, cut) in cuts.enumerated() {
            try? whole.subdata(in: 0..<cut).write(to: log)
            for (index, copy) in copies.enumerated() {
                let helper = helpers[index]
                try? helper.subdata(in: 0..<(step == cuts.count - 1 ? helper.count : helper.count * step / cuts.count)).write(to: copy)
            }
            var started = Date()
            let read = SessionHistoryReader.read(agent: .claude, path: log.path, reading: reading)
            spent.incremental += Date().timeIntervalSince(started)
            started = Date()
            let full = SessionHistoryReader.read(agent: .claude, path: log.path)
            spent.whole += Date().timeIntervalSince(started)
            reads += 1
            // The latest turns' steps (the one at work, as a window keeps it up), read on and read whole.
            if case .success(let history) = full {
                for turn in history.turns.sorted(by: { $0.askedAt < $1.askedAt }).suffix(2) {
                    let on = SessionHistoryReader.steps(agent: .claude, path: log.path, turn: turn, cwd: history.cwd, reading: stepsReading)
                    let whole = SessionHistoryReader.steps(agent: .claude, path: log.path, turn: turn, cwd: history.cwd)
                    if on != whole {
                        stepsDiffer += 1
                    }
                }
            }
            if case .success(let a) = read, case .success(let b) = full, a == b {
                continue
            }
            differ += 1
        }
        failures += differ + stepsDiffer
        print(String(format: "%@ %@: %d reads, %d differ, steps %d differ; reading on %.2f s, whole %.2f s",
                     differ + stepsDiffer == 0 ? "same" : "DIFFERENT", String(session.prefix(8)), reads, differ, stepsDiffer,
                     spent.incremental, spent.whole))
    }
    return failures == 0 ? 0 : 1
}

/// Where a session's sub-agents' logs are, for the parity mode.
enum SessionHistoryReaderPaths {
    static func subagentFiles(beside log: URL, session: String) -> [URL] {
        let folder = log.deletingLastPathComponent().appendingPathComponent(session).appendingPathComponent("subagents")
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "jsonl" }
    }
}
