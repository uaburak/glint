import AppKit
import Observation
import SwiftUI

/// Where Glint's island sits: the camera housing at the top of a built-in MacBook display, or a notch
/// or an island Glint draws itself on a screen without one.
struct Notch {
    let screen: NSScreen
    /// In screen coordinates: from the top of the screen down to the housing's bottom edge; for one
    /// Glint draws, the menu bar's.
    let frame: NSRect
    /// Drawn by Glint: there's no housing behind it.
    var isVirtual = false
    /// Drawn as a capsule floating in the menu bar, rather than a notch joined to the top edge.
    var isIsland = false

    /// A drawn notch is as wide as a MacBook's.
    static let virtualWidth: CGFloat = 185
    /// The gap above and below a grown island, inside the menu bar.
    static let islandInset: CGFloat = 2
    /// A shrunk island is a dot this wide in the middle of the menu bar.
    static let islandDot: CGFloat = 10
    /// A grown island with one app's icon in it; each app more adds room for its icon.
    static let islandGrownWidth: CGFloat = 104

    /// The concave curves joining a notch to the screen's top edge; an island has none.
    var earRadius: CGFloat { isIsland ? 0 : NotchOverlay.earRadius }
    /// The black shape's height, grown: an island leaves a gap above and below it.
    var shapeHeight: CGFloat { frame.height - (isIsland ? 2 * Self.islandInset : 0) }

    /// The black shape while shrunk: the notch's own size, or an island's dot.
    var shrunkSize: CGSize {
        isIsland
            ? CGSize(width: Self.islandDot, height: Self.islandDot)
            : CGSize(width: frame.width + 2 * earRadius, height: shapeHeight)
    }

    /// Every notch the island sits on: each notched display's own, and on the other displays what's
    /// chosen in Çentik / Ada Ayarları, a drawn notch, an island or nothing.
    @MainActor static var all: [Notch] {
        let drawn = DrawnNotch(rawValue: UserDefaults.standard.string(forKey: Pref.drawnNotch) ?? "") ?? .island
        return NSScreen.screens.compactMap { screen in
            if let notch = hardware(on: screen) { return notch }
            switch drawn {
            case .notch: return virtual(on: screen)
            case .island: return virtual(on: screen, island: true)
            case .none: return nil
            }
        }
    }

    /// The notch banners drop from and the waiting list opens under: the one on the display last
    /// focused (`focus(on:)`), or the first there is, the main display's if it has one. nil when
    /// there's no notch to use.
    @MainActor static var current: Notch? {
        let notches = all
        return notches.first { $0.screen.displayID == focusedDisplay } ?? notches.first
    }

    @MainActor private static var focusedDisplay: CGDirectDisplayID?

    /// Makes the notch on `screen` the one banners drop from and the list opens under.
    @MainActor static func focus(on screen: NSScreen) {
        focusedDisplay = screen.displayID
    }

    /// Focuses the display the pointer is on: where the user is working, so a notification comes out
    /// of the island in front of them.
    @MainActor static func focusOnPointer() {
        let pointer = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(pointer, $0.frame, false) }) {
            focus(on: screen)
        }
    }

    /// The screen's own notch, if it has one.
    @MainActor static func hardware(on screen: NSScreen) -> Notch? {
        guard screen.safeAreaInsets.top > 0,
              let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea,
              right.minX > left.maxX else { return nil }
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

    /// A notch drawn in the middle of the screen's menu bar, as tall as the menu bar; or an island
    /// floating inside it. An island's frame is a square as tall as the menu bar around its dot, so
    /// the dot is easy to hover.
    @MainActor static func virtual(on screen: NSScreen, island: Bool = false) -> Notch {
        let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
        // A hidden menu bar leaves no room to measure; the standard height then.
        let height = min(max(menuBar > 0 ? menuBar : NSStatusBar.system.thickness, 22), 40)
        let width = island ? height : virtualWidth
        return Notch(
            screen: screen,
            frame: NSRect(
                x: (screen.frame.midX - width / 2).rounded(),
                y: screen.frame.maxY - height,
                width: width,
                height: height
            ),
            isVirtual: true,
            isIsland: island
        )
    }
}

