import AppKit
import Observation
import OSLog

/// Ties watched apps' notifications, the user's presence, the on-screen alarm and glow overlay together.
///
/// New notifications come from macOS's notification database when Glint has Full Disk Access: each
/// new record is one notification, with its title and message. Without that permission they're
/// inferred from Dock badges rising. Badges are read either way for the unread counts.
@MainActor
@Observable
final class AlarmController {
    struct AppStatus: Equatable {
        var running: Bool
        var unread: Int
    }

    /// Badges that appear this soon after an app launches are old notifications syncing in, not new ones.
    private static let launchGracePeriod: TimeInterval = 20
    /// A badge that climbs back to its earlier count this soon after dropping is the app flickering
    /// (Teams does it when it's opened), not a new notification.
    private static let flickerWindow: TimeInterval = 2
    /// How often the notification database is checked when it hasn't signalled a change.
    private static let recordCheckInterval: TimeInterval = 1
    /// After a badge rises, how long before noting in the log that no record came for it.
    private static let missingRecordNotice: TimeInterval = 5
    /// Diagnostics (Console.app, subsystem dev.burak.glint). Never logs notification content.
    private static let log = Logger(subsystem: "dev.burak.glint", category: "notifications")

    private(set) var unread = 0
    private(set) var appStatuses: [String: AppStatus] = [:]
    private(set) var userAway = false
    /// Whether Accessibility permission lets us read Dock badges too.
    private(set) var canReadDock = false
    /// Whether Full Disk Access permission lets us read the macOS notification SQLite database directly.
    private(set) var hasFullDiskAccess = false
    private(set) var isPaused = false
    private(set) var lastEvent = "İzleme başladı"

    var menuBarSymbol: String {
        if isPaused { return "bell.slash.fill" }
        if unread > 0 { return "bell.badge.fill" }
        return "bell.fill"
    }

    @ObservationIgnored private let badgeReader = AppBadgeReader()
    @ObservationIgnored private let dbReader = NotificationDatabaseReader.shared
    @ObservationIgnored private let overlay = AlarmOverlay()
    @ObservationIgnored private let glow = GlowOverlay()
    @ObservationIgnored private let bannerOverlay = NotificationBannerOverlay.shared
    @ObservationIgnored private var sleepGuard = SleepGuard()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastAlarmAt = Date.distantPast
    @ObservationIgnored var onUpdate: (() -> Void)?
    /// Last badge count of each watched app. No entry means no baseline yet.
    @ObservationIgnored private var previousAppCounts: [String: Int] = [:]
    /// Each app's most recent badge drop: the count before it and when it happened.
    @ObservationIgnored private var lastBadgeDrop: [String: (from: Int, at: Date)] = [:]
    /// Badges from the notification database, re-read when it changes (or every few seconds).
    @ObservationIgnored private var dbBadges: [String: Int] = [:]
    @ObservationIgnored private var dbBadgesReadAt = Date.distantPast
    @ObservationIgnored private var dbChanged = true
    @ObservationIgnored private var recordsChanged = true
    @ObservationIgnored private var recordsCheckedAt = Date.distantPast
    /// When watching the database started; records delivered before it aren't new.
    @ObservationIgnored private var recordsWatchedSince: Date?
    /// Delivery date of the newest record handled per app; later records are new notifications.
    @ObservationIgnored private var recordWatermark: [String: Date] = [:]
    /// Badge rises no record has come for yet (Full Disk Access mode), for a diagnostic log line.
    @ObservationIgnored private var unmatchedBadgeRise: [String: Date] = [:]

    init() {
        Pref.register()
        AlarmSoundPlayer.notification.prepare(AppSettings.load().notifySoundID)
        // Check 4× a second and react the moment anything changes
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        // React immediately whenever usernoted writes to its database (a new notification)
        dbReader.onDatabaseChange = { [weak self] in
            Task { @MainActor [weak self] in
                self?.dbChanged = true
                self?.recordsChanged = true
                self?.poll()
            }
        }

        // The notch island's settings button.
        bannerOverlay.onOpenSettings = { [weak self] in
            guard let self else { return }
            SettingsWindowManager.shared.show(controller: self)
        }

        poll()
    }

