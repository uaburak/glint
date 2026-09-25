import AppKit
import Observation
import SwiftUI

/// A small glass bubble just above and to the right of the pointer with the app's icon and who
/// wrote, for a few seconds: the notification comes to where the user is looking, on whichever screen
/// that is. The icon grows out of the pointer in a circle, which then widens for the sender's name;
/// it follows the pointer, and goes back into it the same way. It never takes a click.
///
/// It moves right to the pointer with each mouse event, so nothing runs while the pointer is still.
/// macOS draws the pointer itself and a moved window shows a frame later, so it can't be closer.
@MainActor
final class PointerBubble {
    private static let duration: TimeInterval = 3
    /// The circle is out before it widens, and narrow again before it goes back in.
    private static let stepDelay: TimeInterval = 0.22
    /// Long enough for the circle to finish going back into the pointer.
    private static let exitDuration: TimeInterval = 0.3
    /// From the pointer's tip to the bubble's nearest corner: above and to the right, clear of the
    /// arrow. The panel's own margin (`BubbleContent.margin`) adds to it.
    private static let offset = CGSize(width: 6, height: 2)
    /// Below the tip, when there's no room above: clear of the arrow, which points down.
    private static let offsetBelow: CGFloat = 20
    private static let movingEvents: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]

    private let state = BubbleState()
    private var panel: NSPanel?
    private var hosting: NSHostingView<PointerBubbleView>?
    private var monitors: [Any] = []
    /// Bumped on every show and hide, so a step scheduled for an earlier one does nothing.
    private var generation = 0

    func show(app: WatchedApp, text: String) {
        let panel = self.panel ?? Self.makePanel()
        self.panel = panel
        if hosting == nil {
            let hosting = NSHostingView(rootView: PointerBubbleView(state: state))
            // The size is set here, from the widened bubble; SwiftUI's would resize it as it animates.
            hosting.sizingOptions = []
            panel.contentView = hosting
            self.hosting = hosting
        }
        generation += 1
        let current = generation

        let wasUp = panel.isVisible && state.phase != .hidden
        state.app = app
        state.text = text
        // The window has the widened bubble's size from the start; the bubble grows inside it.
        let size = NSHostingView(rootView: BubbleContent(app: app, text: text, expanded: true, growsLeft: false)).fittingSize
        place(at: NSEvent.mouseLocation, size: size)

        if wasUp {
            state.phase = .expanded
        } else {
            // It starts inside the pointer and comes out on the next pass, so SwiftUI animates it.
            state.phase = .hidden
            panel.orderFrontRegardless()
            after(0) { $0.state.phase = .circle }
            after(Self.stepDelay) { $0.state.phase = .expanded }
        }
        startFollowing()
        after(Self.duration) { $0.hide() }

        func after(_ delay: TimeInterval, _ step: @escaping (PointerBubble) -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.generation == current else { return }
                    step(self)
                }
            }
        }
    }

    /// Narrows back to the circle, which goes back into the pointer; the window goes once it's in.
    private func hide() {
        generation += 1
        let current = generation
        state.phase = .circle
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.stepDelay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == current else { return }
                self.state.phase = .hidden
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.exitDuration) { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.generation == current else { return }
                        self.panel?.orderOut(nil)
                        self.stopFollowing()
                    }
                }
            }
        }
    }

    // MARK: - Following the pointer

    /// Listens to the mouse while the bubble is up: other apps' events, and Glint's own for when its
    /// settings window is in front.
    private func startFollowing() {
        guard monitors.isEmpty else { return }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: Self.movingEvents, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerMoved() }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: Self.movingEvents, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.pointerMoved() }
            return event
        }) {
            monitors.append(local)
        }
    }

    private func stopFollowing() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }

    /// Moves the bubble to the pointer. Only the window's place changes, so nothing in it is drawn again.
    private func pointerMoved() {
        guard let panel, panel.isVisible else { return }
        place(at: NSEvent.mouseLocation, size: panel.frame.size)
    }

    /// Puts the bubble beside the pointer, with the point it grows from on the pointer and the side it
    /// widens to away from it.
    private func place(at pointer: NSPoint, size: CGSize) {
        guard let panel else { return }
        let origin = Self.origin(beside: pointer, size: size)
        if panel.frame.size != size {
            panel.setFrame(NSRect(origin: origin, size: size), display: false)
        } else if panel.frame.origin != origin {
            panel.setFrameOrigin(origin)
        }
        // In the view's coordinates, whose y runs down.
        let anchor = UnitPoint(
            x: (pointer.x - origin.x) / max(size.width, 1),
            y: 1 - (pointer.y - origin.y) / max(size.height, 1)
        )
        if anchor != state.anchor { state.anchor = anchor }
        let growsLeft = pointer.x > origin.x + size.width / 2
        if growsLeft != state.growsLeft { state.growsLeft = growsLeft }
    }

    /// Up and to the right of the pointer, but always whole on its screen: below it near the top, to
    /// the left of it near the right edge.
    private static func origin(beside pointer: NSPoint, size: CGSize) -> NSPoint {
        let screen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main
        var origin = NSPoint(x: pointer.x + offset.width, y: pointer.y + offset.height)
        guard let visible = screen?.visibleFrame else { return origin }
        if origin.y + size.height > visible.maxY { origin.y = pointer.y - offsetBelow - size.height }
        if origin.x + size.width > visible.maxX { origin.x = pointer.x - offset.width - size.width }
        origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        return origin
    }

    private static func makePanel() -> NSPanel {
        let panel = BannerPanelWindow(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        return panel
    }
}

