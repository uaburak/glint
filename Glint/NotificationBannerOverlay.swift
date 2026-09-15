import AppKit
import Observation
import SwiftUI

/// Notification banners in the style of macOS's own: glass cards, one stack per app. A new
/// notification's banner pops up at the chosen position for a few seconds; hovering keeps it there
/// and reveals its close and "Aç" buttons. The first click on a stack of several notifications spreads
/// them out, a click on a single card opens the app.
///
/// On a Mac with a notch, notifications also wait in the notch whatever the position: the notch grows
/// with the app's icon while a banner is up (`NotchOverlay`), and hovering it opens every waiting
/// notification below it, grouped by app. Under the notch, banners grow out of it.
@MainActor
final class NotificationBannerOverlay {
    static let shared = NotificationBannerOverlay()

    static let cardWidth: CGFloat = 344
    /// Transparent room around the cards for the close button, which overhangs a card's corner.
    static let margin: CGFloat = 14
    /// How long a new notification's banner stays up.
    static let popDuration: TimeInterval = 6
    /// Distance from the cards to the screen's edge (below the menu bar, above the Dock).
    static let screenInset: CGFloat = 10
    /// Space between the notch and the banners below it.
    static let notchGap: CGFloat = 6
    /// Notifications nobody opened wait in the notch; they go once read, or after this long.
    private static let waitingLifetime: TimeInterval = 30 * 60
    /// How long banners stay after the pointer leaves them.
    private static let lingerAfterHover: TimeInterval = 2.5
    /// Long enough for a removal animation to finish before a panel shrinks or hides.
    private static let removalAnimation: TimeInterval = 0.35
    /// How long the notch's list stays open after the pointer leaves both it and the notch.
    private static let notchListLinger: TimeInterval = 0.35
    static let arrival = Animation.spring(response: 0.42, dampingFraction: 0.86)

    private let model = BannerStackModel()
    private lazy var notch: NotchOverlay = {
        let notch = NotchOverlay(model: model)
        notch.onHoverChanged = { [weak self] hovering in self?.notchHoverChanged(hovering) }
        notch.onClearAll = { [weak self] in self?.dismiss() }
        notch.onOpenSettings = { [weak self] in self?.onOpenSettings?() }
        return notch
    }()
    /// Banners popping up at the chosen position (under the notch, it also shows the waiting list).
    private lazy var popPanel = BannerPanel(model: model, handlers: handlers)
    /// The waiting list under the notch, when banners pop up somewhere else.
    private lazy var listPanel = BannerPanel(model: model, handlers: handlers)
    private var position: BannerPosition = .topRight
    private var bannersEnabled = true
    private var notchAvailable = false
    private var timer: Timer?
    private var notchHovered = false
    private var closeNotchListWork: DispatchWorkItem?

    /// Opens Glint's settings, from the island's settings button.
    var onOpenSettings: (() -> Void)?

    private var handlers: BannerPanel.Handlers {
        BannerPanel.Handlers(
            tap: { [weak self] stack in self?.cardTapped(stack) },
            open: { [weak self] stack in self?.open(stack) },
            close: { [weak self] id in self?.remove(stackID: id) },
            hover: { [weak self] hovering in self?.hoverChanged(hovering) }
        )
    }

    /// Where banners pop up: the chosen position, or the top centre when the notch position has no notch.
    private var popPosition: BannerPosition {
        position == .notch && Notch.current == nil ? .topCenter : position
    }

    /// Whether the waiting list needs its own panel under the notch.
    private var listNeedsOwnPanel: Bool {
        Notch.current != nil && popPosition != .notch
    }

