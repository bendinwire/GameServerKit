import Foundation

/// One JSON object per line, on disk, in the server's working directory.
///
/// The persistence story for every game server here is "no database". Rooms live in memory;
/// the few things that must outlive a restart (finished games, linked identities) go to a flat
/// file like this. Low write volume, read back in full, good enough.
///
/// Rows that fail to decode are skipped, not fatal: files are append-only across versions, so
/// an old line the current type cannot read must not take the newer lines down with it. Types
/// stored here should make every field added later Optional for the same reason.
public struct JSONLinesFile<Row: Codable>: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// Every decodable row, in file order (oldest first).
    public func load() -> [Row] {
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else {
            return []
        }
        let decoder = JSONDecoder()
        var rows: [Row] = []
        for line in text.split(separator: "\n") {
            guard let lineData = line.data(using: .utf8),
                  let row = try? decoder.decode(Row.self, from: lineData) else { continue }
            rows.append(row)
        }
        return rows
    }

    /// Adds one row to the end of the file, creating it if needed.
    ///
    /// Failures are reported through `PersistenceHealth` (an error log line and the health
    /// route), never swallowed — see that type for the twenty days this used to cost.
    ///
    /// An existing file is only ever appended to. The old fallback, when the file existed but
    /// couldn't be opened for writing, was `Data.write(to:)` — which TRUNCATES. It only ever ran
    /// into the same permission error, but on any failure it could get past, it would have
    /// replaced the whole history with one row.
    public func append(_ row: Row) {
        let lineData: Data
        do {
            lineData = try JSONEncoder().encode(row) + Data("\n".utf8)
        } catch {
            PersistenceHealth.shared.failed(url, "encode a row for", error)
            return
        }
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: lineData)
            } else {
                // `.withoutOverwriting`: if something creates the file between the check and
                // here, fail rather than clobber it.
                try lineData.write(to: url, options: .withoutOverwriting)
            }
            PersistenceHealth.shared.succeeded(url)
        } catch {
            PersistenceHealth.shared.failed(url, "append to", error)
        }
    }

    /// Replaces the whole file. Written to a temp file and moved into place so a crash mid-write
    /// cannot leave a half-file where the data used to be.
    public func rewrite(_ rows: [Row]) {
        let encoder = JSONEncoder()
        let lines = rows.compactMap { row -> String? in
            guard let data = try? encoder.encode(row) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        let text = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
        let temp = url.appendingPathExtension("rewrite")
        do {
            try text.write(to: temp, atomically: true, encoding: .utf8)
        } catch {
            PersistenceHealth.shared.failed(url, "write the replacement for", error)
            return
        }
        // POSIX rename, not `FileManager.replaceItemAt`: on Linux that call deleted the original
        // and left the `.rewrite` file behind, so the next restart started with nothing.
        // rename(2) is atomic and overwrites in place.
        if rename(temp.path, url.path) == 0 {
            PersistenceHealth.shared.succeeded(url)
        } else {
            PersistenceHealth.shared.failed(url, "rename the replacement over", POSIXFailure(code: errno))
        }
    }
}
