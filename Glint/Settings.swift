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
    /// How long a card stays up, in seconds; 0 = until it's closed.
    static let notifyBannerSeconds = "notifyBannerSeconds"
    static let notifyPreview = "notifyPreview"
    /// What the island is on screens without a notch: `DrawnNotch`.
    static let drawnNotch = "drawnNotch"
    /// Every app with notifications waiting in the island, side by side, instead of the newest one.
    static let notchShowsAllApps = "notchShowsAllApps"
    /// A notch or island Glint draws itself only shows while notifications are waiting.
    static let notchHidesVirtualWhenEmpty = "notchHidesVirtualWhenEmpty"
    /// How long the pointer rests on the island before it opens, in seconds.
    static let notchHoverDelay = "notchHoverDelay"
    /// How long notifications wait in the notch, in minutes; 0 = until they're read.
    static let notchWaitMinutes = "notchWaitMinutes"
    /// The count on the island's icons.
    static let notchShowsBadges = "notchShowsBadges"
    /// The island grows for a moment when a notification comes, not only when it's hovered.
    static let notchGrowsOnArrival = "notchGrowsOnArrival"
    /// A bubble by the pointer with the app and the sender.
    static let notifyNearPointer = "notifyNearPointer"
    /// Glint says who wrote, aloud.
    static let notifySpeaks = "notifySpeaks"
    /// What it says: `SpeechContent`.
    static let speechContent = "speechContent"
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
        notifyBannerSeconds: 6.0,
        notifyPreview: MessagePreview.full.rawValue,
        drawnNotch: DrawnNotch.island.rawValue,
        notchShowsAllApps: false,
        notchHidesVirtualWhenEmpty: true,
        notchHoverDelay: 0.0,
        notchWaitMinutes: 30.0,
        notchShowsBadges: true,
        notchGrowsOnArrival: true,
        notifyNearPointer: false,
        notifySpeaks: false,
        speechContent: SpeechContent.sender.rawValue,
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
        // Which one screen the island was on; `drawnNotch` now.
        "notchScreen",
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
        // Effects that have been taken out again fall back to the glow.
        if let saved = d.string(forKey: notifyEffect) {
            if NotifyEffect(rawValue: saved) == nil {
                d.set(NotifyEffect.glow.rawValue, forKey: notifyEffect)
            }
            return
        }
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

    /// The notch used to be a card position of its own; it's the top centre now.
    static func migrateBannerPosition(_ d: UserDefaults = .standard) {
        if d.string(forKey: notifyBannerPosition) == BannerPosition.notch.rawValue {
            d.set(BannerPosition.topCenter.rawValue, forKey: notifyBannerPosition)
        }
    }

    /// The island used to go on one screen, the notched one or the main one. Now the notched screen
    /// always has it and the others get what `drawnNotch` says; whoever had a notch drawn on the main
    /// screen keeps a drawn notch.
    static func migrateNotchScreen(_ d: UserDefaults = .standard) {
        guard d.string(forKey: "notchScreen") == "main", d.string(forKey: drawnNotch) == nil else { return }
        d.set(DrawnNotch.notch.rawValue, forKey: drawnNotch)
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

    /// The style with the notch and the card each on or off; with both off nothing shows.
    init(notch: Bool, card: Bool) {
        self = switch (notch, card) {
        case (true, true): .full
        case (true, false): .notch
        case (false, true): .banner
        case (false, false): .none
        }
    }

    var showsBanner: Bool { self == .full || self == .banner }
    /// Whether a notification takes its place in the notch, where it waits to be read.
    var showsNotch: Bool { self == .full || self == .notch }
    /// Whether the notification shows at all, as a card or in the notch.
    var showsMessage: Bool { self != .none }
}

/// What the screen does when a notification comes.
enum NotifyEffect: String, CaseIterable, Identifiable {
    /// Soft light along the screen's edges, in the app's own colour.
    case glow
    /// The screen darkens for a moment; the card and the notch stay bright above it.
    case dim
    /// Nothing on screen.
    case none

    var id: String { rawValue }

    var title: String {
        switch self {
        case .glow: "Işıma"
        case .dim: "Karartma"
        case .none: "Efekt Yok"
        }
    }
}

/// What Glint says aloud for a notification.
enum SpeechContent: String, CaseIterable, Identifiable {
    /// Only which app it's from.
    case app
    /// Who wrote, and in which app.
    case sender
    /// Who wrote, and what.
    case message

    var id: String { rawValue }

    var title: String {
        switch self {
        case .app: "Yalnızca uygulama"
        case .sender: "Gönderen"
        case .message: "Gönderen ve mesaj"
        }
    }

