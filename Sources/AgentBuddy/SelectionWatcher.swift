import AppKit
import AgentBuddyCore
import AgentBuddyMarkdown
import ApplicationServices
import Combine

/// What you've selected in another app, for the agent windows' message box:
/// Zed's from its database (no permission needed), any other app's through
/// Accessibility, once you allow it. It's watched only while an agent window is
/// open, kept only in memory, and goes only with a prompt you send.
@MainActor
final class SelectionWatcher: ObservableObject {
    struct Selection: Equatable {
        enum Kind: Equatable {
            /// From Zed's database: shown while it's selected there.
            case zed
            /// Read through Accessibility: shown while it's selected there.
            case accessibility
            /// Copied (⌘C) in an app that doesn't tell Accessibility what's
            /// selected (VS Code, Chrome): kept until sent, dismissed or replaced.
            case copied
            /// In an agent window's answer or steps: shown while it's selected there.
            case window
        }

        var kind: Kind = .accessibility
        /// "Zed", "Xcode", "Safari".
        var app: String
        /// The file, on this Mac or on `host`.
        var file: String?
        var host: String?
        var lines: ClosedRange<Int>?
        /// The window's title, when there's no file.
        var title: String?
        var text: String
        /// Changes when the selection does.
        var id: String

        /// "main.rs, lines 10–12", else the window's title ("Release notes").
        var place: String {
            if let file {
                let name = URL(fileURLWithPath: file).lastPathComponent
                let range = lines.map { $0.count == 1 ? ", line \($0.lowerBound)" : ", lines \($0.lowerBound)–\($0.upperBound)" } ?? ""
                return name + range
            }
            return title ?? ""
        }

        /// As a prompt sent with it says: "main.rs, lines 10–12 on gpu", "Safari · Release notes".
        var summary: String {
            file != nil ? place + (host.map { " on \($0)" } ?? "") : [app, title].compactMap { $0 }.joined(separator: " \u{00B7} ")
        }

        /// As it goes with a prompt: as Claude Code words an editor's selection.
        var block: String {
            SelectionContext.block(text: text, file: file, lines: lines, app: app, title: title)
        }
    }

    static let shared = SelectionWatcher()

    @Published private(set) var selection: Selection? {
        didSet {
            // A selection made on a page, done with: the page stops marking it.
            if oldValue?.kind == .window, selection?.id != oldValue?.id {
                NotificationCenter.default.post(name: MarkdownView.clearKeptSelection, object: nil)
            }
        }
    }
    /// VS Code (or its kin), when it's the app you came from and keeps what you
    /// select to itself, until you let Agent Buddy switch on its screen reader mode.
    @Published private(set) var closedEditor: String?
    /// Whether Agent Buddy may read other apps' selections (Accessibility).
    @Published private(set) var trusted = AXIsProcessTrusted()
    /// Whether to watch at all (Settings).
    var enabled: () -> Bool = { true }
    var isEnabled: Bool { enabled() }
    /// The servers Agent Buddy may read a Zed project's file on.
    var servers: () -> [String] = { [] }
    /// An agent window's agent and session, for a selection made in it: ("Claude Code", "Fix the login page").
    var windowSource: (NSWindow) -> (app: String, title: String)? = { _ in nil }
    /// Whether Agent Buddy may switch VS Code into screen reader mode (Settings), and setting it.
    var editorsAllowed: () -> Bool = { false }
    var allowEditors: (Bool) -> Void = { _ in }

    private var users = 0
    private var timer: Timer?
    private var reading = false
    private var lastOther: pid_t?
    /// Zed's latest selection as last read: its row, editor and offsets (rows are rewritten).
    private var lastZedKey: String?
    /// Dismissed or sent: hidden until the selection changes.
    private var dismissed: String?
    /// The self-test's picture shows a sample, left alone.
    private var frozen = false
    /// The pasteboard as last seen: a change while another app is in front is a copy there.
    private var lastCopy = NSPasteboard.general.changeCount
    /// When each app's missing selection was last noted in the log.
    private var noted: [String: Date] = [:]
    /// VS Code and its kin in screen reader mode: switched on by Agent Buddy (true), or found so (false).
    private var switched: [pid_t: Bool] = [:]

    /// The other app's selection last read: unchanged, it doesn't take the place
    /// of one made in an agent window since.
    private var lastOtherID: String?
    /// The page a selection in an agent window is on.
    private weak var selectedPage: NSView?