    /// Shows a notification: on top of its app's stack if that app's banner is up, as a new stack otherwise.
    func show(app: WatchedApp, title: String, body: String, position: BannerPosition) {
        if position != self.position {
            self.position = position
            arrangePanels()
        }

        let now = Date()
        // With a notch, notifications nobody opened wait in it; without one they go with their banner.
        let lifetime = Notch.current != nil ? Self.waitingLifetime : Self.popDuration
        withAnimation(Self.arrival) {
            if !notchHovered {
                model.showsAll = false
            }
            model.push(
                BannerStackModel.Item(title: title, body: body),
                from: app,
                expiresAt: now.addingTimeInterval(lifetime),
                popsUntil: now.addingTimeInterval(Self.popDuration)
            )
        }
        startTimer()
        syncNotch()
        presentPanels()
    }

    /// Removes an app's notifications, e.g. once they've been read in the app.
    func clear(appID: String) {
        guard model.stacks.contains(where: { $0.id == appID }) else { return }
        remove(stackID: appID)
    }

    /// Follows the settings: where banners pop up and whether they're on. With a notch the island sits
    /// on it whenever banners are on, even before any notification.
    func configure(position: BannerPosition, enabled: Bool) {
        let hasNotch = Notch.current != nil
        guard position != self.position || enabled != bannersEnabled || hasNotch != notchAvailable else { return }
        self.position = position
        bannersEnabled = enabled
        notchAvailable = hasNotch
        arrangePanels()
        syncNotch()
    }

    /// Removes every notification.
    func dismiss(animated: Bool = true) {
        guard !model.stacks.isEmpty else { return }
        if animated {
            withAnimation(.easeOut(duration: 0.25)) { model.stacks.removeAll() }
            syncNotch()
            afterChange()
        } else {
            model.stacks.removeAll()
            allRemoved()
        }
    }

    // MARK: - Panels

    private func arrangePanels() {
        popPanel.configure(position: popPosition, shelf: popPosition == .notch ? .poppingAndList : .popping)
        listPanel.configure(position: .notch, shelf: .list)
        if !listNeedsOwnPanel {
            listPanel.hide()
        }
    }

    private func presentPanels() {
        popPanel.present()
        if listNeedsOwnPanel {
            listPanel.present()
        }
    }

