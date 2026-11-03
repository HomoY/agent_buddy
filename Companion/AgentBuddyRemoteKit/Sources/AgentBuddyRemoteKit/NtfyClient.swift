import Foundation

/// One message as ntfy hands it out.
public struct NtfyMessage: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var time: Date
    public var topic: String
    public var title: String?
    public var message: String
    public var tags: [String]
    public var priority: Int
    /// Where its file is, for a message ntfy keeps as an attachment.
    public var attachment: URL?

    public init(
        id: String, time: Date, topic: String, title: String?, message: String, tags: [String], priority: Int = 3,
        attachment: URL? = nil
    ) {
        self.id = id
        self.time = time
        self.topic = topic
        self.title = title
        self.message = message
        self.tags = tags
        self.priority = priority
        self.attachment = attachment
    }

    /// One line of ntfy's JSON stream; nil for open, keepalive and other events.
    public init?(line: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["event"] as? String == "message",
              let id = object["id"] as? String,
              let time = (object["time"] as? NSNumber)?.doubleValue
        else { return nil }
        let title = (object["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        self.init(
            id: id, time: Date(timeIntervalSince1970: time), topic: object["topic"] as? String ?? "",
            title: title, message: object["message"] as? String ?? "",
            tags: object["tags"] as? [String] ?? [], priority: (object["priority"] as? NSNumber)?.intValue ?? 3,
            attachment: ((object["attachment"] as? [String: Any])?["url"] as? String).flatMap(URL.init(string:)))
    }
}

/// A message to publish.
public struct PushMessage: Equatable, Sendable {
    public var topic: String
    public var title: String?
    public var message: String
    public var tags: [String]
    /// 1 (min) to 5 (max); 3 is ntfy's default, 4 breaks through Focus as time-sensitive.
    public var priority: Int
    /// Opened when the notification is tapped.
    public var click: String?

    public init(topic: String, title: String?, message: String, tags: [String] = [], priority: Int = 3, click: String? = nil) {
        self.topic = topic
        self.title = title
        self.message = message
        self.tags = tags
        self.priority = priority
        self.click = click
    }

    /// The body of a JSON publish (https://docs.ntfy.sh/publish/#publish-as-json).
    public var json: Data {
        var body: [String: Any] = ["topic": topic, "message": message, "priority": priority]
        if let title, !title.isEmpty {
            // ntfy refuses titles over 1 KB.
            body["title"] = String(title.prefix(250))
        }
        if !tags.isEmpty {
            body["tags"] = tags
        }
        if let click {
            body["click"] = click
        }
        return (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
    }
}

/// The little of ntfy's HTTP API Agent Buddy needs (https://docs.ntfy.sh): publish
/// a message as JSON, and read a topic's cached messages.
public struct NtfyClient: Sendable {
    public enum Failure: LocalizedError, Equatable {
        case badServer(String)
        case http(Int)
        case unreachable(String)

        public var errorDescription: String? {
            switch self {
            case .badServer(let server): return "“\(server)” isn't a server address."
            case .http(401), .http(403): return "The server refused the topic. Check its access token."
            case .http(429): return "The server's limit for today is used up (ntfy.sh allows 250 messages a day)."
            case .http(507): return "The server is out of space for messages."
            case .http(let code): return "The server answered HTTP \(code)."
            case .unreachable(let reason): return "Couldn't reach the server: \(reason)"
            }
        }
    }

    public var pairing: Pairing
    public var session: URLSession

    public init(pairing: Pairing, session: URLSession = .shared) {
        self.pairing = pairing
        self.session = session
    }

    /// The server address with one trailing slash, or nil if it isn't http(s).
    public var base: URL? {
        var text = pairing.server
        if !text.contains("://") {
            text = "https://" + text
        }
        while text.hasSuffix("/") {
            text.removeLast()
        }
        guard let url = URL(string: text + "/"), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", url.host?.isEmpty == false
        else { return nil }
        return url
    }

    private func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        if let token = pairing.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Failure.unreachable(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Failure.http(http.statusCode)
        }
        return data
    }

    public func publish(_ message: PushMessage) async throws {
        guard let base else { throw Failure.badServer(pairing.server) }
        var request = request(base)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = message.json
        _ = try await send(request)
    }

