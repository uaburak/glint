import AppKit
import Observation
import SwiftUI

/// Notification banners in the style of macOS's own: glass cards, one stack per app. A new
/// notification's banner pops up at its app's position for a few seconds; hovering keeps it there
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
    /// Distance from the cards to the screen's edge (below the menu bar, above the Dock); macOS 27's
    /// own banners sit 16 pt from the right edge and 16 pt below the menu bar.
    static let screenInset: CGFloat = 16
    /// Space between the notch and the first card below it. The panel starts right at the notch's
    /// bottom edge, so scrolled cards never ride up beside the island; the gap is room for the close
    /// button overhanging the card's corner.
    static let notchGap: CGFloat = 8
    /// Notifications nobody opened wait in the notch; they go once read, or after this long.
    private static let waitingLifetime: TimeInterval = 30 * 60
    /// “Until they're read”: long enough never to run out in practice.
    private static let untilRead: TimeInterval = 7 * 24 * 60 * 60
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
    /// A window per position banners pop up at, made when the first one does. Apps can each have
    /// their own position. The one under the notch also shows the waiting list.
    private var panels: [BannerPosition: BannerPanel] = [:]
    private var bannersEnabled = true
    /// How long a new notification's banner stays up; nil = until it's closed or read.
    private var popDuration: TimeInterval? = 6
    /// Whether notifications also go into the notch (and the island sits on it), or only pop up.
    private var notchEnabled = true
    private var notchAvailable = false
    private var timer: Timer?
    private var notchHovered = false
    private var closeNotchListWork: DispatchWorkItem?

    /// Opens Glint's settings, from the island's settings button.
    var onOpenSettings: (() -> Void)?

    private init() {
        // Banners on screen while a display is plugged in or unplugged: macOS moves their windows,
        // so they're fitted to their corner (or to the notch) again. The island looks after itself.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scheduleFrameUpdates()
            }
        }
    }

    private var handlers: BannerPanel.Handlers {
        BannerPanel.Handlers(
            tap: { [weak self] stack in self?.cardTapped(stack) },
            openChat: { [weak self] stack, chatID in self?.openChat(stack, chatID: chatID) },
            closeStack: { [weak self] id in self?.remove(stackID: id) },
            closeChat: { [weak self] stackID, chatID in self?.removeChat(stackID: stackID, chatID: chatID) },
            closeItem: { [weak self] stackID, itemID in self?.removeItem(stackID: stackID, itemID: itemID) },
            expandChat: { [weak self] stackID, chatID in self?.expandChat(stackID: stackID, chatID: chatID) },
            collapseChat: { [weak self] stackID, chatID in self?.collapseChat(stackID: stackID, chatID: chatID) },
            collapse: { [weak self] id in self?.collapse(stackID: id) },
            hover: { [weak self] hovering in self?.hoverChanged(hovering) }
        )
    }

    /// Where a banner pops up. On a Mac with a notch the top centre is the notch: the card grows out
    /// of it, in the same window as the waiting list.
    private static func popPosition(_ position: BannerPosition) -> BannerPosition {
        switch position {
        case .topCenter, .notch: Notch.current != nil ? .notch : .topCenter
        default: position
        }
    }

    /// When a banner popping up now goes down: never, for banners that stay until they're closed.
    private func popEnd(from now: Date) -> Date {
        popDuration.map(now.addingTimeInterval) ?? .distantFuture
    }

    /// How long notifications nobody opened wait in the notch, from the notch's settings.
    private var notchWaitingLifetime: TimeInterval {
        notch.settings.waitingLifetime ?? Self.untilRead
    }

    private func panel(at position: BannerPosition) -> BannerPanel {
        if let panel = panels[position] { return panel }
        let panel = BannerPanel(model: model, handlers: handlers)
        panel.configure(position: position, shelf: position == .notch ? .poppingAndList : .popping)
        panels[position] = panel
        return panel
    }

    private func scheduleFrameUpdates(after delay: TimeInterval = 0) {
        for panel in panels.values {
            panel.scheduleFrameUpdate(after: delay)
        }
    }

    /// Shows a notification: on top of its app's stack if that app's banner is up, as a new stack
    /// otherwise. Returns the banner's id, so what it says can be filled in later.
    ///
    /// With `popping` off it's the first half of a notification whose message macOS hasn't written
    /// yet: nothing pops up, it goes into the notch and the island grows for a moment to announce it.
    /// `fillIn` then brings the banner out with the message. With `waits` off it goes with its banner,
    /// notch or not.
    @discardableResult
    func show(app: WatchedApp, title: String, body: String, position: BannerPosition, date: Date = Date(), thread: NotificationThread? = nil, popping: Bool = true, waits: Bool = true) -> UUID {
        let now = Date()
        focusNotchOnPointer()
        let item = BannerStackModel.Item(title: title, body: body, date: date, thread: thread)
        // With a notch, notifications nobody opened wait in it; without one they go with their banner.
        let popsUntil = popping ? popEnd(from: now) : nil
        let lifetime = waits && Notch.current != nil ? notchWaitingLifetime : (popDuration ?? Self.waitingLifetime)
        withAnimation(Self.arrival) {
            if !notchHovered {
                model.showsAll = false
            }
            model.push(
                item,
                from: app,
                at: Self.popPosition(position),
                expiresAt: max(now.addingTimeInterval(lifetime), popsUntil ?? now),
                popsUntil: popsUntil
            )
        }
        startTimer()
        syncNotch()
        if !popping, notch.settings.growsOnArrival {
            // Nothing pops up, so the island announces it by itself: long enough to be noticed, short
            // enough not to sit open while the message is still being written.
            notch.holdOpenBriefly(4)
        }
        presentPanels()
        // The app's banners may have moved to another position, leaving a window with nothing in it.
        afterChange()
        return item.id
    }

    /// Fills in a banner that went up from a badge, once the notification's own record turns up with
    /// the sender and the message. Nothing happens if the banner is gone by then.
    func fillIn(appID: String, itemID: UUID, title: String, body: String, thread: NotificationThread? = nil) {
        guard let stackIndex = model.stacks.firstIndex(where: { $0.id == appID }),
              let itemIndex = model.stacks[stackIndex].items.firstIndex(where: { $0.id == itemID })
        else { return }
        let existing = model.stacks[stackIndex].items[itemIndex]
        let now = Date()
        focusNotchOnPointer()
        withAnimation(.easeOut(duration: 0.2)) {
            model.stacks[stackIndex].items[itemIndex] = BannerStackModel.Item(
                id: existing.id, title: title, body: body, date: existing.date, thread: thread ?? existing.thread
            )
            // The message is what the user was waiting to see, and macOS can be slow to write it:
            // the banner gets its full time on screen again, even if the count-only one had gone.
            let popsUntil = popEnd(from: now)
            model.stacks[stackIndex].popsUntil = popsUntil
            let lifetime = Notch.current != nil ? notchWaitingLifetime : (popDuration ?? Self.waitingLifetime)
            model.stacks[stackIndex].expiresAt = max(model.stacks[stackIndex].expiresAt, now.addingTimeInterval(lifetime), popsUntil)
        }
        startTimer()
        syncNotch()
        presentPanels()
        scheduleFrameUpdates()
    }

    /// Removes an app's notifications, e.g. once they've been read in the app.
    func clear(appID: String) {
        guard model.stacks.contains(where: { $0.id == appID }) else { return }
        remove(stackID: appID)
    }

    /// Opens the newest notification's chat (or its app) and removes that chat; false when none is waiting.
    func openNewest() -> Bool {
        guard let stack = model.stacks.first else { return false }
        open(stack)
        return true
    }

    /// Follows the settings: whether banners are on, how long they stay up, and whether notifications
    /// go into the notch too. With a notch the island sits on it whenever that's on, even before any
    /// notification. Where a banner pops up comes with each one, from its app's settings.
    func configure(enabled: Bool, notch notchEnabled: Bool = true, popDuration: TimeInterval? = 6, notchSettings: NotchSettings = NotchSettings()) {
        self.popDuration = popDuration
        notch.settings = notchSettings
        let hasNotch = Notch.current != nil
        guard enabled != bannersEnabled || notchEnabled != self.notchEnabled || hasNotch != notchAvailable else { return }
        self.notchEnabled = notchEnabled
        if !enabled, bannersEnabled {
            dismiss(animated: false)
        }
        bannersEnabled = enabled
        notchAvailable = hasNotch
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

    /// Brings up the windows with something to show: each position with a banner up, and the notch's
    /// for its waiting list.
    private func presentPanels() {
        var positions = Set(model.stacks.map(\.position))
        if Notch.current != nil {
            positions.insert(.notch)
        }
        for position in positions {
            panel(at: position).present()
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
                    for panel in self.panels.values {
                        panel.hideIfEmpty()
                    }
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
        for panel in panels.values {
            panel.hide()
        }
        syncNotch()
    }

    // MARK: - Stacks

    /// The first click on a stack of several notifications spreads it out: its chats, or straight to
    /// the notifications when they're all from one chat. A click on a single notification opens its chat.
    private func cardTapped(_ stack: BannerStackModel.Stack) {
        if stack.items.count > 1 && !stack.expanded {
            guard let index = model.stacks.firstIndex(where: { $0.id == stack.id }) else { return }
            let chats = stack.chats
            withAnimation(Stacking.drop) {
                model.stacks[index].expanded = true
                if chats.count == 1, let only = chats.first {
                    model.stacks[index].expandedChats = [only.id]
                }
            }
            scheduleFrameUpdates()
        } else {
            open(stack)
        }
    }

    /// The stack's newest chat: a click on a single notification, or the "open the latest" shortcut.
    private func open(_ stack: BannerStackModel.Stack) {
        guard let chat = stack.chats.first else { return }
        openChat(stack, chatID: chat.id)
    }

    /// Opens the chat itself where the app has an address for it (a WhatsApp or Teams conversation),
    /// the app otherwise, and takes that chat's notifications away: the rest of the stack stays.
    private func openChat(_ stack: BannerStackModel.Stack, chatID: String) {
        let url = stack.chats.first { $0.id == chatID }?.thread?.url
        if url.map(NSWorkspace.shared.open) != true {
            stack.app.openApplication()
        }
        removeChat(stackID: stack.id, chatID: chatID)
    }

    private func remove(stackID: String) {
        withAnimation(.easeOut(duration: 0.25)) {
            model.stacks.removeAll { $0.id == stackID }
        }
        syncNotch()
        afterChange()
    }

    private func expandChat(stackID: String, chatID: String) {
        guard let index = model.stacks.firstIndex(where: { $0.id == stackID }) else { return }
        withAnimation(Stacking.drop) {
            _ = model.stacks[index].expandedChats.insert(chatID)
        }
        scheduleFrameUpdates()
    }

    private func collapseChat(stackID: String, chatID: String) {
        guard let index = model.stacks.firstIndex(where: { $0.id == stackID }) else { return }
        let chats = model.stacks[index].chats
        // A stack of one chat folds as a whole: its chat was spread out along with it.
        if chats.count == 1 {
            collapse(stackID: stackID)
            return
        }
        let cards = chats.first { $0.id == chatID }?.items.count ?? 1
        withAnimation(Stacking.drop) {
            _ = model.stacks[index].expandedChats.remove(chatID)
        }
        scheduleFrameUpdates(after: Stacking.foldDuration(cards: cards))
    }

    private func removeItem(stackID: String, itemID: UUID) {
        guard let stackIndex = model.stacks.firstIndex(where: { $0.id == stackID }) else { return }
        withAnimation(.easeOut(duration: 0.25)) {
            model.stacks[stackIndex].items.removeAll { $0.id == itemID }
            if model.stacks[stackIndex].items.isEmpty {
                model.stacks.remove(at: stackIndex)
            } else if model.stacks[stackIndex].items.count <= 1 {
                model.stacks[stackIndex].expanded = false
                model.stacks[stackIndex].expandedChats = []
            }
        }
        // No frame update yet: the cards below slide up into the gap. `afterChange` fits the panel.
        syncNotch()
        afterChange()
    }

    private func removeChat(stackID: String, chatID: String) {
        guard let stackIndex = model.stacks.firstIndex(where: { $0.id == stackID }) else { return }
        withAnimation(.easeOut(duration: 0.25)) {
            model.stacks[stackIndex].items.removeAll { $0.chatKey == chatID }
            model.stacks[stackIndex].expandedChats.remove(chatID)
            if model.stacks[stackIndex].items.isEmpty {
                model.stacks.remove(at: stackIndex)
            } else if model.stacks[stackIndex].items.count <= 1 {
                model.stacks[stackIndex].expanded = false
                model.stacks[stackIndex].expandedChats = []
            }
        }
        // No frame update yet: the cards below slide up into the gap, and a panel shrunk now would cut
        // off the last one on its way. `afterChange` fits it once they've moved.
        syncNotch()
        afterChange()
    }

    private func collapse(stackID: String) {
        guard let index = model.stacks.firstIndex(where: { $0.id == stackID }) else { return }
        withAnimation(Stacking.drop) {
            model.stacks[index].expanded = false
            model.stacks[index].expandedChats = []
        }
        // The panel shrinks once the cards have folded back; any sooner would cut them off on their way.
        scheduleFrameUpdates(after: Stacking.foldDuration(cards: max(model.stacks[index].chats.count, model.stacks[index].items.count)))
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
    /// banner is up or the waiting list is open. `releasingNow` is for the list closing because the
    /// pointer left: the island shrinks with it rather than a beat later.
    private func syncNotch(releasingNow: Bool = false) {
        guard Notch.current != nil, bannersEnabled, notchEnabled else {
            notch.holdsOpen = false
            notch.refresh(showing: false)
            return
        }
        notch.refresh(showing: true)
        // Open while the list is, and while a banner is up unless the island is to stay still for them.
        let arriving = notch.settings.growsOnArrival && model.stacks.contains { $0.popsUntil != nil }
        let holds = !model.stacks.isEmpty && (model.showsAll || arriving)
        if releasingNow, !holds {
            notch.releaseNow()
        } else {
            notch.holdsOpen = holds
        }
    }

    /// With an island on every display, a banner comes out of the one on the display the user is
    /// working on. Not while the pointer is in the list or on a card: they stay where they are.
    private func focusNotchOnPointer() {
        guard !notchHovered, !model.hovered else { return }
        Notch.focusOnPointer()
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
                        self.model.stacks[index].expandedChats = []
                    }
                }
                self.syncNotch(releasingNow: true)
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
        if model.hovered, !panels.values.contains(where: { $0.contains(pointer) }) {
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
                        model.stacks[index].expandedChats = []
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
        let openChat: (BannerStackModel.Stack, String) -> Void
        let closeStack: (String) -> Void
        let closeChat: (String, String) -> Void
        let closeItem: (String, UUID) -> Void
        let expandChat: (String, String) -> Void
        let collapseChat: (String, String) -> Void
        let collapse: (String) -> Void
        let hover: (Bool) -> Void
    }

    private let model: BannerStackModel
    private let handlers: Handlers
    private var panel: NSPanel?
    private var hosting: NSHostingView<BannerStackView>?
    private var position: BannerPosition = .topRight
    private var shelf: BannerStackModel.Shelf = .popping
    /// The banners' full height as SwiftUI lays them out. The panel is at most as tall as the screen
    /// allows; beyond that the banners scroll inside it.
    private var contentHeight: CGFloat = 0

    init(model: BannerStackModel, handlers: Handlers) {
        self.model = model
        self.handlers = handlers
    }

    private var shown: [BannerStackModel.Stack] {
        model.shown(on: shelf, at: position)
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
        contentHeight = 0
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
                onOpenChat: handlers.openChat,
                onCloseStack: handlers.closeStack,
                onCloseChat: handlers.closeChat,
                onCloseItem: handlers.closeItem,
                onExpandChat: handlers.expandChat,
                onCollapseChat: handlers.collapseChat,
                onCollapse: handlers.collapse,
                onHover: handlers.hover,
                onContentHeight: { [weak self] height in self?.contentHeightChanged(height) }
            ))
            // `updateFrame` sizes the panel; SwiftUI's own idea of its size (a scroller's width, say)
            // would otherwise resize the window.
            hosting.sizingOptions = []
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
    func scheduleFrameUpdate(after delay: TimeInterval = 0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                self?.updateFrame()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    self?.updateFrame()
                }
            }
        }
    }

    /// Taller banners get their room right away, or a new one would be cut off. Shorter ones wait for
    /// `scheduleFrameUpdate` or `hideIfEmpty`, so banners that are leaving can finish animating.
    private func contentHeightChanged(_ height: CGFloat) {
        let grew = height > contentHeight
        contentHeight = height
        guard grew else { return }
        // Not in the middle of SwiftUI's layout pass that reported it.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.updateFrame() }
        }
    }

    /// Fits the panel to its banners, pinned to its corner or edge, or just below the notch. It never
    /// reaches past the menu bar or the Dock; taller banners scroll.
    private func updateFrame() {
        guard let panel, hosting != nil, !shown.isEmpty, contentHeight > 0 else { return }
        typealias Overlay = NotificationBannerOverlay
        let width = Overlay.cardWidth + 2 * Overlay.margin
        // The margins are transparent, so they may reach past the insets.
        let inset = Overlay.screenInset - Overlay.margin

        if position == .notch, let notch = Notch.current {
            // The panel starts at the notch's bottom edge; its content starts `notchGap` below that.
            let top = notch.frame.minY
            let height = min(contentHeight, top - (notch.screen.visibleFrame.minY + inset))
            panel.setFrame(NSRect(x: notch.frame.midX - width / 2, y: top - height, width: width, height: height), display: true)
            return
        }

        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let height = min(contentHeight, visible.height - 2 * inset)
        let x: CGFloat = switch position {
        case .topLeft, .bottomLeft: visible.minX + inset
        case .topCenter, .bottomCenter, .notch: visible.midX - width / 2
        case .topRight, .bottomRight: visible.maxX - width - inset
        }
        let y: CGFloat = position.isTop ? visible.maxY - height - inset : visible.minY + inset
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
    }

    private static func makePanel() -> NSPanel {
        let panel = BannerPanelWindow(
            contentRect: NSRect(x: 0, y: 0, width: NotificationBannerOverlay.cardWidth + 2 * NotificationBannerOverlay.margin, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // Liquid Glass draws the cards' edges and depth itself; a window shadow would outline the
        // transparent margin instead.
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        return panel
    }
}

/// A panel that always reports itself key and main. Glint never activates, and Liquid Glass in a
/// window macOS thinks is inactive draws flat and dark, without its rim.
final class BannerPanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
    override func resignKey() {}
    override func resignMain() {}
}

