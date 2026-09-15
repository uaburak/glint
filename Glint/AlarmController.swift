import AppKit
import Observation
import OSLog

/// Ties watched apps' notifications, the user's presence, the on-screen alarm and glow overlay together.
///
/// New notifications come from macOS's notification database when Glint has Full Disk Access: each
/// new record is one notification, with its title and message. Without that permission, or while the
/// database can't be read, they're inferred from Dock badges rising. Badges are read either way for
/// the unread counts.
@MainActor
@Observable
final class AlarmController {
    struct AppStatus: Equatable {
        var running: Bool
        var unread: Int
    }

    /// The alarm that rang for a notification while the user was away. Until they touch the keyboard or
    /// mouse they count as away (waking the display for it resets the idle time), and it repeats if set.
    private struct AwayAlarm {
        let app: WatchedApp
        let important: Bool
        /// Whether the app has shown unread notifications since; only then does reading them end it.
        var sawUnread = false
    }

    /// Badges that appear this soon after an app launches are old notifications syncing in, not new ones.
    private static let launchGracePeriod: TimeInterval = 20
    /// A badge that climbs back to its earlier count this soon after dropping is the app flickering
    /// (Teams does it when it's opened), not a new notification.
    private static let flickerWindow: TimeInterval = 2
    /// How often the notification database is checked when it hasn't signalled a change.
    private static let recordCheckInterval: TimeInterval = 1
    /// usernoted writes several times per notification; a poll this long after the first write
    /// handles them together.
    private static let databaseChangeDelay: TimeInterval = 0.05
    /// How long a badge rise waits for its notification record before the badge itself is notified.
    private static let missingRecordWait: TimeInterval = 5
    /// How long records can't be read before it's reported; a single failure (usernoted busy) isn't a problem.
    private static let databaseFailureNotice: TimeInterval = 10
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
    /// Why Glint keeps quiet right now (no sound, glow or alarm), if it does.
    private(set) var quietReason: QuietReason?
    /// What keeps Glint from working fully, shown in the menu and on the Hakkında page.
    private(set) var healthIssues: [HealthIssue] = []
    private(set) var lastEvent = "İzleme başladı"

    var menuBarSymbol: String {
        if isPaused { return "bell.slash.fill" }
        if !healthIssues.isEmpty { return "exclamationmark.triangle.fill" }
        if quietReason != nil { return "moon.fill" }
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
    @ObservationIgnored private var pollScheduled = false
    @ObservationIgnored private var lastAlarmAt = Date.distantPast
    @ObservationIgnored private var awayAlarm: AwayAlarm?
    /// The app of the latest notification, for the “open latest” shortcut once its banner is gone.
    @ObservationIgnored private var latestNotifiedAppID: String?
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
    /// Delivery date of the newest record handled per watched app; later records are new notifications.
    /// Set when the app starts being watched, so records from before never count.
    @ObservationIgnored private var recordWatermark: [String: Date] = [:]
    /// When a record was last handled per app, so a badge rising just after it doesn't wait for another.
    @ObservationIgnored private var lastRecordAt: [String: Date] = [:]
    /// Badge rises no record has come for yet (Full Disk Access mode).
    @ObservationIgnored private var unmatchedBadgeRise: [String: Date] = [:]
    /// Since when the database's records can't be read; meanwhile badges report new notifications.
    @ObservationIgnored private var recordsFailingSince: Date?
    /// Apps whose badge rose without a record while they have no records at all.
    @ObservationIgnored private var appsWithoutRecords: Set<String> = []

    init() {
        Pref.register()
        AlarmSoundPlayer.notification.prepare(AppSettings.load().notifySoundID)
        // Check 4× a second and react the moment anything changes
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        // React right away whenever usernoted writes to its database (a new notification)
        dbReader.onDatabaseChange = { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.dbChanged = true
                self.recordsChanged = true
                self.schedulePoll()
            }
        }

        // The notch island's settings button.
        bannerOverlay.onOpenSettings = { [weak self] in
            guard let self else { return }
            SettingsWindowManager.shared.show(controller: self)
        }

        poll()
    }

