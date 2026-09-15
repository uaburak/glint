import AppKit

/// Menu bar app: the status item (`StatusMenuManager`) is the whole UI, plus a settings window.
@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: AlarmController?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()
        Pref.migrateLegacySettings()

        let controller = AlarmController()
        self.controller = controller
        StatusMenuManager.shared.setup(controller: controller)

        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: Pref.hasLaunched) {
            defaults.set(true, forKey: Pref.hasLaunched)
            SettingsWindowManager.shared.show(controller: controller)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let controller { SettingsWindowManager.shared.show(controller: controller) }
        return false
    }

    /// Menu bar apps never show their main menu, but its shortcuts (⌘W, ⌘Q, copy/paste)
    /// still work in their windows.
    private func makeMainMenu() -> NSMenu {
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Glint'ten Çık", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let editMenu = NSMenu(title: "Düzen")
        editMenu.addItem(withTitle: "Kes", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Kopyala", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Yapıştır", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Tümünü Seç", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let windowMenu = NSMenu(title: "Pencere")
        windowMenu.addItem(withTitle: "Kapat", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        let mainMenu = NSMenu()
        for submenu in [appMenu, editMenu, windowMenu] {
            let item = NSMenuItem()
            item.submenu = submenu
            mainMenu.addItem(item)
        }
        return mainMenu
    }
}
