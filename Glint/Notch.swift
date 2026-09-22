import AppKit

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

/// Reports the pointer resting on the notch, which opens the notifications waiting below it. Nothing
/// is drawn there: the only banner is the card.
///
/// The pointer is polled instead of tracked with a window, which would have to let the mouse through
/// everywhere but the notch. Polling only runs while notifications are waiting.
@MainActor
final class NotchHoverTracker {
    private static let interval: TimeInterval = 1.0 / 30
    /// Room around the housing that still counts as the notch, and a point at the top: the pointer
    /// can rest on the screen's very edge.
    private static let slack = NSSize(width: 6, height: 1)
    /// How many checks apart the notch's place is read again: a display change macOS didn't announce
    /// is caught within half a second.
    private static let notchCheckEvery = 15

    var onHoverChanged: ((Bool) -> Void)?
    /// Where the pointer is, in screen coordinates. Replaceable so the hover logic can be exercised.
    var pointerLocation: () -> NSPoint = { NSEvent.mouseLocation }

    private var timer: Timer?
    private var notch: Notch?
    private var checks = 0
    private var hovered = false

    init() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.notch = Notch.current }
        }
    }

    /// Watches the notch while something waits below it, and stops otherwise.
    func refresh(tracking: Bool) {
        if tracking {
            guard timer == nil else { return }
            notch = Notch.current
            let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.check() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
            check()
        } else {
            timer?.invalidate()
            timer = nil
            setHovered(false)
        }
    }

    private func check() {
        checks += 1
        if checks % Self.notchCheckEvery == 0 {
            notch = Notch.current
        }
        guard let notch else {
            setHovered(false)
            return
        }
        let area = notch.frame.insetBy(dx: -Self.slack.width, dy: -Self.slack.height)
        setHovered(NSMouseInRect(pointerLocation(), area, false))
    }

    private func setHovered(_ inside: Bool) {
        guard inside != hovered else { return }
        hovered = inside
        onHoverChanged?(inside)
    }
}
