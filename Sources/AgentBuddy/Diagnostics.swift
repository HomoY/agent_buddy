import Foundation

/// A small log of what the watcher decided, in ~/Library/Logs/AgentBuddy/agentbuddy.log:
/// sessions opened, turns finished or withdrawn, reminders sent. Every read is
/// logged too after `defaults write io.github.homoy.agentbuddy debugWatcher -bool YES`.
enum Diagnostics {
    static let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/AgentBuddy")
    static let file = folder.appendingPathComponent("agentbuddy.log")
    private static let queue = DispatchQueue(label: "AgentBuddy.Diagnostics")
    private static let limit = 2_000_000

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    static func log(_ message: String) {
        let line = "\(clock.string(from: Date())) \(message)\n"
        queue.async {
            let manager = FileManager.default
            try? manager.createDirectory(at: folder, withIntermediateDirectories: true)
            if let size = (try? manager.attributesOfItem(atPath: file.path))?[.size] as? NSNumber, size.intValue > limit {
                let old = folder.appendingPathComponent("agentbuddy.old.log")
                try? manager.removeItem(at: old)
                try? manager.moveItem(at: file, to: old)
            }
            if let handle = try? FileHandle(forWritingTo: file) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: file)
            }
        }
    }
}
