import AppKit
import Combine
import CoreImage
import CoreImage.CIFilterBuiltins
import AgentBuddyCore
import AgentBuddyRemoteKit
import Security
import SystemConfiguration

/// A reminder as it goes to the iPhone and Apple Watch. What may leave the Mac
/// is decided when it's sent, by the choices in Settings.
struct PhoneReminder: Equatable {
    var title: String
    /// The job's name, folder and server: sent only with "Include job names".
    var identifying: [String] = []
    /// Safe anywhere: "took 48s", "Resets in 2h".
    var details: [String] = []
    /// The agent's last words: sent only with "Include the agent's last words".
    var summary: String?
    var tags: [String] = []
    var priority = 3
}

/// Sends Agent Buddy's reminders to the iPhone and Apple Watch through an ntfy
/// server (the ntfy app shows them; Apple Watch mirrors the iPhone), and the
/// status Agent Buddy Remote shows, on a topic of its own.
@MainActor
final class PhoneLink: ObservableObject {
    enum Delivery: Equatable {
        case sent(Date)
        case failed(String)
    }

    @Published private(set) var reminderDelivery: Delivery?
    @Published private(set) var statusDelivery: Delivery?
    @Published private(set) var testing = false
    /// Messages sent today; ntfy.sh takes 250 a day from one address.
    @Published private(set) var sentToday = 0

    /// What Agent Buddy Remote shows; the model sets it.
    var makeSnapshot: (() -> RemoteSnapshot?)?

    private let settings: AppSettings
    private var defaults: UserDefaults { settings.defaults }
    private var started = false
    private var statusTimer: Timer?
    private var heartbeat: Timer?
    private var urgent = false
    private var lastSignature: Data?
    private var lastStatusAt: Date?
    private var subscriptions: Set<AnyCancellable> = []

    /// ntfy.sh's daily allowance, and how much of it the status may use.
    static let publicDailyLimit = 250
    private static let statusAllowance = 200

    init(settings: AppSettings) {
        self.settings = settings
        sentToday = defaults.string(forKey: "phone.countDay") == Self.today() ? defaults.integer(forKey: "phone.count") : 0
    }

