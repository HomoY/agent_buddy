import AgentBuddyCore
import AppKit

/// Sessions opened in Agent Buddy ("Open here" in an agent window): each kept
/// open in the background, the agent in its long-running mode, for the window's
/// message box (and Agent Buddy Remote) to send into. Nothing is kept until you
/// move it here; "Let go", closing its window, or quitting ends it. A Codex
/// thread open in another program is waited for, and taken once that program
/// lets go of it.
@MainActor
final class SessionKeeper: ObservableObject {
    static let shared = SessionKeeper()

    enum Phase: Equatable {
        /// Another program has the Codex thread open: "VS Code".
        case waiting(String)
        case opening
        case ready
        case working
        /// It couldn't open, or ended by itself: why.
        case failed(String)
    }

    @Published private(set) var phases: [String: Phase] = [:]
    /// The last turn's problem, by window.
    @Published private(set) var problems: [String: String] = [:]
    private var sessions: [String: KeptSession] = [:]
    /// Moves under way, each with its own token (a move cancelled and begun again is a new one).
    private var moving: [String: (token: UUID, task: Task<Void, Never>)] = [:]
    /// Windows closed in the middle of a turn: let go once it's done.
    private var lettingGo: Set<String> = []
    /// Whether an agent window's session is at work, and its title: what taking a thread over would stop.
    var isWorking: (String) -> Bool = { _ in false }
    var titleOf: (String) -> String? = { _ in nil }
    /// For the self-test: a stand-in agent in place of the real one, here.
    var standIn: URL?

