import AppKit
import AgentBuddyCore
import SwiftUI
import WebKit

/// `AgentBuddy --selftest-history LOG`: opens the history window for a session
/// log on this Mac (off screen), waits for its prompts and for where it runs,
/// writes the window as a PNG, and checks how reminder clicks are routed. It
/// never jumps.
@MainActor
enum HistorySelfTest {
    static func run(log path: String, image: URL?) -> Int32 {
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            print(ok ? "  ok    \(what)" : "  FAIL  \(what)")
            if !ok {
                failures += 1
            }
        }
        print("Reminder clicks")
        let notifier = Notifier()
        var opened: [String] = []
        var jumped: [String] = []
        var details = 0
        notifier.onOpenWindow = { opened.append($0) }
        notifier.onJumpWindow = { jumped.append($0) }
        notifier.onOpen = { details += 1 }
        notifier.opened("window-claude|gpu|abc-123", jump: false)
        notifier.opened("window-codex||th-9", jump: true)
        notifier.opened("window-test", jump: false)
        notifier.opened("limit-claude.session-90-0", jump: false)
        check(opened == ["claude|gpu|abc-123"], "a job reminder opens its agent window's history")
        check(jumped == ["codex||th-9"], "its Jump action jumps")
        check(details == 2, "the test reminder and limit reminders open the usual details")

