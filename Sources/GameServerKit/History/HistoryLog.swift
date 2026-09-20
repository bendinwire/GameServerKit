import Foundation

/// A row in a game's history that knows how to redact one person out of itself.
public protocol HistoryRow: Codable, Sendable {
    /// Replaces every trace of `key` with `redactedName` (name, key, and anywhere else the name
    /// was written down). Returns true if anything changed.
    mutating func redact(key: String, as redactedName: String) -> Bool
}

/// Append-only log of finished games, persisted as JSON lines so it survives a restart — the
/// rest of every game server here is deliberately "no database, pure in-memory", but history
/// has to outlive the `Room` it came from. Read back in full once, then cached.
///
/// Owned by the game's history actor, not an actor itself, so the game's own queries
/// (`captainRecord`, stats) run on the same cache without a second hop.
public final class HistoryLog<Row: HistoryRow> {
    public static var redactedName: String { "Former player" }

    private let file: JSONLinesFile<Row>
    private var cache: [Row]?
    public var url: URL { file.url }

    public init(url: URL) {
        file = JSONLinesFile(url: url)
    }

    public func append(_ row: Row) {
        file.append(row)
        cache?.append(row)
    }

    /// Every row, oldest first — the order they were played, which is what a "latest name" or a
    /// streak has to be read in.
    public var allRows: [Row] {
        if let cache { return cache }
        let rows = file.load()
        cache = rows
        return rows
    }

    /// Most recent first.
    public func recent(limit: Int) -> [Row] {
        Array(allRows.suffix(limit).reversed())
    }

    /// Erases one person from the history without touching anyone else's record.
    ///
    /// A row is a shared object — everyone's game, one line — so "delete my data" cannot mean
    /// "delete the row": that would take the other players' record with it. The seat is redacted
    /// in place instead and the game survives for the people still in it. Returns how many rows
    /// changed. Rewrites the file, which is the one operation that does: the log is append-only
    /// precisely so nothing can rewrite history, and this is the deliberate exception.
    public func forget(key: String) -> Int {
        var rows = allRows
        var changed = 0
        for i in rows.indices where rows[i].redact(key: key, as: Self.redactedName) {
            changed += 1
        }
        guard changed > 0 else { return 0 }
        cache = rows
        file.rewrite(rows)
        return changed
    }
}
