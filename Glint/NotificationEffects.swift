import AppKit
import ApplicationServices
import SwiftUI

/// What the screen does when a notification comes, in the app's own colour: the flash, the sweeping
/// band, the ripple, the frame and the corner dot. The glow has its own overlay (`GlowOverlay`), and
/// the shake moves the window in front rather than drawing anything (`WindowShake`).
///
/// Every effect draws in a click-through window on each screen, so nothing gets in the user's way.
@MainActor
final class EffectOverlay {
    /// How long each effect plays when it isn't set to stay until the notifications are read.
    private static let duration: [NotifyEffect: TimeInterval] = [
        .flash: 0.5, .sweep: 0.9, .ripple: 1.0, .frame: 2.5, .dot: 2.5,
    ]
    /// Long enough for the effect to finish before its window goes.
    private static let tailTime: TimeInterval = 0.4

    private var windows: [NSWindow] = []
    private var hideWork: DispatchWorkItem?
    private var persistent = false

    /// Plays the effect on every screen. `duration` is the effect's own setting: nil means an effect
    /// that can stay does stay, until `dismissIfPersistent()`.
    func show(_ effect: NotifyEffect, colorHex: String, intensity: Double, duration: TimeInterval?) {
        guard effect != .none, effect != .glow, effect != .shake else { return }
        dismiss()

        let stays = duration == nil && effect.canPersist
        persistent = stays
        let playTime = stays ? .infinity : (duration ?? 0 > 0 ? min(duration ?? 0, 20) : Self.duration[effect] ?? 1)
        let view = EffectView(effect: effect, color: Color(hex: colorHex), intensity: intensity, stays: stays)

        for screen in NSScreen.screens {
            let window = Self.makeWindow(on: screen)
            window.contentView = NSHostingView(rootView: view.frame(width: screen.frame.width, height: screen.frame.height))
            window.orderFrontRegardless()
            windows.append(window)
        }

        guard !stays else { return }
        let work = DispatchWorkItem { [weak self] in self?.dismiss() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + playTime + Self.tailTime, execute: work)
    }

    /// Takes down an effect that was staying until the notifications were read.
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

