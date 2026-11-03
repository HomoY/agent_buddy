import AppKit
import AgentBuddyCore
import SwiftUI

/// Draws the menu bar item: a small caption per agent above its percentages,
/// e.g. CLAUDE over "5h 25%  wk 13%" (current session first, then the week),
/// coloured by how much is used.
enum MenuBarRenderer {
    typealias Value = MenuValue

    struct Segment {
        var agent: Agent
        var label: String
        var values: [Value]
    }

    /// Black or white at `alpha`, chosen when drawn, so the item follows the
    /// menu bar's light or dark look without being redrawn.
    static func ink(_ alpha: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua, .vibrantLight, .vibrantDark]).map {
                $0 == .darkAqua || $0 == .vibrantDark
            } ?? false
            return (dark ? NSColor.white : NSColor.black).withAlphaComponent(alpha)
        }
    }

    static func color(_ severity: Severity?) -> NSColor {
        guard let severity else { return ink(0.45) }
        switch severity {
        case .normal: return .labelColor
        case .warning: return .systemOrange
        case .critical: return .systemRed
        }
    }

    /// "3", or "99+"; nil for none.
    static func badgeText(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        return count > 99 ? "99+" : "\(count)"
    }

    /// `badge` is the number of finished jobs not yet cleared; 0 draws none.
    /// Colours resolve when the menu bar draws the image, in its own appearance.
    static func image(_ segments: [Segment], badge: Int = 0) -> NSImage {
        let labelFont = NSFont.systemFont(ofSize: 7.5, weight: .semibold)
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        let tagFont = NSFont.systemFont(ofSize: 8, weight: .semibold)
        let height = max(NSStatusBar.system.thickness, 22)
        let columns: [(label: NSAttributedString, value: NSAttributedString, width: CGFloat)] = segments.map { segment in
            let label = NSAttributedString(string: segment.label, attributes: [
                .font: labelFont, .foregroundColor: ink(0.65), .kern: 0.4,
            ])
            let value = NSMutableAttributedString()
            for (index, item) in segment.values.enumerated() {
                if index > 0 {
                    // A wider gap between tagged pairs, e.g. "5h 25%  wk 13%".
                    value.append(NSAttributedString(string: " ", attributes: [.font: valueFont, .kern: 3]))
                }
                if let tag = item.tag {
                    value.append(NSAttributedString(string: tag + "\u{2009}", attributes: [
                        .font: tagFont, .foregroundColor: ink(0.55),
                    ]))
                }
                value.append(NSAttributedString(string: item.text, attributes: [.font: valueFont, .foregroundColor: color(item.severity)]))
            }
            return (label, value, ceil(max(label.size().width, value.size().width)))
        }
        let gap: CGFloat = 9
        let columnsWidth = columns.reduce(0) { $0 + $1.width } + gap * CGFloat(max(columns.count - 1, 0))

        // The finished-jobs badge: a round number at the right end.
        let badgeFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .bold)
        let badgeLabel = badgeText(badge).map {
            NSAttributedString(string: $0, attributes: [.font: badgeFont, .foregroundColor: NSColor.white])
        }
        let badgeHeight: CGFloat = 16
        let badgeWidth = badgeLabel.map { max(badgeHeight, ceil($0.size().width) + 9) } ?? 0
        let badgeGap: CGFloat = columns.isEmpty ? 0 : 8
        let width = columnsWidth + (badgeLabel == nil ? 0 : badgeGap + badgeWidth) + 4

        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            var x: CGFloat = 2
            for column in columns {
                let labelSize = column.label.size()
                let valueSize = column.value.size()
                column.label.draw(at: NSPoint(x: x + (column.width - labelSize.width) / 2, y: height / 2 + 2))
                column.value.draw(at: NSPoint(x: x + (column.width - valueSize.width) / 2, y: height / 2 - valueSize.height + 3))
                x += column.width + gap
            }
            if let badgeLabel {
                let rect = NSRect(
                    x: 2 + columnsWidth + badgeGap, y: ((height - badgeHeight) / 2).rounded(),
                    width: badgeWidth, height: badgeHeight)
                NSColor.systemBlue.setFill()
                NSBezierPath(roundedRect: rect, xRadius: badgeHeight / 2, yRadius: badgeHeight / 2).fill()
                let size = badgeLabel.size()
                badgeLabel.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2 + 0.5))
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}

