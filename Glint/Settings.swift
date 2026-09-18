import Foundation

/// UserDefaults keys shared by the settings UI (@AppStorage) and the controller.
enum Pref {
    static let idleMinutes = "idleMinutes"
    static let lockCountsAsAway = "lockCountsAsAway"
    static let alarmSeconds = "alarmSeconds"
    static let alarmStyle = "alarmStyle"
    static let alarmSound = "alarmSound"
    static let alarmVolume = "alarmVolume"
    static let alarmRepeatMinutes = "alarmRepeatMinutes"
    static let overrideSystemVolume = "overrideSystemVolume"
    static let preventSleep = "preventSleep"
    static let notifyEnabled = "notifyEnabled"
    static let notifyGlow = "notifyGlow"
    static let notifyGlowIntensity = "notifyGlowIntensity"
    static let notifyGlowSeconds = "notifyGlowSeconds"
    static let notifyBanner = "notifyBanner"
    static let notifyBannerPosition = "notifyBannerPosition"
    static let notifySound = "notifySound"
    static let notifyVolume = "notifyVolume"
    static let badgeFallback = "badgeFallback"
    static let quietDuringFocus = "quietDuringFocus"
    static let quietHoursEnabled = "quietHoursEnabled"
    /// Minutes after midnight.
    static let quietHoursStart = "quietHoursStart"
    static let quietHoursEnd = "quietHoursEnd"
    static let importantKeywords = "importantKeywords"
    static let importantBreaksQuiet = "importantBreaksQuiet"
    static let showMenuBarCount = "showMenuBarCount"
    static let hasLaunched = "hasLaunched"
    /// Whether a permission ever worked, so losing it later shows up as a problem.
    static let hadFullDiskAccess = "hadFullDiskAccess"
    static let hadAccessibility = "hadAccessibility"

    static let teamsPurpleHex = "#5B5FC7"

    static let defaults: [String: Any] = [
        idleMinutes: 2.0,
        lockCountsAsAway: true,
        alarmSeconds: 5.0,
        alarmStyle: AlarmStyle.flash.rawValue,
        alarmSound: AlarmSoundLibrary.defaultID,
        alarmVolume: 0.5,
        alarmRepeatMinutes: 0.0,
        overrideSystemVolume: true,
        preventSleep: true,
        notifyEnabled: true,
        notifyGlow: true,
        notifyGlowIntensity: 0.8,
        notifyGlowSeconds: 1.0,
        notifyBanner: true,
        notifyBannerPosition: BannerPosition.topRight.rawValue,
        notifySound: "builtin.ding",
        notifyVolume: 0.6,
        // On: the badge reports a message at once — the island and the glow — and the banner follows
        // with the sender and the text once macOS has written the record.
        badgeFallback: true,
        quietDuringFocus: true,
        quietHoursEnabled: false,
        quietHoursStart: 22.0 * 60,
        quietHoursEnd: 7.0 * 60,
        importantKeywords: "",
        importantBreaksQuiet: true,
        showMenuBarCount: true,
        // Where the menu bar item first appears; the user can still ⌘-drag it elsewhere.
        "NSStatusItem Preferred Position Glint": 400.0,
    ]

    static func register() { UserDefaults.standard.register(defaults: defaults) }

    /// The bundle ID the app had while it was called TeamsAlarm.
    private static let legacyDomain = "dev.burak.teamsalarm.mac"

    /// Settings of TeamsAlarm features Glint doesn't have (phone pairing, proximity, calls), which the
    /// migration below carried over.
    private static let obsoleteKeys = [
        "apnsKeyID", "apnsTeamID", "callDelayMinutes", "maxVolume", "notifyGlowColor", "pairingCode",
        "proximityDelay", "proximityDeviceID", "proximityDeviceName", "proximityEnabled",
        "proximityLostTimeout", "proximityRequireIdle", "proximityThreshold", "repeatCallMinutes",
    ]

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

