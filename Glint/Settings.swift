import Foundation

/// UserDefaults keys shared by the settings UI (@AppStorage) and the controller.
enum Pref {
    static let idleMinutes = "idleMinutes"
    static let lockCountsAsAway = "lockCountsAsAway"
    static let alarmSeconds = "alarmSeconds"
    static let alarmStyle = "alarmStyle"
    static let alarmSound = "alarmSound"
    static let alarmVolume = "alarmVolume"
    static let overrideSystemVolume = "overrideSystemVolume"
    static let preventSleep = "preventSleep"
    static let notifyEnabled = "notifyEnabled"
    static let notifyGlow = "notifyGlow"
    static let notifyGlowIntensity = "notifyGlowIntensity"
    static let notifyGlowSeconds = "notifyGlowSeconds"
    static let notifySound = "notifySound"
    static let notifyVolume = "notifyVolume"
    static let showMenuBarCount = "showMenuBarCount"
    static let hasLaunched = "hasLaunched"

    static let teamsPurpleHex = "#5B5FC7"

    static let defaults: [String: Any] = [
        idleMinutes: 2.0,
        lockCountsAsAway: true,
        alarmSeconds: 5.0,
        alarmStyle: AlarmStyle.flash.rawValue,
        alarmSound: AlarmSoundLibrary.defaultID,
        alarmVolume: 0.5,
        overrideSystemVolume: true,
        preventSleep: true,
        notifyEnabled: true,
        notifyGlow: true,
        notifyGlowIntensity: 0.8,
        notifyGlowSeconds: 1.0,
        notifySound: "builtin.ding",
        notifyVolume: 0.6,
        showMenuBarCount: true,
        // Where the menu bar item first appears; the user can still ⌘-drag it elsewhere.
        "NSStatusItem Preferred Position Glint": 400.0,
    ]

    static func register() { UserDefaults.standard.register(defaults: defaults) }

    /// The bundle ID the app had while it was called TeamsAlarm.
    private static let legacyDomain = "dev.burak.teamsalarm.mac"

    /// On Glint's first launch, carries over the settings saved under the TeamsAlarm name.
    /// AppKit's own keys (window frames, menu bar position) are left behind.
    static func migrateLegacySettings() {
        let d = UserDefaults.standard
        guard d.object(forKey: hasLaunched) == nil,
              let legacy = d.persistentDomain(forName: legacyDomain) else { return }
        for (key, value) in legacy where !key.hasPrefix("NS") {
            d.set(value, forKey: key)
        }
    }
}

enum AlarmStyle: String, CaseIterable, Identifiable {
    case flash, calm, off

    var id: String { rawValue }

    var title: String {
        switch self {
        case .flash: "Yanıp sönen"
        case .calm: "Sakin"
        case .off: "Kapalı"
        }
    }

    var detail: String {
        switch self {
        case .flash: "Tüm ekranlar kırmızı yanıp söner, ortadaki uyarı kartı titrer."
        case .calm: "Ekran hafifçe kararır, uyarı kartı yavaşça sallanır."
        case .off: "Ekranda bir şey gösterilmez, sadece ses çalar."
        }
    }
}

/// A snapshot of the settings, read fresh on every monitoring tick.
struct AppSettings {
    var idleThreshold: TimeInterval
    var lockCountsAsAway: Bool
    var alarmDuration: TimeInterval
    var alarmStyle: AlarmStyle
    var alarmSoundID: String
    var alarmVolume: Double
    var overrideSystemVolume: Bool
    var preventSleep: Bool
    var notifyEnabled: Bool
    var notifyGlow: Bool
    var notifyGlowIntensity: Double
    /// nil = keep glowing until the messages are read.
    var notifyGlowDuration: TimeInterval?
    var notifySoundID: String
    var notifyVolume: Double

    static func load(_ d: UserDefaults = .standard) -> AppSettings {
        let glowSeconds = d.double(forKey: Pref.notifyGlowSeconds)
        return AppSettings(
            idleThreshold: d.double(forKey: Pref.idleMinutes) * 60,
            lockCountsAsAway: d.bool(forKey: Pref.lockCountsAsAway),
            alarmDuration: d.double(forKey: Pref.alarmSeconds),
            alarmStyle: AlarmStyle(rawValue: d.string(forKey: Pref.alarmStyle) ?? "") ?? .flash,
            alarmSoundID: d.string(forKey: Pref.alarmSound) ?? AlarmSoundLibrary.defaultID,
            alarmVolume: d.double(forKey: Pref.alarmVolume),
            overrideSystemVolume: d.bool(forKey: Pref.overrideSystemVolume),
            preventSleep: d.bool(forKey: Pref.preventSleep),
            notifyEnabled: d.bool(forKey: Pref.notifyEnabled),
            notifyGlow: d.bool(forKey: Pref.notifyGlow),
            notifyGlowIntensity: d.double(forKey: Pref.notifyGlowIntensity),
            notifyGlowDuration: glowSeconds > 0 ? glowSeconds : nil,
            notifySoundID: d.string(forKey: Pref.notifySound) ?? "builtin.ding",
            notifyVolume: d.double(forKey: Pref.notifyVolume)
        )
    }
}