    private func schedulePoll() {
        guard !pollScheduled else { return }
        pollScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.databaseChangeDelay) { [weak self] in
            MainActor.assumeIsolated {
                self?.pollScheduled = false
                self?.poll()
            }
        }
    }

    private func poll() {
        let settings = AppSettings.load()
        AlarmSoundPlayer.notification.prepare(settings.notifySoundID)
        sleepGuard.update(enabled: settings.preventSleep && !isPaused)

        let apps = WatchedApp.all
        let watched = apps.filter { WatchedAppStore.shared.config(for: $0).isWatched }

        // @Observable notifies on every assignment, so only write values that changed;
        // otherwise the settings window redraws four times a second.
        let away = checkPresence(settings: settings)
        if userAway != away { userAway = away }
        let runningBundleIDs = watched.flatMap(\.bundleIDs).filter { RunningApps.app(withBundleID: $0) != nil }
        let dockReadable = badgeReader.refreshDock(watching: Set(runningBundleIDs))
        if canReadDock != dockReadable { canReadDock = dockReadable }
        let fda = dbReader.hasFullDiskAccess
        if hasFullDiskAccess != fda { hasFullDiskAccess = fda }
        refreshDatabaseBadges()
        bannerOverlay.configure(position: settings.notifyBannerPosition, enabled: settings.notifyEnabled && settings.notifyBanner)
        updateQuiet(settings: settings)

        if hasFullDiskAccess {
            checkNewRecords(apps: watched, settings: settings)
        } else {
            recordWatermark.removeAll()
            unmatchedBadgeRise.removeAll()
            recordsFailingSince = nil
            appsWithoutRecords.removeAll()
        }
        // Notifications come from the database's records, or from badges while those can't be read.
        let recordMode = hasFullDiskAccess && recordsFailingSince == nil

        var statuses: [String: AppStatus] = [:]
        var readPIDs = Set<pid_t>()

        for app in apps {
            let config = WatchedAppStore.shared.config(for: app)
            // Dropping the baseline means an app that starts (or is switched back on) with
            // notifications already waiting doesn't report them as new.
            guard config.isWatched else {
                previousAppCounts[app.id] = nil
                recordWatermark[app.id] = nil
                appsWithoutRecords.remove(app.id)
                continue
            }

            guard let runningApp = app.runningApp else {
                // Without a Dock tile, the notification database's badge (Full Disk Access) is all
                // there is; its new records already report the notifications.
                let dbCount = app.bundleIDs.compactMap { dbBadges[$0] }.max() ?? 0
                statuses[app.id] = AppStatus(running: false, unread: dbCount)
                previousAppCounts[app.id] = nil
                continue
            }

            // A running app's Dock badge is its unread count. The database's badge can lag behind
            // or stay high after the app clears it.
            let count = badgeReader.read(runningApp, bundleIDs: app.bundleIDs)
            readPIDs.insert(runningApp.processIdentifier)
            statuses[app.id] = AppStatus(running: true, unread: count)

            if let previous = previousAppCounts[app.id], count != previous {
                let now = Date()
                let justLaunched = runningApp.launchDate.map { now.timeIntervalSince($0) < Self.launchGracePeriod } ?? false
                let flicker = count > previous
                    && lastBadgeDrop[app.id].map { count <= $0.from && now.timeIntervalSince($0.at) < Self.flickerWindow } == true
                Self.log.notice("\(app.id, privacy: .public): badge \(previous) → \(count) recordMode=\(recordMode) justLaunched=\(justLaunched) flicker=\(flicker)")

                if count < previous {
                    lastBadgeDrop[app.id] = (previous, now)
                } else if recordMode {
                    // The notification itself arrives as a database record, possibly just before the badge.
                    let recordJustCame = lastRecordAt[app.id].map { now.timeIntervalSince($0) < Self.missingRecordWait } ?? false
                    if !flicker, !justLaunched, !recordJustCame, unmatchedBadgeRise[app.id] == nil {
                        unmatchedBadgeRise[app.id] = now
                    }
                } else if !isPaused, !justLaunched, !flicker {
                    handleNewNotification(for: app, config: config, count: count, settings: settings)
                }
            }
            previousAppCounts[app.id] = count
        }
        badgeReader.forgetApps(except: readPIDs)
        repeatAlarmIfNeeded(statuses: statuses, settings: settings)
        updateHealth()

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

    /// Away while the screen is locked (if that counts) or input has been idle long enough, and after an
    /// alarm until the keyboard or mouse is touched.
    private func checkPresence(settings: AppSettings) -> Bool {
        let locked = settings.lockCountsAsAway && Presence.isScreenLocked()
        let idle = Presence.idleSeconds()
        if awayAlarm != nil, !locked, idle + 1 < Date().timeIntervalSince(lastAlarmAt) {
            awayAlarm = nil
        }
        return locked || idle >= settings.idleThreshold || awayAlarm != nil
    }

    private func updateQuiet(settings: AppSettings) {
        let reason: QuietReason? = if settings.quietDuringFocus, hasFullDiskAccess, FocusState.isOn() {
            .focus
        } else if settings.quietHours?.contains(Date()) == true {
            .quietHours
        } else {
            nil
        }
        guard reason != quietReason else { return }
        quietReason = reason
        log(reason.map { "Sessiz mod: \($0.title)" } ?? "Sessiz mod bitti")
        onUpdate?()
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
    /// option is on; a badge that rises with no record is notified by itself.
    private func checkNewRecords(apps: [WatchedApp], settings: AppSettings) {
        let now = Date()
        // Only what's delivered after an app starts being watched is new: not the records from before
        // Glint started, from before the app was added, or from while it was switched off.
        for app in apps where recordWatermark[app.id] == nil {
            recordWatermark[app.id] = now
        }
        guard recordsChanged || now.timeIntervalSince(recordsCheckedAt) >= Self.recordCheckInterval else { return }
        recordsChanged = false
        recordsCheckedAt = now

        guard let records = dbReader.fetchRecentNotifications(for: apps.flatMap(\.bundleIDs), limit: 50) else {
            if recordsFailingSince == nil {
                recordsFailingSince = now
                Self.log.error("notification records can't be read; badges report new notifications meanwhile")
            }
            return
        }
        if recordsFailingSince != nil {
            recordsFailingSince = nil
            Self.log.notice("notification records can be read again")
            // Badges stood in meanwhile; only what's delivered from now on is new.
            for app in apps { recordWatermark[app.id] = now }
            unmatchedBadgeRise.removeAll()
        }

        // Oldest first, so banners stack in the order the notifications arrived.
        for record in records.reversed() {
            guard let delivered = record.deliveredDate,
                  let app = apps.first(where: { app in
                      app.bundleIDs.contains { $0.caseInsensitiveCompare(record.bundleID) == .orderedSame }
                  }),
                  let watermark = recordWatermark[app.id],
                  delivered > watermark
            else { continue }

            recordWatermark[app.id] = delivered
            lastRecordAt[app.id] = now
            unmatchedBadgeRise[app.id] = nil
            appsWithoutRecords.remove(app.id)
            guard !isPaused else { continue }

            func nonEmpty(_ text: String?) -> String? { text?.isEmpty == false ? text : nil }
            Self.log.notice("\(app.id, privacy: .public): new notification record title=\(nonEmpty(record.title) != nil) body=\(nonEmpty(record.body) != nil)")
            handleNewNotification(
                for: app,
                config: WatchedAppStore.shared.config(for: app),
                count: max(appStatuses[app.id]?.unread ?? 0, 1),
                title: nonEmpty(record.title),
                subtitle: nonEmpty(record.subtitle),
                body: nonEmpty(record.body),
                deliveredDate: delivered,
                settings: settings
            )
        }

        for (appID, rose) in unmatchedBadgeRise where now.timeIntervalSince(rose) >= Self.missingRecordWait {
            unmatchedBadgeRise[appID] = nil
            guard let app = apps.first(where: { $0.id == appID }) else { continue }
            let hasRecords = dbReader.hasRecords(for: app.bundleIDs)
            Self.log.notice("\(appID, privacy: .public): badge rose but no notification record came within \(Self.missingRecordWait)s (appHasRecords=\(hasRecords) badgeFallback=\(settings.badgeFallback))")
            if !hasRecords {
                appsWithoutRecords.insert(appID)
            }
            guard settings.badgeFallback, !isPaused else { continue }
            // A record that turns up late for this badge was delivered before now, so it isn't shown twice.
            recordWatermark[appID] = now
            handleNewNotification(
                for: app,
                config: WatchedAppStore.shared.config(for: app),
                count: max(previousAppCounts[appID] ?? 0, 1),
                settings: settings
            )
        }
    }

    /// The alarm (when away) and the glow notification are switched on and off independently. `title`,
    /// `subtitle` and `body` come from the notification's record; without them the banner shows the count.
    /// While Glint keeps quiet there's no sound, glow or alarm, unless an important word breaks through.
    private func handleNewNotification(
        for app: WatchedApp,
        config: WatchedAppConfig,
        count: Int,
        title: String? = nil,
        subtitle: String? = nil,
        body: String? = nil,
        deliveredDate: Date? = nil,
        settings: AppSettings
    ) {
        let hasText = title != nil || subtitle != nil || body != nil
        let important = hasText && NotificationRules.matches([title, subtitle, body], keywords: settings.importantKeywords)
        let quiet = quietReason != nil && !(important && settings.importantBreaksQuiet)
        // Without the text (no Full Disk Access) there's no telling whether it's important, so the alarm
        // rings: better one too many than a missed one.
        let alarmAllowed = config.alarmEnabled && (!config.alarmOnlyImportant || !hasText || important)

        var notes = ["\(count) okunmamış"]
        if userAway { notes.append("uzaktasın") }
        if important { notes.append("önemli") }
        if quiet, let reason = quietReason { notes.append(reason.title) }
        log("Yeni \(app.name) bildirimi (\(notes.joined(separator: " - ")))")
        latestNotifiedAppID = app.id

        if userAway, alarmAllowed, !quiet {
            awayAlarm = AwayAlarm(app: app, important: important)
            fireAlarm(unread: count, appName: app.name, settings: settings)
        }

        Self.log.notice("\(app.id, privacy: .public): new notification enabled=\(config.enabled) notifyEnabled=\(settings.notifyEnabled) banner=\(settings.notifyBanner) away=\(self.userAway) important=\(important) quiet=\(quiet)")
        guard config.enabled, settings.notifyEnabled else { return }

        if !quiet {
            // The alarm has its own sound; don't play the notification sound over it.
            let alarmRinging = Date().timeIntervalSince(lastAlarmAt) < settings.alarmDuration
            notify(
                colorHex: config.glowColorHex,
                soundID: config.soundID ?? settings.notifySoundID,
                volume: config.volume ?? settings.notifyVolume,
                settings: settings,
                withSound: !alarmRinging
            )
        }

        guard settings.notifyBanner else { return }
        if title != nil || body != nil {
            bannerOverlay.show(app: app, title: title ?? app.name, body: body ?? "", position: settings.notifyBannerPosition, date: deliveredDate ?? Date())
        } else {
            bannerOverlay.show(app: app, title: app.name, body: "\(count) okunmamış bildirim", position: settings.notifyBannerPosition, date: deliveredDate ?? Date())
        }
    }

    private func fireAlarm(unread: Int, appName: String, settings: AppSettings) {
        guard Date().timeIntervalSince(lastAlarmAt) > 5 else { return }
        lastAlarmAt = Date()
        overlay.show(unread: unread, appName: appName, settings: settings)
    }

    /// Rings the away alarm again every so often while its app's notifications stay unread.
    private func repeatAlarmIfNeeded(statuses: [String: AppStatus], settings: AppSettings) {
        guard var alarm = awayAlarm else { return }
        let unread = statuses[alarm.app.id]?.unread ?? 0
        if unread > 0, !alarm.sawUnread {
            alarm.sawUnread = true
            awayAlarm = alarm
        }
        // Over once its notifications are read, or monitoring or the app's alarm is switched off.
        guard !(alarm.sawUnread && unread == 0), !isPaused, WatchedAppStore.shared.config(for: alarm.app).alarmEnabled else {
            awayAlarm = nil
            return
        }
        guard let interval = settings.alarmRepeatInterval,
              Date().timeIntervalSince(lastAlarmAt) >= interval,
              quietReason == nil || (alarm.important && settings.importantBreaksQuiet)
        else { return }
        log("\(alarm.app.name) alarmı yeniden çaldı")
        fireAlarm(unread: max(unread, 1), appName: alarm.app.name, settings: settings)
    }

    private func updateHealth() {
        let defaults = UserDefaults.standard
        if hasFullDiskAccess, !defaults.bool(forKey: Pref.hadFullDiskAccess) {
            defaults.set(true, forKey: Pref.hadFullDiskAccess)
        }
        if canReadDock, !defaults.bool(forKey: Pref.hadAccessibility) {
            defaults.set(true, forKey: Pref.hadAccessibility)
        }

        var issues: [HealthIssue] = []
        if !hasFullDiskAccess, defaults.bool(forKey: Pref.hadFullDiskAccess) {
            issues.append(.fullDiskAccessLost)
        }
        if !canReadDock, defaults.bool(forKey: Pref.hadAccessibility) {
            issues.append(.accessibilityLost)
        }
        if let since = recordsFailingSince, Date().timeIntervalSince(since) >= Self.databaseFailureNotice {
            issues.append(.databaseUnreadable)
        }
        issues += appsWithoutRecords.sorted().map { .notificationCenterOff(appID: $0) }

        guard issues != healthIssues else { return }
        healthIssues = issues
        onUpdate?()
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

    /// Hides a problem that may be on purpose: a permission taken back, or an app whose Bildirim
    /// Merkezi stays off (until its badge rises without a record again).
    func dismiss(_ issue: HealthIssue) {
        switch issue {
        case .fullDiskAccessLost: UserDefaults.standard.set(false, forKey: Pref.hadFullDiskAccess)
        case .accessibilityLost: UserDefaults.standard.set(false, forKey: Pref.hadAccessibility)
        case .notificationCenterOff(let appID): appsWithoutRecords.remove(appID)
        case .databaseUnreadable: break
        }
        updateHealth()
    }

    func perform(_ action: ShortcutAction) {
        switch action {
        case .openLatest:
            if !bannerOverlay.openNewest(), let id = latestNotifiedAppID {
                WatchedApp.find(byID: id)?.openApplication()
            }
        case .clearAll:
            bannerOverlay.dismiss()
            glow.dismiss()
            overlay.dismiss()
        }
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
