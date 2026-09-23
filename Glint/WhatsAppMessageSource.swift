import Foundation
import SQLite3

/// The conversation a notification belongs to: what groups it with the rest of that chat in a stack,
/// and, where the app can be pointed at a chat, the address that opens it.
struct NotificationThread: Hashable, Sendable {
    /// The app's own id for the chat: a WhatsApp JID, a Teams conversation id.
    let id: String
    /// Opens the chat in its app. Nil where the app has no such address (a WhatsApp group): then the
    /// app itself opens.
    let url: URL?
}

/// A message an app wrote into its own database, read before macOS has a notification record for it.
struct InstantMessage: Sendable {
    let bundleID: String
    /// The chat: the contact's name, or the group's.
    let title: String
    /// The message. In a group the sender's name goes in front, the way WhatsApp's own reads.
    let body: String
    /// When the message arrived, as the app recorded it.
    let date: Date
    /// Unread messages in its chat: zero while the user has that chat open, since WhatsApp reads it
    /// the moment it lands.
    let chatUnread: Int
    /// The chat it came in.
    let thread: NotificationThread?
}

/// Reads new WhatsApp messages from WhatsApp's own database, which it writes the moment a message
/// arrives. macOS writes its notification record about five seconds later — and sometimes not at all —
/// so this is what makes a WhatsApp notification appear with its sender and text at once.
///
/// It needs the same Full Disk Access as the notification database. Anything it can't read with
/// confidence it passes over: an unknown kind of message, a chat it can't name, a broadcast or a
/// channel. macOS's record then reports that message the usual way a few seconds later, so passing
/// over costs time, never the notification itself.
@MainActor
final class WhatsAppMessageSource {
    static let bundleID = "net.whatsapp.WhatsApp"

    /// Older than this, a message is WhatsApp filling in history (a new link, a sync), not news.
    private static let freshness: TimeInterval = 60
    /// Messages reported from a single read. A bigger jump is a sync; the rest is left to macOS.
    private static let maxPerRead = 10
    /// The chats Glint reports: one-to-one (0) and groups (1 and 4). Status updates, broadcast lists
    /// and channels notify by rules of their own, so they're left to macOS's records.
    private static let reportedSessionTypes: Set<Int32> = [0, 1, 4]
    /// Message kinds that carry their own text: what someone wrote, a link, a document's name.
    private static let textMessageTypes: Set<Int32> = [0, 7, 8]
    /// Message kinds Glint can name itself; a caption, when there is one, is used instead.
    private static let mediaLabels: [Int32: String] = [
        1: "📷 Fotoğraf",
        2: "🎬 Video",
        3: "🎤 Sesli mesaj",
        15: "Çıkartma",
    ]
    /// What an ordinary message carries. Anything else is one of WhatsApp's own notices — somebody
    /// added to a group, a changed security code, a call — which it doesn't send as a message.
    private static let ordinaryGroupEvents: Set<Int32> = [0, 2]
    /// A burst of WhatsApp's log writes is read once, this long after the first of them.
    private static let readDelay: TimeInterval = 0.05
    /// WhatsApp stores a message first and ties it to its chat a moment later, so a row that isn't
    /// finished yet is looked at again for this long. After that its notification is macOS's to report.
    private static let completionWindow: TimeInterval = 3
    /// How soon an unfinished row is looked at again.
    private static let retryDelay: TimeInterval = 0.2

    /// Called for every new incoming message, oldest first.
    var onMessage: ((InstantMessage) -> Void)?

    /// Whether the database reads as expected. False means Glint is back on macOS's records alone:
    /// no Full Disk Access, WhatsApp never started, or an update that changed its tables.
    private(set) var isReadable = false

    nonisolated private static let databaseURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Group Containers/group.net.whatsapp.WhatsApp.shared/ChatStorage.sqlite")

    private let databasePath: String
    private let walPath: String

    /// The database is WhatsApp's own; another one can be given to try the reading out.
    init(databaseURL: URL = WhatsAppMessageSource.databaseURL) {
        databasePath = databaseURL.path
        walPath = databaseURL.path + "-wal"
    }

    private var enabled = false
    /// The newest message read so far; nil until the first read sets the baseline.
    private var lastRowID: Int64?
    private var walSource: DispatchSourceFileSystemObject?
    private var lastWALState: (size: Int64, modified: Double)?
    private var readScheduled = false
    private var retryScheduled = false
    /// Rows WhatsApp hadn't finished writing, and when each was first seen.
    private var unfinishedRows: [Int64: Date] = [:]

