import AppKit
import Observation
import SwiftUI

/// The camera housing at the top of a built-in MacBook display.
struct Notch {
    let screen: NSScreen
    /// In screen coordinates: from the top of the screen down to the housing's bottom edge.
    let frame: NSRect

    /// The notch of the first screen that has one, or nil on Macs (and displays) without.
    @MainActor static var current: Notch? {
        for screen in NSScreen.screens {
            guard screen.safeAreaInsets.top > 0,
                  let left = screen.auxiliaryTopLeftArea,
                  let right = screen.auxiliaryTopRightArea,
                  right.minX > left.maxX else { continue }
            let height = screen.safeAreaInsets.top
            // The auxiliary areas are in the screen's own coordinate space, which is the global one
            // only for a display at the origin: with another display to its left or above, the
            // built-in screen's frame starts elsewhere and their x would be off by that much. Widths
            // are the same in both spaces, so the notch is placed by the room the left area leaves.
            return Notch(
                screen: screen,
                frame: NSRect(
                    x: screen.frame.minX + left.width,
                    y: screen.frame.maxY - height,
                    width: right.minX - left.maxX,
                    height: height
                )
            )
        }
        return nil
    }
}

/// Glint's “Dynamic Island”. In the notch position it always sits on the notch, at the notch's size.
/// It grows to both sides while hovered or while the banner overlay holds it open (a banner dropping
/// from the notch, or the list open below it). With notifications waiting it shows the newest app's
/// icon on the left and a button that clears them all (`onClearAll`) on the right; with none, Glint's
/// icon and a settings button (`onOpenSettings`). Hovering is reported through `onHoverChanged`, so
/// the banner overlay can open the list.
///
/// The window always has the grown size and never resizes, so growing and shrinking is a single
/// SwiftUI animation. The pointer is tracked instead of relying on hover events: outside the island's
/// current shape the window ignores the mouse, so the menu bar beside the notch stays clickable.
@MainActor
final class NotchOverlay {
    /// How far the black grows on each side of the notch.
    static let expansion: CGFloat = 38
    /// Width of the blur beside the grown island that softens the menu bar's titles into it.
    static let feather: CGFloat = 34
    /// The concave curves joining the shape to the screen's top edge.
    static let earRadius: CGFloat = 6
    static let bottomRadius: CGFloat = 10
    /// Above the screen-edge glow (and the alarm), so the notch and what opens from it stay on top.
    static let level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
    /// Long enough for the island to finish shrinking before its window goes.
    private static let shrinkAnimation: TimeInterval = 0.45
    /// How long the island stays grown after being released: the banners' exit, then a beat. With
    /// the list's linger and the island's own animation, it's back to the notch in about 2 s.
    private static let releaseDelay: TimeInterval = 1.2
    private static let pointerCheckInterval: TimeInterval = 1.0 / 30
    /// How many pointer checks apart the island's place is verified: a display change macOS didn't
    /// announce, or announced before it had finished moving windows, is corrected within half a second.
    private static let placeCheckEvery = 15
    /// When the displays change, windows keep being moved for a moment after the notification.
    private static let screenSettleDelays: [TimeInterval] = [0.3, 1.2]

    var onHoverChanged: ((Bool) -> Void)?
    var onClearAll: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    /// Where the pointer is, in screen coordinates. Replaceable so the hover logic can be exercised.
    var pointerLocation: () -> NSPoint = { NSEvent.mouseLocation }

    /// Keeps the island grown, e.g. while the stack below it is open. Once released it stays grown a
    /// little longer, so the banners below go first and the island follows.
    var holdsOpen = false {
        didSet {
            if oldValue, !holdsOpen {
                // Never shorter than a hold already running (`holdOpenBriefly`).
                heldUntil = max(heldUntil, Date().addingTimeInterval(Self.releaseDelay))
                scheduleRelease()
            }
            updateExpansion()
        }
    }

    private let model: BannerStackModel
    private let island = IslandState()
    private var panel: NSPanel?
    private var notch: Notch?
    /// Whether the island has been asked for. Kept apart from `showing`: without a notch there's
    /// nothing to show, and the island has to come back by itself once the notched display does.
    private var wanted = false
    private var showing = false
    private var hovered = false
    private var heldUntil = Date.distantPast
    private var releaseTimer: Timer?
    private var pointerTimer: Timer?
    private var pointerChecks = 0
    private var hideWork: DispatchWorkItem?
    /// The offset the island's view was built with, so it's only rebuilt when it really moved.
    private var appliedCenterOffset: CGFloat?

