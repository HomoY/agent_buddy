#if canImport(WebKit) && !os(watchOS)
import SwiftUI
import WebKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Where the renderer's files are: in the resource bundle SwiftPM makes for this
/// target, among the app's resources (Agent Buddy on the Mac), at the app's top
/// (an iPhone app), or beside a command-line build, else in the source folder
/// (a debug build run from the checkout). Nil if none has them: answers then
/// show as plain formatted text.
public enum MarkdownAssets {
    static let bundleName = "AgentBuddyRemoteKit_AgentBuddyMarkdown.bundle"

    public static let folder: URL? = {
        let manager = FileManager.default
        var bundles: [URL] = []
        if let resources = Bundle.main.resourceURL {
            bundles.append(resources.appendingPathComponent(bundleName))
        }
        bundles.append(Bundle.main.bundleURL.appendingPathComponent(bundleName))
        for bundle in bundles {
            for web in [bundle.appendingPathComponent("Web"), bundle.appendingPathComponent("Contents/Resources/Web")]
            where manager.fileExists(atPath: web.appendingPathComponent("answer.html").path) {
                return web
            }
        }
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Web")
        return manager.fileExists(atPath: source.appendingPathComponent("answer.html").path) ? source : nil
    }()
}

/// The typeface of an answer's text (code stays monospaced).
public enum MarkdownFont: String, CaseIterable, Sendable {
    case system
    case serif
    case monospaced

    var css: String? {
        switch self {
        case .system: return nil
        case .serif: return "ui-serif, \"New York\", Georgia, serif"
        case .monospaced: return "ui-monospace, \"SF Mono\", Menlo, monospace"
        }
    }
}

extension MarkdownView {
    /// Posted when what's selected on an answer's page changes: `object`, the
    /// page's view; `userInfo["text"]`, the text (empty when nothing is).
    public static let selectionDidChange = Notification.Name("AgentBuddyMarkdownSelectionDidChange")
    /// Post when a selection made on a page is done with (sent, dismissed, replaced):
    /// the pages stop marking it.
    public static let clearKeptSelection = Notification.Name("AgentBuddyMarkdownClearKeptSelection")
}

/// Words searched for on a page, and the last request to scroll to the first.
struct AnswerSearch: Equatable {
    var query = ""
    var reveal = 0
}

/// What's drawn: an answer's Markdown, or a turn's steps as JSON.
enum AnswerContent: Hashable {
    case markdown(String)
    case steps(String)

    var size: Int {
        switch self {
        case .markdown(let text), .steps(let text): return text.count
        }
    }
}

/// An agent's answer from its Markdown: formulas by KaTeX, code in boxes,
/// tables, lists and links, drawn by WebKit from files bundled with the app.
/// It's as tall as the answer, scrolls with what's around it, and its text can
/// be selected and copied. Links open in the browser.
public struct MarkdownView: View {
    let content: AnswerContent
    let fontSize: CGFloat
    let font: MarkdownFont
    /// Words searched for, marked where they show; `revealing` changed, the window scrolls to the first.
    var search = AnswerSearch()
    @State private var height: CGFloat

    public init(_ markdown: String, fontSize: CGFloat, font: MarkdownFont = .system) {
        content = .markdown(markdown)
        self.fontSize = fontSize
        self.font = font
        _height = State(initialValue: MeasuredHeights.shared.height(of: .markdown(markdown), fontSize: fontSize, font: font)
            ?? Self.estimate(markdown, fontSize: fontSize))
    }

    /// A turn's steps, as the agent's terminal shows them after a ●: JSON, an
    /// array of `{kind: "said" | "ran" | "changed", text, outcome, failed,
    /// hunks: [{oldStart, newStart, lines}]}`. Outputs past three lines, and
    /// changes past ten, fold away until opened.
    /// - Parameter estimate: about how tall it will be, until it's measured.
    public init(stepsJSON: String, fontSize: CGFloat, font: MarkdownFont = .system, estimate: CGFloat? = nil) {
        content = .steps(stepsJSON)
        self.fontSize = fontSize
        self.font = font
        _height = State(initialValue: MeasuredHeights.shared.height(of: .steps(stepsJSON), fontSize: fontSize, font: font)
            ?? estimate ?? CGFloat(min(stepsJSON.count / 6, 3000)) + fontSize * 2)
    }

    /// A turn's steps when there are some, else its answer: one page either
    /// way, so an answer shown first gives way to the steps in place, not on a
    /// page made again.
    public init(stepsJSON: String?, orMarkdown markdown: String, fontSize: CGFloat, font: MarkdownFont = .system, estimate: CGFloat? = nil) {
        if let stepsJSON {
            self.init(stepsJSON: stepsJSON, fontSize: fontSize, font: font, estimate: estimate)
        } else {
            self.init(markdown, fontSize: fontSize, font: font)
        }
    }

