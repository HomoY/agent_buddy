import AgentBuddyMarkdown
import AppKit
import SwiftUI

/// The agent windows' text: its size and typeface, the same in every window.
/// The title bar's Aa sets them, and ⌘+, ⌘− and ⌘0.
enum TextStyle {
    static let sizeKey = "agentWindow.textSize"
    static let fontKey = "agentWindow.font"
    static let standardSize = 12.5
    static let sizes: ClosedRange<Double> = 10...22

    static func bigger() {
        change(by: 1)
    }

    static func smaller() {
        change(by: -1)
    }

    static func reset() {
        UserDefaults.standard.removeObject(forKey: sizeKey)
    }

    private static func change(by step: Double) {
        let now = UserDefaults.standard.object(forKey: sizeKey) as? Double ?? standardSize
        UserDefaults.standard.set(min(max(now + step, sizes.lowerBound), sizes.upperBound), forKey: sizeKey)
    }

    static func design(_ font: MarkdownFont) -> Font.Design {
        switch font {
        case .system: return .default
        case .serif: return .serif
        case .monospaced: return .monospaced
        }
    }

    static func name(_ font: MarkdownFont) -> String {
        switch font {
        case .system: return "System"
        case .serif: return "Serif"
        case .monospaced: return "Mono"
        }
    }
}

/// The menu's ⌘+, ⌘− and ⌘0.
@MainActor
final class TextStyleCommands: NSObject {
    static let shared = TextStyleCommands()

    @objc func bigger(_ sender: Any?) {
        TextStyle.bigger()
    }

    @objc func smaller(_ sender: Any?) {
        TextStyle.smaller()
    }

    @objc func reset(_ sender: Any?) {
        TextStyle.reset()
    }
}

/// Aa in an agent window's title bar: the text's size and typeface.
struct TextStyleButton: View {
    @AppStorage(TextStyle.sizeKey) private var size = TextStyle.standardSize
    @AppStorage(TextStyle.fontKey) private var font: MarkdownFont = .system
    @State private var shown = false

    var body: some View {
        Button {
            shown.toggle()
        } label: {
            Image(systemName: "textformat.size")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Text size and font")
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            TextStyleControls(
                size: "\(size.formatted()) pt", smaller: TextStyle.smaller, bigger: TextStyle.bigger,
                canShrink: size > TextStyle.sizes.lowerBound, canGrow: size < TextStyle.sizes.upperBound,
                font: $font, reset: size == TextStyle.standardSize && font == .system ? nil : {
                    TextStyle.reset()
                    font = .system
                },
                note: "Prompts and answers in every agent window; code stays monospaced. The rest of Agent Buddy has its own, in Settings \u{203A} Appearance.")
                .padding(10)
                .frame(width: 300)
        }
    }
}

// MARK: - General display

/// The rest of Agent Buddy's text: the menu bar panel, the floating panel,
/// statistics, settings and reminder cards, and the agent windows' headings.
/// Its size is a scale of each text's own; Settings › Appearance sets it.
enum DisplayStyle {
    static let scaleKey = "display.textScale"
    static let fontKey = "display.font"
    static let scales: [Double] = [0.85, 0.92, 1, 1.1, 1.2, 1.35, 1.5]

    static func bigger() {
        step(1)
    }

    static func smaller() {
        step(-1)
    }

    static func reset() {
        UserDefaults.standard.removeObject(forKey: scaleKey)
    }

    private static func step(_ by: Int) {
        let now = UserDefaults.standard.object(forKey: scaleKey) as? Double ?? 1
        let index = scales.firstIndex { $0 >= now - 0.001 } ?? scales.count - 1
        UserDefaults.standard.set(scales[min(max(index + by, 0), scales.count - 1)], forKey: scaleKey)
    }
}

private struct DisplayTextScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

private struct DisplayTextDesignKey: EnvironmentKey {
    static let defaultValue: Font.Design = .default
}

extension EnvironmentValues {
    /// The General display size, as a scale of each text's own.
    var displayTextScale: CGFloat {
        get { self[DisplayTextScaleKey.self] }
        set { self[DisplayTextScaleKey.self] = newValue }
    }

    /// The General display typeface.
    var displayTextDesign: Font.Design {
        get { self[DisplayTextDesignKey.self] }
        set { self[DisplayTextDesignKey.self] = newValue }
    }
}

/// A window's content, in the General display size and typeface.
struct DisplayStyled<Content: View>: View {
    let content: Content
    @AppStorage(DisplayStyle.scaleKey) private var scale = 1.0
    @AppStorage(DisplayStyle.fontKey) private var font: MarkdownFont = .system

    var body: some View {
        content
            .environment(\.displayTextScale, CGFloat(scale))
            .environment(\.displayTextDesign, TextStyle.design(font))
    }
}