        print("The history window")
        let agent: Agent = path.contains("/.codex/") ? .codex : path.hasSuffix("events.jsonl") ? .copilot
            : path.contains("/.gemini/") ? .gemini : path.contains("/.qwen/") ? .qwen : path.contains("opencode.db#") ? .opencode
            : path.hasSuffix("store.db") ? .cursor : path.contains("/session.") ? .deepseek : .claude
        // Agents sent prompts from the box under their history (the others have none there).
        let sendable = agent == .claude || agent == .codex
        let url = URL(fileURLWithPath: path)
        let session = agent == .copilot ? url.deletingLastPathComponent().lastPathComponent
            : !agent.hasLimits ? ((try? AgentLogs.read(agent: agent, path: path).get())?.history.sessionID ?? url.lastPathComponent)
            : url.deletingPathExtension().lastPathComponent
        let key = "\(agent.rawValue)||\(session)"
        let controller = SessionDetailsController()
        controller.offscreen = true
        controller.show(key: key, info: WindowInfo(title: nil, project: nil, path: path, finished: []))
        guard let open = controller.open(key) else {
            check(false, "a window opens for \(key)")
            return 1
        }
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline, open.details.history == nil || open.details.place == nil {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let history = open.details.history
        check(history != nil, "it reads the session: \(open.details.problem ?? "\(history?.turns.count ?? 0) prompts")")
        check((history?.turns.count ?? 0) > 0, "with its prompts")
        switch open.details.place {
        case .found(let place)?:
            check(true, "it finds where it runs: \(place.appName), \(place.detail)")
        case .closed(let reason)?:
            check(true, "it says why there's nowhere to jump: \(reason)")
        case nil:
            check(false, "it looks for where it runs")
        }
        // A job finished there: the open window reads its session again, and a
        // second word while it's reading isn't lost.
        var reads = 0
        let counting = open.details.didRead.sink { _ in reads += 1 }
        controller.refresh(key)
        controller.refresh(key)
        let until = Date().addingTimeInterval(20)
        while Date() < until, reads < 2 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        counting.cancel()
        check(reads == 2, "a job finishing there makes it read the session again, and once more if told while reading (\(reads) reads)")
        controller.refresh("claude||not-open")
        check(true, "a job in a window that isn't open is no matter")
        print("Answers, and a prompt just sent")
        if let history, let latest = history.turns.max(by: { $0.askedAt < $1.askedAt }) {
            // As typed: other spacing and line breaks than the log keeps.
            let typed = SessionDetails.PendingPrompt(
                text: "  " + latest.text.replacingOccurrences(of: " ", with: "\n") + "\n", at: latest.askedAt.addingTimeInterval(-5))
            check(SessionDetails.recorded(typed, in: history), "a prompt sent from here is known in the log by its words")
            check(!SessionDetails.recorded(SessionDetails.PendingPrompt(text: "Something nobody asked", at: Date()), in: history),
                  "and not mistaken for another")
            check(!SessionDetails.recorded(SessionDetails.PendingPrompt(text: latest.text, at: latest.askedAt.addingTimeInterval(3600)), in: history),
                  "nor for the same words asked long before it")
        }
        // The latest turn, open: what the agent did, step by step, read for it.
        print("A turn's steps")
        let latestID = open.details.latestID
        let stepsBy = Date().addingTimeInterval(20)
        while Date() < stepsBy, latestID.map({ open.details.steps[$0] == nil }) ?? false {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        let steps = latestID.flatMap { open.details.steps[$0]?.steps } ?? []
        if !sendable {
            check(steps.isEmpty, "\(agent.clientName)'s turns have no steps here: its answer shows")
        } else {
            check(!steps.isEmpty, "the open turn's steps are read: \(steps.filter { $0.kind == .said }.count) said, "
                  + "\(steps.filter { $0.kind == .ran }.count) ran, \(steps.filter { $0.kind == .changed }.count) changed")
        }
        // The latest answer (or its steps), drawn by WebKit in the window, as tall as it is.
        let drawnBy = Date().addingTimeInterval(8)
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        while Date() < drawnBy, webViews(in: open.window.contentView).isEmpty {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        let answers = webViews(in: open.window.contentView)
        func script(_ view: WKWebView, _ source: String) -> Any? {
            var result: Any?
            var done = false
            view.evaluateJavaScript(source) { value, _ in
                result = value
                done = true
            }
            let asked = Date()
            while !done, Date().timeIntervalSince(asked) < 5 {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
            return result
        }
        if !steps.isEmpty, let drawn = answers.first(where: { (script($0, "document.querySelectorAll('.step').length") as? NSNumber)?.intValue ?? 0 > 0 }) {
            func count(_ selector: String) -> Int {
                (script(drawn, "document.querySelectorAll(\"\(selector)\").length") as? NSNumber)?.intValue ?? -1
            }
            let said = count(".step.said")
            let actions = count(".step.action")
            check(said + actions == steps.count, "each step is drawn after a \u{25CF}, runs of actions folded: \(said) said, \(actions) actions, \(count(".step.group")) runs")
            check(count(".step .output:not([hidden])") == 0, "outputs wait for a click: \(count(".step .output"))")
            let changed = steps.filter { !$0.hunks.isEmpty }.count
            let long = steps.filter { $0.hunks.reduce(0) { $0 + $1.lines.count } > 10 }.count
            check(count("a.view") == changed && count(".change") == changed && count("details.changes:not([open])") == (changed > 0 ? 1 : 0)
                  && count(".change details.fold") == long,
                  "its \(changed) changes at the end, under View changes, \(long) of them long and folded")
            // Selected in the window: offered with the next prompt, named by its session.
            SelectionWatcher.shared.windowSource = { controller.source(of: $0) }
            _ = script(drawn, "getSelection().selectAllChildren(document.querySelector('.step.said .body'))")
            let pickedBy = Date().addingTimeInterval(4)
            while Date() < pickedBy, SelectionWatcher.shared.selection?.kind != .window {
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            }
            let picked = SelectionWatcher.shared.selection
            check(picked?.kind == .window && picked?.app == agent.clientName && picked?.title == open.details.title
                  && !(picked?.text.isEmpty ?? true) && picked?.block.contains("in \(agent.clientName) (") == true,
                  "what's selected in its answer goes by the message box: Selected in \(picked?.app ?? "-") \u{00B7} \(picked?.place.prefix(40) ?? "-")")
            // As you'd do it: the page clicked into, text selected, then the message box clicked.
            _ = open.window.makeFirstResponder(drawn)
            _ = script(drawn, "getSelection().selectAllChildren(document.querySelector('.step.said .body'))")
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            if let field = textFields(in: open.window.contentView).first(where: \.isEditable) {
                _ = open.window.makeFirstResponder(field)
            }
            RunLoop.main.run(until: Date().addingTimeInterval(1.5))
            let stillOnPage = (script(drawn, "getSelection().toString().length") as? NSNumber)?.intValue ?? -1
            check(SelectionWatcher.shared.selection?.kind == .window,
                  "clicking into the message box keeps it for the prompt (\(stillOnPage) characters still selected on the page)")
            let marked = script(drawn, "CSS.highlights ? CSS.highlights.has('kept') : 'no Highlight API'")
            if history?.isSubagent == true || !sendable {
                check(true, "(a sub-agent's thread has no message box to click into, so nothing to keep marked)")
            } else {
                check((marked as? Bool) == true || (marked as? String) == "no Highlight API", "and keeps it marked on the page: \(String(describing: marked))")
            }
            SelectionWatcher.shared.dismiss()
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            let unmarked = script(drawn, "CSS.highlights ? CSS.highlights.has('kept') : false")
            check((unmarked as? Bool) == false, "dismissed (or sent), the mark goes")
            _ = open.window.makeFirstResponder(drawn)
            _ = script(drawn, "getSelection().removeAllRanges()")
            let clearedBy = Date().addingTimeInterval(4)
            while Date() < clearedBy, SelectionWatcher.shared.selection?.kind == .window {
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            }
            check(SelectionWatcher.shared.selection?.kind != .window, "unselected there, it goes")
            // The page takes the text size set; ⌘+, ⌘− and ⌘0 set it.
            let shown = (script(drawn, "parseFloat(getComputedStyle(document.body).fontSize)") as? NSNumber)?.doubleValue ?? 0
            let set = UserDefaults.standard.object(forKey: TextStyle.sizeKey) as? Double ?? TextStyle.standardSize
            check(shown == set, "the page takes the text size set: \(shown) pt")
            let before = UserDefaults.standard.object(forKey: TextStyle.sizeKey)
            func now() -> Double { UserDefaults.standard.object(forKey: TextStyle.sizeKey) as? Double ?? TextStyle.standardSize }
            TextStyle.reset()
            TextStyle.bigger()
            let bigger = now()
            TextStyle.smaller()
            TextStyle.smaller()
            let smaller = now()
            (1...20).forEach { _ in TextStyle.bigger() }
            let most = now()
            TextStyle.reset()
            let reset = now()
            UserDefaults.standard.set(before, forKey: TextStyle.sizeKey)
            check(bigger == 13.5 && smaller == 11.5 && most == TextStyle.sizes.upperBound && reset == TextStyle.standardSize,
                  "\u{2318}+ and \u{2318}\u{2212} a point at a time, up to \(Int(TextStyle.sizes.upperBound)); \u{2318}0 back to \(TextStyle.standardSize)")
        } else if !steps.isEmpty {
            check(false, "the steps are drawn by WebKit")
        }
        check(!answers.isEmpty || history?.turns.allSatisfy({ $0.answer == nil }) == true, "the latest answer is drawn by WebKit: \(answers.count)")
        // The pages there now (the size test may have made new ones).
        for answer in webViews(in: open.window.contentView).prefix(3) {
            // Measured once the window has taken the page's height.
            var measured: CGFloat = -1
            let until = Date().addingTimeInterval(4)
            repeat {
                measured = CGFloat((script(answer, "Math.ceil(document.getElementById('answer').getBoundingClientRect().height)") as? NSNumber)?.doubleValue ?? -2)
                if measured > 0, abs(answer.frame.height - measured) <= 2 {
                    break
                }
                open.window.contentView?.layoutSubtreeIfNeeded()
                open.window.displayIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.15))
            } while Date() < until
            check(measured > 0 && abs(answer.frame.height - measured) <= 2,
                  "it's as tall as its answer: \(Int(answer.frame.height)) for \(Int(measured)) points")
        }

        // For the picture: a prompt as if just sent, at the end of the line.
        open.details.showPending("Can you also check the domain of the generator?", attached: "notes.tex, lines 12–14")
        // A copy names its file from the window's title, as editors put it.
        check(SelectionWatcher.file(inTitle: "\u{25CF} main.rs \u{2014} head_show \u{2014} Visual Studio Code") == "main.rs"
              && SelectionWatcher.file(inTitle: "lib.rs \u{2014} score [SSH: gpu] \u{2014} Visual Studio Code") == "lib.rs"
              && SelectionWatcher.file(inTitle: "Release notes \u{2014} Safari") == nil
              && SelectionWatcher.file(inTitle: "Untitled") == nil
              && SelectionWatcher.file(inTitle: "07_inverse.tex \u{2014} score [SSH: 203.0.113.7] \u{2014} 2 problems in this file") == "07_inverse.tex",
              "a copy's file, from the window's title")
        // A selection in VS Code: its file and server from the title, its lines from the status bar.
        check(SelectionWatcher.host(inTitle: "07_inverse.tex \u{2014} score [SSH: 203.0.113.7] \u{2014} Modified") == "203.0.113.7"
              && SelectionWatcher.host(inTitle: "main.rs \u{2014} head_show \u{2014} Visual Studio Code") == nil
              && SelectionWatcher.firstPart(ofTitle: "\u{25CF} 07_inverse.tex \u{2014} score [SSH: gpu] \u{2014} Modified") == "07_inverse.tex",
              "a VS Code window's title gives its file and server, without what it adds for a screen reader")
        check(StepsView.summary([TurnStep(kind: .ran, text: "Read(a.tex)"), TurnStep(kind: .ran, text: "Bash(make)"),
                                 TurnStep(kind: .ran, text: "Read(b.tex)"), TurnStep(kind: .ran, text: "Web Search(\"x\")")])
              == "Read 2 files, ran 1 command, searched the web", "a run of actions in a line: \"Read 2 files, ran 1 command, searched the web\"")
        check(SelectionWatcher.cursor(inLabel: "Ln 198, Col 1 (310 selected)").map { [$0.line, $0.column] } == [198, 1]
              && SelectionWatcher.cursor(inLabel: "3 selections (24 characters selected)") == nil,
              "the status bar's cursor: line and column, none for several selections")
        let remote = SelectionWatcher.Selection(kind: .accessibility, app: "Code", file: "07_inverse.tex", host: "203.0.113.7",
                                                lines: 190...197, title: "07_inverse.tex", text: "x", id: "t")
        check(remote.place == "07_inverse.tex, lines 190\u{2013}197" && remote.summary == "07_inverse.tex, lines 190\u{2013}197 on 203.0.113.7",
              "its label is the file and lines; a prompt sent with it names the server too")
        // And a selection made in Zed, by the message box.
        SelectionWatcher.shared.preview(SelectionWatcher.Selection(
            app: "Zed", file: "/Users/me/paper/proof.tex", host: nil, lines: 40...42, title: nil,
            text: "\\begin{lemma}\nThe generator $\\mathcal L_t$ is closable.\n\\end{lemma}", id: "preview"))
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))