    private init() {
        // VS Code goes back as it was when Agent Buddy quits.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.closeEditors() }
        }
        // What you select in an agent window's answer or steps.
        NotificationCenter.default.addObserver(forName: MarkdownView.selectionDidChange, object: nil, queue: .main) { [weak self] note in
            let page = note.object as? NSView
            let text = note.userInfo?["text"] as? String ?? ""
            MainActor.assumeIsolated { self?.selectedInWindow(text, on: page) }
        }
    }

    private func selectedInWindow(_ text: String, on page: NSView?) {
        guard !frozen, users > 0, enabled() else { return }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Unselected there: gone, unless something newer is shown.
            if selection?.kind == .window, selectedPage === page {
                selection = nil
            }
            return
        }
        let source = page?.window.flatMap(windowSource)
        let kept = text.count > 20_000 ? String(text.prefix(20_000)) + "\n\u{2026}" : text
        let found = Selection(kind: .window, app: source?.app ?? "Agent Buddy", file: nil, host: nil, lines: nil,
                              title: source?.title ?? "an agent window", text: kept,
                              id: "window|\(page.map { ObjectIdentifier($0).hashValue } ?? 0)|\(text.hashValue)")
        selectedPage = page
        if found.id != dismissed, found != selection {
            selection = found
        }
    }

    /// For the self-test's picture: shows `selection`, and stops reading.
    func preview(_ selection: Selection?) {
        frozen = true
        self.selection = selection
    }

    /// For the tour's pictures: whether Accessibility is allowed, and an editor that keeps its selection to itself.
    func preview(trusted: Bool, closedEditor: String?) {
        frozen = true
        self.trusted = trusted
        self.closedEditor = closedEditor
    }

    /// An agent window opened: watch while one is.
    func retain() {
        users += 1
        guard timer == nil else { return }
        // What was copied before an agent window opened isn't news.
        lastCopy = NSPasteboard.general.changeCount
        Diagnostics.log("selection: watching; Accessibility \(AXIsProcessTrusted() ? "allowed" : "not allowed"), VS Code \(editorsAllowed() ? "on" : "off")")
        if enabled(), editorsAllowed(), AXIsProcessTrusted() {
            openEditors()
        }
        let timer = Timer(timeInterval: 0.7, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    func release() {
        users = max(0, users - 1)
        guard users == 0 else { return }
        timer?.invalidate()
        timer = nil
        selection = nil
        closedEditor = nil
        lastZedKey = nil
        closeEditors()
    }

    /// Hide it until the selection changes: dismissed, or sent with a prompt.
    func dismiss() {
        dismissed = selection?.id
        selection = nil
    }

    /// Asks macOS to let Agent Buddy read other apps' selections, and opens where
    /// it's switched on. An entry already listed may be for an earlier build:
    /// macOS keeps that build's fingerprint, and switching it off and on doesn't
    /// renew it. So it's cleared first, and macOS asks about this build.
    func askForAccess() {
        guard !AXIsProcessTrusted() else {
            trusted = true
            return
        }
        if let id = Bundle.main.bundleIdentifier {
            let reset = ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/tccutil"), ["reset", "Accessibility", id])
            Diagnostics.log("selection: Agent Buddy's Accessibility entry \(reset?.status == 0 ? "cleared" : "couldn't be cleared"), asking again")
        }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        trusted = AXIsProcessTrustedWithOptions(options)
        if !trusted {
            openAccessibilitySettings()
        }
    }

    private enum Read {
        case unchanged
        case nothing
        case found(Selection)
    }

    /// Whether macOS allows it now, for Settings (agent windows check as they watch).
    func checkTrust() {
        let now = AXIsProcessTrusted()
        if now != trusted {
            trusted = now
        }
    }

    /// It was allowed once: not now means macOS lost track of it (an update).
    var lostAccess: Bool {
        !trusted && UserDefaults.standard.bool(forKey: "selection.wasTrusted")
    }

    /// Privacy & Security › Accessibility, where Agent Buddy is switched on.
    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func tick() {
        guard !frozen else { return }
        // Off: nothing to read, and nothing changes (the message boxes watching
        // this redraw at each change, and a setting written tells all of Agent Buddy).
        guard enabled() else {
            if selection != nil {
                selection = nil
            }
            if closedEditor != nil {
                closedEditor = nil
            }
            closeEditors()
            return
        }
        let trusted = AXIsProcessTrusted()
        if trusted != self.trusted {
            self.trusted = trusted
            Diagnostics.log("selection: Accessibility \(trusted ? "allowed" : "not allowed")")
        }
        if trusted, !UserDefaults.standard.bool(forKey: "selection.wasTrusted") {
            UserDefaults.standard.set(true, forKey: "selection.wasTrusted")
        }
        guard !reading else { return }
        // The app in front; while you're in an agent window, the one you came from.
        let me = ProcessInfo.processInfo.processIdentifier
        let frontmost = NSWorkspace.shared.frontmostApplication
        var target = frontmost
        if target?.processIdentifier == me {
            target = lastOther.flatMap { NSRunningApplication(processIdentifier: $0) }
        } else if let target {
            lastOther = target.processIdentifier
        }
        guard let target, !target.isTerminated else {
            settle(.nothing, mark: nil)
            return
        }
        let name = target.localizedName ?? "another app"
        let bundleID = target.bundleIdentifier ?? ""
        let pid = target.processIdentifier
        let isZed = bundleID.hasPrefix("dev.zed.Zed")
        let inFront = frontmost?.processIdentifier == pid
        // VS Code tells Accessibility what's selected only in its screen reader mode.
        let isEditor = Self.isVSCode(bundleID)
        let allowed = editorsAllowed()
        if isEditor, trusted, allowed {
            openEditor(target)
        } else if !allowed, !switched.isEmpty {
            closeEditors()
        }
        let closed = isEditor && trusted && !allowed ? name : nil
        if closed != closedEditor {
            closedEditor = closed
        }
        // A copy (⌘C) in the app in front: how an app that keeps its selection
        // to itself (VS Code, Chrome) shares it. Zed's selection is read anyway.
        let copies = NSPasteboard.general.changeCount
        if copies != lastCopy {
            lastCopy = copies
            if frontmost?.processIdentifier != me, !isZed, let copied = Self.copied(app: name, pid: pid, trusted: trusted) {
                settle(.found(copied), mark: nil)
                return
            }
        }
        let known = lastZedKey
        let servers = self.servers()
        reading = true
        Task.detached(priority: .utility) { [weak self] in
            var mark: String?
            let read: Read
            var missing: String?
            if isZed {
                (read, mark) = Self.zed(bundleID: bundleID, app: name, known: known, servers: servers)
            } else if trusted {
                let found = Self.accessibility(pid: pid, app: name)
                read = found.selection.map(Read.found) ?? .nothing
                missing = found.missing
            } else {
                read = .nothing
            }
            await self?.settle(read, mark: mark, from: isZed ? .zed : .accessibility, app: name, missing: missing, inFront: inFront)
        }
    }

    /// - Parameters: `from`: where the read was, whose selection a `.nothing` ends
    ///   (a copy stays until sent or replaced); `missing`: why an app showed none, for the log;
    ///   `inFront`: the app was in front. Behind (you're in an agent window), an app may
    ///   not say what's selected: what it showed in front stays.
    private func settle(
        _ read: Read, mark: String?, from: Selection.Kind? = nil, app: String? = nil, missing: String? = nil, inFront: Bool = true
    ) {
        reading = false
        if let mark {
            lastZedKey = mark
        }
        if case .nothing = read, from == .accessibility, !inFront {
            return
        }
        if let app, let missing, Date().timeIntervalSince(noted[app + missing] ?? .distantPast) > 600 {
            // Once in a while, why an app shows no selection (never what's selected).
            noted[app + missing] = Date()
            Diagnostics.log("selection: none from \(app): \(missing)")
        }
        switch read {
        case .unchanged:
            break
        case .nothing:
            // A copy, and a selection in an agent window, stay until replaced (or unselected there).
            if let shown = selection, shown.kind != .copied, shown.kind != .window, from == nil || shown.kind == from {
                selection = nil
            }
        case .found(let found):
            // The same selection as before, elsewhere: one made in an agent window since stays.
            let unchanged = found.id == lastOtherID
            lastOtherID = found.id
            if selection?.kind == .window, unchanged {
                return
            }
            if found.id == dismissed {
                if selection != nil {
                    selection = nil
                }
            } else if found != selection {
                selection = found
            }
        }
    }

    // MARK: - Zed

    /// Zed's latest selection, read from its file (or over SSH, on one of your servers).
    nonisolated private static func zed(bundleID: String, app: String, known: String?, servers: [String]) -> (Read, String?) {
        let database = ZedSelection.database(bundleID)
        guard let latest = ZedSelection.latest(database: database) else { return (.nothing, nil) }
        let key = "\(latest.mark)|\(latest.workspace)|\(latest.editor)|\(latest.start)-\(latest.end)"
        guard key != known else { return (.unchanged, nil) }
        guard !latest.isEmpty, let path = latest.path else { return (.nothing, key) }
        let id = "zed|\(key)|\(path)"
        if let host = latest.host {
            guard servers.contains(where: { SSHHosts.same($0, host) }),
                  let excerpt = ZedSelection.remoteExcerpt(host: host, path: path, start: latest.start, end: latest.end)
            else { return (.nothing, key) }
            return (.found(Selection(kind: .zed, app: app, file: path, host: host, lines: excerpt.lines, title: nil, text: excerpt.text, id: id)), key)
        }
        let data = latest.contents(database: database).map { Data($0.utf8) } ?? FileManager.default.contents(atPath: path)
        guard let data, let excerpt = ZedSelection.excerpt(data, start: latest.start, end: latest.end),
              !excerpt.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return (.nothing, key) }
        return (.found(Selection(kind: .zed, app: app, file: path, host: nil, lines: excerpt.lines, title: nil, text: excerpt.text, id: id)), key)
    }

    // MARK: - VS Code

    /// Asks first, since VS Code changes while it's in screen reader mode; then switches it on.
    func offerEditors(_ app: String) {
        let alert = NSAlert()
        alert.messageText = "Read what you select in \(app)?"
        alert.informativeText = """
            \(app) tells other apps what you select only in its screen reader mode. Agent Buddy can switch that on \
            while an agent window is open, the way a screen reader does, and back off after.

            Meanwhile \(app) shows \u{201C}Screen Reader Optimized\u{201D} in its status bar and may play accessibility \
            sounds (turn them down with the setting accessibility.signalOptions.volume). It also asks once whether \
            you use a screen reader: close that notice, as No stops it sharing.

            You can turn this off in Agent Buddy's settings.
            """
        alert.addButton(withTitle: "Switch On")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        allowEditors(true)
        openEditors()
        tick()
    }

    /// Every VS Code (and kin) running, into screen reader mode.
    private func openEditors() {
        for app in NSWorkspace.shared.runningApplications where Self.isVSCode(app.bundleIdentifier ?? "") {
            openEditor(app)
        }
    }

    /// As a screen reader does, through Electron's AXManualAccessibility; left
    /// alone if something else (VoiceOver) already has it on.
    private func openEditor(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard switched[pid] == nil, !app.isTerminated else { return }
        if Self.electronAccessibility(pid) == true {
            // On already: by an Agent Buddy that didn't get to switch it off (it crashed), or by a screen reader.
            switched[pid] = Self.remembered.contains(Self.mark(app))
            return
        }
        let done = Self.setElectronAccessibility(true, pid: pid)
        // Not retried if it failed; a new VS Code (a new process) is.
        switched[pid] = done
        if done {
            Self.remembered.insert(Self.mark(app))
        }
        Diagnostics.log("selection: \(done ? "switched on" : "couldn't switch on") screen reader mode in \(app.localizedName ?? "VS Code")")
    }

    /// The VS Code processes Agent Buddy switched on, kept across a crash.
    private static var remembered: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "selection.switchedEditors") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "selection.switchedEditors") }
    }

    /// A process, told from a later one with its number.
    private static func mark(_ app: NSRunningApplication) -> String {
        "\(app.processIdentifier)@\(Int(app.launchDate?.timeIntervalSince1970 ?? 0))"
    }

    /// Back as they were: the last agent window closed, the setting went off, or Agent Buddy quits.
    func closeEditors() {
        for (pid, ours) in switched where ours {
            guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { continue }
            Self.setElectronAccessibility(false, pid: pid)
            Diagnostics.log("selection: switched off screen reader mode in \(app.localizedName ?? "VS Code")")
        }
        switched = [:]
        if !Self.remembered.isEmpty {
            Self.remembered = []
        }
    }

    /// Whether an Electron app has its accessibility on; nil if it won't say.
    nonisolated static func electronAccessibility(_ pid: pid_t) -> Bool? {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.5)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, "AXManualAccessibility" as CFString, &value) == .success else { return nil }
        return (value as? NSNumber)?.boolValue
    }

    @discardableResult
    nonisolated private static func setElectronAccessibility(_ on: Bool, pid: pid_t) -> Bool {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.5)
        return AXUIElementSetAttributeValue(application, "AXManualAccessibility" as CFString, on ? kCFBooleanTrue : kCFBooleanFalse) == .success
    }

    // MARK: - Copies

    /// What was just copied, unless an app marked it secret (a password
    /// manager) or passing; named by the window it came from.
    private static func copied(app: String, pid: pid_t, trusted: Bool) -> Selection? {
        let board = NSPasteboard.general
        let types = Set((board.types ?? []).map(\.rawValue))
        guard types.isDisjoint(with: ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType"]),
              let text = board.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        var file: String?
        var title: String?
        if trusted {
            (file, title) = window(of: pid)
        }
        if file == nil, let title {
            file = Self.file(inTitle: title)
        }
        let kept = text.count > 20_000 ? String(text.prefix(20_000)) + "\n…" : text
        return Selection(kind: .copied, app: app, file: file, host: nil, lines: nil, title: file == nil ? title : nil, text: kept,
                         id: "copied|\(board.changeCount)")
    }

    /// VS Code and its kin (Cursor, Windsurf, VSCodium).
    nonisolated static func isVSCode(_ bundleID: String) -> Bool {
        ["com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.exafunction.windsurf", "com.vscodium"].contains { bundleID.hasPrefix($0) }
    }

    /// "● main.rs — head_show — Visual Studio Code": the file a window's title
    /// starts with, as editors put it; nil for a title that isn't a file's.
    nonisolated static func file(inTitle title: String) -> String? {
        let first = firstPart(ofTitle: title)
        guard title.contains(" \u{2014} "), first.contains("."), !first.contains(" "), !first.hasSuffix(".") else { return nil }
        return first
    }

    /// "07_inverse.tex — score [SSH: gpu] — 2 problems in this file": the part
    /// before the folder and what VS Code adds for a screen reader.
    nonisolated static func firstPart(ofTitle title: String) -> String {
        title.components(separatedBy: " \u{2014} ")[0].replacingOccurrences(of: "\u{25CF} ", with: "").trimmingCharacters(in: .whitespaces)
    }

    /// The server a VS Code window's folder is on: "score [SSH: gpu]".
    nonisolated static func host(inTitle title: String) -> String? {
        guard let start = title.range(of: "[SSH: "), let end = title[start.upperBound...].firstIndex(of: "]") else { return nil }
        let host = title[start.upperBound..<end].trimmingCharacters(in: .whitespaces)
        return host.isEmpty ? nil : host
    }

    /// "Ln 12, Col 5 (8 selected)": line 12, column 5.
    nonisolated static func cursor(inLabel label: String) -> (line: Int, column: Int)? {
        func number(after word: String) -> Int? {
            guard let found = label.range(of: word) else { return nil }
            return Int(label[found.upperBound...].prefix { $0.isASCII && $0.isNumber })
        }
        guard let line = number(after: "Ln "), let column = number(after: "Col ") else { return nil }
        return (line, column)
    }

    /// VS Code's status bar item that says where the cursor is ("Ln 12, Col 5 (8
    /// selected)"), found by its element's id, past the editors' and side bars' insides.
    nonisolated private static func cursorLabel(in window: AXUIElement) -> String? {
        func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
        }
        let skipped: Set<String> = ["workbench.parts.editor", "workbench.parts.sidebar", "workbench.parts.panel",
                                    "workbench.parts.auxiliarybar", "workbench.parts.activitybar"]
        var queue = [window]
        var visited = 0
        while !queue.isEmpty, visited < 2000 {
            let node = queue.removeFirst()
            visited += 1
            let id = value(node, "AXDOMIdentifier") as? String
            if id == "status.editor.selection" {
                for each in [node] + ((value(node, kAXChildrenAttribute) as? [AXUIElement]) ?? []) {
                    for name in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] {
                        if let text = value(each, name) as? String, cursor(inLabel: text) != nil {
                            return text
                        }
                    }
                }
                return nil
            }
            if let id, skipped.contains(id) {
                continue
            }
            queue += (value(node, kAXChildrenAttribute) as? [AXUIElement]) ?? []
        }
        return nil
    }

    /// For `--accessibility-status`: whether Agent Buddy may read other apps, and
    /// what VS Code (and kin), Safari and the app in front show now: how much is
    /// selected and where, never the text. It switches nothing on.
    nonisolated static func status() -> [String] {
        var lines = ["Accessibility: \(AXIsProcessTrusted() ? "allowed" : "not allowed")"]
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let apps = NSWorkspace.shared.runningApplications.filter { app in
            let id = app.bundleIdentifier ?? ""
            return isVSCode(id) || id == "com.apple.Safari" || app.processIdentifier == front
        }
        for app in apps where !app.isTerminated {
            let name = app.localizedName ?? app.bundleIdentifier ?? "?"
            var line = "\(name) (pid \(app.processIdentifier)\(app.processIdentifier == front ? ", in front" : ""))"
            if isVSCode(app.bundleIdentifier ?? "") {
                let on = electronAccessibility(app.processIdentifier)
                line += ": its accessibility \(on.map { $0 ? "on" : "off" } ?? "won't say")"
            }
            let found = accessibility(pid: app.processIdentifier, app: name)
            if let selection = found.selection {
                line += "; selected: \(selection.text.count) characters, \(selection.place)"
            } else {
                line += "; nothing read: \(found.missing ?? "?")"
            }
            lines.append(line)
            if isVSCode(app.bundleIdentifier ?? "") {
                lines += editorDetails(app.processIdentifier)
            }
        }
        return lines
    }

    /// What VS Code shows Accessibility, for working out a selection's file and
    /// lines: its window's title and file, the editor's page, and its status bar.
    nonisolated private static func editorDetails(_ pid: pid_t) -> [String] {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.5)
        func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
        }
        func element(_ value: CFTypeRef?) -> AXUIElement? {
            guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return unsafeBitCast(value, to: AXUIElement.self)
        }
        var lines: [String] = []
        if let window = element(attribute(application, kAXFocusedWindowAttribute)) {
            lines.append("  window title: \(attribute(window, kAXTitleAttribute) as? String ?? "-")")
            lines.append("  window file: \(attribute(window, kAXDocumentAttribute) as? String ?? "-")")
            let started = Date()
            let label = cursorLabel(in: window)
            lines.append("  status bar: \(label ?? "not found") (\(Int(Date().timeIntervalSince(started) * 1000)) ms)")
        } else {
            lines.append("  no focused window")
        }
        if let focused = element(attribute(application, kAXFocusedUIElementAttribute)) {
            let role = attribute(focused, kAXRoleAttribute) as? String ?? "?"
            let page = (attribute(focused, kAXValueAttribute) as? String)?.count
            var range = CFRange()
            var selected = "-"
            if let value = attribute(focused, kAXSelectedTextRangeAttribute), CFGetTypeID(value) == AXValueGetTypeID(),
               AXValueGetValue(unsafeBitCast(value, to: AXValue.self), .cfRange, &range) {
                selected = "\(range.location)+\(range.length)"
            }
            let caret = (attribute(focused, kAXInsertionPointLineNumberAttribute) as? NSNumber)?.intValue
            let label = [kAXDescriptionAttribute, kAXTitleAttribute].compactMap { attribute(focused, $0) as? String }.first ?? "-"
            lines.append("  focus: \(role) \"\(label.prefix(80))\"; page \(page.map(String.init) ?? "-") characters; selected \(selected); caret on page line \(caret.map(String.init) ?? "-")")
        } else {
            lines.append("  no focused element")
        }
        return lines
    }

    /// The focused window's file (where the app says) and title.
    nonisolated private static func window(of pid: pid_t) -> (file: String?, title: String?) {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.3)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &value) == .success, let value,
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return (nil, nil) }
        let window = unsafeBitCast(value, to: AXUIElement.self)
        var file: String?
        var document: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, kAXDocumentAttribute as CFString, &document) == .success,
           let url = (document as? String).flatMap(URL.init(string:)), url.isFileURL {
            file = url.path
        }
        var title: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title)
        return (file, (title as? String).flatMap { $0.isEmpty ? nil : $0 })
    }

    // MARK: - Other apps

    /// The selected text of the app's focused element (or, in a web page, of the
    /// page), with its window's file or title, and its lines where the element
    /// counts them. With none: why, for the log.
    nonisolated private static func accessibility(pid: pid_t, app: String) -> (selection: Selection?, missing: String?) {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.3)
        func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
        }
        func element(_ value: CFTypeRef?) -> AXUIElement? {
            guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return unsafeBitCast(value, to: AXUIElement.self)
        }
        func words(_ text: String?) -> String? {
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return text
        }
        /// WebKit (Safari, Mail): a page's selection comes as a range of text markers.
        func marked(_ element: AXUIElement) -> String? {
            guard let range = attribute(element, "AXSelectedTextMarkerRange") else { return nil }
            var value: CFTypeRef?
            guard AXUIElementCopyParameterizedAttributeValue(element, "AXStringForTextMarkerRange" as CFString, range, &value) == .success
            else { return nil }
            return words(value as? String)
        }
        guard let focused = element(attribute(application, kAXFocusedUIElementAttribute)) else {
            return (nil, "it doesn't say what has focus (it may not support Accessibility)")
        }
        let role = (attribute(focused, kAXRoleAttribute) as? String) ?? "?"
        var selected = words(attribute(focused, kAXSelectedTextAttribute) as? String) ?? marked(focused)
        var source = focused
        if selected == nil {
            // Focus on a link or a part of a page: ask the page.
            var parent = element(attribute(focused, kAXParentAttribute))
            for _ in 0..<12 {
                guard let current = parent else { break }
                if (attribute(current, kAXRoleAttribute) as? String) == "AXWebArea" {
                    selected = words(attribute(current, kAXSelectedTextAttribute) as? String) ?? marked(current)
                    source = current
                    break
                }
                parent = element(attribute(current, kAXParentAttribute))
            }
        }
        guard let selected else {
            return (nil, "nothing selected, or the app doesn't tell Accessibility (focus on \(role))")
        }
        var file: String?
        var host: String?
        var title: String?
        let window = element(attribute(application, kAXFocusedWindowAttribute))
        if let window {
            if let document = attribute(window, kAXDocumentAttribute) as? String, let url = URL(string: document), url.isFileURL {
                file = url.path
            }
            title = (attribute(window, kAXTitleAttribute) as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        // Lines, for a file: where the selection starts and ends. VS Code and its
        // kin give a screen reader a page of the file around the selection: its
        // lines are where the status bar's cursor puts them, else where that page
        // is in the file. A file on a server has no path, only its name in the title.
        let paged = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier.map(isVSCode) ?? false
        if paged, let whole = title {
            if file == nil {
                file = Self.file(inTitle: whole)
                host = Self.host(inTitle: whole)
            }
            title = Self.firstPart(ofTitle: whole)
        }
        var lines: ClosedRange<Int>?
        var range = CFRange()
        if let file, let rangeValue = attribute(source, kAXSelectedTextRangeAttribute), CFGetTypeID(rangeValue) == AXValueGetTypeID(),
           AXValueGetValue(unsafeBitCast(rangeValue, to: AXValue.self), .cfRange, &range) {
            if paged {
                let chosen = NSRange(location: range.location, length: range.length)
                let page = attribute(source, kAXValueAttribute) as? String
                if let page, let window, let cursor = Self.cursorLabel(in: window).flatMap(Self.cursor(inLabel:)) {
                    lines = SelectionContext.lines(of: chosen, page: page, cursorLine: cursor.line, cursorColumn: cursor.column)
                }
                let size = (try? FileManager.default.attributesOfItem(atPath: file))?[.size] as? NSNumber
                if lines == nil, host == nil, let page, (size?.intValue ?? .max) <= 8_000_000,
                   let data = FileManager.default.contents(atPath: file), let contents = String(data: data, encoding: .utf8) {
                    lines = SelectionContext.lines(of: chosen, page: page, file: contents)
                }
            } else {
                func line(_ index: Int) -> Int? {
                    var value: CFTypeRef?
                    guard AXUIElementCopyParameterizedAttributeValue(
                        source, kAXLineForIndexParameterizedAttribute as CFString, index as CFNumber, &value) == .success
                    else { return nil }
                    return (value as? NSNumber)?.intValue
                }
                if let first = line(range.location), let last = line(range.location + max(range.length - 1, 0)) {
                    lines = (first + 1)...(max(first, last) + 1)
                }
            }
        }
        let text = selected.count > 20_000 ? String(selected.prefix(20_000)) + "\n…" : selected
        return (Selection(kind: .accessibility, app: app, file: file, host: host, lines: lines, title: title, text: text,
                          id: "ax|\(pid)|\(selected.hashValue)"), nil)
    }
}
