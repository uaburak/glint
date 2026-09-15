import AppKit
import ApplicationServices

/// Reads running apps' unread counts from their Dock badges.
///
/// Two sources are checked and the higher count wins:
/// 1. LaunchServices' `StatusLabel`, which `NSDockTile.badgeLabel` sets (Teams and most apps).
///    Read in-process through a private function, with the `lsappinfo` CLI as a fallback.
/// 2. The Dock tiles' `AXStatusLabel` through the Accessibility API, which also shows badges
///    set through UserNotifications (e.g. Catalyst apps). Needs Accessibility permission.
final class AppBadgeReader {
    private typealias CreateASN = @convention(c) (CFAllocator?, pid_t) -> Unmanaged<CFTypeRef>?
    private typealias CopyItem = @convention(c) (Int32, CFTypeRef, CFString) -> Unmanaged<CFTypeRef>?

    private static let launchServices: (createASN: CreateASN, copyItem: CopyItem)? = {
        let path = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/LaunchServices"
        guard let handle = dlopen(path, RTLD_NOW),
              let create = dlsym(handle, "_LSASNCreateWithPid"),
              let copy = dlsym(handle, "_LSCopyApplicationInformationItem") else { return nil }
        return (unsafeBitCast(create, to: CreateASN.self), unsafeBitCast(copy, to: CopyItem.self))
    }()

    private var cachedASNs: [pid_t: CFTypeRef] = [:]
    private var cachedCLIASNs: [pid_t: String] = [:]
    private var dockElement: AXUIElement?
    /// Badge count per bundle ID, from the last `refreshDock()`.
    private var dockBadges: [String: Int] = [:]
    /// Dock tile URL → bundle ID ("" for tiles that aren't apps), so each bundle is opened once.
    private var bundleIDs: [URL: String] = [:]

    /// Snapshots the badge of every Dock tile. Call once per poll, before `read`.
    /// Returns false without Accessibility permission; then only LaunchServices is used.
    @discardableResult
    func refreshDock() -> Bool {
        dockBadges.removeAll(keepingCapacity: true)
        guard AXIsProcessTrusted() else { return false }

        var tileGroups = dockElement.flatMap(children)
        if tileGroups == nil {
            // First use, or the Dock restarted: look it up again.
            dockElement = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
                .map { AXUIElementCreateApplication($0.processIdentifier) }
            tileGroups = dockElement.flatMap(children)
        }

        for group in tileGroups ?? [] {
            for tile in children(of: group) ?? [] {
                guard let url = attribute(tile, "AXURL") as? URL else { continue }
                let bundleID = bundleID(for: url)
                guard !bundleID.isEmpty else { continue }
                let count = Self.count(fromLabelValue: attribute(tile, "AXStatusLabel"))
                dockBadges[bundleID] = max(dockBadges[bundleID] ?? 0, count)
            }
        }
        return true
    }

    /// Unread count of a running app: the badge number, 1 for a non-numeric badge, 0 for none.
    func read(_ app: NSRunningApplication) -> Int {
        let dockCount = app.bundleIdentifier.flatMap { dockBadges[$0] } ?? 0
        return max(dockCount, readInProcessOrCLI(app: app) ?? 0)
    }

    // MARK: - Dock AXStatusLabel

    private func bundleID(for url: URL) -> String {
        if let cached = bundleIDs[url] { return cached }
        let bundleID = Bundle(url: url)?.bundleIdentifier ?? ""
        bundleIDs[url] = bundleID
        return bundleID
    }

    private func children(of element: AXUIElement) -> [AXUIElement]? {
        attribute(element, kAXChildrenAttribute) as? [AXUIElement]
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    // MARK: - Label Parsing

    static func count(fromLabelValue value: CFTypeRef?) -> Int {
        guard let value else { return 0 }
        if let number = value as? Int { return number }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return count(fromLabel: string) }
        return 1
    }

    /// `"3"` → 3; no badge (nil or empty) → 0.
    static func count(fromLabel label: String?) -> Int {
        guard let label, !label.isEmpty else { return 0 }
        if let number = Int(label.prefix(while: \.isNumber)) { return number }
        return 1 // A non-numeric badge (e.g. "•") still means something is unread.
    }

    /// lsappinfo output: `{ "LSASN"=ASN:0x0-0x37037:, "StatusLabel"={ "label"="3" } }` → 3.
    static func parse(_ info: String) -> Int {
        guard let range = info.range(of: #""label"="[^"]*""#, options: .regularExpression) else { return 0 }
        return count(fromLabel: String(info[range].dropFirst(#""label"=""#.count).dropLast()))
    }

    // MARK: - LaunchServices

    private func readInProcessOrCLI(app: NSRunningApplication) -> Int? {
        if let launchServices = Self.launchServices {
            return readInProcess(app.processIdentifier, launchServices)
        }
        return readWithCLI(app)
    }

    private func readInProcess(_ pid: pid_t, _ launchServices: (createASN: CreateASN, copyItem: CopyItem)) -> Int? {
        var asn = cachedASNs[pid]
        if asn == nil {
            guard let created = launchServices.createASN(nil, pid)?.takeRetainedValue() else { return nil }
            cachedASNs[pid] = created
            asn = created
        }
        guard let validASN = asn else { return nil }
        let item = launchServices.copyItem(-2, validASN, "StatusLabel" as CFString)?.takeRetainedValue()
        return Self.count(fromLabel: (item as? [String: Any])?["label"] as? String)
    }

    private func readWithCLI(_ app: NSRunningApplication) -> Int? {
        let pid = app.processIdentifier
        let asn: String
        if let cached = cachedCLIASNs[pid] {
            asn = cached
        } else {
            guard let bundleID = app.bundleIdentifier,
                  let found = Self.lsappinfo(["find", "bundleid=\(bundleID)"]),
                  let range = found.range(of: "ASN:0x[0-9a-f]+-0x[0-9a-f]+", options: .regularExpression)
            else { return nil }
            asn = String(found[range]) + ":"
            cachedCLIASNs[pid] = asn
        }
        guard let info = Self.lsappinfo(["-all", "info", "-only", "StatusLabel", asn]) else { return nil }
        return Self.parse(info)
    }

    private static func lsappinfo(_ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/lsappinfo")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