        print("Moved here: kept open in the background")
        if agent == .claude {
            // A stand-in for Claude Code reading its prompts as stream-json.
            let standIn = FileManager.default.temporaryDirectory.appendingPathComponent("ab-standin-claude-\(UUID().uuidString)")
            // It keeps what it's told; a change of mode, say, is answered, not taken for a prompt.
            try? """
            #!/usr/bin/env python3
            import json, sys, time
            told = open(sys.argv[0] + ".told", "a")
            for line in sys.stdin:
                o = json.loads(line)
                told.write(line); told.flush()
                if o.get("type") == "control_request" and o["request"]["subtype"] != "interrupt":
                    print(json.dumps({"type": "control_response", "response": {"subtype": "success", "request_id": o["request_id"]}}), flush=True)
                    continue
                if o.get("type") == "user" and o["message"]["content"][0].get("text") == "Take your time":
                    time.sleep(1.5)
                print(json.dumps({"type": "result", "is_error": False, "result": "Done"}), flush=True)

            """.write(to: standIn, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: standIn.path)
            let picture = FileManager.default.temporaryDirectory.appendingPathComponent("ab-standin-shot-\(UUID().uuidString).png")
            try? Data([0x89, 0x50, 0x4E, 0x47]).write(to: picture)
            defer {
                SessionKeeper.shared.standIn = nil
                try? FileManager.default.removeItem(at: standIn)
                try? FileManager.default.removeItem(atPath: standIn.path + ".told")
                try? FileManager.default.removeItem(at: picture)
            }
            SessionKeeper.shared.standIn = standIn
            func settle(_ seconds: TimeInterval, _ done: () -> Bool) {
                let until = Date().addingTimeInterval(seconds)
                while Date() < until, !done() {
                    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                }
            }
            open.details.moveHere()
            settle(6) { SessionKeeper.shared.phases[key] == .ready }
            check(SessionKeeper.shared.phases[key] == .ready && SessionKeeper.shared.isKept(key), "Open here: the session open in the background, waiting for a prompt")
            open.details.draft = "Hello from the box"
            check(open.details.canSend, "the box can send into it")
            open.details.send()
            check(open.details.inFlight != nil && open.details.pending?.text == "Hello from the box" && open.details.draft.isEmpty,
                  "sent into it: under way, and shown where it goes")
            settle(6) { open.details.inFlight == nil }
            if case .finished? = open.details.sent {
                check(true, "its turn done, the box ready for the next")
            } else {
                check(false, "its turn ends: \(String(describing: open.details.sent))")
            }
            // Plan mode chosen in the box, and a picture added: told, and shown with the prompt.
            open.details.composing.options.mode = "plan"
            open.details.composing.files = [picture]
            open.details.draft = "What's in this picture?"
            open.details.send()
            settle(6) { open.details.inFlight == nil }
            let told = ((try? String(contentsOfFile: standIn.path + ".told", encoding: .utf8)) ?? "").split(separator: "\n")
                .compactMap { JSON.parse(String($0)) }
            let asked = told.last { $0["type"].string == "user" }?["message"]["content"]
            check(told.contains { $0["request"]["subtype"].string == "set_permission_mode" && $0["request"]["mode"].string == "plan" },
                  "a mode chosen in the box is told the session kept open")
            check(asked?[1]["type"].string == "image" && asked?[1]["source"]["media_type"].string == "image/png"
                  && open.details.composing.files.isEmpty && open.details.pending?.attached?.contains(picture.lastPathComponent) == true,
                  "a picture added goes with the prompt, and the box lets go of it")
            open.details.composing.options = PromptSender.Options()
            SessionKeeper.shared.letGo(key)
            settle(2) { SessionKeeper.shared.phases[key] == nil }
            check(!SessionKeeper.shared.isKept(key) && SessionKeeper.shared.phases[key] == nil, "Let go: it ends, and the box sends on its own again")

            // Its window closed: let go, at once or, in the middle of a turn, once the turn is done.
            open.details.moveHere()
            settle(6) { SessionKeeper.shared.phases[key] == .ready }
            SessionKeeper.shared.windowClosed(key)
            settle(2) { SessionKeeper.shared.phases[key] == nil }
            check(!SessionKeeper.shared.isKept(key), "its window closed: it ends")
            func slowTurn() {
                open.details.moveHere()
                settle(6) { SessionKeeper.shared.phases[key] == .ready }
                open.details.draft = "Take your time"
                open.details.send()
                settle(2) { SessionKeeper.shared.phases[key] == .working }
            }
            slowTurn()
            SessionKeeper.shared.windowClosed(key)
            check(SessionKeeper.shared.isKept(key), "its window closed in the middle of a turn: kept until the turn's done")
            settle(5) { !SessionKeeper.shared.isKept(key) }
            check(!SessionKeeper.shared.isKept(key) && SessionKeeper.shared.phases[key] == nil, "and let go once it is")
            settle(2) { open.details.inFlight == nil }
            slowTurn()
            SessionKeeper.shared.windowClosed(key)
            SessionKeeper.shared.windowOpened(key)
            settle(5) { SessionKeeper.shared.phases[key] == .ready }
            check(SessionKeeper.shared.isKept(key), "opened again before the turn was done: kept after all")

            // Sent while it works: queued above the box, and sent as the turn ends.
            settle(2) { open.details.inFlight == nil }
            func prompts() -> [String] {
                ((try? String(contentsOfFile: standIn.path + ".told", encoding: .utf8)) ?? "").split(separator: "\n")
                    .compactMap { JSON.parse(String($0)) }.filter { $0["type"].string == "user" }
                    .compactMap { $0["message"]["content"][0]["text"].string }
            }
            open.details.draft = "Take your time"
            open.details.send()
            settle(2) { SessionKeeper.shared.phases[key] == .working }
            open.details.draft = "And then this"
            check(open.details.canSend && open.details.willQueue && !open.details.joinsTurn,
                  "while it works, the box takes another prompt, to wait its turn")
            open.details.send()
            check(open.details.queued.map(\.typed) == ["And then this"] && open.details.draft.isEmpty, "queued, and shown above the box")
            open.details.draft = "Still typing"
            settle(6) { open.details.queued.isEmpty && open.details.inFlight == nil }
            check(prompts().suffix(2) == ["Take your time", "And then this"] && open.details.draft == "Still typing",
                  "sent as the turn before it ended, in order, and what's being typed stays put: \(prompts().suffix(2))")
            open.details.draft = ""
            // Taken back, and Stop: what's queued comes back to the box.
            open.details.draft = "Take your time"
            open.details.send()
            settle(2) { SessionKeeper.shared.phases[key] == .working }
            open.details.draft = "Second thoughts"
            open.details.send()
            if let waiting = open.details.queued.first {
                open.details.unqueue(waiting.id)
            }
            check(open.details.queued.isEmpty && open.details.draft == "Second thoughts", "a queued prompt taken back: its words return to the box")
            open.details.send()
            open.details.stopSending()
            check(open.details.queued.isEmpty && open.details.draft == "Second thoughts", "Stop: what was queued comes back to the box")
            settle(5) { open.details.inFlight == nil }
            open.details.draft = ""
            SessionKeeper.shared.letGo(key)
            settle(2) { SessionKeeper.shared.phases[key] == nil && open.details.inFlight == nil }

            // Settings › Connect to the session when its window opens.
            open.details.connectIfWanted()
            check(SessionKeeper.shared.phases[key] == nil, "not asked for in Settings: the window doesn't connect by itself")
            open.details.connects = { true }
            open.details.connectIfWanted()
            settle(6) { SessionKeeper.shared.phases[key] == .ready }
            check(SessionKeeper.shared.isKept(key), "asked for: the window connects to its session")
            // The connection gone (the server not answering, say): connected again, not at once.
            SessionKeeper.shared.letGo(key)
            open.details.connectIfWanted(now: Date().addingTimeInterval(5))
            check(SessionKeeper.shared.phases[key] == nil, "dropped: not tried again at once")
            open.details.connectIfWanted(now: Date().addingTimeInterval(31))
            settle(6) { SessionKeeper.shared.phases[key] == .ready }
            check(SessionKeeper.shared.isKept(key), "and connected again half a minute on")
            open.details.letGo()
            settle(2) { SessionKeeper.shared.phases[key] == nil }
            open.details.connectIfWanted(now: Date().addingTimeInterval(120))
            check(!SessionKeeper.shared.isKept(key), "Let go by hand: it stays apart while the window's open")
            open.details.connects = { false }
        }