// MARK: - Model

/// The notifications: one stack per app, newest stack first, newest notification first.
@MainActor
@Observable
final class BannerStackModel {
    /// Which notifications a panel shows.
    enum Shelf: Equatable {
        /// Banners that are up at the panel's position.
        case popping
        /// Banners that are up under the notch, and every waiting notification while it's hovered.
        case poppingAndList
    }

    struct Item: Identifiable, Equatable {
        let id: UUID
        let title: String
        let body: String
        let date: Date
        /// The conversation it came in, where the app's own store said.
        let thread: NotificationThread?

        init(id: UUID = UUID(), title: String, body: String, date: Date = Date(), thread: NotificationThread? = nil) {
            self.id = id
            self.title = title
            self.body = body
            self.date = date
            self.thread = thread
        }

        /// Which chat of its app's stack it goes in: its conversation, or whoever it's from (the
        /// notification's title) when the app didn't say.
        var chatKey: String { thread?.id ?? "title:\(title)" }
    }

    /// One conversation's notifications within an app's stack, newest first.
    struct Chat: Identifiable {
        let id: String
        var items: [Item]

        var newest: Item { items[0] }
        var thread: NotificationThread? { items.lazy.compactMap(\.thread).first }
    }

    struct Stack: Identifiable {
        let app: WatchedApp
        /// Where its banner pops up: its app's position when the newest notification came.
        var position: BannerPosition
        var items: [Item]
        var expanded = false
        var expiresAt: Date
        /// Until when the stack's banner is up after a new notification.
        var popsUntil: Date?
        /// The chats spread out within the spread-out stack.
        var expandedChats: Set<String> = []
        /// Notifications that came in for the stack; the notch island's badge.
        var received = 1

