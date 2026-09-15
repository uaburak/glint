import AppKit
import IOKit
import IOKit.pwr_mgt

/// Whether the user is at the Mac: keyboard/mouse idle time and screen lock.
enum Presence {
    /// Seconds since the last keyboard, mouse or trackpad input.
    static func idleSeconds() -> TimeInterval {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        guard service != 0 else { return 0 }
        defer { IOObjectRelease(service) }
        guard let value = IORegistryEntryCreateCFProperty(service, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() else { return 0 }
        if let number = value as? NSNumber {
            return TimeInterval(number.uint64Value) / 1_000_000_000
        }
        if let data = value as? Data, data.count >= 8 {
            let nanos = data.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
            return TimeInterval(nanos) / 1_000_000_000
        }
        return 0
    }

    static func isScreenLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (session["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }

    static func isAway(idleThreshold: TimeInterval, lockCountsAsAway: Bool) -> Bool {
        (lockCountsAsAway && isScreenLocked()) || idleSeconds() >= idleThreshold
    }
}

/// Keeps the Mac from idle-sleeping while monitoring is on (the display may still sleep).
/// Closing a laptop lid still sleeps the Mac; no app can prevent that.
final class SleepGuard {
    private var assertion: IOPMAssertionID = 0

    func update(enabled: Bool) {
        if enabled, assertion == 0 {
            IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Glint: mesajlar izleniyor" as CFString,
                &assertion
            )
        } else if !enabled, assertion != 0 {
            IOPMAssertionRelease(assertion)
            assertion = 0
        }
    }
}

enum Display {
    /// Turns a sleeping display back on. Only called when it is actually asleep,
    /// because declaring user activity also resets the idle timer.
    static func wakeIfAsleep() {
        guard CGDisplayIsAsleep(CGMainDisplayID()) != 0 else { return }
        var id: IOPMAssertionID = 0
        IOPMAssertionDeclareUserActivity("Glint alarm" as CFString, kIOPMUserActiveLocal, &id)
    }
}

/// System output volume through AppleScript's Standard Additions.
enum SystemVolume {
    static func get() -> (volume: Int, muted: Bool)? {
        guard let volume = run("output volume of (get volume settings)"),
              let muted = run("output muted of (get volume settings)") else { return nil }
        return (Int(volume.int32Value), muted.booleanValue)
    }

    static func set(volume: Int, muted: Bool) {
        _ = run("set volume output volume \(max(0, min(100, volume))) \(muted ? "with" : "without") output muted")
    }

    private static func run(_ source: String) -> NSAppleEventDescriptor? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        return error == nil ? result : nil
    }
}
