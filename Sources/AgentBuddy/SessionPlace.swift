import AppKit
import AgentBuddyCore

/// Where an agent session runs, and how to bring it forward.
struct SessionPlace: Equatable {
    enum Move: Equatable {
        /// VS Code, Cursor, Windsurf…: focus the window with this folder (a
        /// file:// or vscode-remote:// URI) through the editor's command-line
        /// tool, then, if given, open the conversation in it.
        case editorWindow(cli: URL?, folderURI: String, conversation: URL?)
        /// Zed: open the project root it has open, so Zed focuses that window.
        case zed(URL)
        /// A link the app opens itself, such as codex://threads/<id>.
        case link(URL)
        /// Terminal or iTerm2: select the tab on this terminal device.
        case terminalTab(tty: String)
        /// Just bring the app forward.
        case activate
    }

    /// "VS Code", "Zed", "Terminal"…
    var appName: String
    var appURL: URL
    var bundleID: String
    var move: Move
    /// Lands on the window (or the conversation), not just the app.
    var exact: Bool
    /// "the head_show window", "score on 203.0.113.7"…
    var detail: String
}

/// Whether the session's window could be found, and if not, why.
enum PlaceResult: Equatable {
    case found(SessionPlace)
    case closed(String)
}

/// Finds where a session runs: the agent's process and the app above it, the
/// editor windows VS Code and Zed have open, and SSH connections to a server.
/// Blocking (a few milliseconds to read the process table and the editors'
/// window lists): call it off the main thread.
enum PlaceFinder {
    struct Request: Equatable {
        var agent: Agent
        var sessionID: String
        /// The server, for a job that ran on one.
        var host: String?
        var client: String?
        var folders: [String]
    }

    static func find(_ request: Request) -> PlaceResult {
        let table = ProcessTable.recent()
        let apps = RunningApps.now()
        if let host = request.host {
            return remote(request, host: host, table: table, apps: apps)
        }
        return local(request, table: table, apps: apps)
    }

    // MARK: - On this Mac

    private static func local(_ request: Request, table: ProcessTable, apps: RunningApps) -> PlaceResult {
        // The Codex app opens a thread by its id.
        if request.client == "Codex Desktop" || request.client?.lowercased().contains("desktop") == true && request.agent == .codex,
           let codex = apps.first(bundleIDs: ["com.openai.codex", "com.openai.chat"]),
           let link = URL(string: "codex://threads/\(request.sessionID)") {
            return .found(SessionPlace(
                appName: codex.name, appURL: codex.url, bundleID: codex.bundleID, move: .link(link), exact: true,
                detail: "this thread"))
        }
        let folder = request.folders.first
        // The app above a live agent process in the session's folder.
        let hosts = table.agentProcesses(request.agent, in: request.folders).compactMap { pid -> (RunningApps.App, Int32)? in
            apps.host(of: pid, in: table).map { ($0, pid) }
        }
        let preferred = hosts.first { hint(request.client, matches: $0.0) } ?? hosts.first
        if let (app, pid) = preferred {
            if let family = EditorFamily.of(app.bundleID), let folder,
               let window = EditorWindows.recent(family).bestMatch(for: request.folders, host: nil) {
                return .found(editorPlace(family, app: app, window: window, request: request, folder: folder))
            }
            if app.bundleID.hasPrefix("dev.zed.Zed"), let root = ZedWindows.recent(app.bundleID).bestMatch(for: request.folders, host: nil) {
                return .found(zedPlace(app: app, workspace: root))
            }
            if let tty = table.entries[pid]?.tty, Terminals.scriptable.contains(app.bundleID) {
                return .found(SessionPlace(
                    appName: app.name, appURL: app.url, bundleID: app.bundleID, move: .terminalTab(tty: tty), exact: true,
                    detail: "its tab"))
            }
            return .found(SessionPlace(
                appName: app.name, appURL: app.url, bundleID: app.bundleID, move: .activate, exact: false,
                detail: folder.map { "working in \(URL(fileURLWithPath: $0).lastPathComponent)" } ?? ""))
        }
        // No live agent: an editor window with the folder still open (the
        // conversation can be opened there again).
        for family in EditorFamily.all {
            guard let app = apps.first(bundleIDs: family.bundleIDs),
                  let window = EditorWindows.recent(family).bestMatch(for: request.folders, host: nil),
                  hint(request.client, matches: app) || request.client == nil
            else { continue }
            return .found(editorPlace(family, app: app, window: window, request: request, folder: folder ?? window.path))
        }
        for app in apps.all where app.bundleID.hasPrefix("dev.zed.Zed") {
            if let root = ZedWindows.recent(app.bundleID).bestMatch(for: request.folders, host: nil) {
                return .found(zedPlace(app: app, workspace: root))
            }
        }
        let name = folder.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "this folder"
        return .closed("\(request.agent.clientName) isn't running in \(name) anymore, and no editor window has it open.")
    }