        var id: String { app.id }

        /// The stack's notifications by chat, the chat with the newest notification first.
        var chats: [Chat] {
            var chats: [Chat] = []
            var indices: [String: Int] = [:]
            for item in items {
                if let index = indices[item.chatKey] {
                    chats[index].items.append(item)
                } else {
                    indices[item.chatKey] = chats.count
                    chats.append(Chat(id: item.chatKey, items: [item]))
                }
            }
            return chats
        }
    }

    var stacks: [Stack] = []
    var hovered = false
    /// Whether the notch's waiting list is open.
    var showsAll = false

    func shown(on shelf: Shelf, at position: BannerPosition) -> [Stack] {
        switch shelf {
        case .popping: stacks.filter { $0.popsUntil != nil && $0.position == position }
        case .poppingAndList: showsAll ? stacks : stacks.filter { $0.popsUntil != nil && $0.position == position }
        }
    }

    func push(_ item: Item, from app: WatchedApp, at position: BannerPosition, expiresAt: Date, popsUntil: Date?, maxStacks: Int = 4) {
        if let index = stacks.firstIndex(where: { $0.id == app.id }) {
            var stack = stacks.remove(at: index)
            stack.received += 1
            stack.position = position
            // The newest on top and the rest slide down; a stack isn't capped, the panel scrolls.
            stack.items.insert(item, at: 0)
            stack.expiresAt = expiresAt
            stack.popsUntil = popsUntil
            stacks.insert(stack, at: 0)
        } else {
            stacks.insert(Stack(app: app, position: position, items: [item], expiresAt: expiresAt, popsUntil: popsUntil), at: 0)
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
    let onOpenChat: (BannerStackModel.Stack, String) -> Void
    let onCloseStack: (String) -> Void
    let onCloseChat: (String, String) -> Void
    let onCloseItem: (String, UUID) -> Void
    let onExpandChat: (String, String) -> Void
    let onCollapseChat: (String, String) -> Void
    let onCollapse: (String) -> Void
    let onHover: (Bool) -> Void
    /// The banners' full height, which the panel fits as far as the screen allows.
    let onContentHeight: (CGFloat) -> Void

    /// The banners' height as laid out, which the backdrop follows.
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        // The newest stack sits nearest the screen edge (or the notch).
        let shown = model.shown(on: shelf, at: position)
        let stacks = position.isTop ? shown : Array(shown.reversed())
        let edge: UnitPoint = position.isTop ? .top : .bottom
        // Banners that don't fit on the screen scroll; the margins are inside, so the close buttons
        // overhanging the cards aren't cut off. No GlassEffectContainer: inside one, overlapping glass
        // melts into a single shape, and the cards peeking out behind a stack's top card have to stay
        // cards of their own.
        ScrollView(.vertical) {
            VStack(spacing: 10) {
                ForEach(stacks) { stack in
                    BannerStackCards(
                        stack: stack,
                        underNotch: position == .notch,
                        actions: StackActions(
                            tapStack: { onTap(stack) },
                            openChat: { chatID in onOpenChat(stack, chatID) },
                            expandChat: { chatID in onExpandChat(stack.id, chatID) },
                            collapseChat: { chatID in onCollapseChat(stack.id, chatID) },
                            closeStack: { onCloseStack(stack.id) },
                            closeChat: { chatID in onCloseChat(stack.id, chatID) },
                            closeItem: { itemID in onCloseItem(stack.id, itemID) },
                            collapse: { onCollapse(stack.id) }
                        )
                    )
                    .transition(stackTransition)
                }
            }
            .padding(.horizontal, NotificationBannerOverlay.margin)
            .padding(.bottom, NotificationBannerOverlay.margin)
            .padding(.top, position == .notch ? NotificationBannerOverlay.notchGap : NotificationBannerOverlay.margin)
            .frame(width: NotificationBannerOverlay.cardWidth + 2 * NotificationBannerOverlay.margin)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                contentHeight = height
                onContentHeight(height)
            }
        }
        // Behind the cards, whenever there are any, the blurred backdrop Notification Center puts behind
        // its own. It stays put while the cards scroll, and it keeps the pointer on the panel between them.
        .background(alignment: position.isTop ? .top : .bottom) {
            if !stacks.isEmpty {
                // As tall as the cards, and moving with them: the window only follows once they've
                // settled (it waits for a stack to fold, for one).
                BannerBackdrop()
                    .frame(height: contentHeight)
                    .animation(Stacking.drop, value: contentHeight)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.4), value: stacks.isEmpty)
        // The panel never becomes key, and glass drawn in a window macOS thinks is inactive comes out
        // flat and dark; this is the same trick the notch's blur uses.
        .environment(\.controlActiveState, .key)
        // With “always show” scroll bars a scroller would sit in the transparent panel and take room
        // from the cards; scrolling still works without it.
        .scrollIndicators(.never)
        .scrollBounceBehavior(.basedOnSize)
        // Against the screen edge (or the notch): while the panel waits to shrink, when it opens, and
        // as banners come and go, so the newest stays in sight.
        .defaultScrollAnchor(edge, for: .alignment)
        .defaultScrollAnchor(edge, for: .initialOffset)
        .defaultScrollAnchor(edge, for: .sizeChanges)
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

/// How a stack folds and spreads out, the same at both levels: an app's stack of chats, and a chat's
/// stack of notifications.
enum Stacking {
    /// How many cards a folded stack shows: the top one and two peeking out behind it.
    static let shownFolded = 3
    /// How far each card behind the top one shows past it.
    static let peek: CGFloat = 7
    /// Each card drops this long after the one before it.
    static let stagger: TimeInterval = 0.035
    /// Folding back is quicker: the stack is going away, not coming.
    static let foldStagger: TimeInterval = 0.025
    /// How long the cards past the folded three take to fade out as the stack folds.
    static let extrasFade: TimeInterval = 0.15
    static let drop = Animation.spring(response: 0.34, dampingFraction: 0.8)
    static let space = "bannerStack"

    /// How long folding a stack of this many cards back takes, the last card's delay included.
    static func foldDuration(cards: Int) -> TimeInterval {
        0.42 + Double(max(min(cards, shownFolded) - 1, 0)) * foldStagger
    }
}

/// What the cards of an app's stack can ask for.
struct StackActions {
    /// A click on the folded stack: it spreads out, or opens its one notification.
    let tapStack: () -> Void
    let openChat: (String) -> Void
    let expandChat: (String) -> Void
    let collapseChat: (String) -> Void
    let closeStack: () -> Void
    let closeChat: (String) -> Void
    let closeItem: (UUID) -> Void
    let collapse: () -> Void
}

/// One app's notifications, as a stack of chats (a conversation, or a sender where the app didn't name
/// the conversation), each of them a stack of its notifications. The first click on a stack spreads it
/// out, at either level; a click on a single notification, or on one once its chat is spread out,
/// opens the chat.
///
/// Folded, the newest chat is on top with the next chats peeking out behind it; a stack of one chat
/// shows that chat's own notifications peeking out instead, and spreading it out goes straight to them.
private struct BannerStackCards: View {
    let stack: BannerStackModel.Stack
    let underNotch: Bool
    let actions: StackActions
    @AppStorage(Pref.notifyPreview) private var previewName = MessagePreview.full.rawValue

    private var preview: MessagePreview { MessagePreview(rawValue: previewName) ?? .full }

    var body: some View {
        let chats = stack.chats
        CardStack(ids: chats.map(\.id), expanded: stack.expanded, underNotch: underNotch) {
            StackHeader(title: stack.app.name, prominent: true, onCollapse: actions.collapse, onClose: actions.closeStack)
        } card: { index, behind in
            chatStack(chats[index], behind: behind, only: chats.count == 1)
        }
    }

    private func chatStack(_ chat: BannerStackModel.Chat, behind: Bool, only: Bool) -> some View {
        let appExpanded = stack.expanded
        let chatExpanded = appExpanded && stack.expandedChats.contains(chat.id)
        // Its own notifications peek out behind it, except while it waits behind another chat or, folded,
        // other chats are what peeks out.
        let items = behind || (!appExpanded && !only) ? Array(chat.items.prefix(1)) : chat.items
        return CardStack(
            ids: items.map(\.id.uuidString),
            expanded: chatExpanded,
            underNotch: underNotch,
            // The app's own header does for a stack of one chat.
            hasHeader: !only
        ) {
            StackHeader(title: preview.title(chat.newest.title, app: stack.app), prominent: false, onCollapse: { actions.collapseChat(chat.id) }, onClose: { actions.closeChat(chat.id) })
        } card: { index, innerBehind in
            let item = items[index]
            BannerCardView(
                app: stack.app,
                title: preview.title(item.title, app: stack.app),
                message: preview.message(item.body),
                date: item.date,
                isExpandedMode: appExpanded,
                reservesTime: stack.items.count > 1,
                showsContent: !behind && !innerBehind,
                lineLimits: preview.lineLimits,
                onTap: { tapped(chat, chatExpanded: chatExpanded) },
                onOpen: { actions.openChat(chat.id) },
                onClose: { closed(chat, item: item, chatExpanded: chatExpanded) }
            )
        }
    }

    /// Folded, the stack spreads out; a chat of several notifications spreads out next; a notification
    /// on its own, or in a chat already spread out, opens the chat.
    private func tapped(_ chat: BannerStackModel.Chat, chatExpanded: Bool) {
        if !stack.expanded {
            actions.tapStack()
        } else if chatExpanded || chat.items.count == 1 {
            actions.openChat(chat.id)
        } else {
            actions.expandChat(chat.id)
        }
    }

    /// The close button takes away what the card stands for: the folded stack, a folded chat, or one
    /// notification of a chat spread out.
    private func closed(_ chat: BannerStackModel.Chat, item: BannerStackModel.Item, chatExpanded: Bool) {
        if !stack.expanded {
            actions.closeStack()
        } else if chatExpanded {
            actions.closeItem(item.id)
        } else {
            actions.closeChat(chat.id)
        }
    }
}

/// A stack of cards, folded or spread out. Folded, the first card is on top with the next two peeking
/// out behind it (above it under the notch, below it elsewhere); spread out, a header and every card
/// under it.
///
/// Folded and spread out are the same views, so nothing disappears in between. Spreading out, the top
/// card moves down to make room for the header, which comes out from under it, and the cards behind
/// it drop into place one after another. Folding back, the cards past the three a folded stack shows
/// fade out where they are while those three slide back into the stack, the third one first.
private struct CardStack<Header: View, Card: View>: View {
    let ids: [String]
    let expanded: Bool
    let underNotch: Bool
    var hasHeader = true
    @ViewBuilder let header: () -> Header
    /// The card at an index; `behind` is whether it's waiting behind the top one, folded.
    @ViewBuilder let card: (_ index: Int, _ behind: Bool) -> Card

    /// The top card's height, for placing cards that come in from the stack.
    @State private var topHeight: CGFloat = 0

    var body: some View {
        let layers = min(ids.count, Stacking.shownFolded) - 1
        VStack(alignment: .leading, spacing: 0) {
            if hasHeader {
                header()
                    .padding(.bottom, 8)
                    // Folded, it has no height and sits behind the top card, which uncovers it on its way down.
                    .frame(height: expanded ? nil : 0, alignment: .top)
                    .opacity(expanded ? 1 : 0)
                    .allowsHitTesting(expanded)
                    .zIndex(-Double(ids.count + 1))
                    .animation(Stacking.drop, value: expanded)
            }

            ForEach(Array(ids.enumerated()), id: \.element) { index, _ in
                // Past the folded three, a card is only there while the stack is spread out.
                if expanded || index < Stacking.shownFolded {
                    entry(index, expanded: expanded, layers: layers)
                }
            }
        }
        .frame(width: NotificationBannerOverlay.cardWidth)
        .padding(underNotch ? .top : .bottom, expanded ? 0 : CGFloat(max(layers, 0)) * Stacking.peek)
        .coordinateSpace(.named(Stacking.space))
    }

    private func entry(_ index: Int, expanded: Bool, layers: Int) -> some View {
        let behind = index > 0 && !expanded
        return card(index, behind)
            // Always its own height, whatever room it's given: folded, a card behind the top one takes
            // none, and its text would squeeze into fewer lines and slide back out.
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                if index == 0 { topHeight = height }
            }
            .modifier(layer(depth: behind ? min(index, Stacking.shownFolded - 1) : 0, hidden: false, layers: layers))
            .padding(.top, index > 0 && expanded ? 8 : 0)
            // Folded, the cards behind the top one take no room; they're drawn where the stack is.
            .frame(height: behind ? 0 : nil, alignment: .top)
            .allowsHitTesting(!behind)
            // Each card comes out from behind the one before it.
            .zIndex(Double(-index))
            .animation(Stacking.drop.delay(delay(index, expanded: expanded)), value: expanded)
            .transition(transition(index: index, expanded: expanded, layers: layers))
    }

    private func layer(depth: Int, hidden: Bool, layers: Int) -> StackLayer {
        StackLayer(depth: depth, hidden: hidden, underNotch: underNotch, layers: layers, topHeight: topHeight, peek: Stacking.peek, space: Stacking.space)
    }

    /// The first card first when spreading out; folding back, the third of the folded three first.
    /// The cards past those three fade out at once.
    private func delay(_ index: Int, expanded: Bool) -> TimeInterval {
        if expanded { return Double(index) * Stacking.stagger }
        let folding = min(ids.count, Stacking.shownFolded)
        return Double(max(folding - 1 - index, 0)) * Stacking.foldStagger
    }

    /// Cards past the folded three come out of the stack when it spreads (like the rest, a moment after
    /// the one before) and fade out where they are when it folds. Otherwise a new notification lands on
    /// a folded stack the way a new stack arrives.
    private func transition(index: Int, expanded: Bool, layers: Int) -> AnyTransition {
        if index >= Stacking.shownFolded {
            let fromStack = AnyTransition.modifier(
                active: layer(depth: Stacking.shownFolded - 1, hidden: true, layers: layers),
                identity: layer(depth: 0, hidden: false, layers: layers)
            )
            return .asymmetric(
                insertion: fromStack.animation(Stacking.drop.delay(Double(index) * Stacking.stagger)),
                removal: .opacity.animation(.easeOut(duration: Stacking.extrasFade))
            )
        }
        if underNotch { return .fromNotch }
        return expanded ? .opacity : .asymmetric(insertion: .scale(scale: 0.9).combined(with: .opacity), removal: .opacity)
    }
}

/// A spread-out stack's header, as macOS draws an expanded notification stack: its name as plain text,
/// the buttons on glass. The app's is a little bigger than a chat's.
private struct StackHeader: View {
    let title: String
    let prominent: Bool
    let onCollapse: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .center) {
            Text(title)
                .font(.system(size: prominent ? 15 : 13, weight: prominent ? .bold : .semibold))
                .lineLimit(1)
                .padding(.horizontal, 4)

            Spacer()

            Button(action: onCollapse) {
                Text("Daha az göster")
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 11)
                    .padding(.vertical, 4)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .glassEffect(in: Capsule())

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 22, height: 22)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .glassEffect(in: Circle())
            .help("Tümünü Kapat")
        }
        .padding(.horizontal, 4)
    }
}

