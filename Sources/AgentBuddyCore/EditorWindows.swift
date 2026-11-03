import Foundation
import SQLite3

// The editor windows open now, read from the editors' own state, so Agent Buddy
// can tell whether a session's window is open and focus exactly that one.

// MARK: - VS Code and its relatives

/// An editor built on VS Code: its app, its settings folder and its command-line tool.
public struct EditorFamily: Sendable {
    public var name: String
    public var bundleIDs: [String]
    /// Under ~/Library/Application Support.
    public var support: String
    public var tool: String

    public static let all = [
        EditorFamily(name: "VS Code", bundleIDs: ["com.microsoft.VSCode"], support: "Code", tool: "code"),
        EditorFamily(name: "VS Code Insiders", bundleIDs: ["com.microsoft.VSCodeInsiders"], support: "Code - Insiders", tool: "code-insiders"),
        EditorFamily(name: "Cursor", bundleIDs: ["com.todesktop.230313mzl4w4u92"], support: "Cursor", tool: "cursor"),
        EditorFamily(name: "Windsurf", bundleIDs: ["com.exafunction.windsurf"], support: "Windsurf", tool: "windsurf"),
        EditorFamily(name: "VSCodium", bundleIDs: ["com.vscodium", "com.vscodium.VSCodium"], support: "VSCodium", tool: "codium"),
    ]

    public static func of(_ bundleID: String) -> EditorFamily? {
        all.first { $0.bundleIDs.contains(bundleID) }
    }

    /// The command-line tool inside the app, which asks the running editor to
    /// focus a window (an `open` link would make it ask for confirmation).
    public func cli(_ app: URL) -> URL? {
        let bin = app.appendingPathComponent("Contents/Resources/app/bin")
        let named = bin.appendingPathComponent(tool)
        if FileManager.default.isExecutableFile(atPath: named.path) {
            return named
        }
        let others = (try? FileManager.default.contentsOfDirectory(at: bin, includingPropertiesForKeys: nil)) ?? []
        return others.first { !$0.lastPathComponent.contains("tunnel") && FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// The app's link scheme ("vscode", "cursor"…), for its extensions' links.
    public func scheme(_ app: URL) -> String? {
        let types = Bundle(url: app)?.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]]
        return types?.lazy.compactMap { ($0["CFBundleURLSchemes"] as? [String])?.first }.first
    }
}

/// The windows a VS Code-family editor has open, from its `storage.json`
/// (`windowsState`), which it rewrites as windows open, close and take focus.
public struct EditorWindows: Sendable {
    public struct Window: Equatable, Sendable {
        /// "file:///Users/me/app" or "vscode-remote://ssh-remote%2Bserver/home/me/app".
        public var uri: String
        public var path: String
        /// The server, for a Remote-SSH window.
        public var host: String?
        /// How deep the match was: the root's length.
        public var depth: Int { path.count }
    }

    public var windows: [Window]

    public static func vscode(_ family: EditorFamily, home: URL = Environment.home) -> EditorWindows {
        let file = home.appendingPathComponent("Library/Application Support/\(family.support)/User/globalStorage/storage.json")
        guard let data = try? Data(contentsOf: file), let json = JSON.parse(data) else { return EditorWindows(windows: []) }
        return parse(json)
    }

    public static func parse(_ json: JSON) -> EditorWindows {
        let state = json["windowsState"]
        var seen = Set<String>()
        var windows: [Window] = []
        for entry in [state["lastActiveWindow"]] + state["openedWindows"].array {
            guard let uri = entry["folder"].nonEmptyString, seen.insert(uri).inserted,
                  let components = URLComponents(string: uri)
            else { continue }
            let path = components.percentEncodedPath.removingPercentEncoding ?? components.path
            switch components.scheme {
            case "file":
                windows.append(Window(uri: uri, path: path, host: nil))
            case "vscode-remote":
                let authority = (components.percentEncodedHost ?? components.host ?? "").removingPercentEncoding ?? ""
                guard authority.hasPrefix("ssh-remote+") else { continue }
                let host = String(authority.dropFirst("ssh-remote+".count))
                windows.append(Window(uri: uri, path: path, host: host))
            default:
                continue
            }
        }
        return EditorWindows(windows: windows)
    }

    /// The open window whose folder holds one of the session's folders (the
    /// deepest), on `host` for a server's session.
    public func bestMatch(for folders: [String], host: String?) -> Window? {
        let candidates = windows.filter { window in
            switch (host, window.host) {
            case (nil, nil): return true
            case let (wanted?, have?): return SSHHosts.same(wanted, have)
            default: return false
            }
        }
        let matched = candidates
            .filter { window in folders.contains { Paths.contains(window.path, $0) } }
            .max { $0.depth < $1.depth }
        // A server's window that doesn't hold the folder (the terminal moved
        // elsewhere) is still where the session runs.
        if matched == nil, host != nil, candidates.count == 1 {
            return candidates.first
        }
        return matched
    }
}

