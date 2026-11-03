import AppKit

/// Agent Buddy shows no menu bar of its own, but macOS sends ⌘A, ⌘C, ⌘V, ⌘X
/// and ⌘Z to text through the app's main menu: with none, the message box and
/// selectable text ignore them. This menu is never shown; it carries those
/// keys, and ⌘F, ⌘G and ⇧⌘G (search), ⌘W, ⌘M, ⌘⇧] and ⌘⇧[ (tabs), and ⌘+,
/// ⌘− and ⌘0 (text size) for the agent windows.
@MainActor
enum MainMenu {
    static func install() {
        let menu = NSMenu()
        menu.addItem(submenu(NSMenu(title: "Agent Buddy")))

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z").keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        // Searching the agent window in front: its prompts and answers.
        edit.addItem(.separator())
        for (title, key, shift, action) in [("Find\u{2026}", "f", false, #selector(SearchCommands.find(_:))),
                                            ("Find Next", "g", false, #selector(SearchCommands.findNext(_:))),
                                            ("Find Previous", "g", true, #selector(SearchCommands.findPrevious(_:)))] {
            let item = edit.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = shift ? [.command, .shift] : [.command]
            item.target = SearchCommands.shared
        }
        menu.addItem(submenu(edit))

        // The agent windows' text size; ⌘= is ⌘+ without Shift.
        let view = NSMenu(title: "View")
        for (title, key, action) in [("Bigger Text", "+", #selector(TextStyleCommands.bigger(_:))),
                                     ("Bigger Text", "=", #selector(TextStyleCommands.bigger(_:))),
                                     ("Smaller Text", "-", #selector(TextStyleCommands.smaller(_:))),
                                     ("Actual Size", "0", #selector(TextStyleCommands.reset(_:)))] {
            view.addItem(withTitle: title, action: action, keyEquivalent: key).target = TextStyleCommands.shared
        }
        menu.addItem(submenu(view))

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        // Agent windows merged into tabs: the next and the previous.
        window.addItem(withTitle: "Show Next Tab", action: #selector(NSWindow.selectNextTab(_:)), keyEquivalent: "]")
            .keyEquivalentModifierMask = [.command, .shift]
        window.addItem(withTitle: "Show Previous Tab", action: #selector(NSWindow.selectPreviousTab(_:)), keyEquivalent: "[")
            .keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(submenu(window))
        NSApp.mainMenu = menu
    }

    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}
