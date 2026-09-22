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
        terminateOtherInstances()
        NSApp.mainMenu = makeMainMenu()
        Pref.migrateLegacySettings()
        Pref.migrateNotifyStyle()
        Pref.removeObsoleteSettings()

        let controller = AlarmController()
        self.controller = controller
        StatusMenuManager.shared.setup(controller: controller)
        GlobalShortcuts.shared.handler = { [weak controller] action in controller?.perform(action) }
        GlobalShortcuts.shared.reload()
        AppUpdater.shared.start()

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

    /// Puts the Mac's volume back if the alarm is ringing.
    func applicationWillTerminate(_ notification: Notification) {
        AlarmSoundPlayer.shared.stop()
    }

    /// With two copies running (say, a new build next to the installed app) every notification would
    /// show twice; the one launched last takes over.
    private func terminateOtherInstances() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        for other in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        where other.processIdentifier != getpid() {
            if !other.terminate() {
                other.forceTerminate()
            }
        }
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