    static func removeObsoleteSettings() {
        let d = UserDefaults.standard
        for key in obsoleteKeys where d.object(forKey: key) != nil {
            d.removeObject(forKey: key)
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

enum BannerPosition: String, CaseIterable, Identifiable, Codable {
    case topRight = "topRight"
    case topCenter = "topCenter"
    case topLeft = "topLeft"
    case bottomRight = "bottomRight"
    case bottomCenter = "bottomCenter"
    case bottomLeft = "bottomLeft"
    /// Waiting in the notch (MacBooks with one): it grows with the app's icon, hovering opens the stack.
    case notch = "notch"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .topRight: "Üst Sağ"
        case .topCenter: "Üst Orta"
        case .topLeft: "Üst Sol"
        case .bottomRight: "Alt Sağ"
        case .bottomCenter: "Alt Orta"
        case .bottomLeft: "Alt Sol"
        case .notch: "Çentik"
        }
    }

    var iconName: String {
        switch self {
        case .topRight: "arrow.up.right.square.fill"
        case .topCenter: "arrow.up.square.fill"
        case .topLeft: "arrow.up.left.square.fill"
        case .bottomRight: "arrow.down.right.square.fill"
        case .bottomCenter: "arrow.down.square.fill"
        case .bottomLeft: "arrow.down.left.square.fill"
        case .notch: "macbook"
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
    /// nil = the alarm rings once.
    var alarmRepeatInterval: TimeInterval?
    var overrideSystemVolume: Bool
    var preventSleep: Bool
    var notifyEnabled: Bool
    var notifyGlow: Bool
    var notifyGlowIntensity: Double
    /// nil = keep glowing until the messages are read.
    var notifyGlowDuration: TimeInterval?
    var notifyBanner: Bool
    var notifyBannerPosition: BannerPosition
    var notifySoundID: String
    var notifyVolume: Double
    /// Notify as soon as a badge rises, without waiting for the notification's record to be written.
    var badgeFallback: Bool
    var quietDuringFocus: Bool
    /// nil = no quiet hours.
    var quietHours: QuietHours?
    var importantKeywords: [String]
    var importantBreaksQuiet: Bool

    static func load(_ d: UserDefaults = .standard) -> AppSettings {
        let glowSeconds = d.double(forKey: Pref.notifyGlowSeconds)
        let repeatMinutes = d.double(forKey: Pref.alarmRepeatMinutes)
        return AppSettings(
            idleThreshold: d.double(forKey: Pref.idleMinutes) * 60,
            lockCountsAsAway: d.bool(forKey: Pref.lockCountsAsAway),
            alarmDuration: d.double(forKey: Pref.alarmSeconds),
            alarmStyle: AlarmStyle(rawValue: d.string(forKey: Pref.alarmStyle) ?? "") ?? .flash,
            alarmSoundID: d.string(forKey: Pref.alarmSound) ?? AlarmSoundLibrary.defaultID,
            alarmVolume: d.double(forKey: Pref.alarmVolume),
            alarmRepeatInterval: repeatMinutes > 0 ? repeatMinutes * 60 : nil,
            overrideSystemVolume: d.bool(forKey: Pref.overrideSystemVolume),
            preventSleep: d.bool(forKey: Pref.preventSleep),
            notifyEnabled: d.bool(forKey: Pref.notifyEnabled),
            notifyGlow: d.bool(forKey: Pref.notifyGlow),
            notifyGlowIntensity: d.double(forKey: Pref.notifyGlowIntensity),
            notifyGlowDuration: glowSeconds > 0 ? glowSeconds : nil,
            notifyBanner: d.bool(forKey: Pref.notifyBanner),
            notifyBannerPosition: BannerPosition(rawValue: d.string(forKey: Pref.notifyBannerPosition) ?? "") ?? .topRight,
            notifySoundID: d.string(forKey: Pref.notifySound) ?? "builtin.ding",
            notifyVolume: d.double(forKey: Pref.notifyVolume),
            badgeFallback: d.bool(forKey: Pref.badgeFallback),
            quietDuringFocus: d.bool(forKey: Pref.quietDuringFocus),
            quietHours: d.bool(forKey: Pref.quietHoursEnabled)
                ? QuietHours(start: Int(d.double(forKey: Pref.quietHoursStart)), end: Int(d.double(forKey: Pref.quietHoursEnd)))
                : nil,
            importantKeywords: NotificationRules.keywords(from: d.string(forKey: Pref.importantKeywords) ?? ""),
            importantBreaksQuiet: d.bool(forKey: Pref.importantBreaksQuiet)
        )
    }
}
