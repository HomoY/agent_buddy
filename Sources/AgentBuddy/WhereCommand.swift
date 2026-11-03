import AppKit
import AgentBuddyCore

/// `AgentBuddy --where LOG [--on SERVER] [--agent claude|codex|copilot]`: where a
/// session runs and what Jump would do, without jumping, and what sending it a
/// prompt would run, without sending. LOG is a session log on this Mac, or with
/// --on, its path on the server, or just the session's id.
@MainActor
enum WhereCommand {
    static func run(_ arguments: [String]) -> Int32 {
        guard let index = arguments.firstIndex(of: "--where"), index + 1 < arguments.count else { return 2 }
        let path = arguments[index + 1]
        let host = arguments.firstIndex(of: "--on").flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
        let named = arguments.firstIndex(of: "--agent").flatMap { $0 + 1 < arguments.count ? Agent(rawValue: arguments[$0 + 1]) : nil }
        let agent: Agent = named ?? (path.contains("/.codex/") ? .codex : (path.hasSuffix("events.jsonl") ? .copilot : .claude))
        let isID = !path.contains("/")
        let url = URL(fileURLWithPath: path)
        let sessionID = isID ? path
            : (agent == .copilot ? url.deletingLastPathComponent().lastPathComponent : url.deletingPathExtension().lastPathComponent)
        let read: Result<SessionHistory, ReadError>
        if let host {
            read = RemoteHistory.fetch(host: host, agent: agent, path: isID ? nil : path, sessionID: sessionID)
        } else if isID, let found = SessionHistoryReader.locate(agent: agent, sessionID: sessionID) {
            read = SessionHistoryReader.read(agent: agent, path: found)
        } else {
            read = SessionHistoryReader.read(agent: agent, path: path)
        }
        guard case .success(let history) = read else {
            if case .failure(let error) = read {
                print("couldn't read the session: \(error.message)")
            }
            return 1
        }
        print("\(agent.clientName) session \(history.sessionID)\(host.map { " on \($0)" } ?? "")")
        print("  client: \(history.client ?? "-"); folders: \(history.folders.joined(separator: ", "))")
        print("  log: \(history.logPath ?? "-")")
        print("  \(history.turns.count) prompts; title: \(history.title ?? "-")")
        let start = Date()
        let result = PlaceFinder.find(PlaceFinder.Request(
            agent: agent, sessionID: history.sessionID, host: host, client: history.client, folders: history.folders))
        let took = String(format: "%.0f ms", Date().timeIntervalSince(start) * 1000)
        switch result {
        case .found(let place):
            print("  runs in \(place.appName) (\(place.bundleID)), \(place.detail); found in \(took)")
            switch place.move {
            case let .editorWindow(cli, folderURI, conversation):
                print("  Jump: \(cli?.lastPathComponent ?? "open") --folder-uri \(folderURI)")
                if let conversation {
                    print("        then open \(conversation.absoluteString)")
                }
            case .zed(let url), .link(let url):
                print("  Jump: open \(url.absoluteString) with \(place.appName)")
            case .terminalTab(let tty):
                print("  Jump: select the \(place.appName) tab on \(tty)")
            case .activate:
                print("  Jump: bring \(place.appName) forward")
            }
        case .closed(let reason):
            print("  not open: \(reason) (\(took))")
        }
        // What sending it a prompt would run: shown, never run.
        switch PromptSender.plan(PromptSender.Request(history: history, host: host, prompt: "…")) {
        case .success(let plan):
            let program = host.map { "\(plan.command) on \($0)" }
                ?? (plan.command == "codex" ? Executables.newest("codex") : Executables.find(plan.command))?.path
                ?? "\(plan.command) (not found on this Mac)"
            print("  Send: in \(plan.folder), \(plan.permissions); \(plan.asks)")
            print("        \(program) \(plan.arguments.joined(separator: " ")) < the prompt")
            if let narrowed = plan.narrowed {
                print("        \(narrowed)")
            }
        case .failure(let problem):
            print("  Send: \(problem.message)")
        }
        return 0
    }
}
