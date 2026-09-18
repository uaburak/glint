import Foundation

/// Reads new Microsoft Teams messages from Teams' own store, which it writes the moment a message
/// arrives — measured 5 ms after its Dock badge rises, where macOS's notification record takes about
/// five seconds.
///
/// Teams keeps its chats in its embedded browser's IndexedDB, and appends every new message to that
/// store's log file. A message is a run of strings there: `content` and then `imdisplayname`,
/// `originalarrivaltime`, `from` and the rest, with the chat's own `threadType` just before it.
/// Glint reads those runs and nothing else; whatever it can't read with confidence it leaves to
/// macOS's record, which arrives seconds later as before.
///
/// Reading the folder needs the same Full Disk Access as the notification database.
@MainActor
final class TeamsMessageSource {
    static let bundleID = "com.microsoft.teams2"

    /// Older than this, a message is Teams catching up rather than news: it writes a new one within
    /// a moment of its arrival, but it also rewrites a chat's recent messages when it syncs one.
    private static let freshness: TimeInterval = 20
    /// Messages reported from a single read; a bigger jump is a sync.
    private static let maxPerRead = 10
    /// The chats Glint reports. A channel post follows rules of its own (mentions, followed channels),
    /// so those are left to macOS's records.
    private static let reportedThreadType = "chat"
    /// A burst of writes is read once, this long after the first of them.
    private static let readDelay: TimeInterval = 0.05
    /// How many message ids are remembered, so a record Teams rewrites isn't reported twice.
    private static let idMemory = 400
    /// Teams' own file naming the signed-in user.
    private static let accountFile = "ecs_request_param.json"

    /// Called for every new incoming message, oldest first.
    var onMessage: ((InstantMessage) -> Void)?

    /// Whether the store reads as expected: false means Glint is back on macOS's records alone.
    private(set) var isReadable = false

    private static let teamsFolder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Containers/com.microsoft.teams2/Data/Library/Application Support/Microsoft/MSTeams")

    private let teamsFolder: URL
    private var storeFolder: URL {
        teamsFolder.appendingPathComponent("EBWebView/WV2Profile_tfw/IndexedDB/https_teams.microsoft.com_0.indexeddb.leveldb")
    }

    init(teamsFolder: URL = TeamsMessageSource.teamsFolder) {
        self.teamsFolder = teamsFolder
    }

    private var enabled = false
    private var logPath: String?
    private var offset: UInt64 = 0
    private var logSource: DispatchSourceFileSystemObject?
    private var readScheduled = false
    /// The ids of the messages already reported, oldest first.
    private var reportedIDs: [String] = []
    /// The user's own account id, so their own messages don't come back as notifications.
    private var ownID: String?

    /// Starts or stops watching. Switched on, everything already in the store counts as old.
    func update(enabled: Bool) {
        if enabled, self.enabled {
            if ownID == nil { ownID = readOwnID() }
            refreshLogFile()
            return
        }
        guard enabled != self.enabled else { return }
        self.enabled = enabled
        if enabled {
            ownID = readOwnID()
            refreshLogFile()
        } else {
            stopWatching()
            logPath = nil
            isReadable = false
        }
    }

    /// Reads whatever Teams has appended since the last look. Cheap to call often: with nothing new
    /// it's a single `stat`.
    func check() {
        guard enabled, let path = logPath else { return }
        var info = stat()
        guard stat(path, &info) == 0 else {
            refreshLogFile()
            return
        }
        let size = UInt64(info.st_size)
        if size < offset {
            // Teams rewrote the file: take it from here.
            offset = size
            return
        }
        guard size > offset else { return }
        readAppended(path: path, upTo: size)
    }

    // MARK: - Who the user is

    /// Teams names the signed-in user in its own settings file; without it nothing is reported, since
    /// the user's own messages couldn't be told from anyone else's.
    private func readOwnID() -> String? {
        let path = teamsFolder.appendingPathComponent(Self.accountFile)
        guard let data = FileManager.default.contents(atPath: path.path) else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        guard let range = text.range(of: "\"userId\"\\s*:\\s*\"[^\"]+\"", options: .regularExpression),
              let id = text[range].split(separator: "\"").last.map(String.init),
              !id.isEmpty else { return nil }
        return id
    }

    // MARK: - The log file

    /// Teams writes to the newest `.log` in the store and starts a new one now and then.
    private func refreshLogFile() {
        let newest = ((try? FileManager.default.contentsOfDirectory(atPath: storeFolder.path)) ?? [])
            .filter { $0.hasSuffix(".log") }
            .sorted()
            .last
        guard let newest else {
            isReadable = false
            return
        }
        let path = storeFolder.appendingPathComponent(newest).path
        guard path != logPath else {
            if logSource == nil { startWatching(path: path) }
            return
        }
        logPath = path
        // Everything already written is old news.
        var info = stat()
        offset = stat(path, &info) == 0 ? UInt64(info.st_size) : 0
        isReadable = offset > 0 && ownID != nil
        startWatching(path: path)
    }

