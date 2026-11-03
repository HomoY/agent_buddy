import AppKit
import AgentBuddyCore
import SwiftUI

/// A reminder drawn by Agent Buddy itself: used when macOS notifications are off,
/// or when chosen in Settings.
struct Toast: Identifiable {
    var id: String
    var agent: Agent?
    var title: String
    var subtitle: String?
    var body: String
}

struct ToastView: View {
    let toast: Toast
    let close: () -> Void
    let open: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if let agent = toast.agent {
                AgentMark(agent: agent)
            } else {
                Image(systemName: "gauge.with.dots.needle.67percent")
                    .uiFont(18, weight: .semibold)
                    .frame(width: 24, height: 24)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(toast.title)
                    .uiFont(13, weight: .semibold)
                    .lineLimit(1)
                if let subtitle = toast.subtitle {
                    Text(subtitle).uiFont(12).lineLimit(1)
                }
                if !toast.body.isEmpty {
                    Text(toast.body)
                        .uiFont(11)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            Button(action: close) {
                Image(systemName: "xmark")
                    .uiFont(9, weight: .bold)
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Color.primary.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(12)
        .frame(width: ToastController.width, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
    }
}

@MainActor
final class ToastController {
    static let width: CGFloat = 340
    private static let margin: CGFloat = 12
    private static let visibleSeconds: TimeInterval = 12
    private static let most = 4

    /// The clicked card's reminder id.
    var onClick: ((String) -> Void)?
    private var panels: [NSPanel] = []
    /// Which reminder each card shows, so a newer one for the same agent window replaces it.
    private var shownIDs: [ObjectIdentifier: String] = [:]
    private var timers: [ObjectIdentifier: Int] = [:]

    func show(_ toast: Toast) {
        // The same window's card is already up: show the newer reminder in it.
        if let panel = panels.first(where: { shownIDs[ObjectIdentifier($0)] == toast.id }) {
            panel.contentView = host(for: toast, in: panel)
            panel.setContentSize(panel.contentView?.fittingSize ?? panel.frame.size)
            layout(animated: true, newest: nil)
            dismissLater(panel)
            return
        }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 80),
            styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        let host = host(for: toast, in: panel)
        panel.setContentSize(host.fittingSize)
        panel.contentView = host
        shownIDs[ObjectIdentifier(panel)] = toast.id

        panels.insert(panel, at: 0)
        while panels.count > Self.most, let oldest = panels.last {
            dismiss(oldest)
        }
        layout(animated: false, newest: panel)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel.animator().alphaValue = 1
        }
        dismissLater(panel)
    }

    private func host(for toast: Toast, in panel: NSPanel) -> NSView {
        let view = ToastView(
            toast: toast,
            close: { [weak self, weak panel] in
                if let panel { self?.dismiss(panel) }
            },
            open: { [weak self, weak panel] in
                self?.onClick?(toast.id)
                if let panel { self?.dismiss(panel) }
            })
        let host = NSHostingView(rootView: view.displayStyled())
        host.frame.size = host.fittingSize
        return host
    }

    /// Dismisses the card a while after its latest reminder.
    private func dismissLater(_ panel: NSPanel) {
        let key = ObjectIdentifier(panel)
        let token = (timers[key] ?? 0) + 1
        timers[key] = token
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.visibleSeconds) { [weak self, weak panel] in
            guard let self, let panel, self.timers[ObjectIdentifier(panel)] == token else { return }
            self.dismiss(panel)
        }
    }

    private func dismiss(_ panel: NSPanel) {
        guard let index = panels.firstIndex(of: panel) else { return }
        panels.remove(at: index)
        shownIDs[ObjectIdentifier(panel)] = nil
        timers[ObjectIdentifier(panel)] = nil
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
        layout(animated: true, newest: nil)
    }

    /// Newest at the top right, older ones below it.
    private func layout(animated: Bool, newest: NSPanel?) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let area = screen.visibleFrame
        var top = area.maxY - Self.margin
        for panel in panels {
            let size = panel.frame.size
            let origin = NSPoint(x: area.maxX - size.width - Self.margin, y: top - size.height)
            if animated && panel !== newest {
                panel.animator().setFrameOrigin(origin)
            } else {
                panel.setFrameOrigin(origin)
            }
            top -= size.height + 8
        }
    }
}
