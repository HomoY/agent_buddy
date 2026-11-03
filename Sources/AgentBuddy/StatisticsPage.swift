import AppKit
import Combine
import AgentBuddyCore
import SwiftUI

extension Agent {
    /// The agents the statistics show: those with plan limits always, the others
    /// once they've used tokens in the period.
    static func shown(in bars: [StatsBar]) -> [Agent] {
        allCases.filter { agent in agent.hasLimits || bars.contains { ($0.byAgent[agent] ?? 0) > 0 } }
    }

    /// Its name as a table's column.
    var columnName: String {
        self == .codex ? "Codex" : displayName
    }

    /// The agent's colour in charts and legends: one step per appearance, checked
    /// for colour-vision separation as a set, in `Agent.allCases`'s order (light:
    /// #e58e6f #0a7f62 #7350d4 #e34948 #2a78d6 #eda100 #e87ba4 #008300; dark:
    /// #e0704a #007153 #906ff8 #e66767 #3987e5 #c98500 #d55181 #008300). Text never
    /// wears it; it marks bars and swatches, with each agent's number beside it.
    var chartColor: Color {
        let (light, dark): (UInt32, UInt32)
        switch self {
        case .claude: (light, dark) = (0xe58e6f, 0xe0704a)
        case .codex: (light, dark) = (0x0a7f62, 0x007153)
        case .copilot: (light, dark) = (0x7350d4, 0x906ff8)
        case .deepseek: (light, dark) = (0xe34948, 0xe66767)
        case .gemini: (light, dark) = (0x2a78d6, 0x3987e5)
        case .opencode: (light, dark) = (0xeda100, 0xc98500)
        case .qwen: (light, dark) = (0xe87ba4, 0xd55181)
        case .cursor: (light, dark) = (0x008300, 0x008300)
        }
        func color(_ hex: UInt32) -> NSColor {
            NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255, alpha: 1)
        }
        return Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua, .vibrantLight, .vibrantDark]).map {
                $0 == .darkAqua || $0 == .vibrantDark
            } ?? false
            return color(isDark ? dark : light)
        })
    }
}