// MARK: - What's in the island

extension Notch {
    /// The icon and the button are this big, each in a square; smaller in an island, which is
    /// thinner than a notch.
    var itemSize: CGFloat { isIsland ? min(20, shapeHeight - 6) : 20 }

    /// The gap between the icon (or button) and the shape's bottom edge, used beside them too.
    var itemInset: CGFloat { max(0, (shapeHeight - itemSize) / 2) }

    /// From the shape's sides to the icon and the button. A capsule's ends curve in, so they keep
    /// further from them.
    var horizontalInset: CGFloat { isIsland ? 2 * itemInset : earRadius + itemInset }

    /// Between one app's icon and the next: room for the count on its corner.
    var iconGap: CGFloat { isIsland ? 8 : NotchOverlay.iconStep - itemSize }

    /// Every waiting app's icon, side by side, or the newest one's: an island always shows them all.
    func showsAllApps(_ chosen: Bool) -> Bool { chosen || isIsland }

    /// How far the black grows past the frame on each side with this many icons in it. The two sides
    /// grow alike, so it stays centred. A notch grows past its housing; an island to its own width,
    /// less than a notch, and by each app's icon past the first.
    func expansion(icons: Int) -> CGFloat {
        let icons = CGFloat(max(icons, 1))
        guard isIsland else { return NotchOverlay.expansion + (icons - 1) * NotchOverlay.iconStep }
        let grown = Self.islandGrownWidth + (icons - 1) * (itemSize + iconGap)
        return max(0, (grown - frame.width) / 2)
    }
}

extension NSScreen {
    /// The display's id: it stays the same while the display is connected, unlike its NSScreen, which
    /// macOS replaces when the displays change.
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}

/// Glint's “Dynamic Island”. It sits on the notch, at the notch's size, and grows to both sides while
/// hovered or while the banner overlay holds it open (a banner dropping from the notch, or the list
/// open below it). With notifications waiting it shows the newest app's icon on the left (or every
/// waiting app's, side by side) and a button that clears them all (`onClearAll`) on the right; with
/// none, Glint's icon and a settings button (`onOpenSettings`). Hovering is reported through
/// `onHoverChanged`, so the banner overlay can open the list. On a screen without a notch it sits on
/// a notch or an island it draws, which can stay away while nothing is waiting.
///
/// With an island on every display, each has its own window and they all grow and shrink together;
/// the one hovered becomes the focused notch (`Notch.focus(on:)`), so the list opens below it.
///
/// A window always has the grown size and never resizes, so growing and shrinking is a single
/// SwiftUI animation. The pointer is tracked instead of relying on hover events: outside the island's
/// current shape the window ignores the mouse, so the menu bar beside the notch stays clickable.
@MainActor
final class NotchOverlay {
    /// How far the black grows on each side of the notch, with one icon in it.
    nonisolated static let expansion: CGFloat = 38
    /// Most app icons the island shows side by side.
    static let maxIcons = 3
    /// What each icon past the first adds to the growth: the icon and the gap before it, room for
    /// the count on its corner.
    nonisolated static let iconStep: CGFloat = 30
    /// Width of the blur beside the grown island that softens the menu bar's titles into it.
    static let feather: CGFloat = 34
    /// The concave curves joining the shape to the screen's top edge.
    nonisolated static let earRadius: CGFloat = 6
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

    /// How the island behaves; set from Görünüm Ayarları.
    var settings = NotchSettings() {
        didSet {
            guard settings != oldValue else { return }
            island.showsAllApps = settings.showsAllApps
            island.showsBadges = settings.showsBadges
            place()
        }
    }

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

