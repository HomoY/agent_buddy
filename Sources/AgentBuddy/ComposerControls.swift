import AgentBuddyCore
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The message box's controls, as an agent's own has them: + for files, how
/// it may act (Auto…), the model, its effort and fast mode. Each starts as the
/// session has it; a choice holds for the prompts sent from this window.
struct ComposerControls: View {
    @ObservedObject var details: SessionDetails
    @ObservedObject var composing: MessageDraft

    /// The session as it is, and as it would be sent.
    private var session: PromptSender.Request? { details.sessionRequest("\u{2026}") }
    private var chosen: PromptSender.Request? { session?.with(composing.options) }

    var body: some View {
        // However narrow the window, the controls stay on one line, each whole:
        // the mode's and fast mode's names give way to their symbols, then the effort's.
        ViewThatFits(in: .horizontal) {
            bar(.names)
            bar(.symbols)
            bar(.fewest)
        }
        .onAppear { details.loadModels() }
    }

    /// How much of the controls' names show.
    private enum Names {
        case names, symbols, fewest
    }

    private func bar(_ names: Names) -> some View {
        HStack(spacing: 2) {
            addMenu
            modeMenu(named: names == .names)
            modelMenu
            effortMenu(named: names != .fewest)
            fastToggle(named: names == .names)
        }
        .fixedSize()
    }

    // MARK: - +

    private var addMenu: some View {
        Menu {
            Button("Add Files or Photos\u{2026}") { Attachments.choose(into: composing) }
            Button("Paste Image or File") { Attachments.paste(into: composing) }
                .disabled(!Attachments.canPaste)
        } label: {
            Image(systemName: "plus")
        }
        .composerMenu()
        .help("Send files or pictures with the prompt (or drop them on the box)")
    }

    // MARK: - Mode

    private struct Mode {
        let id: String
        let name: String
        let what: String
    }

    private var modes: [Mode] {
        var modes: [Mode]
        switch details.agent {
        case .claude:
            modes = [Mode(id: "auto", name: "Auto", what: "Claude decides what's safe to do"),
                     Mode(id: "acceptEdits", name: "Accept edits", what: "it edits files; anything else that asks is refused"),
                     Mode(id: "plan", name: "Plan", what: "it plans, and changes nothing")]
            // The session's own, when it's none of these (one that skipped the checks
            // keeps them from here): nothing that asks goes through.
            let own = session?.permissionMode ?? "default"
            if !modes.contains(where: { $0.id == own }) {
                modes.append(Mode(id: own, name: "Ask first", what: "anything that asks is refused, as no one's here to answer"))
            }
        case .codex:
            modes = [Mode(id: "auto", name: "Auto", what: "it works in the folder; Codex's reviewer decides a step beyond it"),
                     Mode(id: "workspace", name: "Folder only", what: "it works in the folder; a step beyond is refused"),
                     Mode(id: "read-only", name: "Read only", what: "it reads, and changes nothing")]
        default:
            modes = []
        }
        return modes
    }

    private func modeMenu(named: Bool) -> some View {
        let current = chosen?.mode ?? (details.agent == .claude ? "default" : "workspace")
        let shown = modes.first { $0.id == current } ?? modes.last
        return Menu {
            Picker("Mode", selection: Binding(
                get: { current },
                set: { composing.options.mode = $0 == (session?.mode ?? "default") ? nil : $0 })) {
                ForEach(modes, id: \.id) { mode in
                    Text("\(mode.name): \(mode.what)").tag(mode.id)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            if named {
                Label(shown?.name ?? "Mode", systemImage: current == "auto" ? "wand.and.stars" : "hand.raised")
            } else {
                Image(systemName: current == "auto" ? "wand.and.stars" : "hand.raised")
            }
        }
        .composerMenu(highlighted: current == "auto")
        .help("How it may act: \(shown?.what ?? "")")
    }

    // MARK: - Model

    private var modelMenu: some View {
        let current = chosen?.model
        return Menu {
            Picker("Model", selection: Binding(
                get: { current ?? "" },
                set: { composing.options.model = $0 == session?.model ? nil : $0 })) {
                ForEach(models, id: \.id) { model in
                    Text(model.name).tag(model.id)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            if details.agent == .codex, composing.codexModels == nil {
                Text(composing.modelsProblem.map { "Codex's models: \($0)" } ?? "Asking Codex for its models\u{2026}")
            }
        } label: {
            Text(current.map(name) ?? "Model")
        }
        .composerMenu()
        .help("The model for prompts sent from here")
    }

    /// The models to choose from, the session's among them.
    private var models: [(id: String, name: String)] {
        var models: [(id: String, name: String)]
        switch details.agent {
        case .claude:
            models = ClaudeModels.choices.map { ($0, ClaudeModels.name($0) + " (latest)") }
        case .codex:
            models = (composing.codexModels ?? []).map { ($0.id, $0.name) }
        default:
            models = []
        }
        for model in [session?.model, composing.options.model].compactMap({ $0 }) where !models.contains(where: { $0.id == model }) {
            models.insert((model, name(model)), at: 0)
        }
        return models
    }

    private func name(_ model: String) -> String {
        switch details.agent {
        case .claude: return ClaudeModels.name(model)
        default: return composing.codexModels?.first { $0.id == model }?.name ?? model
        }
    }

    // MARK: - Effort

    private var efforts: [String] {
        switch details.agent {
        case .claude:
            return ClaudeModels.efforts
        case .codex:
            let model = composing.codexModels?.first { $0.id == chosen?.model }
            return model?.efforts.isEmpty == false ? model?.efforts ?? [] : ["low", "medium", "high", "xhigh"]
        default:
            return []
        }
    }

    private func effortMenu(named: Bool) -> some View {
        let current = chosen?.effort
        return Menu {
            Picker("Effort", selection: Binding(
                get: { current ?? "" },
                set: { composing.options.effort = $0.isEmpty || $0 == session?.effort ? nil : $0 })) {
                if session?.effort == nil {
                    Text("As it's set").tag("")
                }
                ForEach(efforts, id: \.self) { effort in
                    Text(Self.effortName(effort)).tag(effort)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            if named {
                Text(current.map(Self.effortName) ?? "Effort")
            } else {
                Image(systemName: "gauge.with.dots.needle.50percent")
            }
        }
        .composerMenu()
        .help("How hard it thinks" + (current.map { ": \(Self.effortName($0))" } ?? ""))
    }

    static func effortName(_ effort: String) -> String {
        switch effort {
        case "xhigh": return "Extra high"
        default: return effort.prefix(1).uppercased() + effort.dropFirst()
        }
    }

    // MARK: - Fast

    /// Codex's fast mode is a model's; while the list isn't in, it's offered.
    private var fastAvailable: Bool {
        guard details.agent == .codex, let models = composing.codexModels else { return details.agent != .copilot }
        return models.first { $0.id == chosen?.model }?.fast ?? true
    }

    private func fastToggle(named: Bool) -> some View {
        let on = chosen?.fast == true
        return Button {
            composing.options.fast = !on
        } label: {
            Label("Fast", systemImage: on ? "bolt.fill" : "bolt")
        }
        .buttonStyle(ComposerChipStyle(highlighted: on, named: named))
        .disabled(!fastAvailable)
        .help(details.agent == .claude
              ? "Fast mode: the same model, faster output (it uses more of your usage)"
              : "Fast mode: Codex's faster tier (it uses more of your usage)")
    }
}

/// The files to send with the prompt, each with its × to leave it out.
struct AttachedFiles: View {
    @ObservedObject var composing: MessageDraft

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(composing.files, id: \.self) { file in
                    HStack(spacing: 4) {
                        Image(systemName: PromptSender.isImage(file.path) ? "photo" : "doc")
                            .foregroundStyle(.secondary)
                        Text(file.lastPathComponent)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 160, alignment: .leading)
                        Button {
                            composing.files.removeAll { $0 == file }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("Don't send it")
                    }
                    .uiFont(11)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.12)))
                    .help(file.path)
                }
            }
        }
    }
}