/// `size` points scaled by the General display size, in its typeface (unless
/// the text asks for its own, such as monospaced code).
struct DisplayFont: ViewModifier {
    let size: CGFloat
    let weight: Font.Weight
    let design: Font.Design?
    let digits: Bool
    @SwiftUI.Environment(\.displayTextScale) private var scale
    @SwiftUI.Environment(\.displayTextDesign) private var chosen

    func body(content: Content) -> some View {
        let font = Font.system(size: size * scale, weight: weight, design: design ?? chosen)
        content.font(digits ? font.monospacedDigit() : font)
    }
}

extension View {
    /// In the General display size and typeface.
    func displayStyled() -> DisplayStyled<Self> {
        DisplayStyled(content: self)
    }

    /// Text at `size` points, as the General display size scales it; `digits`, figures all one width.
    func uiFont(_ size: CGFloat, weight: Font.Weight = .regular, design: Font.Design? = nil, digits: Bool = false) -> some View {
        modifier(DisplayFont(size: size, weight: weight, design: design, digits: digits))
    }

    /// A column `width` points wide at 100%, as wide as its text at other sizes.
    func uiWidth(_ width: CGFloat, alignment: Alignment = .center) -> some View {
        modifier(DisplayWidth(width: width, alignment: alignment))
    }
}

struct DisplayWidth: ViewModifier {
    let width: CGFloat
    let alignment: Alignment
    @SwiftUI.Environment(\.displayTextScale) private var scale

    func body(content: Content) -> some View {
        content.frame(width: width * scale, alignment: alignment)
    }
}

// MARK: - Settings › Appearance

/// Settings › Appearance: a box for the agent windows' prompts and answers, and
/// one for the rest of Agent Buddy.
struct TextSettings: View {
    @AppStorage(TextStyle.sizeKey) private var agentSize = TextStyle.standardSize
    @AppStorage(TextStyle.fontKey) private var agentFont: MarkdownFont = .system
    @AppStorage(DisplayStyle.scaleKey) private var scale = 1.0
    @AppStorage(DisplayStyle.fontKey) private var displayFont: MarkdownFont = .system

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GroupBox {
                TextStyleControls(
                    size: "\(agentSize.formatted()) pt", smaller: TextStyle.smaller, bigger: TextStyle.bigger,
                    canShrink: agentSize > TextStyle.sizes.lowerBound, canGrow: agentSize < TextStyle.sizes.upperBound,
                    font: $agentFont, reset: agentSize == TextStyle.standardSize && agentFont == .system ? nil : {
                        TextStyle.reset()
                        agentFont = .system
                    },
                    note: "Prompts, answers and the message box. Also Aa in an agent window's title bar, and \u{2318}+, \u{2318}\u{2212}, \u{2318}0 there.")
            } label: {
                Text("Agent windows").uiFont(11.5, weight: .semibold)
            }
            GroupBox {
                TextStyleControls(
                    size: "\(Int((scale * 100).rounded()))%", smaller: DisplayStyle.smaller, bigger: DisplayStyle.bigger,
                    canShrink: scale > DisplayStyle.scales[0] + 0.001, canGrow: scale < DisplayStyle.scales[DisplayStyle.scales.count - 1] - 0.001,
                    font: $displayFont, reset: scale == 1 && displayFont == .system ? nil : {
                        DisplayStyle.reset()
                        displayFont = .system
                    },
                    note: "The menu bar panel, the floating panel, statistics, settings, reminder cards, and the agent windows' headings.")
            } label: {
                Text("General display").uiFont(11.5, weight: .semibold)
            }
        }
    }
}

/// A text's size (A− and A+ around it) and typeface, with a reset.
struct TextStyleControls: View {
    let size: String
    let smaller: () -> Void
    let bigger: () -> Void
    let canShrink: Bool
    let canGrow: Bool
    @Binding var font: MarkdownFont
    /// Nil when it's as it was.
    let reset: (() -> Void)?
    let note: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Size")
                Spacer()
                Button(action: smaller) {
                    Image(systemName: "textformat.size.smaller")
                }
                .disabled(!canShrink)
                .help("Smaller")
                Text(size)
                    .monospacedDigit()
                    .frame(minWidth: 44)
                Button(action: bigger) {
                    Image(systemName: "textformat.size.larger")
                }
                .disabled(!canGrow)
                .help("Bigger")
            }
            HStack(spacing: 8) {
                Text("Font")
                Spacer()
                Picker("Font", selection: $font) {
                    ForEach(MarkdownFont.allCases, id: \.self) { font in
                        Text(TextStyle.name(font)).tag(font)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
            }
            HStack(alignment: .top) {
                Text(note)
                    .uiFont(10.5)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 6)
                if let reset {
                    Button("Reset", action: reset)
                        .controlSize(.small)
                }
            }
        }
        .uiFont(12)
        .padding(4)
    }
}
