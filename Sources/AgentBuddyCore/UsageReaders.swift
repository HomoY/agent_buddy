import Foundation

public enum UsageReaders {
    /// Reads one agent's plan limits. Blocking: call it off the main thread.
    public static func read(_ agent: Agent) throws -> AgentReading {
        switch agent {
        case .claude: return try ClaudeUsage.read()
        case .codex: return try CodexUsage.read()
        case .copilot: return try CopilotUsage.read()
        default: throw ReadError("\(agent.clientName) has no plan limits to read.")
        }
    }
}
