import Foundation

/// Where the Mac publishes: an ntfy server and topic. Reminders go to `topic`
/// (subscribe to it in the ntfy app); status snapshots go to `statusTopic`,
/// which only Agent Buddy Remote reads, so they never ring. With a `key`, the
/// phone can also ask the Mac for a job's prompts, statistics, or to send a
/// prompt: sealed requests on `commandTopic`, sealed replies on `replyTopic`.
public struct Pairing: Codable, Equatable, Sendable {
    public var server: String
    public var topic: String
    public var token: String?
    /// The secret both ends seal requests and replies with (32 bytes, base64url).
    /// It's only in the pairing code, never sent over the network.
    public var key: String?

    public init(server: String, topic: String, token: String? = nil, key: String? = nil) {
        self.server = server.trimmingCharacters(in: .whitespacesAndNewlines)
        self.topic = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.token = trimmed?.isEmpty == false ? trimmed : nil
        self.key = key.flatMap { Sealed.isValid(key: $0) ? $0 : nil }
    }

    public var statusTopic: String { topic + "-status" }
    public var commandTopic: String { topic + "-ask" }
    public var replyTopic: String { topic + "-answer" }

    /// The same place, without the secret (for Apple Watch, which only reads).
    public var withoutKey: Pairing {
        var copy = self
        copy.key = nil
        return copy
    }

    /// `agentbuddy://pair?server=…&topic=…&key=…`, which Agent Buddy shows as a QR code.
    public var link: URL? {
        var components = URLComponents()
        components.scheme = "agentbuddy"
        components.host = "pair"
        components.queryItems = [URLQueryItem(name: "server", value: server), URLQueryItem(name: "topic", value: topic)]
            + (token.map { [URLQueryItem(name: "token", value: $0)] } ?? [])
            + (key.map { [URLQueryItem(name: "key", value: $0)] } ?? [])
        return components.url
    }

    public init?(url: URL) {
        guard url.scheme == "agentbuddy", url.host == "pair",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else { return nil }
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 }
        }
        guard let server = value("server"), let topic = value("topic"), Pairing.isValid(topic: topic) else { return nil }
        self.init(server: server, topic: topic, token: value("token"), key: value("key"))
    }

    /// ntfy topics: letters, digits, "-" and "_", up to 64 characters.
    public static func isValid(topic: String) -> Bool {
        !topic.isEmpty && topic.count <= 64 && topic.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    /// A topic nobody can guess: "agentbuddy-" and 22 random letters and digits.
    public static func newTopic() -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        var generator = SystemRandomNumberGenerator()
        return "agentbuddy-" + String((0..<22).map { _ in alphabet[Int(generator.next() % UInt64(alphabet.count))] })
    }
}
