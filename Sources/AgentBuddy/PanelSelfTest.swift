import AppKit
import AgentBuddyCore

/// `AgentBuddy --selftest-panel`: puts up a real floating panel, then drags it,
/// drops it off screen and clicks it through its own event handlers, checking
/// where it ends up. Run it from .build (it keeps its own settings).
@MainActor
enum PanelSelfTest {
    static func run() -> Int32 {
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            print(ok ? "  ok    \(what)" : "  FAIL  \(what)")
            if !ok {
                failures += 1
            }
        }
        UserDefaults.standard.removeObject(forKey: "floatingPanel.frame")
        let settings = AppSettings()
        let model = AppModel(settings: settings, notifier: Notifier())
        let popover = PopoverController(model: model)
        let floating = FloatingHUDController(model: model, popover: popover)
        floating.setVisible(true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))

        let panel = floating.panel
        let view = floating.dragView
        check(panel.isVisible, "the panel shows")
        check(panel.level == .floating, "it floats above other windows")
        check(panel.collectionBehavior.contains(.canJoinAllSpaces), "it's on every Space")
        guard let area = panel.screen?.visibleFrame else {
            print("  FAIL  no screen")
            return 1
        }
        check(area.contains(panel.frame), "it starts on screen, at \(panel.frame.origin)")

        // The numbers arrive after it shows: it grows to fit them.
        let before = panel.frame
        model.refreshAll(force: true)
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline, model.readings.count + model.errors.count < settings.trackedAgents.count || !model.refreshing.isEmpty {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let needed = floating.contentSize
        print("  (width before the numbers \(before.width), needed now \(needed.width), panel now \(panel.frame.width))")
        check(abs(panel.frame.width - needed.width) < 1 && abs(panel.frame.height - needed.height) < 1,
              "it resizes to fit the numbers")
        check(abs(panel.frame.maxX - before.maxX) < 1, "growing, it keeps its right edge where it was")

        var pointer = NSPoint.zero
        view.pointer = { pointer }
        func send(_ type: NSEvent.EventType) {
            guard let event = NSEvent.mouseEvent(
                with: type, location: NSPoint(x: 10, y: 10), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
            else { return }
            switch type {
            case .leftMouseDown: view.mouseDown(with: event)
            case .leftMouseDragged: view.mouseDragged(with: event)
            default: view.mouseUp(with: event)
            }
        }
        func drag(by delta: NSPoint) {
            pointer = NSPoint(x: panel.frame.minX + 10, y: panel.frame.minY + 10)
            send(.leftMouseDown)
            pointer = NSPoint(x: pointer.x + delta.x, y: pointer.y + delta.y)
            send(.leftMouseDragged)
            send(.leftMouseUp)
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        }

        // To the middle of the screen.
        let target = NSPoint(x: area.midX.rounded(), y: area.midY.rounded())
        drag(by: NSPoint(x: target.x - panel.frame.minX, y: target.y - panel.frame.minY))
        check(abs(panel.frame.minX - target.x) < 1 && abs(panel.frame.minY - target.y) < 1,
              "dragging moves it, to \(panel.frame.origin)")
        let saved = UserDefaults.standard.array(forKey: "floatingPanel.frame") as? [Double]
        check(saved.map { abs($0[0] - panel.frame.minX) < 1 && abs($0[1] - panel.frame.minY) < 1 } ?? false,
              "its new place is remembered")
        check(!popover.isShown, "a drag doesn't open the details")

        // Far off screen to the bottom right: pulled back, snapped into the corner.
        drag(by: NSPoint(x: 5000, y: -5000))
        if let final = panel.screen?.visibleFrame {
            check(final.contains(panel.frame), "dropped off screen, it's pulled back inside")
            check(abs(panel.frame.maxX - (final.maxX - 8)) < 1 && abs(panel.frame.minY - (final.minY + 8)) < 1,
                  "and snapped into the bottom-right corner")
        } else {
            check(false, "dropped off screen, it's pulled back onto a screen")
        }

        // Dropped near the left edge: snapped to it.
        drag(by: NSPoint(x: area.minX + 12 - panel.frame.minX, y: area.midY - panel.frame.minY))
        check(abs(panel.frame.minX - ((panel.screen?.visibleFrame.minX ?? 0) + 8)) < 1, "dropped near an edge, it snaps to it")

        // A click without moving opens the details.
        pointer = NSPoint(x: panel.frame.minX + 10, y: panel.frame.minY + 10)
        send(.leftMouseDown)
        send(.leftMouseUp)
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        check(popover.isShown, "a click opens the details")

        // Hiding closes the details pointing at it.
        check(popover.isAnchored(to: view), "the details point at the panel")
        floating.setVisible(false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        check(!panel.isVisible, "it hides")
        check(!popover.isShown, "hiding it closes the details that pointed at it")

        print(failures == 0 ? "Panel self-test passed." : "\(failures) panel checks failed.")
        return failures == 0 ? 0 : 1
    }
}
