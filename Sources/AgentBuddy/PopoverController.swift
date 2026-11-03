import AppKit
import Combine
import SwiftUI

/// The details popover, opened from the menu bar item or from the floating panel.
@MainActor
final class PopoverController {
    private let popover = NSPopover()
    private let model: AppModel
    /// The view the popover points at: the menu bar item or the floating panel.
    private weak var anchor: NSView?
    /// Light or dark as chosen, changed while it's open too.
    private var appearanceWatch: AnyCancellable?

    init(model: AppModel) {
        self.model = model
        let host = NSHostingController(rootView: PopoverView().environmentObject(model).environmentObject(model.settings).displayStyled())
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.behavior = .transient
        popover.animates = true
        appearanceWatch = model.settings.$appearance.sink { [weak self] mode in
            Task { @MainActor in self?.popover.appearance = mode.appearance }
        }
    }

    var isShown: Bool { popover.isShown }

    func toggle(from view: NSView) {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            show(from: view)
        }
    }

    func show(from view: NSView) {
        guard !popover.isShown, view.window != nil else { return }
        anchor = view
        model.popoverOpened()
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
        popover.contentViewController?.view.window?.makeKey()
    }

    func close() {
        if popover.isShown {
            popover.performClose(nil)
        }
    }

    func isAnchored(to view: NSView?) -> Bool {
        guard let view, let anchor else { return false }
        return anchor === view
    }

    /// Closes the popover when the view it points at is going away.
    func close(ifAnchoredTo view: NSView?) {
        // performClose, not close(): close() leaves a transient popover open here.
        if popover.isShown, let view, anchor === view {
            popover.performClose(nil)
        }
    }
}