        print("@ for files, / for commands")
        if history?.isSubagent != true, sendable {
            let suggestions = open.details.composing.suggestions
            suggestions.details = open.details
            func settle(_ seconds: TimeInterval, _ done: () -> Bool) {
                let until = Date().addingTimeInterval(seconds)
                while Date() < until, !done() {
                    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                }
            }
            open.details.draft = "Look at @"
            suggestions.update()
            settle(15) { !suggestions.items.isEmpty }
            check(suggestions.kind == .file && !suggestions.items.isEmpty,
                  "@ offers the session folder's files and folders: \(suggestions.items.prefix(3).map(\.title)) of \(open.details.composing.projectFiles?.count ?? 0)")
            if let first = suggestions.items.first {
                suggestions.choose(first)
                check(open.details.draft == "Look at \(first.insert)" && !suggestions.isShown, "choosing one puts it in the box: \(open.details.draft)")
            }
            open.details.draft = "/"
            suggestions.update()
            settle(10) { open.details.composing.commands != nil }
            if agent == .claude {
                check(suggestions.kind == .command && suggestions.items.contains { $0.title == "/compact" },
                      "/ at the start offers the agent's commands: \(suggestions.items.prefix(4).map(\.title))")
            } else {
                check(suggestions.kind == .command, "/ at the start offers Codex's prompts: \(suggestions.items.map(\.title))")
            }
            open.details.draft = "a / in the middle"
            suggestions.update()
            check(!suggestions.isShown, "a / later in the text is just a /")
            open.details.draft = ""
            suggestions.hide()
        }