    private func startWatching(path: String) {
        stopWatching()
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .delete, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            if !source.data.isDisjoint(with: [.delete, .rename]) {
                self.stopWatching()
            }
            self.scheduleRead()
        }
        source.setCancelHandler { close(descriptor) }
        logSource = source
        source.resume()
    }

    private func stopWatching() {
        logSource?.cancel()
        logSource = nil
    }

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

    private func readAppended(path: String, upTo size: UInt64) {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            isReadable = false
            return
        }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: offset)
        } catch {
            offset = size
            return
        }
        let data = (try? handle.readToEnd()) ?? Data()
        offset = size
        guard !data.isEmpty else { return }
        if ownID == nil { ownID = readOwnID() }
        guard let ownID else {
            isReadable = false
            return
        }
        isReadable = true

        let found = Self.messages(in: [UInt8](data), now: Date(), ownID: ownID)
        for message in found.prefix(Self.maxPerRead) where !reportedIDs.contains(message.id) {
            reportedIDs.append(message.id)
            if reportedIDs.count > Self.idMemory { reportedIDs.removeFirst(reportedIDs.count - Self.idMemory) }
            onMessage?(message.message)
        }
    }

    // MARK: - Teams' records

    /// One message read out of the store, with the id Teams gave it.
    struct Reported {
        let id: String
        let message: InstantMessage
    }

    /// The messages in a chunk of Teams' log. Everything uncertain is left out for macOS's record: a
    /// channel post, a message from the user themselves, one whose sender, text or time can't be read.
    static func messages(in bytes: [UInt8], now: Date, ownID: String) -> [Reported] {
        let strings = v8Strings(in: bytes)
        var messages: [Reported] = []
        var fields: [String: String] = [:]
        /// The chat's kind is written just before the message that belongs to it.
        var threadType: String?
        var recordThreadType: String?

        func finish() {
            defer { fields.removeAll() }
            guard recordThreadType == reportedThreadType else { return }
            guard let sender = fields["from"], let name = fields["imdisplayname"], !name.isEmpty else { return }
            // `from` reads like "worker/8:orgid:<id>"; the user's own messages stay quiet.
            guard !sender.contains(ownID) else { return }
            guard let arrived = fields["originalarrivaltime"] ?? fields["composetime"],
                  let date = isoDate(arrived),
                  now.timeIntervalSince(date) < freshness else { return }
            guard let body = fields["content"].map(plainText), !body.isEmpty else { return }
            let id = fields["clientmessageid"] ?? "\(sender)-\(arrived)"
            messages.append(Reported(id: id, message: InstantMessage(
                bundleID: bundleID,
                title: name,
                body: body,
                date: date,
                // Teams names the open conversation in its window title, which is what tells Glint
                // whether the user is looking at it.
                chatUnread: 1
            )))
        }

        var index = 0
        while index + 1 < strings.count {
            let key = strings[index]
            if key == "threadType" {
                threadType = strings[index + 1]
                index += 2
                continue
            }
            guard Self.messageKeys.contains(key) else { index += 1; continue }
            // A message starts at its text; what follows belongs to it.
            if key == "content" {
                finish()
                recordThreadType = threadType
            }
            if fields[key] == nil { fields[key] = strings[index + 1] }
            index += 2
        }
        finish()
        return messages
    }

    /// The fields a message is put together from.
    private static let messageKeys: Set<String> = [
        "content", "imdisplayname", "originalarrivaltime", "composetime", "from", "clientmessageid",
    ]

    /// V8 writes a string as a tag, its length and its bytes: 0x22 for plain text, 0x63 for UTF-16
    /// (what a message with Turkish letters or emoji becomes).
    static func v8Strings(in bytes: [UInt8]) -> [String] {
        var strings: [String] = []
        var index = 0
        while index < bytes.count {
            let tag = bytes[index]
            guard tag == 0x22 || tag == 0x63 else { index += 1; continue }
            var length = 0, shift = 0, cursor = index + 1, complete = false
            while cursor < bytes.count, shift <= 28 {
                let byte = bytes[cursor]
                cursor += 1
                length |= Int(byte & 0x7F) << shift
                if byte & 0x80 == 0 { complete = true; break }
                shift += 7
            }
            guard complete, length > 0, length <= 8192, cursor + length <= bytes.count else {
                index += 1
                continue
            }
            let slice = Array(bytes[cursor..<(cursor + length)])
            if tag == 0x22 {
                guard slice.allSatisfy({ $0 >= 9 && $0 < 127 }) else { index += 1; continue }
                strings.append(String(decoding: slice, as: UTF8.self))
            } else {
                guard length % 2 == 0, let text = String(bytes: slice, encoding: .utf16LittleEndian),
                      !text.unicodeScalars.contains(where: { $0.value < 9 }) else { index += 1; continue }
                strings.append(text)
            }
            index = cursor + length
        }
        return strings
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func isoDate(_ text: String) -> Date? {
        isoFormatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    /// Teams sends its messages as HTML: the text of it, with mentions and emoji kept as they read.
    static func plainText(_ html: String) -> String {
        var text = html
        // An emoji is written as <emoji alt="😀" …>; keep what it stands for.
        text = text.replacingOccurrences(
            of: "<emoji[^>]*alt=\"([^\"]*)\"[^>]*>", with: "$1",
            options: [.regularExpression, .caseInsensitive]
        )
        text = text.replacingOccurrences(of: "<(br|/p|/div)[^>]*>", with: " ", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (entity, character) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&nbsp;", " ")] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        return text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