    /// Whether the renderer's files are there.
    public static var available: Bool {
        MarkdownAssets.folder != nil
    }

    public var body: some View {
        AnswerWebView(content: content, fontSize: fontSize, font: font, search: search, height: $height)
            .frame(height: max(height, fontSize * 1.5))
    }

    /// `query` marked wherever it shows; each new `reveal` number scrolls the window to the first (0: never).
    public func searching(_ query: String, reveal: Int = 0) -> MarkdownView {
        var view = self
        view.search = AnswerSearch(query: query, reveal: reveal)
        return view
    }

    /// About how tall it will be, until it's measured.
    static func estimate(_ text: String, fontSize: CGFloat) -> CGFloat {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).reduce(0) { $0 + $1.count / 80 + 1 }
        return CGFloat(min(lines, 400)) * fontSize * 1.45
    }
}

#if os(macOS)
/// Up and down scrolls the window's history around it; sideways, a wide code box or formula.
final class AnswerWebKitView: WKWebView {
    override func scrollWheel(with event: NSEvent) {
        if abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) {
            nextResponder?.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }
}

struct AnswerWebView: NSViewRepresentable {
    let content: AnswerContent
    let fontSize: CGFloat
    let font: MarkdownFont
    let search: AnswerSearch
    @Binding var height: CGFloat

    func makeCoordinator() -> AnswerCoordinator {
        AnswerCoordinator(height: $height)
    }

    func makeNSView(context: Context) -> WKWebView {
        let view = AnswerWebKitView(frame: .zero, configuration: AnswerCoordinator.configuration(context.coordinator))
        view.setValue(false, forKey: "drawsBackground")
        context.coordinator.attach(view)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.height = $height
        context.coordinator.show(content, fontSize: fontSize, font: font, in: view)
        context.coordinator.mark(search, in: view)
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: AnswerCoordinator) {
        coordinator.detach(view)
    }
}
#else
struct AnswerWebView: UIViewRepresentable {
    let content: AnswerContent
    let fontSize: CGFloat
    let font: MarkdownFont
    let search: AnswerSearch
    @Binding var height: CGFloat

    func makeCoordinator() -> AnswerCoordinator {
        AnswerCoordinator(height: $height)
    }

    func makeUIView(context: Context) -> WKWebView {
        let view = WKWebView(frame: .zero, configuration: AnswerCoordinator.configuration(context.coordinator))
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.scrollView.isScrollEnabled = false
        view.scrollView.bounces = false
        context.coordinator.attach(view)
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.height = $height
        context.coordinator.show(content, fontSize: fontSize, font: font, in: view)
        context.coordinator.mark(search, in: view)
    }

    static func dismantleUIView(_ view: WKWebView, coordinator: AnswerCoordinator) {
        coordinator.detach(view)
    }
}
#endif