    /// Starts sending (the app, not the snapshot or self-test modes).
    func start() {
        guard !started else { return }
        started = true
        // A status at least every 3 hours keeps one in ntfy's 12-hour cache.
        heartbeat = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.statusChanged() }
        }
        heartbeat?.tolerance = 60
        // Turning sending on, a new topic or server, or a privacy choice sends the status soon.
        settings.objectWillChange
            .debounce(for: .seconds(2), scheduler: RunLoop.main)
            .sink { [weak self] _ in Task { @MainActor in self?.statusChanged(urgent: true) } }
            .store(in: &subscriptions)
        statusChanged()
    }

    var pairing: Pairing? { settings.phonePairing }

    /// The public ntfy.sh, with its daily limit, rather than a server of your own.
    var onPublicServer: Bool {
        guard let pairing else { return false }
        return NtfyClient(pairing: pairing).base?.host?.lowercased() == "ntfy.sh"
    }

    // MARK: - Reminders

    func send(_ reminder: PhoneReminder) {
        guard started, let pairing else { return }
        if settings.phoneTiming == .away && !Presence.isAway() {
            return
        }
        publish(message(reminder, topic: pairing.topic), to: pairing) { [weak self] result in
            self?.reminderDelivery = result
        }
    }

    /// The reminder as ntfy gets it, with the privacy choices applied.
    func message(_ reminder: PhoneReminder, topic: String) -> PushMessage {
        PushMessage(
            topic: topic, title: reminder.title,
            message: PushComposer.message(
                identifying: reminder.identifying, details: reminder.details, summary: reminder.summary,
                includeTitles: settings.phoneIncludeTitles, includeSummaries: settings.phoneIncludeSummaries),
            tags: reminder.tags, priority: reminder.priority,
            // Tapping it in ntfy opens Agent Buddy Remote, if it's installed: a job's at its window's prompts.
            click: Self.click(for: reminder.tags))
    }

    /// Where a tapped reminder leads in Agent Buddy Remote: a job's window, else the app.
    static func click(for tags: [String]) -> String {
        guard let window = tags.first(where: { $0.hasPrefix("hsw-") }) else { return "agentbuddy://open" }
        return "agentbuddy://open?window=\(window)"
    }

    /// A test reminder, and the status at once.
    func sendTest() {
        guard let pairing else { return }
        testing = true
        let reminder = PhoneReminder(
            title: "Agent Buddy test", details: ["Reminders from \(Self.macName) will look like this."], tags: ["bell"])
        publish(message(reminder, topic: pairing.topic), to: pairing) { [weak self] result in
            self?.reminderDelivery = result
            self?.testing = false
        }
        if settings.phoneShareStatus {
            publishStatus(force: true)
        }
    }

    // MARK: - The status for Agent Buddy Remote

    /// Something Agent Buddy Remote shows changed. On ntfy.sh the status goes at
    /// most every 15 minutes (a minute when jobs were cleared by hand), to stay
    /// well inside its daily limit; on your own server, every minute.
    func statusChanged(urgent: Bool = false) {
        guard started, pairing != nil, settings.phoneShareStatus else { return }
        self.urgent = self.urgent || urgent
        let shared = onPublicServer
        let spacing: TimeInterval = self.urgent ? (shared ? 60 : 5) : (shared ? 15 * 60 : 60)
        let due = max(Date().addingTimeInterval(shared ? 20 : 3), (lastStatusAt ?? .distantPast).addingTimeInterval(spacing))
        if let timer = statusTimer, timer.isValid, timer.fireDate <= due {
            return
        }
        statusTimer?.invalidate()
        let timer = Timer(fire: due, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.publishStatus() }
        }
        timer.tolerance = 2
        RunLoop.main.add(timer, forMode: .common)
        statusTimer = timer
    }

    private func publishStatus(force: Bool = false) {
        statusTimer?.invalidate()
        statusTimer = nil
        urgent = false
        guard let pairing, settings.phoneShareStatus, let snapshot = makeSnapshot?() else { return }
        var signature = snapshot.signature
        signature.append(Data("\(pairing.server)|\(pairing.topic)".utf8))
        let stale = lastStatusAt.map { Date().timeIntervalSince($0) > 3 * 3600 } ?? true
        guard force || signature != lastSignature || stale else { return }
        // ntfy.sh's daily allowance is kept for the reminders.
        if onPublicServer && !force && sentToday >= Self.statusAllowance {
            return
        }
        lastSignature = signature
        lastStatusAt = Date()
        let body = String(decoding: snapshot.fitted(), as: UTF8.self)
        let message = PushMessage(topic: pairing.statusTopic, title: "Agent Buddy status", message: body, priority: 1)
        publish(message, to: pairing) { [weak self] result in
            self?.statusDelivery = result
            if case .failed = result {
                // Try again with the next change, or the next half hour.
                self?.lastSignature = nil
            }
        }
    }

    // MARK: - Sending

    /// Sends one message. A reminder that meets a network blip or a server
    /// error is tried again after 20 seconds and after a minute; a refusal isn't.
    private func publish(
        _ message: PushMessage, to pairing: Pairing, retries: [UInt64] = [20, 60], done: @escaping (Delivery) -> Void
    ) {
        let client = NtfyClient(pairing: pairing)
        countOne()
        Task {
            do {
                try await client.publish(message)
                done(.sent(Date()))
            } catch {
                Diagnostics.log("phone: couldn't send to \(pairing.server): \(error.localizedDescription)")
                let passing: Bool
                switch error as? NtfyClient.Failure {
                case .unreachable?: passing = true
                case .http(let code)?: passing = code >= 500
                default: passing = false
                }
                guard passing, let wait = retries.first, message.topic == pairing.topic else {
                    done(.failed(error.localizedDescription))
                    return
                }
                try? await Task.sleep(nanoseconds: wait * 1_000_000_000)
                // Only while sending is still on, to the same place.
                guard self.pairing == pairing else {
                    done(.failed(error.localizedDescription))
                    return
                }
                self.publish(message, to: pairing, retries: Array(retries.dropFirst()), done: done)
            }
        }
    }

    /// A reply to Agent Buddy Remote went: it counts toward ntfy.sh's daily allowance too.
    func noteSent() {
        countOne()
    }

    private func countOne() {
        let day = Self.today()
        if defaults.string(forKey: "phone.countDay") != day {
            defaults.set(day, forKey: "phone.countDay")
            sentToday = 0
        }
        sentToday += 1
        defaults.set(sentToday, forKey: "phone.count")
    }

    private static func today() -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        return "\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)"
    }

    /// The Mac's name, as in Sharing settings.
    static var macName: String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? Host.current().localizedName ?? "Mac"
    }

    /// The pairing link as a QR code, for the iPhone's Camera.
    static func qrCode(_ text: String, points: CGFloat) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage, output.extent.width > 0 else { return nil }
        // Whole pixels per module, at twice the size for Retina screens.
        let scale = max(1, (points * 2 / output.extent.width).rounded(.down))
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let image = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: scaled.extent.width / 2, height: scaled.extent.height / 2))
    }
}

/// Whether you're at the Mac: for "Only when I'm away from this Mac".
enum Presence {
    /// Locked, the display asleep, or no keyboard or mouse use for 3 minutes.
    static func isAway(idleAfter: TimeInterval = 180) -> Bool {
        if let session = CGSessionCopyCurrentDictionary() as? [String: Any],
           (session["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue == true {
            return true
        }
        if CGDisplayIsAsleep(CGMainDisplayID()) != 0 {
            return true
        }
        guard let anyInput = CGEventType(rawValue: ~0) else { return false }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput) >= idleAfter
    }
}

/// The ntfy access token, in the login Keychain.
enum Keychain {
    static let service = "io.github.homoy.agentbuddy"

    private static func query(_ account: String, service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    static func read(account: String, service: String = Keychain.service) -> String? {
        var query = query(account, service: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// An empty value removes the item.
    static func write(_ value: String, account: String) {
        SecItemDelete(query(account, service: service) as CFDictionary)
        guard !value.isEmpty else { return }
        var item = query(account, service: service)
        item[kSecValueData as String] = Data(value.utf8)
        let status = SecItemAdd(item as CFDictionary, nil)
        if status != errSecSuccess {
            Diagnostics.log("couldn't keep the ntfy token in the Keychain (\(status))")
        }
    }
}
