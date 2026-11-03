import Foundation
import Network

/// How long a message takes to a server and back: a ping, or, if the server
/// doesn't answer pings, the time to reach its SSH port. Neither signs in, so
/// neither leaves a session or a failed login on the server.
public enum RoundTrip {
    public struct Measured: Equatable, Sendable {
        public var milliseconds: Int
        /// "ping", or "its SSH port".
        public var how: String

        public init(milliseconds: Int, how: String) {
            self.milliseconds = milliseconds
            self.how = how
        }
    }

    /// Blocking: call it off the main thread.
    public static func measure(_ host: String) -> Measured? {
        let (name, port) = address(of: host)
        if let ms = ping(name) {
            return Measured(milliseconds: ms, how: "ping")
        }
        if let ms = connectTime(name, port) {
            return Measured(milliseconds: ms, how: "its SSH port")
        }
        return nil
    }

    /// The server's address and SSH port, as ssh would reach it (aliases in ~/.ssh/config too).
    static func address(of host: String) -> (String, UInt16) {
        let bare = host.split(separator: "@").last.map(String.init) ?? host
        guard let result = ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/ssh"), ["-G", host], timeout: 5), result.status == 0 else {
            return (bare, 22)
        }
        return address(fromSSHConfig: result.text, fallback: bare)
    }

    /// `ssh -G`'s lines: "hostname 203.0.113.7", "port 22".
    public static func address(fromSSHConfig text: String, fallback: String) -> (String, UInt16) {
        var name = fallback
        var port: UInt16 = 22
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            switch parts[0].lowercased() {
            case "hostname": name = parts[1]
            case "port": port = UInt16(parts[1]) ?? port
            default: break
            }
        }
        return (name, port)
    }

    public static func ping(_ name: String) -> Int? {
        guard let result = ProcessRunner.run(URL(fileURLWithPath: "/sbin/ping"), ["-n", "-c", "1", "-W", "3000", name], timeout: 6),
              result.status == 0
        else { return nil }
        return pingTime(result.text)
    }

    /// ping's summary: "round-trip min/avg/max/stddev = 431.208/431.208/431.208/0.000 ms".
    public static func pingTime(_ output: String) -> Int? {
        guard let line = output.split(separator: "\n").first(where: { $0.contains("round-trip") || $0.contains("rtt ") }),
              let numbers = line.split(separator: "=").last,
              let average = numbers.trimmingCharacters(in: .whitespaces).split(separator: "/").dropFirst().first,
              let value = Double(average)
        else { return nil }
        return max(1, Int(value.rounded()))
    }

    private final class Reached: @unchecked Sendable {
        var milliseconds: Int?
    }

    /// The time to open a connection to the port (then closed at once, unused).
    public static func connectTime(_ name: String, _ port: UInt16, timeout: TimeInterval = 4) -> Int? {
        guard let port = NWEndpoint.Port(rawValue: port) else { return nil }
        let connection = NWConnection(host: NWEndpoint.Host(name), port: port, using: .tcp)
        let reached = Reached()
        let done = DispatchSemaphore(value: 0)
        let start = DispatchTime.now()
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                reached.milliseconds = max(1, Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000))
                done.signal()
            case .failed, .waiting:
                done.signal()
            default:
                break
            }
        }
        connection.start(queue: DispatchQueue.global(qos: .utility))
        _ = done.wait(timeout: .now() + timeout)
        connection.cancel()
        return reached.milliseconds
    }
}
