import AppKit
import Observation
import SwiftUI

/// An app whose notifications Glint shows. Apps are recognized by their Dock badge, so any app
/// that badges its icon works. Every app is added by the user; the well-known messaging apps have
/// a built-in entry, with its own color and icon, that is used when one of them is added.
struct WatchedApp: Identifiable, Hashable {
    /// Built-in apps use a short id ("teams"), added apps their bundle ID.
    let id: String
    let name: String
    let bundleIDs: [String]
    let defaultColorHex: String
    let fallbackIconName: String
    let isBuiltIn: Bool

    var isInstalled: Bool {
        installedURL != nil
    }

    var installedURL: URL? {
        for bid in bundleIDs {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
                return url
            }
        }
        return nil
    }

    var primaryBundleID: String {
        for bid in bundleIDs {
            if NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) != nil {
                return bid
            }
        }
        return bundleIDs.first ?? ""
    }

    @MainActor var runningApp: NSRunningApplication? {
        for bid in bundleIDs {
            if let app = RunningApps.app(withBundleID: bid) {
                return app
            }
        }
        return nil
    }

    @MainActor var appIcon: NSImage? {
        installedURL.map(AppIconCache.icon(forAppAt:))
    }

    /// 16x16 formatted native full-color icon for macOS menu items.
    @MainActor var menuIcon: NSImage? {
        guard let raw = appIcon else { return nil }
        let targetSize = NSSize(width: 16, height: 16)
        let cleanImage = NSImage(size: targetSize)
        cleanImage.lockFocus()
        raw.draw(in: NSRect(origin: .zero, size: targetSize),
                 from: NSRect(origin: .zero, size: raw.size),
                 operation: .sourceOver,
                 fraction: 1.0)
        cleanImage.unlockFocus()
        cleanImage.isTemplate = false
        return cleanImage
    }

    /// Opens macOS System Settings directly to this application's notification settings pane.
    func openNotificationSettings() {
        let bundleID = primaryBundleID
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(bundleID)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Launches the application, or brings it to the foreground (reopening its window) if it's running.
    @MainActor func openApplication() {
        guard let url = installedURL ?? runningApp?.bundleURL else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config, completionHandler: nil)
    }

    static let builtIn: [WatchedApp] = [
        WatchedApp(
            id: "teams",
            name: "Microsoft Teams",
            bundleIDs: ["com.microsoft.teams2", "com.microsoft.teams"],
            defaultColorHex: "#5B5FC7",
            fallbackIconName: "bubble.left.and.bubble.right.fill",
            isBuiltIn: true
        ),
        WatchedApp(
            id: "whatsapp",
            name: "WhatsApp",
            bundleIDs: ["net.whatsapp.WhatsApp", "net.whatsapp.WhatsApp.mac"],
            defaultColorHex: "#25D366",
            fallbackIconName: "phone.bubble.fill",
            isBuiltIn: true
        ),
        WatchedApp(
            id: "telegram",
            name: "Telegram",
            bundleIDs: ["ru.keepcoder.Telegram", "ph.telegra.Telegraph"],
            defaultColorHex: "#24A1DE",
            fallbackIconName: "paperplane.fill",
            isBuiltIn: true
        ),
        WatchedApp(
            id: "slack",
            name: "Slack",
            bundleIDs: ["com.tinyspeck.slackmacgap"],
            defaultColorHex: "#E01E5A",
            fallbackIconName: "number",
            isBuiltIn: true
        ),
        WatchedApp(
            id: "discord",
            name: "Discord",
            bundleIDs: ["com.hnc.Discord"],
            defaultColorHex: "#5865F2",
            fallbackIconName: "bubble.fill",
            isBuiltIn: true
        ),
        WatchedApp(
            id: "signal",
            name: "Signal",
            bundleIDs: ["org.whispersystems.signal-desktop"],
            defaultColorHex: "#3A76F0",
            fallbackIconName: "lock.bubble.fill",
            isBuiltIn: true
        ),
    ]

    /// Every watched app: the ones the user added.
    @MainActor static var all: [WatchedApp] {
        WatchedAppStore.shared.addedApps
    }

    /// The apps shown in settings and the menu, by name.
    @MainActor static var listed: [WatchedApp] {
        all
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    @MainActor static func find(byID id: String) -> WatchedApp? {
        all.first { $0.id == id }
    }
}

/// Persistent per-app settings.
struct WatchedAppConfig: Codable, Equatable {
    /// Glint's own notification (glow and sound) for this app.
    var enabled: Bool
    /// The full-screen alarm when a notification arrives while the user is away.
    var alarmEnabled: Bool
    /// The alarm rings only for notifications with an important word (Odak ve Öncelik).
    var alarmOnlyImportant: Bool
    var glowColorHex: String
    /// nil = the default sound from Bildirim Ayarları.
    var soundID: String?
    /// nil = the default volume from Bildirim Ayarları.
    var volume: Double?
    /// Where the app's cards pop up; nil = the position from Görünüm Ayarları.
    var bannerPosition: BannerPosition?

