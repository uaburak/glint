import AppKit

/// The menu bar item and its dropdown menu.
@MainActor
final class StatusMenuManager: NSObject, NSMenuDelegate {
    static let shared = StatusMenuManager()

    private var controller: AlarmController?
    private var statusItem: NSStatusItem?
    private let menu = NSMenu()
    private var shownSymbol: String?
    /// App rows of the open menu, so their unread counts update while it's open.
    private var appItems: [String: NSMenuItem] = [:]

    override init() {
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
    }

    func setup(controller: AlarmController) {
        self.controller = controller

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "Glint"
        item.button?.imagePosition = .imageLeading
        item.menu = menu
        statusItem = item

        controller.onUpdate = { [weak self] in self?.controllerDidUpdate() }
        // Picks up "show unread count" being switched in settings right away.
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.controllerDidUpdate() }
        }
        controllerDidUpdate()
        rebuildMenu()
    }

    private func controllerDidUpdate() {
        guard let controller, let button = statusItem?.button else { return }
        let symbol = controller.menuBarSymbol
        if symbol != shownSymbol {
            shownSymbol = symbol
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Glint")
        }
        let showCount = UserDefaults.standard.bool(forKey: Pref.showMenuBarCount)
        let countText = showCount && controller.unread > 0 ? " \(controller.unread)" : ""
        if button.title != countText { button.title = countText }

        for (id, item) in appItems {
            if let app = WatchedApp.find(byID: id) {
                item.title = title(for: app)
            }
        }
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu()
    }

    func menuDidClose(_ menu: NSMenu) {
        appItems.removeAll()
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        appItems.removeAll()

        let header = NSMenuItem(title: "Glint", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        // Problems and quiet mode first: they explain the menu bar symbol.
        if let controller, !controller.healthIssues.isEmpty || controller.quietReason != nil {
            for issue in controller.healthIssues {
                let item = addItem(issue.title, action: #selector(fixHealthIssue(_:)), image: symbol("exclamationmark.triangle.fill"))
                item.toolTip = issue.detail
                item.representedObject = issue
            }
            if let reason = controller.quietReason {
                addItem("Sessiz mod: \(reason.title)", action: #selector(openSettings(_:)), image: symbol("moon.fill"))
            }
            menu.addItem(.separator())
        }

        let apps = WatchedApp.listed.filter { WatchedAppStore.shared.config(for: $0).isWatched }
        if apps.isEmpty {
            let empty = NSMenuItem(title: "İzlenen uygulama yok", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for app in apps {
                let item = addItem(
                    title(for: app),
                    action: #selector(openApp(_:)),
                    image: app.menuIcon ?? symbol(app.fallbackIconName)
                )
                item.representedObject = app.id
                appItems[app.id] = item
            }
        }

        menu.addItem(.separator())

        let isPaused = controller?.isPaused ?? false
        addItem(
            isPaused ? "İzlemeyi Sürdür" : "İzlemeyi Duraklat",
            action: #selector(togglePause(_:)),
            image: symbol(isPaused ? "play.fill" : "pause.fill")
        )
        addItem(
            "Mac'i Şimdi Kilitle",
            action: #selector(lockMac(_:)),
            image: symbol("lock.fill")
        )

        menu.addItem(.separator())
        addItem("Ayarlar…", action: #selector(openSettings(_:)), key: ",", image: symbol("gearshape"))

        menu.addItem(.separator())
        addItem("Glint'ten Çık", action: #selector(quit(_:)), key: "q", image: symbol("power"))
    }

    @discardableResult
    private func addItem(_ title: String, action: Selector, key: String = "", image: NSImage?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.isEnabled = true
        item.image = image
        // macOS 27 hides menu item images unless the item asks for them (the default, 0, hides
        // them). The property isn't in the macOS 26 SDK yet, so it's set by name; 1 shows the image.
        let visibility = "preferredImageVisibility"
        if image != nil, item.responds(to: NSSelectorFromString(visibility)) {
            item.setValue(1, forKey: visibility)
        }
        menu.addItem(item)
        return item
    }

    private func title(for app: WatchedApp) -> String {
        let unread = controller?.appStatuses[app.id]?.unread ?? 0
        return unread > 0 ? "\(app.name) (\(unread) okunmamış)" : app.name
    }

    private func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
    }

    // MARK: - Actions

    @objc private func openApp(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        WatchedApp.find(byID: id)?.openApplication()
    }

    /// Fixes the problem where a button can (System Settings); otherwise shows it on the Hakkında page.
    @objc private func fixHealthIssue(_ sender: NSMenuItem) {
        guard let issue = sender.representedObject as? HealthIssue else { return }
        if issue.actionTitle != nil {
            issue.performAction()
        } else {
            UserDefaults.standard.set(SettingsPage.about.rawValue, forKey: "settingsPage")
            openSettings(sender)
        }
    }

    @objc private func togglePause(_ sender: Any?) {
        guard let controller else { return }
        controller.setPaused(!controller.isPaused)
        rebuildMenu()
    }

    @objc private func lockMac(_ sender: Any?) {
        ScreenLock.lock()
    }

    @objc private func openSettings(_ sender: Any?) {
        guard let controller else { return }
        // Ensure menu dismissal finishes, then activate app and show window
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            SettingsWindowManager.shared.show(controller: controller)
        }
    }

    @objc private func quit(_ sender: Any?) {
        NSApp.terminate(nil)
    }
}