        print("Transparency, light and dark")
        controller.opacity = 0.7
        check(abs(open.window.alphaValue - 0.7) < 0.01, "an open agent window takes the opacity set: \(open.window.alphaValue)")
        controller.opacity = 1
        check(open.window.alphaValue == 1, "and back to opaque")
        check(AppearanceMode.dark.appearance?.name == .darkAqua && AppearanceMode.light.appearance?.name == .aqua
              && AppearanceMode.system.appearance == nil, "Dark, Light, or as macOS is")

        print("Pinning, and ⌘A in the message box")
        check(open.window.titlebarAccessoryViewControllers.contains { $0.layoutAttribute == .left && $0.view is NSHostingView<PinButton> },
              "the pin is in the title bar, after the window's buttons")
        open.details.togglePin()
        check(open.window.level == .floating && open.window.collectionBehavior.contains(.canJoinAllSpaces),
              "pinned, it floats above other windows, on every Space")
        open.details.togglePin()
        check(open.window.level == .normal && open.window.collectionBehavior.contains(.moveToActiveSpace)
              && !open.window.collectionBehavior.contains(.canJoinAllSpaces), "let go, it's an ordinary window again")

        print("Searching the prompts and answers")
        MainMenu.install()
        let searchMenu = NSApp.mainMenu?.items.compactMap(\.submenu).flatMap(\.items)
        check(searchMenu?.contains { $0.keyEquivalent == "f" && $0.action == #selector(SearchCommands.find(_:)) } == true
              && SearchCommands.shared.searchOf(open.window) === open.details.search, "⌘F searches the agent window in front")
        if let rows = history?.rows, let first = rows.first,
           let word = first.turn.text.split(whereSeparator: { !$0.isLetter }).first(where: { $0.count >= 5 }).map(String.init) {
            let search = open.details.search
            search.open()
            check(search.shown, "the search bar shows")
            search.search(word.uppercased(), in: rows)
            check(search.matches.contains(first.id) && search.currentID == search.matches.last,
                  "found whatever its case, starting at the newest: \(search.matches.count) of \(rows.count) prompts")
            let count = search.matches.count
            let moves = search.moves
            search.next()
            check(search.current == 0 && search.moves == moves + 1, "next after the newest: round to the first, and there")
            search.previous()
            check(search.current == count - 1, "and back")
            search.search("zzqx not in it", in: rows)
            check(search.matches.isEmpty && search.currentID == nil, "words it hasn't: not found")
            search.close()
            check(!search.shown && search.query.isEmpty && search.matches.isEmpty, "Done: the search ends, nothing marked")
        }
        let marked = HistorySearch.marked("A générator, the GENERATOR.", "generator")
        check(marked.runs.filter { $0.backgroundColor != nil }.count == 2, "in a prompt, each place marked, whatever its case and accents")

        print("Tabs: agent windows merged into one")
        let otherKey = "\(agent.rawValue)||tabs-\(session)"
        func settleTabs() {
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        }
        check(open.window.titlebarAccessoryViewControllers.contains { $0.layoutAttribute == .right
            && ($0.view.subviews.first as? NSButton)?.accessibilityLabel() == "Tabs" }, "a Tabs menu in the title bar")
        controller.show(key: otherKey, info: WindowInfo(title: "Another session", project: nil, path: path, finished: []))
        if let other = controller.open(otherKey) {
            settleTabs()
            check(open.window.tabbingIdentifier == other.window.tabbingIdentifier && (open.window.tabbedWindows?.count ?? 1) == 1,
                  "two agent windows, apart unless chosen")
            controller.mergeAll(into: open.window)
            settleTabs()
            check(open.window.tabbedWindows?.count == 2 && open.window.tabbedWindows?.contains(other.window) == true,
                  "Merge All Agent Windows: tabs of one window")
            check(other.window.tab.title == other.details.title && other.window.tab.title != agent.clientName,
                  "each tab says which session it is: \(other.window.tab.title ?? "")")
            // The window with its tabs, its title bar too.
            if let image, let view = open.window.contentView?.superview {
                open.window.makeKeyAndOrderFront(nil)
                open.window.appearance = NSAppearance(named: .aqua)
                settleTabs()
                view.layoutSubtreeIfNeeded()
                if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    let tabsImage = image.deletingPathExtension().appendingPathExtension("tabs.png")
                    try? rep.representation(using: .png, properties: [:])?.write(to: tabsImage)
                    print("  wrote \(tabsImage.path)")
                }
            }
            open.details.togglePin()
            check(other.window.level == .floating && other.details.pinned, "a pinned tab pins its whole window")
            open.details.togglePin()
            check(other.window.level == .normal && !other.details.pinned, "and letting go lets go of it all")
            other.window.moveTabToNewWindow(nil)
            settleTabs()
            check((open.window.tabbedWindows?.count ?? 1) == 1, "Move Tab to New Window: apart again")
            other.window.close()
            settleTabs()
        } else {
            check(false, "a second agent window opens")
        }
        controller.tabs.openAsTabs = true
        controller.show(key: otherKey, info: WindowInfo(title: "Another session", project: nil, path: path, finished: []))
        if let other = controller.open(otherKey) {
            settleTabs()
            check(open.window.tabbedWindows?.contains(other.window) == true, "opening as tabs: a new agent window joins the one in front")
            other.window.close()
            settleTabs()
        }
        controller.tabs.openAsTabs = false
        check(controller.open(otherKey) == nil && (open.window.tabbedWindows?.count ?? 1) == 1, "a tab closed: the window goes on with the rest")
        // The key goes from the Edit menu to the window's first responder; off
        // screen, Agent Buddy isn't the active app, so the two halves are checked.
        MainMenu.install()
        let selectAll = NSApp.mainMenu?.items.compactMap(\.submenu).flatMap(\.items)
            .first { $0.action == #selector(NSText.selectAll(_:)) }
        check(selectAll?.keyEquivalent == "a" && selectAll?.keyEquivalentModifierMask == [.command] && selectAll?.target == nil,
              "the Edit menu sends ⌘A to whatever has the keyboard")
        if let field = textFields(in: open.window.contentView).first(where: \.isEditable) {
            _ = open.window.makeFirstResponder(field)
            if let editor = field.currentEditor() as? NSTextView {
                editor.string = "select all of this"
                editor.setSelectedRange(NSRange(location: 3, length: 0))
                editor.selectAll(nil)
                check(open.window.firstResponder === editor && editor.selectedRange() == NSRange(location: 0, length: 18),
                      "and the message box, having it, selects all of its text: \(editor.selectedRange())")
                // Made narrower while you type: the words wrap inside the box, not past its edge.
                editor.string = ""
                editor.insertText(String(repeating: "wrap these words ", count: 12), replacementRange: editor.selectedRange())
                let wide = open.window.frame
                open.window.setContentSize(NSSize(width: 720, height: open.window.contentView?.frame.height ?? 720))
                RunLoop.main.run(until: Date().addingTimeInterval(0.5))
                open.window.setContentSize(NSSize(width: 400, height: open.window.contentView?.frame.height ?? 720))
                RunLoop.main.run(until: Date().addingTimeInterval(0.8))
                func right(_ view: NSView) -> CGFloat { view.convert(view.bounds, to: nil).maxX }
                let lines = editor.layoutManager.map { manager -> Int in
                    var count = 0
                    manager.enumerateLineFragments(forGlyphRange: manager.glyphRange(for: editor.textContainer!)) { _, _, _, _, _ in count += 1 }
                    return count
                } ?? 0
                check(right(editor) <= right(field) + 2 && (editor.textContainer?.containerSize.width ?? .infinity) <= field.bounds.width + 2,
                      "made narrower while typing, the words wrap inside the box (\(lines) lines)")
                open.window.setFrame(wide, display: false)
                editor.string = ""
            } else {
                check(false, "the message box takes the keyboard")
            }
        } else if history?.isSubagent == true || !sendable {
            check(true, sendable ? "a sub-agent's thread has no message box: it's sent to from the session that started it"
                                 : "\(agent.clientName)'s sessions aren't sent prompts from here: no message box")
        } else {
            check(false, "the window has a message box")
        }
        // The whole window, its title bar too.
        if let image, let view = open.window.contentView?.superview ?? open.window.contentView {
            // Drawn light on white, whatever the Mac's appearance, so the picture reads.
            open.window.appearance = NSAppearance(named: .aqua)
            view.wantsLayer = true
            view.layer?.backgroundColor = NSColor.white.cgColor
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            view.layoutSubtreeIfNeeded()
            if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                // A web view draws apart from the window's views: each answer's picture goes on top.
                for answer in webViews(in: view) {
                    var picture: NSImage?
                    var done = false
                    answer.takeSnapshot(with: nil) { image, _ in
                        picture = image
                        done = true
                    }
                    let asked = Date()
                    while !done, Date().timeIntervalSince(asked) < 5 {
                        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                    }
                    // Only the part the history's scroll view shows (a web view is flipped; a picture isn't).
                    let visible = answer.visibleRect
                    if let picture, !visible.isEmpty, let context = NSGraphicsContext(bitmapImageRep: rep) {
                        let source = NSRect(
                            x: visible.minX, y: answer.bounds.height - visible.maxY, width: visible.width, height: visible.height)
                        NSGraphicsContext.saveGraphicsState()
                        NSGraphicsContext.current = context
                        picture.draw(in: answer.convert(visible, to: view), from: source, operation: .sourceOver, fraction: 1)
                        NSGraphicsContext.restoreGraphicsState()
                    }
                }
                try? rep.representation(using: .png, properties: [:])?.write(to: image)
                print("  wrote \(image.path)")
            }
        }
        // Out of sight (covered, put away, in the Dock), a window doesn't read or look.
        check(open.details.isInSight(), "a self-test window counts as in sight")
        controller.offscreen = false
        open.window.orderOut(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        check(!open.details.isInSight(), "a window put away is out of sight: it doesn't read its log until it shows")
        controller.offscreen = true
        open.window.close()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        check(controller.open(key) == nil, "closing the window lets it go")

        // Opened from a job at an older prompt, then scrolled away to write: a
        // prompt landing in the session (one sent from here, say) follows the
        // conversation, and doesn't take the window back to the prompt it opened at.
        print("Opened at a job's prompt, then writing below")
        if sendable, let history, history.turns.count >= 2,
           let first = history.turns.min(by: { $0.askedAt < $1.askedAt }) {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ab-jump-\(UUID().uuidString)")
            let copy = folder.appendingPathComponent(url.lastPathComponent)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? FileManager.default.copyItem(at: url, to: copy)
            defer { try? FileManager.default.removeItem(at: folder) }
            let jumpKey = "\(agent.rawValue)||jump-\(session)"
            controller.show(key: jumpKey, info: WindowInfo(title: nil, project: nil, path: copy.path, finished: []), focus: first.id)
            if let jump = controller.open(jumpKey) {
                func settle(_ seconds: TimeInterval) {
                    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
                }
                let readBy = Date().addingTimeInterval(20)
                while Date() < readBy, jump.details.history == nil {
                    settle(0.1)
                }
                settle(2)
                let scroll = scrollViews(in: jump.window.contentView).max { $0.frame.height < $1.frame.height }
                // How far down the history is shown, from its top.
                func shown() -> CGFloat {
                    guard let scroll, let document = scroll.documentView else { return 0 }
                    let clip = scroll.contentView.bounds
                    return document.isFlipped ? clip.minY : document.frame.height - clip.maxY
                }
                func toBottom() {
                    guard let scroll, let document = scroll.documentView else { return }
                    let clip = scroll.contentView.bounds
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: document.isFlipped ? max(0, document.frame.height - clip.height) : 0))
                    scroll.reflectScrolledClipView(scroll.contentView)
                }
                let atFocus = shown()
                check(jump.details.focus == nil, "the job's prompt, once shown, is let go of")
                // Down to the end, again once the answers there have their heights.
                toBottom()
                settle(1.5)
                toBottom()
                settle(0.5)
                let atBottom = shown()
                if atBottom - atFocus < (scroll?.contentView.bounds.height ?? 0) / 2 {
                    check(true, "(the session is too short to tell: \(Int(atFocus)) to \(Int(atBottom)) pt)")
                } else {
                    check(atFocus < atBottom / 2, "it opens at the job's prompt (\(Int(atFocus)) pt down, of \(Int(atBottom)))")
                    // Anything redrawing the window (its clock ticks every 5 seconds) leaves it where it is.
                    jump.details.objectWillChange.send()
                    settle(0.6)
                    check(abs(shown() - atBottom) < 2, "a redraw leaves it where it is (\(Int(shown())) pt down)")
                    // Typed a key at a time, as you do.
                    for typed in "Writing a follow-up" {
                        jump.details.draft.append(typed)
                        settle(0.03)
                    }
                    settle(0.6)
                    let written = shown()
                    check(abs(written - atBottom) < 2, "writing in the box leaves it where it is (\(Int(written)) pt down)")
                    // A prompt lands in the log, as one sent from here does.
                    let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: TimeZone(secondsFromGMT: 0)!, formatOptions: [.withInternetDateTime, .withFractionalSeconds])
                    let line: [String: Any]
                    if agent == .codex {
                        line = ["timestamp": stamp, "type": "event_msg",
                                "payload": ["type": "user_message", "message": "A prompt from the self-test", "images": [String]()]]
                    } else {
                        let last = ((try? String(contentsOf: copy, encoding: .utf8)) ?? "").split(separator: "\n")
                            .reversed().lazy.compactMap { JSON.parse(String($0))?["uuid"].nonEmptyString }.first
                        line = ["type": "user", "uuid": UUID().uuidString.lowercased(), "parentUuid": last ?? NSNull(), "timestamp": stamp,
                                "isSidechain": false, "message": ["role": "user", "content": "A prompt from the self-test"]]
                    }
                    if let data = try? JSONSerialization.data(withJSONObject: line), let handle = try? FileHandle(forWritingTo: copy) {
                        handle.seekToEndOfFile()
                        handle.write(Data("\n".utf8) + data + Data("\n".utf8))
                        try? handle.close()
                    }
                    let before = jump.details.history?.turns.count ?? 0
                    jump.details.load()
                    let landBy = Date().addingTimeInterval(10)
                    while Date() < landBy, (jump.details.history?.turns.count ?? 0) <= before {
                        settle(0.1)
                    }
                    settle(1.5)
                    check((jump.details.history?.turns.count ?? 0) == before + 1, "the new prompt is read")
                    // The new prompt is the last: shown from its top, which is as far down as the history goes.
                    let after = shown()
                    let end = max(0, (scroll?.documentView?.frame.height ?? 0) - (scroll?.contentView.bounds.height ?? 0))
                    check(after >= end - 2 && after > atFocus + 2,
                          "a prompt landing shows it, not the job's prompt again (\(Int(after)) pt down, the end \(Int(end)); the job's prompt at \(Int(atFocus)))")
                }
                jump.window.close()
                settle(0.2)
            } else {
                check(false, "a window opens at a job's prompt")
            }
        }
        print(failures == 0 ? "History self-test passed." : "\(failures) history checks failed.")
        return failures == 0 ? 0 : 1
    }

    /// The web views in a window: the answers.
    static func webViews(in view: NSView?) -> [WKWebView] {
        guard let view else { return [] }
        return (view as? WKWebView).map { [$0] } ?? [] + view.subviews.flatMap { webViews(in: $0) }
    }

    /// The scroll views in a window: the history's is the tallest.
    static func scrollViews(in view: NSView?) -> [NSScrollView] {
        guard let view else { return [] }
        return (view as? NSScrollView).map { [$0] } ?? [] + view.subviews.flatMap { scrollViews(in: $0) }
    }

    /// The text fields in a window, however deep SwiftUI puts them.
    static func textFields(in view: NSView?) -> [NSTextField] {
        guard let view else { return [] }
        return (view as? NSTextField).map { [$0] } ?? [] + view.subviews.flatMap { textFields(in: $0) }
    }
}