    /// Starts or stops watching. Switched on, everything already in the database counts as old.
    func update(enabled: Bool) {
        if enabled, self.enabled {
            // SQLite starts a new log file when WhatsApp's last connection closes; watch that one.
            if walSource == nil { startWatching() }
            return
        }
        guard enabled != self.enabled else { return }
        self.enabled = enabled
        lastRowID = nil
        lastWALState = nil
        unfinishedRows.removeAll()
        if enabled {
            startWatching()
            check()
        } else {
            stopWatching()
            isReadable = false
        }
    }

    /// Reads the new messages if WhatsApp has written anything since the last look. Cheap to call
    /// often: with nothing new it's a single `stat`.
    func check() {
        guard enabled else { return }
        var info = stat()
        guard stat(walPath, &info) == 0 else {
            // No log file (WhatsApp has never run, or it checkpointed the log away): the database
            // itself still answers.
            readNewMessages()
            return
        }
        let state = (
            size: Int64(info.st_size),
            modified: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000
        )
        guard lastWALState == nil || state != lastWALState! else { return }
        lastWALState = state
        readNewMessages()
    }

    // MARK: - Watching

    private func startWatching() {
        stopWatching()
        let descriptor = open(walPath, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .delete, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            // The log is gone: WhatsApp closed the database and SQLite will start a new file, which
            // this one would never hear about again. `update(enabled:)` picks the new one up.
            if !source.data.isDisjoint(with: [.delete, .rename]) {
                self.stopWatching()
            }
            self.scheduleRead()
        }
        source.setCancelHandler { close(descriptor) }
        walSource = source
        source.resume()
    }

    private func stopWatching() {
        walSource?.cancel()
        walSource = nil
    }