    /// Once a change has animated: hide everything if nothing is left, otherwise hide the panels with
    /// nothing to show and fit the others.
    private func afterChange() {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.removalAnimation) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.model.stacks.isEmpty {
                    self.allRemoved()
                } else {
                    self.popPanel.hideIfEmpty()
                    self.listPanel.hideIfEmpty()
                }
            }
        }
    }

    private func allRemoved() {
        timer?.invalidate()
        timer = nil
        // A banner closed under the pointer never reports the pointer leaving.
        model.hovered = false
        model.showsAll = false
        notchHovered = false
        popPanel.hide()
        listPanel.hide()
        syncNotch()
    }

    // MARK: - Stacks

    /// The first click on a stack of several notifications spreads them out; a click on a card that's
    /// on its own, or already spread out, counts as clicking the notification.
    private func cardTapped(_ stack: BannerStackModel.Stack) {
        if stack.items.count > 1 && !stack.expanded {
            guard let index = model.stacks.firstIndex(where: { $0.id == stack.id }) else { return }
            withAnimation(.spring(response: 0.38, dampingFraction: 0.88)) {
                model.stacks[index].expanded = true
            }
            popPanel.scheduleFrameUpdate()
            listPanel.scheduleFrameUpdate()
        } else {
            open(stack)
        }
    }

    private func open(_ stack: BannerStackModel.Stack) {
        stack.app.openApplication()
        remove(stackID: stack.id)
    }

    private func remove(stackID: String) {
        withAnimation(.easeOut(duration: 0.25)) {
            model.stacks.removeAll { $0.id == stackID }
        }
        syncNotch()
        afterChange()
    }

    private func hoverChanged(_ hovering: Bool) {
        model.hovered = hovering
        guard !hovering else { return }
        let resume = Date().addingTimeInterval(Self.lingerAfterHover)
        for index in model.stacks.indices {
            if model.stacks[index].expiresAt < resume {
                model.stacks[index].expiresAt = resume
            }
            if let pops = model.stacks[index].popsUntil, pops < resume {
                model.stacks[index].popsUntil = resume
            }
        }
        scheduleNotchListClose()
    }

    // MARK: - Notch

    /// The island sits on the notch while banners are on, whatever their position, and grows while a
    /// banner is up or the waiting list is open.
    private func syncNotch() {
        guard Notch.current != nil, bannersEnabled else {
            notch.holdsOpen = false
            notch.refresh(showing: false)
            return
        }
        notch.refresh(showing: true)
        notch.holdsOpen = !model.stacks.isEmpty && (model.showsAll || model.stacks.contains { $0.popsUntil != nil })
    }

    private func notchHoverChanged(_ hovering: Bool) {
        notchHovered = hovering
        if hovering {
            guard Notch.current != nil, !model.stacks.isEmpty else { return }
            closeNotchListWork?.cancel()
            withAnimation(Self.arrival) {
                model.showsAll = true
            }
            syncNotch()
            presentPanels()
        } else {
            scheduleNotchListClose()
        }
    }

    /// Closes the waiting list once the pointer has left both it and the notch; banners still up stay
    /// until their time is up.
    private func scheduleNotchListClose() {
        guard Notch.current != nil else { return }
        closeNotchListWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.notchHovered, !self.model.hovered, self.model.showsAll else { return }
                withAnimation(.easeOut(duration: 0.25)) {
                    self.model.showsAll = false
                    for index in self.model.stacks.indices where self.model.stacks[index].popsUntil == nil {
                        self.model.stacks[index].expanded = false
                    }
                }
                self.syncNotch()
                self.afterChange()
            }
        }
        closeNotchListWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.notchListLinger, execute: work)
    }

    // MARK: - Timing

    private func startTimer() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Ends banners whose time is up (they keep waiting in the notch, if there is one) and removes
    /// notifications that have waited too long.
    private func tick() {
        // Hover-exit isn't reported when the card under the pointer goes away; check the pointer itself.
        let pointer = NSEvent.mouseLocation
        if model.hovered, !popPanel.contains(pointer), !listPanel.contains(pointer) {
            hoverChanged(false)
        }
        guard !model.hovered else { return }
        let now = Date()
        var changed = false

        let popsEnded = model.stacks.indices.filter { model.stacks[$0].popsUntil.map { $0 <= now } == true }
        if !popsEnded.isEmpty {
            withAnimation(.easeOut(duration: 0.3)) {
                for index in popsEnded {
                    model.stacks[index].popsUntil = nil
                    if !model.showsAll {
                        model.stacks[index].expanded = false
                    }
                }
            }
            changed = true
        }

        if model.stacks.contains(where: { $0.expiresAt <= now }) {
            withAnimation(.easeOut(duration: 0.3)) {
                model.stacks.removeAll { $0.expiresAt <= now }
            }
            changed = true
        }

        if changed {
            syncNotch()
            afterChange()
        }
    }
}

extension BannerPosition {
    var isTop: Bool {
        switch self {
        case .topLeft, .topCenter, .topRight, .notch: true
        case .bottomLeft, .bottomCenter, .bottomRight: false
        }
    }
}

/// Takes the first click even though Glint isn't the active app, like a system banner does.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Panel

/// One window of banners: at a screen position or under the notch, showing one shelf of the model.
@MainActor
private final class BannerPanel {
    struct Handlers {
        let tap: (BannerStackModel.Stack) -> Void
        let open: (BannerStackModel.Stack) -> Void
        let close: (String) -> Void
        let hover: (Bool) -> Void
    }

    private let model: BannerStackModel
    private let handlers: Handlers
    private var panel: NSPanel?
    private var hosting: NSHostingView<BannerStackView>?
    private var position: BannerPosition = .topRight
    private var shelf: BannerStackModel.Shelf = .popping