    /// A topic's cached messages, oldest first. `since` is "latest", "12h", a
    /// Unix time or "all" (https://docs.ntfy.sh/subscribe/api/#fetch-cached-messages).
    public func messages(topic: String, since: String) async throws -> [NtfyMessage] {
        guard let base,
              var components = URLComponents(url: base.appendingPathComponent(topic).appendingPathComponent("json"), resolvingAgainstBaseURL: false)
        else { throw Failure.badServer(pairing.server) }
        components.queryItems = [URLQueryItem(name: "poll", value: "1"), URLQueryItem(name: "since", value: since)]
        guard let url = components.url else { throw Failure.badServer(pairing.server) }
        let data = try await send(request(url))
        return data.split(separator: 0x0A).compactMap { NtfyMessage(line: Data($0)) }.sorted { $0.time < $1.time }
    }

    /// The Mac's latest status, if ntfy still holds one (ntfy.sh keeps messages 12 hours).
    public func latestSnapshot() async throws -> RemoteSnapshot? {
        var messages: [NtfyMessage]
        do {
            messages = try await self.messages(topic: pairing.statusTopic, since: "latest")
        } catch Failure.http(400) {
            // A server from before "since=latest" (ntfy 2.8).
            messages = try await self.messages(topic: pairing.statusTopic, since: "12h")
        }
        for message in messages.reversed() {
            if let snapshot = RemoteSnapshot.decode(Data(message.message.utf8)) {
                return snapshot
            }
        }
        return nil
    }

    /// The reminders sent after `since` (or in the last 12 hours).
    public func reminders(since: Date?) async throws -> [NtfyMessage] {
        let value = since.map { String(Int($0.timeIntervalSince1970)) } ?? "12h"
        return try await messages(topic: pairing.topic, since: value)
    }

    // MARK: - Sealed requests and replies

    /// How a sealed message's text begins.
    public static let sealedPrefix = "abr1:"

    /// Publishes sealed bytes: as a message's text when that fits ntfy's
    /// 4,096-byte limit, else as a file ntfy keeps beside the message.
    public func publishSealed(_ sealed: Data, topic: String) async throws {
        let text = Self.sealedPrefix + sealed.base64EncodedString()
        if text.utf8.count <= 3500 {
            try await publish(PushMessage(topic: topic, title: nil, message: text, priority: 1))
            return
        }
        guard let base else { throw Failure.badServer(pairing.server) }
        var upload = request(base.appendingPathComponent(topic))
        upload.httpMethod = "PUT"
        upload.timeoutInterval = 60
        upload.setValue("sealed.bin", forHTTPHeaderField: "Filename")
        upload.setValue("1", forHTTPHeaderField: "Priority")
        upload.httpBody = sealed
        _ = try await send(upload)
    }

    /// The sealed bytes a message carries, fetched from its file if it has one;
    /// nil for any other message.
    public func sealedBytes(_ message: NtfyMessage) async throws -> Data? {
        if let file = message.attachment {
            var fetch = request(file)
            fetch.timeoutInterval = 60
            return try await send(fetch)
        }
        guard message.message.hasPrefix(Self.sealedPrefix) else { return nil }
        return Data(base64Encoded: String(message.message.dropFirst(Self.sealedPrefix.count)))
    }

    /// A topic's messages as they come: first those cached since `since` (an id,
    /// a Unix time, or "30s"), then each new one, until the connection ends.
    public func stream(topic: String, since: String) -> AsyncThrowingStream<NtfyMessage, Error> {
        let base = self.base
        let server = pairing.server
        let session = self.session
        let token = pairing.token
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let base,
                          var components = URLComponents(url: base.appendingPathComponent(topic).appendingPathComponent("json"),
                                                         resolvingAgainstBaseURL: false)
                    else { throw Failure.badServer(server) }
                    components.queryItems = [URLQueryItem(name: "since", value: since)]
                    guard let url = components.url else { throw Failure.badServer(server) }
                    // ntfy sends a keepalive every 45 seconds, so a quiet minute and a half means it's gone.
                    var listen = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 90)
                    if let token {
                        listen.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                    }
                    let (bytes, response) = try await session.bytes(for: listen)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        throw Failure.http(http.statusCode)
                    }
                    for try await line in bytes.lines {
                        if let message = NtfyMessage(line: Data(line.utf8)) {
                            continuation.yield(message)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
