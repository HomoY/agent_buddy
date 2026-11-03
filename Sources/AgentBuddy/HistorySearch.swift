import AgentBuddyCore
import AgentBuddyMarkdown
import AppKit
import SwiftUI

/// Searching an agent window's prompts and answers (⌘F): the prompts whose
/// words, selections sent with them, or answer have it, in the window's order,
/// and the one shown now.
@MainActor
final class HistorySearch: ObservableObject {
    @Published var shown = false
    /// What's searched for, once typing pauses (empty: nothing).
    @Published private(set) var query = ""
    /// The prompts with it, in their words or their answer, top to bottom.
    @Published private(set) var matches: [String] = []
    /// Which of them is shown now.
    @Published private(set) var current = 0
    /// Each move to a match: the window scrolls there.
    @Published private(set) var moves = 0
    /// Asks the search field to take the keyboard.
    @Published private(set) var focusing = 0

    var currentID: String? {
        matches.indices.contains(current) ? matches[current] : nil
    }

    func open() {
        shown = true
        focusing += 1
    }

    func close() {
        shown = false
        query = ""
        matches = []
        current = 0
    }

    /// Looks for `text` in `rows`, starting at the newest prompt that has it.
    func search(_ text: String, in rows: [HistoryRow]) {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard words != query else { return }
        query = words
        matches = Self.find(words, in: rows)
        current = max(0, matches.count - 1)
        if !matches.isEmpty {
            moves += 1
        }
    }

    /// The history read again: found again, staying on the same prompt while it's there.
    func refresh(_ rows: [HistoryRow]) {
        guard !query.isEmpty else { return }
        let was = currentID
        matches = Self.find(query, in: rows)
        current = was.flatMap { matches.firstIndex(of: $0) } ?? max(0, matches.count - 1)
    }

    func next() {
        move(by: 1)
    }

    func previous() {
        move(by: -1)
    }

    private func move(by step: Int) {
        guard !matches.isEmpty else { return }
        current = (current + step + matches.count) % matches.count
        moves += 1
    }

    /// Whatever the case and accents.
    static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    static func find(_ words: String, in rows: [HistoryRow]) -> [String] {
        guard !words.isEmpty else { return [] }
        return rows.filter { row in
            row.turn.text.range(of: words, options: options) != nil || row.turn.answer?.range(of: words, options: options) != nil
                || row.turn.selections.contains { $0.text.range(of: words, options: options) != nil }
        }.map(\.id)
    }

    static let mark = Color(red: 1, green: 0.77, blue: 0).opacity(0.5)

    /// `text`, with `words` marked wherever they are.
    static func marked(_ text: String, _ words: String) -> AttributedString {
        var marked = AttributedString(text)
        guard !words.isEmpty else { return marked }
        var rest = marked.startIndex..<marked.endIndex
        while let found = marked[rest].range(of: words, options: options) {
            marked[found].backgroundColor = mark
            rest = found.upperBound..<marked.endIndex
        }
        return marked
    }
}

/// The bar above a window's history while it's searched: the words, how many
/// prompts have them, and the way from one to the next.
struct HistorySearchBar: View {
    @ObservedObject var search: HistorySearch
    /// The window's prompts, as listed now.
    let rows: () -> [HistoryRow]
    @State private var text: String
    @FocusState private var focused: Bool

    init(search: HistorySearch, rows: @escaping () -> [HistoryRow]) {
        self.search = search
        self.rows = rows
        _text = State(initialValue: search.query)
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .uiFont(11)
                .foregroundStyle(.secondary)
            TextField("Search the prompts and answers", text: $text)
                .textFieldStyle(.plain)
                .uiFont(12)
                .focused($focused)
                .onSubmit { search.next() }
                .onExitCommand { search.close() }
            if !search.query.isEmpty {
                Text(search.matches.isEmpty ? "Not found" : "\(search.current + 1) of \(search.matches.count)")
                    .uiFont(10.5, digits: true)
                    .foregroundStyle(search.matches.isEmpty ? Color.orange : Color.secondary)
            }
            Button {
                search.previous()
            } label: {
                Image(systemName: "chevron.up").uiFont(10.5, weight: .semibold)
            }
            .disabled(search.matches.isEmpty)
            .help("The one before (⇧⌘G)")
            Button {
                search.next()
            } label: {
                Image(systemName: "chevron.down").uiFont(10.5, weight: .semibold)
            }
            .disabled(search.matches.isEmpty)
            .help("The next one (⌘G, or Return)")
            Button("Done") { search.close() }
                .uiFont(11)
                .help("Stop searching (Esc)")
        }
        .buttonStyle(.borderless)
        .onChange(of: text) { typed in
            // Searched once typing pauses.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 180_000_000)
                if typed == text {
                    search.search(typed, in: rows())
                }
            }
        }
        .onChange(of: search.focusing) { _ in focused = true }
        .onAppear { focused = true }
    }
}