    init(model: BannerStackModel, handlers: Handlers) {
        self.model = model
        self.handlers = handlers
    }

    private var shown: [BannerStackModel.Stack] {
        model.shown(on: shelf)
    }

    func contains(_ point: NSPoint) -> Bool {
        guard let panel, panel.isVisible else { return false }
        return NSMouseInRect(point, panel.frame, false)
    }

    /// Where the panel sits and what it shows; its view is rebuilt when either changes.
    func configure(position: BannerPosition, shelf: BannerStackModel.Shelf) {
        guard position != self.position || shelf != self.shelf else { return }
        self.position = position
        self.shelf = shelf
        hosting = nil
        panel?.orderOut(nil)
    }

    func present() {
        guard !shown.isEmpty else { return }
        let panel = self.panel ?? Self.makePanel()
        self.panel = panel
        // Under the notch the banners stay above the screen-edge glow, like the notch itself.
        panel.level = position == .notch ? NotchOverlay.level : .statusBar

        if hosting == nil {
            let hosting = FirstMouseHostingView(rootView: BannerStackView(
                model: model,
                position: position,
                shelf: shelf,
                onTap: handlers.tap,
                onOpen: handlers.open,
                onClose: handlers.close,
                onHover: handlers.hover
            ))
            panel.contentView = hosting
            self.hosting = hosting
        }
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
        scheduleFrameUpdate()
    }

    /// Hides the panel when its shelf is empty, or fits it to what's left.
    func hideIfEmpty() {
        guard let panel, panel.isVisible else { return }
        if shown.isEmpty {
            panel.orderOut(nil)
        } else {
            updateFrame()
        }
    }

    func hide() {
        panel?.orderOut(nil)
    }

    /// The size is right once SwiftUI has laid out the change.
    func scheduleFrameUpdate() {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.updateFrame() }
        }
    }

    /// Fits the panel to its banners, pinned to its corner or edge, or just below the notch.
    private func updateFrame() {
        guard let panel, let hosting, !shown.isEmpty else { return }
        let size = hosting.fittingSize
        typealias Overlay = NotificationBannerOverlay

        if position == .notch, let notch = Notch.current {
            // The top margin is transparent, so the first card starts `notchGap` below the notch.
            let y = notch.frame.minY - Overlay.notchGap + Overlay.margin - size.height
            panel.setFrame(NSRect(x: notch.frame.midX - size.width / 2, y: y, width: size.width, height: size.height), display: true)
            return
        }

        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        // The margin is transparent, so it may reach past the inset.
        let inset = Overlay.screenInset - Overlay.margin
        let x: CGFloat = switch position {
        case .topLeft, .bottomLeft: visible.minX + inset
        case .topCenter, .bottomCenter, .notch: visible.midX - size.width / 2
        case .topRight, .bottomRight: visible.maxX - size.width - inset
        }
        let y: CGFloat = position.isTop ? visible.maxY - size.height - inset : visible.minY + inset
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: NotificationBannerOverlay.cardWidth + 2 * NotificationBannerOverlay.margin, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The glass draws its own edge and shadow; a window shadow would outline the transparent margin.
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        return panel
    }
}

// MARK: - Model

/// The notifications: one stack per app, newest stack first, newest notification first.
@MainActor
@Observable
final class BannerStackModel {
    /// Which notifications a panel shows.
    enum Shelf: Equatable {
        /// Banners that are up.
        case popping
        /// Banners that are up, and every waiting notification while the notch is hovered.
        case poppingAndList
        /// Every waiting notification while the notch is hovered.
        case list
    }

    struct Item: Identifiable, Equatable {
        let id = UUID()
        let title: String
        let body: String
    }

    struct Stack: Identifiable {
        let app: WatchedApp
        var items: [Item]
        var expanded = false
        var expiresAt: Date
        /// Until when the stack's banner is up after a new notification.
        var popsUntil: Date?

        var id: String { app.id }
    }