    private init() {
        // Quitting lets go of every session (their agents end, and Codex's holds with them).
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.closeAll() }
        }
    }

    func isKept(_ key: String) -> Bool {
        sessions[key] != nil
    }

    /// Opens the session here, once no other program holds a Codex thread:
    /// tried again every few seconds while one does.
    func moveHere(_ key: String, request: PromptSender.Request) {
        guard sessions[key] == nil, moving[key] == nil else { return }
        phases[key] = .opening
        Diagnostics.log("keep: moving \(key) here")
        let token = UUID()
        let task = Task { [weak self] in
            while !Task.isCancelled {
                // Who holds the Codex thread, here or on the server: wait while anyone does.
                if request.agent == .codex {
                    let holder = await Task.detached(operation: { () -> String? in
                        if let host = request.host {
                            return RemoteHistory.codexWriter(host: host, thread: request.sessionID)
                        }
                        return CodexWriter.holder(thread: request.sessionID)
                    }).value
                    if let holder {
                        if self?.phases[key] != .waiting(holder) {
                            Diagnostics.log("keep: \(key) waits for \(holder) to let go of the thread")
                        }
                        self?.phases[key] = .waiting(holder)
                        try? await Task.sleep(nanoseconds: 5_000_000_000)
                        continue
                    }
                }
                if case .waiting? = self?.phases[key] {
                } else {
                    self?.phases[key] = .opening
                }
                let standIn = self?.standIn
                let opened = await Task.detached(operation: { KeptSession.open(request, executable: request.host == nil ? standIn : nil) }).value
                guard case .success(let kept) = opened else {
                    if case .failure(let problem) = opened {
                        self?.phases[key] = .failed(problem.message)
                    }
                    break
                }
                while kept.state == .opening, !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                if Task.isCancelled {
                    kept.close()
                    break
                }
                switch kept.state {
                case .closed(let why?) where why.hasPrefix("Codex has this thread open elsewhere"):
                    // Held on the server: wait, and try again.
                    if case .waiting? = self?.phases[key] {
                    } else {
                        self?.phases[key] = .waiting("another program")
                    }
                    try? await Task.sleep(nanoseconds: 6_000_000_000)
                    continue
                case .closed(let why):
                    self?.phases[key] = .failed(why ?? "It stopped.")
                default:
                    self?.kept(kept, as: key)
                }
                break
            }
            if self?.moving[key]?.token == token {
                self?.moving[key] = nil
            }
        }
        moving[key] = (token, task)
    }

    /// Takes the thread from the program holding it, after asking: stops that
    /// program's Codex (it lets go of every thread it holds; they open again
    /// there), then moves the session here. With nobody holding it: Move here.
    func takeOver(_ key: String, request: PromptSender.Request) {
        guard request.agent == .codex else { return moveHere(key, request: request) }
        Task { [weak self] in
            let holder = await Task.detached(operation: { () -> CodexHolder? in
                if let host = request.host {
                    return RemoteHistory.codexHolder(host: host, thread: request.sessionID)
                }
                return CodexWriter.holderProcess(thread: request.sessionID)
            }).value
            guard let self else { return }
            guard let holder, holder.pid > 0, holder.name != "another program" else {
                return self.moveHere(key, request: request)
            }
            let others = holder.threads.filter { $0 != request.sessionID }.map { "codex|\(request.host ?? "")|\($0)" }
            let busy = others.filter(self.isWorking).map { self.titleOf($0) ?? "a chat" }
            guard Self.confirmTakeOver(holder, host: request.host, others: others.count, busy: busy) else { return }
            self.moving.removeValue(forKey: key)?.task.cancel()
            self.phases[key] = .opening
            Diagnostics.log("keep: stopping \(holder.name)'s Codex (pid \(holder.pid)) to take \(key)")
            let stopped = await Task.detached(operation: { () -> Bool in
                if let host = request.host {
                    return RemoteHistory.stopCodex(host: host, thread: request.sessionID, pid: holder.pid)
                }
                return CodexWriter.stop(thread: request.sessionID, pid: holder.pid)
            }).value
            guard stopped else {
                Diagnostics.log("keep: \(holder.name)'s Codex didn't let go of \(key)")
                self.phases[key] = .failed("\(holder.name)'s Codex didn't let go. \(Self.howToFree(holder.name))")
                return
            }
            self.moveHere(key, request: request)
        }
    }

    private static func confirmTakeOver(_ holder: CodexHolder, host: String?, others: Int, busy: [String]) -> Bool {
        let place = host.map { " on \($0)" } ?? ""
        let alert = NSAlert()
        alert.messageText = "Take this thread from \(holder.name)?"
        var text: String
        switch holder.name {
        case "Codex in a terminal":
            text = "Agent Buddy ends the Codex session in that terminal\(place), which lets go of the thread, and keeps the thread open here."
        case "the Codex app":
            text = "Agent Buddy stops the Codex app's Codex\(place), which lets go of the thread, and keeps the thread open here. The app starts it again when you use it."
        default:
            text = "Agent Buddy stops \(holder.name)'s Codex\(place), which lets go of the thread, and keeps the thread open here. "
                + "\(holder.name) starts its Codex again when you next use it there, but can't write to this thread while it's here."
        }
        if others > 0 {
            text += " It has \(others) other chat\(others == 1 ? "" : "s") open too: \(others == 1 ? "it's" : "they're") kept, and \(others == 1 ? "opens" : "open") again there."
        }
        if !busy.isEmpty {
            text += "\n\nIt's working on \(busy.joined(separator: ", ")) right now: that stops too."
        }
        alert.informativeText = text
        alert.alertStyle = busy.isEmpty ? .informational : .warning
        alert.addButton(withTitle: "Take It")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func kept(_ session: KeptSession, as key: String) {
        sessions[key] = session
        phases[key] = .ready
        Diagnostics.log("keep: \(key) is open here")
        session.onChange = { [weak self] state in
            MainActor.assumeIsolated { self?.changed(key, state, session) }
        }
    }

    private func changed(_ key: String, _ state: KeptSession.State, _ session: KeptSession) {
        guard sessions[key] === session else { return }
        switch state {
        case .opening:
            phases[key] = .opening
        case .ready:
            if lettingGo.contains(key) {
                return letGo(key)
            }
            // The problem first: whoever hears "ready" reads it.
            problems[key] = session.problem
            phases[key] = .ready
        case .working:
            phases[key] = .working
            problems[key] = nil
        case .closed(let why):
            sessions[key] = nil
            lettingGo.remove(key)
            phases[key] = why.map(Phase.failed)
            Diagnostics.log("keep: \(key) closed\(why.map { ": \($0)" } ?? "")")
        }
    }

    /// Shows a window's session as kept (or not) without opening it (the tour's pictures only).
    func preview(_ phase: Phase?, for key: String) {
        phases[key] = phase
    }

    /// Its window closed: let go now, or once the turn under way is done.
    func windowClosed(_ key: String) {
        guard sessions[key] != nil || moving[key] != nil else { return }
        if phases[key] == .working {
            lettingGo.insert(key)
            Diagnostics.log("keep: \(key)'s window closed; letting go once its turn is done")
        } else {
            letGo(key)
        }
    }

    /// Its window open again before the turn was done: kept after all.
    func windowOpened(_ key: String) {
        lettingGo.remove(key)
    }

    /// Ends it, or stops waiting to; `now`, as Agent Buddy quits: its connection
    /// closed before the app ends, which ends the agent.
    func letGo(_ key: String, now: Bool = false) {
        moving.removeValue(forKey: key)?.task.cancel()
        lettingGo.remove(key)
        if let session = sessions.removeValue(forKey: key) {
            if now {
                session.closeNow()
            } else {
                session.close()
            }
        }
        phases[key] = nil
        problems[key] = nil
        Diagnostics.log("keep: let go of \(key)")
    }

    func send(_ key: String, _ prompt: String) -> Result<Void, ReadError> {
        guard let session = sessions[key] else { return .failure(ReadError("The session isn't open here.")) }
        return session.send(prompt)
    }

    /// As the message box sends it: its choices, and images on this Mac.
    func send(_ key: String, _ request: PromptSender.Request, images: [URL]) -> Result<Void, ReadError> {
        guard let session = sessions[key] else { return .failure(ReadError("The session isn't open here.")) }
        return session.send(request, images: images)
    }

    func interrupt(_ key: String) {
        sessions[key]?.interrupt()
    }

    /// Codex: a prompt added to the turn under way; `then(false)` if it couldn't be.
    func steer(_ key: String, _ request: PromptSender.Request, images: [URL], then: @escaping @MainActor @Sendable (Bool) -> Void) {
        guard let session = sessions[key] else { return then(false) }
        session.steer(request, images: images) { joined in
            Task { @MainActor in then(joined) }
        }
    }

    /// What makes a program let go of a Codex thread.
    static func howToFree(_ holder: String) -> String {
        switch holder {
        case "VS Code", "Cursor", "Windsurf":
            return "Closing its Codex tab isn't enough: start a new chat in \(holder)'s Codex panel, or reload that window (Developer: Reload Window)."
        case "the Codex app":
            return "Open another chat in the Codex app, or quit it."
        case "Codex in a terminal":
            return "End that Codex session (/quit or Ctrl-C twice)."
        default:
            return "Close the thread there."
        }
    }

    func closeAll() {
        for key in Array(sessions.keys) + Array(moving.keys) {
            letGo(key, now: true)
        }
    }
}