/// Token use today, over 7 days or over 30 days, from the session logs on this Mac.
struct StatisticsPage: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @State private var period: StatsPeriod
    @State private var hovered: Int?
    @State private var asTable: Bool
    /// Totals, or each job with its tokens.
    @State private var byJob: Bool
    /// Jobs shown open at first (the snapshot mode).
    private let openJobs: Set<String>
    private let ticker = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    /// Starts on today's chart; snapshots can start elsewhere.
    init(period: StatsPeriod = .day, hovered: Int? = nil, asTable: Bool = false, byJob: Bool = false, openJobs: Set<String> = []) {
        _period = State(initialValue: period)
        _hovered = State(initialValue: hovered)
        _asTable = State(initialValue: asTable)
        _byJob = State(initialValue: byJob)
        self.openJobs = openJobs
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Show", selection: $byJob) {
                Text("Totals").tag(false)
                Text("By job").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Picker("Period", selection: $period) {
                Text("Today").tag(StatsPeriod.day)
                Text("7 days").tag(StatsPeriod.week)
                Text("30 days").tag(StatsPeriod.month)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: period) { _ in hovered = nil }

            if byJob {
                JobsTokenList(store: model.jobUsage, period: period, expanded: openJobs)
            } else if let entries = model.tokenEntries {
                let summary = TokenStatistics.summary(entries, period: period, now: model.now)
                VStack(alignment: .leading, spacing: 12) {
                    headline(summary)
                    agents(summary)
                    if !settings.remoteHosts.isEmpty {
                        places(summary)
                    }
                    Divider()
                    overTime(summary)
                    Divider()
                    kinds(summary)
                    models(summary)
                    Text(settings.remoteHosts.isEmpty
                        ? "Counted from the session logs on this Mac. Add servers in Settings to count your remote terminals too. Cache reads are the agents re-reading earlier context. Copilot counts a session when it ends."
                        : "Counted from the session logs on this Mac and your servers. Cache reads are the agents re-reading earlier context. Copilot counts a session when it ends.")
                        .uiFont(10)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // A recount keeps the last numbers on screen, a little faded.
                .opacity(model.countingTokens ? 0.6 : 1)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Counting tokens in your session logs…")
                        .uiFont(12)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 120)
            }
        }
        .padding(12)
        .onAppear { model.refreshTokens() }
        .onReceive(ticker) { _ in
            if byJob {
                model.jobUsage.refresh(archive: model.archive)
            } else {
                model.refreshTokens()
            }
        }
    }

    // MARK: - Parts

    private func headline(_ summary: StatsSummary) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(periodTitle).uiFont(11).foregroundStyle(.secondary)
            Text(TokenStatistics.compact(summary.total.total))
                .uiFont(30, weight: .semibold)
            Text(periodNote(summary)).uiFont(11).foregroundStyle(.secondary)
        }
    }

    private var periodTitle: String {
        switch period {
        case .day: return "Tokens today"
        case .week: return "Tokens in the last 7 days"
        case .month: return "Tokens in the last 30 days"
        }
    }

    private func periodNote(_ summary: StatsSummary) -> String {
        if period == .day {
            return "Since midnight"
        }
        return "About \(TokenStatistics.compact(summary.total.total / max(summary.days, 1))) a day"
    }

    /// The legend, with each agent's tokens and share.
    private func agents(_ summary: StatsSummary) -> some View {
        VStack(spacing: 5) {
            ForEach(Agent.shown(in: summary.bars)) { agent in
                let tokens = summary.byAgent[agent]?.total ?? 0
                HStack(spacing: 7) {
                    RoundedRectangle(cornerRadius: 2).fill(agent.chartColor).frame(width: 10, height: 10)
                    Text(agent.clientName).uiFont(12)
                    Spacer()
                    Text(TokenStatistics.compact(tokens)).uiFont(12, weight: .semibold, digits: true)
                    Text(share(tokens, of: summary.total.total))
                        .uiFont(11, digits: true)
                        .foregroundStyle(.secondary)
                        .uiWidth(36, alignment: .trailing)
                }
            }
        }
    }

    /// Where the tokens were used: this Mac, then each server, with how its last count went.
    private func places(_ summary: StatsSummary) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Where").uiFont(11, weight: .semibold).foregroundStyle(.secondary)
            place("laptopcomputer", "This Mac", tokens: summary.bySource[""]?.total ?? 0, of: summary.total.total, note: nil)
            ForEach(settings.remoteHosts, id: \.self) { host in
                place("server.rack", host, tokens: summary.bySource[host]?.total ?? 0, of: summary.total.total, note: model.remoteStatus[host])
            }
        }
    }

    private func place(_ symbol: String, _ name: String, tokens: Int, of total: Int, note: RemoteStatus?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                    .uiFont(10)
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                Text(name).uiFont(12).lineLimit(1)
                if note?.counting == true {
                    ProgressView().controlSize(.small).scaleEffect(0.55).frame(width: 12, height: 12)
                }
                Spacer()
                Text(TokenStatistics.compact(tokens)).uiFont(12, weight: .semibold, digits: true)
                Text(share(tokens, of: total))
                    .uiFont(11, digits: true)
                    .foregroundStyle(.secondary)
                    .uiWidth(36, alignment: .trailing)
            }
            if let note, let error = note.error {
                Label(note.updated.map { "\(error). Showing its counts from \(Format.ago($0, now: model.now))." } ?? error,
                      systemImage: "exclamationmark.triangle.fill")
                    .uiFont(10)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 21)
            } else if let updated = note?.updated {
                Text("Counted \(Format.ago(updated, now: model.now))")
                    .uiFont(10)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 21)
            }
        }
    }

    private func share(_ part: Int, of whole: Int) -> String {
        guard whole > 0 else { return "–" }
        let percent = Double(part) / Double(whole) * 100
        return percent > 0 && percent < 1 ? "<1%" : "\(Int(percent.rounded()))%"
    }

    private func overTime(_ summary: StatsSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                readout(summary)
                Spacer()
                Button(asTable ? "Chart" : "Table") { asTable.toggle() }
                    .buttonStyle(.borderless)
                    .uiFont(11)
                    .help(asTable ? "Show the chart" : "Show the numbers as a table")
            }
            if asTable {
                StatsTable(bars: summary.bars, period: period)
            } else {
                StackedBarChart(bars: summary.bars, period: period, hovered: $hovered)
            }
        }
    }

    /// What the hovered column holds: the value first, then what it is.
    @ViewBuilder
    private func readout(_ summary: StatsSummary) -> some View {
        if !asTable, let index = hovered, summary.bars.indices.contains(index) {
            let bar = summary.bars[index]
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(TokenStatistics.compact(bar.total)).uiFont(12, weight: .semibold, digits: true)
                    Text(StatsFormat.slot(bar.start, period: period)).uiFont(11).foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    ForEach(Agent.allCases) { agent in
                        if let value = bar.byAgent[agent], value > 0 {
                            HStack(spacing: 3) {
                                Capsule().fill(agent.chartColor).frame(width: 8, height: 2)
                                Text(TokenStatistics.compact(value)).uiFont(10, digits: true)
                            }
                        }
                    }
                }
            }
            .frame(height: 30, alignment: .topLeading)
        } else {
            VStack(alignment: .leading, spacing: 3) {
                Text(period == .day ? "By hour" : "By day").uiFont(12, weight: .semibold)
                Text(asTable ? "Every \(period == .day ? "hour" : "day") of the period" : "Hover a column for its numbers")
                    .uiFont(10)
                    .foregroundStyle(.secondary)
            }
            .frame(height: 30, alignment: .topLeading)
        }
    }

    private func kinds(_ summary: StatsSummary) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
            GridRow {
                kind("Input", summary.total.input)
                kind("Output", summary.total.output)
            }
            GridRow {
                kind("Cache write", summary.total.cacheWrite)
                kind("Cache read", summary.total.cacheRead)
            }
        }
    }

    private func kind(_ name: String, _ value: Int) -> some View {
        HStack(spacing: 4) {
            Text(name).uiFont(11).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(TokenStatistics.compact(value)).uiFont(11, weight: .medium, digits: true)
        }
        .uiWidth(150)
    }

    @ViewBuilder
    private func models(_ summary: StatsSummary) -> some View {
        if !summary.models.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Models").uiFont(11, weight: .semibold).foregroundStyle(.secondary)
                ForEach(summary.models.prefix(5)) { usage in
                    HStack(spacing: 7) {
                        RoundedRectangle(cornerRadius: 2).fill(usage.agent.chartColor).frame(width: 8, height: 8)
                        Text(usage.model).uiFont(11).lineLimit(1)
                        Spacer()
                        Text(TokenStatistics.compact(usage.counts.total)).uiFont(11, digits: true)
                    }
                }
            }
        }
    }
}

