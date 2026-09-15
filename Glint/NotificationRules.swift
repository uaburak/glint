import Foundation

/// Which notifications are important: those with one of the user's words in them.
enum NotificationRules {
    /// The words typed in settings, separated by commas or new lines.
    static func keywords(from text: String) -> [String] {
        text.split { $0 == "," || $0.isNewline }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Whether any of the texts contains one of the keywords, ignoring case and accents.
    static func matches(_ texts: [String?], keywords: [String]) -> Bool {
        guard !keywords.isEmpty else { return false }
        let text = texts.compactMap { $0 }.joined(separator: "\n")
        return keywords.contains { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }
}

/// Daily hours Glint keeps quiet, in minutes after midnight. They may run past midnight (22:00–07:00).
struct QuietHours: Equatable {
    var start: Int
    var end: Int

    func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        guard start != end else { return false }
        return start < end ? (start..<end).contains(minute) : (minute >= start || minute < end)
    }
}

/// Why Glint keeps quiet: no sound, glow or alarm, while banners still come in silently.
enum QuietReason: Equatable {
    case focus
    case quietHours

    var title: String {
        switch self {
        case .focus: "Odak açık"
        case .quietHours: "Sessiz saatler"
        }
    }
}

/// Whether a macOS Focus (Rahatsız Etme, Uyku, İş…) is on, scheduled ones included, from the record
/// macOS keeps of them. The file is protected like the notification database, so reading it needs
/// Full Disk Access.
///
/// Each Focus that's switched on is an assertion; switching it off adds an invalidation for its UUID,
/// or a request that invalidates every assertion made before it.
@MainActor
enum FocusState {
    private static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/DoNotDisturb/DB/Assertions.json")

    /// The file's modification date, size and file number when it was last parsed.
    private static var parsedVersion: [FileAttributeKey: AnyHashable]?
    private static var focused = false

    /// Cheap to call often: the file is parsed again only once it changes.
    static func isOn() -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            parsedVersion = nil
            focused = false
            return false
        }
        let version = attributes.filter { [.modificationDate, .size, .systemFileNumber].contains($0.key) }
            .compactMapValues { $0 as? AnyHashable }
        if version != parsedVersion {
            parsedVersion = version
            focused = parse()
        }
        return focused
    }

    private static func parse() -> Bool {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stores = root["data"] as? [[String: Any]] else { return false }

        for store in stores {
            let invalidated = Set((store["storeInvalidationRecords"] as? [[String: Any]] ?? []).compactMap {
                ($0["invalidationAssertion"] as? [String: Any])?["assertionUUID"] as? String
            })
            let clearedAt = (store["storeInvalidationRequestRecords"] as? [[String: Any]] ?? [])
                .filter { (($0["invalidationRequestPredicate"] as? [String: Any])?["invalidationPredicateType"] as? String) == "any" }
                .compactMap { ($0["invalidationRequestDateTimestamp"] as? NSNumber)?.doubleValue }
                .max() ?? 0

            for assertion in store["storeAssertionRecords"] as? [[String: Any]] ?? [] {
                if let uuid = assertion["assertionUUID"] as? String, invalidated.contains(uuid) { continue }
                if let start = (assertion["assertionStartDateTimestamp"] as? NSNumber)?.doubleValue, start < clearedAt { continue }
                return true
            }
        }
        return false
    }
}