/// Where a stack's card is drawn. At depth 0 it's in its own place: the top card, or any card once
/// spread out. At depth 1 or 2 it waits behind the top card, a little narrower and peeking out past it
/// (below it, or above it under the notch), only that edge showing; deeper ones wait out of sight.
private struct StackLayer: ViewModifier {
    let depth: Int
    let hidden: Bool
    let underNotch: Bool
    /// How many cards peek out behind the top one.
    let layers: Int
    /// The top card's height.
    let topHeight: CGFloat
    let peek: CGFloat
    let space: String

    func body(content: Content) -> some View {
        let d = CGFloat(depth)
        content
            // Behind the top card only the part past it shows; the rest would darken the top card's
            // glass. In its own place nothing is cut, on any side: the close button overhangs the
            // card's top-left corner.
            .mask(alignment: depth == 0 ? .center : underNotch ? .top : .bottom) {
                Rectangle().frame(width: depth == 0 ? 2000 : nil, height: depth == 0 ? 2000 : 22 + peek * d)
            }
            .visualEffect { [depth, underNotch, layers, topHeight, peek, space] content, proxy in
                // Moved from wherever its own place is to behind the folded stack's top card: bottoms
                // lined up, or tops under the notch, where the layers peek out above.
                let top = proxy.frame(in: .named(space)).minY
                let d = CGFloat(depth)
                let target = underNotch
                    ? CGFloat(layers) * peek - peek * d
                    : topHeight + peek * d - proxy.size.height
                let lift: CGFloat = depth == 0 ? 0 : target - top
                return content
                    .offset(y: lift)
                    .scaleEffect(x: 1 - 0.05 * d, y: 1, anchor: underNotch ? .top : .bottom)
            }
            .opacity(hidden ? 0 : 1 - 0.2 * d)
    }
}