enum StatsFormat {
    private static let hour: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("j")
        return formatter
    }()

    private static let weekday: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEE")
        return formatter
    }()

    private static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter
    }()

    private static let dayAndWeekday: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEEMMMd")
        return formatter
    }()

    /// What one column covers: "3 PM–4 PM" or "Tue, Oct 21".
    static func slot(_ start: Date, period: StatsPeriod) -> String {
        if period == .day {
            let end = start.addingTimeInterval(3600)
            return "\(hour.string(from: start))–\(hour.string(from: end))"
        }
        return dayAndWeekday.string(from: start)
    }

    /// The x-axis labels: a few hours, every weekday, or a day a week.
    static func axisLabels(_ bars: [StatsBar], period: StatsPeriod) -> [(index: Int, text: String)] {
        switch period {
        case .day:
            return stride(from: 0, to: bars.count, by: 6).map { ($0, hour.string(from: bars[$0].start)) }
        case .week:
            return bars.indices.map { ($0, weekday.string(from: bars[$0].start)) }
        case .month:
            return stride(from: bars.count - 1, through: 0, by: -7).reversed().map { ($0, day.string(from: bars[$0].start)) }
        }
    }
}

/// Stacked columns in the agents' fixed order (Claude Code at the base): thin
/// bars with air between them, rounded only at the top, a 2-point gap between
/// segments, and hairline gridlines.
struct StackedBarChart: View {
    let bars: [StatsBar]
    let period: StatsPeriod
    @Binding var hovered: Int?
    private let plotHeight: CGFloat = 110
    private let axisWidth: CGFloat = 30