    init(model: BannerStackModel) {
        self.model = model
        // A display coming or going moves windows about, so the island is put back on the notch.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
    }

    /// Puts the island on the notch, or takes it away.
    func refresh(showing: Bool) {
        wanted = showing
        place()
    }

    /// Puts the island where the notch is now. Safe to call again at any time: it only touches the
    /// window when something has actually moved.
    private func place() {
        guard wanted, let notch = Notch.current else {
            showing = false
            updateExpansion()
            hide()
            return
        }
        showing = true
        hideWork?.cancel()
        hideWork = nil

        let panel = self.panel ?? makePanel()
        self.panel = panel
        // Room for the grown island and the blur on each side of it. Re-applied even when the notch
        // itself hasn't moved: macOS shifts windows when the displays change, and the island stayed
        // where it was pushed — in the middle of the screen after an external display went away.
        let frame = Self.shapeFrame(for: notch, grown: true).insetBy(dx: -Self.feather, dy: 0)
        if panel.frame != frame {
            panel.setFrame(frame, display: false)
        }
        // Window frames snap to whole points; shift the island so it stays centred on the notch.
        let centerOffset = notch.frame.midX - panel.frame.midX
        if self.notch?.frame.size != notch.frame.size || centerOffset != appliedCenterOffset {
            appliedCenterOffset = centerOffset
            panel.contentView = FirstMouseHostingView(rootView: NotchIslandView(
                model: model,
                island: island,
                notchSize: notch.frame.size,
                centerOffset: centerOffset,
                onClearAll: { [weak self] in self?.onClearAll?() },
                onOpenSettings: { [weak self] in self?.onOpenSettings?() }
            ))
        }
        self.notch = notch
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
        startTrackingPointer()
    }

    /// The screens settle over a moment: windows are still being moved after the notification, and a
    /// display that comes back brings the island with it.
    private func screensChanged() {
        place()
        for delay in Self.screenSettleDelays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated { self?.place() }
            }
        }
    }

    // MARK: - Pointer

    private func startTrackingPointer() {
        guard pointerTimer == nil else { return }
        let timer = Timer(timeInterval: Self.pointerCheckInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkPointer() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pointerTimer = timer
        checkPointer()
    }

    private func stopTrackingPointer() {
        pointerTimer?.invalidate()
        pointerTimer = nil
    }

    /// Hovered while the pointer is over the island's current shape; everywhere else the window lets
    /// the mouse through to whatever is below.
    private func checkPointer() {
        pointerChecks += 1
        if pointerChecks % Self.placeCheckEvery == 0 {
            place()
        }
        guard let panel, let notch, showing else { return }
        // A point of slack at the top: the pointer can rest on the screen's very edge.
        let shape = Self.shapeFrame(for: notch, grown: island.expanded).insetBy(dx: 0, dy: -1)
        let inside = NSMouseInRect(pointerLocation(), shape, false)
        if panel.ignoresMouseEvents == inside {
            panel.ignoresMouseEvents = !inside
        }
        if inside != hovered {
            hovered = inside
            updateExpansion()
            onHoverChanged?(inside)
        }
    }

    // MARK: - Growing and shrinking

    /// Re-checks the island once the release delay is over. A timer with a tight tolerance: a delayed
    /// dispatch can be coalesced up to a second late while Glint is in the background.
    /// Grows the island for a moment on its own: a notification the badge reported, whose message is
    /// still on its way, so there's no banner to hold it open yet.
    func holdOpenBriefly(_ seconds: TimeInterval) {
        heldUntil = max(heldUntil, Date().addingTimeInterval(seconds))
        releaseTimer?.invalidate()
        let timer = Timer(timeInterval: seconds + 0.05, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateExpansion() }
        }
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
        releaseTimer = timer
        updateExpansion()
    }

    /// Lets go at once, without the linger `holdsOpen` leaves behind: the list below closed because the
    /// pointer left, and the island goes with it.
    func releaseNow() {
        holdsOpen = false
        heldUntil = .distantPast
        releaseTimer?.invalidate()
        releaseTimer = nil
        updateExpansion()
    }

    private func scheduleRelease() {
        releaseTimer?.invalidate()
        let timer = Timer(timeInterval: Self.releaseDelay + 0.02, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateExpansion() }
        }
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
        releaseTimer = timer
    }

    private func updateExpansion() {
        let grow = showing && (hovered || holdsOpen || Date() < heldUntil)
        if grow != island.expanded {
            island.expanded = grow
        }
    }

    /// The island's outline in screen coordinates, ears included.
    private static func shapeFrame(for notch: Notch, grown: Bool) -> NSRect {
        let extra = grown ? expansion : 0
        return NSRect(
            x: notch.frame.minX - extra - earRadius,
            y: notch.frame.minY,
            width: notch.frame.width + 2 * extra + 2 * earRadius,
            height: notch.frame.height
        )
    }

    private func hide() {
        guard let panel, panel.isVisible, hideWork == nil else { return }
        // The island shrinks by itself; its window goes once that's done.
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.hideWork = nil
                guard !self.showing else { return }
                self.stopTrackingPointer()
                self.hovered = false
                self.panel?.orderOut(nil)
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.shrinkAnimation, execute: work)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = Self.level
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

