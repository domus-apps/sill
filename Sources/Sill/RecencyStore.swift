import Foundation

/* Remembers which suggestions the user actually picked, per command, so
   they float to the top next time. Ranking still puts match quality first:
   recency only orders suggestions that match the typed prefix equally, so a
   recently used item never outranks what you're visibly typing toward.
   Kept small (LRU-trimmed) and in UserDefaults — this is a convenience,
   not data. */
final class RecencyStore {
    private static let key = "recency.uses"
    private static let limit = 300

    private let defaults: UserDefaults?
    /// "<command>\u{1F}<display>" → seconds since 1970 of the last pick.
    private var uses: [String: Double]

    /// Pass nil for an in-memory store (tests).
    init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        uses = defaults?.dictionary(forKey: Self.key) as? [String: Double] ?? [:]
    }

    func lastUse(command: String, display: String) -> Date? {
        uses[Self.id(command, display)].map { Date(timeIntervalSince1970: $0) }
    }

    /// The most recent pick made anywhere under `command` — evidence that
    /// the command is one the user actually runs.
    func lastUse(command: String) -> Date? {
        let prefix = command + "\u{1F}"
        let latest = uses.filter { $0.key.hasPrefix(prefix) }.map(\.value).max()
        return latest.map { Date(timeIntervalSince1970: $0) }
    }

    func record(command: String, display: String) {
        uses[Self.id(command, display)] = Date().timeIntervalSince1970
        if uses.count > Self.limit {
            // Drop the oldest entries down to the cap.
            let oldest = uses.sorted { $0.value < $1.value }.prefix(uses.count - Self.limit)
            for (key, _) in oldest { uses.removeValue(forKey: key) }
        }
        defaults?.set(uses, forKey: Self.key)
    }

    /// Stable reorder: most recently picked first, never-picked keep their
    /// existing order after them.
    func sorted(_ suggestions: [Suggestion], command: String) -> [Suggestion] {
        let stamped = suggestions.enumerated().map { index, s in
            (s, uses[Self.id(command, s.display)] ?? -Double.infinity, index)
        }
        return stamped.sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            return $0.2 < $1.2
        }.map(\.0)
    }

    private static func id(_ command: String, _ display: String) -> String {
        command + "\u{1F}" + display
    }
}
