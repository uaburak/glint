import AppKit
import QuartzCore
import SwiftUI

/// A Teams-colored glow that hugs every screen's edges and fades inward, shown with each
/// new-message notification. The windows are click-through, so it never gets in the way.
@MainActor
final class GlowOverlay {
    /// One smooth pulse: a quick ease in, a slower ease out.
    private static let fadeIn: TimeInterval = 0.3
    private static let fadeOut: TimeInterval = 0.7

    private var windows: [NSWindow] = []
    private var hideWork: DispatchWorkItem?
    private var persistent = false
    private var visible = false
    /// Bumped on every show/dismiss so a finishing fade-out can't hide a newer glow.
    private var generation = 0

    init() {
        // Build the windows up front so the first glow appears without a delay.
        windows = NSScreen.screens.map(makeWindow)
    }

    /// Glows for `duration` in total — fade in, hold, fade out. nil keeps it on until
    /// `dismissIfPersistent()`, i.e. until the messages are read.
    func show(colorHex: String, intensity: Double, duration: TimeInterval?) {
        generation += 1
        hideWork?.cancel()
        hideWork = nil

        let screens = NSScreen.screens
        if windows.count != screens.count {
            windows.forEach { $0.orderOut(nil) }
            windows = screens.map(makeWindow)
        }
        let view = EdgeGlowView(color: Color(hex: colorHex), intensity: intensity)
        for (window, screen) in zip(windows, screens) {
            window.setFrame(screen.frame, display: false)
            window.contentView = NSHostingView(rootView: view)
            window.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeIn
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            windows.forEach { $0.animator().alphaValue = 1 }
        }
        visible = true

        persistent = duration == nil
        if let duration {
            let work = DispatchWorkItem { [weak self] in self?.dismiss() }
            hideWork = work
            let fadeOutStart = max(duration - Self.fadeOut, Self.fadeIn)
            DispatchQueue.main.asyncAfter(deadline: .now() + fadeOutStart, execute: work)
        }
    }

    func dismissIfPersistent() {
        if persistent { dismiss() }
    }

    func dismiss() {
        hideWork?.cancel()
        hideWork = nil
        persistent = false
        guard visible else { return }
        visible = false
        generation += 1
        let current = generation
        let fading = windows
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeOut
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            fading.forEach { $0.animator().alphaValue = 0 }
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == current else { return }
                // Drop the view too, so its animation stops while nothing is showing.
                fading.forEach {
                    $0.orderOut(nil)
                    $0.contentView = nil
                }
            }
        }
    }

    private func makeWindow(for screen: NSScreen) -> NSWindow {
        let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.setFrame(screen.frame, display: false)
        return window
    }
}

/// Layered, blurred strokes along the screen border. Only the inner half of each blur is
/// on screen, which is what makes it read as light glowing inward from the edges.
struct EdgeGlowView: View {
    let color: Color
    let intensity: Double
    @State private var start = Date()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
            let t = timeline.date.timeIntervalSince(start)
            let light = color.mix(with: .white, by: 0.4)
            let gradient = AngularGradient(
                colors: [color, light, color, light, color],
                center: .center,
                angle: .degrees(t * 15) // a slow shimmer along the edges
            )
            // Bright thin line at the very edge, then a tighter falloff inward.
            ZStack {
                edge(gradient, width: 70, blur: 45).opacity(0.55)
                edge(gradient, width: 26, blur: 14).opacity(0.85)
                edge(gradient, width: 6, blur: 2.5)
            }
            .opacity(intensity)
            .drawingGroup()
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private func edge(_ gradient: AngularGradient, width: CGFloat, blur: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(gradient, lineWidth: width)
            .blur(radius: blur)
    }
}

extension Color {
    /// "#RRGGBB" → Color (falls back to Teams purple).
    init(hex: String) {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        let value = UInt64(digits, radix: 16) ?? 0x5B5FC7
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    var hexString: String {
        NSColor(self).hexString ?? Pref.teamsPurpleHex
    }
}

extension NSColor {
    /// "#RRGGBB" in sRGB, or nil for colors without an RGB form (reading the components of
    /// one, like a catalog color, would crash).
    var hexString: String? {
        guard let rgb = usingColorSpace(.sRGB) else { return nil }
        return String(
            format: "#%02X%02X%02X",
            Int((rgb.redComponent * 255).rounded()),
            Int((rgb.greenComponent * 255).rounded()),
            Int((rgb.blueComponent * 255).rounded())
        )
    }
}
