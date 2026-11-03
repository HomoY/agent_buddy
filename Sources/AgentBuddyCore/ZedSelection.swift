import Foundation
import SQLite3

/// What's selected in Zed. Its database keeps each editor's selections, saved
/// a moment after they change, as byte offsets into the file; the latest saved
/// is the one you just made.
public struct ZedSelection: Equatable, Sendable {
    /// Which save it was: the row's id grows with each, so a new one is a new selection.
    public var mark: Int64
    public var editor: Int64
    public var workspace: Int64
    /// The file, on this Mac or on `host`.
    public var path: String?
    public var host: String?
    public var user: String?
    public var port: Int?
    /// Byte offsets into the file; the same for a bare cursor.
    public var start: Int
    public var end: Int
    /// Zed kept the buffer's unsaved text.
    public var hasContents: Bool

    public var isEmpty: Bool { start == end }

    /// The database of Zed's stable, preview or dev channel.
    public static func database(_ bundleID: String = "dev.zed.Zed", home: URL = Environment.home) -> URL {
        let channel = bundleID.hasSuffix("Preview") ? "0-preview" : (bundleID.hasSuffix("Dev") ? "0-dev" : "0-stable")
        return home.appendingPathComponent("Library/Application Support/Zed/db/\(channel)/db.sqlite")
    }

