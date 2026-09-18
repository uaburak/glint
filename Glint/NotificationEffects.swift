import AppKit
import SwiftUI

/// The frame effect: a sharp line tracing the screen's own outline — around its rounded corners and
/// around Glint's island in the notch — in the app's colour. It appears and goes without animating.
///
/// It draws in a click-through window on each screen, so nothing gets in the user's way. The glow has
/// its own overlay (`GlowOverlay`).
@MainActor
final class EffectOverlay {
    /// How long the frame stays when it isn't set to wait for the notifications to be read.
    private static let defaultDuration: TimeInterval = 2.5
    /// It doesn't animate away, so its window goes with it.
    private static let exitTime: TimeInterval = 0

    private var windows: [NSWindow] = []
    private var hideWork: DispatchWorkItem?
    private var persistent = false

    /// Shows the effect on every screen. `duration` nil keeps it there until `dismissIfPersistent()`.
    func show(_ effect: NotifyEffect, colorHex: String, intensity: Double, duration: TimeInterval?) {
        guard effect == .frame else { return }
        dismiss()

        let stays = duration == nil
        persistent = stays
        let onScreenTime = stays ? .infinity : min(max(duration ?? Self.defaultDuration, 0.6), 20)

        for screen in NSScreen.screens {
            let window = Self.makeWindow(on: screen)
            let view = ScreenFrameView(
                color: Color(hex: colorHex),
                intensity: intensity,
                notch: Self.notchRect(on: screen)
            )
            window.contentView = NSHostingView(rootView: view)
            window.orderFrontRegardless()
            windows.append(window)
        }

        guard !stays else { return }
        let work = DispatchWorkItem { [weak self] in self?.dismiss() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + onScreenTime + Self.exitTime, execute: work)
    }

    /// Takes down a frame that was waiting for the notifications to be read.
    func dismissIfPersistent() {
        if persistent { dismiss() }
    }

    func dismiss() {
        hideWork?.cancel()
        hideWork = nil
        persistent = false
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
    }

    /// The notch in the window's own coordinates (top-left origin), on the screen that has one.
    private static func notchRect(on screen: NSScreen) -> CGRect? {
        guard let notch = Notch.current, notch.screen == screen else { return nil }
        return CGRect(
            x: notch.frame.minX - screen.frame.minX,
            y: 0,
            width: notch.frame.width,
            height: notch.frame.height
        )
    }

    private static func makeWindow(on screen: NSScreen) -> NSWindow {
        let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        // Above the menu bar and the notch, so the line can trace the screen's very edge.
        window.level = NotchOverlay.level
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.setFrame(screen.frame, display: false)
        return window
    }
}

// MARK: - The frame

private struct ScreenFrameView: View {
    let color: Color
    let intensity: Double
    /// The notch along the top edge, when this screen has one.
    let notch: CGRect?

    private static let lineWidth: CGFloat = 5
    /// The island's own growing animation, so the line stays on its edge while it moves.
    private static let follow = Animation.smooth(duration: 0.38)

    private var island = IslandState.shared

    var body: some View {
        // The screen's edges are inset by half the line, so none of it falls off; the island keeps
        // its own place, which is where the user sees it.
        ScreenOutline(island: islandRect, cornerRadius: Self.cornerRadius, inset: Self.lineWidth / 2)
            .stroke(color.opacity(0.95 * intensity), lineWidth: Self.lineWidth)
            .shadow(color: color.opacity(0.55 * intensity), radius: 10)
            .animation(Self.follow, value: island.expanded)
            .ignoresSafeArea()
    }

    /// Glint's island as it stands right now: the notch, its ears, and the room it takes when grown.
    private var islandRect: CGRect? {
        guard let notch else { return nil }
        let extra = NotchOverlay.earRadius + (island.expanded ? NotchOverlay.expansion : 0)
        return notch.insetBy(dx: -extra, dy: 0)
    }

    /// The rounded corners of a modern Mac display. Apple doesn't hand the radius out, and being a
    /// point or two off is invisible against the bezel.
    private static var cornerRadius: CGFloat {
        Notch.current != nil ? 12 : 0
    }
}

/// The outline of the screen itself: rounded corners, and Glint's island hanging into the top edge.
private struct ScreenOutline: Shape {
    let island: CGRect?
    let cornerRadius: CGFloat
    /// How far inside the screen's edge the line runs.
    let inset: CGFloat

    func path(in bounds: CGRect) -> Path {
        let rect = bounds.insetBy(dx: inset, dy: inset)
        var path = Path()
        let radius = min(cornerRadius, min(rect.width, rect.height) / 2)

        guard let island, island.width > 0, island.height > 0 else {
            path.addRoundedRect(in: rect, cornerSize: CGSize(width: radius, height: radius))
            return path
        }

        // The island's own shape: ears curving out of the top edge and a rounded bottom, as
        // `NotchShape` draws it.
        let ear = NotchOverlay.earRadius
        let bottom = NotchOverlay.bottomRadius
        let left = island.minX
        let right = island.maxX
        let base = island.maxY

        path.move(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        path.addQuadCurve(to: CGPoint(x: rect.minX + radius, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: left, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: left + ear, y: rect.minY + ear), control: CGPoint(x: left + ear, y: rect.minY))
        path.addLine(to: CGPoint(x: left + ear, y: base - bottom))
        path.addQuadCurve(to: CGPoint(x: left + ear + bottom, y: base), control: CGPoint(x: left + ear, y: base))
        path.addLine(to: CGPoint(x: right - ear - bottom, y: base))
        path.addQuadCurve(to: CGPoint(x: right - ear, y: base - bottom), control: CGPoint(x: right - ear, y: base))
        path.addLine(to: CGPoint(x: right - ear, y: rect.minY + ear))
        path.addQuadCurve(to: CGPoint(x: right, y: rect.minY), control: CGPoint(x: right - ear, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + radius), control: CGPoint(x: rect.maxX, y: rect.minY))
        // Down the right side, along the bottom, and back up the left.
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - radius, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - radius), control: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