/// Loads the page once, renders each new answer into it, and takes its height.
@MainActor
final class AnswerCoordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    var height: Binding<CGFloat>
    private var loaded = false
    private var wanted: (content: AnswerContent, fontSize: CGFloat, font: MarkdownFont)?
    private var shown: (content: AnswerContent, fontSize: CGFloat, font: MarkdownFont)?

    init(height: Binding<CGFloat>) {
        self.height = height
    }

    static func configuration(_ coordinator: AnswerCoordinator) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(WeakMessages(coordinator), name: "size")
        configuration.userContentController.add(WeakMessages(coordinator), name: "reveal")
        configuration.userContentController.add(WeakMessages(coordinator), name: "selection")
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        return configuration
    }

    /// The page, for scrolling the window to a part of it.
    private weak var view: WKWebView?
    /// What's selected on it now.
    private(set) var selected = ""

    private var clearing: NSObjectProtocol?

    func attach(_ view: WKWebView) {
        self.view = view
        view.navigationDelegate = self
        clearing = NotificationCenter.default.addObserver(forName: MarkdownView.clearKeptSelection, object: nil, queue: .main) { [weak view] _ in
            view?.evaluateJavaScript("window.clearKept && clearKept()", completionHandler: nil)
        }
        guard let folder = MarkdownAssets.folder else { return }
        view.loadFileURL(folder.appendingPathComponent("answer.html"), allowingReadAccessTo: folder)
    }

    func detach(_ view: WKWebView) {
        if let clearing {
            NotificationCenter.default.removeObserver(clearing)
        }
        view.navigationDelegate = nil
        view.configuration.userContentController.removeScriptMessageHandler(forName: "size")
        view.configuration.userContentController.removeScriptMessageHandler(forName: "reveal")
        view.configuration.userContentController.removeScriptMessageHandler(forName: "selection")
    }

    func show(_ content: AnswerContent, fontSize: CGFloat, font: MarkdownFont = .system, in view: WKWebView) {
        wanted = (content, fontSize, font)
        render(in: view)
    }

    private func render(in view: WKWebView) {
        guard loaded, let wanted,
              wanted.content != shown?.content || wanted.fontSize != shown?.fontSize || wanted.font != shown?.font
        else { return }
        shown = wanted
        func json<T: Encodable>(_ value: T) -> String {
            (try? JSONEncoder().encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "null"
        }
        var options = ["size": json(Double(wanted.fontSize))]
        if let css = wanted.font.css {
            options["font"] = json(css)
        }
        let settings = "{" + options.map { "\($0.key): \($0.value)" }.joined(separator: ", ") + "}"
        switch wanted.content {
        case .markdown(let markdown):
            view.evaluateJavaScript("render(\(json(markdown)), \(settings))", completionHandler: nil)
        case .steps(let steps):
            // JSON is a script's literal, but for two line separators older scripts refuse.
            let literal = steps.replacingOccurrences(of: "\u{2028}", with: "\\u2028").replacingOccurrences(of: "\u{2029}", with: "\\u2029")
            view.evaluateJavaScript("renderSteps(\(literal), \(settings))", completionHandler: nil)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
        // A reload (from the page's menu) starts blank: render again.
        shown = nil
        render(in: webView)
        marked = nil
        if let wantedSearch {
            mark(wantedSearch, in: webView)
        }
    }

    private var wantedSearch: AnswerSearch?
    private var marked: AnswerSearch?

    /// Words searched for, marked on the page (it marks them again as it's drawn
    /// anew); asked to reveal again, it scrolls the window to the first.
    func mark(_ search: AnswerSearch, in view: WKWebView) {
        wantedSearch = search
        guard loaded, search != marked else { return }
        let reveal = search.reveal != 0 && search.reveal != marked?.reveal
        marked = search
        let query = (try? JSONEncoder().encode(search.query)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
        view.evaluateJavaScript("window.highlightSearch && highlightSearch(\(query), \(reveal))", completionHandler: nil)
    }

    func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        if navigationAction.navigationType == .linkActivated {
            // A link in an answer opens in the browser, not in here.
            if let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) {
                #if os(macOS)
                NSWorkspace.shared.open(url)
                #else
                UIApplication.shared.open(url)
                #endif
            }
            decisionHandler(.cancel)
            return
        }
        // Only the page itself loads.
        decisionHandler(url.isFileURL ? .allow : .cancel)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "reveal" {
            reveal(message.body)
            return
        }
        if message.name == "selection" {
            selected = message.body as? String ?? ""
            NotificationCenter.default.post(name: MarkdownView.selectionDidChange, object: view, userInfo: ["text": selected])
            return
        }
        guard let value = (message.body as? NSNumber).map({ CGFloat($0.doubleValue) }), value > 0 else { return }
        if let shown {
            MeasuredHeights.shared.remember(value, of: shown.content, fontSize: shown.fontSize, font: shown.font)
        }
        guard abs(value - height.wrappedValue) >= 1 else { return }
        height.wrappedValue = value
    }

    /// A part just opened ("View" on a change): the window around scrolls to it,
    /// once it has made room for it.
    private func reveal(_ body: Any) {
        #if os(macOS)
        guard let place = body as? [String: Any], let top = (place["top"] as? NSNumber)?.doubleValue,
              let height = (place["height"] as? NSNumber)?.doubleValue
        else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak view] in
            guard let view else { return }
            let y = view.isFlipped ? top : view.bounds.height - top - height
            view.scrollToVisible(NSRect(x: 0, y: y, width: 1, height: height))
        }
        #else
        guard let place = body as? [String: Any], let top = (place["top"] as? NSNumber)?.doubleValue,
              let height = (place["height"] as? NSNumber)?.doubleValue
        else { return }
        // The list around it: the first scroll view up from the page (its own doesn't scroll).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak view] in
            guard let view else { return }
            var above = view.superview
            while let current = above, !(current is UIScrollView) {
                above = current.superview
            }
            guard let list = above as? UIScrollView else { return }
            list.scrollRectToVisible(view.convert(CGRect(x: 0, y: top, width: 1, height: height), to: list), animated: true)
        }
        #endif
    }
}

/// How tall each page was when last measured, by what it showed. A list lets go
/// of rows out of sight and makes them again to lay itself out: a page made
/// again starts at its height, not a guess, so the list doesn't change height
/// under what you're reading (and a message box typed into, which redraws the
/// window, doesn't move it).
final class MeasuredHeights: @unchecked Sendable {
    static let shared = MeasuredHeights()
    private let lock = NSLock()
    private var heights: [Int: CGFloat] = [:]

    private func key(_ content: AnswerContent, _ fontSize: CGFloat, _ font: MarkdownFont) -> Int {
        var hasher = Hasher()
        hasher.combine(content)
        hasher.combine(fontSize)
        hasher.combine(font)
        return hasher.finalize()
    }