    /// The latest selection saved; nil when there's none (or no database).
    public static func latest(database file: URL) -> ZedSelection? {
        guard let db = open(file) else { return nil }
        defer { sqlite3_close(db) }
        let sql = """
            SELECT s.rowid, s.editor_id, s.workspace_id, s.start, s.end, e.path, e.buffer_path, e.contents IS NOT NULL,
                   rc.host, rc.user, rc.port
            FROM editor_selections s
            JOIN editors e ON e.item_id = s.editor_id AND e.workspace_id = s.workspace_id
            LEFT JOIN workspaces w ON w.workspace_id = s.workspace_id
            LEFT JOIN remote_connections rc ON rc.id = w.remote_connection_id
            ORDER BY s.rowid DESC LIMIT 1
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        func text(_ column: Int32) -> String? {
            switch sqlite3_column_type(statement, column) {
            case SQLITE_NULL:
                return nil
            case SQLITE_BLOB:
                guard let bytes = sqlite3_column_blob(statement, column) else { return nil }
                let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
                return String(data: data, encoding: .utf8)
            default:
                return sqlite3_column_text(statement, column).map { String(cString: $0) }
            }
        }
        let path = text(5).flatMap { $0.isEmpty ? nil : $0 } ?? text(6).flatMap { $0.isEmpty ? nil : $0 }
        return ZedSelection(
            mark: sqlite3_column_int64(statement, 0), editor: sqlite3_column_int64(statement, 1),
            workspace: sqlite3_column_int64(statement, 2), path: path, host: text(8), user: text(9),
            port: sqlite3_column_type(statement, 10) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(statement, 10)),
            start: Int(sqlite3_column_int64(statement, 3)), end: Int(sqlite3_column_int64(statement, 4)),
            hasContents: sqlite3_column_int(statement, 7) != 0)
    }

    /// The buffer's unsaved text, as Zed kept it.
    public func contents(database file: URL) -> String? {
        guard hasContents, let db = Self.open(file) else { return nil }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT contents FROM editors WHERE item_id = ? AND workspace_id = ?", -1, &statement, nil) == SQLITE_OK,
              let statement
        else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, editor)
        sqlite3_bind_int64(statement, 2, workspace)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return sqlite3_column_text(statement, 0).map { String(cString: $0) }
    }

    private static func open(_ file: URL) -> OpaquePointer? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(file.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            return nil
        }
        sqlite3_busy_timeout(db, 200)
        return db
    }

    /// The selected text and its lines (counted from 1), from the file's bytes;
    /// nil if the offsets don't fit it (the file changed since).
    public static func excerpt(_ data: Data, start: Int, end: Int, limit: Int = 20_000) -> (text: String, lines: ClosedRange<Int>)? {
        guard start >= 0, end > start, end <= data.count else { return nil }
        let base = data.startIndex
        let first = data[base..<(base + start)].reduce(1) { $0 + ($1 == 0x0A ? 1 : 0) }
        let slice = data[(base + start)..<(base + end)]
        var last = first + slice.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) }
        if slice.last == 0x0A, last > first {
            last -= 1
        }
        let kept = slice.count > limit ? slice.prefix(limit) : slice
        let text = String(decoding: kept, as: UTF8.self) + (slice.count > limit ? "\n…" : "")
        return (text, first...last)
    }
}

extension ZedSelection {
    /// A selection in a Zed project on a server: its bytes and lines, read there
    /// with one `python3` run over SSH (batch mode, never asking for a password).
    public static func remoteExcerpt(
        host: String, path: String, start: Int, end: Int, transport: [String]? = nil, limit: Int = 20_000
    ) -> (text: String, lines: ClosedRange<Int>)? {
        guard end > start, start >= 0,
              let request = try? JSONSerialization.data(withJSONObject: ["path": path, "start": start, "end": end, "limit": limit])
        else { return nil }
        let command = transport ?? RemoteTokenSource.ssh(host)
        guard let program = command.first else { return nil }
        let script = remoteScript.replacingOccurrences(of: "__REQUEST__", with: request.base64EncodedString())
        guard let result = ProcessRunner.run(
            URL(fileURLWithPath: program), Array(command.dropFirst()), environment: Environment.engineEnvironment(),
            input: Data(script.utf8), timeout: 8),
              result.status == 0,
              let reply = SessionHistoryReader.lines(result.output).last,
              let first = reply["line"].int,
              let body = reply["body"].string.flatMap({ Data(base64Encoded: $0) })
        else { return nil }
        let breaks = body.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) } - (body.last == 0x0A ? 1 : 0)
        let text = String(decoding: body, as: UTF8.self) + (reply["more"].bool == true ? "\n…" : "")
        return (text, first...(first + max(breaks, 0)))
    }

    static let remoteScript = #"""
import base64, json, os, sys
req = json.loads(base64.b64decode("__REQUEST__"))
start, end, limit = int(req["start"]), int(req["end"]), int(req["limit"])
try:
    with open(os.path.expanduser(req["path"]), "rb") as f:
        head = f.read(start)
        body = f.read(end - start)
except (OSError, ValueError):
    sys.exit(0)
if len(head) < start or len(body) < end - start:
    sys.exit(0)
print(json.dumps({"line": head.count(b"\n") + 1, "body": base64.b64encode(body[:limit]).decode(), "more": len(body) > limit}))
"""#
}

/// What you've selected elsewhere, worded as Claude Code words an editor's
/// selection, so the agent takes it as context and the history hides it.
public enum SelectionContext {
    public static func block(text: String, file: String?, lines: ClosedRange<Int>?, app: String, title: String?) -> String {
        let source: String
        if let file, let lines {
            source = "the lines \(lines.lowerBound) to \(lines.upperBound) from \(file)"
        } else if let file {
            source = "the following text from \(file)"
        } else {
            source = "the following text in \(app)\(title.map { " (\($0))" } ?? "")"
        }
        return "<ide_selection>The user selected \(source):\n\(text)\n\nThis may or may not be related to the current task.</ide_selection>"
    }

    /// Where a selection is in its file, when the app gives Accessibility only a
    /// page of it (VS Code: the lines around the cursor), found by where that page
    /// is in the file. `selected` counts UTF-16 units into `page`, as Accessibility
    /// does. Nil if the page isn't in the file (unsaved changes) or is in it twice.
    public static func lines(of selected: NSRange, page: String, file: String) -> ClosedRange<Int>? {
        let units = Array(page.utf16)
        guard selected.location >= 0, selected.length > 0, selected.location + selected.length <= units.count else { return nil }
        let wanted = page.replacingOccurrences(of: "\r\n", with: "\n")
        let whole = file.replacingOccurrences(of: "\r\n", with: "\n")
        guard !wanted.isEmpty, let found = whole.range(of: wanted),
              whole.range(of: wanted, range: whole.index(after: found.lowerBound)..<whole.endIndex) == nil
        else { return nil }
        func breaks<S: Sequence>(_ units: S) -> Int where S.Element == UInt16 {
            units.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) }
        }
        let top = whole.utf8[..<found.lowerBound].reduce(1) { $0 + ($1 == 0x0A ? 1 : 0) }
        let chosen = units[selected.location..<(selected.location + selected.length)]
        let first = top + breaks(units[..<selected.location])
        // A selection running to a line's end takes its break: still that line.
        let last = first + breaks(chosen) - (chosen.last == 0x0A && chosen.count > 1 ? 1 : 0)
        return first...max(first, last)
    }

    /// A selection's lines from where the editor's cursor is ("Ln 12, Col 5" in
    /// VS Code's status bar): at the selection's end, unless its column is the
    /// start's and not the end's. `selected` counts UTF-16 units into `page`.
    public static func lines(of selected: NSRange, page: String, cursorLine: Int, cursorColumn: Int) -> ClosedRange<Int>? {
        let units = Array(page.utf16)
        guard cursorLine >= 1, selected.location >= 0, selected.length > 0, selected.location + selected.length <= units.count else { return nil }
        let chosen = units[selected.location..<(selected.location + selected.length)]
        let breaks = chosen.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) }
        /// Counted from 1, as editors count columns.
        func column(at offset: Int) -> Int {
            var start = offset
            while start > 0, units[start - 1] != 0x0A {
                start -= 1
            }
            return offset - start + 1
        }
        let atStart = cursorColumn == column(at: selected.location) && cursorColumn != column(at: selected.location + selected.length)
        let first = atStart ? cursorLine : cursorLine - breaks
        // A selection running to a line's end takes its break: still that line.
        let last = first + breaks - (chosen.last == 0x0A && breaks > 0 ? 1 : 0)
        guard first >= 1 else { return nil }
        return first...max(first, last)
    }
}