/// What the bubble shows, how far out of the pointer it is, and where the pointer is on it.
@MainActor
@Observable
final class BubbleState {
    enum Phase { case hidden, circle, expanded }

    var app: WatchedApp?
    var text = ""
    var phase = Phase.hidden
    /// The pointer, relative to the bubble: where the circle grows from and shrinks back into.
    var anchor = UnitPoint.bottomLeading
    /// The pointer is to the bubble's right (near the screen's right edge): it widens to the left.
    var growsLeft = false
}

struct PointerBubbleView: View {
    let state: BubbleState

    var body: some View {
        let phase = state.phase
        BubbleContent(app: state.app, text: state.text, expanded: phase == .expanded, growsLeft: state.growsLeft)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: state.growsLeft ? .trailing : .leading)
            // Scaled as the whole window, whose coordinates the pointer's anchor is in.
            .scaleEffect(phase == .hidden ? 0.1 : 1, anchor: state.anchor)
            .opacity(phase == .hidden ? 0 : 1)
            .animation(.spring(response: 0.32, dampingFraction: 0.68), value: phase == .hidden)
            // The panel is never key, and glass in a window macOS thinks is inactive comes out flat.
            .environment(\.controlActiveState, .key)
    }
}

/// The bubble itself: a circle around the app's icon, or widened to the sender's name beside it.
struct BubbleContent: View {
    let app: WatchedApp?
    let text: String
    let expanded: Bool
    /// The name goes on the icon's left, the bubble widening away from the pointer.
    let growsLeft: Bool

    /// Room for the glass's edge, which draws just outside the capsule.
    static let margin: CGFloat = 4
    private static let iconSize: CGFloat = 18
    private static let iconInset: CGFloat = 6
    private static let diameter = iconSize + 2 * iconInset

    var body: some View {
        HStack(spacing: 7) {
            if growsLeft { title }
            icon
            if !growsLeft { title }
        }
        .padding(.horizontal, Self.iconInset)
        .padding(growsLeft ? .leading : .trailing, 5)
        // Narrowed to the circle, the name is cut off beside the icon, which stays in its middle.
        .frame(width: expanded ? nil : Self.diameter, height: Self.diameter, alignment: growsLeft ? .trailing : .leading)
        .clipShape(Capsule())
        .glassEffect(.regular, in: Capsule())
        .animation(.spring(response: 0.4, dampingFraction: 0.86), value: expanded)
        .padding(Self.margin)
    }

    @ViewBuilder
    private var icon: some View {
        if let app {
            AppIcon(app: app, size: Self.iconSize)
        }
    }

    private var title: some View {
        Text(text)
            .font(.system(size: 12.5, weight: .semibold))
            .lineLimit(1)
            .frame(maxWidth: 220, alignment: .leading)
            .fixedSize()
            // In once the bubble has widened for it, out before it narrows.
            .opacity(expanded ? 1 : 0)
            .animation(expanded ? .easeOut(duration: 0.2).delay(0.12) : .easeIn(duration: 0.08), value: expanded)
    }
}