    /// One display's island: its window, the notch it sits on, and whether it's on its way out.
    @MainActor
    private final class IslandWindow {
        let panel: NSPanel
        var notch: Notch?
        /// Off once the island isn't wanted on this display; its window goes when it has shrunk.
        var isPlaced = false
        var hideWork: DispatchWorkItem?
        /// The offset the island's view was built with, so it's only rebuilt when it really moved.
        var appliedCenterOffset: CGFloat?

        init() {
            panel = NotchOverlay.makePanel()
        }
    }

    private let model: BannerStackModel
    private let island = IslandState()
    /// The island's windows, by display.
    private var windows: [CGDirectDisplayID: IslandWindow] = [:]
    /// Whether the island has been asked for. Kept apart from `showing`: without a notch there's
    /// nothing to show, and the island has to come back by itself once the notched display does.
    private var wanted = false
    private var showing = false
    private var hovered = false
    /// When the pointer came onto the shrunk island, for the delay before it opens.
    private var pointerArrived: Date?
    private var heldUntil = Date.distantPast
    private var releaseTimer: Timer?
    private var pointerTimer: Timer?
    private var pointerChecks = 0

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

    /// Puts an island on each notch there is now, and takes the others away. Safe to call again at any
    /// time: it only touches a window when something has actually moved.
    private func place() {
        // A drawn notch goes away with the last notification, if the user asked for that.
        let notches = wanted
            ? Notch.all.filter { !($0.isVirtual && settings.hidesVirtualWhenEmpty && model.stacks.isEmpty) }
            : []
        showing = !notches.isEmpty
        if !showing {
            updateExpansion()
        }

        var placed = Set<CGDirectDisplayID>()
        for notch in notches {
            guard let display = notch.screen.displayID else { continue }
            placed.insert(display)
            let window = windows[display] ?? IslandWindow()
            windows[display] = window
            place(window, on: notch)
        }
        for (display, window) in windows where !placed.contains(display) {
            hide(window, of: display)
        }
        if showing {
            startTrackingPointer()
        }
    }

    private func place(_ window: IslandWindow, on notch: Notch) {
        window.isPlaced = true
        window.hideWork?.cancel()
        window.hideWork = nil

        let panel = window.panel
        // Room for the grown island and the blur on each side of it. Re-applied even when the notch
        // itself hasn't moved: macOS shifts windows when the displays change, and the island stayed
        // where it was pushed — in the middle of the screen after an external display went away.
        let frame = Self.shapeFrame(for: notch, extra: notch.expansion(icons: Self.maxIcons)).insetBy(dx: -Self.feather, dy: 0)
        if panel.frame != frame {
            panel.setFrame(frame, display: false)
        }
        // Window frames snap to whole points; shift the island so it stays centred on the notch.
        let centerOffset = notch.frame.midX - panel.frame.midX
        if window.notch?.frame.size != notch.frame.size || window.notch?.isVirtual != notch.isVirtual
            || window.notch?.isIsland != notch.isIsland || centerOffset != window.appliedCenterOffset {
            window.appliedCenterOffset = centerOffset
            panel.contentView = FirstMouseHostingView(rootView: NotchIslandView(
                model: model,
                island: island,
                notch: notch,
                centerOffset: centerOffset,
                onClearAll: { [weak self] in self?.onClearAll?() },
                onOpenSettings: { [weak self] in self?.onOpenSettings?() }
            ))
        }
        window.notch = notch
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
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
        guard showing else { return }
        let pointer = pointerLocation()
        var under: Notch?
        for window in windows.values {
            var inside = false
            if window.isPlaced, let notch = window.notch {
                let extra = island.expanded ? notch.expansion(icons: iconCount(on: notch)) : 0
                // A point of slack at the top: the pointer can rest on the screen's very edge.
                let shape = Self.shapeFrame(for: notch, extra: extra).insetBy(dx: 0, dy: -1)
                inside = NSMouseInRect(pointer, shape, false)
                if inside {
                    under = notch
                }
            }
            if window.panel.ignoresMouseEvents == inside {
                window.panel.ignoresMouseEvents = !inside
            }
        }
        let inside = under != nil
        // A shrunk island opens once the pointer has rested on it for the chosen delay, so passing
        // over it on the way to the menu bar doesn't; a grown one is open already.
        var opens = inside
        if inside, !hovered, !island.expanded, settings.hoverDelay > 0 {
            let arrived = pointerArrived ?? Date()
            pointerArrived = arrived
            opens = Date().timeIntervalSince(arrived) >= settings.hoverDelay
        }
        if !inside {
            pointerArrived = nil
        }
        if opens != hovered {
            hovered = opens
            // The list opens below the island the pointer is on.
            if opens, let under {
                Notch.focus(on: under.screen)
            }
            updateExpansion()
            onHoverChanged?(opens)
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
            // Islands taken away while grown go once they've shrunk.
            if !grow {
                for (display, window) in windows where !window.isPlaced && window.panel.isVisible {
                    orderOutAfterShrinking(window, of: display)
                }
            }
        }
    }

