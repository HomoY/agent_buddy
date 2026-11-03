import Foundation
import AgentBuddyCore

/// What you select in Zed, read from a stand-in for its database, and how a
/// selection goes with a prompt.
func checkSelections() {
    print("What you select in Zed and other apps")
    let manager = FileManager.default
    let scratch = manager.temporaryDirectory.appendingPathComponent("ab-zed-\(UUID().uuidString)")
    try? manager.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: scratch) }
    let source = scratch.appendingPathComponent("main.rs")
    let code = "use std::io;\n\nfn main() {\n    println!(\"héllo\");\n}\n"
    try? code.write(to: source, atomically: true, encoding: .utf8)
    let bytes = Data(code.utf8)
    // "fn main() {\n    println!(\"héllo\");" as byte offsets, as Zed keeps them.
    let start = bytes.firstRange(of: Data("fn main".utf8))?.lowerBound ?? 0
    let end = (bytes.firstRange(of: Data("\");".utf8))?.upperBound ?? 0)

    let database = scratch.appendingPathComponent("db.sqlite")
    let hex = Data(source.path.utf8).map { String(format: "%02X", $0) }.joined()
    let sql = """
        CREATE TABLE remote_connections (id INTEGER PRIMARY KEY, host TEXT, user TEXT, port INTEGER);
        CREATE TABLE workspaces (workspace_id INTEGER PRIMARY KEY, remote_connection_id INTEGER);
        CREATE TABLE editors (item_id INTEGER NOT NULL, workspace_id INTEGER NOT NULL, path BLOB, contents TEXT, buffer_path TEXT,
                              PRIMARY KEY (item_id, workspace_id));
        CREATE TABLE editor_selections (item_id INTEGER NOT NULL, editor_id INTEGER NOT NULL, workspace_id INTEGER NOT NULL,
                                        start INTEGER NOT NULL, end INTEGER NOT NULL, PRIMARY KEY (item_id));
        INSERT INTO remote_connections VALUES (1, 'gpu', 'me', 22);
        INSERT INTO workspaces VALUES (1, NULL), (2, 1);
        INSERT INTO editors VALUES (10, 1, X'\(hex)', NULL, NULL), (20, 2, CAST('/home/me/app/lib.rs' AS BLOB), NULL, NULL);
        INSERT INTO editor_selections VALUES (100, 10, 1, 3, 3);
        INSERT INTO editor_selections VALUES (101, 10, 1, \(start), \(end));
        """
    let made = ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/sqlite3"), [database.path], input: Data(sql.utf8), timeout: 10)
    check(made?.status == 0, "a stand-in for Zed's database")
    guard let latest = ZedSelection.latest(database: database) else {
        check(false, "Zed's latest selection reads")
        return
    }
    check(latest.path == source.path && latest.host == nil && !latest.isEmpty, "the latest selection, in a file on this Mac")
    if let excerpt = ZedSelection.excerpt(bytes, start: latest.start, end: latest.end) {
        check(excerpt.text == "fn main() {\n    println!(\"héllo\");" && excerpt.lines == 3...4,
              "its text and lines, from byte offsets: lines \(excerpt.lines.lowerBound)–\(excerpt.lines.upperBound)")
    } else {
        check(false, "its text from the file")
    }
    check(ZedSelection.excerpt(bytes, start: 0, end: bytes.count + 5) == nil, "offsets past the file's end (it changed) read nothing")

    // A selection in a project on a server, then a bare cursor.
    let more = """
        INSERT INTO editor_selections VALUES (102, 20, 2, 4, 9);
        """
    _ = ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/sqlite3"), [database.path], input: Data(more.utf8), timeout: 10)
    let remote = ZedSelection.latest(database: database)
    check(remote?.host == "gpu" && remote?.user == "me" && remote?.path == "/home/me/app/lib.rs" && (remote?.mark ?? 0) > latest.mark,
          "a project on a server: its host, and a newer mark")
    _ = ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/sqlite3"), [database.path],
                          input: Data("INSERT INTO editor_selections VALUES (103, 10, 1, 7, 7);".utf8), timeout: 10)
    check(ZedSelection.latest(database: database)?.isEmpty == true, "a bare cursor is no selection")

    // Read on the server: the script, run here in place of ssh.
    let there = ZedSelection.remoteExcerpt(host: "test", path: source.path, start: start, end: end,
                                           transport: ["/usr/bin/env", "python3", "-"])
    check(there?.text == "fn main() {\n    println!(\"héllo\");" && there?.lines == 3...4, "a server's file reads the same over SSH")
    check(ZedSelection.remoteExcerpt(host: "test", path: source.path, start: 0, end: 10_000, transport: ["/usr/bin/env", "python3", "-"]) == nil,
          "and offsets past its end read nothing")

    // As it goes with a prompt, and as the history then shows the prompt.
    let block = SelectionContext.block(text: "fn main() {", file: "/tmp/main.rs", lines: 3...4, app: "Zed", title: nil)
    check(block == "<ide_selection>The user selected the lines 3 to 4 from /tmp/main.rs:\nfn main() {\n\nThis may or may not be related to the current task.</ide_selection>",
          "worded as Claude Code words an editor's selection")
    check(SelectionContext.block(text: "x", file: nil, lines: nil, app: "Safari", title: "Release notes")
          .contains("the following text in Safari (Release notes)"), "a selection with no file names the app and window")
    let line = jsonLine(["uuid": "u1", "parentUuid": NSNull(), "type": "user", "timestamp": "2026-10-26T12:00:00Z",
                         "cwd": "/tmp", "message": ["role": "user", "content": block + "\n\nWhy does this panic?"]])
    let history = SessionHistoryReader.claude(lines: [line].compactMap { JSON.parse($0) }, sessionID: "s")
    check(history.turns.first?.text == "Why does this panic?", "the history shows the prompt as typed, the selection hidden")

    // VS Code gives Accessibility a page of the file: its lines, from where the page is.
    let tex = "\\documentclass{article}\n\\begin{document}\n% 😀 note\nLet $A$ be invertible.\nThen $A^{-1}A = I$.\n\\end{document}\n"
    let page = "% 😀 note\nLet $A$ be invertible.\nThen $A^{-1}A = I$.\n"
    func range(of piece: String, in text: String) -> NSRange {
        NSRange(text.range(of: piece)!, in: text)
    }
    check(SelectionContext.lines(of: range(of: "invertible", in: page), page: page, file: tex) == 4...4,
          "a word on the page's second line is on the file's fourth (past an emoji, counted as Accessibility counts)")
    check(SelectionContext.lines(of: range(of: "invertible.\nThen", in: page), page: page, file: tex) == 4...5, "a selection over two lines")
    check(SelectionContext.lines(of: range(of: "Let $A$ be invertible.\n", in: page), page: page, file: tex) == 4...4,
          "a whole line with its break is still that one line")
    check(SelectionContext.lines(of: range(of: "invertible", in: page), page: page,
                                 file: tex.replacingOccurrences(of: "\n", with: "\r\n")) == 4...4, "a file with Windows line breaks")
    check(SelectionContext.lines(of: range(of: "invertible", in: page), page: page, file: tex + tex) == nil,
          "a page found twice in the file gives no lines")
    check(SelectionContext.lines(of: range(of: "invertible", in: page), page: page,
                                 file: tex.replacingOccurrences(of: "invertible", with: "regular")) == nil,
          "nor one not in it (unsaved changes)")
    check(SelectionContext.lines(of: NSRange(location: 40, length: 500), page: page, file: tex) == nil, "nor a range past the page")

    // A file on a server: the status bar's cursor ("Ln 12, Col 5") places the selection.
    // On the page: line 0 "% 😀 note", 1 "Let $A$ be invertible.", 2 "Then $A^{-1}A = I$."
    check(SelectionContext.lines(of: range(of: "invertible", in: page), page: page, cursorLine: 41, cursorColumn: 22) == 41...41,
          "a word, the cursor after it: that line")
    check(SelectionContext.lines(of: range(of: "invertible", in: page), page: page, cursorLine: 41, cursorColumn: 12) == 41...41,
          "selected backwards, the cursor before it: the same line")
    check(SelectionContext.lines(of: range(of: "invertible.\nThen", in: page), page: page, cursorLine: 42, cursorColumn: 5) == 41...42,
          "over two lines, the cursor at the end")
    check(SelectionContext.lines(of: range(of: "invertible.\nThen", in: page), page: page, cursorLine: 41, cursorColumn: 12) == 41...42,
          "and backwards, the cursor at the start")
    check(SelectionContext.lines(of: range(of: "Let $A$ be invertible.\nThen $A^{-1}A = I$.\n", in: page), page: page,
                                 cursorLine: 43, cursorColumn: 1) == 41...42,
          "whole lines with their breaks: the cursor on the next line's start (\"Ln 43, Col 1\")")
    check(SelectionContext.lines(of: range(of: "invertible", in: page), page: page, cursorLine: 0, cursorColumn: 1) == nil
          && SelectionContext.lines(of: range(of: "invertible.\nThen", in: page), page: page, cursorLine: 1, cursorColumn: 5) == nil,
          "no lines from a cursor that can't be right")
}