    private func poll() {
        let settings = AppSettings.load()
        AlarmSoundPlayer.notification.prepare(settings.notifySoundID)
        sleepGuard.update(enabled: settings.preventSleep && !isPaused)

        // @Observable notifies on every assignment, so only write values that changed;
        // otherwise the settings window redraws four times a second.
        let away = Presence.isAway(idleThreshold: settings.idleThreshold, lockCountsAsAway: settings.lockCountsAsAway)
        if userAway != away { userAway = away }
        let dockReadable = badgeReader.refreshDock()
        if canReadDock != dockReadable { canReadDock = dockReadable }
        let fda = dbReader.hasFullDiskAccess
        if hasFullDiskAccess != fda { hasFullDiskAccess = fda }
        refreshDatabaseBadges()
        bannerOverlay.configure(position: settings.notifyBannerPosition, enabled: settings.notifyEnabled && settings.notifyBanner)

        if hasFullDiskAccess {
            checkNewRecords(settings: settings)
        } else {
            recordsWatchedSince = nil
            recordWatermark.removeAll()
            unmatchedBadgeRise.removeAll()
        }

        let running = NSWorkspace.shared.runningApplications
        var statuses: [String: AppStatus] = [:]

        for app in WatchedApp.all {
            let config = WatchedAppStore.shared.config(for: app)
            // Dropping the baseline means an app that starts (or is switched back on) with
            // notifications already waiting doesn't report them as new.
            guard config.enabled || config.alarmEnabled else {
                previousAppCounts[app.id] = nil
                continue
            }

            guard let runningApp = app.runningApp(in: running) else {
                // Without a Dock tile, the notification database's badge (Full Disk Access) is all
                // there is; its new records already report the notifications.
                let dbCount = app.bundleIDs.compactMap { dbBadges[$0] }.max() ?? 0
                statuses[app.id] = AppStatus(running: false, unread: dbCount)
                previousAppCounts[app.id] = nil
                continue
            }

            // A running app's Dock badge is its unread count. The database's badge can lag behind
            // or stay high after the app clears it.
            let count = badgeReader.read(runningApp)
            statuses[app.id] = AppStatus(running: true, unread: count)

            if let previous = previousAppCounts[app.id], count != previous {
                let now = Date()
                let justLaunched = runningApp.launchDate.map { now.timeIntervalSince($0) < Self.launchGracePeriod } ?? false
                let flicker = count > previous
                    && lastBadgeDrop[app.id].map { count <= $0.from && now.timeIntervalSince($0.at) < Self.flickerWindow } == true
                Self.log.notice("\(app.id, privacy: .public): badge \(previous) → \(count) fullDiskAccess=\(self.hasFullDiskAccess) justLaunched=\(justLaunched) flicker=\(flicker)")

                if count < previous {
                    lastBadgeDrop[app.id] = (previous, now)
                } else if hasFullDiskAccess {
                    // The notification itself arrives as a database record.
                    if !flicker, !justLaunched, unmatchedBadgeRise[app.id] == nil {
                        unmatchedBadgeRise[app.id] = now
                    }
                } else if !isPaused, !justLaunched, !flicker {
                    handleNewNotification(for: app, config: config, count: count, title: nil, body: nil, settings: settings)
                }
            }
            previousAppCounts[app.id] = count
        }

        guard statuses != appStatuses else { return }
        let previousTotal = unread
        let previousStatuses = appStatuses
        appStatuses = statuses
        unread = statuses.values.reduce(0) { $0 + $1.unread }
        onUpdate?()

        // Once an app's notifications have been read in the app, its banners (and notch icon) go too.
        for (appID, status) in statuses where status.unread == 0 && (previousStatuses[appID]?.unread ?? 0) > 0 {
            bannerOverlay.clear(appID: appID)
        }

        if unread == 0 && previousTotal > 0 && !isPaused {
            glow.dismissIfPersistent()
            overlay.dismiss()
            log("Bildirimler okundu")
        }
    }

    private func refreshDatabaseBadges() {
        guard hasFullDiskAccess else {
            dbBadges = [:]
            return
        }
        guard dbChanged || Date().timeIntervalSince(dbBadgesReadAt) > 5 else { return }
        dbBadges = dbReader.readBadges()
        dbBadgesReadAt = Date()
        dbChanged = false
    }

    /// Handles each record added to macOS's notification database since the last check as a new
    /// notification for its app. usernoted keeps records only for apps whose “Bildirim Merkezi”
    /// option is on.
    private func checkNewRecords(settings: AppSettings) {
        let now = Date()
        guard recordsChanged || now.timeIntervalSince(recordsCheckedAt) >= Self.recordCheckInterval else { return }
        recordsChanged = false
        recordsCheckedAt = now
        let watchedSince = recordsWatchedSince ?? now
        recordsWatchedSince = watchedSince

        let apps = WatchedApp.all.filter {
            let config = WatchedAppStore.shared.config(for: $0)
            return config.enabled || config.alarmEnabled
        }
        let records = dbReader.fetchRecentNotifications(for: apps.flatMap(\.bundleIDs), limit: 50)

        // Oldest first, so banners stack in the order the notifications arrived.
        for record in records.reversed() {
            guard let delivered = record.deliveredDate,
                  let app = apps.first(where: { app in
                      app.bundleIDs.contains { $0.caseInsensitiveCompare(record.bundleID) == .orderedSame }
                  }),
                  delivered > (recordWatermark[app.id] ?? watchedSince)
            else { continue }

            recordWatermark[app.id] = delivered
            unmatchedBadgeRise[app.id] = nil
            guard !isPaused else { continue }

            let title = record.title ?? ""
            let body = record.body ?? ""
            Self.log.notice("\(app.id, privacy: .public): new notification record title=\(!title.isEmpty) body=\(!body.isEmpty)")
            handleNewNotification(
                for: app,
                config: WatchedAppStore.shared.config(for: app),
                count: max(appStatuses[app.id]?.unread ?? 0, 1),
                title: title.isEmpty ? nil : title,
                body: body.isEmpty ? nil : body,
                settings: settings
            )
        }

        for (appID, rose) in unmatchedBadgeRise where now.timeIntervalSince(rose) >= Self.missingRecordNotice {
            unmatchedBadgeRise[appID] = nil
            let known = WatchedApp.find(byID: appID).map { dbReader.hasAppEntry(for: $0.bundleIDs) } ?? false
            Self.log.notice("\(appID, privacy: .public): badge rose but no notification record came within \(Self.missingRecordNotice)s (appInNotificationDatabase=\(known)); is its Bildirim Merkezi option on?")
        }
    }