/// ⌘F, ⌘G and ⇧⌘G from the app's hidden menu, for the agent window in front.
@MainActor
final class SearchCommands: NSObject {
    static let shared = SearchCommands()
    /// An agent window's search, if the window is one.
    var searchOf: (NSWindow) -> HistorySearch? = { _ in nil }

    private var front: HistorySearch? {
        NSApp.keyWindow.flatMap(searchOf)
    }

    @objc func find(_ sender: Any?) {
        front?.open()
    }

    @objc func findNext(_ sender: Any?) {
        guard let search = front else { return }
        search.shown ? search.next() : search.open()
    }

    @objc func findPrevious(_ sender: Any?) {
        guard let search = front else { return }
        search.shown ? search.previous() : search.open()
    }
}

/// What was selected and sent with a prompt (from Zed, VS Code, another app,
/// or copied): where from, and, the prompt open, its text, as a quote.
struct PromptSelectionsView: View {
    let selections: [PromptSelection]
    /// The prompt open: the text too; folded, where each came from.
    let open: Bool
    var searched = ""
    /// Long ones shown whole, by hand.
    @State private var whole: Set<Int> = []
    @AppStorage(TextStyle.sizeKey) private var textSize = TextStyle.standardSize
    @AppStorage(TextStyle.fontKey) private var font: MarkdownFont = .system

    /// Folded, a selection shows this many lines; its header, or Show all, opens the rest.
    static let foldedLines = 3

    var body: some View {
        if open {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(selections.enumerated()), id: \.offset) { index, selection in
                    quote(selection, index)
                }
            }
            .padding(.top, 2)
        } else {
            HStack(spacing: 8) {
                ForEach(Array(selections.prefix(2).enumerated()), id: \.offset) { _, selection in
                    Label(selection.source, systemImage: "text.quote")
                        .uiFont(10)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if selections.count > 2 {
                    Text("+\(selections.count - 2)")
                        .uiFont(10)
                        .foregroundStyle(.secondary)
                }
            }
            .help("Sent with your selection; click for it")
        }
    }

    private func quote(_ selection: PromptSelection, _ index: Int) -> some View {
        let lines = selection.text.split(separator: "\n", omittingEmptySubsequences: false).count
        let long = lines > Self.foldedLines
        let open = whole.contains(index)
        // From a file's lines: code, kept monospaced.
        let code = selection.source.contains(", lines ")
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Label("With your selection: \(selection.source)", systemImage: "text.quote")
                if long {
                    Text("\u{00B7} \(lines) lines")
                    Image(systemName: open ? "chevron.up" : "chevron.down")
                        .uiFont(8.5, weight: .semibold)
                }
            }
            .uiFont(10.5, weight: .medium)
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
            .onTapGesture { if long { toggle(index) } }
            .help(long ? (open ? "Click to fold it" : "Click for all of it") : "")
            Text(searched.isEmpty ? AttributedString(selection.text) : HistorySearch.marked(selection.text, searched))
                .font(code ? .system(size: textSize - 1.5, design: .monospaced) : .system(size: textSize - 1, design: TextStyle.design(font)))
                .foregroundStyle(.secondary)
                .lineLimit(long && !open ? Self.foldedLines : nil)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 9)
                .overlay(alignment: .leading) {
                    Rectangle().fill(Color.secondary.opacity(0.35)).frame(width: 2)
                }
            if long {
                Button(open ? "Fold" : "Show all \(lines) lines") { toggle(index) }
                    .buttonStyle(.link)
                    .uiFont(10.5)
            }
        }
    }

    private func toggle(_ index: Int) {
        if whole.contains(index) {
            whole.remove(index)
        } else {
            whole.insert(index)
        }
    }
}
