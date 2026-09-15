import AppKit
import SwiftUI

/// The settings window: a resizable System Settings–style window with a sidebar (`SettingsView`).
@MainActor
final class SettingsWindowManager {
    static let shared = SettingsWindowManager()
    private static let frameName = "GlintSettings"
    private var window: NSWindow?

    func show(controller: AlarmController) {
        let win = window ?? makeWindow(controller: controller)
        window = win
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        win.orderFrontRegardless()
    }

    private func makeWindow(controller: AlarmController) -> NSWindow {
        let hosting = NSHostingController(rootView: SettingsView(controller: controller))
        // SwiftUI provides the toolbar (back/forward buttons) and the title (the current page's
        // name), like System Settings; the window keeps its own size.
        hosting.sceneBridgingOptions = [.toolbars, .title]
        hosting.sizingOptions = []

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.contentViewController = hosting
        win.title = "Glint Ayarları"
        win.toolbarStyle = .unified
        win.isReleasedWhenClosed = false
        win.contentMinSize = NSSize(width: 680, height: 460)
        win.setContentSize(NSSize(width: 760, height: 620))
        if !win.setFrameUsingName(Self.frameName) {
            win.center()
        }
        win.setFrameAutosaveName(Self.frameName)
        return win
    }
}