/// One notification, laid out the way macOS 27 lays out its own banners. The numbers were read off the
/// system's banners (their Accessibility frames and pixels at 2x): 344 pt wide, a continuous 20 pt
/// corner, a 39 pt icon 9.5 pt from the left edge and centred, text from 58 pt with 12 pt to spare on
/// the right, 12 pt above and 11.5 pt below it, never shorter than 58 pt. The title is 13 pt semibold
/// on up to two lines, the message 13 pt in the primary colour on up to four, 1 pt below it.
struct BannerCardView: View {
    static let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
    private static let iconSize: CGFloat = 39
    private static let iconInset: CGFloat = 9.5
    private static let textInset: CGFloat = iconInset + iconSize + iconInset
    private static let minHeight: CGFloat = iconSize + 2 * iconInset

    let app: WatchedApp
    let title: String
    let message: String
    let date: Date?
    let isExpandedMode: Bool
    /// Keeps the time's room in the title row even while it isn't shown, so spreading a stack out
    /// shows the time without moving the title.
    let reservesTime: Bool
    /// Off for a card waiting behind a stack's top card: its glass edge peeks out, its text doesn't.
    let showsContent: Bool
    /// Most lines of the title and of the message: fewer for the short content setting.
    let lineLimits: (title: Int, message: Int)
    let onTap: () -> Void
    let onOpen: () -> Void
    let onClose: () -> Void

