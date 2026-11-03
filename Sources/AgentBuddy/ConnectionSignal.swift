import AgentBuddyCore
import AppKit
import SwiftUI

/// How well each server answers, for the agent windows' signal: the round
/// trip there, measured every 20 seconds while a window of one of its
/// sessions is open, and whether Agent Buddy's own connection to it is up.
@MainActor
final class ConnectionMonitor: ObservableObject {
    static let shared = ConnectionMonitor()

    enum Reading: Equatable {
        case measuring
        case roundTrip(RoundTrip.Measured)
        case noReply
    }

    @Published private(set) var readings: [String: Reading] = [:]
    /// Agent Buddy's own connection to each server in Settings (its watcher of the server's sessions).
    @Published var links: [String: RemoteSessionStream.Status] = [:]

    static let every: TimeInterval = 20
    /// Off for the pictures: only what's previewed shows, no server is asked.
    var live = true
    /// Windows open, by server: measured while there's one.
    private var watching: [String: Int] = [:]
    private var measuring: Set<String> = []
    private var timer: Timer?

    func watch(_ host: String) {
        guard live else { return }
        watching[host, default: 0] += 1
        if watching[host] == 1 {
            measure(host)
        }
        if timer == nil {
            let timer = Timer(timeInterval: Self.every, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.measureAll() }
            }
            timer.tolerance = 2
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
    }

    func unwatch(_ host: String) {
        guard let count = watching[host] else { return }
        watching[host] = count > 1 ? count - 1 : nil
        if watching.isEmpty {
            timer?.invalidate()
            timer = nil
        }
    }

    private func measureAll() {
        for host in watching.keys {
            measure(host)
        }
    }

    private func measure(_ host: String) {
        guard !measuring.contains(host) else { return }
        measuring.insert(host)
        if readings[host] == nil {
            readings[host] = .measuring
        }
        Task.detached(priority: .utility) { [weak self] in
            let measured = RoundTrip.measure(host)
            await self?.measured(host, measured)
        }
    }

    private func measured(_ host: String, _ result: RoundTrip.Measured?) {
        measuring.remove(host)
        let reading = result.map(Reading.roundTrip) ?? .noReply
        if readings[host] != reading {
            readings[host] = reading
        }
    }

    /// For the pictures: a server as if measured.
    func preview(_ reading: Reading?, for host: String) {
        readings[host] = reading
    }
}

/// An agent window's signal: for a session on this Mac, full and green,
/// "Local"; for one on a server, the round trip there ("430 ms"), fewer and
/// warmer bars the slower it is, or "Disconnected" when it can't be reached.
struct ConnectionTag: View {
    let host: String?
    @ObservedObject private var monitor = ConnectionMonitor.shared

    struct Signal: Equatable {
        /// How full the bars are, 0 to 1.
        var level: Double
        var color: Color
        var words: String
        var tip: String
    }

    var body: some View {
        let signal = Self.signal(host: host, link: host.flatMap { monitor.links[$0] }, reading: host.flatMap { monitor.readings[$0] })
        HStack(spacing: 4) {
            Image(systemName: "cellularbars", variableValue: signal.level)
                .uiFont(10, weight: .semibold)
            Text(signal.words)
                .uiFont(10, weight: .medium, digits: true)
        }
        .foregroundStyle(signal.color)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(signal.color.opacity(0.12)))
        .help(signal.tip)
        .onAppear {
            if let host {
                monitor.watch(host)
            }
        }
        .onDisappear {
            if let host {
                monitor.unwatch(host)
            }
        }
    }

    static func signal(host: String?, link: RemoteSessionStream.Status?, reading: ConnectionMonitor.Reading?) -> Signal {
        guard let host else {
            return Signal(level: 1, color: .green, words: "Local", tip: "On this Mac: nothing between you and the agent")
        }
        switch link {
        case .retrying(let why)?:
            return Signal(level: 0, color: .red, words: "Disconnected", tip: "Agent Buddy can't reach \(host) (\(why)). It keeps trying.")
        case .stopped?:
            return Signal(level: 0, color: .red, words: "Disconnected", tip: "Agent Buddy isn't connected to \(host)")
        default:
            break
        }
        switch reading ?? .measuring {
        case .measuring:
            return Signal(level: 0, color: .secondary, words: "\u{2026}", tip: "Timing the round trip to \(host)\u{2026}")
        case .noReply:
            return Signal(level: 0, color: .red, words: "No reply",
                          tip: "\(host) didn't answer a ping, or on its SSH port, just now. Measured again every \(Int(ConnectionMonitor.every)) seconds.")
        case .roundTrip(let measured):
            let ms = measured.milliseconds
            let (level, color): (Double, Color) = ms < 80 ? (1, .green) : ms < 200 ? (0.75, .green) : ms < 500 ? (0.5, .orange) : (0.25, .red)
            return Signal(level: level, color: color, words: "\(ms) ms",
                          tip: "A round trip to \(host) takes \(ms) ms (by \(measured.how)), measured every \(Int(ConnectionMonitor.every)) seconds")
        }
    }
}
