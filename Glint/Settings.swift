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
    static let notifyStyle = "notifyStyle"
    static let notifyEffect = "notifyEffect"
    static let notifyGlowIntensity = "notifyGlowIntensity"
    static let notifyGlowSeconds = "notifyGlowSeconds"
    static let notifyBannerPosition = "notifyBannerPosition"
    static let notifySound = "notifySound"
    static let notifyVolume = "notifyVolume"
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
        notifyStyle: NotifyStyle.full.rawValue,
        notifyEffect: NotifyEffect.glow.rawValue,
        notifyGlowIntensity: 0.8,
        notifyGlowSeconds: 1.0,
        notifyBannerPosition: BannerPosition.topRight.rawValue,
        notifySound: "builtin.ding",
        notifyVolume: 0.6,
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
        // Glint used to announce a message from its badge and fill the text in later; now a
        // notification waits until its text is there and everything comes at once.
        "badgeFallback",
        // The glow and the banner each had a switch; `notifyStyle` carries both.
        "notifyGlow", "notifyBanner",
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

    /// Glint used to have a switch for the glow and another for the banner, and then a single style
    /// that carried both. What the screen does and where the message shows are two settings now, so
    /// whatever a user had is carried into the pair that matches it.
    static func migrateNotifyStyle(_ d: UserDefaults = .standard) {
        guard d.string(forKey: notifyEffect) == nil else { return }
        let glowed: Bool
        let style: NotifyStyle
        switch d.string(forKey: notifyStyle) {
        case "full": glowed = true; style = .full
        case "notchGlow": glowed = true; style = .notch
        case "notch": glowed = false; style = .notch
        case "banner": glowed = false; style = .banner
        case "glow": glowed = true; style = NotifyStyle.none
        default:
            // Older still: one switch for the glow, one for the banner.
            glowed = d.object(forKey: "notifyGlow") as? Bool ?? true
            style = (d.object(forKey: "notifyBanner") as? Bool ?? true) ? .full : .notch
        }
        d.set(style.rawValue, forKey: notifyStyle)
        d.set((glowed ? NotifyEffect.glow : NotifyEffect.none).rawValue, forKey: notifyEffect)
    }

    static func removeObsoleteSettings() {
        let d = UserDefaults.standard
        for key in obsoleteKeys where d.object(forKey: key) != nil {
            d.removeObject(forKey: key)
        }
    }
}

/// Where a notification's message shows itself. The screen's effect is `NotifyEffect`, and the
/// sound and the alarm are their own settings.
enum NotifyStyle: String, CaseIterable, Identifiable {
    /// The notch holds it and a card pops out with the message.
    case full
    /// The notch alone: the app's icon with the number of waiting notifications on it.
    case notch
    /// A card with the message, and nothing else.
    case banner
    /// Nothing but the effect on screen.
    case none

    var id: String { rawValue }

    var title: String {
        switch self {
        case .full: "Çentik ve kart"
        case .notch: "Yalnızca çentik"
        case .banner: "Yalnızca kart"
        case .none: "Hiçbiri"
        }
    }

    var detail: String {
        switch self {
        case .full: "Çentikte uygulamanın simgesi, altında mesajı gösteren kart."
        case .notch: "Çentik büyür, simge ve bekleyen bildirim sayısı görünür."
        case .banner: "Yalnızca mesajı gösteren kart."
        case .none: "Mesaj gösterilmez; yalnızca seçtiğin efekt ve ses."
        }
    }

    var symbol: String {
        switch self {
        case .full: "rectangle.inset.topthird.filled"
        case .notch: "rectangle.topthird.inset.filled"
        case .banner: "rectangle.fill.on.rectangle.fill"
        case .none: "rectangle.dashed"
        }
    }

    var showsBanner: Bool { self == .full || self == .banner }
    /// Whether a notification takes its place in the notch, where it waits to be read.
    var showsNotch: Bool { self == .full || self == .notch }
}