    /// Whether the app is the kind the session's client runs in.
    private static func hint(_ client: String?, matches app: RunningApps.App) -> Bool {
        guard let client = client?.lowercased() else { return false }
        if client.contains("vscode") || client == "copilot-agent" {
            return EditorFamily.of(app.bundleID) != nil
        }
        if client == "sdk-ts" || client.contains("acp") {
            return app.bundleID.hasPrefix("dev.zed.Zed")
        }
        if client.contains("desktop") {
            return app.bundleID == "com.anthropic.claudefordesktop" || app.bundleID == "com.openai.codex"
        }
        if client == "cli" || client.contains("cli") {
            return EditorFamily.of(app.bundleID) == nil && !app.bundleID.hasPrefix("dev.zed.Zed")
        }
        return false
    }

    // MARK: - On a server

    private static func remote(_ request: Request, host: String, table: ProcessTable, apps: RunningApps) -> PlaceResult {
        var best: (place: SessionPlace, depth: Int)?
        func offer(_ place: SessionPlace, depth: Int) {
            if best == nil || depth > best!.depth {
                best = (place, depth)
            }
        }
        for family in EditorFamily.all {
            guard let app = apps.first(bundleIDs: family.bundleIDs),
                  let window = EditorWindows.recent(family).bestMatch(for: request.folders, host: host)
            else { continue }
            offer(editorPlace(family, app: app, window: window, request: request, folder: request.folders.first ?? window.path),
                  depth: window.depth)
        }
        for app in apps.all where app.bundleID.hasPrefix("dev.zed.Zed") {
            if let root = ZedWindows.recent(app.bundleID).bestMatch(for: request.folders, host: host) {
                offer(zedPlace(app: app, workspace: root), depth: root.depth)
            }
        }
        if let best {
            return .found(best.place)
        }
        // `ssh server` typed in Terminal or iTerm2.
        for pid in table.sshProcesses(to: host) {
            guard let tty = table.entries[pid]?.tty, let app = apps.host(of: pid, in: table),
                  Terminals.scriptable.contains(app.bundleID)
            else { continue }
            return .found(SessionPlace(
                appName: app.name, appURL: app.url, bundleID: app.bundleID, move: .terminalTab(tty: tty), exact: true,
                detail: "its ssh tab"))
        }
        // Connected from somewhere Agent Buddy can't steer: bring that app forward.
        for pid in table.sshProcesses(to: host) {
            if let app = apps.host(of: pid, in: table) {
                return .found(SessionPlace(
                    appName: app.name, appURL: app.url, bundleID: app.bundleID, move: .activate, exact: false,
                    detail: "connected to \(host)"))
            }
        }
        return .closed("No VS Code, Zed or terminal window is connected to \(host).")
    }

    // MARK: - Places

    private static func editorPlace(
        _ family: EditorFamily, app: RunningApps.App, window: EditorWindows.Window, request: Request, folder: String
    ) -> SessionPlace {
        var conversation: URL?
        if let scheme = family.scheme(app.url) {
            switch (request.agent, request.client) {
            case (.claude, "claude-vscode"?):
                var parts = URLComponents()
                parts.scheme = scheme
                parts.host = "anthropic.claude-code"
                parts.path = "/open"
                parts.queryItems = [URLQueryItem(name: "session", value: request.sessionID)]
                conversation = parts.url
            case (.codex, "codex_vscode"?):
                conversation = URL(string: "\(scheme)://openai.chatgpt/local/\(request.sessionID)")
            default:
                break
            }
        }
        let name = URL(fileURLWithPath: window.path).lastPathComponent
        return SessionPlace(
            appName: family.name, appURL: app.url, bundleID: app.bundleID,
            move: .editorWindow(cli: family.cli(app.url), folderURI: window.uri, conversation: conversation), exact: true,
            detail: window.host.map { "\(name) on \($0)" } ?? "the \(name) window")
    }

