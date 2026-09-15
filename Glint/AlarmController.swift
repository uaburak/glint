import AppKit
import Observation

/// Ties watched apps' badges, the user's presence, the on-screen alarm and glow overlay together.
@MainActor
@Observable
final class AlarmController {
    struct AppStatus: Equatable {
        var running: Bool
        var unread: Int
    }

    /// Badges that appear this soon after an app launches are old notifications syncing in, not new ones.
    private static let launchGracePeriod: TimeInterval = 20

    private(set) var unread = 0
    private(set) var appStatuses: [String: AppStatus] = [:]
    private(set) var userAway = false
    /// Whether Accessibility permission lets us read Dock badges too.
    private(set) var canReadDock = false
    private(set) var isPaused = false
    private(set) var lastEvent = "İzleme başladı"

    var menuBarSymbol: String {
        if isPaused { return "bell.slash.fill" }
        if unread > 0 { return "bell.badge.fill" }
        return "bell.fill"
    }

    @ObservationIgnored private let badgeReader = AppBadgeReader()
    @ObservationIgnored private let overlay = AlarmOverlay()
    @ObservationIgnored private let glow = GlowOverlay()
    @ObservationIgnored private var sleepGuard = SleepGuard()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastAlarmAt = Date.distantPast
    @ObservationIgnored var onUpdate: (() -> Void)?
    /// Last badge count of each watched, running app. No entry means no baseline yet.
    @ObservationIgnored private var previousAppCounts: [String: Int] = [:]

    init() {
        Pref.register()
        AlarmSoundPlayer.notification.prepare(AppSettings.load().notifySoundID)
        // Check badges 4× a second and react the moment any badge changes
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
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
                statuses[app.id] = AppStatus(running: false, unread: 0)
                previousAppCounts[app.id] = nil
                continue
            }

            let count = badgeReader.read(runningApp)
            statuses[app.id] = AppStatus(running: true, unread: count)

            let justLaunched = runningApp.launchDate.map { Date().timeIntervalSince($0) < Self.launchGracePeriod } ?? false
            if let previous = previousAppCounts[app.id], count > previous, !isPaused, !justLaunched {
                handleNewNotification(for: app, config: config, count: count, settings: settings)
            }
            previousAppCounts[app.id] = count
        }

        guard statuses != appStatuses else { return }
        let previousTotal = unread
        appStatuses = statuses
        unread = statuses.values.reduce(0) { $0 + $1.unread }
        onUpdate?()

        if unread == 0 && previousTotal > 0 && !isPaused {
            glow.dismissIfPersistent()
            overlay.dismiss()
            log("Bildirimler okundu")
        }
    }

    /// The alarm (when away) and the glow notification are switched on and off independently.
    private func handleNewNotification(for app: WatchedApp, config: WatchedAppConfig, count: Int, settings: AppSettings) {
        if userAway {
            log("Yeni \(app.name) bildirimi (\(count) okunmamış - uzaktasın)")
            if config.alarmEnabled {
                fireAlarm(unread: count, appName: app.name, settings: settings)
            }
        } else {
            log("Yeni \(app.name) bildirimi (\(count) okunmamış)")
        }

        guard config.enabled else { return }
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
        }
        log(paused ? "Duraklatıldı" : "İzleme devam ediyor")
        onUpdate?()
    }

    func testAlarm(for app: WatchedApp? = nil) {
        let name = app?.name ?? "Test Bildirimi"
        overlay.show(unread: max(unread, 1), appName: name, settings: .load())
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
