import AppKit
import Sparkle

/// Glint's updates, through Sparkle. Once a day Glint reads the appcast attached to the latest
/// GitHub release (`SUFeedURL` in Info.plist) and offers any newer version; the download is
/// installed only if it carries the signature of the key whose public half is `SUPublicEDKey`.
/// Releases are made with Tools/release.sh.
@MainActor
@Observable
final class AppUpdater: NSObject {
    static let shared = AppUpdater()

    /// An update a scheduled check found while the user was busy. Rather than putting Sparkle's
    /// window up behind whatever they're doing, Glint lists it in the menu and on the settings
    /// page until they look at it.
    private(set) var pendingVersion: String?
    /// False while a check or an update is already under way.
    private(set) var canCheck = false
    private(set) var lastCheck: Date?
    var automaticallyChecks = false {
        didSet {
            guard let updater, updater.automaticallyChecksForUpdates != automaticallyChecks else { return }
            updater.automaticallyChecksForUpdates = automaticallyChecks
        }
    }

    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var canCheckObservation: NSKeyValueObservation?

    private var updater: SPUUpdater? { controller?.updater }

    /// "1.2 (7)", from the running bundle.
    var currentVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }

    /// Starts the schedule: the first check comes a day after the previous one, or soon after
    /// launch if that's overdue.
    func start() {
        guard controller == nil else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
        self.controller = controller
        let updater = controller.updater
        automaticallyChecks = updater.automaticallyChecksForUpdates
        lastCheck = updater.lastUpdateCheckDate
        canCheck = updater.canCheckForUpdates
        canCheckObservation = updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] updater, _ in
            MainActor.assumeIsolated { self?.canCheck = updater.canCheckForUpdates }
        }
    }

    /// Checks now and shows the result, or brings an update that's already been found forward.
    func checkForUpdates() {
        // A menu bar app isn't active, and Sparkle's window would open behind the frontmost app.
        NSApp.activate(ignoringOtherApps: true)
        updater?.checkForUpdates()
    }
}

extension AppUpdater: SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        #if DEBUG
        // An Xcode build shares the release's bundle ID, so a scheduled check would offer to
        // replace it with the published version. "Şimdi Denetle" still works, for testing.
        if updateCheck == .updatesInBackground {
            throw CocoaError(.userCancelled)
        }
        #endif
    }

    /// Also when an update is found: its session stays open until the user deals with it.
    func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) {
        lastCheck = updater.lastUpdateCheckDate
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        lastCheck = updater.lastUpdateCheckDate
    }
}

extension AppUpdater: @preconcurrency SPUStandardUserDriverDelegate {
    /// Sparkle asks a background app to say how it reminds the user of a found update.
    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Sparkle shows the update itself only when it can do so in focus: shortly after launch, or
    /// when the Mac has been idle. Otherwise Glint shows it in the menu.
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        if !handleShowingUpdate {
            pendingVersion = update.displayVersionString
        }
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        pendingVersion = nil
    }

    func standardUserDriverWillFinishUpdateSession() {
        pendingVersion = nil
    }
}