    var stacks: [Stack] = []
    var hovered = false
    /// Whether the notch's waiting list is open.
    var showsAll = false

    func shown(on shelf: Shelf) -> [Stack] {
        switch shelf {
        case .popping: stacks.filter { $0.popsUntil != nil }
        case .poppingAndList: showsAll ? stacks : stacks.filter { $0.popsUntil != nil }
        case .list: showsAll ? stacks : []
        }
    }

    func push(_ item: Item, from app: WatchedApp, expiresAt: Date, popsUntil: Date?, maxStacks: Int = 4, maxPerStack: Int = 10) {
        if let index = stacks.firstIndex(where: { $0.id == app.id }) {
            var stack = stacks.remove(at: index)
            stack.items.insert(item, at: 0)
            stack.items = Array(stack.items.prefix(maxPerStack))
            stack.expiresAt = expiresAt
            stack.popsUntil = popsUntil
            stacks.insert(stack, at: 0)
        } else {
            stacks.insert(Stack(app: app, items: [item], expiresAt: expiresAt, popsUntil: popsUntil), at: 0)
            stacks = Array(stacks.prefix(maxStacks))
        }
    }
}

// MARK: - Views

extension AnyTransition {
    /// Grows out of the notch above and shrinks back into it.
    static var fromNotch: AnyTransition {
        .scale(scale: 0.3, anchor: .top).combined(with: .opacity)
    }
}

struct BannerStackView: View {
    let model: BannerStackModel
    let position: BannerPosition
    let shelf: BannerStackModel.Shelf
    let onTap: (BannerStackModel.Stack) -> Void
    let onOpen: (BannerStackModel.Stack) -> Void
    let onClose: (String) -> Void
    let onHover: (Bool) -> Void

    var body: some View {
        // The newest stack sits nearest the screen edge (or the notch).
        let shown = model.shown(on: shelf)
        let stacks = position.isTop ? shown : Array(shown.reversed())
        VStack(spacing: 10) {
            ForEach(stacks) { stack in
                BannerStackCards(
                    stack: stack,
                    underNotch: position == .notch,
                    onTap: { onTap(stack) },
                    onOpen: { onOpen(stack) },
                    onClose: { onClose(stack.id) }
                )
                .transition(stackTransition)
            }
        }
        .padding(NotificationBannerOverlay.margin)
        .frame(width: NotificationBannerOverlay.cardWidth + 2 * NotificationBannerOverlay.margin)
        // While the panel waits to shrink, keep the banners against the screen edge.
        .frame(maxHeight: .infinity, alignment: position.isTop ? .top : .bottom)
        .onHover(perform: onHover)
    }

    private var stackTransition: AnyTransition {
        guard position != .notch else { return .fromNotch }
        let edge: Edge = switch position {
        case .topRight, .bottomRight: .trailing
        case .topLeft, .bottomLeft: .leading
        case .topCenter, .notch: .top
        case .bottomCenter: .bottom
        }
        return .asymmetric(
            insertion: .move(edge: edge).combined(with: .opacity),
            removal: .opacity.combined(with: .scale(scale: 0.95))
        )
    }
}

/// One app's notifications: the newest card with the others peeking out behind it (above it under the
/// notch, below it elsewhere), or every card once spread out.
private struct BannerStackCards: View {
    let stack: BannerStackModel.Stack
    let underNotch: Bool
    let onTap: () -> Void
    let onOpen: () -> Void
    let onClose: () -> Void

    /// How far each card behind the top one shows past it.
    private static let peek: CGFloat = 7