    private static func zedPlace(app: RunningApps.App, workspace: ZedWindows.Workspace) -> SessionPlace {
        let name = URL(fileURLWithPath: workspace.root).lastPathComponent
        let target: URL
        if let host = workspace.host {
            var authority = host
            if let user = workspace.user {
                authority = "\(user)@\(host)"
            }
            if let port = workspace.port {
                authority += ":\(port)"
            }
            let path = workspace.root.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? workspace.root
            target = URL(string: "zed://ssh/\(authority)\(path.hasPrefix("/") ? path : "/" + path)") ?? URL(fileURLWithPath: workspace.root)
        } else {
            target = URL(fileURLWithPath: workspace.root, isDirectory: true)
        }
        return SessionPlace(
            appName: "Zed", appURL: app.url, bundleID: app.bundleID, move: .zed(target), exact: true,
            detail: workspace.host.map { "\(name) on \($0)" } ?? "the \(name) window")
    }
}

// MARK: - Apps

/// The apps running now, found by the bundle their processes run from.
struct RunningApps {
    struct App: Equatable {
        var name: String
        var bundleID: String
        var url: URL
    }

    let all: [App]
    private let byPath: [String: App]

    init() {
        let me = Bundle.main.bundleIdentifier
        var apps: [App] = []
        for running in NSWorkspace.shared.runningApplications where running.activationPolicy == .regular {
            guard let url = running.bundleURL, let id = running.bundleIdentifier, id != me else { continue }
            apps.append(App(name: Self.shortName(running.localizedName ?? url.deletingPathExtension().lastPathComponent, id),
                            bundleID: id, url: url))
        }
        all = apps
        byPath = Dictionary(apps.map { ($0.url.standardizedFileURL.path, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// The apps running now. Kept until one starts or quits, or a minute goes
    /// by: asking each app for its bundle is slow, and an open agent window
    /// looks for where its session runs every few seconds.
    static func now() -> RunningApps {
        RunningAppsCache.shared.apps()
    }

    func first(bundleIDs: [String]) -> App? {
        all.first { bundleIDs.contains($0.bundleID) }
    }

    /// The app whose bundle the process, or one above it, runs from.
    func host(of pid: Int32, in table: ProcessTable) -> App? {
        for ancestor in table.lineage(of: pid) {
            guard let path = ProcessTable.path(of: ancestor), let bundle = ProcessTable.appBundle(containing: path) else { continue }
            if let app = byPath[URL(fileURLWithPath: bundle).standardizedFileURL.path] {
                return app
            }
        }
        return nil
    }

    private static func shortName(_ name: String, _ id: String) -> String {
        switch id {
        case "com.microsoft.VSCode": return "VS Code"
        case "com.microsoft.VSCodeInsiders": return "VS Code Insiders"
        case "com.openai.codex": return "Codex"
        case "com.anthropic.claudefordesktop": return "Claude"
        default: return name
        }
    }
}

private final class RunningAppsCache: @unchecked Sendable {
    static let shared = RunningAppsCache()
    private let lock = NSLock()
    private var kept: (apps: RunningApps, at: Date)?
    private var observers: [NSObjectProtocol] = []

    private init() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in self?.forget() })
        }
    }

    func apps() -> RunningApps {
        lock.lock()
        defer { lock.unlock() }
        if let kept, Date().timeIntervalSince(kept.at) < 60 {
            return kept.apps
        }
        let apps = RunningApps()
        kept = (apps, Date())
        return apps
    }

    private func forget() {
        lock.lock()
        defer { lock.unlock() }
        kept = nil
    }
}

extension EditorWindows {
    /// The editor's windows now, or as they were a moment ago (agent windows share a look).
    static func recent(_ family: EditorFamily) -> EditorWindows {
        recently.value(family.bundleIDs.joined(separator: ",")) { vscode(family) }
    }

    private static let recently = Recently<String, EditorWindows>(lifetime: 3)
}

extension ZedWindows {
    /// Zed's workspaces now, or as they were a moment ago (agent windows share a look).
    static func recent(_ bundleID: String) -> ZedWindows {
        recently.value(bundleID) { read(bundleID) }
    }

    private static let recently = Recently<String, ZedWindows>(lifetime: 3)
}

/// Terminals whose tabs can be picked by their terminal device.
enum Terminals {
    static let scriptable: Set<String> = ["com.apple.Terminal", "com.googlecode.iterm2"]
}