    func height(of content: AnswerContent, fontSize: CGFloat, font: MarkdownFont) -> CGFloat? {
        let key = key(content, fontSize, font)
        lock.lock()
        defer { lock.unlock() }
        return heights[key]
    }

    func remember(_ height: CGFloat, of content: AnswerContent, fontSize: CGFloat, font: MarkdownFont) {
        let key = key(content, fontSize, font)
        lock.lock()
        defer { lock.unlock() }
        // Answers come and go: the oldest heights are forgotten, all at once.
        if heights.count >= 2000 {
            heights.removeAll()
        }
        heights[key] = height
    }
}

/// The page holds its message handler strongly: this lets the coordinator go.
private final class WeakMessages: NSObject, WKScriptMessageHandler {
    weak var target: AnswerCoordinator?

    init(_ target: AnswerCoordinator) {
        self.target = target
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            target?.userContentController(userContentController, didReceive: message)
        }
    }
}
#endif

#if os(macOS) && canImport(WebKit)
/// For the self-test: draws an answer off screen, then says what the page
/// made of it (by CSS selector) and gives a picture of it.
@MainActor
public enum MarkdownProbe {
    public struct Result {
        public var height: CGFloat
        public var counts: [String: Int]
        public var image: NSImage?
        /// What the page last said is selected.
        public var selected: String?
        /// What `asking` came to, run on the page last.
        public var answer: String?
    }

    public static func render(
        _ markdown: String, counting selectors: [String], width: CGFloat = 520, fontSize: CGFloat = 13, dark: Bool = false,
        then script: String? = nil, asking question: String? = nil, timeout: TimeInterval = 15
    ) async -> Result? {
        await render(.markdown(markdown), counting: selectors, width: width, fontSize: fontSize, font: .system, dark: dark, then: script,
                     asking: question, timeout: timeout)
    }

    /// A turn's steps (as `MarkdownView(stepsJSON:)` takes them), the same way;
    /// `then` runs on the page first (a click on a part).
    public static func render(
        stepsJSON: String, counting selectors: [String], width: CGFloat = 520, fontSize: CGFloat = 13, font: MarkdownFont = .system,
        dark: Bool = false, then script: String? = nil, asking question: String? = nil, timeout: TimeInterval = 15
    ) async -> Result? {
        await render(.steps(stepsJSON), counting: selectors, width: width, fontSize: fontSize, font: font, dark: dark, then: script,
                     asking: question, timeout: timeout)
    }

    static func render(
        _ content: AnswerContent, counting selectors: [String], width: CGFloat, fontSize: CGFloat, font: MarkdownFont, dark: Bool,
        then script: String? = nil, asking question: String? = nil, timeout: TimeInterval
    ) async -> Result? {
        guard MarkdownAssets.folder != nil else { return nil }
        final class Box {
            var height: CGFloat = 0
        }
        let box = Box()
        let coordinator = AnswerCoordinator(height: Binding(get: { box.height }, set: { box.height = $0 }))
        let view = AnswerWebKitView(frame: NSRect(x: 0, y: 0, width: width, height: 100), configuration: AnswerCoordinator.configuration(coordinator))
        view.setValue(false, forKey: "drawsBackground")
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: width, height: 100), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.backgroundColor = dark ? .black : .white
        window.contentView = view
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        coordinator.attach(view)
        coordinator.show(content, fontSize: fontSize, font: font, in: view)
        let deadline = Date().addingTimeInterval(timeout)
        while box.height == 0, Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard box.height > 0 else { return nil }
        // Fonts arrive after the first layout; let the height settle.
        try? await Task.sleep(nanoseconds: 700_000_000)
        view.setFrameSize(NSSize(width: width, height: box.height))
        window.setContentSize(NSSize(width: width, height: box.height))
        try? await Task.sleep(nanoseconds: 300_000_000)
        if let script {
            _ = try? await view.evaluateJavaScript(script)
            try? await Task.sleep(nanoseconds: 400_000_000)
            if box.height > 0 {
                view.setFrameSize(NSSize(width: width, height: box.height))
                window.setContentSize(NSSize(width: width, height: box.height))
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        var counts: [String: Int] = [:]
        for selector in selectors {
            let script = "document.querySelectorAll(\(String(data: try! JSONEncoder().encode(selector), encoding: .utf8)!)).length"
            counts[selector] = (try? await view.evaluateJavaScript(script) as? NSNumber)?.intValue ?? -1
        }
        let answer = question == nil ? nil : (try? await view.evaluateJavaScript(question!)) as? String
        let image = try? await view.takeSnapshot(configuration: nil)
        return Result(height: box.height, counts: counts, image: image, selected: coordinator.selected.isEmpty ? nil : coordinator.selected,
                      answer: answer)
    }
}
#endif