    /// How many app icons the island on `notch` shows now.
    private func iconCount(on notch: Notch) -> Int {
        Self.iconCount(showsAllApps: notch.showsAllApps(settings.showsAllApps), waiting: model.stacks.count)
    }

    static func iconCount(showsAllApps: Bool, waiting: Int) -> Int {
        showsAllApps ? min(max(waiting, 1), maxIcons) : 1
    }

    /// The island's outline in screen coordinates, ears included, grown by `extra` on each side. A
    /// floating island's includes the gaps above and below it.
    private static func shapeFrame(for notch: Notch, extra: CGFloat) -> NSRect {
        NSRect(
            x: notch.frame.minX - extra - notch.earRadius,
            y: notch.frame.minY,
            width: notch.frame.width + 2 * extra + 2 * notch.earRadius,
            height: notch.frame.height
        )
    }

    /// Takes a display's island away: its window goes once the island has shrunk. With nothing left to
    /// show, every island shrinks by itself; one taken from a display while the others stay grown (a
    /// drawn notch after the last notification) waits for them to shrink (`updateExpansion`).
    private func hide(_ window: IslandWindow, of display: CGDirectDisplayID) {
        window.isPlaced = false
        guard window.panel.isVisible, window.hideWork == nil, !island.expanded else { return }
        orderOutAfterShrinking(window, of: display)
    }

