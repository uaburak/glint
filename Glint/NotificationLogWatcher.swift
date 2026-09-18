import Foundation
import OSLog

/// Hears the moment macOS shows any app's notification, from the system log.
///
/// Notification Center writes a line the instant it takes a notification in — measured 257 ms after
/// delivery, where its record reaches the database about five seconds later. The line names the app
/// and nothing else: macOS keeps the title and the message out of the log, so this says *that*
/// something arrived, not what it says. That's the same part a Dock badge plays, for the apps that
/// don't badge at all (Claude, Antigravity, and anything else that only ever posts notifications).
///
/// It runs `log stream` with a predicate narrow enough to cost nothing measurable (0.0% CPU over
/// eighteen minutes in testing).
@MainActor
final class NotificationLogWatcher {
    /// Called with the app's bundle identifier the moment one of its notifications is shown.
    var onDelivery: ((String) -> Void)?

    /// Notification Center's own line, which carries the bundle identifier twice; the one after
    /// "from app" is the app that posted it.
    private static let predicate = #"subsystem == "com.apple.unc" AND eventMessage CONTAINS "addOrUpdate listItem:""#
    private static let marker = "from app "
    /// After the stream stops (log restarted, machine woke), it's started again after this long.
    private static let restartDelay: TimeInterval = 2

    private static let log = Logger(subsystem: "dev.burak.glint", category: "notifications")

    private var enabled = false
    private var process: Process?
    private var pipe: Pipe?
    private var restartWork: DispatchWorkItem?

    func update(enabled: Bool) {
        guard enabled != self.enabled else {
            if enabled, process?.isRunning != true { start() }
            return
        }
        self.enabled = enabled
        if enabled { start() } else { stop() }
    }

    // MARK: - The stream

    private func start() {
        stop()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = ["stream", "--style", "compact", "--predicate", Self.predicate]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            let bundleIDs = text.split(whereSeparator: \.isNewline).compactMap(Self.bundleID(inLine:))
            guard !bundleIDs.isEmpty else { return }
            Task { @MainActor [weak self] in
                guard let self, self.enabled else { return }
                for bundleID in bundleIDs {
                    self.onDelivery?(bundleID)
                }
            }
        }

        process.terminationHandler = { _ in
            Task { @MainActor [weak self] in self?.streamEnded() }
        }

        do {
            try process.run()
        } catch {
            Self.log.error("notification log stream couldn't start: \(error.localizedDescription, privacy: .public)")
            scheduleRestart()
            return
        }
        self.process = process
        self.pipe = pipe
    }

    private func streamEnded() {
        guard enabled else { return }
        Self.log.notice("notification log stream ended; starting it again")
        scheduleRestart()
    }

    private func scheduleRestart() {
        restartWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.enabled else { return }
                self.start()
            }
        }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.restartDelay, execute: work)
    }

    private func stop() {
        restartWork?.cancel()
        restartWork = nil
        pipe?.fileHandleForReading.readabilityHandler = nil
        pipe = nil
        if let process, process.isRunning {
            process.terminationHandler = nil
            process.terminate()
        }
        process = nil
    }

    /// The app in one of Notification Center's lines:
    /// `addOrUpdate listItem: <app>:<id>:<id> from app <app>, canDisplayWhileCenterIsClosed: …`
    static func bundleID(inLine line: some StringProtocol) -> String? {
        guard let start = line.range(of: marker) else { return nil }
        let rest = line[start.upperBound...]
        let bundleID = rest.prefix { !$0.isWhitespace && $0 != "," }
        guard bundleID.contains("."), bundleID.count > 3 else { return nil }
        return String(bundleID)
    }
}