/// Adding files to the message box: chosen, pasted or dropped.
@MainActor
enum Attachments {
    /// At most this many files with a prompt.
    static let most = 10

    static func add(_ urls: [URL], to composing: MessageDraft) {
        for url in urls where url.isFileURL && !composing.files.contains(url) && composing.files.count < most {
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), !isFolder.boolValue else { continue }
            composing.files.append(url)
        }
    }

    static func choose(into composing: MessageDraft) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Files and pictures to send with the prompt"
        panel.prompt = "Add"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK {
            add(panel.urls, to: composing)
        }
    }

    static var canPaste: Bool {
        let pasteboard = NSPasteboard.general
        return pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            || pasteboard.canReadObject(forClasses: [NSImage.self], options: nil)
    }

    /// The clipboard's files, or its picture (a screenshot copied, say), kept as a PNG.
    static func paste(into composing: MessageDraft) {
        let pasteboard = NSPasteboard.general
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return add(urls, to: composing)
        }
        guard let image = pasteboard.readObjects(forClasses: [NSImage.self], options: nil)?.first as? NSImage,
              let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { return }
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Agent Buddy/Pasted", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let file = folder.appendingPathComponent("Pasted image \(stamp.string(from: Date())).png")
        if (try? png.write(to: file)) != nil {
            add([file], to: composing)
        }
    }

    /// Files dropped on the box.
    static func drop(_ providers: [NSItemProvider], into composing: MessageDraft) -> Bool {
        let files = providers.filter { $0.canLoadObject(ofClass: NSURL.self) }
        for provider in files {
            _ = provider.loadObject(ofClass: NSURL.self) { object, _ in
                guard let url = (object as? NSURL) as URL? else { return }
                Task { @MainActor in add([url], to: composing) }
            }
        }
        return !files.isEmpty
    }
}

/// A control in the message box's bar: small, in the label's color as macOS
/// draws a borderless menu's, tinted when it's on.
struct ComposerChipStyle: ButtonStyle {
    var highlighted = false
    /// Its name beside its symbol, or the symbol alone.
    var named = true

    func makeBody(configuration: Configuration) -> some View {
        Group {
            if named {
                configuration.label.labelStyle(.titleAndIcon)
            } else {
                configuration.label.labelStyle(.iconOnly)
            }
        }
            .font(.system(size: NSFont.smallSystemFontSize))
            // Whole, on one line: never squeezed into a column of letters.
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .foregroundStyle(highlighted ? Color.accentColor : Color.primary)
            .background(RoundedRectangle(cornerRadius: 6).fill(
                highlighted ? Color.accentColor.opacity(configuration.isPressed ? 0.25 : 0.14)
                    : Color.secondary.opacity(configuration.isPressed ? 0.18 : 0.0)))
            .contentShape(Rectangle())
    }
}

extension View {
    /// A menu in the message box's bar: macOS draws it, small; tinted when it's on.
    func composerMenu(highlighted: Bool = false) -> some View {
        self
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .controlSize(.small)
            .fixedSize()
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6).fill(highlighted ? Color.accentColor.opacity(0.14) : Color.clear))
    }
}
