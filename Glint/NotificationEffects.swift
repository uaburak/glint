import AppKit
import SwiftUI

/// The frame effect: a sharp line tracing the screen's own outline — around the rounded corners and
/// around the notch — in the app's colour. It arrives from beyond the screen's edge, settles onto the
/// outline, and leaves the same way.
///
/// It draws in a click-through window on each screen, so nothing gets in the user's way. The glow has
/// its own overlay (`GlowOverlay`).
@MainActor
final class EffectOverlay {
    /// How long the frame stays when it isn't set to wait for the notifications to be read.
    private static let defaultDuration: TimeInterval = 2.5
    /// Long enough for it to leave before its window goes.
    private static let exitTime: TimeInterval = 0.45

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
                notch: Self.notchRect(on: screen),
                onScreenTime: onScreenTime
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

    /// The notch's place in the window's own coordinates (top-left origin), on the screen that has one.
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
    /// Where the notch sits along the top edge, when this screen has one.
    let notch: CGRect?
    let onScreenTime: TimeInterval

    /// The line's width, and how far outside the screen it starts and ends.
    private static let lineWidth: CGFloat = 5
    private static let travel: CGFloat = 26
    private static let arrival: TimeInterval = 0.32
    private static let departure: TimeInterval = 0.4

    /// 0 while it is still outside the screen, 1 once it sits on the outline.
    @State private var arrived = false

    var body: some View {
        GeometryReader { geometry in
            ScreenOutline(notch: notch, cornerRadius: Self.cornerRadius)
                .stroke(color.opacity(0.95 * intensity), lineWidth: Self.lineWidth)
                .shadow(color: color.opacity(0.55 * intensity), radius: 10)
                // Out beyond the screen's edge to begin with, so it comes in from the outside and,
                // when its time is up, leaves the same way rather than shrinking inwards.
                .padding(arrived ? Self.lineWidth / 2 : -Self.travel)
                .opacity(arrived ? 1 : 0)
                .frame(width: geometry.size.width, height: geometry.size.height)
                .onAppear {
                    withAnimation(.easeOut(duration: Self.arrival)) { arrived = true }
                    guard onScreenTime.isFinite else { return }
                    withAnimation(.easeIn(duration: Self.departure).delay(onScreenTime)) { arrived = false }
                }
        }
        .ignoresSafeArea()
    }

    /// The rounded corners of a modern Mac display. Apple doesn't hand the radius out, and being a
    /// point or two off is invisible against the bezel.
    private static var cornerRadius: CGFloat {
        Notch.current != nil ? 12 : 0
    }
}

/// The outline of the screen itself: rounded corners, and a bite taken out around the notch.
private struct ScreenOutline: Shape {
    let notch: CGRect?
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let radius = min(cornerRadius, min(rect.width, rect.height) / 2)

        guard let notch, notch.width > 0, notch.height > 0 else {
            path.addRoundedRect(in: rect, cornerSize: CGSize(width: radius, height: radius))
            return path
        }

        // The notch's own corners, rounded the way the hardware is.
        let notchRadius = min(6, notch.height / 2)
        let left = max(rect.minX + radius, notch.minX)
        let right = min(rect.maxX - radius, notch.maxX)
        let bottom = notch.maxY

        path.move(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        path.addQuadCurve(to: CGPoint(x: rect.minX + radius, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
        // Along the top to the notch, around it, and on to the far corner.
        path.addLine(to: CGPoint(x: left - notchRadius, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: left, y: rect.minY + notchRadius), control: CGPoint(x: left, y: rect.minY))
        path.addLine(to: CGPoint(x: left, y: bottom - notchRadius))
        path.addQuadCurve(to: CGPoint(x: left + notchRadius, y: bottom), control: CGPoint(x: left, y: bottom))
        path.addLine(to: CGPoint(x: right - notchRadius, y: bottom))
        path.addQuadCurve(to: CGPoint(x: right, y: bottom - notchRadius), control: CGPoint(x: right, y: bottom))
        path.addLine(to: CGPoint(x: right, y: rect.minY + notchRadius))
        path.addQuadCurve(to: CGPoint(x: right + notchRadius, y: rect.minY), control: CGPoint(x: right, y: rect.minY))
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