    init(enabled: Bool = true, alarmEnabled: Bool = true, alarmOnlyImportant: Bool = false, glowColorHex: String, soundID: String? = nil, volume: Double? = nil, bannerPosition: BannerPosition? = nil) {
        self.enabled = enabled
        self.alarmEnabled = alarmEnabled
        self.alarmOnlyImportant = alarmOnlyImportant
        self.glowColorHex = glowColorHex
        self.soundID = soundID
        self.volume = volume
        self.bannerPosition = bannerPosition
    }

    enum CodingKeys: String, CodingKey {
        case enabled, alarmEnabled, alarmOnlyImportant, glowColorHex, soundID, volume, bannerPosition
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        self.alarmEnabled = try container.decodeIfPresent(Bool.self, forKey: .alarmEnabled) ?? true
        self.alarmOnlyImportant = try container.decodeIfPresent(Bool.self, forKey: .alarmOnlyImportant) ?? false
        self.glowColorHex = try container.decode(String.self, forKey: .glowColorHex)
        self.soundID = try container.decodeIfPresent(String.self, forKey: .soundID)
        self.volume = try container.decodeIfPresent(Double.self, forKey: .volume)
        // A position a later version took out falls back to the default rather than losing the rest.
        // The notch is the top centre now.
        let position = (try? container.decodeIfPresent(BannerPosition.self, forKey: .bannerPosition)) ?? nil
        self.bannerPosition = position == .notch ? .topCenter : position
    }
}

/// The apps the user added and every app's settings, saved in UserDefaults. Observable, so
/// settings views update as soon as an app is added, removed or changed.
@MainActor
@Observable
final class WatchedAppStore {
    static let shared = WatchedAppStore()

    /// Glow color for an added app whose icon has no clear color of its own.
    static let fallbackColorHex = "#0A84FF"
    /// Kept from when only messaging apps were supported, so earlier settings still load.
    private static let configsKey = "messagingAppConfigs"
    private static let addedAppsKey = "addedApps"
    /// Set once the installed built-in apps, which used to be listed on their own, were carried
    /// into the added apps.
    private static let manualListKey = "appListIsManual"

    private(set) var addedApps: [WatchedApp]
    private var configs: [String: WatchedAppConfig]

    private struct SavedApp: Codable {
        let bundleID: String
        let name: String
        let colorHex: String

        /// A built-in app's own entry when it is one of them.
        var watchedApp: WatchedApp {
            if let builtIn = WatchedApp.builtIn.first(where: { $0.bundleIDs.contains(bundleID) }) {
                return builtIn
            }
            return WatchedApp(id: bundleID, name: name, bundleIDs: [bundleID], defaultColorHex: colorHex,
                       fallbackIconName: "app.badge", isBuiltIn: false)
        }
    }

    private init() {
        let defaults = UserDefaults.standard
        configs = defaults.data(forKey: Self.configsKey)
            .flatMap { try? JSONDecoder().decode([String: WatchedAppConfig].self, from: $0) } ?? [:]
        addedApps = (defaults.data(forKey: Self.addedAppsKey)
            .flatMap { try? JSONDecoder().decode([SavedApp].self, from: $0) } ?? [])
            .map(\.watchedApp)
    }

    /// Glint used to list the built-in apps by itself whenever they were installed. For users from
    /// then, those apps become added ones, so nothing they watched disappears; a new user starts
    /// with an empty list. Runs before the store is first used.
    static func migrateToManualList(_ d: UserDefaults = .standard) {
        guard !d.bool(forKey: manualListKey) else { return }
        d.set(true, forKey: manualListKey)
        guard d.object(forKey: Pref.hasLaunched) != nil else { return }
        var saved = d.data(forKey: addedAppsKey)
            .flatMap { try? JSONDecoder().decode([SavedApp].self, from: $0) } ?? []
        for app in WatchedApp.builtIn where app.isInstalled {
            guard !saved.contains(where: { app.bundleIDs.contains($0.bundleID) }) else { continue }
            saved.append(SavedApp(bundleID: app.primaryBundleID, name: app.name, colorHex: app.defaultColorHex))
        }
        if let data = try? JSONEncoder().encode(saved) {
            d.set(data, forKey: addedAppsKey)
        }
    }

    func config(for app: WatchedApp) -> WatchedAppConfig {
        configs[app.id] ?? WatchedAppConfig(glowColorHex: app.defaultColorHex)
    }

    /// Changes only the fields set in `change`, so views holding an older copy of the config
    /// can't undo each other's edits.
    @discardableResult
    func update(_ app: WatchedApp, _ change: (inout WatchedAppConfig) -> Void) -> WatchedAppConfig {
        var updated = config(for: app)
        change(&updated)
        configs[app.id] = updated
        saveConfigs()
        return updated
    }