    private func orderOutAfterShrinking(_ window: IslandWindow, of display: CGDirectDisplayID) {
        window.hideWork?.cancel()
        let work = DispatchWorkItem { [weak self, weak window] in
            MainActor.assumeIsolated {
                guard let self, let window else { return }
                window.hideWork = nil
                // Grown again meanwhile: it goes after the next shrink.
                guard !window.isPlaced, !self.island.expanded else { return }
                window.panel.orderOut(nil)
                // A display that's gone takes its island with it.
                if !NSScreen.screens.contains(where: { $0.displayID == display }) {
                    self.windows[display] = nil
                }
                if !self.showing {
                    self.stopTrackingPointer()
                    self.hovered = false
                }
            }
        }
        window.hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.shrinkAnimation, execute: work)
    }

    private static func makePanel() -> NSPanel {
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

/// Whether the island is grown (with its icons) or sits on the notch at its size, and what it shows.
@MainActor
@Observable
final class IslandState {
    var expanded = false
    /// Every waiting app's icon, side by side, instead of the newest one's; an island always shows them.
    var showsAllApps = false
    /// The count on the icons' corners.
    var showsBadges = true
}

// MARK: - Island view

struct NotchIslandView: View {
    let model: BannerStackModel
    let island: IslandState
    /// What it sits on; only its size and shape are used.
    let notch: Notch
    /// The notch's centre relative to the window's.
    let centerOffset: CGFloat
    let onClearAll: () -> Void
    let onOpenSettings: () -> Void

    /// Both sides move together, with no overshoot.
    private static let resize = Animation.smooth(duration: 0.38)

    var body: some View {
        let newest = model.stacks.first
        let grown = island.expanded
        let showsAllApps = notch.showsAllApps(island.showsAllApps)
        let icons = NotchOverlay.iconCount(showsAllApps: showsAllApps, waiting: model.stacks.count)
        let expansion = notch.expansion(icons: icons)
        let shape = notch.isIsland
            ? AnyShape(Capsule())
            : AnyShape(NotchShape(earRadius: NotchOverlay.earRadius, bottomRadius: NotchOverlay.bottomRadius))
        let grownWidth = notch.frame.width + 2 * notch.earRadius + 2 * expansion
        // The whole menu bar's height, also around an island floating in it.
        let blurSize = CGSize(width: grownWidth + 2 * NotchOverlay.feather, height: notch.frame.height)

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
                    Group {
                        if showsAllApps, model.stacks.count > 1 {
                            appIcons(Array(model.stacks.prefix(NotchOverlay.maxIcons)))
                        } else {
                            leadingIcon(newest)
                        }
                    }
                    .scaleEffect(grown ? 1 : 0.4)
                    .opacity(grown ? 1 : 0)
                    Spacer(minLength: 0)
                    trailingButton(empty: newest == nil)
                        .scaleEffect(grown ? 1 : 0.4)
                        .opacity(grown ? 1 : 0)
                }
                .padding(.horizontal, notch.horizontalInset)
            }
            // An island is centred in the menu bar's height: a dot shrunk, with gaps above and below grown.
            .frame(width: grown ? grownWidth : notch.shrunkSize.width, height: grown ? notch.shapeHeight : notch.shrunkSize.height)
            .clipShape(shape)
            .allowsHitTesting(grown)
        }
        .offset(x: centerOffset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(Self.resize, value: grown)
        .animation(Self.resize, value: icons)
    }

    private var itemSize: CGFloat { notch.itemSize }
    private var itemInset: CGFloat { notch.itemInset }

    private func leadingIcon(_ newest: BannerStackModel.Stack?) -> some View {
        ZStack {
            if let newest {
                appIcon(newest.app)
                    .transition(.opacity)
            } else {
                GlintIcon(size: itemSize)
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
        .frame(width: itemSize, height: itemSize)
        // How many notifications came in, on the icon's corner like a Dock badge; its top stays a point
        // inside the island.
        .overlay(alignment: .topTrailing) {
            if let newest, island.showsBadges {
                CountBadge(count: newest.received)
                    .offset(x: 6, y: -max(0, itemInset - 1))
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: newest == nil)
    }

    /// Every waiting app's icon side by side, the newest first, each with its own count.
    private func appIcons(_ stacks: [BannerStackModel.Stack]) -> some View {
        HStack(spacing: notch.iconGap) {
            ForEach(stacks) { stack in
                appIcon(stack.app)
                    .frame(width: itemSize, height: itemSize)
                    // The app a notification just came from gives a little bounce.
                    .keyframeAnimator(initialValue: 1.0, trigger: stack.items.first?.id) { content, scale in
                        content.scaleEffect(scale)
                    } keyframes: { _ in
                        CubicKeyframe(1.22, duration: 0.14)
                        SpringKeyframe(1.0, duration: 0.32, spring: .smooth)
                    }
                    .overlay(alignment: .topTrailing) {
                        if island.showsBadges {
                            CountBadge(count: stack.received)
                                .offset(x: 6, y: -max(0, itemInset - 1))
                        }
                    }
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: stacks.map(\.id))
    }

    /// A bare symbol, square like the icon, so the gaps around it match the icon's.
    private func trailingButton(empty: Bool) -> some View {
        Button(action: empty ? onOpenSettings : onClearAll) {
            Image(systemName: empty ? "gearshape.fill" : "xmark")
                .font(.system(size: (itemSize * 0.65).rounded(), weight: .bold))
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: itemSize, height: itemSize)
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

    /// The island grows wider with more icons in it, and the blur with it.
    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        if view.maskImage?.size != size {
            view.maskImage = Self.mask(size: size, feather: feather)
        }
    }

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