/// Agent Buddy's own symbol, as on its app icon (three gauges), drawn as a
/// template so the menu bar tints it for light and dark.
enum AppSymbol {
    static func image(size: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let unit = rect.width / 18
            let center = NSPoint(x: rect.midX, y: rect.midY - 1.2 * unit)
            let start: CGFloat = 205
            let sweep: CGFloat = 230
            for (radius, fraction) in [(7.5, 0.78), (5.2, 0.55), (2.9, 0.33)] as [(CGFloat, CGFloat)] {
                for (alpha, share) in [(0.35, 1.0), (1.0, fraction)] as [(CGFloat, CGFloat)] {
                    let arc = NSBezierPath()
                    arc.appendArc(
                        withCenter: center, radius: radius * unit, startAngle: start,
                        endAngle: start - sweep * share, clockwise: true)
                    arc.lineWidth = 1.4 * unit
                    arc.lineCapStyle = .round
                    NSColor.black.withAlphaComponent(alpha).setStroke()
                    arc.stroke()
                }
            }
            // The dial's hub, as on the app icon.
            let hub = 1.0 * unit
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: center.x - hub, y: center.y - hub, width: hub * 2, height: hub * 2)).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Agent Buddy"
        return image
    }
}

@MainActor
final class StatusItemController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover: PopoverController
    private let model: AppModel
    /// What the item shows now; an unchanged item isn't redrawn.
    private var shown: String?
    /// Whether the floating panel is showing, and how to show or hide it, for the right-click menu.
    var floatingPanelShown: () -> Bool = { false }
    var setFloatingPanel: (Bool) -> Void = { _ in }

    /// The app icon, the usage numbers, or nothing.
    var style: MenuBarStyle = .icon {
        didSet {
            guard style != oldValue else { return }
            if style == .hidden {
                popover.close(ifAnchoredTo: item.button)
            }
            item.isVisible = style != .hidden
            shown = nil
            redraw()
        }
    }

    init(model: AppModel, popover: PopoverController) {
        self.model = model
        self.popover = popover
        super.init()
        item.autosaveName = "Agent Buddy"
        if let button = item.button {
            button.target = self
            button.action = #selector(clicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageOnly
        }
        redraw()
    }

    var isVisible: Bool { item.isVisible }

    func redraw() {
        guard let button = item.button, style != .hidden else { return }
        let segments = model.menuSegments()
        let badge = model.jobWindows.count
        let content: String
        if style == .icon {
            content = "icon"
        } else {
            content = segments.map { segment in
                segment.label + ":" + segment.values.map { "\($0.tag ?? "")\($0.text)\(String(describing: $0.severity))" }.joined(separator: ",")
            }.joined(separator: "|") + "|\(badge)"
        }
        if content != shown {
            shown = content
            if style == .icon || (segments.isEmpty && badge == 0) {
                button.image = AppSymbol.image()
            } else {
                button.image = MenuBarRenderer.image(segments, badge: badge)
            }
        }
        let tooltip = model.tooltip()
        if button.toolTip != tooltip {
            button.toolTip = tooltip
            button.setAccessibilityLabel(tooltip)
        }
    }

    /// Left click: the details. Right click: a short menu.
    @objc private func clicked(_ sender: Any?) {
        guard let button = item.button else { return }
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
        } else {
            popover.toggle(from: button)
        }
    }

    func show() {
        if let button = item.button, style != .hidden {
            popover.show(from: button)
        }
    }

    private func showMenu() {
        guard let button = item.button else { return }
        popover.close()
        let menu = NSMenu()
        let shown = floatingPanelShown()
        let panel = NSMenuItem(
            title: shown ? "Hide Floating Panel" : "Show Floating Panel",
            action: #selector(togglePanel), keyEquivalent: "")
        let details = NSMenuItem(title: "Show Details", action: #selector(showDetails), keyEquivalent: "")
        let quit = NSMenuItem(title: "Quit Agent Buddy", action: #selector(quit), keyEquivalent: "")
        for entry in [panel, details, quit] {
            entry.target = self
        }
        menu.items = [panel, details, .separator(), quit]
        // Attached for this one click, so the menu opens under the item like any menu bar menu.
        item.menu = menu
        button.performClick(nil)
        item.menu = nil
    }

    @objc private func togglePanel() {
        setFloatingPanel(!floatingPanelShown())
    }

    @objc private func showDetails() {
        show()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
