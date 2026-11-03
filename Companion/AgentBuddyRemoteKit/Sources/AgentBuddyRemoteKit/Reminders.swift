import Foundation

/// The tags on Agent Buddy's reminders. ntfy on iPhone and Apple Watch shows only
/// emoji tags (as an emoji before the title), so the others, which let Agent Buddy
/// Remote fold a window's reminders together, stay out of sight.
public enum ReminderTag {
    /// On every "job finished" reminder.
    public static let job = "hs-job"

    /// "hsw-" and a hash of the agent window: the same on all of its reminders.
    public static func window(_ key: String) -> String {
        // FNV-1a: stable across launches and devices, unlike Hasher.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return "hsw-" + String(String(hash, radix: 16).suffix(12))
    }

    public static func agent(_ agent: String) -> String { "hsa-\(agent)" }

    public static func count(_ count: Int) -> String { "hsn-\(count)" }

    /// The emoji before the title: ✅ finished, ❌ stopped with an error, ⌛ hit a limit.
    public static func emoji(outcome: String) -> String {
        switch outcome {
        case "failed": return "x"
        case "limited": return "hourglass"
        default: return "white_check_mark"
        }
    }

    public static func outcome(emoji: String) -> String? {
        switch emoji {
        case "white_check_mark": return "completed"
        case "x": return "failed"
        case "hourglass": return "limited"
        default: return nil
        }
    }

    /// All the tags of a window's reminder.
    public static func forWindow(key: String, agent: String, count: Int, outcome: String) -> [String] {
        [emoji(outcome: outcome), job, window(key), self.agent(agent), self.count(count)]
    }
}

/// How a reminder reads, on the Mac and on the phone alike.
public enum PushComposer {
    /// "Claude Code job finished", "Claude Code · 3 jobs finished".
    public static func headline(client: String, count: Int, outcome: String) -> String {
        switch outcome {
        case "failed": return "\(client) job stopped with an error"
        case "limited": return "\(client) hit a usage limit"
        default: return count > 1 ? "\(client) · \(count) jobs finished" : "\(client) job finished"
        }
    }

    /// The text under the title, with the privacy choices applied.
    /// - Parameters:
    ///   - identifying: the job's name, its folder and server; only with `includeTitles`.
    ///   - details: what's safe anywhere ("took 48s", "Resets in 2h").
    ///   - summary: the agent's last words; only with `includeSummaries`.
    public static func message(
        identifying: [String], details: [String], summary: String?, includeTitles: Bool, includeSummaries: Bool
    ) -> String {
        var lines: [String] = []
        if includeTitles {
            let named = identifying.filter { !$0.isEmpty }
            if !named.isEmpty {
                lines.append(named.joined(separator: " · "))
            }
        }
        let rest = details.filter { !$0.isEmpty }.joined(separator: " · ")
        if !rest.isEmpty {
            lines.append(rest)
        }
        if includeSummaries, let summary, !summary.isEmpty {
            lines.append(summary)
        }
        return lines.isEmpty ? "Open Agent Buddy on your Mac for details." : lines.joined(separator: "\n")
    }
}

extension RemoteSnapshot.FinishedWindow {
    /// The window a "job finished" reminder speaks for; nil for other reminders.
    public init?(message: NtfyMessage) {
        guard message.tags.contains(ReminderTag.job),
              let window = message.tags.first(where: { $0.hasPrefix("hsw-") })
        else { return nil }
        func value(_ prefix: String) -> String? {
            message.tags.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
        }
        self.init(
            id: window,
            agent: value("hsa-") ?? "claude",
            headline: message.title ?? "Job finished",
            detail: message.message,
            count: value("hsn-").flatMap(Int.init) ?? 1,
            outcome: message.tags.lazy.compactMap(ReminderTag.outcome(emoji:)).first ?? "completed",
            finishedAt: message.time)
    }
}

/// The finished jobs Agent Buddy Remote shows: the Mac's list as of its last
/// status, and the windows whose reminders came after it.
public enum WindowFeed {
    /// - Parameter hidden: windows swiped away on the phone, with the time of
    ///   their latest job then; a newer job brings a window back.
    public static func merge(
        snapshot: RemoteSnapshot?, reminders: [NtfyMessage], hidden: [String: Date] = [:]
    ) -> [RemoteSnapshot.FinishedWindow] {
        var byID: [String: RemoteSnapshot.FinishedWindow] = [:]
        for window in snapshot?.windows ?? [] {
            byID[window.id] = window
        }
        // ntfy stamps whole seconds; a reminder in the status's own second counts too.
        let after = snapshot.map { $0.at.addingTimeInterval(-2) } ?? .distantPast
        for message in reminders where message.time > after {
            guard let window = RemoteSnapshot.FinishedWindow(message: message) else { continue }
            if let known = byID[window.id], known.finishedAt > window.finishedAt {
                continue
            }
            byID[window.id] = window
        }
        return byID.values
            .filter { window in hidden[window.id].map { window.finishedAt > $0 } ?? true }
            .sorted { ($0.finishedAt, $0.id) > ($1.finishedAt, $1.id) }
    }
}