    /// The alarm (when away) and the glow notification are switched on and off independently.
    /// `title` and `body` come from the notification's record; without them the banner shows the count.
    private func handleNewNotification(for app: WatchedApp, config: WatchedAppConfig, count: Int, title: String?, body: String?, settings: AppSettings) {
        if userAway {
            log("Yeni \(app.name) bildirimi (\(count) okunmamış - uzaktasın)")
            if config.alarmEnabled {
                fireAlarm(unread: count, appName: app.name, settings: settings)
            }
        } else {
            log("Yeni \(app.name) bildirimi (\(count) okunmamış)")
        }

        Self.log.notice("\(app.id, privacy: .public): new notification enabled=\(config.enabled) notifyEnabled=\(settings.notifyEnabled) banner=\(settings.notifyBanner) away=\(self.userAway)")
        guard config.enabled, settings.notifyEnabled else { return }

        // The alarm has its own sound; don't play the notification sound over it.
        let alarmRinging = Date().timeIntervalSince(lastAlarmAt) < settings.alarmDuration
        notify(
            colorHex: config.glowColorHex,
            soundID: config.soundID ?? settings.notifySoundID,
            volume: config.volume ?? settings.notifyVolume,
            settings: settings,
            withSound: !alarmRinging
        )

        guard settings.notifyBanner else { return }
        if title != nil || body != nil {
            bannerOverlay.show(app: app, title: title ?? app.name, body: body ?? "", position: settings.notifyBannerPosition)
        } else {
            bannerOverlay.show(app: app, title: app.name, body: "\(count) okunmamış bildirim", position: settings.notifyBannerPosition)
        }
    }

    private func fireAlarm(unread: Int, appName: String, settings: AppSettings) {
        guard Date().timeIntervalSince(lastAlarmAt) > 5 else { return }
        lastAlarmAt = Date()
        overlay.show(unread: unread, appName: appName, settings: settings)
    }

    private func log(_ message: String) {
        lastEvent = message
    }

    // MARK: - Menu & Settings actions

    func setPaused(_ paused: Bool) {
        isPaused = paused
        if paused {
            overlay.dismiss()
            glow.dismissIfPersistent()
            bannerOverlay.dismiss()
        }
        log(paused ? "Duraklatıldı" : "İzleme devam ediyor")
        onUpdate?()
    }

    func testAlarm(for app: WatchedApp? = nil) {
        let name = app?.name ?? "Test Bildirimi"
        overlay.show(unread: max(unread, 1), appName: name, settings: .load())
    }

    func testBanner(position: BannerPosition? = nil, for app: WatchedApp? = nil) {
        let testApp = app ?? WatchedApp.listed.first ?? WatchedApp.builtIn[0]
        let pos = position ?? AppSettings.load().notifyBannerPosition
        bannerOverlay.show(
            app: testApp,
            title: "\(testApp.name) Bildirimi",
            body: "Bu seçilen konumda (\(pos.title)) örnek bir bildirimdir.",
            position: pos
        )
    }

    func testNotification(for app: WatchedApp? = nil) {
        var settings = AppSettings.load()
        settings.notifyEnabled = true
        settings.notifyGlowDuration = settings.notifyGlowDuration ?? 4

        var colorHex = Pref.teamsPurpleHex
        var soundID = settings.notifySoundID
        var volume = settings.notifyVolume
        if let app {
            let config = WatchedAppStore.shared.config(for: app)
            colorHex = config.glowColorHex
            soundID = config.soundID ?? soundID
            volume = config.volume ?? volume
        }

        notify(colorHex: colorHex, soundID: soundID, volume: volume, settings: settings, withSound: true)

        if settings.notifyBanner {
            testBanner(position: settings.notifyBannerPosition, for: app)
        }
    }

    private func notify(colorHex: String, soundID: String, volume: Double, settings: AppSettings, withSound: Bool) {
        guard settings.notifyEnabled else { return }
        if settings.notifyGlow {
            glow.show(
                colorHex: colorHex,
                intensity: settings.notifyGlowIntensity,
                duration: settings.notifyGlowDuration
            )
        }
        if withSound {
            AlarmSoundPlayer.notification.playOnce(soundID, volume: volume)
        }
    }
}
