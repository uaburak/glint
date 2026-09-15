import Foundation
import SQLite3

/// Reads application unread badge counts and notification records directly from macOS's
/// internal Notification Center database (`group.com.apple.usernoted/db2/db`).
///
/// Requires Full Disk Access (FDA) permission due to macOS TCC privacy protection.
/// If FDA is not granted, this reader gracefully indicates unavailable status.
final class NotificationDatabaseReader: @unchecked Sendable {
    static let shared = NotificationDatabaseReader()

    private static let dbDirectory: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/group.com.apple.usernoted/db2", isDirectory: true)
    }()

    private static let dbURL = dbDirectory.appendingPathComponent("db")
    private static let walURL = dbDirectory.appendingPathComponent("db-wal")

    /// Tells SQLite to copy bound strings: the Swift strings behind them don't outlive the call.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// Called on the main queue whenever `usernoted` writes to the database's write-ahead log.
    var onDatabaseChange: (() -> Void)?

    private var walSource: DispatchSourceFileSystemObject?
    private var lastFDACheckDate = Date.distantPast
    private var cachedFDAStatus = false

    // Cached column availability for dynamic schema compatibility
    private var appTableHasBadge = false
    private var appTableIdentifierCol = "identifier"
    private var schemaInspected = false

    init() {
        startWatchingWAL()
    }

    deinit {
        stopWatchingWAL()
    }

    // MARK: - Permission Check

    /// Checks if Glint has Full Disk Access (FDA) to read the usernoted SQLite database.
    var hasFullDiskAccess: Bool {
        let now = Date()
        if now.timeIntervalSince(lastFDACheckDate) < 2.0 {
            return cachedFDAStatus
        }
        lastFDACheckDate = now

        let fd = open(Self.dbURL.path, O_RDONLY)
        guard fd >= 0 else {
            cachedFDAStatus = false
            return false
        }
        close(fd)
        cachedFDAStatus = true
        if walSource == nil {
            startWatchingWAL()
        }
        return true
    }

    // MARK: - WAL File Monitoring

    /// Watches the SQLite Write-Ahead Log (`db-wal`) for real-time notification events.
    private func startWatchingWAL() {
        stopWatchingWAL()

        let fd = open(Self.walURL.path, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .attrib, .link, .delete, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            // SQLite removes the log once no connection is left and usernoted then starts a new file,
            // so the old one never changes again. `hasFullDiskAccess` watches the new one.
            if !source.data.isDisjoint(with: [.delete, .rename]) {
                self.stopWatchingWAL()
            }
            self.onDatabaseChange?()
        }
        source.setCancelHandler {
            close(fd)
        }
        walSource = source
        source.resume()
    }

    private func stopWatchingWAL() {
        walSource?.cancel()
        walSource = nil
    }

    // MARK: - Opening

    /// Opens the database read-only. A normal open also reads the WAL, where the newest
    /// notifications sit until usernoted checkpoints; `immutable` ignores the WAL and would return
    /// stale badges and records, so it's only a fallback.
    private func openDatabase() -> OpaquePointer? {
        var db: OpaquePointer?
        if sqlite3_open_v2(Self.dbURL.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
           let opened = db {
            sqlite3_busy_timeout(opened, 150)
            if sqlite3_exec(opened, "SELECT 1 FROM sqlite_master LIMIT 1;", nil, nil, nil) == SQLITE_OK {
                inspectSchema(db: opened)
                return opened
            }
        }
        if let db { sqlite3_close(db) }

        var fallback: OpaquePointer?
        let uri = Self.dbURL.absoluteString + "?immutable=1&mode=ro"
        guard sqlite3_open_v2(uri, &fallback, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let opened = fallback else {
            if let fallback { sqlite3_close(fallback) }
            return nil
        }
        inspectSchema(db: opened)
        return opened
    }

    // MARK: - Schema Discovery

    private func inspectSchema(db: OpaquePointer) {
        guard !schemaInspected else { return }
        schemaInspected = true

        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "PRAGMA table_info(app);", -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let nameCol = sqlite3_column_text(stmt, 1) {
                    let colName = String(cString: nameCol).lowercased()
                    if colName == "badge" {
                        appTableHasBadge = true
                    } else if colName == "identifier" || colName == "bundle_id" {
                        appTableIdentifierCol = colName
                    }
                }
            }
            sqlite3_finalize(stmt)
        }
    }

    // MARK: - Read Badges

    /// Reads all unread badge counts recorded in the system notification database.
    /// Returns a map of `bundleIdentifier -> unreadCount`.
    func readBadges() -> [String: Int] {
        guard hasFullDiskAccess, let db = openDatabase() else { return [:] }
        defer { sqlite3_close(db) }
        guard appTableHasBadge else { return [:] }

        var results: [String: Int] = [:]
        let sql = "SELECT \(appTableIdentifierCol), badge FROM app WHERE badge IS NOT NULL;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(stmt) }

        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let idText = sqlite3_column_text(stmt, 0) else { continue }
            let count = parseBadgeColumn(stmt: stmt, columnIndex: 1)
            if count > 0 {
                results[String(cString: idText)] = count
            }
        }
        return results
    }

    private func parseBadgeColumn(stmt: OpaquePointer?, columnIndex: Int32) -> Int {
        switch sqlite3_column_type(stmt, columnIndex) {
        case SQLITE_INTEGER:
            return Int(sqlite3_column_int(stmt, columnIndex))
        case SQLITE_TEXT:
            guard let text = sqlite3_column_text(stmt, columnIndex) else { return 0 }
            return AppBadgeReader.count(fromLabel: String(cString: text))
        case SQLITE_BLOB:
            guard let blob = sqlite3_column_blob(stmt, columnIndex) else { return 0 }
            let length = sqlite3_column_bytes(stmt, columnIndex)
            guard length > 0,
                  let plist = try? PropertyListSerialization.propertyList(from: Data(bytes: blob, count: Int(length)), options: [], format: nil)
            else { return 0 }
            if let num = plist as? Int { return num }
            if let num = plist as? NSNumber { return num.intValue }
            if let str = plist as? String { return AppBadgeReader.count(fromLabel: str) }
            if let dict = plist as? [String: Any], let val = dict["badge"] ?? dict["count"] ?? dict["label"] {
                return AppBadgeReader.count(fromLabelValue: val as CFTypeRef)
            }
            return 0
        default:
            return 0
        }
    }

    // MARK: - Read Notification Records (Title & Body)

    /// The most recent notification records of the apps with any of the given bundle IDs, newest
    /// delivery first. usernoted keeps an app's records only while its “Bildirim Merkezi” option is on.
    /// nil when the records can't be read (no access, or a schema this doesn't know).
    func fetchRecentNotifications(for bundleIDs: [String], limit: Int = 10) -> [NotificationDetails]? {
        guard !bundleIDs.isEmpty else { return [] }
        guard hasFullDiskAccess, let db = openDatabase() else { return nil }
        defer { sqlite3_close(db) }

        let sql = """
            SELECT a.\(appTableIdentifierCol), r.data, r.delivered_date
            FROM record r
            JOIN app a ON r.app_id = a.app_id
            WHERE a.\(appTableIdentifierCol) COLLATE NOCASE IN (\(Self.placeholders(bundleIDs.count)))
            ORDER BY r.delivered_date DESC
            LIMIT \(limit);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        Self.bind(bundleIDs, to: stmt)

        var results: [NotificationDetails] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let matchedBundleID = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
            let dateValue = sqlite3_column_double(stmt, 2)
            // usernoted stores Mac absolute time (seconds since 2001); accept Unix time too. The
            // reading nearer now is the right one: a fixed cutoff (1e9) would flip in 2032, dating
            // every record to 2001 so none would ever count as new.
            let deliveredDate: Date? = dateValue > 0
                ? [Date(timeIntervalSinceReferenceDate: dateValue), Date(timeIntervalSince1970: dateValue)]
                    .min { abs($0.timeIntervalSinceNow) < abs($1.timeIntervalSinceNow) }
                : nil

            var content: (title: String?, subtitle: String?, body: String?) = (nil, nil, nil)
            if let blob = sqlite3_column_blob(stmt, 1) {
                let length = sqlite3_column_bytes(stmt, 1)
                if length > 0 {
                    content = parseNotificationContent(data: Data(bytes: blob, count: Int(length)))
                }
            }

            results.append(NotificationDetails(
                bundleID: matchedBundleID,
                title: content.title,
                subtitle: content.subtitle,
                body: content.body,
                deliveredDate: deliveredDate
            ))
        }
        return results
    }

    /// Whether usernoted keeps any notification record for the app, which it does only while the app's
    /// “Bildirim Merkezi” option is on. True when that can't be told, so no app is suspected for nothing.
    func hasRecords(for bundleIDs: [String]) -> Bool {
        guard hasFullDiskAccess, !bundleIDs.isEmpty, let db = openDatabase() else { return true }
        defer { sqlite3_close(db) }

        let sql = """
            SELECT 1 FROM record r
            JOIN app a ON r.app_id = a.app_id
            WHERE a.\(appTableIdentifierCol) COLLATE NOCASE IN (\(Self.placeholders(bundleIDs.count)))
            LIMIT 1;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return true }
        defer { sqlite3_finalize(stmt) }
        Self.bind(bundleIDs, to: stmt)
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    private static func placeholders(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ", ")
    }

    private static func bind(_ strings: [String], to stmt: OpaquePointer?) {
        for (index, string) in strings.enumerated() {
            sqlite3_bind_text(stmt, Int32(index + 1), string, -1, transient)
        }
    }

    private func parseNotificationContent(data: Data) -> (title: String?, subtitle: String?, body: String?) {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            return (nil, nil, nil)
        }

        // usernoted's record is a plain dictionary with the request's content under "req".
        if let request = plist["req"] as? [String: Any] {
            return (request["titl"] as? String, request["subt"] as? String, request["body"] as? String)
        }

        // Otherwise a keyed archive: look for the content's dictionary among its objects.
        guard let objects = plist["$objects"] as? [Any] else { return (nil, nil, nil) }

        func resolveString(from value: Any?) -> String? {
            if let string = value as? String { return string }
            if let dict = value as? [String: Any], let uid = dict["CF$UID"] as? Int, objects.indices.contains(uid) {
                return objects[uid] as? String
            }
            return nil
        }

        for case let dict as [String: Any] in objects {
            let title = resolveString(from: dict["titl"] ?? dict["title"])
            let body = resolveString(from: dict["body"] ?? dict["message"])
            if title != nil || body != nil {
                return (title, resolveString(from: dict["subt"] ?? dict["subtitle"]), body)
            }
        }
        return (nil, nil, nil)
    }
}

/// A decoded notification record from macOS's SQLite database.
struct NotificationDetails: Sendable {
    let bundleID: String
    let title: String?
    let subtitle: String?
    let body: String?
    let deliveredDate: Date?
}