    var body: some View {
        if stack.expanded {
            VStack(spacing: 8) {
                ForEach(stack.items) { item in
                    BannerCardView(app: stack.app, title: item.title, message: item.body, onTap: onTap, onOpen: onOpen, onClose: onClose)
                        .transition(underNotch ? .fromNotch : .opacity)
                }
            }
        } else {
            let layers = min(stack.items.count - 1, 2)
            let newest = stack.items[0]
            ZStack {
                BannerCardView(app: stack.app, title: newest.title, message: newest.body, onTap: onTap, onOpen: onOpen, onClose: onClose)
                    .id(newest.id)
                    // A new notification lands on the stack the way a new stack arrives.
                    .transition(.asymmetric(
                        insertion: underNotch ? .fromNotch : .scale(scale: 0.9).combined(with: .opacity),
                        removal: .opacity
                    ))
            }
            .background {
                ForEach(0..<layers, id: \.self) { layer in
                    let depth = CGFloat(layers - layer)
                    Color.clear
                        .bannerGlass(in: BannerCardView.shape)
                        // Only the part past the top card shows; the rest would darken its glass.
                        .mask(alignment: underNotch ? .top : .bottom) {
                            Rectangle().frame(height: 22 + Self.peek * depth)
                        }
                        .scaleEffect(x: 1 - 0.05 * depth, y: 1, anchor: underNotch ? .top : .bottom)
                        .offset(y: (underNotch ? -1 : 1) * Self.peek * depth)
                        .opacity(1 - 0.2 * depth)
                }
            }
            .padding(underNotch ? .top : .bottom, CGFloat(layers) * Self.peek)
        }
    }
}

struct BannerCardView: View {
    static let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)

    let app: WatchedApp
    let title: String
    let message: String
    let onTap: () -> Void
    let onOpen: () -> Void
    let onClose: () -> Void

    @State private var hovered: Bool

    init(
        app: WatchedApp,
        title: String,
        message: String,
        hovered: Bool = false,
        onTap: @escaping () -> Void,
        onOpen: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        self.app = app
        self.title = title
        self.message = message
        self.onTap = onTap
        self.onOpen = onOpen
        self.onClose = onClose
        _hovered = State(initialValue: hovered)
    }

    var body: some View {
        HStack(spacing: 10) {
            icon

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                if !message.isEmpty {
                    Text(message)
                        .font(.system(size: 13))
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // The "Aç" button covers the text's end, which fades out instead of making room: the
            // card never reflows.
            .mask(textMask)
        }
        .padding(.leading, 12)
        .padding(.trailing, 14)
        .padding(.vertical, 11)
        .frame(width: NotificationBannerOverlay.cardWidth)
        .frame(minHeight: 62)
        .contentShape(Self.shape)
        .onTapGesture(perform: onTap)
        .bannerGlass(in: Self.shape)
        .overlay(alignment: .trailing) {
            if hovered {
                Button("Aç", action: onOpen)
                    .buttonStyle(BannerCapsuleButtonStyle())
                    .padding(.trailing, 14)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .topLeading) {
            if hovered {
                closeButton
                    .offset(x: -8, y: -8)
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
            }
        }
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) { hovered = hovering }
        }
    }

    private var textMask: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: .black, location: 0),
                .init(color: .black, location: hovered ? 0.62 : 1),
                .init(color: hovered ? .clear : .black, location: hovered ? 0.8 : 1),
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    @ViewBuilder
    private var icon: some View {
        if let image = app.appIcon {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: 38, height: 38)
        } else {
            Image(systemName: app.fallbackIconName)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(Color(hex: app.defaultColorHex), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .frame(width: 38, height: 38)
        }
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .frame(width: 24, height: 24)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .bannerGlass(in: Circle())
        .help("Kapat")
    }
}

/// The light, translucent capsule of a system notification's action button.
private struct BannerCapsuleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(configuration.isPressed ? 0.22 : 0.12), in: Capsule())
            .contentShape(Capsule())
    }
}

private extension View {
    /// Liquid Glass on macOS 26 and later; the closest system material before that.
    @ViewBuilder
    func bannerGlass(in shape: some Shape) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(.regularMaterial, in: shape)
                .shadow(color: .black.opacity(0.2), radius: 10, y: 3)
        }
    }
}