    var body: some View {
        let top = Self.niceCeiling(bars.map(\.total).max() ?? 0)
        VStack(spacing: 4) {
            HStack(alignment: .top, spacing: 4) {
                ZStack(alignment: .topTrailing) {
                    ForEach([0, 1, 2], id: \.self) { step in
                        Text(TokenStatistics.compact(top * (2 - step) / 2))
                            .uiFont(9, digits: true)
                            .foregroundStyle(.secondary)
                            .offset(y: CGFloat(step) * plotHeight / 2 - 6)
                    }
                }
                .frame(width: axisWidth, height: plotHeight, alignment: .topTrailing)
                GeometryReader { geometry in
                    let slot = geometry.size.width / CGFloat(max(bars.count, 1))
                    let width = min(24, max(2, slot * 0.7))
                    ZStack(alignment: .bottomLeading) {
                        ForEach([0, 1, 2], id: \.self) { step in
                            Rectangle()
                                .fill(Color.primary.opacity(0.1))
                                .frame(height: 1)
                                .offset(y: -CGFloat(step) * (plotHeight - 1) / 2)
                        }
                        HStack(alignment: .bottom, spacing: 0) {
                            ForEach(Array(bars.enumerated()), id: \.offset) { index, bar in
                                column(bar, top: top, width: width)
                                    .opacity(hovered == nil || hovered == index ? 1 : 0.45)
                                    .frame(width: slot, height: plotHeight, alignment: .bottom)
                                    .contentShape(Rectangle())
                                    .onHover { inside in
                                        if inside {
                                            hovered = index
                                        } else if hovered == index {
                                            hovered = nil
                                        }
                                    }
                            }
                        }
                    }
                }
                .frame(height: plotHeight)
            }
            GeometryReader { geometry in
                let slot = geometry.size.width / CGFloat(max(bars.count, 1))
                ForEach(StatsFormat.axisLabels(bars, period: period), id: \.index) { label in
                    Text(label.text)
                        .uiFont(9)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .position(x: (CGFloat(label.index) + 0.5) * slot, y: 6)
                }
            }
            .frame(height: 12)
            .padding(.leading, axisWidth + 4)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Tokens \(period == .day ? "by hour" : "by day"); use Table for the numbers")
    }

    /// One column: its agents' segments stacked bottom up, 2-point gaps between.
    private func column(_ bar: StatsBar, top: Int, width: CGFloat) -> some View {
        let parts = Agent.allCases.compactMap { agent -> (Agent, Int)? in
            guard let value = bar.byAgent[agent], value > 0 else { return nil }
            return (agent, value)
        }
        let gap: CGFloat = 2
        let height = top > 0 ? CGFloat(bar.total) / CGFloat(top) * plotHeight : 0
        let available = max(height - gap * CGFloat(max(parts.count - 1, 0)), 0)
        return VStack(spacing: gap) {
            ForEach(Array(parts.reversed().enumerated()), id: \.offset) { position, part in
                let segment = max(available * CGFloat(part.1) / CGFloat(max(bar.total, 1)), 1)
                TopRounded(radius: position == 0 ? 4 : 0)
                    .fill(part.0.chartColor)
                    .frame(width: width, height: segment)
            }
        }
    }

    /// The axis top: 1, 2 or 5 times a power of ten, at or above the largest column.
    static func niceCeiling(_ value: Int) -> Int {
        guard value > 0 else { return 1 }
        let power = pow(10, floor(log10(Double(value))))
        for step in [1.0, 2.0, 5.0, 10.0] where step * power >= Double(value) {
            return Int(step * power)
        }
        return Int(10 * power)
    }
}

/// A rectangle rounded at the top only, square where it meets the baseline.
struct TopRounded: Shape {
    var radius: CGFloat

    func path(in rect: CGRect) -> Path {
        let r = min(radius, rect.width / 2, rect.height)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY), tangent2End: CGPoint(x: rect.minX + r, y: rect.minY), radius: r)
        path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.minY + r), radius: r)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// The chart's numbers as rows: every hour or day, with each agent's share.
struct StatsTable: View {
    let bars: [StatsBar]
    let period: StatsPeriod

    var body: some View {
        VStack(spacing: 0) {
            let agents = Agent.shown(in: bars)
            row(period == .day ? "Hour" : "Day", ["Total"] + agents.map(\.columnName), header: true)
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(bars.reversed()) { bar in
                        row(StatsFormat.slot(bar.start, period: period),
                            [TokenStatistics.compact(bar.total)] + agents.map { TokenStatistics.compact(bar.byAgent[$0] ?? 0) },
                            header: false)
                            .frame(height: Self.rowHeight)
                    }
                }
            }
            // Every row of a week; today's hours and a month scroll past eight.
            .frame(height: min(CGFloat(bars.count), 8) * Self.rowHeight)
        }
    }

    private static let rowHeight: CGFloat = 18

    private func row(_ label: String, _ values: [String], header: Bool) -> some View {
        HStack(spacing: 4) {
            Text(label).frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
            ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                Text(value)
                    .lineLimit(1)
                    .frame(width: index == 0 ? 44 : 50, alignment: .trailing)
            }
        }
        .uiFont(header ? 9 : 10, weight: header ? .semibold : .regular, digits: !header)
        .foregroundStyle(header ? .secondary : .primary)
        .padding(.vertical, 2)
    }
}
