import Foundation
import AgentBuddyCore

enum Format {
    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    private static let weekdayTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEEjmm")
        return formatter
    }()

    private static let monthDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter
    }()

    private static let monthDayTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMdjmm")
        return formatter
    }()

    /// "Oct 24, 9:41 PM".
    static func dayAndTime(_ date: Date) -> String {
        monthDayTime.string(from: date)
    }

    /// "2h 05m", "5d 11h", "12m".
    static func countdown(to date: Date, from now: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(now)))
        let days = seconds / 86400
        let hours = seconds % 86400 / 3600
        let minutes = seconds % 3600 / 60
        if days > 0 {
            return "\(days)d \(hours)h"
        }
        if hours > 0 {
            return "\(hours)h \(String(format: "%02d", minutes))m"
        }
        return "\(max(minutes, 1))m"
    }

    /// "4:19 PM", "tomorrow 4:19 PM", "Fri 7:59 AM" or "Nov 1".
    static func clock(_ date: Date, now: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) {
            return time.string(from: date)
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return "tomorrow \(time.string(from: date))"
        }
        if date.timeIntervalSince(now) < 6 * 86400 {
            return weekdayTime.string(from: date)
        }
        return monthDay.string(from: date)
    }

    static func resetLine(_ window: UsageWindow, now: Date) -> String {
        var parts: [String] = []
        if let resetsAt = window.resetsAt {
            if resetsAt <= now {
                parts.append("Reset · refreshing soon")
            } else {
                parts.append("Resets in \(countdown(to: resetsAt, from: now)) · \(clock(resetsAt, now: now))")
            }
        } else if window.kind == .session {
            parts.append("No session running")
        }
        if let detail = window.detail {
            parts.append(detail)
        }
        return parts.joined(separator: " · ")
    }

    /// "45s", "3m 12s", "1h 05m".
    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 {
            return "\(max(total, 1))s"
        }
        if total < 3600 {
            return "\(total / 60)m \(String(format: "%02d", total % 60))s"
        }
        return "\(total / 3600)h \(String(format: "%02d", total % 3600 / 60))m"
    }

    /// "just now", "5m ago", "2h ago", "Oct 24".
    static func ago(_ date: Date, now: Date) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 {
            return "just now"
        }
        if seconds < 3600 {
            return "\(Int(seconds / 60))m ago"
        }
        if seconds < 86400 {
            return "\(Int(seconds / 3600))h ago"
        }
        return monthDay.string(from: date)
    }

    /// How a limit is named in a reminder: "Claude session", "ChatGPT weekly limit".
    static func limitName(_ agent: Agent, _ window: UsageWindow) -> String {
        switch window.id {
        case "claude.session": return "Claude session"
        case "claude.weekly": return "Claude weekly limit"
        default: break
        }
        if window.kind == .weeklyModel, let family = window.title.components(separatedBy: "· ").last {
            return "Claude \(family) weekly limit"
        }
        if window.id.hasPrefix("codex.codex.") {
            return "ChatGPT \(window.title.lowercased())"
        }
        if agent == .copilot {
            return "Copilot \(window.title.lowercased())"
        }
        return "\(agent.displayName) \(window.title)"
    }
}