    /// Starts watching the app at `url`. Returns its entry (the existing one if it's already
    /// watched), or nil when `url` isn't an app or is Glint itself.
    @discardableResult
    func add(appAt url: URL) -> WatchedApp? {
        guard let bundleID = Bundle(url: url)?.bundleIdentifier,
              bundleID != Bundle.main.bundleIdentifier else { return nil }
        if let existing = WatchedApp.all.first(where: { $0.bundleIDs.contains(bundleID) }) {
            return existing
        }

        var name = FileManager.default.displayName(atPath: url.path)
        if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
        let colorHex = NSWorkspace.shared.icon(forFile: url.path).glowColorHex ?? Self.fallbackColorHex
        let app = SavedApp(bundleID: bundleID, name: name, colorHex: colorHex).watchedApp
        addedApps.append(app)
        saveAddedApps()
        return app
    }

    /// Stops watching an app and forgets its settings.
    func remove(_ app: WatchedApp) {
        addedApps.removeAll { $0.id == app.id }
        configs[app.id] = nil
        saveAddedApps()
        saveConfigs()
    }

    private func saveConfigs() {
        if let data = try? JSONEncoder().encode(configs) {
            UserDefaults.standard.set(data, forKey: Self.configsKey)
        }
    }

    private func saveAddedApps() {
        // A built-in app is saved by one of its bundle IDs, which brings its entry back on loading.
        let saved = addedApps.map { app in
            SavedApp(bundleID: app.isBuiltIn ? app.primaryBundleID : app.id, name: app.name, colorHex: app.defaultColorHex)
        }
        if let data = try? JSONEncoder().encode(saved) {
            UserDefaults.standard.set(data, forKey: Self.addedAppsKey)
        }
    }
}

extension WatchedAppConfig {
    /// Whether Glint follows the app at all: for its notification, its alarm or both.
    var isWatched: Bool { enabled || alarmEnabled }

    /// Where the app's cards pop up: its own position, or the one from Görünüm Ayarları.
    func bannerPosition(default fallback: BannerPosition) -> BannerPosition {
        bannerPosition ?? fallback
    }
}

/// Running apps by bundle ID. Each property read on an `NSRunningApplication` is a LaunchServices
/// lookup, and scanning every running app on each poll was most of Glint's CPU time; the map is
/// rebuilt when an app launches or quits (and every few seconds, in case a notice was missed).
@MainActor
enum RunningApps {
    private static let maxAge: TimeInterval = 5
    private static var byBundleID: [String: NSRunningApplication] = [:]
    private static var builtAt = Date.distantPast
    private static var observers: [NSObjectProtocol] = []

    static func app(withBundleID bundleID: String) -> NSRunningApplication? {
        if Date().timeIntervalSince(builtAt) > maxAge {
            rebuild()
        }
        return byBundleID[bundleID]
    }

    private static func rebuild() {
        if observers.isEmpty {
            let center = NSWorkspace.shared.notificationCenter
            observers = [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification].map { name in
                center.addObserver(forName: name, object: nil, queue: .main) { _ in
                    MainActor.assumeIsolated { RunningApps.builtAt = .distantPast }
                }
            }
        }
        var map: [String: NSRunningApplication] = [:]
        for app in NSWorkspace.shared.runningApplications where !app.isTerminated {
            if let bundleID = app.bundleIdentifier, map[bundleID] == nil {
                map[bundleID] = app
            }
        }
        byBundleID = map
        builtAt = Date()
    }
}

/// App icons by location. `NSWorkspace` loads a new image on every call, and banners and the notch
/// ask for them each time they redraw.
@MainActor
enum AppIconCache {
    private static var icons: [URL: NSImage] = [:]

    static func icon(forAppAt url: URL) -> NSImage {
        if let icon = icons[url] { return icon }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icons[url] = icon
        return icon
    }
}

extension NSImage {
    /// A glow color taken from the image: its average color, made vivid. nil when the image is
    /// mostly gray or transparent, where the average says little.
    var glowColorHex: String? {
        guard let cgImage = cgImage(forProposedRect: nil, context: nil, hints: nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let side = 16
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                bytesPerRow: side * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .high
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }

        // The pixels are premultiplied, so summing them weights each one by its opacity.
        var red = 0.0, green = 0.0, blue = 0.0, coverage = 0.0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            red += Double(pixels[i])
            green += Double(pixels[i + 1])
            blue += Double(pixels[i + 2])
            coverage += Double(pixels[i + 3])
        }
        guard coverage > 0 else { return nil }
        let average = NSColor(srgbRed: red / coverage, green: green / coverage, blue: blue / coverage, alpha: 1)
        guard average.saturationComponent > 0.15 else { return nil }
        return NSColor(
            hue: average.hueComponent,
            saturation: min(1, average.saturationComponent * 1.4 + 0.15),
            brightness: max(0.8, average.brightnessComponent),
            alpha: 1
        ).hexString
    }
}
