import AppKit
import AgentBuddyCore

/// Brings a session's window forward, the way its app allows.
@MainActor
enum Jumper {
    /// Nil when it worked, else what went wrong.
    static func go(_ place: SessionPlace) async -> String? {
        switch place.move {
        case let .editorWindow(cli, folderURI, conversation):
            var focused = false
            if let cli {
                // The editor's own tool focuses the window that has the folder open.
                let result = await Task.detached(priority: .userInitiated) {
                    ProcessRunner.run(cli, ["--folder-uri", folderURI], timeout: 15)
                }.value
                focused = result?.status == 0
            }
            if !focused, let url = URL(string: folderURI), url.isFileURL {
                focused = await open(url, with: place.appURL)
            }
            if !focused {
                activate(place.bundleID)
            }
            if let conversation {
                // Once that window has focus, it takes the link to the conversation.
                try? await Task.sleep(nanoseconds: 700_000_000)
                _ = await open(conversation, with: place.appURL)
            }
            return nil
        case let .zed(target), let .link(target):
            return await open(target, with: place.appURL) ? nil : "\(place.appName) didn't open it."
        case let .terminalTab(tty):
            if let problem = selectTab(tty, in: place.bundleID) {
                activate(place.bundleID)
                return problem
            }
            return nil
        case .activate:
            activate(place.bundleID)
            return nil
        }
    }

    private static func open(_ url: URL, with app: URL) async -> Bool {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        return await withCheckedContinuation { continuation in
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: configuration) { _, error in
                continuation.resume(returning: error == nil)
            }
        }
    }

    static func activate(_ bundleID: String) {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return }
        if #available(macOS 14.0, *) {
            NSApp.yieldActivation(to: app)
            app.activate()
        } else {
            app.activate(options: [.activateIgnoringOtherApps])
        }
    }

    /// Selects the Terminal or iTerm2 tab on `tty`; nil when it did.
    private static func selectTab(_ tty: String, in bundleID: String) -> String? {
        let quoted = tty.replacingOccurrences(of: "\"", with: "")
        let source: String
        if bundleID == "com.googlecode.iterm2" {
            source = """
            tell application id "com.googlecode.iterm2"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if tty of s is "\(quoted)" then
                                tell w to select
                                tell t to select
                                tell s to select
                                activate
                                return "ok"
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
            return "missing"
            """
        } else {
            source = """
            tell application id "com.apple.Terminal"
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t is "\(quoted)" then
                            set selected of t to true
                            set index of w to 1
                            activate
                            return "ok"
                        end if
                    end repeat
                end repeat
            end tell
            return "missing"
            """
        }
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            let code = error[NSAppleScript.errorNumber] as? Int ?? 0
            if code == -1743 {
                return "Allow Agent Buddy to control it in System Settings › Privacy & Security › Automation."
            }
            return error[NSAppleScript.errorMessage] as? String ?? "The terminal didn't answer."
        }
        return result?.stringValue == "ok" ? nil : "That tab is closed."
    }
}
