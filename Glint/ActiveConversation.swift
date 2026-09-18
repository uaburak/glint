import AppKit
import ApplicationServices

/// Whether the user is looking at the very conversation a notification is about: its app is in front,
/// they've been using it just now, and the name in the app's window title is the notification's.
///
/// Chat apps put the open conversation in their window title — Teams' is "Sohbet | Oguz Acar |
/// Microsoft Teams" — so the title says who the user is talking to. Reading it needs Accessibility
/// permission; without it, or without a name to compare, nothing is suppressed.
@MainActor
enum ActiveConversation {
    /// The user is in the conversation while they've touched the keyboard or mouse this recently.
    private static let activeWithin: TimeInterval = 30
    /// A window title is re-read at most this often: it's an Accessibility request to another app.
    private static let titleLifetime: TimeInterval = 1

    private static var cachedTitle: (pid: pid_t, title: String?, at: Date)?

    /// Whether the app is in front and the user is using it right now.
    static func isInUse(_ app: WatchedApp) -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication,
              let bundleID = front.bundleIdentifier,
              app.bundleIDs.contains(bundleID) else { return false }
        return Presence.idleSeconds() < activeWithin
    }

    /// Whether a notification is from the conversation open in front of the user. Without a title to
    /// compare (no Full Disk Access), being in the app is enough: the message is on screen anyway.
    static func isOnScreen(title: String?, subtitle: String?, of app: WatchedApp) -> Bool {
        guard isInUse(app) else { return false }
        let names = [title, subtitle].compactMap { $0 }.filter { !$0.isEmpty }
        guard !names.isEmpty else { return true }
        guard let windowTitle = frontWindowTitle(of: app) else { return false }
        return segments(of: windowTitle).contains { segment in
            names.contains { matches(segment, $0) }
        }
    }

    /// The parts of a window title: "Sohbet | Oguz Acar | Microsoft Teams" gives its three pieces.
    private static func segments(of title: String) -> [String] {
        title.split(whereSeparator: { "|—–·•:".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count >= 3 }
    }

    /// Either name containing the other, ignoring case and accents: a notification's title can say
    /// more than the window's ("Oguz Acar (Sohbet)").
    private static func matches(_ segment: String, _ name: String) -> Bool {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return segment.range(of: name, options: options) != nil || name.range(of: segment, options: options) != nil
    }

    private static func frontWindowTitle(of app: WatchedApp) -> String? {
        guard AXIsProcessTrusted(), let runningApp = app.runningApp else { return nil }
        let pid = runningApp.processIdentifier
        if let cached = cachedTitle, cached.pid == pid, Date().timeIntervalSince(cached.at) < Self.titleLifetime {
            return cached.title
        }
        let title = readFrontWindowTitle(pid: pid)
        cachedTitle = (pid, title, Date())
        return title
    }

    private static func readFrontWindowTitle(pid: pid_t) -> String? {
        let application = AXUIElementCreateApplication(pid)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &focused) == .success,
              let window = focused, CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &value) == .success,
              let title = value as? String, !title.isEmpty else { return nil }
        return title
    }
}
