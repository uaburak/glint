import AppKit
import Observation
import SwiftUI

/// An app whose notifications Glint shows. Apps are recognized by their Dock badge, so any app
/// that badges its icon works: the well-known messaging apps are built in, others are added.
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

    var runningApp: NSRunningApplication? {
        runningApp(in: NSWorkspace.shared.runningApplications)
    }

    func runningApp(in apps: [NSRunningApplication]) -> NSRunningApplication? {
        apps.first { app in
            guard let bid = app.bundleIdentifier, !app.isTerminated else { return false }
            return bundleIDs.contains(bid)
        }
    }

    var appIcon: NSImage? {
        if let url = installedURL {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return nil
    }

    /// 16x16 formatted native full-color icon for macOS menu items.
    var menuIcon: NSImage? {
        guard let url = installedURL else { return nil }
        let raw = NSWorkspace.shared.icon(forFile: url.path)
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
    func openApplication() {
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

    /// Every app that can be watched: all built-in ones (installed or not) plus the added ones.
    @MainActor static var all: [WatchedApp] {
        builtIn + WatchedAppStore.shared.addedApps
    }

    /// The apps shown in settings and the menu: installed built-in apps and the added ones, by name.
    @MainActor static var listed: [WatchedApp] {
        (builtIn.filter(\.isInstalled) + WatchedAppStore.shared.addedApps)
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
    var glowColorHex: String
    /// nil = the default sound from Bildirim Ayarları.
    var soundID: String?
    /// nil = the default volume from Bildirim Ayarları.
    var volume: Double?

    init(enabled: Bool = true, alarmEnabled: Bool = true, glowColorHex: String, soundID: String? = nil, volume: Double? = nil) {
        self.enabled = enabled
        self.alarmEnabled = alarmEnabled
        self.glowColorHex = glowColorHex
        self.soundID = soundID
        self.volume = volume
    }

    enum CodingKeys: String, CodingKey {
        case enabled, alarmEnabled, glowColorHex, soundID, volume
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        self.alarmEnabled = try container.decodeIfPresent(Bool.self, forKey: .alarmEnabled) ?? true
        self.glowColorHex = try container.decode(String.self, forKey: .glowColorHex)
        self.soundID = try container.decodeIfPresent(String.self, forKey: .soundID)
        self.volume = try container.decodeIfPresent(Double.self, forKey: .volume)
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

    private(set) var addedApps: [WatchedApp]
    private var configs: [String: WatchedAppConfig]

    private struct SavedApp: Codable {
        let bundleID: String
        let name: String
        let colorHex: String

        var watchedApp: WatchedApp {
            WatchedApp(id: bundleID, name: name, bundleIDs: [bundleID], defaultColorHex: colorHex,
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

    /// Stops watching an added app and forgets its settings. Built-in apps can only be turned off.
    func remove(_ app: WatchedApp) {
        guard !app.isBuiltIn else { return }
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
        let saved = addedApps.map { SavedApp(bundleID: $0.id, name: $0.name, colorHex: $0.defaultColorHex) }
        if let data = try? JSONEncoder().encode(saved) {
            UserDefaults.standard.set(data, forKey: Self.addedAppsKey)
        }
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