    /// The words for a notification from `app`; `title` and `body` are nil until its text is known.
    func phrase(app: String, title: String?, body: String?) -> String {
        guard self != .app, let title, !title.isEmpty, title != app else { return "Yeni bildirim: \(app)" }
        if self == .message, let body, !body.isEmpty {
            return "\(title): \(body)"
        }
        return "\(title), \(app)"
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

/// How much of a message its card shows, as macOS's own “Önizlemeleri göster” does. Hiding it keeps
/// messages off a shared or watched screen.
enum MessagePreview: String, CaseIterable, Identifiable {
    /// The sender and the message.
    case full
    /// The sender and the message's first line.
    case short
    /// The sender, but not the message.
    case sender
    /// Only the app.
    case hidden

    var id: String { rawValue }

    var title: String {
        switch self {
        case .full: "Tam"
        case .short: "Kısa"
        case .sender: "Gönderen"
        case .hidden: "Gizli"
        }
    }

    /// What a card shows for its title: the sender, or the app's name when it's hidden too.
    func title(_ title: String, app: WatchedApp) -> String {
        self == .hidden ? app.name : title
    }

    /// What a card shows for its message.
    func message(_ message: String) -> String {
        self == .full || self == .short || message.isEmpty ? message : "Yeni bildirim"
    }

    /// How many lines of the title and of the message a card shows.
    var lineLimits: (title: Int, message: Int) {
        self == .short ? (1, 1) : (2, 4)
    }
}

/// What Glint draws for the island on a screen without a notch of its own: an external display, or
/// a Mac that has none. A notched screen always has the island on its notch.
enum DrawnNotch: String, CaseIterable, Identifiable {
    /// A notch like a MacBook's, joined to the screen's top edge.
    case notch
    /// A capsule floating in the menu bar, shorter than a notch.
    case island
    /// Nothing: the island is only on a notched screen.
    case none

    var id: String { rawValue }

    var title: String {
        switch self {
        case .notch: "Çentik"
        case .island: "Ada"
        case .none: "Yok"
        }
    }
}

/// How the notch island behaves, from Çentik / Ada Ayarları.
struct NotchSettings: Equatable {
    var drawn: DrawnNotch = .island
    var showsAllApps = false
    var hidesVirtualWhenEmpty = true
    /// How long the pointer rests on the shrunk island before it opens.
    var hoverDelay: TimeInterval = 0
    /// How long notifications wait in the notch; nil = until they're read.
    var waitingLifetime: TimeInterval? = 30 * 60
    var showsBadges = true
    var growsOnArrival = true
}

enum BannerPosition: String, CaseIterable, Identifiable, Codable {
    case topRight = "topRight"
    case topCenter = "topCenter"
    case topLeft = "topLeft"
    case bottomRight = "bottomRight"
    case bottomCenter = "bottomCenter"
    case bottomLeft = "bottomLeft"
    /// Under the notch, growing out of it. Not a choice of its own: on a Mac with a notch the top centre
    /// is the notch. Glint uses it for the window there, and settings from before still load.
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
    /// nil = a card stays up until it's closed or read.
    var notifyBannerDuration: TimeInterval?
    var notch: NotchSettings
    var notifyPreview: MessagePreview
    var notifyNearPointer: Bool
    var notifySpeaks: Bool
    var speechContent: SpeechContent
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
        let bannerSeconds = d.double(forKey: Pref.notifyBannerSeconds)
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
            notifyBannerDuration: bannerSeconds > 0 ? bannerSeconds : nil,
            notch: NotchSettings(
                drawn: DrawnNotch(rawValue: d.string(forKey: Pref.drawnNotch) ?? "") ?? .island,
                showsAllApps: d.bool(forKey: Pref.notchShowsAllApps),
                hidesVirtualWhenEmpty: d.bool(forKey: Pref.notchHidesVirtualWhenEmpty),
                hoverDelay: d.double(forKey: Pref.notchHoverDelay),
                waitingLifetime: d.double(forKey: Pref.notchWaitMinutes) > 0 ? d.double(forKey: Pref.notchWaitMinutes) * 60 : nil,
                showsBadges: d.bool(forKey: Pref.notchShowsBadges),
                growsOnArrival: d.bool(forKey: Pref.notchGrowsOnArrival)
            ),
            notifyPreview: MessagePreview(rawValue: d.string(forKey: Pref.notifyPreview) ?? "") ?? .full,
            notifyNearPointer: d.bool(forKey: Pref.notifyNearPointer),
            notifySpeaks: d.bool(forKey: Pref.notifySpeaks),
            speechContent: SpeechContent(rawValue: d.string(forKey: Pref.speechContent) ?? "") ?? .sender,
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