    /// WhatsApp writes to its log several times per message (and for receipts it sends); a burst is
    /// read once.
    private func scheduleRead() {
        guard !readScheduled else { return }
        readScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.readDelay) { [weak self] in
            MainActor.assumeIsolated {
                self?.readScheduled = false
                self?.check()
            }
        }
    }

    // MARK: - Reading

    /// The new messages, and the rows that weren't finished last time (`rowIDs`, already integers).
    private static func newMessagesSQL(retrying rowIDs: [Int64]) -> String {
        let retry = rowIDs.isEmpty ? "" : " OR m.Z_PK IN (\(rowIDs.map(String.init).joined(separator: ",")))"
        return """
            SELECT m.Z_PK, m.ZTEXT, m.ZMESSAGEDATE, m.ZMESSAGETYPE, m.ZPUSHNAME, m.ZGROUPEVENTTYPE,
                   s.ZPARTNERNAME, s.ZSESSIONTYPE, s.ZUNREADCOUNT,
                   g.ZCONTACTNAME, g.ZFIRSTNAME, m.ZGROUPMEMBER,
                   p.ZMUTEDUNTIL, m.ZCHATSESSION, s.ZCONTACTJID, s.ZCONTACTIDENTIFIER
            FROM ZWAMESSAGE m
            LEFT JOIN ZWACHATSESSION s ON s.Z_PK = m.ZCHATSESSION
            LEFT JOIN ZWAGROUPMEMBER g ON g.Z_PK = m.ZGROUPMEMBER
            LEFT JOIN ZWACHATPUSHCONFIG p ON p.ZJID = s.ZCONTACTJID
            WHERE m.ZISFROMME = 0 AND (m.Z_PK > ?\(retry))
            ORDER BY m.Z_PK
            LIMIT 50;
        """
    }

    private func readNewMessages() {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(databasePath, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let database = handle else {
            if let handle { sqlite3_close(handle) }
            isReadable = false
            return
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 100)

        guard let lastRowID else {
            // The first read only marks where the new messages start.
            self.lastRowID = Self.newestRowID(in: database)
            isReadable = self.lastRowID != nil
            return
        }

        var statement: OpaquePointer?
        let sql = Self.newMessagesSQL(retrying: unfinishedRows.keys.sorted())
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            // A WhatsApp update changed the tables: macOS's records take over again.
            isReadable = false
            return
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, lastRowID)

        let now = Date()
        var newest = lastRowID
        var messages: [InstantMessage] = []
        var seen: Set<Int64> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let rowID = sqlite3_column_int64(statement, 0)
            newest = max(newest, rowID)
            seen.insert(rowID)
            let firstSeen = unfinishedRows[rowID] ?? now
            switch Self.read(statement: statement, now: now) {
            case .message(let message):
                unfinishedRows[rowID] = nil
                messages.append(message)
            case .unfinished where now.timeIntervalSince(firstSeen) < Self.completionWindow:
                unfinishedRows[rowID] = firstSeen
            case .unfinished, .notOurs:
                unfinishedRows[rowID] = nil
            }
        }
        // A row that's gone (WhatsApp removed it) is no longer waited for.
        for rowID in unfinishedRows.keys where !seen.contains(rowID) {
            unfinishedRows[rowID] = nil
        }
        isReadable = true
        self.lastRowID = newest
        if !unfinishedRows.isEmpty {
            scheduleRetry()
        }
        // More at once than anyone gets in one moment: WhatsApp is catching up, and macOS's records
        // report the rest at their own pace.
        for message in messages.prefix(Self.maxPerRead) {
            onMessage?(message)
        }
    }

    private static func newestRowID(in database: OpaquePointer) -> Int64? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT max(Z_PK) FROM ZWAMESSAGE;", -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return sqlite3_column_int64(statement, 0)
    }

    /// What a row turned out to be.
    private enum Row {
        case message(InstantMessage)
        /// WhatsApp is still writing it: its chat isn't tied to it yet, or the message itself is missing.
        case unfinished
        /// Not a notification Glint reports: a muted chat, a status update or a channel, WhatsApp's own
        /// system messages, a message older than the app catching up, or a kind Glint can't put into words.
        case notOurs
    }

    private static func read(statement: OpaquePointer?, now: Date) -> Row {
        func text(_ column: Int32) -> String? {
            guard sqlite3_column_type(statement, column) == SQLITE_TEXT,
                  let value = sqlite3_column_text(statement, column) else { return nil }
            let string = String(cString: value).trimmingCharacters(in: .whitespacesAndNewlines)
            return string.isEmpty ? nil : string
        }
        func isNull(_ column: Int32) -> Bool {
            sqlite3_column_type(statement, column) == SQLITE_NULL
        }

        let messageType = sqlite3_column_int(statement, 3)
        let groupEvent = sqlite3_column_int(statement, 5)
        guard ordinaryGroupEvents.contains(groupEvent) else { return .notOurs }

        let date = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 2))
        guard now.timeIntervalSince(date) < freshness else { return .notOurs }

        // The chat is tied to the message a moment after WhatsApp stores it.
        guard !isNull(13), !isNull(7) else { return .unfinished }
        let sessionType = sqlite3_column_int(statement, 7)
        guard reportedSessionTypes.contains(sessionType) else { return .notOurs }

        // A muted chat doesn't notify in WhatsApp either. "Muted until" is far in the future when
        // it's muted for good.
        if !isNull(12), sqlite3_column_double(statement, 12) > now.timeIntervalSinceReferenceDate {
            return .notOurs
        }

        guard let chatName = text(6) ?? text(4) else { return .unfinished }
        // A kind of message Glint can't put into words is left to macOS's record; one whose text
        // hasn't landed yet is looked at again in a moment.
        var body: String
        if textMessageTypes.contains(messageType) {
            guard let written = text(1) else { return .unfinished }
            body = written
        } else if let label = mediaLabels[messageType] {
            body = text(1) ?? label
        } else {
            return .notOurs
        }
        // In a group the sender goes in front of the message, as WhatsApp's own notification has it.
        if !isNull(11), let sender = text(9) ?? text(10) ?? text(4) {
            body = "\(sender): \(body)"
        }

        return .message(InstantMessage(
            bundleID: bundleID,
            title: chatName,
            body: body,
            date: date,
            chatUnread: Int(sqlite3_column_int(statement, 8)),
            thread: text(14).map { NotificationThread(id: $0, url: chatURL(jid: $0, identifier: text(15), sessionType: sessionType)) }
        ))
    }

    /// Opens a one-to-one chat: WhatsApp's address takes a phone number. A chat is filed under its
    /// number or under a hidden id ("…@lid"), and the other one is kept as its contact identifier, so
    /// the number is in one of the two. A group has no address; WhatsApp itself opens for those.
    private static func chatURL(jid: String, identifier: String?, sessionType: Int32) -> URL? {
        guard sessionType == 0,
              let phoneJID = [jid, identifier].compactMap({ $0 }).first(where: { $0.hasSuffix("@s.whatsapp.net") })
        else { return nil }
        let number = phoneJID.prefix { $0 != "@" && $0 != ":" }.filter(\.isNumber)
        guard !number.isEmpty else { return nil }
        return URL(string: "whatsapp://send?phone=\(number)")
    }

    /// Looks again shortly: the rest of a message lands within moments of the row itself.
    private func scheduleRetry() {
        guard !retryScheduled else { return }
        retryScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.retryDelay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.retryScheduled = false
                guard self.enabled else { return }
                self.readNewMessages()
            }
        }
    }
}
