import AgentBuddyCore
import AppKit
import SwiftUI

/// What @ and / offer in the message box, as Zed's does: the session folder's
/// files after @, the agent's commands after a / that starts the message (and
/// Codex's skills after $). ↑ and ↓ choose, Return or Tab puts it in, Esc closes.
@MainActor
final class ComposerSuggestions: ObservableObject {
    struct Item: Identifiable, Equatable {
        /// What goes in the box in place of what's typed.
        let insert: String
        let title: String
        let detail: String
        let symbol: String
        var id: String { insert }
    }

    enum Kind {
        case file
        case command
    }

    /// Shown: what for, where in the text it's typed, the choices, and the one chosen.
    @Published private(set) var kind: Kind?
    @Published private(set) var items: [Item] = []
    @Published var selected = 0
    private var range = NSRange(location: 0, length: 0)
    /// Where an Esc closed it: not offered again for that word.
    private var dismissedAt: Int?
    private var monitor: Any?
    private weak var window: NSWindow?
    weak var details: SessionDetails?

    var isShown: Bool { kind != nil }

    /// The message box's editor while it has the keyboard.
    private var editor: NSTextView? {
        guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.isFieldEditor else { return nil }
        return editor
    }

    /// The word being typed at the caret: @…, a / that starts the message, or $… for Codex.
    func update() {
        guard let details else { return hide() }
        let composing = details.composing
        let text = composing.text as NSString
        let caret = min(editor?.selectedRange().location ?? text.length, text.length)
        let before = text.substring(to: caret) as NSString
        let space = before.rangeOfCharacter(from: .whitespacesAndNewlines, options: .backwards)
        let start = space.location == NSNotFound ? 0 : space.location + space.length
        let word = before.substring(from: start)
        guard start != dismissedAt else { return }
        dismissedAt = nil
        let query = String(word.dropFirst())
        if word.hasPrefix("@") {
            guard let files = composing.projectFiles else {
                details.loadSuggestions()
                return show(.file, start, caret, [])
            }
            show(.file, start, caret, ProjectFiles.matches(query, in: files).map { path in
                let folder = path.hasSuffix("/")
                let name = (folder ? String(path.dropLast()) : path).split(separator: "/").last.map(String.init) ?? path
                let parent = (path as NSString).deletingLastPathComponent
                return Item(insert: ProjectFiles.mention(path) + " ", title: name + (folder ? "/" : ""),
                            detail: parent == "." ? "" : parent, symbol: folder ? "folder" : "doc.text")
            })
        } else if (word.hasPrefix("/") && start == 0) || (word.hasPrefix("$") && details.agent == .codex) {
            guard let commands = composing.commands else {
                details.loadSuggestions()
                return show(.command, start, caret, [])
            }
            let sign = String(word.prefix(1))
            show(.command, start, caret, AgentCommands.matches(query, in: commands.filter { $0.sign == sign }).map { command in
                let symbol: String
                switch command.kind {
                case .builtIn: symbol = "command"
                case .command: symbol = "text.alignleft"
                case .skill: symbol = "sparkles"
                case .prompt: symbol = "text.quote"
                }
                return Item(insert: command.typed + " ", title: command.typed, detail: command.description, symbol: symbol)
            })
        } else {
            hide()
        }
    }

    private func show(_ kind: Kind, _ start: Int, _ caret: Int, _ items: [Item]) {
        if self.kind != kind || self.items != items {
            selected = 0
        }
        self.kind = kind
        self.items = items
        range = NSRange(location: start, length: caret - start)
        watchKeys()
    }

    func hide() {
        kind = nil
        items = []
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }

    /// Puts the choice in the box in place of what's typed, the caret after it.
    func choose(_ item: Item) {
        guard let composing = details?.composing else { return }
        let text = composing.text as NSString
        guard NSMaxRange(range) <= text.length else { return hide() }
        composing.text = text.replacingCharacters(in: range, with: item.insert)
        let caret = range.location + (item.insert as NSString).length
        hide()
        DispatchQueue.main.async { [weak self] in
            self?.editor?.setSelectedRange(NSRange(location: caret, length: 0))
        }
    }

    /// ↑, ↓, Return, Tab and Esc, in this window's box, while the list shows.
    private func watchKeys() {
        guard monitor == nil else { return }
        window = NSApp.keyWindow
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let (key, number) = (event.keyCode, event.windowNumber)
            let handled = MainActor.assumeIsolated { self?.handle(key, inWindow: number) ?? false }
            return handled ? nil : event
        }
    }

    private func handle(_ key: UInt16, inWindow number: Int) -> Bool {
        guard isShown, number == window?.windowNumber, editor != nil else { return false }
        switch key {
        case 125 where !items.isEmpty:
            selected = min(selected + 1, items.count - 1)
        case 126 where !items.isEmpty:
            selected = max(selected - 1, 0)
        case 36, 76, 48:
            guard items.indices.contains(selected) else { return false }
            choose(items[selected])
        case 53:
            dismissedAt = range.location
            hide()
        default:
            return false
        }
        return true
    }
}

/// The choices while they show, over the foot of the history (it alone watches them, so typing doesn't redraw the history).
struct SuggestionOverlay: View {
    @ObservedObject var suggestions: ComposerSuggestions

    var body: some View {
        if suggestions.isShown {
            SuggestionList(suggestions: suggestions)
                .padding(.horizontal, 14)
                .padding(.bottom, 6)
        }
    }
}

/// The choices above the message box: eight rows, scrolling for more, the chosen one kept in view.
struct SuggestionList: View {
    @ObservedObject var suggestions: ComposerSuggestions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if suggestions.items.isEmpty {
                Text(suggestions.kind == .file ? "No files here match" : "No commands match")
                    .uiFont(11)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(Array(suggestions.items.enumerated()), id: \.element.id) { index, item in
                                row(item, chosen: index == suggestions.selected)
                                    .id(index)
                                    .onTapGesture { suggestions.choose(item) }
                                    .onHover { inside in
                                        if inside {
                                            suggestions.selected = index
                                        }
                                    }
                            }
                        }
                    }
                    .frame(height: min(CGFloat(suggestions.items.count), 8) * 24)
                    .onChange(of: suggestions.selected) { index in
                        proxy.scrollTo(index)
                    }
                }
            }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.secondary.opacity(0.3)))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
    }

    private func row(_ item: ComposerSuggestions.Item, chosen: Bool) -> some View {
        HStack(spacing: 7) {
            Image(systemName: item.symbol)
                .frame(width: 14)
                .foregroundStyle(chosen ? Color.white : Color.secondary)
            Text(item.title)
                .lineLimit(1)
                .layoutPriority(1)
            Text(item.detail)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(chosen ? Color.white.opacity(0.8) : Color.secondary)
            Spacer(minLength: 0)
        }
        .uiFont(11.5)
        .foregroundStyle(chosen ? Color.white : Color.primary)
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 5).fill(chosen ? Color.accentColor : Color.clear))
        .contentShape(Rectangle())
    }
}
