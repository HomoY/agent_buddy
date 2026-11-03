import AppKit
import SwiftUI

/// Frosted glass behind an agent window: what's behind the window shows
/// through, blurred, as in Finder's sidebar; frosted whether the window is in
/// front or not.
struct FrostedGlass: NSViewRepresentable {
    /// Settings › Appearance › Agent windows › Frosted glass.
    static let key = "display.windowGlass"

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// An agent window's glass: the real thing on screen; in the tour's pictures,
/// drawn off screen with nothing behind to blur, a light, see-through tint the
/// picture's desktop shows through.
struct GlassBackground: View {
    @SwiftUI.Environment(\.glassPicture) private var picture

    var body: some View {
        if picture {
            Color(nsColor: .windowBackgroundColor).opacity(0.8)
        } else {
            FrostedGlass()
        }
    }
}

private struct GlassPictureKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var glassPicture: Bool {
        get { self[GlassPictureKey.self] }
        set { self[GlassPictureKey.self] = newValue }
    }
}