    private static func makeWindow(on screen: NSScreen) -> NSWindow {
        let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = .screenSaver
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

// MARK: - The effects themselves

private struct EffectView: View {
    let effect: NotifyEffect
    let color: Color
    let intensity: Double
    /// Whether it stays until the notifications are read, rather than playing once.
    let stays: Bool

    @State private var phase: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            content(in: geometry.size)
                .allowsHitTesting(false)
                .onAppear {
                    switch effect {
                    case .flash:
                        withAnimation(.easeOut(duration: 0.12)) { phase = 1 }
                        withAnimation(.easeIn(duration: 0.38).delay(0.12)) { phase = 0 }
                    case .sweep:
                        withAnimation(.easeInOut(duration: 0.9)) { phase = 1 }
                    case .ripple:
                        withAnimation(.easeOut(duration: 1.0)) { phase = 1 }
                    case .frame:
                        withAnimation(.easeOut(duration: 0.25)) { phase = 1 }
                        if !stays {
                            withAnimation(.easeIn(duration: 0.5).delay(2)) { phase = 0 }
                        }
                    case .dot:
                        withAnimation(.easeOut(duration: 0.2)) { phase = 1 }
                    default:
                        break
                    }
                }
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    private func content(in size: CGSize) -> some View {
        switch effect {
        case .flash:
            color.opacity(0.32 * intensity * phase)

        case .sweep:
            // A band of colour crossing the screen, softest at its edges.
            LinearGradient(
                colors: [.clear, color.opacity(0.55 * intensity), .clear],
                startPoint: .leading, endPoint: .trailing
            )
            .frame(width: size.width * 0.45)
            .blur(radius: 24)
            .offset(x: -size.width * 0.75 + phase * size.width * 1.5)
            .frame(width: size.width, height: size.height, alignment: .leading)

        case .ripple:
            // Out from the notch, or from the top middle on a Mac without one.
            let diameter = max(size.width, size.height) * 1.6
            Circle()
                .stroke(color.opacity(0.75 * intensity * (1 - phase)), lineWidth: 10 + 22 * (1 - phase))
                .frame(width: diameter, height: diameter)
                .scaleEffect(0.02 + phase)
                .position(x: size.width / 2, y: 0)
                .blur(radius: 6)

        case .frame:
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(color.opacity(0.95 * intensity * phase), lineWidth: 4)
                .shadow(color: color.opacity(0.7 * intensity * phase), radius: 12)
                .padding(2)

        case .dot:
            // Under the menu bar in the top-right corner, where the eye goes for a status.
            PulsingDot(color: color, intensity: intensity, stays: stays)
                .opacity(phase)
                .frame(width: 18, height: 18)
                .position(x: size.width - 26, y: 44)

        default:
            Color.clear
        }
    }
}

/// The corner dot, breathing while it waits.
private struct PulsingDot: View {
    let color: Color
    let intensity: Double
    let stays: Bool

    var body: some View {
        Circle()
            .fill(color.opacity(0.95 * intensity))
            .shadow(color: color.opacity(0.9), radius: 8)
            .phaseAnimator(stays ? [1.0, 1.35] : [1.0, 1.45, 1.0], trigger: stays) { dot, scale in
                dot.scaleEffect(scale)
            } animation: { _ in .easeInOut(duration: 0.55) }
    }
}

// MARK: - Shake

/// Jolts the window in front a few pixels and puts it back, the way a hand knocks a desk.
///
/// It moves the frontmost app's focused window through the Accessibility API — the same permission
/// Glint already uses for Dock badges. Anything it can't move (a full-screen app, a window that
/// refuses to be positioned, Glint's own) is left alone, and the caller falls back to another effect.
@MainActor
enum WindowShake {
    /// Sideways steps of the shake, as a share of its strength.
    private static let steps: [CGFloat] = [1, -0.85, 0.6, -0.4, 0.2, 0]
    private static let stepTime: TimeInterval = 0.045

    /// Shakes the window in front. Returns false when there was nothing to shake.
    @discardableResult
    static func shakeFrontWindow(intensity: Double) -> Bool {
        guard AXIsProcessTrusted(),
              let front = NSWorkspace.shared.frontmostApplication,
              front.bundleIdentifier != Bundle.main.bundleIdentifier
        else { return false }

        let application = AXUIElementCreateApplication(front.processIdentifier)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &focused) == .success,
              let windowValue = focused, CFGetTypeID(windowValue) == AXUIElementGetTypeID() else { return false }
        let window = windowValue as! AXUIElement

        var positionValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue) == .success,
              let positionValue else { return false }
        var origin = CGPoint.zero
        AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin)

        // A window that won't be moved (full screen, say) leaves everything as it was.
        let amplitude = 5 + 9 * intensity
        guard move(window, to: CGPoint(x: origin.x + amplitude, y: origin.y)) else { return false }

        for (index, step) in steps.enumerated().dropFirst() {
            DispatchQueue.main.asyncAfter(deadline: .now() + stepTime * Double(index)) {
                MainActor.assumeIsolated {
                    _ = move(window, to: CGPoint(x: origin.x + amplitude * step, y: origin.y))
                }
            }
        }
        // Whatever happened in between, it ends where it started.
        DispatchQueue.main.asyncAfter(deadline: .now() + stepTime * Double(steps.count)) {
            MainActor.assumeIsolated { _ = move(window, to: origin) }
        }
        return true
    }

    @discardableResult
    private static func move(_ window: AXUIElement, to point: CGPoint) -> Bool {
        var target = point
        guard let value = AXValueCreate(.cgPoint, &target) else { return false }
        return AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value) == .success
    }
}
