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
    /// How long a banner shown from a badge waits for the notification's record to fill in the sender
    /// and the message. macOS writes a record seconds after the notification, sometimes much later.
    private static let recordFillInWindow: TimeInterval = 30
    /// How long records can't be read before it's reported; a single failure (usernoted busy) isn't a problem.
    private static let databaseFailureNotice: TimeInterval = 10
    /// How long a message read from an app's own database stands in for the badge rise that follows it.
    private static let instantBadgeWindow: TimeInterval = 5
    /// How far apart their delivery times may be for a record to be that same message. macOS's record
    /// carries the time it delivered the notification, a moment after the app stored the message.
    private static let instantRecordWindow: TimeInterval = 60
    /// How long such a message is remembered, so a late record is still recognised.
    private static let instantEchoLifetime: TimeInterval = 120
    /// How long an announcement stands in for the system log's line about that same notification,
    /// which Notification Center writes about a quarter of a second after it shows it.
    private static let deliverySignalWindow: TimeInterval = 3
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
    /// A notification a signal reported, waiting for its record to say who it's from and what it says.
    private struct PendingBanner {
        /// The notch item put up for it, when it was announced before its text; nil otherwise.
        let itemID: UUID?
        /// Whether it was already announced (glow, sound, island), so its record doesn't announce again.
        let announced: Bool
        /// Whether macOS's own log said it was shown — then a notification certainly went up, and one
        /// whose record never comes is still worth reporting late. A badge can rise without any
        /// notification at all (a muted chat, messages read elsewhere), so those are left alone.
        let fromLog: Bool
        let at: Date
    }

    /// Per app, oldest first: the messages its badge counted whose records haven't turned up yet.
    @ObservationIgnored private var pendingBadgeBanners: [String: [PendingBanner]] = [:]
    /// WhatsApp keeps its own messages, which it stores the moment they arrive: seconds before macOS
    /// writes their notification records, and even when it never writes one.
    @ObservationIgnored private let whatsapp = WhatsAppMessageSource()
    /// Teams keeps its chats the same way, in its embedded browser's store.
    @ObservationIgnored private let teams = TeamsMessageSource()
    /// macOS's own word that it has just shown a notification: the instant signal for the apps whose
    /// Dock icon never carries a badge (Claude, Antigravity and the like).
    @ObservationIgnored private let deliveryLog = NotificationLogWatcher()

    /// A notification Glint has already announced, and which of the other signals for it have been
    /// through. macOS tells Glint about the same notification three ways — the app's own database,
    /// the app's Dock badge, and the system log the moment Notification Center shows it — and each
    /// notification must be announced exactly once.
    private struct Announcement {
        /// When Glint announced it.
        let at: Date
        /// When the app says the message arrived; only the app's own database knows that.
        let delivered: Date?
        /// Whether its text is already on screen, so macOS's record has nothing to add.
        let hasContent: Bool
        var badgeSeen = false
        var logSeen = false
        var recordSeen = false
    }

    /// Per app, oldest first: what has been announced, until every signal for it has been through.
    @ObservationIgnored private var announcements: [String: [Announcement]] = [:]
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

        // WhatsApp stores a message itself the moment it arrives, so its notification doesn't have to
        // wait for macOS's record.
        whatsapp.onMessage = { [weak self] message in
            self?.handleInstantMessage(message)
        }
        teams.onMessage = { [weak self] message in
            self?.handleInstantMessage(message)
        }
        deliveryLog.onDelivery = { [weak self] bundleID in
            self?.handleDeliverySignal(bundleID: bundleID)
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
        // Apps that keep their own messages report them here, ahead of macOS. Reading them needs the
        // same Full Disk Access; without it only macOS's records are left.
        let whatsappWatched = watched.contains { $0.bundleIDs.contains(WhatsAppMessageSource.bundleID) }
        whatsapp.update(enabled: hasFullDiskAccess && whatsappWatched && !isPaused)
        whatsapp.check()
        let teamsWatched = watched.contains { $0.bundleIDs.contains(TeamsMessageSource.bundleID) }
        teams.update(enabled: hasFullDiskAccess && teamsWatched && !isPaused)
        teams.check()
        deliveryLog.update(enabled: !isPaused && settings.notifyEnabled && !watched.isEmpty)
        bannerOverlay.configure(position: settings.notifyBannerPosition, enabled: settings.notifyEnabled && settings.notifyStyle.showsMessage, notch: settings.notifyStyle.showsNotch)
        updateQuiet(settings: settings)

        if hasFullDiskAccess {
            checkNewRecords(apps: watched, settings: settings)
        } else {
            recordWatermark.removeAll()
            pendingBadgeBanners.removeAll()
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
                } else if !isPaused, !justLaunched, !flicker {
                    // A message in the conversation the user is reading is on their screen already, and
                    // its badge clears itself a moment later.
                    let inUse = ActiveConversation.isInUse(app)
                    // A badge only counts; the notification itself goes up once its record says who
                    // wrote and what — glow, notch and banner together. Without records to wait for,
                    // the badge is all there will ever be.
                    let waitsForRecord = recordMode
                    // One rise can count several messages; each gets its own place in the queue.
                    let messages = max(count - previous, 1)
                    // Those the app's own database already reported are this rise, not something new.
                    let reported = cover(app.id, \.badgeSeen, limit: messages, within: Self.instantBadgeWindow, now: now)
                    let newMessages = messages - reported
                    Self.log.notice("\(app.id, privacy: .public): badge rise +\(messages) reportedByApp=\(reported) inUse=\(inUse) waitsForRecord=\(waitsForRecord)")

                    if inUse || newMessages <= 0 {
                        // On screen already, or the app's own database has reported it.
                    } else if waitsForRecord {
                        // Queued unannounced: the record reports it, and an app whose records never come
                        // is still reported as a problem. The system log's line for it is this same one.
                        for _ in 0..<newMessages {
                            pendingBadgeBanners[app.id, default: []].append(PendingBanner(itemID: nil, announced: false, fromLog: false, at: now))
                            noteAnnouncement(appID: app.id, at: now, hasContent: false, badgeSeen: true)
                        }
                    } else {
                        // In record mode this is the first half of the notification: the island and the
                        // glow say a message came, and the banner waits for the record to say what it
                        // is. Without records the badge is all there will ever be, so it pops at once.
                        let itemID = handleNewNotification(
                            for: app, config: config, count: count,
                            popsBanner: !recordMode, settings: settings
                        )
                        if recordMode {
                            pendingBadgeBanners[app.id, default: []].append(PendingBanner(itemID: itemID, announced: true, fromLog: false, at: now))
                            for _ in 1..<newMessages {
                                pendingBadgeBanners[app.id, default: []].append(PendingBanner(itemID: nil, announced: true, fromLog: false, at: now))
                            }
                        }
                        // The system log's lines for these are the same notifications, already announced.
                        for _ in 0..<newMessages {
                            noteAnnouncement(appID: app.id, at: now, hasContent: false, badgeSeen: true)
                        }
                    }
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

    /// Handles each record added to macOS's notification database since the last check: the sender and
    /// the message of a notification. A record can be written many seconds after its notification, so
    /// a banner that already went up from the app's badge is filled in here rather than shown again.
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
            pendingBadgeBanners.removeAll()
        }

        // Oldest first, so banners stack in the order the notifications arrived. macOS writes records in
        // batches, so however many of an app's records turn up together, the app is announced once.
        var announced = Set<String>()
        for record in records.reversed() {
            guard let delivered = record.deliveredDate,
                  let app = apps.first(where: { app in
                      app.bundleIDs.contains { $0.caseInsensitiveCompare(record.bundleID) == .orderedSame }
                  }),
                  let watermark = recordWatermark[app.id],
                  delivered > watermark
            else { continue }

            recordWatermark[app.id] = delivered
            appsWithoutRecords.remove(app.id)
            guard !isPaused else { continue }

            // Its app reported this message itself, seconds ago; the record is the same one arriving late.
            if takeContentAnnouncement(for: app.id, delivered: delivered, now: now) {
                Self.log.notice("\(app.id, privacy: .public): record is a message the app already reported")
                continue
            }

            func nonEmpty(_ text: String?) -> String? { text?.isEmpty == false ? text : nil }
            let title = nonEmpty(record.title)
            let subtitle = nonEmpty(record.subtitle)
            let body = nonEmpty(record.body)
            let pending = takeOldestPending(for: app.id, now: now)

            // The conversation is open in front of the user: the message is on their screen already.
            if ActiveConversation.isOnScreen(title: title, subtitle: subtitle, of: app) {
                Self.log.notice("\(app.id, privacy: .public): record is the conversation on screen; not notified")
                continue
            }

            // Its badge already announced it: the record only says who it's from and what it says.
            if let pending, pending.announced {
                Self.log.notice("\(app.id, privacy: .public): record fills in what the badge announced")
                showAnnouncedMessage(title: title, body: body, delivered: delivered, of: app, into: pending.itemID, settings: settings)
                continue
            }
            // Another of this app's records from the same batch.
            if announced.contains(app.id) {
                showAnnouncedMessage(title: title, body: body, delivered: delivered, of: app, into: nil, settings: settings)
                continue
            }
            announced.insert(app.id)

            Self.log.notice("\(app.id, privacy: .public): new notification record title=\(title != nil) body=\(body != nil)")
            handleNewNotification(
                for: app,
                config: WatchedAppStore.shared.config(for: app),
                count: max(appStatuses[app.id]?.unread ?? 0, 1),
                title: title,
                subtitle: subtitle,
                body: body,
                deliveredDate: delivered,
                settings: settings
            )
        }

        // Messages whose records never turned up keep what the badge said. An app that has no records
        // at all is one whose “Bildirim Merkezi” option looks off, which the Hakkında page reports.
        for (appID, queue) in pendingBadgeBanners {
            let expired = queue.filter { now.timeIntervalSince($0.at) >= Self.recordFillInWindow }
            guard !expired.isEmpty else { continue }
            let remaining = queue.filter { now.timeIntervalSince($0.at) < Self.recordFillInWindow }
            pendingBadgeBanners[appID] = remaining.isEmpty ? nil : remaining
            guard let app = apps.first(where: { $0.id == appID }) else { continue }
            let hasRecords = dbReader.hasRecords(for: app.bundleIDs)
            Self.log.notice("\(appID, privacy: .public): \(expired.count) message(s) got no record within \(Self.recordFillInWindow)s (appHasRecords=\(hasRecords))")
            if !hasRecords {
                appsWithoutRecords.insert(appID)
            }
            // macOS showed a notification and never wrote down what it said. Rather than losing it,
            // it goes up late with the unread count. A badge that rose without a notification behind
            // it (a muted chat, messages read on the phone) is left alone.
            let missed = expired.filter { $0.fromLog && !$0.announced }
            if !missed.isEmpty, !isPaused, !ActiveConversation.isInUse(app) {
                Self.log.notice("\(appID, privacy: .public): notifying late from the count; its text never came")
                handleNewNotification(
                    for: app, config: WatchedAppStore.shared.config(for: app),
                    count: max(appStatuses[appID]?.unread ?? 0, missed.count),
                    settings: settings
                )
            }
        }
    }

    /// The oldest message the app's badge counted that is still waiting for its record, off the queue.
    private func takeOldestPending(for appID: String, now: Date) -> PendingBanner? {
        guard var queue = pendingBadgeBanners[appID] else { return nil }
        queue.removeAll { now.timeIntervalSince($0.at) >= Self.recordFillInWindow }
        let oldest = queue.isEmpty ? nil : queue.removeFirst()
        pendingBadgeBanners[appID] = queue.isEmpty ? nil : queue
        return oldest
    }

    // MARK: - Messages from an app's own database

    /// A message an app stored itself, which Glint reads before macOS has a record for it: the whole
    /// notification at once, sender and text included, instead of a count that fills in seconds later.
    private func handleInstantMessage(_ message: InstantMessage) {
        guard !isPaused,
              let app = WatchedApp.all.first(where: { $0.bundleIDs.contains(message.bundleID) })
        else { return }
        let config = WatchedAppStore.shared.config(for: app)
        guard config.isWatched else { return }

        let now = Date()
        noteAnnouncement(appID: app.id, at: now, delivered: message.date, hasContent: true)

        // The chat the user has open: the app reads it the moment it lands, so its chat keeps no
        // unread count — which is also why macOS writes no record for it.
        if message.chatUnread == 0, ActiveConversation.isInUse(app) {
            Self.log.notice("\(app.id, privacy: .public): app's message is the chat on screen; not notified")
            return
        }
        if ActiveConversation.isOnScreen(title: message.title, subtitle: nil, of: app) {
            Self.log.notice("\(app.id, privacy: .public): app's message is the conversation on screen; not notified")
            return
        }

        let settings = AppSettings.load()
        // The badge can beat it by a moment; then this fills in the sender and the message rather
        // than announcing the same one twice.
        if let pending = takeOldestPending(for: app.id, now: now), pending.announced {
            Self.log.notice("\(app.id, privacy: .public): app's message fills in what the badge announced")
            showAnnouncedMessage(title: message.title, body: message.body, delivered: message.date, thread: message.thread, of: app, into: pending.itemID, settings: settings)
            return
        }

        Self.log.notice("\(app.id, privacy: .public): new message from the app's own database")
        handleNewNotification(
            for: app,
            config: config,
            count: max(appStatuses[app.id]?.unread ?? 0, 1),
            title: message.title,
            body: message.body,
            deliveredDate: message.date,
            thread: message.thread,
            settings: settings
        )
    }

    /// macOS has just shown a notification for this app, as its system log says the moment it happens.
    /// This is the half a Dock badge plays — that something arrived — for apps that never badge; the
    /// text follows from the notification's record a few seconds later.
    private func handleDeliverySignal(bundleID: String) {
        guard !isPaused,
              let app = WatchedApp.all.first(where: { app in
                  app.bundleIDs.contains { $0.caseInsensitiveCompare(bundleID) == .orderedSame }
              })
        else { return }
        let config = WatchedAppStore.shared.config(for: app)
        guard config.isWatched else { return }

        let now = Date()
        // Its own database or its badge has announced this notification already.
        guard cover(app.id, \.logSeen, limit: 1, within: Self.deliverySignalWindow, now: now) == 0 else { return }
        // The user is in the app: the message is in front of them.
        guard !ActiveConversation.isInUse(app) else {
            Self.log.notice("\(app.id, privacy: .public): delivery while the app is in use; not notified")
            return
        }

        let settings = AppSettings.load()
        let recordMode = hasFullDiskAccess && recordsFailingSince == nil
        noteAnnouncement(appID: app.id, at: now, hasContent: false, logSeen: true)

        // A notification is on its way: its record says what it is in a few seconds, and everything
        // goes up then, at once. Only when records can't be read does this report it by itself.
        guard !recordMode else {
            Self.log.notice("\(app.id, privacy: .public): macOS delivered a notification; waiting for its text")
            pendingBadgeBanners[app.id, default: []].append(PendingBanner(itemID: nil, announced: false, fromLog: true, at: now))
            return
        }

        Self.log.notice("\(app.id, privacy: .public): macOS says a notification was delivered (system log)")
        handleNewNotification(
            for: app, config: config, count: max(appStatuses[app.id]?.unread ?? 0, 1),
            settings: settings
        )
    }

    /// Marks up to `limit` of the app's announcements as accounted for by this signal, and says how
    /// many: a badge rise or a log line for a notification already announced isn't a new one.
    private func cover(
        _ appID: String,
        _ flag: WritableKeyPath<Announcement, Bool>,
        limit: Int,
        within window: TimeInterval,
        now: Date
    ) -> Int {
        pruneAnnouncements(now: now)
        guard var list = announcements[appID] else { return 0 }
        var covered = 0
        for index in list.indices where covered < limit {
            guard !list[index][keyPath: flag], now.timeIntervalSince(list[index].at) < window else { continue }
            list[index][keyPath: flag] = true
            covered += 1
        }
        announcements[appID] = list
        return covered
    }

    /// Whether this record is a message its app already reported with its text, which is then off
    /// the queue. Announcements without text aren't matched: their record is what fills them in.
    private func takeContentAnnouncement(for appID: String, delivered: Date, now: Date) -> Bool {
        pruneAnnouncements(now: now)
        guard var list = announcements[appID],
              let index = list.firstIndex(where: {
                  $0.hasContent && !$0.recordSeen
                      && abs(($0.delivered ?? $0.at).timeIntervalSince(delivered)) < Self.instantRecordWindow
              })
        else { return false }
        list[index].recordSeen = true
        announcements[appID] = list
        return true
    }

    /// Notes that Glint has just announced a notification for an app, and which signal did it.
    private func noteAnnouncement(
        appID: String, at: Date, delivered: Date? = nil, hasContent: Bool,
        badgeSeen: Bool = false, logSeen: Bool = false
    ) {
        var announcement = Announcement(at: at, delivered: delivered, hasContent: hasContent)
        announcement.badgeSeen = badgeSeen
        announcement.logSeen = logSeen
        announcements[appID, default: []].append(announcement)
    }

    private func pruneAnnouncements(now: Date) {
        for (appID, list) in announcements {
            let kept = list.filter { now.timeIntervalSince($0.at) < Self.instantEchoLifetime }
            announcements[appID] = kept.isEmpty ? nil : kept
        }
    }

    /// A message whose arrival was already announced: its text goes into the notch item the badge put
    /// up (which then pops out as a banner), or into a banner of its own, with no second glow or sound.
    private func showAnnouncedMessage(title: String?, body: String?, delivered: Date, thread: NotificationThread? = nil, of app: WatchedApp, into itemID: UUID?, settings: AppSettings) {
        guard title != nil || body != nil else { return }
        if let itemID {
            bannerOverlay.fillIn(appID: app.id, itemID: itemID, title: title ?? app.name, body: body ?? "", thread: thread)
        } else if settings.notifyEnabled, settings.notifyStyle.showsMessage, WatchedAppStore.shared.config(for: app).enabled {
            bannerOverlay.show(
                app: app, title: title ?? app.name, body: body ?? "",
                position: settings.notifyBannerPosition, date: delivered, thread: thread,
                popping: settings.notifyStyle.showsBanner, waits: settings.notifyStyle.showsNotch
            )
        }
    }

    /// The alarm (when away) and the glow notification are switched on and off independently. `title`,
    /// `subtitle` and `body` come from the notification's record; without them the banner shows the count
    /// until the record turns up and fills it in. While Glint keeps quiet there's no sound, glow or
    /// alarm, unless an important word breaks through. Returns the banner's id, if one went up.
    @discardableResult
    private func handleNewNotification(
        for app: WatchedApp,
        config: WatchedAppConfig,
        count: Int,
        title: String? = nil,
        subtitle: String? = nil,
        body: String? = nil,
        deliveredDate: Date? = nil,
        thread: NotificationThread? = nil,
        popsBanner: Bool = true,
        settings: AppSettings
    ) -> UUID? {
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
        guard config.enabled, settings.notifyEnabled else { return nil }

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

        // The style decides whether the notification takes its place in the notch and whether a card
        // pops out; the effect-only one shows nothing.
        guard settings.notifyStyle.showsMessage else { return nil }
        let pops = popsBanner && settings.notifyStyle.showsBanner
        let waits = settings.notifyStyle.showsNotch
        if title != nil || body != nil {
            return bannerOverlay.show(app: app, title: title ?? app.name, body: body ?? "", position: settings.notifyBannerPosition, date: deliveredDate ?? Date(), thread: thread, popping: pops, waits: waits)
        } else {
            return bannerOverlay.show(app: app, title: app.name, body: "\(count) okunmamış bildirim", position: settings.notifyBannerPosition, date: deliveredDate ?? Date(), popping: pops, waits: waits)
        }
    }

    /// Puts the chosen effect on screen.
    private func play(effect: NotifyEffect, colorHex: String, settings: AppSettings) {
        switch effect {
        case .none:
            break
        case .glow:
            glow.show(colorHex: colorHex, intensity: settings.notifyGlowIntensity, duration: settings.notifyGlowDuration)
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

    /// A banner from the test page, shown the way the settings would show it: at the chosen position,
    /// in the chosen style. No sound, glow or alarm, so a burst of them can be watched in peace.
    func showTestBanner(app: WatchedApp, title: String, body: String, thread: NotificationThread? = nil) {
        let settings = AppSettings.load()
        guard settings.notifyStyle.showsMessage else { return }
        bannerOverlay.show(
            app: app, title: title, body: body,
            position: settings.notifyBannerPosition, thread: thread,
            popping: settings.notifyStyle.showsBanner,
            waits: settings.notifyStyle.showsNotch
        )
    }

    /// Takes every banner off the screen, and out of the notch.
    func clearBanners() {
        bannerOverlay.dismiss()
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

        if settings.notifyStyle.showsMessage {
            let testApp = app ?? WatchedApp.listed.first ?? WatchedApp.builtIn[0]
            bannerOverlay.show(
                app: testApp,
                title: "\(testApp.name) Bildirimi",
                body: settings.notifyStyle.showsBanner
                    ? "Bu seçilen konumda (\(settings.notifyBannerPosition.title)) örnek bir bildirimdir."
                    : "Çentikte bekleyen örnek bir bildirimdir.",
                position: settings.notifyBannerPosition,
                popping: settings.notifyStyle.showsBanner,
                waits: settings.notifyStyle.showsNotch
            )
        }
    }

    private func notify(colorHex: String, soundID: String, volume: Double, settings: AppSettings, withSound: Bool) {
        guard settings.notifyEnabled else { return }
        play(effect: settings.notifyEffect, colorHex: colorHex, settings: settings)
        if withSound {
            AlarmSoundPlayer.notification.playOnce(soundID, volume: volume)
        }
    }
}
