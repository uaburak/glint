import AppKit
import SwiftUI

/// The settings window: a resizable System Settings–style window with a sidebar (`SettingsView`).
///
/// While it's open Glint is an ordinary app, in the Dock and the app switcher. A menu bar app isn't
/// among the apps macOS goes back to, so closing System Settings opened from here would bring up
/// some other app over this window instead of returning to it.
@MainActor
final class SettingsWindowManager: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowManager()
    private static let frameName = "GlintSettings"
    private var window: NSWindow?

    func show(controller: AlarmController) {
        let win = window ?? makeWindow(controller: controller)
        window = win
        showInDock(true)
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        win.orderFrontRegardless()
    }

    func windowWillClose(_ notification: Notification) {
        showInDock(false)
    }

    private func showInDock(_ shown: Bool) {
        if shown, NSApp.applicationIconImage != Self.dockIcon {
            NSApp.applicationIconImage = Self.dockIcon
        }
        NSApp.setActivationPolicy(shown ? .regular : .accessory)
    }

    /// Glint's mark on the standard icon grid, for the Dock and the app switcher: the bundle has no
    /// icon of its own yet.
    private static let dockIcon: NSImage? = {
        let renderer = ImageRenderer(content: GlintIcon(size: 824).frame(width: 1024, height: 1024))
        renderer.scale = 1
        return renderer.nsImage
    }()

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
        win.delegate = self
        win.contentMinSize = NSSize(width: 680, height: 460)
        win.setContentSize(NSSize(width: 760, height: 620))
        if !win.setFrameUsingName(Self.frameName) {
            win.center()
        }
        win.setFrameAutosaveName(Self.frameName)
        return win
    }
}
