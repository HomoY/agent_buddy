import AppKit
import Combine
import AgentBuddyCore
import SwiftUI

func hudColor(_ severity: Severity?) -> Color {
    guard let severity else { return .secondary }
    switch severity {
    case .normal: return .primary
    case .warning: return .orange
    case .critical: return .red
    }
}

/// The floating panel's numbers: the same as the menu bar's, a little larger,
/// e.g. CLAUDE 5h 29% wk 14% · GPT 33% · COPILOT 27%, then the finished-jobs number.
struct FloatingHUDView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        let segments = model.menuSegments()
        HStack(alignment: .center, spacing: 14) {
            if segments.isEmpty {
                Image(systemName: "gauge.with.dots.needle.67percent")
                    .uiFont(16, weight: .semibold)
                    .foregroundStyle(.secondary)
            }
            ForEach(segments, id: \.agent) { segment in
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Circle().fill(segment.agent.chartColor).frame(width: 6, height: 6)
                        Text(segment.label)
                            .uiFont(9, weight: .semibold)
                            .kerning(0.4)
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 8) {
                        ForEach(Array(segment.values.enumerated()), id: \.offset) { _, value in
                            HStack(alignment: .firstTextBaseline, spacing: 2) {
                                if let tag = value.tag {
                                    Text(tag)
                                        .uiFont(10, weight: .semibold)
                                        .foregroundStyle(.secondary)
                                }
                                Text(value.text)
                                    .uiFont(15, weight: .semibold, digits: true)
                                    .foregroundColor(hudColor(value.severity))
                            }
                        }
                    }
                }
            }
            if let badge = MenuBarRenderer.badgeText(model.jobWindows.count) {
                Text(badge)
                    .uiFont(11, weight: .bold, digits: true)
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .frame(minWidth: 22, minHeight: 22)
                    .background(Capsule().fill(Color.blue))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .overlay(
            RoundedRectangle(cornerRadius: FloatingHUDController.cornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12)))
        .fixedSize()
    }
}

/// The panel's content: a translucent rounded background with the numbers on
/// top. It takes every click itself, so the panel can be dragged or clicked.
final class DragHostView: NSView {
    var onClick: (() -> Void)?
    var onMoved: (() -> Void)?
    var onMenu: ((NSEvent) -> Void)?
    /// Where the pointer is, in screen coordinates (replaced in the self-test).
    var pointer: () -> NSPoint = { NSEvent.mouseLocation }

    private let effect = NSVisualEffectView()
    private var start: (mouse: NSPoint, origin: NSPoint)?
    private var dragging = false

    init(content: NSView, cornerRadius: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: 200, height: 44))
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.maskImage = Self.roundedMask(radius: cornerRadius)
        effect.frame = bounds
        effect.autoresizingMask = [.width, .height]
        content.frame = bounds
        content.autoresizingMask = [.width, .height]
        addSubview(effect)
        addSubview(content)
        toolTip = "Drag to move. Click for details. Right-click for options."
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        start = (pointer(), window.frame.origin)
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start, let window else { return }
        let now = pointer()
        let dx = now.x - start.mouse.x
        let dy = now.y - start.mouse.y
        if !dragging {
            guard hypot(dx, dy) >= 3 else { return }
            dragging = true
            NSCursor.closedHand.push()
        }
        window.setFrameOrigin(NSPoint(x: start.origin.x + dx, y: start.origin.y + dy))
    }

    override func mouseUp(with event: NSEvent) {
        guard start != nil else { return }
        let moved = dragging
        start = nil
        dragging = false
        if moved {
            NSCursor.pop()
            onMoved?()
        } else {
            onClick?()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        onMenu?(event)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.cursorUpdate, .activeAlways, .inVisibleRect], owner: self))
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.openHand.set()
    }

    static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// A small panel with the usage numbers that floats above other windows, on
/// every Space, and that you can drag anywhere. It remembers where you put it.
@MainActor
final class FloatingHUDController: NSObject {
    static let cornerRadius: CGFloat = 12
    private static let frameKey = "floatingPanel.frame"

    let panel: NSPanel
    let dragView: DragHostView
    private let host: NSHostingView<AnyView>
    private let popover: PopoverController
    private let model: AppModel
    private var resizeWatch: AnyCancellable?
    /// Called by "Hide Floating Panel".
    var onHide: (() -> Void)?

    init(model: AppModel, popover: PopoverController) {
        self.model = model
        self.popover = popover
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 44),
            styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        host = NSHostingView(rootView: AnyView(EmptyView()))
        dragView = DragHostView(content: host, cornerRadius: Self.cornerRadius)
        super.init()

        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.contentView = dragView

