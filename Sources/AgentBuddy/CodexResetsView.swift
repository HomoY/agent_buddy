import AgentBuddyCore
import SwiftUI

/// Under Codex's own limits, only while OpenAI has announced its next reset of
/// everyone's limits: when, and what was said. The data is codex-reset.com's,
/// credited where it shows, as the site asks.
struct CodexResetsView: View {
    let announced: CodexResetForecast.Announcement
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(Self.next(announced, now: now), systemImage: "arrow.counterclockwise.circle.fill")
                .foregroundStyle(.orange)
            Text("\u{201C}\(announced.summary)\u{201D}")
                .foregroundStyle(.secondary)
                .padding(.leading, 19)
            HStack(spacing: 3) {
                Text("Data:")
                    .foregroundStyle(.secondary)
                Link("codex-reset.com", destination: CodexResetSource.site)
            }
            .padding(.leading, 19)
        }
        .uiFont(10.5)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, 2)
        .help(announced.url?.absoluteString ?? "")
    }

    /// "Next reset for everyone: 4:01 PM, in 1h 35m", or as the site words it.
    static func next(_ announcement: CodexResetForecast.Announcement, now: Date) -> String {
        var line = "Next reset for everyone"
        if let target = announcement.target, target > now {
            line += ": \(Format.clock(target, now: now)), in \(Format.countdown(to: target, from: now))"
        } else if let end = announcement.end, end > now {
            line += announcement.window.map { ": \($0), by \(Format.clock(end, now: now))" } ?? ": by \(Format.clock(end, now: now))"
        } else if let window = announcement.window {
            line += ": \(window)"
        } else {
            line += " is announced"
        }
        return line
    }
}