/// What the screen does when a notification comes, in the app's own colour.
enum NotifyEffect: String, CaseIterable, Identifiable {
    /// Soft light along the screen's edges.
    case glow
    /// The window in front jolts a few pixels and settles back.
    case shake
    /// The whole screen takes the colour for an instant.
    case flash
    /// A band of colour sweeps across the screen once.
    case sweep
    /// A ring spreads out from the notch, like a drop in water.
    case ripple
    /// A thin, sharp border around the screen.
    case frame
    /// A small dot pulses in the corner.
    case dot
    /// Nothing on screen.
    case none

    var id: String { rawValue }

    var title: String {
        switch self {
        case .glow: "Işıma"
        case .shake: "Sarsıntı"
        case .flash: "Flaş"
        case .sweep: "Perde"
        case .ripple: "Dalga"
        case .frame: "Çerçeve"
        case .dot: "Nokta"
        case .none: "Efekt yok"
        }
    }

    var detail: String {
        switch self {
        case .glow: "Ekran kenarlarında uygulamanın renginde yumuşak ışıma."
        case .shake: "Öndeki pencere bir an sağa sola oynar ve yerine döner."
        case .flash: "Ekran bir anlığına uygulamanın renginde parlar."
        case .sweep: "Renkli bir bant ekranı bir kenardan diğerine süpürür."
        case .ripple: "Çentikten dışa doğru genişleyen bir halka."
        case .frame: "Ekranın kenarında ince, keskin bir renkli çerçeve."
        case .dot: "Ekranın köşesinde nabız gibi atan küçük bir nokta."
        case .none: "Ekranda hiçbir şey olmaz."
        }
    }

    var symbol: String {
        switch self {
        case .glow: "sparkles"
        case .shake: "waveform.path"
        case .flash: "bolt.fill"
        case .sweep: "arrow.left.and.right"
        case .ripple: "dot.radiowaves.left.and.right"
        case .frame: "rectangle.portrait.inset.filled"
        case .dot: "circle.fill"
        case .none: "nosign"
        }
    }

    /// Whether it can stay on screen until the notifications are read.
    var canPersist: Bool { self == .glow || self == .frame || self == .dot }
    /// Whether how strong it is can be chosen.
    var hasIntensity: Bool { self != .none }
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
    var notifyStyle: NotifyStyle
    var notifyEffect: NotifyEffect
    var notifyGlowIntensity: Double
    /// nil = keep glowing until the messages are read.
    var notifyGlowDuration: TimeInterval?
    var notifyBannerPosition: BannerPosition
    var notifySoundID: String
    var notifyVolume: Double
    var quietDuringFocus: Bool

    /// Whether the chosen effect lights the screen's edges.
    var notifyGlow: Bool { notifyEffect == .glow }
    /// Whether it puts a card on screen; without one, a notification waits in the notch instead.
    var notifyBanner: Bool { notifyStyle.showsBanner }
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
            notifyStyle: NotifyStyle(rawValue: d.string(forKey: Pref.notifyStyle) ?? "") ?? .full,
            notifyEffect: NotifyEffect(rawValue: d.string(forKey: Pref.notifyEffect) ?? "") ?? .glow,
            notifyGlowIntensity: d.double(forKey: Pref.notifyGlowIntensity),
            notifyGlowDuration: glowSeconds > 0 ? glowSeconds : nil,
            notifyBannerPosition: BannerPosition(rawValue: d.string(forKey: Pref.notifyBannerPosition) ?? "") ?? .topRight,
            notifySoundID: d.string(forKey: Pref.notifySound) ?? "builtin.ding",
            notifyVolume: d.double(forKey: Pref.notifyVolume),
            quietDuringFocus: d.bool(forKey: Pref.quietDuringFocus),
            quietHours: d.bool(forKey: Pref.quietHoursEnabled)
                ? QuietHours(start: Int(d.double(forKey: Pref.quietHoursStart)), end: Int(d.double(forKey: Pref.quietHoursEnd)))
                : nil,
            importantKeywords: NotificationRules.keywords(from: d.string(forKey: Pref.importantKeywords) ?? ""),
            importantBreaksQuiet: d.bool(forKey: Pref.importantBreaksQuiet)
        )
    }
}
