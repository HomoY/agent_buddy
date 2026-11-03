import AppKit
import AgentBuddyCore
import AgentBuddyMarkdown
import SwiftUI

/// Answers drawn as text, not by WebKit: for pictures of windows (the snapshot
/// mode), which can't capture a web view.
struct PlainAnswersKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var plainAnswers: Bool {
        get { self[PlainAnswersKey.self] }
        set { self[PlainAnswersKey.self] = newValue }
    }
}

/// Under a window's history: a box to send its agent a prompt. The agent's own
/// command resumes the session, here or on the server, with no window; the
/// answer shows above as it comes.
struct PromptComposer: View {
    @SwiftUI.Environment(\.windowRoom) private var room
    @ObservedObject var details: SessionDetails
    /// What's typed, watched here alone.
    @ObservedObject private var composing: MessageDraft
    /// What @ and / offer as you type.
    @ObservedObject private var suggestions: ComposerSuggestions
    /// What you've selected in Zed or another app.
    @ObservedObject private var selections = SelectionWatcher.shared
    /// The session kept open here, if it is: whether it takes a prompt now.
    @ObservedObject private var keeper = SessionKeeper.shared
    @FocusState private var focused: Bool
    @AppStorage(TextStyle.sizeKey) private var textSize = TextStyle.standardSize
    @AppStorage(TextStyle.fontKey) private var font: MarkdownFont = .system

    init(details: SessionDetails) {
        self.details = details
        _composing = ObservedObject(wrappedValue: details.composing)
        _suggestions = ObservedObject(wrappedValue: details.composing.suggestions)
    }

    var body: some View {
        switch details.sendPlan {
        case .failure(let problem)?:
            Label(problem.message, systemImage: "paperplane")
                .uiFont(10.5)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .success(let plan)?:
            VStack(alignment: .leading, spacing: 6) {
                if let selection = selections.selection {
                    selected(selection)
                }
                if !details.queued.isEmpty {
                    QueuedPrompts(details: details)
                }
                box
                notes(plan)
                if !room.short {
                    selectionLinks
                }
            }
        case nil:
            EmptyView()
        }
    }

    /// Sends what's typed, with the selection made elsewhere, if there is one.
    private func send() {
        let selection = selections.selection
        details.send(context: selection?.block, attached: selection?.summary) {
            if selection != nil {
                selections.dismiss()
            }
        }
    }