    @State private var hovered: Bool

    init(
        app: WatchedApp,
        title: String,
        message: String,
        date: Date? = nil,
        isExpandedMode: Bool = false,
        reservesTime: Bool = false,
        showsContent: Bool = true,
        lineLimits: (title: Int, message: Int) = (2, 4),
        hovered: Bool = false,
        onTap: @escaping () -> Void,
        onOpen: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        self.app = app
        self.title = title
        self.message = message
        self.date = date
        self.isExpandedMode = isExpandedMode
        self.reservesTime = reservesTime
        self.showsContent = showsContent
        self.lineLimits = lineLimits
        self.onTap = onTap
        self.onOpen = onOpen
        self.onClose = onClose
        _hovered = State(initialValue: hovered)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineHeight(Self.lineHeight(for: title, weight: .semibold))
                    .lineLimit(lineLimits.title)

                if isExpandedMode || reservesTime, let timeString = relativeTimeString {
                    Spacer(minLength: 6)
                    Text(timeString)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(.secondary.opacity(0.85))
                        .lineLimit(1)
                        .opacity(isExpandedMode && !hovered ? 1 : 0)
                }
            }

            if !message.isEmpty {
                Text(message)
                    .font(.system(size: 13))
                    .lineHeight(Self.lineHeight(for: message, weight: .regular))
                    .lineLimit(lineLimits.message)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // The "Aç" button covers the text's end, which fades out instead of making room: the card
        // never reflows.
        .mask(textMask)
        .opacity(showsContent ? 1 : 0)
        .padding(.leading, Self.textInset)
        .padding(.trailing, 12)
        .padding(.top, 12)
        .padding(.bottom, 11.5)
        .frame(width: NotificationBannerOverlay.cardWidth, alignment: .leading)
        .frame(minHeight: Self.minHeight, alignment: .top)
        // The text starts at the top; the icon stays centred however many lines there are.
        .overlay(alignment: .leading) {
            icon.padding(.leading, Self.iconInset)
                .opacity(showsContent ? 1 : 0)
        }
        // Apple: the regular variant is the default and stays legible; clear needs a dimming layer.
        // Interactive, as for any custom control that reacts to the pointer.
        .glassEffect(.regular.interactive(), in: Self.shape)
        .contentShape(Self.shape)
        .onTapGesture(perform: onTap)
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

    /// macOS's banners give a text 18 pt lines instead of 16 when one of its glyphs reaches below the
    /// font's descent: a cedilla does (ç, ş), ü, é or ı don't. It applies to every line of that text,
    /// and to the title and the message separately. SwiftUI's own line heights don't do this.
    private static func lineHeight(for text: String, weight: NSFont.Weight) -> AttributedString.LineHeight? {
        let font = NSFont.systemFont(ofSize: 13, weight: weight)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        return -bounds.minY > -font.descender ? .exact(points: 18) : nil
    }

    private var relativeTimeString: String? {
        guard let date else { return nil }
        let seconds = -date.timeIntervalSinceNow
        if seconds < 60 {
            return "şimdi"
        } else if seconds < 3600 {
            let minutes = max(1, Int(seconds / 60))
            return "\(minutes) dk. önce"
        } else if seconds < 86400 {
            let hours = Int(seconds / 3600)
            return "\(hours) sa. önce"
        } else {
            let days = Int(seconds / 86400)
            return "\(days) gün önce"
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
                .frame(width: Self.iconSize, height: Self.iconSize)
        } else {
            // The size of an app icon's artwork inside its 39 pt frame.
            Image(systemName: app.fallbackIconName)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 31, height: 31)
                .background(Color(hex: app.defaultColorHex), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .frame(width: Self.iconSize, height: Self.iconSize)
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
        .glassEffect(in: Circle())
        .help("Kapat")
    }
}

/// What's behind the panel, blurred and nothing else, like iOS's scroll edge effect: no grey fill, no
/// tint, fading out towards the panel's edges. Between the cards a transparent panel lets the pointer
/// through to the window behind, which then scrolls instead of the cards; the backdrop is what the
/// pointer rests on there. Always active: a window macOS thinks is inactive would draw it flat.
private struct BannerBackdrop: View {
    /// How far in from each edge the blur takes to come in fully: past the margin and under the cards,
    /// so it never has an edge of its own.
    private static let fade: CGFloat = 40
    /// An ease-in-out ramp from clear to solid, so the blur starts and ends without a visible step.
    private static let ramp: [Gradient.Stop] = [
        (0, 0), (0.15, 0.04), (0.3, 0.15), (0.5, 0.5), (0.7, 0.85), (0.85, 0.96), (1, 1),
    ].map { Gradient.Stop(color: .black.opacity($0.1), location: $0.0) }

    var body: some View {
        BackdropMaterial()
            .mask {
                HStack(spacing: 0) {
                    LinearGradient(stops: Self.ramp, startPoint: .leading, endPoint: .trailing)
                        .frame(width: Self.fade)
                    Color.black
                    LinearGradient(stops: Self.ramp, startPoint: .trailing, endPoint: .leading)
                        .frame(width: Self.fade)
                }
            }
            .mask {
                VStack(spacing: 0) {
                    LinearGradient(stops: Self.ramp, startPoint: .top, endPoint: .bottom)
                        .frame(height: Self.fade)
                    Color.black
                    LinearGradient(stops: Self.ramp, startPoint: .bottom, endPoint: .top)
                        .frame(height: Self.fade)
                }
            }
            .allowsHitTesting(false)
    }

    private struct BackdropMaterial: NSViewRepresentable {
        func makeNSView(context: Context) -> NSVisualEffectView {
            // The blur the notch softens the menu bar with, lighter: what's behind stays recognisable.
            let view = PureBlurView()
            view.blurRadius = 3
            view.material = .menu
            view.blendingMode = .behindWindow
            view.state = .active
            return view
        }

        func updateNSView(_ view: NSVisualEffectView, context: Context) {}
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
