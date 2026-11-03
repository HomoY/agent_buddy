import AppKit
import AgentBuddyRemoteKit
import SwiftUI

/// Settings ▸ iPhone: where reminders go, what they may say, and a test; what
/// Agent Buddy Remote may do; and how to set up ntfy and Agent Buddy Remote.
struct PhoneSection: View {
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject var phone: PhoneLink
    @State private var token = ""
    @State private var showSetup = false
    /// The snapshot mode draws the set-up steps open.
    var setupOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsGroup("Reminders on iPhone and Apple Watch", note: settings.phoneEnabled ? privacyNote : nil) {
                Toggle("Send reminders to my iPhone and Apple Watch", isOn: $settings.phoneEnabled)
                note("Through the free ntfy app: Agent Buddy sends each reminder to an ntfy server, ntfy shows it on your iPhone, and Apple Watch shows the iPhone's alerts.")
                if settings.phoneEnabled {
                    connection
                }
            }
            if settings.phoneEnabled {
                SettingsGroup("Agent Buddy Remote", note: "It asks for an agent window's prompts and answers, the statistics, or a prompt to send. Requests and replies are sealed with a key only your Mac and the phone that scanned the pairing code have: the server can't read them, and nobody else can send them. A prompt from the phone runs the agent as the message box under a window's prompts does.") {
                    Toggle("Share usage with Agent Buddy Remote", isOn: $settings.phoneShareStatus)
                    Toggle("Let it open jobs and statistics", isOn: $settings.remoteBrowse)
                    Toggle("Let it send prompts", isOn: $settings.remoteSend)
                        .disabled(!settings.remoteBrowse)
                        .padding(.leading, 18)
                }
                SettingsGroup("Set up") {
                    DisclosureGroup("The steps, and the pairing code", isExpanded: $showSetup) {
                        setup.padding(.top, 4)
                    }
                }
            }
        }
        .onAppear {
            token = settings.phoneToken
            showSetup = setupOpen
        }
    }

    /// Where reminders go, when, what they say, and a test.
    @ViewBuilder
    private var connection: some View {
        HStack(spacing: 6) {
            Text("Server").uiWidth(44, alignment: .leading)
            TextField("https://ntfy.sh", text: $settings.phoneServer)
                .textFieldStyle(.roundedBorder)
        }
        HStack(spacing: 6) {
            Text("Topic").uiWidth(44, alignment: .leading)
            Text(settings.phoneTopic)
                .uiFont(11, design: .monospaced)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 4)
            Button("Copy") { copy(settings.phoneTopic) }
            Button("New") { settings.phoneTopic = Pairing.newTopic() }
                .help("Make a new topic. Phones subscribed to the old one stop getting reminders.")
        }
        HStack(spacing: 6) {
            Text("Token").uiWidth(44, alignment: .leading)
            SecureField("Only if the server needs one", text: $token)
                .textFieldStyle(.roundedBorder)
                .onSubmit { settings.phoneToken = token }
            if token != settings.phoneToken {
                Button("Save") { settings.phoneToken = token }
            }
        }
        if serverProblem != nil || plainHTTP {
            Text(serverProblem ?? "Plain http:// sends reminders unencrypted. Use it only on a private network, such as Tailscale.")
                .uiFont(10.5)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
        SettingsRow("Send") {
            Picker("Send", selection: $settings.phoneTiming) {
                ForEach(PhoneTiming.allCases) { timing in
                    Text(timing.label).tag(timing)
                }
            }
        }
        Toggle("Include job names, folders and servers", isOn: $settings.phoneIncludeTitles)
        Toggle("Include the agent's last words", isOn: $settings.phoneIncludeSummaries)
        HStack(spacing: 8) {
            Button("Send a test to iPhone") { phone.sendTest() }
                .disabled(phone.testing || phone.pairing == nil)
            delivery
        }
        if phone.onPublicServer && phone.sentToday >= PhoneLink.publicDailyLimit - 50 {
            Text("\(phone.sentToday) of ntfy.sh's \(PhoneLink.publicDailyLimit) messages a day are used. Usage updates pause first; reminders may stop until tomorrow. A server of your own has no such limit.")
                .uiFont(10.5)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Set-up steps

    private var setup: some View {
        VStack(alignment: .leading, spacing: 8) {
            step(1, "On your iPhone, install ntfy from the App Store and allow its notifications.")
            step(2, ntfySubscribeStep)
            step(3, "Apple Watch shows ntfy's alerts while the iPhone is locked. If it doesn't, open the Watch app on the iPhone, then Notifications, and turn on ntfy under Mirror iPhone Alerts.")
            step(4, "Optional: Agent Buddy Remote, in this project's Companion folder, shows usage, finished jobs, each window's prompts and the statistics on iPhone, and can send prompts. Build it with Xcode, then scan this code with the iPhone's Camera:")
            if let link = phone.pairing?.link {
                HStack(alignment: .top, spacing: 10) {
                    if let code = PhoneLink.qrCode(link.absoluteString, points: 128) {
                        Image(nsImage: code)
                            .interpolation(.none)
                            .padding(6)
                            .background(Color.white, in: RoundedRectangle(cornerRadius: 6))
                            .accessibilityLabel("Pairing code for Agent Buddy Remote")
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        note(phone.pairing?.token == nil
                             ? "The code holds the server, the topic and the key. Keep it to yourself."
                             : "The code holds the server, the topic, your access token and the key. Keep it to yourself.")
                        Button("Copy pairing link") { copy(link.absoluteString) }
                        Button("Make a new code") { settings.phoneKey = Sealed.newKey() }
                            .help("A new key: a phone paired with the old code can no longer ask your Mac for anything.")
                    }
                }
            }
        }
    }

    private var ntfySubscribeStep: String {
        let topic = "In ntfy, tap +, enter the topic above"
        if phone.onPublicServer || phone.pairing == nil {
            return topic + " and tap Subscribe."
        }
        return topic + ", turn on Use another server, enter \(settings.phoneServer), and tap Subscribe."
            + (settings.phoneToken.isEmpty ? "" : " Add the access token under Settings, Manage users.")
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(number).")
                .uiFont(11, weight: .semibold)
                .foregroundStyle(.secondary)
            Text(text)
                .uiFont(11)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Details

    private var privacyNote: String {
        let shown = settings.phoneIncludeTitles ? "Reminders name the job" : "Reminders don't name the job"
        if phone.onPublicServer {
            return "\(shown). They pass through ntfy.sh unencrypted, and anyone who knows the topic can read them for 12 hours. For privacy, run your own ntfy server."
        }
        return "\(shown). They pass through your server, readable to anyone it lets subscribe to the topic."
    }

    @ViewBuilder
    private var delivery: some View {
        if phone.testing {
            ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 14, height: 14)
        } else {
            switch phone.reminderDelivery {
            case .sent(let date)?:
                Label("Sent at \(Format.clock(date, now: Date()))", systemImage: "checkmark.circle.fill")
                    .uiFont(10.5)
                    .foregroundStyle(.green)
            case .failed(let reason)?:
                Text(reason)
                    .uiFont(10.5)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            case nil:
                EmptyView()
            }
        }
    }

    private var serverProblem: String? {
        let pairing = Pairing(server: settings.phoneServer, topic: settings.phoneTopic)
        return NtfyClient(pairing: pairing).base == nil ? "That server address doesn't look right." : nil
    }

    private var plainHTTP: Bool {
        settings.phoneServer.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("http://")
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .uiFont(10.5)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