// MARK: - Zed

/// The projects Zed has open now, from its database: the workspaces of its
/// current session that have a window.
public struct ZedWindows: Sendable {
    public struct Workspace: Equatable, Sendable {
        public var root: String
        public var host: String?
        public var user: String?
        public var port: Int?
        public var depth: Int { root.count }
    }

    public var workspaces: [Workspace]

    public static func read(_ bundleID: String, home: URL = Environment.home) -> ZedWindows {
        let channel = bundleID.hasSuffix("Preview") ? "0-preview" : (bundleID.hasSuffix("Dev") ? "0-dev" : "0-stable")
        let file = home.appendingPathComponent("Library/Application Support/Zed/db/\(channel)/db.sqlite")
        return read(database: file)
    }

    public static func read(database file: URL) -> ZedWindows {
        guard FileManager.default.fileExists(atPath: file.path) else { return ZedWindows(workspaces: []) }
        var db: OpaquePointer?
        guard sqlite3_open_v2(file.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            return ZedWindows(workspaces: [])
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 300)
        guard let session = query(db, "SELECT value FROM kv_store WHERE key = 'session_id'").first?.first ?? nil else {
            return ZedWindows(workspaces: [])
        }
        let rows = query(db, """
            SELECT w.paths, rc.host, rc.user, rc.port FROM workspaces w
            LEFT JOIN remote_connections rc ON rc.id = w.remote_connection_id
            WHERE w.session_id = ? AND w.window_id IS NOT NULL
            """, bind: session)
        var workspaces: [Workspace] = []
        for row in rows {
            guard let paths = row[0] else { continue }
            for root in paths.split(separator: "\n").map(String.init) where !root.isEmpty {
                workspaces.append(Workspace(root: root, host: row[1], user: row[2], port: row[3].flatMap(Int.init)))
            }
        }
        return ZedWindows(workspaces: workspaces)
    }

    private static func query(_ db: OpaquePointer, _ sql: String, bind: String? = nil) -> [[String?]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return [] }
        defer { sqlite3_finalize(statement) }
        if let bind {
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(statement, 1, bind, -1, transient)
        }
        var rows: [[String?]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append((0..<sqlite3_column_count(statement)).map { column in
                sqlite3_column_text(statement, column).map { String(cString: $0) }
            })
        }
        return rows
    }

    public func bestMatch(for folders: [String], host: String?) -> Workspace? {
        let candidates = workspaces.filter { workspace in
            switch (host, workspace.host) {
            case (nil, nil): return true
            case let (wanted?, have?): return SSHHosts.same(wanted, have)
            default: return false
            }
        }
        let matched = candidates.filter { workspace in folders.contains { Paths.contains(workspace.root, $0) } }
            .max { $0.depth < $1.depth }
        if matched == nil, host != nil, candidates.count == 1 {
            return candidates.first
        }
        return matched
    }
}

// MARK: - Paths and hosts

public enum Paths {
    /// Whether `folder` is `root` or inside it.
    public static func contains(_ root: String, _ folder: String) -> Bool {
        let root = root.hasSuffix("/") && root.count > 1 ? String(root.dropLast()) : root
        return folder == root || folder.hasPrefix(root == "/" ? "/" : root + "/")
    }
}

/// Whether two ways of naming a server name the same one: "user@server:22",
/// "server", or an alias from ~/.ssh/config (resolved with `ssh -G`).
public enum SSHHosts {
    private static var resolved: [String: String] = [:]
    private static let lock = NSLock()

    public static func same(_ first: String, _ second: String) -> Bool {
        let a = ProcessTable.hostKey(first)
        let b = ProcessTable.hostKey(second)
        return a == b || hostname(a) == hostname(b)
    }

    /// The HostName ssh would connect to, from `ssh -G` (no connection is made).
    public static func hostname(_ alias: String) -> String {
        lock.lock()
        if let known = resolved[alias] {
            lock.unlock()
            return known
        }
        lock.unlock()
        var name = alias
        if let result = ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/ssh"), ["-G", alias], timeout: 3), result.status == 0 {
            for line in result.text.split(separator: "\n") where line.hasPrefix("hostname ") {
                name = String(line.dropFirst("hostname ".count)).lowercased()
                break
            }
        }
        lock.lock()
        resolved[alias] = name
        lock.unlock()
        return name
    }
}