/// Whether the island is grown (with its icons) or sits on the notch at its size.
@MainActor
@Observable
final class IslandState {
    var expanded = false
}

// MARK: - Island view

struct NotchIslandView: View {
    let model: BannerStackModel
    let island: IslandState
    let notchSize: CGSize
    /// The notch's centre relative to the window's.
    let centerOffset: CGFloat
    let onClearAll: () -> Void
    let onOpenSettings: () -> Void

    /// Both sides move together, with no overshoot.
    private static let resize = Animation.smooth(duration: 0.38)

    var body: some View {
        let newest = model.stacks.first
        let grown = island.expanded
        let shape = NotchShape(earRadius: NotchOverlay.earRadius, bottomRadius: NotchOverlay.bottomRadius)
        let grownWidth = notchSize.width + 2 * NotchOverlay.earRadius + 2 * NotchOverlay.expansion
        let blurSize = CGSize(width: grownWidth + 2 * NotchOverlay.feather, height: notchSize.height)

        ZStack {
            // Blurs the menu bar beside the grown island, fading out to the sides, so its titles
            // soften into the black instead of being cut off by it. A fixed size: it only fades in
            // and out with the island, so growing stays a single smooth animation.
            NotchFeatherBlur(size: blurSize, feather: NotchOverlay.feather)
                .frame(width: blurSize.width, height: blurSize.height)
            .opacity(grown ? 1 : 0)
            .allowsHitTesting(false)

            ZStack {
                shape.fill(.black)

                // Pinned to the shape's edges: while shrunk they sit behind the notch's hardware, and
                // as the island grows they slide out of it. The gap beside each is the gap below it.
                HStack(spacing: 0) {
                    leadingIcon(newest)
                        .scaleEffect(grown ? 1 : 0.4)
                        .opacity(grown ? 1 : 0)
                    Spacer(minLength: 0)
                    trailingButton(empty: newest == nil)
                        .scaleEffect(grown ? 1 : 0.4)
                        .opacity(grown ? 1 : 0)
                }
                .padding(.horizontal, NotchOverlay.earRadius + itemInset)
            }
            .frame(width: grown ? grownWidth : grownWidth - 2 * NotchOverlay.expansion, height: notchSize.height)
            .clipShape(shape)
            .allowsHitTesting(grown)
        }
        .offset(x: centerOffset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(Self.resize, value: grown)
    }

    /// The icon and the button are this big, each in a square.
    private static let itemSize: CGFloat = 20

    /// The gap between the icon (or button) and the island's bottom edge, used beside them too.
    private var itemInset: CGFloat {
        max(0, (notchSize.height - Self.itemSize) / 2)
    }

    private func leadingIcon(_ newest: BannerStackModel.Stack?) -> some View {
        ZStack {
            if let newest {
                appIcon(newest.app)
                    .transition(.opacity)
            } else {
                GlintIcon(size: Self.itemSize)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: newest?.app.id)
        // A new notification gives the icon a little bounce.
        .keyframeAnimator(initialValue: 1.0, trigger: newest?.items.first?.id) { content, scale in
            content.scaleEffect(scale)
        } keyframes: { _ in
            CubicKeyframe(1.22, duration: 0.14)
            SpringKeyframe(1.0, duration: 0.32, spring: .smooth)
        }
        .frame(width: Self.itemSize, height: Self.itemSize)
        // How many notifications came in, on the icon's corner like a Dock badge; its top stays a point
        // inside the island.
        .overlay(alignment: .topTrailing) {
            if let newest {
                CountBadge(count: newest.received)
                    .offset(x: 6, y: -max(0, itemInset - 1))
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: newest == nil)
    }

    /// A bare symbol, square like the icon, so the gaps around it match the icon's.
    private func trailingButton(empty: Bool) -> some View {
        Button(action: empty ? onOpenSettings : onClearAll) {
            Image(systemName: empty ? "gearshape.fill" : "xmark")
                .font(.system(size: 13, weight: .bold))
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: Self.itemSize, height: Self.itemSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(empty ? "Glint Ayarları" : "Tüm bildirimleri temizle")
        .animation(.easeInOut(duration: 0.2), value: empty)
    }

    /// The number of notifications that came in, in a Dock badge's red.
    private struct CountBadge: View {
        let count: Int

        var body: some View {
            Text(count > 99 ? "99+" : "\(count)")
                .font(.system(size: 9, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .contentTransition(.numericText(value: Double(count)))
                .animation(.snappy, value: count)
                .padding(.horizontal, 3.5)
                .frame(minWidth: 13, minHeight: 13)
                .background(Color.red, in: Capsule())
        }
    }

    @ViewBuilder
    private func appIcon(_ app: WatchedApp) -> some View {
        if let image = app.appIcon {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
        } else {
            Image(systemName: app.fallbackIconName)
                .resizable()
                .scaledToFit()
                .foregroundStyle(Color(hex: app.defaultColorHex))
        }
    }
}

/// A behind-window blur (what's under it, here the menu bar) that fades out towards its left and
/// right ends. Always active: a non-key window would otherwise draw the inactive, flat material.
struct NotchFeatherBlur: NSViewRepresentable {
    let size: CGSize
    let feather: CGFloat

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = PureBlurView()
        view.material = .menu
        view.blendingMode = .behindWindow
        view.state = .active
        view.maskImage = Self.mask(size: size, feather: feather)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}

    /// Opaque in the middle, fading to clear over `feather` at each end.
    private static func mask(size: CGSize, feather: CGFloat) -> NSImage {
        NSImage(size: size, flipped: false) { rect in
            guard let fade = NSGradient(starting: .clear, ending: .black) else { return false }
            fade.draw(in: NSRect(x: 0, y: 0, width: feather, height: rect.height), angle: 0)
            NSColor.black.setFill()
            NSRect(x: feather, y: 0, width: rect.width - 2 * feather, height: rect.height).fill()
            fade.draw(in: NSRect(x: rect.width - feather, y: 0, width: feather, height: rect.height), angle: 180)
            return true
        }
    }
}

/// A visual effect view reduced to its blur, like iOS's scroll-edge effect: no darkening, no tint.
///
/// A material normally draws a grey `fill`, a `tone` layer and a `desktop tint` over its `backdrop`
/// (the blur, with a saturation boost). Those are AppKit's internal layers (seen on macOS 27), so
/// they're hidden again after every update in case AppKit rebuilds them, e.g. on an appearance change.
final class PureBlurView: NSVisualEffectView {
    var blurRadius = 12

    override func updateLayer() {
        super.updateLayer()
        stripToBlur()
    }

    override func layout() {
        super.layout()
        stripToBlur()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        stripToBlur()
    }

    private func stripToBlur() {
        for material in layer?.sublayers ?? [] {
            for sublayer in material.sublayers ?? [] {
                if sublayer.name == "backdrop" {
                    let filters = sublayer.filters ?? []
                    let blurOnly = filters.filter { (($0 as AnyObject).value(forKey: "name") as? String) != "colorSaturate" }
                    if blurOnly.count != filters.count {
                        sublayer.filters = blurOnly
                    }
                    let radiusPath = "filters.gaussianBlur.inputRadius"
                    if (sublayer.value(forKeyPath: radiusPath) as? NSNumber)?.intValue != blurRadius {
                        sublayer.setValue(blurRadius, forKeyPath: radiusPath)
                    }
                } else if !sublayer.isHidden {
                    sublayer.isHidden = true
                }
            }
        }
    }
}

/// The notch's outline: sides that curve out into the screen's top edge, and a rounded bottom.
struct NotchShape: Shape {
    let earRadius: CGFloat
    let bottomRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let ear = earRadius
        let bottom = bottomRadius
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.minX + ear, y: rect.minY + ear), control: CGPoint(x: rect.minX + ear, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + ear, y: rect.maxY - bottom))
        path.addQuadCurve(to: CGPoint(x: rect.minX + ear + bottom, y: rect.maxY), control: CGPoint(x: rect.minX + ear, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - ear - bottom, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - ear, y: rect.maxY - bottom), control: CGPoint(x: rect.maxX - ear, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - ear, y: rect.minY + ear))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.maxX - ear, y: rect.minY))
        path.closeSubpath()
        return path
    }
}