        host.rootView = AnyView(FloatingHUDView().environmentObject(model).environmentObject(model.settings).displayStyled())
        // When the numbers, the tracked agents or the text size change, fit the
        // panel to them, once the change has landed.
        let restyled = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).map { _ in () }
        resizeWatch = model.objectWillChange.merge(with: model.settings.objectWillChange).merge(with: restyled)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor in self?.refit() }
            }
        dragView.onClick = { [weak self] in self?.toggleDetails() }
        dragView.onMoved = { [weak self] in self?.finishMove() }
        dragView.onMenu = { [weak self] event in self?.showMenu(event) }
    }

    var isVisible: Bool { panel.isVisible }

    /// The size the numbers need right now.
    var contentSize: CGSize { host.fittingSize }

    func setVisible(_ visible: Bool) {
        if visible {
            guard !panel.isVisible else { return }
            refit()
            place()
            panel.orderFrontRegardless()
        } else if panel.isVisible {
            popover.close(ifAnchoredTo: dragView)
            panel.orderOut(nil)
        }
    }

    func showDetails() {
        popover.show(from: dragView)
    }

    private func toggleDetails() {
        popover.toggle(from: dragView)
    }

    private func refit() {
        fit(host.fittingSize)
    }

    /// Resizes to the numbers, growing away from the nearest screen edges so the
    /// panel stays where you put it.
    private func fit(_ size: CGSize) {
        guard size.width > 1, size.height > 1 else { return }
        let old = panel.frame
        guard abs(old.width - size.width) > 0.5 || abs(old.height - size.height) > 0.5 else { return }
        var frame = NSRect(origin: old.origin, size: size)
        if panel.isVisible, let area = (panel.screen ?? NSScreen.main)?.visibleFrame {
            if old.midX > area.midX {
                frame.origin.x = old.maxX - size.width
            }
            if old.midY > area.midY {
                frame.origin.y = old.maxY - size.height
            }
        }
        panel.setFrame(frame, display: true)
        panel.invalidateShadow()
    }

    /// Where it was last left, or the bottom right of the main screen.
    private func place() {
        let size = panel.frame.size
        if let saved = UserDefaults.standard.array(forKey: Self.frameKey) as? [Double], saved.count == 4 {
            let old = NSRect(x: saved[0], y: saved[1], width: saved[2], height: saved[3])
            if let area = NSScreen.screens.first(where: { $0.visibleFrame.intersects(old) })?.visibleFrame {
                var origin = old.origin
                if old.midX > area.midX {
                    origin.x = old.maxX - size.width
                }
                if old.midY > area.midY {
                    origin.y = old.maxY - size.height
                }
                panel.setFrameOrigin(origin)
                keepOnScreen(animate: false)
                return
            }
        }
        guard let area = NSScreen.screens.first?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(x: area.maxX - size.width - 16, y: area.minY + 16))
    }

    private func finishMove() {
        keepOnScreen(animate: true)
        let frame = panel.frame
        UserDefaults.standard.set([frame.minX, frame.minY, frame.width, frame.height], forKey: Self.frameKey)
    }

    /// Keeps the panel inside the screen it's on, snapped to an edge it was dropped near.
    private func keepOnScreen(animate: Bool) {
        var frame = panel.frame
        let center = NSPoint(x: frame.midX, y: frame.midY)
        let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) ?? panel.screen ?? NSScreen.main
        guard let area = screen?.visibleFrame else { return }
        let snap: CGFloat = 20
        let margin: CGFloat = 8
        frame.origin.x = min(max(frame.minX, area.minX), area.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, area.minY), area.maxY - frame.height)
        if frame.minX - area.minX < snap {
            frame.origin.x = area.minX + margin
        } else if area.maxX - frame.maxX < snap {
            frame.origin.x = area.maxX - frame.width - margin
        }
        if frame.minY - area.minY < snap {
            frame.origin.y = area.minY + margin
        } else if area.maxY - frame.maxY < snap {
            frame.origin.y = area.maxY - frame.height - margin
        }
        if frame.origin != panel.frame.origin {
            panel.setFrame(frame, display: true, animate: animate)
        }
    }

    private func showMenu(_ event: NSEvent) {
        let menu = NSMenu()
        for (title, action) in [
            ("Show Details", #selector(menuShowDetails)),
            ("Hide Floating Panel", #selector(menuHide)),
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Agent Buddy", action: #selector(menuQuit), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
        NSMenu.popUpContextMenu(menu, with: event, for: dragView)
    }

    @objc private func menuShowDetails() {
        showDetails()
    }

    @objc private func menuHide() {
        onHide?()
    }

    @objc private func menuQuit() {
        NSApp.terminate(nil)
    }
}