    /// "Selected in Zed · main.rs, lines 10–12": it goes with the next prompt.
    private func selected(_ selection: SelectionWatcher.Selection) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "text.cursor")
                .uiFont(11, weight: .semibold)
                .foregroundStyle(Color.accentColor)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                (Text("\(selection.kind == .copied ? "Copied" : "Selected") in \(selection.app)").fontWeight(.semibold)
                    + Text(selection.place.isEmpty ? "" : " \u{00B7} \(selection.place)"))
                    .uiFont(11)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\u{201C}\(Self.firstLine(selection.text))\u{201D}")
                    .uiFont(11, design: .monospaced)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 4)
            Button {
                selections.dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .uiFont(12)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Don't send this selection")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.09)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor.opacity(0.25)))
        .help("It goes with your next prompt, as an editor's selection does:\n\n" + String(selection.text.prefix(600)))
    }

    /// The selection's first line with words, for the bar.
    static func firstLine(_ text: String) -> String {
        let line = text.split(separator: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).count
        return line.trimmingCharacters(in: .whitespaces) + (lines > 1 ? " \u{2026}" : "")
    }

    private var box: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !composing.files.isEmpty {
                AttachedFiles(composing: composing)
            }
            TextField("Message \(details.agent.clientName)\u{2026}", text: $composing.text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: textSize, design: TextStyle.design(font)))
                .lineLimit(1...(room.short ? 3 : 8))
                .focused($focused)
                .onSubmit { send() }
                // Opened from a reminder: type the reply straight away.
                .onAppear {
                    focused = true
                    suggestions.details = details
                }
                .onChange(of: composing.text) { _ in suggestions.update() }
                .onDisappear { suggestions.hide() }
            HStack(spacing: 4) {
                // First to the room: the space beside it gives way before its names do.
                ComposerControls(details: details, composing: composing)
                    .layoutPriority(1)
                Spacer(minLength: 4)
                Button(action: dictate) {
                    Image(systemName: "mic")
                        .uiFont(13)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Dictate into the box (as pressing fn twice does)")
                if details.inFlight != nil {
                    Button("Stop") { details.stopSending() }
                        .controlSize(.small)
                        .help("Stop \(details.agent.clientName) working on it" + (details.queued.isEmpty ? "" : "; what's queued comes back to the box"))
                } else if details.starting {
                    ProgressView().controlSize(.small).frame(width: 22, height: 22)
                }
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .uiFont(20)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(details.canSend ? Color.accentColor : Color.secondary.opacity(0.45))
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!details.canSend)
                .help(details.joinsTurn ? "Add it to the answer under way (Return), as typing while Codex works does."
                      : details.willQueue ? "Queue it (Return): it's sent as soon as the answer under way is done."
                      : "Send it (Return). Option-Return starts a new line.")
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 5)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(focused ? Color.accentColor.opacity(0.7) : Color.secondary.opacity(0.3)))
        .onDrop(of: [.fileURL], isTargeted: nil) { Attachments.drop($0, into: composing) }
    }

    /// macOS's own dictation, into the box: what you say is typed there.
    private func dictate() {
        focused = true
        DispatchQueue.main.async {
            NSApp.sendAction(Selector(("startDictation:")), to: nil, from: nil)
        }
    }

    /// How it goes, or how it would.
    @ViewBuilder
    private func notes(_ plan: PromptSender.Plan) -> some View {
        let client = details.agent.clientName
        if let since = details.inFlight {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 12, height: 12)
                note("\(client) is working on it, since \(Format.clock(since, now: details.now)). " + (room.short ? "" : "Its answer shows above as it comes. ")
                     + (details.joinsTurn ? "What you send now joins it." : "What you send now waits its turn."))
            }
        } else if details.starting {
            note("Sending\u{2026}")
        } else if let holder = details.heldElsewhere {
            Label("\(holder) has this thread open\(details.host.map { " on \($0)" } ?? ""), and Codex lets one program at a time write to a thread. "
                  + "\(SessionKeeper.howToFree(holder)) Then Send works here again (or Open here takes it). Or Jump there and type it in \(holder).",
                  systemImage: "lock")
                .uiFont(10.5)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        } else if case .notSent(let why)? = details.sent {
            warning("Not sent: \(why)")
        } else if case .failed(let why)? = details.sent {
            warning("It stopped: \(why)")
        } else if details.isWorking() {
            Label("\(client) is working on this session now. What you send waits until it's done.", systemImage: "hourglass")
                .uiFont(10.5)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if room.short {
            // Little room: how it went, not how sending works.
            if case .finished(let at)? = details.sent {
                Label("Done at \(Format.clock(at, now: details.now)).", systemImage: "checkmark.circle.fill")
                    .uiFont(10.5)
                    .foregroundStyle(.green)
            }
        } else {
            VStack(alignment: .leading, spacing: 3) {
                if case .finished(let at)? = details.sent {
                    Label("Done at \(Format.clock(at, now: details.now)). Its answer is above.", systemImage: "checkmark.circle.fill")
                        .uiFont(10.5)
                        .foregroundStyle(.green)
                }
                if SessionKeeper.shared.isKept(details.key) {
                    note("Goes into the session kept open here, in the background, \(plan.permissions); \(plan.asks).")
                } else {
                    note("Sends it to \(client) \(details.host.map { "on \($0)" } ?? "on this Mac") \(plan.permissions), as if you resumed the session; \(plan.asks).")
                }
                if let narrowed = plan.narrowed {
                    note(narrowed)
                }
                if case .found(let place)? = details.place {
                    note("If \(place.appName) still has this chat open, it won't show this exchange, and what you type there next carries on without it.")
                }
            }
        }
    }

    /// What it takes to see what you select in other apps: shown whatever the session's doing.
    @ViewBuilder
    private var selectionLinks: some View {
        if selections.isEnabled, selections.trusted, selections.selection == nil, let editor = selections.closedEditor {
            Button("\(editor) keeps what you select to itself, except in its screen reader mode. Switch that on\u{2026}") {
                selections.offerEditors(editor)
            }
            .buttonStyle(.link)
            .uiFont(10.5)
            .help("Agent Buddy asks first, and switches it off again when you close the agent windows.")
        }
        if selections.isEnabled, !selections.trusted, selections.selection == nil {
            if selections.lostAccess {
                // Listed as allowed, but for an earlier build of it.
                Button("Selections in apps other than Zed are off: macOS no longer counts Agent Buddy as allowed. Allow it again\u{2026}") {
                    selections.askForAccess()
                }
                .buttonStyle(.link)
                .uiFont(10.5)
                .foregroundStyle(.orange)
            } else {
                Button("What you select in Zed shows here. For other apps too, allow Accessibility\u{2026}") {
                    selections.askForAccess()
                }
                .buttonStyle(.link)
                .uiFont(10.5)
                .help("Agent Buddy clears an entry left from an earlier build, and macOS asks again: switch Agent Buddy on under Privacy & Security \u{203A} Accessibility.")
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .uiFont(10.5)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func warning(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .uiFont(10.5)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}

/// The agent's answer, formatted from its Markdown, formulas and code boxes
/// too: whole, or its start with a link to the rest.
struct AnswerView: View {
    let text: String
    let whole: Bool
    let showWhole: () -> Void
    @SwiftUI.Environment(\.plainAnswers) private var plain
    @AppStorage(TextStyle.sizeKey) private var textSize = TextStyle.standardSize
    @AppStorage(TextStyle.fontKey) private var font: MarkdownFont = .system

    static let preview = 700

    var body: some View {
        let start = whole ? nil : Self.start(of: text)
        VStack(alignment: .leading, spacing: 6) {
            if MarkdownView.available && !plain {
                MarkdownView(start ?? text, fontSize: textSize, font: font)
            } else {
                Text(MarkdownText.attributed(start ?? text))
                    .font(.system(size: textSize - 0.5, design: TextStyle.design(font)))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if start != nil {
                Button("Show the whole answer (\(Self.words(text)) words)", action: showWhole)
                    .buttonStyle(.link)
                    .uiFont(11)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }

    /// The start of a long answer, cut at a line or a word; nil for a short one.
    static func start(of text: String) -> String? {
        guard text.count > preview + 200 else { return nil }
        let head = text.prefix(preview)
        let cut = head.lastIndex(of: "\n") ?? head.lastIndex(of: " ") ?? head.endIndex
        return String(head[..<cut]).trimmingCharacters(in: .whitespacesAndNewlines) + " \u{2026}"
    }

    static func words(_ text: String) -> String {
        let count = text.split(whereSeparator: { $0.isWhitespace }).count
        return count.formatted()
    }
}

/// A turn's answer, and once they're read its steps, on one page: the answer
/// shown first gives way to the steps in place, not on a page made again.
struct TurnPage: View {
    let steps: SessionDetails.TurnSteps?
    let answer: String
    let whole: Bool
    let showWhole: () -> Void
    /// Words searched for, marked on the page; a new `reveal`, scrolled to.
    var searched = ""
    var reveal = 0
    @SwiftUI.Environment(\.plainAnswers) private var plain
    @AppStorage(TextStyle.sizeKey) private var textSize = TextStyle.standardSize
    @AppStorage(TextStyle.fontKey) private var font: MarkdownFont = .system

    var body: some View {
        if MarkdownView.available && !plain {
            let start = steps == nil && !whole ? AnswerView.start(of: answer) : nil
            VStack(alignment: .leading, spacing: 6) {
                MarkdownView(stepsJSON: steps?.json, orMarkdown: start ?? answer, fontSize: textSize, font: font,
                             estimate: steps.map { StepsView.estimate($0.steps, fontSize: textSize) })
                    .searching(searched, reveal: reveal)
                if start != nil {
                    Button("Show the whole answer (\(AnswerView.words(answer)) words)", action: showWhole)
                        .buttonStyle(.link)
                        .uiFont(11)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
        } else if let steps {
            StepsView(steps: steps)
        } else {
            AnswerView(text: answer, whole: whole, showWhole: showWhole)
        }
    }
}

/// What the agent did in a turn, step by step, after a ● each, as its terminal
/// shows it: what it wrote, the tools it ran and what came of them, the files it
/// changed and how. Long outputs and changes fold away until opened.
struct StepsView: View {
    let steps: SessionDetails.TurnSteps
    @SwiftUI.Environment(\.plainAnswers) private var plain
    @AppStorage(TextStyle.sizeKey) private var textSize = TextStyle.standardSize
    @AppStorage(TextStyle.fontKey) private var font: MarkdownFont = .system

    var body: some View {
        Group {
            if MarkdownView.available && !plain {
                MarkdownView(stepsJSON: steps.json, fontSize: textSize, font: font, estimate: Self.estimate(steps.steps, fontSize: textSize))
            } else {
                // Without WebKit (the snapshot pictures): the same lines, nothing to open.
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(Self.rows(steps.steps).enumerated()), id: \.offset) { _, row in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("\u{25CF}")
                                .foregroundStyle(row.failed ? Color.red : row.said ? Color.primary : Color.green)
                            VStack(alignment: .leading, spacing: 2) {
                                if row.said {
                                    Text(MarkdownText.attributed(row.text))
                                } else {
                                    Text(row.text).fontWeight(.semibold).lineLimit(2)
                                    if let outcome = row.outcome {
                                        Text("\u{23BF}  \(outcome)")
                                            .font(.system(size: textSize - 1.5, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                            }
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if let changes = Self.changes(steps.steps) {
                        Text(changes)
                            .fontWeight(.semibold)
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .font(.system(size: textSize - 0.5, design: TextStyle.design(font)))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }

}

extension StepsView {
    struct Row {
        var text: String
        var outcome: String?
        var said = false
        var failed = false
    }

    /// As the page shows them: a run of actions that went well folds into one line.
    static func rows(_ steps: [TurnStep]) -> [Row] {
        var rows: [Row] = []
        var run: [TurnStep] = []
        func flush() {
            if run.count == 1 {
                rows.append(Row(text: run[0].text, outcome: run[0].outcome))
            } else if run.count > 1 {
                rows.append(Row(text: summary(run)))
            }
            run = []
        }
        for step in steps {
            if step.kind == .ran && !step.failed {
                run.append(step)
                continue
            }
            flush()
            rows.append(Row(text: step.text, outcome: step.outcome, said: step.kind == .said, failed: step.failed))
        }
        flush()
        return rows
    }

    /// "Read 2 files, ran 3 commands", worded as the page words it.
    static func summary(_ run: [TurnStep]) -> String {
        let wordings: [(names: Set<String>, say: (Int) -> String)] = [
            (["Bash", "Shell"], { "ran \($0) command\($0 == 1 ? "" : "s")" }),
            (["Read"], { "read \($0) file\($0 == 1 ? "" : "s")" }),
            (["Search"], { "searched for \($0) pattern\($0 == 1 ? "" : "s")" }),
            (["Web Search"], { "searched the web\($0 == 1 ? "" : " \($0) times")" }),
            (["Fetch"], { "fetched \($0) page\($0 == 1 ? "" : "s")" }),
            (["Task", "Agent"], { "ran \($0) agent\($0 == 1 ? "" : "s")" }),
            (["View Image"], { "viewed \($0) image\($0 == 1 ? "" : "s")" }),
        ]
        var counts: [(index: Int, count: Int)] = []
        for step in run {
            let name = step.text.firstIndex(of: "(").map { String(step.text[..<$0]) } ?? step.text
            let index = wordings.firstIndex { $0.names.contains(name) } ?? wordings.count
            if let at = counts.firstIndex(where: { $0.index == index }) {
                counts[at].count += 1
            } else {
                counts.append((index, 1))
            }
        }
        let text = counts.map { index, count in
            index < wordings.count ? wordings[index].say(count) : "used \(count) tool\(count == 1 ? "" : "s")"
        }.joined(separator: ", ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    /// About how tall the page will draw them: the rows folded as it folds them,
    /// what was said by its length.
    static func estimate(_ steps: [TurnStep], fontSize: CGFloat) -> CGFloat {
        let rows = rows(steps)
        let said = rows.filter(\.said).reduce(0) { $0 + $1.text.count / 80 + 1 }
        let actions = rows.filter { !$0.said }.reduce(0) { $0 + ($1.outcome == nil ? 1 : 2) }
        let changes = steps.contains { !$0.hunks.isEmpty } ? 2 : 0
        return CGFloat(said + actions + changes) * fontSize * 1.6
    }

    /// "View changes · 2 files, +40 −12", for a turn that changed any.
    static func changes(_ steps: [TurnStep]) -> String? {
        let changed = steps.filter { !$0.hunks.isEmpty }
        guard !changed.isEmpty else { return nil }
        let files = Set(changed.map(\.text)).count
        let added = changed.reduce(0) { $0 + $1.changes.added }
        let removed = changed.reduce(0) { $0 + $1.changes.removed }
        return "View changes \u{00B7} \(files) file\(files == 1 ? "" : "s"), +\(added) \u{2212}\(removed)"
    }
}

/// An agent's Markdown as one attributed string: headings bold, code in
/// monospace, lists with bullets, inline styles and links kept. One string, so
/// it selects and copies as one text.
@MainActor
enum MarkdownText {
    private static var made: [String: AttributedString] = [:]

    static func attributed(_ markdown: String) -> AttributedString {
        if let done = made[markdown] {
            return done
        }
        let result = make(markdown)
        if made.count > 80 {
            made.removeAll()
        }
        made[markdown] = result
        return result
    }

    static func make(_ markdown: String) -> AttributedString {
        var result = AttributedString()
        var inCode = false
        var first = true
        for raw in markdown.components(separatedBy: "\n") {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inCode.toggle()
                continue
            }
            var line: AttributedString
            if inCode {
                line = AttributedString(raw.isEmpty ? " " : raw)
                line.font = Font.system(size: 11, design: .monospaced)
                line.backgroundColor = Color.secondary.opacity(0.12)
            } else if let (level, title) = heading(trimmed) {
                line = inline(title)
                line.font = Font.system(size: level <= 2 ? 13.5 : 12.5, weight: .semibold)
            } else if let item = bullet(raw) {
                line = AttributedString(item.indent + "\u{2022}  ") + inline(item.text)
            } else if trimmed.hasPrefix("|") {
                line = AttributedString(raw)
                line.font = Font.system(size: 11, design: .monospaced)
            } else if trimmed == ">" || trimmed.hasPrefix("> ") {
                line = inline("\u{258D} " + trimmed.dropFirst(trimmed == ">" ? 1 : 2))
                line.foregroundColor = Color.secondary
            } else if ["---", "***", "___"].contains(trimmed) {
                line = AttributedString("\u{2014}\u{2014}\u{2014}")
                line.foregroundColor = Color.secondary
            } else {
                line = inline(raw)
            }
            if !first {
                result.append(AttributedString("\n"))
            }
            result.append(line)
            first = false
        }
        return result
    }

    /// `**bold**`, `*italic*`, `` `code` `` and links, the spaces as written.
    static func inline<S: StringProtocol>(_ text: S) -> AttributedString {
        let string = String(text)
        return (try? AttributedString(markdown: string, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(string)
    }

    static func heading(_ line: String) -> (Int, String)? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return (hashes, String(line.dropFirst(hashes + 1)))
    }

    static func bullet(_ raw: String) -> (indent: String, text: String)? {
        let spaces = raw.prefix { $0 == " " || $0 == "\t" }.count
        let rest = raw.dropFirst(spaces)
        guard ["- ", "* ", "+ "].contains(String(rest.prefix(2))) else { return nil }
        return (String(repeating: "    ", count: spaces / 2), String(rest.dropFirst(2)))
    }
}

/// Prompts sent while one was under way, in the order they'll go: each can be
/// taken back (its words return to the box).
struct QueuedPrompts: View {
    @ObservedObject var details: SessionDetails
    @SwiftUI.Environment(\.windowRoom) private var room

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            // Little room: the next one, and how many after it.
            let shown = room.short ? Array(details.queued.prefix(1)) : details.queued
            if room.short, details.queued.count > 1 {
                Text("\(details.queued.count) queued")
                    .uiFont(10, weight: .medium)
                    .foregroundStyle(.secondary)
                    .help(details.queued.map(\.typed).joined(separator: "\n\n"))
            }
            ForEach(shown) { waiting in
                HStack(spacing: 6) {
                    Image(systemName: waiting.joining ? "arrow.turn.down.right" : "clock")
                        .uiFont(10)
                        .foregroundStyle(.secondary)
                    Text(waiting.joining ? "Adding to the answer\u{2026}" : "Queued")
                        .uiFont(10.5, weight: .medium)
                        .foregroundStyle(.secondary)
                    Text(PromptComposer.firstLine(waiting.typed))
                        .uiFont(11)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    if !waiting.joining {
                        Button {
                            details.unqueue(waiting.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill").uiFont(11)
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Take it back: it won't be sent, and its words return to the box")
                    }
                }
                .help(waiting.typed)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }
}
