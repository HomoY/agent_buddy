import AppKit
import AgentBuddyCore
import SwiftUI

/// Every agent window Agent Buddy has seen finish a job, by day, kept when the
/// finished-jobs list is cleared. Click one for its prompts.
struct HistoryPage: View {
    @EnvironmentObject private var model: AppModel
    private static let rowHeight: CGFloat = 38
    /// A day's title is a row too, as tall as the others.
    private static let headerHeight: CGFloat = 40
    private static let maxHeight: CGFloat = 470

    var body: some View {
        let days = model.archive.byDay(now: model.now)
        VStack(alignment: .leading, spacing: 8) {
            Text("Each agent window with finished jobs stays here when you clear the list, for 90 days. Click one to see the prompts asked there.")
                .uiFont(10.5)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if days.isEmpty {
                Text("None yet: a window appears when one of its jobs finishes.")
                    .uiFont(12)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                // Day titles as plain rows: a list's own section headers stick
                // to the top with a bar behind them.
                List {
                    ForEach(days, id: \.day) { day in
                        Text(Self.title(of: day.day, now: model.now))
                            .uiFont(11, weight: .semibold)
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                        ForEach(day.entries) { entry in
                            row(entry)
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .environment(\.defaultMinListRowHeight, Self.rowHeight)
                .frame(height: min(
                    CGFloat(days.count) * Self.headerHeight + CGFloat(model.archive.entries.count) * (Self.rowHeight + 4) + 8,
                    Self.maxHeight))
            }
        }
        .padding(12)
    }

    private func row(_ entry: SessionArchive.Entry) -> some View {
        ArchiveRow(entry: entry, now: model.now, open: { model.showWindow(entry.key) }, jump: { model.jumpToWindow(entry.key) })
            .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button(role: .destructive) {
                    model.forgetWindow(entry.key)
                } label: {
                    Label("Remove", systemImage: "trash")
                }
            }
            .contextMenu {
                Button("Show the Prompts") { model.showWindow(entry.key) }
                Button("Jump to Where It Runs") { model.jumpToWindow(entry.key) }
                Divider()
                Button("Remove from This List") { model.forgetWindow(entry.key) }
            }
    }

    /// "Today", "Yesterday", "Monday", "Oct 12".
    static func title(of day: Date, now: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDate(day, inSameDayAs: now) {
            return "Today"
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(day, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate(now.timeIntervalSince(day) < 6 * 86400 ? "EEEE" : "MMMd")
        return formatter.string(from: day)
    }
}

/// One kept agent window: its name, where it ran, how many jobs finished, and when the last did.
struct ArchiveRow: View {
    let entry: SessionArchive.Entry
    let now: Date
    let open: () -> Void
    let jump: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            AgentMark(agent: entry.agent, size: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title ?? entry.project ?? entry.agent.clientName)
                    .uiFont(12)
                    .lineLimit(1)
                Text(facts)
                    .uiFont(10)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if hovering {
                Button(action: jump) {
                    Image(systemName: "arrow.up.forward.app")
                        .uiFont(12)
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .help("Jump to where it runs")
            }
            Text(Format.ago(entry.lastFinished, now: now))
                .uiFont(10, digits: true)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover { hovering = $0 }
        .help("Click to see the prompts asked in this window")
    }

    private var facts: String {
        var parts = [entry.agent.clientName]
        if entry.title != nil, let project = entry.project {
            parts.append(project)
        }
        if let source = entry.source {
            parts.append("on \(source)")
        }
        parts.append(entry.jobs.count == 1 ? "1 job" : "\(entry.jobs.count) jobs")
        return parts.joined(separator: " · ")
    }
}
